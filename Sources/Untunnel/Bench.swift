import Darwin
import Foundation
import Synchronization
import UntunnelEngine

/// The default tier set the benchmark measures and the app's tier rule chooses from.
///
/// Each step up in rate also steps up the exit depth, so the cheapest tier stays useful on a
/// slow machine while the highest rate gets the deepest exit the model offers.
enum BenchTiers {
    static let all = [
        Tier(sampleRate: 16_000, exitLayer: 4, lookAhead: 0),
        Tier(sampleRate: 24_000, exitLayer: 5, lookAhead: 1),
        Tier(sampleRate: 32_000, exitLayer: 6, lookAhead: 1),
        Tier(sampleRate: 48_000, exitLayer: 7, lookAhead: 1),
    ]
}

/// A command-line mistake, reported with the usage line instead of a stack trace.
struct BenchUsageError: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

/// A benchmark run that could not produce a measurement.
struct BenchError: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

struct BenchOptions {
    var all = false
    var tiers: [Tier] = []
    var frames = 3000
    var load = 0
    var jsonPath: String?
    var assertP99Ms: Double?
    var params = false
    var concurrent = false

    /// The tiers this run covers, in the order the user named them.
    var selectedTiers: [Tier] {
        let requested = all ? BenchTiers.all + tiers : tiers
        if concurrent && !requested.isEmpty { return requested }
        let unique = requested.reduce(into: [Tier]()) { result, tier in
            if !result.contains(tier) {
                result.append(tier)
            }
        }
        return unique.isEmpty ? BenchTiers.all : unique
    }

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--all":
                all = true
                index += 1
            case "--tier":
                let value = try Self.value(after: &index, in: arguments, for: argument)
                tiers.append(try Self.tier(from: value))
            case "--frames":
                let value = try Self.value(after: &index, in: arguments, for: argument)
                guard let frames = Int(value), frames > 0 else {
                    throw BenchUsageError(message: "--frames needs a positive frame count")
                }
                self.frames = frames
            case "--load":
                let value = try Self.value(after: &index, in: arguments, for: argument)
                guard let load = Int(value), load >= 0 else {
                    throw BenchUsageError(message: "--load needs a non-negative thread count")
                }
                self.load = load
            case "--json":
                jsonPath = try Self.value(after: &index, in: arguments, for: argument)
            case "--assert-p99-ms":
                let value = try Self.value(after: &index, in: arguments, for: argument)
                guard let limit = Double(value), limit > 0 else {
                    throw BenchUsageError(
                        message: "--assert-p99-ms needs a positive millisecond value")
                }
                assertP99Ms = limit
            case "--params":
                params = true
                index += 1
            case "--concurrent":
                concurrent = true
                index += 1
            default:
                throw BenchUsageError(message: "unknown bench option '\(argument)'")
            }
        }
        if concurrent && selectedTiers.count < 2 {
            throw BenchUsageError(message: "--concurrent needs at least two tiers")
        }
    }

    private static func value(
        after index: inout Int,
        in arguments: [String],
        for option: String
    ) throws -> String {
        let next = index + 1
        guard next < arguments.count else {
            throw BenchUsageError(message: "\(option) needs a value")
        }
        index = next + 1
        return arguments[next]
    }

    /// Parses `RATE:EXIT[:LOOKAHEAD]` into a tier the streaming transform can run.
    static func tier(from value: String) throws -> Tier {
        let fields = value.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2 || fields.count == 3 else {
            throw BenchUsageError(message: "a tier reads RATE:EXIT[:LOOKAHEAD], not '\(value)'")
        }
        guard
            let sampleRate = Int(fields[0]),
            let exitLayer = Int(fields[1]),
            let lookAhead = fields.count == 3 ? Int(fields[2]) : 0
        else {
            throw BenchUsageError(message: "a tier reads RATE:EXIT[:LOOKAHEAD], not '\(value)'")
        }
        guard Enhance.supportsRate(sampleRate, hopMilliseconds: Tier.streamingHopMilliseconds)
        else {
            throw BenchUsageError(
                message: "\(sampleRate) Hz cannot make an even 40 ms frame with a 20 ms hop"
            )
        }
        guard exitLayer > 0 else {
            throw BenchUsageError(message: "an exit layer must be at least 1")
        }
        guard (0...RealtimeModel.maximumLookAhead).contains(lookAhead) else {
            throw BenchUsageError(
                message:
                    "a look-ahead must be between 0 and \(RealtimeModel.maximumLookAhead) frames"
            )
        }
        return Tier(sampleRate: sampleRate, exitLayer: exitLayer, lookAhead: lookAhead)
    }
}

