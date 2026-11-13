import Foundation
import UntunnelAudio
import UntunnelDSP

/// A microphone-only session for Monitor when no call is using the virtual microphone.
/// It has no speaker output, so opening Monitor cannot feed the microphone back into itself.
final class MonitorCapture: @unchecked Sendable {
    let pipeline: Pipeline
    let latency: LatencyMeter
    private let capture: InputCapture

    init(
        source: any AudioCaptureSource, model: MicModel, deviceLatencyMs: Double = 0,
        recordingRing: RingBuffer? = nil
    ) throws {
        let rate = source.format.sampleRate
        guard rate > 0, rate % Pipeline.hopsPerSecond == 0 else {
            throw UserFacingError.audioDeviceUnavailable("a \(rate) Hz microphone")
        }
        let stage = model.makeRestorer(fallbackRate: rate)
        let latency = LatencyMeter(
            deviceLatencyMs: deviceLatencyMs + Double(stage.restorer.latencySamples) * 1000
                / Double(stage.rate))
        self.latency = latency
        let pipeline = Pipeline(
            inputRate: rate, tierRate: stage.rate, outputRate: stage.rate,
            restorer: stage.restorer, latency: latency, measuresProcessingLatency: true)
        pipeline.setBypass(model.tier == nil)
        pipeline.monitorTap.setEnabled(true)
        self.pipeline = pipeline
        capture = InputCapture(
            source: source, ring: pipeline.inputRing, latency: latency,
            recordingRing: recordingRing,
            signal: { pipeline.signalHop() })
        pipeline.start()
        do {
            try capture.start()
        } catch {
            pipeline.stop()
            throw error
        }
    }

    func stop() {
        capture.stop()
        pipeline.stop()
    }
}

/// Owned by the main thread; FFT work and recording arrays never reach the pipeline thread.
@MainActor
final class MonitorStream {
    let pipeline: Pipeline
    private let input: SpectrumPublisher
    private let output: SpectrumPublisher
    private var pairs = [Float](repeating: 0, count: 4096)
    private var before = [Float](repeating: 0, count: 2048)
    private var after = [Float](repeating: 0, count: 2048)
    private var frames = 0
    private var recordedBefore: [Float] = []
    private var recordedAfter: [Float] = []
    private var recording = false
    private var droppedAtStart = 0

    init(pipeline: Pipeline, feed: MonitorFeed) {
        self.pipeline = pipeline
        input = SpectrumPublisher(
            analyzer: SpectrumAnalyzer(
                sampleRate: pipeline.tierRate, rowCount: MonitorLayout.rowCount),
            mailbox: feed.input)
        output = SpectrumPublisher(
            analyzer: SpectrumAnalyzer(
                sampleRate: pipeline.tierRate, rowCount: MonitorLayout.rowCount),
            mailbox: feed.output)
        pipeline.monitorTap.setEnabled(true)
    }

    func drain() {
        while true {
            let count =
                pairs.withUnsafeMutableBufferPointer { pipeline.monitorTap.read(into: $0) } / 2
            guard count > 0 else { return }
            for index in 0..<count {
                before[index] = pairs[index * 2]
                after[index] = pairs[index * 2 + 1]
            }
            frames += count
            let time = Double(frames) / Double(pipeline.tierRate)
            _ = before.withUnsafeBufferPointer {
                input.consume(UnsafeBufferPointer(rebasing: $0[..<count]), now: time)
            }
            _ = after.withUnsafeBufferPointer {
                output.consume(UnsafeBufferPointer(rebasing: $0[..<count]), now: time)
            }
            if recording {
                let needed = min(count, pipeline.tierRate * ABTake.seconds - recordedBefore.count)
                recordedBefore.append(contentsOf: before.prefix(needed))
                recordedAfter.append(contentsOf: after.prefix(needed))
            }
        }
    }

    func beginRecording() {
        drain()
        recordedBefore = []
        recordedAfter = []
        droppedAtStart = pipeline.monitorTap.droppedFrames
        recording = true
    }

    var complete: Bool { recordedBefore.count == pipeline.tierRate * ABTake.seconds }

    func finishRecording() throws -> ABTake {
        recording = false
        guard pipeline.monitorTap.droppedFrames == droppedAtStart else {
            throw UserFacingError.audioDeviceUnavailable("Monitor dropped audio; record again")
        }
        guard complete else {
            throw UserFacingError.audioDeviceUnavailable(
                "the path stopped during recording; record again")
        }
        return ABTake(sampleRate: pipeline.tierRate, before: recordedBefore, after: recordedAfter)
    }

    func cancelRecording() { recording = false }
}
