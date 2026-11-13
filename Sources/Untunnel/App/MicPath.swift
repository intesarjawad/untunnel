import Foundation
import Synchronization
import UntunnelAudio
import UntunnelEngine

/// The restore model the live path runs, or the reason it cannot run one.
enum MicModel: Sendable {
    case ready(weights: RealtimeRestorerWeights, tier: Tier)
    case unavailable(UserFacingError)

    /// Loads the active checkpoint at the tier `tierReport` measured, or at the cheapest
    /// benchmark tier when this Mac has no report yet (limited to frequencies below 8 kHz).
    ///
    /// The exit depth never exceeds the blocks the checkpoint holds, so a smaller checkpoint
    /// installed through the swap path still runs.
    static func load(paths: InstalledPaths, tierReport: URL? = nil, preferredTier: Tier? = nil)
        -> MicModel
    {
        let file = paths.model.appendingPathComponent(Download.checkpointName)
        guard FileManager.default.fileExists(atPath: file.path) else {
            return .unavailable(.modelMissing)
        }
        do {
            let checkpoint = try SafeTensors(data: Data(contentsOf: file, options: .alwaysMapped))
            var map = WeightMap(checkpoint)
            let measured = tierReport.flatMap { try? TierRule.autoTier(from: Data(contentsOf: $0)) }
            let preferred = preferredTier ?? measured ?? BenchTiers.all[0]
            let tier = Tier(
                sampleRate: preferred.sampleRate,
                exitLayer: min(preferred.exitLayer, max(1, map.blockCount)),
                lookAhead: preferred.lookAhead
            )
            let weights = try RealtimeRestorerWeights(map: &map, exitLayer: tier.exitLayer)
            return .ready(weights: weights, tier: tier)
        } catch let error as SafeTensorsError {
            return .unavailable(.modelRejected(error.description))
        } catch let error as WeightMapError {
            return .unavailable(.modelRejected(error.description))
        } catch {
            return .unavailable(
                .modelRejected("\(Download.checkpointName) could not be read: \(error)")
            )
        }
    }

    /// The model's tier, or nil when the path has to pass audio through unchanged.
    var tier: Tier? {
        guard case .ready(_, let tier) = self else {
            return nil
        }
        return tier
    }

    var failure: UserFacingError? {
        guard case .unavailable(let error) = self else {
            return nil
        }
        return error
    }

    /// A stage for one stream: the model at its tier, or a pass-through at `fallbackRate`.
    func makeRestorer(fallbackRate: Int) -> (restorer: any PipelineRestorer, rate: Int) {
        switch self {
        case .ready(let weights, let tier):
            return (ModelRestorer(weights: weights, tier: tier), tier.sampleRate)
        case .unavailable:
            let hopFrames = fallbackRate / Pipeline.hopsPerSecond
            return (MonitorPassThroughRestorer(hopFrames: hopFrames), fallbackRate)
        }
    }
}

/// The model as loaded at launch, readable from any thread.
///
/// Loading takes long enough to run off the main thread, and Hear Yourself records on a
/// background task, so both read the result through this lock rather than through app state.
final class LoadedModel: Sendable {
    private let model = Mutex<MicModel?>(nil)
    private let alternatives = Mutex<[Tier: MicModel]>([:])
    private let report = Mutex<BenchmarkReport?>(nil)

    var current: MicModel? {
        get { model.withLock { $0 } }
        set { model.withLock { $0 = newValue } }
    }

