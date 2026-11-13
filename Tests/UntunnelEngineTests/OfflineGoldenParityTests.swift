import Foundation
import Testing

@testable import UntunnelEngine

/// The most the restored and reference waveforms may differ by at any sample.
private let maximumDifferenceLimit: Float = 1e-3
/// The difference SNR the restored file must beat, which is a floor and not a claim.
private let differenceSNRFloorDB = 50.0

/// Restores every offline golden as one chunk and compares the result with the waveform the
/// publisher's inference wrote for the same file.
///
/// As for the real-time goldens, the tolerances apply to the file restored from the
/// reference's analysed frames and to the one restored from this engine's transform with the
/// first frame's branch-cut signs taken from the reference; and the file restored from raw
/// samples. Both ends are compared: the publisher pads by reflection too.
///
/// The goldens hold no weights, so the suite needs the pinned checkpoint and is skipped
/// without it. Set `UNTUNNEL_REGENERATE_PARITY=1` to update `docs/bench.md`.
@Suite(.enabled(if: OfflineReference.isAvailable, OfflineReference.unavailableReason))
struct OfflineGoldenParity {
    @Test
    func theRestorerMatchesEveryGolden() async throws {
        let reference = try OfflineReference.shared.get()
        let weights = try reference.weights()
        let goldens = try reference.manifest.goldens.map { entry in
            OfflineGolden(
                name: entry.name,
                sampleRate: entry.sampleRate,
                input: try reference.array("goldens.\(entry.name).input").values,
                output: try reference.array("goldens.\(entry.name).output").values,
                magnitudes: try reference.array("goldens.\(entry.name).magnitude").values,
                phases: try reference.array("goldens.\(entry.name).phase").values
            )
        }
        #expect(!goldens.isEmpty)

        // Every restoration is a whole file through thirty blocks; they share nothing but the
        // weights, so they run side by side.
        var measured: [String: [OfflineParityPath: ParityMeasurement]] = [:]
        await withTaskGroup(of: (String, OfflineParityPath, ParityMeasurement).self) { group in
            for golden in goldens {
                for path in OfflineParityPath.allCases {
                    group.addTask { (golden.name, path, golden.measure(path, weights: weights)) }
                }
            }
            for await (name, path, measurement) in group {
                measured[name, default: [:]][path] = measurement
            }
        }

        var rows: [OfflineParityRow] = []
        for golden in goldens {
            guard
                let paths = measured[golden.name],
                let fromFrames = paths[.frames],
                let ownTransform = paths[.ownTransform],
                let fromSamples = paths[.samples]
            else {
                Issue.record("golden '\(golden.name)' was not measured")
                continue
            }
            let row = OfflineParityRow(
                name: golden.name, sampleRate: golden.sampleRate, fromFrames: fromFrames,
                ownTransform: ownTransform, fromSamples: fromSamples)
            rows.append(row)

            #expect(row.fromSamples.peakLag == 0, "golden '\(golden.name)' is misaligned")
            for (path, measurement) in [
                ("frames", row.fromFrames), ("own transform", row.ownTransform),
                ("samples", row.fromSamples),
            ] {
                #expect(
                    measurement.maximumDifference < maximumDifferenceLimit,
                    "golden '\(golden.name)' differs by \(measurement.maximumDifference) from \(path)"
                )
                #expect(
                    measurement.snrDB > differenceSNRFloorDB,
                    "golden '\(golden.name)' reaches only \(measurement.snrDB) dB from \(path)"
                )
            }
        }

        try writeBenchSection(offlineParitySection(rows))
    }
}

/// Where a restoration starts.
private enum OfflineParityPath: CaseIterable, Sendable {
    /// The reference's analysed frames.
    case frames
    /// This engine's frames with the reference's first-frame branch-cut signs.
    case ownTransform
    /// The input samples, through this engine's own transform.
    case samples
}

/// One file and what the publisher's inference made of it.
private struct OfflineGolden: Sendable {
    let name: String
    let sampleRate: Int
    let input: [Float]
    let output: [Float]
    let magnitudes: [Float]
    let phases: [Float]

