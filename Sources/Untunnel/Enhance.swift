import Foundation
import UntunnelDSP
import UntunnelEngine

/// The model `enhance` runs.
enum EnhanceModel: String, Equatable {
    case offline
    case streaming
}

/// What an `enhance` command line asks for.
struct EnhanceOptions: Equatable {
    var input: String
    var output: String
    var model = EnhanceModel.offline
    var bandwidthRate: Int?
    var tier: Tier?
    var modelDirectory: String?
    var chunkSeconds: Double?
    var overlapSeconds: Double?

    init(arguments: [String]) throws {
        var paths: [String] = []
        var model = EnhanceModel.offline
        var bandwidthRate: Int?
        var tier: Tier?
        var modelDirectory: String?
        var chunkSeconds: Double?
        var overlapSeconds: Double?

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else {
                paths.append(argument)
                index += 1
                continue
            }
            let value = try Self.value(after: index, in: arguments)
            index += 2
            switch argument {
            case "--model":
                guard let chosen = EnhanceModel(rawValue: value) else {
                    throw UserFacingError.usage("--model is offline or streaming, not '\(value)'")
                }
                model = chosen
            case "--bwe":
                guard let rate = Int(value), (1...Enhance.maximumSampleRate).contains(rate) else {
                    throw UserFacingError.usage(
                        "--bwe needs a sample rate from 1 to \(Enhance.maximumSampleRate) Hz, such as 48000"
                    )
                }
                bandwidthRate = rate
            case "--tier":
                do {
                    tier = try BenchOptions.tier(from: value)
                } catch {
                    throw UserFacingError.usage(String(describing: error))
                }
            case "--model-dir":
                modelDirectory = value
            case "--chunk-seconds":
                chunkSeconds = try Self.seconds(value, for: argument)
            case "--overlap-seconds":
                overlapSeconds = try Self.seconds(value, for: argument, allowsZero: true)
            default:
                throw UserFacingError.usage("unknown enhance option '\(argument)'")
            }
        }

        guard paths.count == 2 else {
            throw UserFacingError.usage("enhance needs an input file and an output file")
        }
        if model == .offline, tier != nil {
            throw UserFacingError.usage("--tier applies to --model streaming")
        }
        if model == .streaming, chunkSeconds != nil || overlapSeconds != nil {
            throw UserFacingError.usage(
                "--chunk-seconds and --overlap-seconds apply to --model offline")
        }
        self.input = paths[0]
        self.output = paths[1]
        self.model = model
        self.bandwidthRate = bandwidthRate
        self.tier = tier
        self.modelDirectory = modelDirectory
        self.chunkSeconds = chunkSeconds
        self.overlapSeconds = overlapSeconds
    }

    private static func value(after index: Int, in arguments: [String]) throws -> String {
        guard index + 1 < arguments.count else {
            throw UserFacingError.usage("\(arguments[index]) needs a value")
        }
        return arguments[index + 1]
    }

    private static func seconds(
        _ text: String,
        for option: String,
        allowsZero: Bool = false
    ) throws -> Double {
        guard let value = Double(text), value.isFinite, allowsZero ? value >= 0 : value > 0 else {
            throw UserFacingError.usage(
                "\(option) needs \(allowsZero ? "a number of seconds" : "a positive number of seconds")"
            )
        }
        return value
    }
}

/// The part of the model's `config.json` that `enhance` reads.
///
/// Chunk settings override the README's file-mode recipe; command-line options override both.
struct EnhanceConfig: Decodable, Equatable {
    static let defaultChunkSeconds = 10.0
    static let defaultOverlapSeconds = 1.0
    var exitLayer: Int?
    var chunkSeconds: Double?
    var overlapSeconds: Double?

    private enum CodingKeys: String, CodingKey {
        case exitLayer = "exit_layer"
        case chunkSeconds = "chunk_seconds"
        case overlapSeconds = "overlap_seconds"
    }
}

/// Restores a WAV file with the offline model, or with the streaming model run over the file.
///
/// The signal is resampled to the model's rate first, so `--bwe 48000` hands the model a
/// 48 kHz signal whose upper band is empty and the model fills it. The output is written at that
/// rate with as many samples as the resampled input. The resampler's own filter delay is not
/// removed.
enum Enhance {
    /// Bounds transform and resampler allocations to audio rates up to 96 kHz.
    static let maximumSampleRate = 96_000

    /// What a finished command leaves behind.
    struct Outcome {
        let status: Int32
        let output: CommandOutput
    }