    /// Prepares the measured choices off the audio thread, including recovery tiers.
    func load(paths: InstalledPaths, tierReport: URL) -> MicModel {
        let measured = try? JSONDecoder().decode(
            BenchmarkReport.self, from: Data(contentsOf: tierReport))
        report.withLock { $0 = measured }
        let primary = MicModel.load(paths: paths, tierReport: tierReport)
        guard let tier = primary.tier else { return primary }
        let incoming = TierRule.incomingTier(in: measured, microphone: tier)
        let recovery = [tier, incoming].flatMap { preferred in
            BenchTiers.all.filter { $0.sampleRate < preferred.sampleRate }.map { preset in
                Tier(
                    sampleRate: preset.sampleRate,
                    exitLayer: min(preset.exitLayer, preferred.exitLayer),
                    lookAhead: preferred.lookAhead
                )
            }
        }
        let tiers = Set(recovery + [tier, incoming])
        var prepared: [Tier: MicModel] = [tier: primary]
        for candidate in tiers where candidate != tier {
            let loaded: MicModel
            if let shared = prepared.values.first(where: {
                $0.tier?.exitLayer == candidate.exitLayer
            }),
                case .ready(let weights, _) = shared
            {
                loaded = .ready(weights: weights, tier: candidate)
            } else {
                loaded = MicModel.load(paths: paths, preferredTier: candidate)
            }
            if let actual = loaded.tier, prepared[actual] == nil { prepared[actual] = loaded }
        }
        alternatives.withLock { $0 = prepared }
        return primary
    }

    func atTier(_ tier: Tier) -> MicModel? {
        let primary = current
        if primary?.tier == tier { return primary }
        return alternatives.withLock { choices in
            if let exact = choices[tier] { return exact }
            // Swap checkpoints may have fewer blocks than the benchmark's requested depth.
            let available = choices.keys.filter {
                $0.sampleRate == tier.sampleRate && $0.lookAhead == tier.lookAhead
                    && $0.exitLayer <= tier.exitLayer
            }.max { $0.exitLayer < $1.exitLayer }
            return available.flatMap { choices[$0] }
        }
    }

    var recoveryTiers: [Tier] {
        alternatives.withLock { Array($0.keys) }
    }

    var incoming: MicModel? {
        let primary = current
        guard let tier = primary?.tier else { return primary }
        let chosen = report.withLock { TierRule.incomingTier(in: $0, microphone: tier) }
        return atTier(chosen) ?? .unavailable(.modelMissing)
    }
}

/// Runs the restore model inside the pipeline, one twenty-millisecond hop per call.
final class ModelRestorer: PipelineRestorer, @unchecked Sendable {
    let hopFrames: Int
    var latencySamples: Int { restorer.latencySamples }
    private let restorer: RealtimeRestorer
    private let resetRequested = Atomic<Bool>(false)

    init(weights: RealtimeRestorerWeights, tier: Tier) {
        restorer = RealtimeRestorer(weights: weights, tier: tier)
        hopFrames = restorer.hopLength
    }

    func process(
        _ input: UnsafeBufferPointer<Float>,
        into output: UnsafeMutableBufferPointer<Float>
    ) -> Int {
        if resetRequested.exchange(false, ordering: .acquiringAndReleasing) {
            restorer.reset()
        }
        let count = min(input.count, output.count)
        restorer.process(
            UnsafeBufferPointer(rebasing: input[..<count]),
            into: output
        )
        return count
    }

    /// The model's workers run in the time-constraint class and each hop waits for them.
    func prepareCallingThread() {
        RealtimeThread.requestTimeConstraint()
    }

    /// Asks for a clean stream before the next hop.
    ///
    /// The device thread calls this when the headset leaves, while the pipeline thread may be
    /// inside `process`; the flag hands the reset to the pipeline thread so only one thread ever
    /// touches the model's state.
    func reset() {
        resetRequested.store(true, ordering: .releasing)
    }
}

/// The audio devices a session opens, behind a protocol so tests never touch Core Audio.
protocol MicPathHardware: Sendable {
    func captureSource(uid: String) throws -> any AudioCaptureSource
    func renderSink(uid: String) throws -> any AudioRenderSink
    /// The input device's capture latency plus the output device's playback latency.
    func deviceLatencyMs(inputUID: String, outputUID: String) -> Double
}

struct CoreAudioMicPathHardware: MicPathHardware {
    func captureSource(uid: String) throws -> any AudioCaptureSource {
        try HALCaptureSource(uid: uid)
    }

