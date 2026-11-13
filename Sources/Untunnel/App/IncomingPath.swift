import Foundation
import Synchronization
import UntunnelAudio
import UntunnelEngine

/// One run of the incoming path: the tapped call audio, the model, the headphone output.
///
/// It is the mirror of `MicPathSession`: the same pipeline, capture and output stages, with the
/// tap's aggregate device as the input and the headphones as the output. Anything that fails to
/// start stops what already runs, so a failed start never leaves a device open.
final class IncomingSession: @unchecked Sendable {
    let pipeline: Pipeline
    private let capture: InputCapture
    private let output: VirtualMicOutput

    init(
        tapUID: String,
        outputUID: String,
        hardware: any MicPathHardware,
        bypass: Bool,
        makeRestorer: (_ outputRate: Int) -> (restorer: any PipelineRestorer, rate: Int)
    ) throws {
        let source = try Self.opened("the tapped call audio") {
            try hardware.captureSource(uid: tapUID)
        }
        let sink = try Self.opened("the headphone output") {
            try hardware.renderSink(uid: outputUID)
        }
        for (rate, name) in [
            (source.format.sampleRate, "the tapped call audio"),
            (sink.format.sampleRate, "the headphone output"),
        ]
        where rate % 100 != 0 {
            throw UserFacingError.audioDeviceUnavailable("\(name) runs at \(rate) Hz")
        }

        let (restorer, tierRate) = makeRestorer(sink.format.sampleRate)
        let latency = LatencyMeter(
            deviceLatencyMs: hardware.deviceLatencyMs(inputUID: tapUID, outputUID: outputUID)
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
        let output = VirtualMicOutput(
            sink: sink,
            ring: pipeline.outputRing,
            hopFrames: pipeline.outputFramesPerHop,
            latency: latency
        )
        self.pipeline = pipeline
        self.capture = capture
        self.output = output

        pipeline.start()
        do {
            try output.start()
        } catch {
            pipeline.stop()
            throw UserFacingError.audioDeviceUnavailable("the headphone output: \(error)")
        }
        do {
            try capture.start()
        } catch {
            output.stop()
            pipeline.stop()
            throw UserFacingError.audioDeviceUnavailable("the tapped call audio: \(error)")
        }
    }

    func stop() {
        capture.stop()
        output.stop()
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

/// Plays the tapped call audio, restored, on the headphones for as long as the tap runs.
///
/// It wraps the tap so `IncomingTap` keeps owning every decision. Creating the tap mutes the call
/// app, so a session that fails to start destroys the tap again before it reports the failure:
/// the app is never left muted with nothing playing in its place. When the model is not loaded
/// the session passes the raw audio through, so the call stays audible.
final class IncomingPlayback: ProcessTapDevice, @unchecked Sendable {
    private struct State {
        var session: IncomingSession?
        var bypass = false
        var tier: Tier?
    }

    private let tap: any ProcessTapDevice
    private let hardware: any MicPathHardware
    private let model: LoadedModel
    private let state = Mutex(State())

    init(tap: any ProcessTapDevice, hardware: any MicPathHardware, model: LoadedModel) {
        self.tap = tap
        self.hardware = hardware
        self.model = model
    }

    deinit {
        stop()
    }

    func start(_ target: TapTarget, outputUID: String) throws -> String {
        let tapUID = try tap.start(target, outputUID: outputUID)
        let current = state.withLock { $0.tier }.flatMap { model.atTier($0) } ?? model.incoming
        do {
            let session = try IncomingSession(
                tapUID: tapUID,
                outputUID: outputUID,
                hardware: hardware,
                bypass: state.withLock { $0.bypass } || current?.tier == nil,
                makeRestorer: { outputRate in
                    (current ?? .unavailable(.modelMissing)).makeRestorer(fallbackRate: outputRate)
                }
            )
            state.withLock { $0.session = session }
        } catch let error as UserFacingError {
            tap.stop()
            throw TapError.playbackFailed(error.message)
        } catch {
            tap.stop()
            throw TapError.playbackFailed(String(describing: error))
        }
        return tapUID
    }

    /// Stops playback first, then destroys the tap, which unmutes the call app.
    func stop() {
        let session = state.withLock { state -> IncomingSession? in
            defer { state.session = nil }
            return state.session
        }
        session?.stop()
        tap.stop()
    }

    /// Applies the bypass choice to the running session and to the next one.
    func setBypass(_ bypass: Bool) {
        state.withLock { state in
            state.bypass = bypass
            state.session?.pipeline.setBypass(bypass)
        }
    }

    var pipeline: Pipeline? { state.withLock { $0.session?.pipeline } }

    var metrics: PipelineMetrics? { state.withLock { $0.session?.pipeline.metrics } }

    func selectTier(_ tier: Tier?) { state.withLock { $0.tier = tier } }
}