/// Measures tiers on a real-time thread and writes the report and its Markdown table.
enum Bench {
    static let warmupFrames = 100
    /// Frames slower than this count as a missed deadline.
    static let deadlineMissMs = 20.0
    /// The report always lands here, relative to the directory the command runs in.
    static let markdownPath = "docs/bench.md"

    static func run(arguments: [String]) -> Int32 {
        let options: BenchOptions
        do {
            options = try BenchOptions(arguments: arguments)
        } catch let error as BenchUsageError {
            report(error.message)
            printUsage()
            return 2
        } catch {
            report(String(describing: error))
            return 2
        }

        if options.params {
            printParameters(options.selectedTiers)
            return 0
        }

        do {
            let report = try measure(options).carryingSequentialPasses(
                from: options.jsonPath.flatMap(previousReport)
            )
            try write(
                markdown(
                    for: report, keeping: try? String(contentsOfFile: markdownPath, encoding: .utf8)
                ),
                to: markdownPath
            )
            if let jsonPath = options.jsonPath {
                try writeJSON(report, to: jsonPath)
            }
            printSummary(report, jsonPath: options.jsonPath)

            let limit = options.assertP99Ms
            let overBudget =
                limit.map { limit in
                    measuredTiers(in: report).compactMap { tier -> (String, Double)? in
                        guard let p99 = tier.decisionP99Ms, p99 > limit else {
                            return nil
                        }
                        return (tier.name, p99)
                    }
                } ?? []
            guard overBudget.isEmpty else {
                for (name, p99) in overBudget {
                    standardError(
                        "tier \(name) has p99 \(formatted(p99)) ms above \(formatted(limit ?? 0)) ms"
                    )
                }
                return 1
            }
            return 0
        } catch {
            standardError("benchmark failed: \(error)")
            return 1
        }
    }

    /// Setup keeps measurements in Application Support without writing repository reports.
    static func ensureTierReport(
        at url: URL,
        measure: () throws -> BenchmarkReport = measureSetupTiers
    ) throws -> Tier {
        if let data = try? Data(contentsOf: url),
            let report = try? JSONDecoder().decode(BenchmarkReport.self, from: data),
            report.schemaVersion == BenchmarkReport.schemaVersion,
            let tier = try? TierRule.autoTier(in: report)
        {
            return tier
        }
        let report = try measure()
        let tier = try TierRule.autoTier(in: report)
        try writeJSON(report, to: url.path)
        return tier
    }

    private static func measureSetupTiers() throws -> BenchmarkReport {
        try measure(BenchOptions(arguments: ["--all", "--frames", "300", "--load", "1"]))
    }

    static func printUsage() {
        standardError(
            """
            Usage: untunnel bench [--all] [--tier RATE:EXIT[:LOOKAHEAD]]... [--frames N] \
            [--load N] [--json PATH] [--assert-p99-ms MS] [--params] [--concurrent]
            """
        )
    }

    /// Prints the structural parameter count without building a checkpoint.
    static func printParameters(_ tiers: [Tier]) {
        for tier in tiers {
            let name = "\(tier.sampleRate):\(tier.exitLayer):\(tier.lookAhead)"
            print("\(name)  \(parameterCount(exitLayer: tier.exitLayer)) parameters")
        }
    }

    /// The number of F32 parameters a stream that exits after `exitLayer` blocks computes
    /// with: the encoder with one first layer, those blocks and that depth's decoder pair.
    static func parameterCount(exitLayer: Int) -> Int {
        let unused = (2...(RealtimeModel.maximumLookAhead + 1)).map {
            "dense_encoder.dense_conv_1_\($0)."
        }
        let pair = ["mask", "phase"].map { "\($0)_decoder_list.\(exitLayer - 1)." }
        let used = ["dense_encoder."] + pair + (0..<exitLayer).map { "TSMamba.\($0)." }
        return RealtimeModelLayout.tensors(blockCount: exitLayer).reduce(0) { total, tensor in
            let counts =
                used.contains(where: tensor.name.hasPrefix)
                && !unused.contains(where: tensor.name.hasPrefix)
            return counts ? total + tensor.shape.reduce(1, *) : total
        }
    }

    // MARK: - Measurement

