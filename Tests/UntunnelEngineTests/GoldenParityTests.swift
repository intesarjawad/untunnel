import Foundation
import Testing

@testable import UntunnelEngine

/// The most the streaming and reference waveforms may differ by at any sample.
private let maximumDifferenceLimit: Float = 1e-3
/// The difference SNR the streaming path must beat, which is a floor and not a claim.
private let differenceSNRFloorDB = 50.0

/// Runs every golden through the real-time model and compares the result with the waveform
/// the reference implementation wrote for the same input.
///
/// All three paths meet the same tolerances: reference frames, the engine's frames with the
/// first-frame branch-cut signs taken from the reference, and raw samples. Matching the
/// publisher's float32 window construction and multiplication keeps the reflected first
/// frame's phase sufficiently close even when the FFTs round differently.
///
/// The goldens hold no weights, so the suite needs the pinned checkpoint and is skipped
/// without it rather than passing on an empty comparison. Set `UNTUNNEL_REGENERATE_PARITY=1`
/// to record the measured difference SNR per golden in `docs/bench.md`.
@Suite(.enabled(if: RealtimeReference.isAvailable, RealtimeReference.unavailableReason))
struct GoldenParity {
    @Test
    func streamingMatchesEveryGolden() throws {
        let reference = try RealtimeReference.shared.get()
        #expect(!reference.manifest.goldens.isEmpty)

        var rows: [GoldenParityRow] = []
        for entry in reference.manifest.goldens {
            let golden = ParityGolden(
                name: entry.name,
                sampleRate: entry.sampleRate,
                exitLayer: entry.exitLayer,
                lookAhead: entry.lookAhead,
                input: try reference.array("goldens.\(entry.name).input").values,
                output: try reference.array("goldens.\(entry.name).output").values
            )
            let weights = try reference.weights(exitLayer: golden.exitLayer)
            let phases = try reference.array("goldens.\(entry.name).phase").values
            let measurement = measure(
                golden,
                magnitudes: try reference.array("goldens.\(entry.name).magnitude").values,
                phases: phases,
                weights: weights
            )
            let ownTransform = measureOwnTransform(
                golden, referencePhases: phases, weights: weights)
            let fromSamples = measure(golden, weights: weights)
            rows.append(
                GoldenParityRow(
                    golden: golden,
                    measurement: measurement,
                    ownTransform: ownTransform,
                    fromSamples: fromSamples
                )
            )

            #expect(fromSamples.peakLag == 0, "golden '\(golden.name)' is misaligned from samples")
            #expect(
                fromSamples.maximumDifference < maximumDifferenceLimit,
                "golden '\(golden.name)' differs by \(fromSamples.maximumDifference) from samples")
            #expect(
                fromSamples.snrDB > differenceSNRFloorDB,
                "golden '\(golden.name)' reaches only \(fromSamples.snrDB) dB from samples")
            #expect(measurement.peakLag == 0, "golden '\(golden.name)' is misaligned")
            #expect(
                measurement.maximumDifference < maximumDifferenceLimit,
                "golden '\(golden.name)' differs by \(measurement.maximumDifference)"
            )
            #expect(
                measurement.snrDB > differenceSNRFloorDB,
                "golden '\(golden.name)' reaches only \(measurement.snrDB) dB"
            )
            #expect(
                ownTransform.maximumDifference < maximumDifferenceLimit,
                "golden '\(golden.name)' differs by \(ownTransform.maximumDifference) through this transform"
            )
            #expect(
                ownTransform.snrDB > differenceSNRFloorDB,
                "golden '\(golden.name)' reaches only \(ownTransform.snrDB) dB through this transform"
            )
        }

        try writeBenchSection(goldenParitySection(rows))
    }
}

/// How one streamed waveform compares with its reference after the alignment shift.
struct ParityMeasurement: Equatable {
    let maximumDifference: Float
    let snrDB: Double
    let peakLag: Int
}

/// Aligns a whole streamed output with the offline reference and measures the difference.
///
/// The stream is delayed by the latency, so dropping that many leading samples lines it up with
/// the reference. The reference pads both ends by reflection, which a stream cannot reproduce,
/// so only the span from one frame in to one frame before the end is compared.
func parityMeasurement(
    streamed: [Float],
    reference: [Float],
    latencySamples: Int,
    windowLength: Int
) -> ParityMeasurement {
    let shifted = Array(streamed.dropFirst(latencySamples))
    precondition(
        shifted.count == reference.count,
        "the stream and the reference cover different numbers of samples"
    )
    let span = windowLength..<(reference.count - windowLength)
    let streaming = Array(shifted[span])
    let expected = Array(reference[span])
    return ParityMeasurement(
        maximumDifference: maximumError(streaming, expected),
        snrDB: differenceSNR(expected, streaming),
        peakLag: correlationPeakLag(streaming, expected, maxLag: windowLength)
    )
}

