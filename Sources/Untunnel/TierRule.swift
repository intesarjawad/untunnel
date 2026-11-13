import Foundation
import UntunnelEngine

/// One measured pass over a tier, in the units the benchmark writes.
struct BenchmarkMeasurement: Codable, Sendable, Equatable {
    let medianMs: Double
    let p95Ms: Double
    let p99Ms: Double
    let p999Ms: Double
    let maxMs: Double
    let deadlineMissesPer10000: Double
    let peakRSSBytes: Int
    let parameterCount: Int

    enum CodingKeys: String, CodingKey {
        case medianMs = "median_ms"
        case p95Ms = "p95_ms"
        case p99Ms = "p99_ms"
        case p999Ms = "p999_ms"
        case maxMs = "max_ms"
        case deadlineMissesPer10000 = "deadline_misses_per_10000"
        case peakRSSBytes = "peak_rss_bytes"
        case parameterCount = "parameter_count"
    }
}

/// The tier a result row describes and the passes measured for it.
///
/// `loaded` is absent when the run did not add busy threads, so the rule falls back to the
/// idle pass instead of treating the missing measurement as a failure.
struct BenchmarkTier: Codable, Sendable, Equatable {
    let sampleRate: Int
    let exitLayer: Int
    let lookAhead: Int
    let idle: BenchmarkMeasurement?
    let loaded: BenchmarkMeasurement?

    enum CodingKeys: String, CodingKey {
        case sampleRate = "sample_rate"
        case exitLayer = "exit_layer"
        case lookAhead = "look_ahead"
        case idle
        case loaded
    }

    var tier: Tier {
        Tier(sampleRate: sampleRate, exitLayer: exitLayer, lookAhead: lookAhead)
    }

    var name: String {
        "\(sampleRate):\(exitLayer):\(lookAhead)"
    }

    /// The p99 the selection rule uses: the loaded pass when it exists, otherwise idle.
    var decisionP99Ms: Double? {
        (loaded ?? idle)?.p99Ms
    }
}

/// The tiers measured together, one real-time thread each.
struct BenchmarkConcurrent: Codable, Sendable, Equatable {
    let loadThreads: Int
    let tiers: [BenchmarkTier]
    let passes: Bool
    /// When this run was taken, since it can sit beside sequential passes from another day.
    let date: String?

    enum CodingKeys: String, CodingKey {
        case loadThreads = "load_threads"
        case tiers
        case passes
        case date
    }
}

/// The machine the numbers came from, so a report is never read as hardware-independent.
struct BenchmarkEnvironment: Codable, Sendable, Equatable {
    let machine: String
    let macOS: String
    let powerSource: String
    let date: String

    enum CodingKeys: String, CodingKey {
        case machine
        case macOS = "macos"
        case powerSource = "power_source"
        case date
    }
}

/// One complete `bench --json` document.
struct BenchmarkReport: Codable, Sendable, Equatable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let environment: BenchmarkEnvironment
    let tiers: [BenchmarkTier]
    let concurrent: BenchmarkConcurrent?
    var concurrentHistory: [BenchmarkConcurrent]? = nil

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case environment
        case tiers
        case concurrent
        case concurrentHistory = "concurrent_history"
    }
}

extension BenchmarkReport {
    /// Adds the sequential passes of an earlier report to a concurrent-only run.
    ///
    /// The tier rule reads the sequential passes, so a concurrent run written to the same file
    /// must not erase them. They are carried over only when the earlier run came from the same
    /// machine, system and power source, because numbers do not transfer between those.
    func carryingSequentialPasses(from previous: BenchmarkReport?) -> BenchmarkReport {
        guard
            let previous,
            previous.environment.machine == environment.machine,
            previous.environment.macOS == environment.macOS,
            previous.environment.powerSource == environment.powerSource
        else {
            return self
        }
        guard concurrent != nil else {
            return BenchmarkReport(
                schemaVersion: schemaVersion, environment: environment, tiers: tiers,
                concurrent: previous.concurrent, concurrentHistory: previous.concurrentHistory)
        }
        let history = (previous.concurrentHistory ?? []) + [previous.concurrent].compactMap { $0 }
        var merged = BenchmarkReport(
            schemaVersion: schemaVersion,
            environment: tiers.isEmpty ? previous.environment : environment,
            tiers: tiers.isEmpty ? previous.tiers : tiers,
            concurrent: concurrent
        )
        merged.concurrentHistory = history.filter { old in
            old.loadThreads != concurrent?.loadThreads
                || old.tiers.map(\.tier) != concurrent?.tiers.map(\.tier)
        }
        return merged
    }
}