    private static func measure(_ options: BenchOptions) throws -> BenchmarkReport {
        let environment = BenchmarkEnvironment(
            machine: machineModel(),
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            powerSource: powerSource(),
            date: ISO8601DateFormatter().string(from: Date())
        )
        let prepared = try prepare(options.selectedTiers)

        if options.concurrent {
            let load = LoadGenerator()
            if options.load > 0 {
                load.start(count: options.load)
            }
            defer {
                load.stopAndWait()
            }

            let measured = try measureConcurrently(prepared, frames: options.frames)
            let tiers = measured.map { run in
                BenchmarkTier(
                    sampleRate: run.tier.sampleRate,
                    exitLayer: run.tier.exitLayer,
                    lookAhead: run.tier.lookAhead,
                    idle: nil,
                    loaded: run.measurement
                )
            }
            let passes = tiers.allSatisfy(TierRule.meetsBudget)
            return BenchmarkReport(
                schemaVersion: BenchmarkReport.schemaVersion,
                environment: environment,
                tiers: [],
                concurrent: BenchmarkConcurrent(
                    loadThreads: options.load,
                    tiers: tiers,
                    passes: passes,
                    date: environment.date
                )
            )
        }

        var tiers: [BenchmarkTier] = []
        for preparedTier in prepared {
            let idle = measurement(
                latencies: try runOne(
                    preparedTier.tier,
                    weights: preparedTier.weights,
                    frames: options.frames
                ),
                parameterCount: parameterCount(exitLayer: preparedTier.tier.exitLayer)
            )
            let loaded =
                options.load > 0
                ? measurement(
                    latencies: try runOne(
                        preparedTier.tier,
                        weights: preparedTier.weights,
                        frames: options.frames,
                        loadThreads: options.load
                    ),
                    parameterCount: parameterCount(exitLayer: preparedTier.tier.exitLayer)
                )
                : nil
            tiers.append(
                BenchmarkTier(
                    sampleRate: preparedTier.tier.sampleRate,
                    exitLayer: preparedTier.tier.exitLayer,
                    lookAhead: preparedTier.tier.lookAhead,
                    idle: idle,
                    loaded: loaded
                )
            )
        }
        return BenchmarkReport(
            schemaVersion: BenchmarkReport.schemaVersion,
            environment: environment,
            tiers: tiers,
            concurrent: nil
        )
    }

    private struct PreparedTier {
        let tier: Tier
        let weights: RealtimeRestorerWeights
    }

    private static func prepare(_ tiers: [Tier]) throws -> [PreparedTier] {
        var cache: [Int: RealtimeRestorerWeights] = [:]
        return try tiers.map { tier in
            let weights: RealtimeRestorerWeights
            if let cached = cache[tier.exitLayer] {
                weights = cached
            } else {
                weights = try syntheticWeights(exitLayer: tier.exitLayer)
                cache[tier.exitLayer] = weights
            }
            return PreparedTier(tier: tier, weights: weights)
        }
    }

    private struct ConcurrentRun {
        let tier: Tier
        let measurement: BenchmarkMeasurement
    }

    private static func measureConcurrently(
        _ prepared: [PreparedTier],
        frames: Int
    ) throws -> [ConcurrentRun] {
        let ready = DispatchSemaphore(value: 0)
        let start = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let boxes = prepared.map { _ in LatencyBox() }
        // Every stream's hops fall due together, the case in which they share the least.
        let startDelayNanoseconds: UInt64 = 500_000_000
        let firstHop = DispatchTime.now().uptimeNanoseconds + startDelayNanoseconds

        var threads: [Thread] = []
        for (index, preparedTier) in prepared.enumerated() {
            let box = boxes[index]
            let thread = Thread {
                ready.signal()
                start.wait()
                do {
                    box.latencies = try streamLatencies(
                        preparedTier.tier,
                        weights: preparedTier.weights,
                        frames: frames,
                        firstHop: firstHop
                    )
                } catch {
                    box.failure = String(describing: error)
                }
                done.signal()
            }
            thread.name = "untunnel.bench.\(preparedTier.tier.sampleRate)"
            thread.qualityOfService = .userInteractive
            thread.start()
            threads.append(thread)
        }
        // Every stream waits here, so the two-path result reflects them running together.
        for _ in threads {
            ready.wait()
        }
        for _ in threads {
            start.signal()
        }
        for _ in threads {
            done.wait()
        }

        return try prepared.enumerated().map { index, preparedTier in
            let box = boxes[index]
            if let failure = box.failure {
                throw BenchError(message: failure)
            }
            return ConcurrentRun(
                tier: preparedTier.tier,
                measurement: measurement(
                    latencies: box.latencies,
                    parameterCount: parameterCount(exitLayer: preparedTier.tier.exitLayer)
                )
            )
        }
    }