private func restorer(for golden: ParityGolden, weights: RealtimeRestorerWeights)
    -> RealtimeRestorer
{
    RealtimeRestorer(
        weights: weights,
        tier: Tier(
            sampleRate: golden.sampleRate,
            exitLayer: golden.exitLayer,
            lookAhead: golden.lookAhead
        )
    )
}

private func measure(
    _ golden: ParityGolden,
    magnitudes: [Float],
    phases: [Float],
    weights: RealtimeRestorerWeights
) -> ParityMeasurement {
    let restorer = restorer(for: golden, weights: weights)
    return parityMeasurement(
        streamed: restorer.restore(magnitudes: magnitudes, phases: phases),
        reference: golden.output,
        latencySamples: 0,
        windowLength: restorer.windowLength
    )
}

/// Restores the frames of this engine's transform, with the first frame's branch-cut signs
/// taken from the reference's frames.
private func measureOwnTransform(
    _ golden: ParityGolden,
    referencePhases: [Float],
    weights: RealtimeRestorerWeights
) -> ParityMeasurement {
    let restorer = restorer(for: golden, weights: weights)
    let tier = Tier(
        sampleRate: golden.sampleRate, exitLayer: golden.exitLayer, lookAhead: golden.lookAhead)
    let frames = analyzedFrames(golden.input, with: StreamingSTFT(tier: tier))
    let phases = takingFirstFrameBranchCutSigns(
        of: frames.flatMap(\.phases),
        from: referencePhases,
        binCount: restorer.binCount
    )
    return parityMeasurement(
        streamed: restorer.restore(magnitudes: frames.flatMap(\.magnitudes), phases: phases),
        reference: golden.output,
        latencySamples: 0,
        windowLength: restorer.windowLength
    )
}

/// Returns `phases` with each bin of the first frame that lies on the other side of the branch
/// cut from `reference`, π against -π, set to the reference's value.
func takingFirstFrameBranchCutSigns(
    of phases: [Float],
    from reference: [Float],
    binCount: Int
) -> [Float] {
    var result = phases
    for bin in 0..<binCount where abs(phases[bin] - reference[bin]) > .pi {
        result[bin] = reference[bin]
    }
    return result
}

private func measure(
    _ golden: ParityGolden,
    weights: RealtimeRestorerWeights
) -> ParityMeasurement {
    let restorer = restorer(for: golden, weights: weights)
    var streamed: [Float] = []
    for start in stride(from: 0, to: golden.input.count, by: restorer.hopLength) {
        let end = min(start + restorer.hopLength, golden.input.count)
        streamed.append(contentsOf: restorer.process(Array(golden.input[start..<end])))
    }
    streamed.append(contentsOf: restorer.finish())

    return parityMeasurement(
        streamed: streamed,
        reference: golden.output,
        latencySamples: restorer.latencySamples,
        windowLength: restorer.windowLength
    )
}

private let benchReportURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("docs/bench.md")

/// One input and the output the reference implementation produced for it.
struct ParityGolden {
    let name: String
    let sampleRate: Int
    let exitLayer: Int
    let lookAhead: Int
    let input: [Float]
    let output: [Float]
}

struct GoldenParityRow {
    let golden: ParityGolden
    /// The stream restored from the reference's analysed frames.
    let measurement: ParityMeasurement
    /// The stream restored from this engine's frames with the reference's first-frame signs.
    let ownTransform: ParityMeasurement
    /// The stream restored from the input samples through this engine's own transform.
    let fromSamples: ParityMeasurement
}

private let reportStart = "<!-- golden-parity:start -->"
private let reportEnd = "<!-- golden-parity:end -->"