/// Why a report cannot choose a tier.
enum TierRuleError: Error, Equatable, CustomStringConvertible {
    case noMeasuredTiers
    case noConcurrentTiers

    var description: String {
        switch self {
        case .noMeasuredTiers:
            return "the report holds no measured tier; run the benchmark again"
        case .noConcurrentTiers:
            return "the report holds no concurrent tiers; rerun with --concurrent"
        }
    }
}

/// Chooses the tier the app runs from measured latency.
///
/// A tier qualifies when its loaded p99 is at most `loadedP99BudgetMs`. Among the qualifying
/// tiers the rule takes the highest rate, then the deeper exit, then the larger look-ahead,
/// because each of those buys quality. When nothing qualifies it takes the cheapest tier, so a
/// slow machine still starts with the fastest configuration instead of failing.
enum TierRule {
    /// The p99 a tier must meet under load before the app selects it.
    static let loadedP99BudgetMs = 12.0

    /// Reads a report and applies the rule.
    static func autoTier(from data: Data) throws -> Tier {
        try autoTier(in: JSONDecoder().decode(BenchmarkReport.self, from: data))
    }

    /// Applies the rule to a decoded report.
    static func autoTier(in report: BenchmarkReport) throws -> Tier {
        let measured = report.tiers.filter { $0.decisionP99Ms != nil }
        guard !measured.isEmpty else {
            throw TierRuleError.noMeasuredTiers
        }
        let ranked = measured.sorted(by: isBetter)
        if let qualifying = ranked.first(where: meetsBudget) {
            return qualifying.tier
        }
        guard let cheapest = ranked.last else {
            throw TierRuleError.noMeasuredTiers
        }
        return cheapest.tier
    }

    /// Whether every concurrently measured tier keeps its p99 inside the budget.
    ///
    /// Running the microphone and incoming paths at once is the two-path case: one slow path
    /// makes the whole selection unsuitable even when the other path is fast.
    static func concurrentPasses(in report: BenchmarkReport) throws -> Bool {
        guard let concurrent = report.concurrent, !concurrent.tiers.isEmpty else {
            throw TierRuleError.noConcurrentTiers
        }
        return concurrent.tiers.allSatisfy(meetsBudget)
    }

    /// Concurrent rows are ordered as the CLI's mic selection followed by its candidate.
    /// Only loaded pairs measured with this mic qualify; a missing pass falls back to T16.
    static func incomingTier(in report: BenchmarkReport?, microphone: Tier) -> Tier {
        let runs = (report?.concurrentHistory ?? []) + [report?.concurrent].compactMap { $0 }
        let candidates = runs.filter { run in
            run.loadThreads > 0 && run.tiers.count == 2 && run.tiers[0].tier == microphone
                && run.tiers.allSatisfy { ($0.loaded?.p99Ms ?? .infinity) <= loadedP99BudgetMs }
        }.map { $0.tiers[1] }.filter { $0.lookAhead == 0 }
        return candidates.sorted(by: isBetter).first?.tier ?? BenchTiers.all[0]
    }

    /// Whether a tier's selected p99 fits the loaded budget.
    static func meetsBudget(_ tier: BenchmarkTier) -> Bool {
        (tier.decisionP99Ms ?? .infinity) <= loadedP99BudgetMs
    }

    /// Orders better tiers first.
    private static func isBetter(_ lhs: BenchmarkTier, _ rhs: BenchmarkTier) -> Bool {
        if lhs.sampleRate != rhs.sampleRate {
            return lhs.sampleRate > rhs.sampleRate
        }
        if lhs.exitLayer != rhs.exitLayer {
            return lhs.exitLayer > rhs.exitLayer
        }
        return lhs.lookAhead > rhs.lookAhead
    }
}