    private static func runOne(
        _ tier: Tier,
        weights: RealtimeRestorerWeights,
        frames: Int,
        loadThreads: Int = 0
    ) throws -> [Double] {
        let load = LoadGenerator()
        if loadThreads > 0 {
            load.start(count: loadThreads)
        }
        defer {
            load.stopAndWait()
        }

        let box = LatencyBox()
        let ready = DispatchSemaphore(value: 0)
        let start = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            ready.signal()
            start.wait()
            do {
                box.latencies = try streamLatencies(tier, weights: weights, frames: frames)
            } catch {
                box.failure = String(describing: error)
            }
            done.signal()
        }
        thread.name = "untunnel.bench.\(tier.sampleRate)"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        start.signal()
        done.wait()
        if let failure = box.failure {
            throw BenchError(message: failure)
        }
        return box.latencies
    }

    private static func streamLatencies(
        _ tier: Tier,
        weights: RealtimeRestorerWeights,
        frames: Int,
        firstHop: UInt64? = nil
    ) throws -> [Double] {
        let restorer = RealtimeRestorer(weights: weights, tier: tier)
        let input = frameSignal(rate: tier.sampleRate, count: restorer.hopLength)
        // The class the pipeline thread runs a restorer in.
        RealtimeThread.requestTimeConstraint()
        var output = [Float](repeating: 0, count: input.count)
        var latencies: [Double] = []
        latencies.reserveCapacity(frames)

        // Hops arrive one hop apart, so the workers sleep and the caches cool between frames
        // as they do on a live stream. A frame that overruns makes the next one start late.
        let hopNanoseconds = UInt64(Tier.streamingHopMilliseconds) * 1_000_000
        var due = firstHop ?? DispatchTime.now().uptimeNanoseconds
        for frame in 0..<(warmupFrames + frames) {
            let now = DispatchTime.now().uptimeNanoseconds
            if now < due {
                usleep(UInt32((due - now) / 1_000))
            }
            let began = DispatchTime.now().uptimeNanoseconds
            input.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { restorer.process(source, into: $0) }
            }
            let ended = DispatchTime.now().uptimeNanoseconds
            if frame >= warmupFrames {
                latencies.append(Double(ended - began) / 1_000_000)
            }
            due += hopNanoseconds
        }
        return latencies
    }

    /// The nearest-rank percentile of a pass, so a p99 with 3,000 frames is the 30th slowest.
    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else {
            return 0
        }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    static func measurement(
        latencies: [Double],
        parameterCount: Int
    ) -> BenchmarkMeasurement {
        let sorted = latencies.sorted()
        let misses = sorted.count { $0 > deadlineMissMs }
        let perTenThousand =
            sorted.isEmpty
            ? 0
            : Double(misses) * 10_000 / Double(sorted.count)
        return BenchmarkMeasurement(
            medianMs: percentile(sorted, 0.5),
            p95Ms: percentile(sorted, 0.95),
            p99Ms: percentile(sorted, 0.99),
            p999Ms: percentile(sorted, 0.999),
            maxMs: sorted.last ?? 0,
            deadlineMissesPer10000: perTenThousand,
            peakRSSBytes: peakRSSBytes(),
            parameterCount: parameterCount
        )
    }

    private static func frameSignal(rate: Int, count: Int) -> [Float] {
        (0..<count).map { index in
            Float(sin(2 * Double.pi * 440 * Double(index) / Double(rate))) * 0.1
        }
    }

    // MARK: - Synthetic checkpoint

    /// Builds a checkpoint with zero payloads in the real-time model's layout with `exitLayer`
    /// blocks.
    ///
    /// The benchmark needs the real layer graph but not trained values, and zero weights keep
    /// the file small while every multiply still runs over the same buffers.
    static func syntheticCheckpoint(exitLayer: Int) -> Data {
        zeroCheckpoint(RealtimeModelLayout.tensors(blockCount: exitLayer))
    }

    /// The same for the offline model with `blockCount` blocks.
    static func syntheticOfflineCheckpoint(blockCount: Int) -> Data {
        zeroCheckpoint(OfflineModelLayout.tensors(blockCount: blockCount))
    }

    static func syntheticWeights(exitLayer: Int) throws -> RealtimeRestorerWeights {
        var map = WeightMap(try SafeTensors(data: syntheticCheckpoint(exitLayer: exitLayer)))
        let weights = try RealtimeRestorerWeights(map: &map, exitLayer: exitLayer)
        try map.finish()
        return weights
    }

    private static func zeroCheckpoint(_ tensors: [RealtimeModelLayout.Tensor]) -> Data {
        var entries: [String] = []
        var offset = 0
        for tensor in tensors {
            let byteCount = tensor.shape.reduce(1, *) * MemoryLayout<Float>.size
            let end = offset + byteCount
            let shape = tensor.shape.map(String.init).joined(separator: ",")
            entries.append(
                """
                "\(tensor.name)":{"dtype":"F32","shape":[\(shape)],\
                "data_offsets":[\(offset),\(end)]}
                """
            )
            offset = end
        }

        let header = "{" + entries.joined(separator: ",") + "}"
        let headerBytes = Array(header.utf8)
        let prefix = (0..<8).map {
            UInt8(truncatingIfNeeded: UInt64(headerBytes.count) >> (8 * UInt64($0)))
        }
        return Data(prefix + headerBytes + [UInt8](repeating: 0, count: offset))
    }

    // MARK: - Report output

    static func markdown(for report: BenchmarkReport, keeping previous: String? = nil) -> String {
        BenchmarkMarkdown.render(report, keeping: previous)
    }

    private static func previousReport(at path: String) -> BenchmarkReport? {
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }
        return try? JSONDecoder().decode(BenchmarkReport.self, from: data)
    }

    private static func writeJSON(_ report: BenchmarkReport, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(report)
        data.append(contentsOf: [0x0A])
        try write(data, to: path)
    }

    private static func write(_ text: String, to path: String) throws {
        try write(Data(text.utf8), to: path)
    }

    private static func write(_ data: Data, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private static func printSummary(_ report: BenchmarkReport, jsonPath: String?) {
        print("Machine: \(report.environment.machine)")
        print("macOS: \(report.environment.macOS)")
        print("Power source: \(report.environment.powerSource)")
        for tier in measuredTiers(in: report) {
            guard let p99 = tier.decisionP99Ms else {
                continue
            }
            print("Tier \(tier.name) p99 \(formatted(p99)) ms")
        }
        print("Wrote \(markdownPath)")
        if let jsonPath {
            print("Wrote \(jsonPath)")
        }
    }

    private static func measuredTiers(in report: BenchmarkReport) -> [BenchmarkTier] {
        report.concurrent?.tiers ?? report.tiers
    }

    // MARK: - Environment

    private static func machineModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else {
            return "unknown"
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func powerSource() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "batt"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "unknown"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        if text.contains("AC Power") {
            return "AC power"
        }
        if text.contains("Battery Power") {
            return "battery"
        }
        return "unknown"
    }

    private static func peakRSSBytes() -> Int {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            return 0
        }
        return Int(usage.ru_maxrss)
    }

    private static func formatted(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func report(_ message: String) {
        standardError(message)
    }

    private static func standardError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// Collects one stream's latencies; the thread writes before signalling, so the read is ordered.
private final class LatencyBox: @unchecked Sendable {
    var latencies: [Double] = []
    var failure: String?
}

/// Keeps a fixed number of default-QoS threads busy for the length of a measurement.
private final class LoadGenerator: @unchecked Sendable {
    private let stop = Atomic<Bool>(false)
    private let finished = DispatchGroup()
    private var threads: [Thread] = []

    func start(count: Int) {
        for index in 0..<count {
            finished.enter()
            let thread = Thread { [self] in
                var value = Double(index) + 1
                while !stop.load(ordering: .acquiring) {
                    for _ in 0..<10_000 {
                        value = value * 1.000_000_1 + 0.5
                        if value > 1_000_000 {
                            value = 1
                        }
                    }
                }
                finished.leave()
            }
            thread.name = "untunnel.bench.load.\(index)"
            thread.qualityOfService = .default
            thread.start()
            threads.append(thread)
        }
    }

    func stopAndWait() {
        stop.store(true, ordering: .releasing)
        finished.wait()
    }
}

/// Renders the measured report as the Markdown file the command writes.
enum BenchmarkMarkdown {
    private static let startMarker = "<!-- reuse-rs:start -->"
    private static let endMarker = "<!-- reuse-rs:end -->"

    /// Renders the report; `previous` is the file being replaced, whose reuse-rs rows and
    /// the notes written after them survive because this command does not measure them.
    static func render(_ report: BenchmarkReport, keeping previous: String? = nil) -> String {
        var lines = [
            "# Benchmark report",
            "",
            "Machine: \(report.environment.machine)",
            "macOS: \(report.environment.macOS)",
            "Power source: \(report.environment.powerSource)",
            "Date: \(report.environment.date)",
            "",
            "Run the benchmark again on the machine you are deciding for; these numbers are not",
            "portable between machines or power sources.",
            "",
            "## untunnel",
            "",
        ]

        if report.tiers.isEmpty {
            lines.append("No sequential passes in this run.")
            lines.append("")
        } else {
            lines.append(header)
            for tier in report.tiers {
                if let idle = tier.idle {
                    lines.append(row(tier: tier, pass: "idle", measurement: idle))
                }
                if let loaded = tier.loaded {
                    lines.append(row(tier: tier, pass: "loaded", measurement: loaded))
                }
            }
            lines.append("")
            lines.append(verdict(for: report))
            lines.append("")
        }

        if let concurrent = report.concurrent {
            lines.append("## Concurrent")
            lines.append("")
            lines.append(
                "Two-path rule at \(formatted(TierRule.loadedP99BudgetMs)) ms p99: "
                    + (concurrent.passes ? "pass" : "fail")
                    + " with \(concurrent.loadThreads) busy thread(s)."
            )
            if let date = concurrent.date {
                lines.append("")
                lines.append("Measured: \(date)")
            }
            lines.append("")
            lines.append(header)
            for tier in concurrent.tiers {
                if let loaded = tier.loaded {
                    lines.append(row(tier: tier, pass: "concurrent", measurement: loaded))
                }
            }
            lines.append("")
        }

        lines.append("## reuse-rs")
        lines.append("")
        if let kept = keptReuseSection(in: previous) {
            lines.append(kept.block)
            lines.append("")
            if !kept.notes.isEmpty {
                lines.append(kept.notes)
                lines.append("")
            }
        } else {
            lines.append(startMarker)
            lines.append(
                "Run `tools/src/untunnel_tools/measure/bench_reuse_rs.sh` to fill this section."
            )
            lines.append(endMarker)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Which measured tiers run in real time on this machine, and the one the app takes.
    private static func verdict(for report: BenchmarkReport) -> String {
        let budget = "\(formatted(TierRule.loadedP99BudgetMs)) ms p99 budget"
        let qualifying = report.tiers.filter(TierRule.meetsBudget).map(\.name)
        guard let chosen = try? TierRule.autoTier(in: report) else {
            return "No tier could be chosen from this run."
        }
        let name = "\(chosen.sampleRate):\(chosen.exitLayer):\(chosen.lookAhead)"
        guard !qualifying.isEmpty else {
            return "No tier is inside the \(budget) on this machine; the app falls back to "
                + "\(name), the cheapest."
        }
        return "Inside the \(budget) on this machine: \(qualifying.joined(separator: ", ")). "
            + "The app runs \(name)."
    }

    private static func keptReuseSection(in previous: String?) -> (block: String, notes: String)? {
        guard
            let previous,
            let start = previous.range(of: startMarker),
            let end = previous.range(of: endMarker, range: start.upperBound..<previous.endIndex)
        else {
            return nil
        }
        let block = String(previous[start.lowerBound..<end.upperBound])
        let notes = previous[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (block, notes)
    }

    private static let header = """
        | Tier | Pass | Median ms | p95 ms | p99 ms | p99.9 ms | Max ms \
        | Misses / 10,000 | Peak RSS MB | Parameters |
        | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
        """

    private static func row(
        tier: BenchmarkTier,
        pass: String,
        measurement: BenchmarkMeasurement
    ) -> String {
        let columns = [
            tier.name,
            pass,
            formatted(measurement.medianMs),
            formatted(measurement.p95Ms),
            formatted(measurement.p99Ms),
            formatted(measurement.p999Ms),
            formatted(measurement.maxMs),
            formatted(measurement.deadlineMissesPer10000),
            formatted(Double(measurement.peakRSSBytes) / 1_048_576, digits: 0),
            String(measurement.parameterCount),
        ]
        return "| " + columns.joined(separator: " | ") + " |"
    }

    private static func formatted(_ value: Double, digits: Int = 2) -> String {
        String(format: "%.\(digits)f", value)
    }
}