    static func run(arguments: [String]) -> Int32 {
        let outcome = perform(arguments: arguments, paths: .current)
        outcome.output.write()
        if outcome.status == 2 {
            printUsage()
        }
        return outcome.status
    }

    static func printUsage() {
        let message = """
            Usage: untunnel enhance IN.wav OUT.wav [--model offline|streaming] [--bwe RATE]
                   offline:   [--chunk-seconds S] [--overlap-seconds S]
                   streaming: [--tier RATE:EXIT[:LOOKAHEAD]]
                   either:    [--model-dir DIR]

            """
        FileHandle.standardError.write(Data(message.utf8))
    }

    /// Runs the command. `offlineLayers` is the depth the offline checkpoint must have.
    static func perform(
        arguments: [String],
        paths: InstalledPaths,
        offlineLayers: Int = OfflineModel.blockCount
    ) -> Outcome {
        var output = CommandOutput()
        do {
            let options = try EnhanceOptions(arguments: arguments)
            try enhance(options, paths: paths, offlineLayers: offlineLayers, output: &output)
            return Outcome(status: 0, output: output)
        } catch let error as UserFacingError {
            output.error(error)
            if case .usage = error {
                return Outcome(status: 2, output: output)
            }
            return Outcome(status: 1, output: output)
        } catch let error as SafeTensorsError {
            output.error(.modelRejected(error.description))
        } catch let error as WeightMapError {
            output.error(.modelRejected(error.description))
        } catch {
            output.error(.unexpected(String(describing: error)))
        }
        return Outcome(status: 1, output: output)
    }

    /// Whether the transform can frame `rate` hertz at a hop of `hopMilliseconds`.
    ///
    /// A frame is twice the hop, and the platform's real DFT needs its length to be
    /// 1, 3, 5 or 15 times a power of two of at least 16.
    static func supportsRate(_ rate: Int, hopMilliseconds: Int) -> Bool {
        let (hopTimesThousand, overflow) = rate.multipliedReportingOverflow(by: hopMilliseconds)
        guard (1...maximumSampleRate).contains(rate), hopMilliseconds > 0,
            !overflow, hopTimesThousand % 1000 == 0
        else {
            return false
        }
        let window = 2 * (hopTimesThousand / 1000)
        return [1, 3, 5, 15].contains { factor in
            guard window % factor == 0 else {
                return false
            }
            let rest = window / factor
            return rest >= 16 && rest & (rest - 1) == 0
        }
    }

    private static func enhance(
        _ options: EnhanceOptions,
        paths: InstalledPaths,
        offlineLayers: Int,
        output: inout CommandOutput
    ) throws {
        let wav: WAVFile
        do {
            wav = try WAVFile(decoding: Data(contentsOf: URL(fileURLWithPath: options.input)))
        } catch {
            throw UserFacingError.usage("cannot read '\(options.input)': \(error)")
        }

        let directory: URL
        if let custom = options.modelDirectory {
            directory = URL(fileURLWithPath: custom)
        } else if options.model == .offline {
            guard let pin = ModelPins.recorded.offline else {
                throw UserFacingError.modelNotPinned("offline")
            }
            directory = paths.models.appendingPathComponent("\(pin.repo)@\(pin.revision)")
            guard
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(Download.checkpointName).path)
            else {
                throw UserFacingError.offlineModelMissing
            }
        } else {
            directory = paths.model
        }
        let checkpoint = try readCheckpoint(in: directory)
        let config = readConfig(in: directory)

        let hop =
            options.model == .offline
            ? OfflineModel.hopMilliseconds : Tier.streamingHopMilliseconds
        let rate = try processingRate(options, inputRate: wav.sampleRate, hop: hop)
        let signal = resampled(wav.samples, from: wav.sampleRate, to: rate)

        let restored: [Float]
        switch options.model {
        case .offline:
            restored = try restoreOffline(
                signal,
                rate: rate,
                options: options,
                config: config,
                checkpoint: checkpoint,
                layers: offlineLayers
            )
        case .streaming:
            restored = try restoreStreaming(
                signal,
                rate: rate,
                options: options,
                config: config,
                checkpoint: checkpoint
            )
        }

