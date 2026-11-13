import Darwin
import Foundation
import Testing
import UntunnelEngine

@testable import Untunnel

private let inputRate = 8_000

private func options(_ arguments: [String]) throws -> EnhanceOptions {
    try EnhanceOptions(arguments: arguments)
}

@Test
func enhanceDefaultsToTheOfflineModelAtTheInputRate() throws {
    let parsed = try options(["in.wav", "out.wav"])

    #expect(parsed.input == "in.wav")
    #expect(parsed.output == "out.wav")
    #expect(parsed.model == .offline)
    #expect(parsed.bandwidthRate == nil)
    #expect(parsed.tier == nil)
}

@Test
func enhanceReadsTheModelAndTheBandwidthRate() throws {
    let offline = try options(["a.wav", "b.wav", "--model", "offline", "--bwe", "48000"])
    #expect(offline.model == .offline)
    #expect(offline.bandwidthRate == 48_000)

    let streaming = try options(["--model", "streaming", "a.wav", "b.wav", "--tier", "24000:5:1"])
    #expect(streaming.model == .streaming)
    #expect(streaming.tier == Tier(sampleRate: 24_000, exitLayer: 5, lookAhead: 1))
}

@Test
func enhanceReadsTheChunkOptions() throws {
    let parsed = try options(
        ["a.wav", "b.wav", "--chunk-seconds", "4.5", "--overlap-seconds", "0", "--model-dir", "m"]
    )

    #expect(parsed.chunkSeconds == 4.5)
    #expect(parsed.overlapSeconds == 0)
    #expect(parsed.modelDirectory == "m")
}

@Test
func enhanceRejectsAMalformedCommandLine() {
    let bad: [[String]] = [
        [],
        ["only.wav"],
        ["a.wav", "b.wav", "c.wav"],
        ["a.wav", "b.wav", "--model", "tiny"],
        ["a.wav", "b.wav", "--model"],
        ["a.wav", "b.wav", "--bwe", "fast"],
        ["a.wav", "b.wav", "--bwe", "0"],
        ["a.wav", "b.wav", "--chunk-seconds", "0"],
        ["a.wav", "b.wav", "--overlap-seconds", "-1"],
        ["a.wav", "b.wav", "--tier", "24000:5:1"],
        ["a.wav", "b.wav", "--model", "streaming", "--tier", "24050:5"],
        ["a.wav", "b.wav", "--model", "streaming", "--chunk-seconds", "2"],
        ["a.wav", "b.wav", "--unknown", "1"],
    ]

    for arguments in bad {
        #expect(throws: UserFacingError.self, "\(arguments)") {
            try EnhanceOptions(arguments: arguments)
        }
    }
}

@Test
func enhanceSupportsTheRatesTheTransformCanFrame() {
    for rate in [8_000, 16_000, 24_000, 32_000, 48_000] {
        // 5 ms hop: frames of 80, 160, 240, 320 and 480 samples.
        #expect(Enhance.supportsRate(rate, hopMilliseconds: 5), "\(rate)")
        #expect(Enhance.supportsRate(rate, hopMilliseconds: 10), "\(rate)")
    }
    // 44.1 kHz and 22.05 kHz give a fractional hop; 11.2 kHz gives a 112-sample frame, which is
    // 7 times a power of two.
    #expect(!Enhance.supportsRate(44_100, hopMilliseconds: 5))
    #expect(!Enhance.supportsRate(22_050, hopMilliseconds: 5))
    #expect(!Enhance.supportsRate(11_200, hopMilliseconds: 5))
    // 100 Hz would make a 1-sample hop, below the transform's smallest frame.
    #expect(!Enhance.supportsRate(100, hopMilliseconds: 10))
    #expect(!Enhance.supportsRate(0, hopMilliseconds: 5))
}

@Test
func offlineEnhanceWritesTheBandwidthRateAndKeepsTheDuration() throws {
    let scene = try EnhanceScene(
        checkpoint: Bench.syntheticOfflineCheckpoint(blockCount: 1),
        config: #"{"chunk_seconds": 0.05, "overlap_seconds": 0.01}"#
    )

    let outcome = scene.run(["--model", "offline", "--bwe", "16000"], layers: 1)

    #expect(outcome.status == 0, "\(outcome.output.errorText)")
    let written = try scene.output()
    #expect(written.sampleRate == 16_000)
    // 800 samples at 8 kHz become 1600 at 16 kHz.
    #expect(written.samples.count == 1_600)
    #expect(outcome.output.text.contains("16000 Hz"))
}

