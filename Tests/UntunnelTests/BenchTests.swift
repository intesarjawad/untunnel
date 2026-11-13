import Foundation
import Testing
import UntunnelEngine

@testable import Untunnel

@Test
func parameterCountMatchesThePublishedCheckpoint() {
    // Summed from the published checkpoint's header: 383,616 in the encoder with one first
    // layer, 814,403 in a decoder pair and 208,512 in each time-frequency block.
    #expect(Bench.parameterCount(exitLayer: 4) == 2_032_067)
    #expect(Bench.parameterCount(exitLayer: 7) == 2_657_603)
    #expect(
        Bench.parameterCount(exitLayer: 7) - Bench.parameterCount(exitLayer: 6) == 208_512
    )
    // The full depth is the 3.7M the model card states.
    #expect(Bench.parameterCount(exitLayer: 12) == 3_700_163)
}

@Test
func syntheticWeightsBuildAStreamingRestorer() throws {
    let weights = try Bench.syntheticWeights(exitLayer: 1)
    let restorer = RealtimeRestorer(
        weights: weights,
        tier: Tier(sampleRate: 400, exitLayer: 1, lookAhead: 0)
    )
    let input = [Float](repeating: 0.1, count: restorer.hopLength)

    let output = restorer.process(input)

    #expect(weights.blocks.count == 1)
    #expect(restorer.hopLength == 8)
    #expect(output.count == input.count)
    #expect(restorer.finish().count == restorer.latencySamples)
}

@Test
func percentileUsesTheNearestRank() {
    let values = [1.0, 2, 3, 4, 5, 6, 7, 8, 9, 10]

    #expect(Bench.percentile(values, 0.5) == 5)
    #expect(Bench.percentile(values, 0.95) == 10)
    #expect(Bench.percentile(values, 0.99) == 10)
    #expect(Bench.percentile([1, 2, 3, 4], 0.5) == 2)
    #expect(Bench.percentile([], 0.5) == 0)
}

@Test
func measurementCountsOnlyFramesOverTwentyMilliseconds() {
    let measurement = Bench.measurement(
        latencies: [1, 20, 20.001, 30],
        parameterCount: 155_874
    )

    #expect(measurement.medianMs == 20)
    #expect(measurement.p95Ms == 30)
    #expect(measurement.p99Ms == 30)
    #expect(measurement.maxMs == 30)
    // Two of four frames missed, which is 5,000 in 10,000.
    #expect(measurement.deadlineMissesPer10000 == 5_000)
    #expect(measurement.parameterCount == 155_874)
}

@Test
func tierFlagParsesTheThreeFields() throws {
    #expect(
        try BenchOptions.tier(from: "24000:5:1")
            == Tier(sampleRate: 24_000, exitLayer: 5, lookAhead: 1))
    #expect(
        try BenchOptions.tier(from: "16000:4")
            == Tier(sampleRate: 16_000, exitLayer: 4, lookAhead: 0))
}

@Test
func tierFlagRejectsAnImpossibleConfiguration() {
    #expect(throws: BenchUsageError.self) {
        try BenchOptions.tier(from: "24000")
    }
    #expect(throws: BenchUsageError.self) {
        try BenchOptions.tier(from: "24050:5:1")
    }
    #expect(throws: BenchUsageError.self) {
        try BenchOptions.tier(from: "24000:0:1")
    }
    #expect(throws: BenchUsageError.self) {
        try BenchOptions.tier(from: "24000:5:17")
    }
}

@Test
func optionsSelectEveryDefaultTierWithoutExplicitSelections() throws {
    let options = try BenchOptions(arguments: ["--all"])

    #expect(options.selectedTiers == BenchTiers.all)
    #expect(options.frames == 3_000)
    #expect(options.load == 0)
}

@Test
func concurrentNeedsTwoTiers() {
    #expect(throws: BenchUsageError.self) {
        try BenchOptions(arguments: ["--concurrent", "--tier", "24000:5:1"])
    }
}

@Test
func concurrentCanMeasureTwoIndependentPathsAtTheSameTier() throws {
    let options = try BenchOptions(arguments: [
        "--concurrent", "--tier", "16000:4", "--tier", "16000:4",
    ])
    #expect(options.selectedTiers == [BenchTiers.all[0], BenchTiers.all[0]])
}

@Test
func markdownListsBothPassesAndTheReuseSection() {
    let report = BenchmarkReport(
        schemaVersion: BenchmarkReport.schemaVersion,
        environment: BenchmarkEnvironment(
            machine: "fixture",
            macOS: "fixture",
            powerSource: "fixture",
            date: "2026-01-01T00:00:00Z"
        ),
        tiers: [
            BenchmarkTier(
                sampleRate: 16_000,
                exitLayer: 4,
                lookAhead: 0,
                idle: fixtureMeasurement(),
                loaded: fixtureMeasurement()
            )
        ],
        concurrent: nil
    )

    let markdown = BenchmarkMarkdown.render(report)

    #expect(markdown.contains("| 16000:4:0 | idle |"))
    #expect(markdown.contains("| 16000:4:0 | loaded |"))
    #expect(
        markdown.contains(
            "Inside the 12.00 ms p99 budget on this machine: 16000:4:0. The app runs 16000:4:0."))
    #expect(markdown.contains("## reuse-rs"))
    #expect(markdown.contains("<!-- reuse-rs:start -->"))
    #expect(markdown.contains("Machine: fixture"))
}