        let outputURL = URL(fileURLWithPath: options.output)
        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try WAVFile(sampleRate: rate, samples: restored).encoded()
                .write(to: outputURL, options: .atomic)
        } catch {
            throw UserFacingError.permissionDenied(
                "writing '\(options.output)': \(error.localizedDescription)")
        }
        output.line(
            "Wrote \(options.output): \(options.model.rawValue) model, \(rate) Hz, "
                + "\(restored.count) samples."
        )
    }

    private static func readCheckpoint(in directory: URL) throws -> SafeTensors {
        let file = directory.appendingPathComponent(Download.checkpointName)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw UserFacingError.modelMissing
        }
        return try SafeTensors(data: Data(contentsOf: file, options: .mappedIfSafe))
    }

    private static func readConfig(in directory: URL) -> EnhanceConfig {
        let file = directory.appendingPathComponent(Download.configName)
        guard
            let data = try? Data(contentsOf: file),
            let config = try? JSONDecoder().decode(EnhanceConfig.self, from: data)
        else {
            return EnhanceConfig()
        }
        return config
    }

    private static func processingRate(
        _ options: EnhanceOptions,
        inputRate: Int,
        hop: Int
    ) throws -> Int {
        if let tier = options.tier, let bandwidth = options.bandwidthRate,
            tier.sampleRate != bandwidth
        {
            throw UserFacingError.usage(
                "--tier runs at \(tier.sampleRate) Hz but --bwe asks for \(bandwidth) Hz"
            )
        }
        let rate = options.tier?.sampleRate ?? options.bandwidthRate ?? inputRate
        if let bandwidth = options.bandwidthRate, bandwidth < inputRate {
            throw UserFacingError.usage(
                "--bwe \(bandwidth) is below the input's \(inputRate) Hz; it only extends upwards"
            )
        }
        guard supportsRate(rate, hopMilliseconds: hop) else {
            let hint = options.bandwidthRate == nil ? "; choose a rate with --bwe" : ""
            throw UserFacingError.usage(
                "\(rate) Hz cannot make a frame with a \(hop) ms hop\(hint)"
            )
        }
        return rate
    }

    private static func resampled(_ samples: [Float], from source: Int, to rate: Int) -> [Float] {
        guard source != rate else {
            return samples
        }
        let count = Int((Double(samples.count) * Double(rate) / Double(source)).rounded())
        return PolyphaseResampler(inputRate: source, outputRate: rate)
            .resample(samples, count: count)
    }

    private static func restoreOffline(
        _ signal: [Float],
        rate: Int,
        options: EnhanceOptions,
        config: EnhanceConfig,
        checkpoint: SafeTensors,
        layers: Int
    ) throws -> [Float] {
        // The README's file-mode recipe is the default when the published config has no plan.
        let chunkSeconds =
            options.chunkSeconds ?? config.chunkSeconds ?? EnhanceConfig.defaultChunkSeconds
        let overlapSeconds =
            options.overlapSeconds ?? config.overlapSeconds ?? EnhanceConfig.defaultOverlapSeconds
        guard
            let chunkSamples = Int(exactly: (chunkSeconds * Double(rate)).rounded()),
            let overlapSamples = Int(exactly: (overlapSeconds * Double(rate)).rounded()),
            overlapSamples <= chunkSamples / 2,
            let plan = ChunkPlan(chunkSamples: chunkSamples, overlapSamples: overlapSamples)
        else {
            throw UserFacingError.usage(
                "the chunk must hold at least one sample and the overlap at most half of it"
            )
        }

        var map = WeightMap(checkpoint)
        let weights = try OfflineRestorerWeights(map: &map, blockCount: layers)
        try map.finish()
        // A signal shorter than one chunk is one chunk, so the buffers need not be larger.
        let fitted =
            signal.count < plan.chunkSamples
            ? ChunkPlan(chunkSamples: max(1, signal.count), overlapSamples: 0) ?? plan : plan
        return OfflineRestorer(weights: weights, sampleRate: rate, plan: fitted).restore(signal)
    }

    private static func restoreStreaming(
        _ signal: [Float],
        rate: Int,
        options: EnhanceOptions,
        config: EnhanceConfig,
        checkpoint: SafeTensors
    ) throws -> [Float] {
        var map = WeightMap(checkpoint)
        let tier =
            options.tier
            ?? Tier(
                sampleRate: rate,
                exitLayer: config.exitLayer ?? max(1, map.blockCount),
                lookAhead: 0
            )
        let weights = try RealtimeRestorerWeights(map: &map, exitLayer: tier.exitLayer)
        try map.finish()

        let restorer = RealtimeRestorer(weights: weights, tier: tier)
        // File inference waits for the same time-constrained workers as the live path.
        RealtimeThread.requestTimeConstraint()
        var restored = restorer.process(signal)
        restored.append(contentsOf: restorer.finish())
        return Array(restored.dropFirst(restorer.latencySamples).prefix(signal.count))
    }
}