    func renderSink(uid: String) throws -> any AudioRenderSink {
        guard let device = CoreAudioDeviceLookup.deviceID(for: uid) else {
            throw AudioOutputError.unsupportedDevice
        }
        return try HALRenderSink(device: device)
    }

    func deviceLatencyMs(inputUID: String, outputUID: String) -> Double {
        let source = CoreAudioDeviceLatencySource()
        let input = source.latency(deviceUID: inputUID)?.inputSeconds ?? 0
        let output = source.latency(deviceUID: outputUID)?.outputSeconds ?? 0
        return (input + output) * 1_000
    }
}

/// One engaged run of the microphone path: headset capture, the model, the feed device.
///
/// Start order matters: the pipeline thread runs first so its silence hops cover the time the
/// devices take to start, then the feed, then capture. Anything that fails to start stops what
/// already runs, so a failed engage never leaves a device open.
final class MicPathSession {
    let pipeline: Pipeline
    let restorer: any PipelineRestorer
    let virtualMic: VirtualMicOutput
    private let capture: InputCapture
    private let recovery: ReconnectRecovery

    init(
        input: AudioDevice,
        feedUID: String,
        devices: AudioDevices,
        hardware: any MicPathHardware,
        bypass: Bool,
        makeRestorer: (_ feedRate: Int) -> (restorer: any PipelineRestorer, rate: Int),
        onRecovery: @escaping @Sendable (ReconnectRecovery.State) -> Void
    ) throws {
        let source = try Self.opened("the headset input \(input.name)") {
            try hardware.captureSource(uid: input.uid)
        }
        let sink = try Self.opened("the Untunnel Feed device") {
            try hardware.renderSink(uid: feedUID)
        }
        for (rate, name) in [
            (source.format.sampleRate, input.name), (sink.format.sampleRate, "Untunnel Feed"),
        ]
        where rate % 100 != 0 {
            throw UserFacingError.audioDeviceUnavailable("\(name) runs at \(rate) Hz")
        }

        let (restorer, tierRate) = makeRestorer(sink.format.sampleRate)
        let latency = LatencyMeter(
            deviceLatencyMs: hardware.deviceLatencyMs(inputUID: input.uid, outputUID: feedUID)
        )
        let pipeline = Pipeline(
            inputRate: source.format.sampleRate,
            tierRate: tierRate,
            outputRate: sink.format.sampleRate,
            restorer: restorer,
            latency: latency
        )
        pipeline.setBypass(bypass)
        let capture = InputCapture(
            source: source,
            ring: pipeline.inputRing,
            latency: latency,
            signal: { pipeline.signalHop() }
        )
        let virtualMic = VirtualMicOutput(
            sink: sink,
            ring: pipeline.outputRing,
            hopFrames: pipeline.outputFramesPerHop,
            latency: latency
        )
        self.pipeline = pipeline
        self.restorer = restorer
        self.virtualMic = virtualMic
        self.capture = capture
        recovery = ReconnectRecovery(
            devices: devices,
            capture: capture,
            restorer: restorer,
            onState: onRecovery
        )

        pipeline.start()
        do {
            try virtualMic.start()
        } catch {
            pipeline.stop()
            throw UserFacingError.audioDeviceUnavailable("the Untunnel Feed device: \(error)")
        }
        do {
            try capture.start()
        } catch {
            virtualMic.stop()
            pipeline.stop()
            throw UserFacingError.audioDeviceUnavailable(
                "the headset input \(input.name): \(error)")
        }
        recovery.start()
    }

    func stop() {
        recovery.stop()
        capture.stop()
        virtualMic.stop()
        pipeline.stop()
    }

    private static func opened<Device>(
        _ name: String,
        _ open: () throws -> Device
    ) throws -> Device {
        do {
            return try open()
        } catch {
            throw UserFacingError.audioDeviceUnavailable("\(name): \(error)")
        }
    }
}