@Test
func markdownSaysWhenNoTierFitsTheBudget() {
    let slow = BenchmarkMeasurement(
        medianMs: 20, p95Ms: 30, p99Ms: 40, p999Ms: 50, maxMs: 60,
        deadlineMissesPer10000: 10_000, peakRSSBytes: 1_048_576, parameterCount: 121_314)
    let report = BenchmarkReport(
        schemaVersion: BenchmarkReport.schemaVersion,
        environment: BenchmarkEnvironment(
            machine: "fixture", macOS: "fixture", powerSource: "fixture",
            date: "2026-01-01T00:00:00Z"),
        tiers: [
            BenchmarkTier(sampleRate: 16_000, exitLayer: 4, lookAhead: 0, idle: slow, loaded: slow),
            BenchmarkTier(sampleRate: 48_000, exitLayer: 7, lookAhead: 1, idle: slow, loaded: slow),
        ],
        concurrent: nil
    )

    #expect(
        BenchmarkMarkdown.render(report).contains(
            "No tier is inside the 12.00 ms p99 budget on this machine; the app falls back to "
                + "16000:4:0, the cheapest."))
}

@Test
func markdownReportsTheTwoPathVerdict() {
    let tier = BenchmarkTier(
        sampleRate: 32_000,
        exitLayer: 6,
        lookAhead: 1,
        idle: nil,
        loaded: fixtureMeasurement()
    )
    let report = BenchmarkReport(
        schemaVersion: BenchmarkReport.schemaVersion,
        environment: BenchmarkEnvironment(
            machine: "fixture",
            macOS: "fixture",
            powerSource: "fixture",
            date: "2026-01-01T00:00:00Z"
        ),
        tiers: [],
        concurrent: BenchmarkConcurrent(
            loadThreads: 6, tiers: [tier], passes: true, date: "2026-01-02T00:00:00Z")
    )

    let markdown = BenchmarkMarkdown.render(report)

    #expect(markdown.contains("Two-path rule at 12.00 ms p99: pass with 6 busy thread(s)."))
    #expect(markdown.contains("| 32000:6:1 | concurrent |"))
    #expect(markdown.contains("Measured: 2026-01-02T00:00:00Z"))
}

@Test
func markdownKeepsTheReuseRowsAndNotesOfTheFileItReplaces() {
    let previous = """
        # Benchmark report

        ## reuse-rs

        <!-- reuse-rs:start -->
        | Tier | Result |
        | 16000:4:0 | measured |
        <!-- reuse-rs:end -->

        ## Notes

        Kept by hand.
        """
    let report = BenchmarkReport(
        schemaVersion: BenchmarkReport.schemaVersion,
        environment: BenchmarkEnvironment(
            machine: "fixture", macOS: "fixture", powerSource: "fixture",
            date: "2026-01-01T00:00:00Z"),
        tiers: [],
        concurrent: nil
    )

    let markdown = BenchmarkMarkdown.render(report, keeping: previous)

    #expect(markdown.contains("| 16000:4:0 | measured |"))
    #expect(markdown.hasSuffix("## Notes\n\nKept by hand.\n"))
    #expect(markdown.components(separatedBy: "<!-- reuse-rs:start -->").count == 2)
    #expect(!markdown.contains("to fill this section"))
}

private func fixtureMeasurement() -> BenchmarkMeasurement {
    BenchmarkMeasurement(
        medianMs: 1,
        p95Ms: 2,
        p99Ms: 3,
        p999Ms: 4,
        maxMs: 5,
        deadlineMissesPer10000: 0,
        peakRSSBytes: 1_048_576,
        parameterCount: 121_314
    )
}

@Test
func setupStoresAndReusesTheMeasuredTierReport() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let paths = InstalledPaths(home: home)
    let report = BenchmarkReport(
        schemaVersion: BenchmarkReport.schemaVersion,
        environment: BenchmarkEnvironment(
            machine: "fixture", macOS: "fixture", powerSource: "AC", date: "fixture"),
        tiers: [
            BenchmarkTier(
                sampleRate: 48_000, exitLayer: 7, lookAhead: 1,
                idle: fixtureMeasurement(), loaded: fixtureMeasurement())
        ], concurrent: nil)
    var measurements = 0
    func measure() -> BenchmarkReport {
        measurements += 1
        return report
    }
    let expected = Tier(sampleRate: 48_000, exitLayer: 7, lookAhead: 1)
    #expect(try Bench.ensureTierReport(at: paths.tierReport, measure: measure) == expected)
    #expect(try TierRule.autoTier(from: Data(contentsOf: paths.tierReport)) == expected)
    #expect(try Bench.ensureTierReport(at: paths.tierReport, measure: measure) == expected)
    #expect(measurements == 1)
    try FileManager.default.createDirectory(at: paths.model, withIntermediateDirectories: true)
    try Bench.syntheticCheckpoint(exitLayer: 1).write(
        to: paths.model.appendingPathComponent(Download.checkpointName))
    #expect(MicModel.load(paths: paths, tierReport: paths.tierReport).tier?.sampleRate == 48_000)
    try Data("invalid report".utf8).write(to: paths.tierReport)
    #expect(try Bench.ensureTierReport(at: paths.tierReport, measure: measure) == expected)
    #expect(measurements == 2)
}
