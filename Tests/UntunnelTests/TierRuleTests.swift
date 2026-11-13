import Foundation
import Testing
import UntunnelEngine

@testable import Untunnel
@testable import UntunnelAudio

private struct FixtureTier {
    let sampleRate: Int
    let exitLayer: Int
    let lookAhead: Int
    let idleP99: Double?
    let loadedP99: Double?
}

@Test
func tierRulePicksTheHighestRateThatFitsTheBudget() throws {
    let report = try fixtureReport([
        FixtureTier(sampleRate: 16_000, exitLayer: 4, lookAhead: 0, idleP99: 2, loadedP99: 2),
        FixtureTier(sampleRate: 24_000, exitLayer: 5, lookAhead: 1, idleP99: 7, loadedP99: 8),
        FixtureTier(sampleRate: 32_000, exitLayer: 6, lookAhead: 1, idleP99: 12, loadedP99: 14),
        FixtureTier(sampleRate: 48_000, exitLayer: 7, lookAhead: 1, idleP99: 9, loadedP99: 11.5),
    ])

    #expect(
        try TierRule.autoTier(from: report) == Tier(sampleRate: 48_000, exitLayer: 7, lookAhead: 1))
}

@Test
func tierRuleUsesTheLoadedPassWhenBothRunsExist() throws {
    let report = try fixtureReport([
        FixtureTier(sampleRate: 16_000, exitLayer: 4, lookAhead: 0, idleP99: 1, loadedP99: 2),
        FixtureTier(sampleRate: 24_000, exitLayer: 5, lookAhead: 1, idleP99: 4, loadedP99: 8),
        FixtureTier(sampleRate: 32_000, exitLayer: 6, lookAhead: 1, idleP99: 5, loadedP99: 9),
        FixtureTier(sampleRate: 48_000, exitLayer: 7, lookAhead: 1, idleP99: 5, loadedP99: 13),
    ])

    #expect(
        try TierRule.autoTier(from: report) == Tier(sampleRate: 32_000, exitLayer: 6, lookAhead: 1))
}

@Test
func tierRuleFallsBackToTheCheapestTierWhenNothingFits() throws {
    let report = try fixtureReport([
        FixtureTier(sampleRate: 16_000, exitLayer: 4, lookAhead: 0, idleP99: 20, loadedP99: 20),
        FixtureTier(sampleRate: 32_000, exitLayer: 6, lookAhead: 1, idleP99: 30, loadedP99: 40),
    ])

    #expect(
        try TierRule.autoTier(from: report) == Tier(sampleRate: 16_000, exitLayer: 4, lookAhead: 0))
}

@Test
func tierRulePrefersTheDeeperExitAtTheSameRate() throws {
    let report = try fixtureReport([
        FixtureTier(sampleRate: 32_000, exitLayer: 6, lookAhead: 1, idleP99: 9, loadedP99: 11),
        FixtureTier(sampleRate: 32_000, exitLayer: 7, lookAhead: 1, idleP99: 9, loadedP99: 11.5),
    ])

    #expect(
        try TierRule.autoTier(from: report) == Tier(sampleRate: 32_000, exitLayer: 7, lookAhead: 1))
}

@Test
func tierRuleFallsBackToTheIdlePassWithoutABusyRun() throws {
    let report = try fixtureReport([
        FixtureTier(sampleRate: 24_000, exitLayer: 5, lookAhead: 1, idleP99: 8, loadedP99: nil),
        FixtureTier(sampleRate: 48_000, exitLayer: 7, lookAhead: 1, idleP99: 10, loadedP99: nil),
    ])

    #expect(
        try TierRule.autoTier(from: report) == Tier(sampleRate: 48_000, exitLayer: 7, lookAhead: 1))
}

@Test
func tierRuleRejectsAReportWithoutMeasurements() throws {
    let report = try fixtureReport([])

    #expect(throws: TierRuleError.noMeasuredTiers) {
        try TierRule.autoTier(from: report)
    }
}