@Test
func offlineEnhanceKeepsTheInputRateWithoutBandwidthExtension() throws {
    let scene = try EnhanceScene(
        checkpoint: Bench.syntheticOfflineCheckpoint(blockCount: 1),
        config: nil
    )

    let outcome = scene.run(
        ["--chunk-seconds", "0.05", "--overlap-seconds", "0.01"],
        layers: 1
    )

    #expect(outcome.status == 0, "\(outcome.output.errorText)")
    let written = try scene.output()
    #expect(written.sampleRate == inputRate)
    #expect(written.samples.count == 800)
}

@Test
func offlineEnhanceChoosesTheOfflineDownloadInsteadOfTheActiveLiveModel() throws {
    let scene = try EnhanceScene(checkpoint: Bench.syntheticCheckpoint(exitLayer: 1), config: nil)
    let paths = InstalledPaths(home: scene.directory)
    let pin = try #require(ModelPins.recorded.offline)
    let offline = paths.models.appendingPathComponent("\(pin.repo)@\(pin.revision)")
    try FileManager.default.createDirectory(at: offline, withIntermediateDirectories: true)
    try Bench.syntheticOfflineCheckpoint(blockCount: 1).write(
        to: offline.appendingPathComponent("model.safetensors"))
    try FileManager.default.createSymbolicLink(
        at: paths.model, withDestinationURL: scene.modelDirectory)
    let outcome = Enhance.perform(
        arguments: [
            scene.inputURL.path, scene.outputURL.path, "--model", "offline", "--chunk-seconds",
            "0.05", "--overlap-seconds", "0.01",
        ], paths: paths, offlineLayers: 1)
    #expect(outcome.status == 0, "\(outcome.output.errorText)")
    #expect(try scene.output().samples.count == 800)
    #expect(paths.model.resolvingSymlinksInPath() == scene.modelDirectory.resolvingSymlinksInPath())
}

@Test
func aMissingOfflineDownloadNamesItsOwnInstallCommand() throws {
    let scene = try EnhanceScene(checkpoint: nil, config: nil)
    let outcome = Enhance.perform(
        arguments: [scene.inputURL.path, scene.outputURL.path, "--model", "offline"],
        paths: InstalledPaths(home: scene.directory))
    #expect(outcome.status == 1)
    #expect(outcome.output.errorText.contains("untunnel download --offline-model"))
    #expect(!FileManager.default.fileExists(atPath: scene.outputURL.path))
}

@Test
func commandLineChunkingOverridesTheConfig() throws {
    let scene = try EnhanceScene(
        checkpoint: Bench.syntheticOfflineCheckpoint(blockCount: 1),
        config: #"{"chunk_seconds": 0.05, "overlap_seconds": 0.04}"#
    )

    // The config's overlap is more than half its chunk; the override is not.
    let rejected = scene.run([], layers: 1)
    #expect(rejected.status == 2)

    let accepted = scene.run(["--overlap-seconds", "0.01"], layers: 1)
    #expect(accepted.status == 0, "\(accepted.output.errorText)")
}

@Test
func offlineEnhanceUsesTheReadmeChunkRecipeWithoutConfigOverrides() throws {
    let scene = try EnhanceScene(
        checkpoint: Bench.syntheticOfflineCheckpoint(blockCount: 1),
        config: "{}"
    )

    let outcome = scene.run([], layers: 1)

    #expect(outcome.status == 0, "\(outcome.output.errorText)")
    #expect(try scene.output().samples.count == 800)
}

@Test
func enhanceRefusesToLowerTheRate() throws {
    let scene = try EnhanceScene(
        checkpoint: Bench.syntheticOfflineCheckpoint(blockCount: 1),
        config: nil
    )

    let outcome = scene.run(["--bwe", "4000"], layers: 1)

    #expect(outcome.status == 2)
    #expect(outcome.output.errorText.contains("below the input's 8000 Hz"))
}

@Test
func enhanceExplainsARateTheTransformCannotFrame() throws {
    let scene = try EnhanceScene(
        checkpoint: Bench.syntheticOfflineCheckpoint(blockCount: 1),
        config: nil,
        sampleRate: 11_200
    )

    let outcome = scene.run([], layers: 1)

    #expect(outcome.status == 2)
    #expect(outcome.output.errorText.contains("11200 Hz"))
    #expect(outcome.output.errorText.contains("--bwe"))
}

@Test
func enhanceRejectsACheckpointOfTheOtherModel() throws {
    // A real-time checkpoint names its entry layers by look-ahead, so the file-mode model
    // misses its first tensor.
    let scene = try EnhanceScene(
        checkpoint: Bench.syntheticCheckpoint(exitLayer: 1),
        config: nil
    )

    let outcome = scene.run(
        ["--chunk-seconds", "0.05", "--overlap-seconds", "0.01"],
        layers: 1
    )

    #expect(outcome.status == 1)
    #expect(outcome.output.errorText.contains("dense_encoder.dense_conv_1.0.weight"))
}