    func measure(_ path: OfflineParityPath, weights: OfflineRestorerWeights) -> ParityMeasurement {
        // The plan covers the whole file, so it is restored as one chunk, as the reference was.
        guard let plan = ChunkPlan(chunkSamples: max(input.count, 1), overlapSamples: 0) else {
            preconditionFailure("a one-chunk plan is always valid")
        }
        let restorer = OfflineRestorer(weights: weights, sampleRate: sampleRate, plan: plan)
        let restored: [Float]
        switch path {
        case .frames:
            restored = restorer.restore(magnitudes: magnitudes, phases: phases)
        case .ownTransform:
            let own = restorer.analyze(input)
            restored = restorer.restore(
                magnitudes: own.magnitudes,
                phases: takingFirstFrameBranchCutSigns(
                    of: own.phases, from: phases, binCount: restorer.binCount))
        case .samples:
            restored = restorer.restore(input)
        }
        return offlineMeasurement(restored, output, restorer.windowLength)
    }
}

/// Compares the samples a restorer wrote with the start of the reference, which can be longer
/// by the padding the publisher adds to an input that is not a whole number of hops.
private func offlineMeasurement(_ restored: [Float], _ reference: [Float], _ windowLength: Int)
    -> ParityMeasurement
{
    let expected = Array(reference.prefix(restored.count))
    return ParityMeasurement(
        maximumDifference: maximumError(restored, expected),
        snrDB: differenceSNR(expected, restored),
        peakLag: correlationPeakLag(restored, expected, maxLag: windowLength)
    )
}

struct OfflineParityRow {
    let name: String
    let sampleRate: Int
    /// Restored from the reference's analysed frames.
    let fromFrames: ParityMeasurement
    /// Restored from this engine's frames with the reference's first-frame signs.
    let ownTransform: ParityMeasurement
    /// Restored from the input samples through this engine's own transform.
    let fromSamples: ParityMeasurement
}

/// The section of the benchmark report that holds the offline restorer's measured difference.
func offlineParitySection(_ rows: [OfflineParityRow]) -> String {
    var lines = [
        "## Offline golden parity",
        "",
        "<!-- offline-golden-parity:start -->",
        "Difference between this engine's offline restorer and the publisher's file inference,",
        "per golden, over the whole file: restored from the publisher's analysed frames; from",
        "this engine's transform with the signs of the first frame's phases at ±π taken from",
        "the publisher's frames; and from the input samples.",
        "",
        "| Golden | Rate Hz | Max abs difference | SNR dB | Own transform: SNR dB "
            + "| From samples: max abs difference | From samples: SNR dB |",
        "| --- | --- | --- | --- | --- | --- | --- |",
    ]
    for row in rows {
        let columns = [
            row.name,
            String(row.sampleRate),
            String(format: "%.2e", row.fromFrames.maximumDifference),
            String(format: "%.2f", row.fromFrames.snrDB),
            String(format: "%.2f", row.ownTransform.snrDB),
            String(format: "%.2e", row.fromSamples.maximumDifference),
            String(format: "%.2f", row.fromSamples.snrDB),
        ]
        lines.append("| " + columns.joined(separator: " | ") + " |")
    }
    lines.append("<!-- offline-golden-parity:end -->")
    return lines.joined(separator: "\n") + "\n"
}

@Test
func theOfflineSectionSplicesBesideTheStreamingOne() {
    let streaming =
        "## Golden parity\n\n<!-- golden-parity:start -->\nold\n<!-- golden-parity:end -->\n"
    let row = OfflineParityRow(
        name: "speech-8k", sampleRate: 8_000,
        fromFrames: ParityMeasurement(maximumDifference: 0.00025, snrDB: 61.234, peakLag: 0),
        ownTransform: ParityMeasurement(maximumDifference: 0.0003, snrDB: 60.5, peakLag: 0),
        fromSamples: ParityMeasurement(maximumDifference: 0.002, snrDB: 48.5, peakLag: 0))
    let section = offlineParitySection([row])
    #expect(section.contains("| speech-8k | 8000 | 2.50e-04 | 61.23 | 60.50 | 2.00e-03 | 48.50 |"))

    let report = "# Benchmark report\n\n" + streaming
    let spliced = splicingGoldenSection(section, into: report)
    #expect(spliced == report + "\n" + section)
    #expect(splicingGoldenSection(section, into: spliced) == spliced)
}