@Test
func concurrentRuleRequiresEveryPathInsideTheBudget() throws {
    let passing = try fixtureReport(
        [],
        concurrent: [
            FixtureTier(sampleRate: 32_000, exitLayer: 6, lookAhead: 1, idleP99: nil, loadedP99: 9),
            FixtureTier(
                sampleRate: 24_000, exitLayer: 5, lookAhead: 1, idleP99: nil, loadedP99: 11.5),
        ]
    )
    #expect(try TierRule.concurrentPasses(in: decode(passing)))

    let failing = try fixtureReport(
        [],
        concurrent: [
            FixtureTier(sampleRate: 32_000, exitLayer: 6, lookAhead: 1, idleP99: nil, loadedP99: 9),
            FixtureTier(
                sampleRate: 24_000, exitLayer: 5, lookAhead: 1, idleP99: nil, loadedP99: 12.5),
        ]
    )
    #expect(try TierRule.concurrentPasses(in: decode(failing)) == false)
}

@Test
func aConcurrentRunKeepsTheSequentialPassesOfTheSameMachine() throws {
    let earlier = try decode(
        fixtureReport([
            FixtureTier(sampleRate: 24_000, exitLayer: 5, lookAhead: 1, idleP99: 4, loadedP99: 8)
        ]))
    let concurrentOnly = try decode(
        fixtureReport(
            [],
            concurrent: [
                FixtureTier(
                    sampleRate: 24_000, exitLayer: 5, lookAhead: 1, idleP99: nil, loadedP99: 9)
            ]
        ))

    let merged = concurrentOnly.carryingSequentialPasses(from: earlier)

    #expect(merged.tiers == earlier.tiers)
    #expect(merged.concurrent == concurrentOnly.concurrent)
    #expect(
        try TierRule.autoTier(in: merged) == Tier(sampleRate: 24_000, exitLayer: 5, lookAhead: 1))
}

@Test
func aConcurrentRunDropsSequentialPassesFromAnotherMachine() throws {
    let earlier = try decode(
        fixtureReport(
            [FixtureTier(sampleRate: 24_000, exitLayer: 5, lookAhead: 1, idleP99: 4, loadedP99: 8)],
            machine: "other"
        ))
    let concurrentOnly = try decode(
        fixtureReport(
            [],
            concurrent: [
                FixtureTier(
                    sampleRate: 24_000, exitLayer: 5, lookAhead: 1, idleP99: nil, loadedP99: 9)
            ]
        ))

    #expect(concurrentOnly.carryingSequentialPasses(from: earlier) == concurrentOnly)
}

/// Builds the report document with hand-written latencies so the rule is exercised on data.
private func fixtureReport(
    _ tiers: [FixtureTier],
    concurrent: [FixtureTier]? = nil,
    machine: String = "fixture"
) throws -> Data {
    let document: [String: Any] = [
        "schema_version": 1,
        "environment": [
            "machine": machine,
            "macos": "fixture",
            "power_source": "fixture",
            "date": "2026-01-01T00:00:00Z",
        ],
        "tiers": tiers.map(tierJSON),
        "concurrent": concurrent.map { tiers in
            [
                "load_threads": 6,
                "tiers": tiers.map(tierJSON),
                "passes": tiers.allSatisfy { ($0.loadedP99 ?? .infinity) <= 12 },
            ] as [String: Any]
        } ?? NSNull(),
    ]
    return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
}

private func decode(_ data: Data) throws -> BenchmarkReport {
    try JSONDecoder().decode(BenchmarkReport.self, from: data)
}

private func tierJSON(_ tier: FixtureTier) -> [String: Any] {
    var entry: [String: Any] = [
        "sample_rate": tier.sampleRate,
        "exit_layer": tier.exitLayer,
        "look_ahead": tier.lookAhead,
    ]
    if let idle = tier.idleP99 {
        entry["idle"] = measurementJSON(idle)
    }
    if let loaded = tier.loadedP99 {
        entry["loaded"] = measurementJSON(loaded)
    }
    return entry
}

private func measurementJSON(_ p99: Double) -> [String: Any] {
    [
        "median_ms": p99 / 2,
        "p95_ms": p99,
        "p99_ms": p99,
        "p999_ms": p99,
        "max_ms": p99,
        "deadline_misses_per_10000": 0,
        "peak_rss_bytes": 1_048_576,
        "parameter_count": 121_314,
    ]
}