@Test
func enhanceReportsAMissingModel() throws {
    let scene = try EnhanceScene(checkpoint: nil, config: nil)

    let outcome = scene.run([], layers: 1)

    #expect(outcome.status == 1)
    #expect(outcome.output.errorText.contains(UserFacingError.modelMissing.message))
}

@Test
func enhanceReportsAnUnreadableInput() throws {
    let scene = try EnhanceScene(checkpoint: nil, config: nil)
    let outcome = Enhance.perform(
        arguments: [scene.directory.appendingPathComponent("missing.wav").path, "out.wav"],
        paths: InstalledPaths(home: scene.directory)
    )

    #expect(outcome.status == 2)
    #expect(outcome.output.errorText.contains("cannot read"))
}

@Test
func streamingEnhanceKeepsTheLengthAtTheTierRate() throws {
    let scene = try EnhanceScene(
        checkpoint: Bench.syntheticCheckpoint(exitLayer: 2),
        config: #"{"exit_layer": 2}"#,
        sampleRate: 16_000
    )

    let outcome = scene.run(["--model", "streaming"], layers: 1)

    #expect(outcome.status == 0, "\(outcome.output.errorText)")
    let written = try scene.output()
    #expect(written.sampleRate == 16_000)
    #expect(written.samples.count == 800 * 2)
}

/// A model directory and a short input in a temporary home, with the command run against them.
private struct EnhanceScene {
    let directory: URL
    let modelDirectory: URL
    let inputURL: URL
    let outputURL: URL

    init(checkpoint: Data?, config: String?, sampleRate: Int = inputRate) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        modelDirectory = directory.appendingPathComponent("model")
        inputURL = directory.appendingPathComponent("in.wav")
        outputURL = directory.appendingPathComponent("out.wav")
        try FileManager.default.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )
        if let checkpoint {
            try checkpoint.write(
                to: modelDirectory.appendingPathComponent(Download.checkpointName)
            )
        }
        if let config {
            try Data(config.utf8)
                .write(to: modelDirectory.appendingPathComponent(Download.configName))
        }
        // 0.1 s of a tone a tenth of the way to Nyquist.
        let tone = (0..<(sampleRate / 10)).map {
            0.5 * Float(sin(2 * Double.pi * 0.05 * Double($0)))
        }
        try WAVFile(sampleRate: sampleRate, samples: tone).encoded().write(to: inputURL)
    }

    func run(_ extra: [String], layers: Int) -> Enhance.Outcome {
        Enhance.perform(
            arguments: [inputURL.path, outputURL.path, "--model-dir", modelDirectory.path] + extra,
            paths: InstalledPaths(home: directory),
            offlineLayers: layers
        )
    }

    func output() throws -> WAVFile {
        try WAVFile(decoding: Data(contentsOf: outputURL))
    }
}

@Test
func enhanceRejectsRatesBeforeOverflowOrAllocation() {
    for rate in [String(Int.max), "96001", "-1"] {
        #expect(throws: UserFacingError.self) {
            try EnhanceOptions(arguments: ["in.wav", "out.wav", "--bwe", rate])
        }
    }
}

@Test
func enhanceRejectsHugeChunkDurationsFromArgumentsAndConfig() throws {
    let scene = try EnhanceScene(
        checkpoint: Bench.syntheticOfflineCheckpoint(blockCount: 1),
        config: #"{"chunk_seconds": 1e300, "overlap_seconds": 0}"#)
    let configured = scene.run([], layers: 1)
    #expect(configured.status == 2)
    #expect(configured.output.errorText.contains("chunk"))
    for option in ["--chunk-seconds", "--overlap-seconds"] {
        let outcome = scene.run([option, "1e300"], layers: 1)
        #expect(outcome.status == 2)
    }
}

@Test
func streamingFileCallerUsesTheWorkersSchedulingClass() throws {
    let scene = try EnhanceScene(
        checkpoint: Bench.syntheticCheckpoint(exitLayer: 1), config: #"{"exit_layer": 1}"#)
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        defer { done.signal() }
        let outcome = scene.run(["--model", "streaming"], layers: 1)
        #expect(outcome.status == 0)
        var policy = thread_time_constraint_policy_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        var getDefault: boolean_t = 0
        let result = withUnsafeMutablePointer(to: &policy) { policy in
            policy.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_get(
                    pthread_mach_thread_np(pthread_self()),
                    thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, &count, &getDefault)
            }
        }
        #expect(result == KERN_SUCCESS)
        #expect(getDefault == 0)
        #expect(policy.period > 0)
    }
    thread.start()
    done.wait()
}