/// The section of the benchmark report that holds the measured difference SNR per golden.
func goldenParitySection(_ rows: [GoldenParityRow]) -> String {
    var lines = [
        "## Golden parity",
        "",
        reportStart,
        "Difference between this engine's stream and the publisher's implementation, per golden:",
        "restored from the publisher's analysed frames; from this engine's transform with the",
        "signs of the first frame's phases at ±π taken from the publisher's frames; and from the",
        "input samples. The model path uses float32 Hann window construction and multiplication.",
        "The analysed-frame paths isolate model arithmetic from preprocessing differences.",
        "",
        "| Golden | Rate Hz | Exit | Look-ahead | Max abs difference | SNR dB "
            + "| Own transform: SNR dB "
            + "| From samples: max abs difference | From samples: SNR dB |",
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    for row in rows {
        let golden = row.golden
        let columns = [
            golden.name,
            String(golden.sampleRate),
            String(golden.exitLayer),
            String(golden.lookAhead),
            String(format: "%.2e", row.measurement.maximumDifference),
            String(format: "%.2f", row.measurement.snrDB),
            String(format: "%.2f", row.ownTransform.snrDB),
            String(format: "%.2e", row.fromSamples.maximumDifference),
            String(format: "%.2f", row.fromSamples.snrDB),
        ]
        lines.append("| " + columns.joined(separator: " | ") + " |")
    }
    lines.append(reportEnd)
    return lines.joined(separator: "\n") + "\n"
}

/// Puts `section` into the report, replacing an earlier copy of it and keeping the rest.
///
/// A section opens with its heading, a blank line and a start marker and closes with an end
/// marker, so the copy to replace is found by those lines.
func splicingGoldenSection(_ section: String, into report: String?) -> String {
    guard let report else {
        return "# Benchmark report\n\n" + section
    }
    let lines = section.split(separator: "\n", omittingEmptySubsequences: false)
    let opening = lines.prefix(3).joined(separator: "\n")
    let closing = lines.dropLast().last.map { $0 + "\n" } ?? ""
    guard
        let start = report.range(of: opening),
        let end = report.range(of: closing, range: start.upperBound..<report.endIndex)
    else {
        let separator = report.hasSuffix("\n") ? "\n" : "\n\n"
        return report + separator + section
    }
    return String(report[..<start.lowerBound]) + section + String(report[end.upperBound...])
}

private let benchReportLock = NSLock()

/// Regenerates `docs/bench.md` only with `UNTUNNEL_REGENERATE_PARITY=1 swift test`.
func writeBenchSection(
    _ section: String,
    to benchReportURL: URL = benchReportURL,
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws {
    guard environment["UNTUNNEL_REGENERATE_PARITY"] == "1" else { return }
    benchReportLock.lock()
    defer { benchReportLock.unlock() }
    let existing = try? String(contentsOf: benchReportURL, encoding: .utf8)
    let report = splicingGoldenSection(section, into: existing)
    try FileManager.default.createDirectory(
        at: benchReportURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(report.utf8).write(to: benchReportURL, options: .atomic)
}

// MARK: - The comparison itself, on signals written by hand

@Test
func differenceSNRUsesTheEnergyOfTheReferenceOverTheEnergyOfTheDifference() {
    // The reference carries 3² + 4² = 25 and the difference carries 1², so the ratio is 25.
    #expect(abs(differenceSNR([3, 4], [3, 3]) - 13.979_400_086_720_376) < 1e-9)
    #expect(differenceSNR([3, 4], [3, 4]) == .infinity)
}

@Test
func parityMeasurementDropsTheLatencyAndTheReflectedEdges() {
    var random = ModelRandom(seed: 0x0E51_0101)
    let reference = random.values(count: 64, limit: 0.5)
    let latency = 12
    var streamed = [Float](repeating: 0, count: latency) + reference

    let exact = parityMeasurement(
        streamed: streamed,
        reference: reference,
        latencySamples: latency,
        windowLength: 8
    )
    #expect(exact.maximumDifference == 0)
    #expect(exact.snrDB == .infinity)
    #expect(exact.peakLag == 0)

    // A change inside the first and last frame lies in the reflected padding and is ignored; one
    // inside the compared span counts.
    streamed[latency + 3] += 1
    streamed[latency + 61] += 1
    let edges = parityMeasurement(
        streamed: streamed,
        reference: reference,
        latencySamples: latency,
        windowLength: 8
    )
    #expect(edges.maximumDifference == 0)

    streamed[latency + 30] += 0.25
    let inside = parityMeasurement(
        streamed: streamed,
        reference: reference,
        latencySamples: latency,
        windowLength: 8
    )
    #expect(abs(inside.maximumDifference - 0.25) < 1e-6)
    #expect(inside.snrDB.isFinite)
}

@Test
func onlyTheFirstFramesOppositeSignsAtTheBranchCutAreTakenFromTheReference() {
    let pi = Float.pi
    let ours: [Float] = [pi, -pi, 0, 1, pi, -pi]
    let reference: [Float] = [-pi, -pi, pi, 1.5, -pi, pi]

    // Bins 0 and 1 are the first frame; the second frame's flips are left alone.
    #expect(
        takingFirstFrameBranchCutSigns(of: ours, from: reference, binCount: 2)
            == [-pi, -pi, 0, 1, pi, -pi])
    // A difference of exactly π, or any smaller one, is not a sign flip.
    #expect(
        takingFirstFrameBranchCutSigns(of: [0, 1], from: [pi, 1.5], binCount: 2) == [0, 1])
}

@Test
func aWrongShiftMovesTheCorrelationPeakAwayFromZero() {
    var random = ModelRandom(seed: 0x0E51_0102)
    let reference = random.values(count: 96, limit: 0.5)
    let late = [Float](repeating: 0, count: 3) + reference.dropLast(3)

    #expect(correlationPeakLag(reference, reference, maxLag: 8) == 0)
    #expect(correlationPeakLag(late, reference, maxLag: 8) == 3)
}

@Test
func theGoldenSectionListsOneRowPerGolden() {
    let rows = [
        GoldenParityRow(
            golden: ParityGolden(
                name: "mic-48k", sampleRate: 48_000, exitLayer: 7, lookAhead: 1,
                input: [0], output: [0]),
            measurement: ParityMeasurement(maximumDifference: 0.00025, snrDB: 61.234, peakLag: 0),
            ownTransform: ParityMeasurement(maximumDifference: 0.0003, snrDB: 60.5, peakLag: 0),
            fromSamples: ParityMeasurement(maximumDifference: 0.002, snrDB: 48.5, peakLag: 0)
        ),
        GoldenParityRow(
            golden: ParityGolden(
                name: "speech", sampleRate: 16_000, exitLayer: 8, lookAhead: 0,
                input: [0], output: [0]),
            measurement: ParityMeasurement(maximumDifference: 0.5, snrDB: 31, peakLag: 0),
            ownTransform: ParityMeasurement(maximumDifference: 0.5, snrDB: 30.5, peakLag: 0),
            fromSamples: ParityMeasurement(maximumDifference: 0.5, snrDB: 30, peakLag: 0)
        ),
    ]

    let expected = """
        ## Golden parity

        <!-- golden-parity:start -->
        Difference between this engine's stream and the publisher's implementation, per golden:
        restored from the publisher's analysed frames; from this engine's transform with the
        signs of the first frame's phases at ±π taken from the publisher's frames; and from the
        input samples. The model path uses float32 Hann window construction and multiplication.
        The analysed-frame paths isolate model arithmetic from preprocessing differences.

        | Golden | Rate Hz | Exit | Look-ahead | Max abs difference | SNR dB | Own transform: SNR dB | From samples: max abs difference | From samples: SNR dB |
        | --- | --- | --- | --- | --- | --- | --- | --- | --- |
        | mic-48k | 48000 | 7 | 1 | 2.50e-04 | 61.23 | 60.50 | 2.00e-03 | 48.50 |
        | speech | 16000 | 8 | 0 | 5.00e-01 | 31.00 | 30.50 | 5.00e-01 | 30.00 |
        <!-- golden-parity:end -->

        """
    #expect(goldenParitySection(rows) == expected)
}

@Test
func theGoldenSectionReplacesItselfAndKeepsTheRestOfTheReport() {
    let old = "## Golden parity\n\n<!-- golden-parity:start -->\nold\n<!-- golden-parity:end -->\n"
    let fresh =
        "## Golden parity\n\n<!-- golden-parity:start -->\nnew\n<!-- golden-parity:end -->\n"

    #expect(splicingGoldenSection(fresh, into: nil) == "# Benchmark report\n\n" + fresh)

    let without = "# Benchmark report\n\nbody\n"
    #expect(splicingGoldenSection(fresh, into: without) == without + "\n" + fresh)

    let around = "# Benchmark report\n\n" + old + "\n## reuse-rs\n\ntable\n"
    let expected = "# Benchmark report\n\n" + fresh + "\n## reuse-rs\n\ntable\n"
    #expect(splicingGoldenSection(fresh, into: around) == expected)
    #expect(splicingGoldenSection(fresh, into: expected) == expected)
}

@Test
func goldenReportsAreReadOnlyUnlessRegenerationIsRequested() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let report = directory.appendingPathComponent("bench.md")
    try writeBenchSection("new section", to: report, environment: [:])
    #expect(!FileManager.default.fileExists(atPath: report.path))
}

@Test
func explicitGoldenRegenerationKeepsBothConcurrentSections() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let report = directory.appendingPathComponent("bench.md")
    DispatchQueue.concurrentPerform(iterations: 2) { index in
        do {
            try writeBenchSection(
                "section \(index)\n", to: report,
                environment: ["UNTUNNEL_REGENERATE_PARITY": "1"])
        } catch { Issue.record(error) }
    }
    let text = try String(contentsOf: report, encoding: .utf8)
    #expect(text.contains("section 0"))
    #expect(text.contains("section 1"))
}