@Test
func incomingTierUsesTheMeasuredSecondPathAndKeepsTheMicTier() throws {
    let mic = FixtureTier(
        sampleRate: 48_000, exitLayer: 7, lookAhead: 1, idleP99: nil, loadedP99: 10)
    let candidate = FixtureTier(
        sampleRate: 24_000, exitLayer: 5, lookAhead: 0, idleP99: nil, loadedP99: 11)
    let report = try decode(fixtureReport([mic], concurrent: [mic, candidate]))
    #expect(TierRule.incomingTier(in: report, microphone: micTier(mic)) == micTier(candidate))
    #expect(try TierRule.autoTier(in: report) == micTier(mic))
    #expect(TierRule.incomingTier(in: report, microphone: micTier(candidate)).sampleRate == 16_000)
}

@Test
func incomingTierRejectsAnOverloadedMicEvenWhenTheCandidatePasses() throws {
    let mic = FixtureTier(
        sampleRate: 48_000, exitLayer: 7, lookAhead: 0, idleP99: nil, loadedP99: 13)
    let candidate = FixtureTier(
        sampleRate: 24_000, exitLayer: 5, lookAhead: 0, idleP99: nil, loadedP99: 10)
    let report = try decode(fixtureReport([mic], concurrent: [mic, candidate]))
    #expect(TierRule.incomingTier(in: report, microphone: micTier(mic)) == BenchTiers.all[0])
}

@Test
func incomingLookAheadRequiresAManualChoiceEvenWhenItsBenchmarkPasses() throws {
    let mic = FixtureTier(
        sampleRate: 48_000, exitLayer: 7, lookAhead: 0, idleP99: nil, loadedP99: 10)
    let candidate = FixtureTier(
        sampleRate: 24_000, exitLayer: 5, lookAhead: 1, idleP99: nil, loadedP99: 10)
    let report = try decode(fixtureReport([mic], concurrent: [mic, candidate]))
    #expect(TierRule.incomingTier(in: report, microphone: micTier(mic)) == BenchTiers.all[0])
}

@Test
func theLoadedIncomingStageUsesItsOwnMeasuredRateAndExit() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let paths = InstalledPaths(home: home)
    try FileManager.default.createDirectory(at: paths.model, withIntermediateDirectories: true)
    try Bench.syntheticCheckpoint(exitLayer: 2).write(
        to: paths.model.appendingPathComponent("model.safetensors"))
    let mic = FixtureTier(
        sampleRate: 32_000, exitLayer: 2, lookAhead: 0, idleP99: nil, loadedP99: 10)
    let candidate = FixtureTier(
        sampleRate: 24_000, exitLayer: 1, lookAhead: 0, idleP99: nil, loadedP99: 11)
    let url = home.appendingPathComponent("bench.json")
    try fixtureReport([mic], concurrent: [mic, candidate]).write(to: url)
    let model = LoadedModel()
    model.current = model.load(paths: paths, tierReport: url)
    let incoming = try #require(model.incoming)
    #expect(incoming.tier == micTier(candidate))
    let stage = incoming.makeRestorer(fallbackRate: 48_000)
    #expect(stage.rate == 24_000)
    #expect(stage.restorer.hopFrames == 480)
    #expect(model.current?.tier == micTier(mic))
}

@Test
func repeatedConcurrentRunsKeepCandidatesAndReplaceTheirOldMeasurements() throws {
    let mic = FixtureTier(
        sampleRate: 48_000, exitLayer: 7, lookAhead: 0, idleP99: nil, loadedP99: 10)
    let low = FixtureTier(
        sampleRate: 24_000, exitLayer: 5, lookAhead: 0, idleP99: nil, loadedP99: 9)
    let high = FixtureTier(
        sampleRate: 32_000, exitLayer: 6, lookAhead: 0, idleP99: nil, loadedP99: 11)
    let previous = try decode(fixtureReport([mic], concurrent: [mic, low]))
    let next = try decode(fixtureReport([], concurrent: [mic, high])).carryingSequentialPasses(
        from: previous)
    #expect(TierRule.incomingTier(in: next, microphone: micTier(mic)) == micTier(high))
    let slow = FixtureTier(
        sampleRate: 32_000, exitLayer: 6, lookAhead: 0, idleP99: nil, loadedP99: 14)
    let latest = try decode(fixtureReport([], concurrent: [mic, slow])).carryingSequentialPasses(
        from: next)
    let roundTrip = try JSONDecoder().decode(
        BenchmarkReport.self, from: JSONEncoder().encode(latest))
    #expect(TierRule.incomingTier(in: roundTrip, microphone: micTier(mic)) == micTier(low))
    let sequential = try decode(fixtureReport([mic])).carryingSequentialPasses(from: roundTrip)
    #expect(TierRule.incomingTier(in: sequential, microphone: micTier(mic)) == micTier(low))
}

private func micTier(_ fixture: FixtureTier) -> Tier {
    Tier(sampleRate: fixture.sampleRate, exitLayer: fixture.exitLayer, lookAhead: fixture.lookAhead)
}

@Test
@MainActor
func theControllerAdaptsEachPathIndependentlyAndResetsBetweenCalls() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let harness = Harness()
    defer {
        harness.controller.stop()
        try? FileManager.default.removeItem(at: home)
    }
    let paths = InstalledPaths(home: home)
    try FileManager.default.createDirectory(at: paths.model, withIntermediateDirectories: true)
    try Bench.syntheticCheckpoint(exitLayer: 2).write(
        to: paths.model.appendingPathComponent("model.safetensors"))
    let mic = FixtureTier(
        sampleRate: 32_000, exitLayer: 2, lookAhead: 0, idleP99: nil, loadedP99: 10)
    let candidate = FixtureTier(
        sampleRate: 24_000, exitLayer: 1, lookAhead: 0, idleP99: nil, loadedP99: 11)
    let url = home.appendingPathComponent("bench.json")
    try fixtureReport([mic], concurrent: [mic, candidate]).write(to: url)
    let loaded = harness.controller.model.load(paths: paths, tierReport: url)
    harness.controller.start(cleanExit: true)
    harness.controller.modelLoaded(loaded)
    harness.processes.set([
        AudioProcessObject(
            objectID: 11, pid: 900, bundleID: "example.call", name: "fixture", isRunningInput: true,
            isRunningOutput: true)
    ])
    harness.controller.setRestoreOther(true)
    harness.controller.apply(.restoring(client: "fixture"))
    #expect(
        try await eventually { harness.state.incoming == .restoring(pid: 900, name: "fixture") })
    let original = try #require(harness.controller.session?.pipeline)
    original.stop()

    harness.controller.adaptTiers(
        microphone: runtimeMetrics(hops: 500, late: 11),
        incomingMetrics: runtimeMetrics(hops: 500, late: 0), at: 10)
    #expect(
        harness.state.micPath == .restoring(Tier(sampleRate: 24_000, exitLayer: 2, lookAhead: 0)))
    #expect(harness.controller.session?.pipeline !== original)
    #expect(harness.tap.starts == 1)
    #expect(harness.state.tierNote == "Reduced quality tier (CPU busy)")
    harness.controller.session?.pipeline.stop()

    harness.controller.adaptTiers(
        microphone: runtimeMetrics(hops: 3000, late: 0),
        incomingMetrics: runtimeMetrics(hops: 3500, late: 0), at: 70)
    #expect(harness.state.micPath == .restoring(micTier(mic)))
    #expect(harness.state.tierNote == nil)
    let restored = try #require(harness.controller.session?.pipeline)
    restored.stop()

    harness.controller.adaptTiers(
        microphone: runtimeMetrics(hops: 500, late: 0),
        incomingMetrics: runtimeMetrics(hops: 4000, late: 11), at: 80)
    #expect(harness.controller.session?.pipeline === restored)
    #expect(harness.tap.starts == 2)
    #expect(harness.state.tierNote != nil)
    harness.controller.adaptTiers(
        microphone: runtimeMetrics(hops: 550, late: 0), incomingMetrics: nil, at: 81)
    #expect(harness.state.tierNote == nil)
    harness.controller.adaptTiers(
        microphone: runtimeMetrics(hops: 3500, late: 0),
        incomingMetrics: runtimeMetrics(hops: 3000, late: 0), at: 140)
    #expect(harness.tap.starts == 3)
    #expect(harness.state.tierNote == nil)

    harness.controller.adaptTiers(
        microphone: runtimeMetrics(hops: 4000, late: 11), incomingMetrics: nil, at: 150)
    #expect(harness.state.tierNote != nil)
    harness.controller.apply(.standby)
    #expect(harness.state.tierNote == nil)
    harness.controller.apply(.restoring(client: "fixture"))
    #expect(harness.state.micPath == .restoring(micTier(mic)))
}

private func runtimeMetrics(hops: UInt64, late: UInt64) -> PipelineMetrics {
    PipelineMetrics(
        status: .running, addedLatencyMs: nil, lateFrames: late, deadlineMisses: late,
        processedHops: hops, hops: hops)
}
