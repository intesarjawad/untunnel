import Darwin
import Foundation
import Testing
import UntunnelDSP

@testable import UntunnelAudio

private final class FixedRestorer: PipelineRestorer {
    let hopFrames: Int
    private let value: Float
    private let invert: Bool
    let latencySamples: Int

    init(hopFrames: Int, value: Float = 0, invert: Bool = false, latencySamples: Int = 0) {
        self.hopFrames = hopFrames
        self.value = value
        self.invert = invert
        self.latencySamples = latencySamples
    }

    func process(
        _ input: UnsafeBufferPointer<Float>,
        into output: UnsafeMutableBufferPointer<Float>
    ) -> Int {
        let count = min(input.count, output.count)
        for index in 0..<count {
            output[index] = invert ? -input[index] : value
        }
        return count
    }

    func reset() {}
}

@Test
func aModelDeadlineMissUsesDelayedRawAndBypassStillUsesDirectRaw() {
    let restorer = FixedRestorer(hopFrames: 10, invert: true, latencySamples: 10)
    let pipeline = makePipeline(restorer: restorer)
    let ticks = UInt64(HostClock.system.ticksPerSecond * 0.021)
    func hop(_ value: Float, late: Bool) -> [Float] {
        write([Float](repeating: value, count: 10), to: pipeline)
        var call = 0
        pipeline.runHop(now: {
            defer { call += 1 }
            return call == 0 || !late ? 0 : ticks
        })
        return readOutput(10, from: pipeline)
    }
    _ = hop(0.25, late: false)
    let substituted = hop(0.75, late: true)
    #expect(abs((substituted.last ?? 0) - 0.25) < 1e-6)
    #expect(pipeline.metrics.deadlineMisses == 1)
    #expect(pipeline.metrics.processedHops == 2)
    #expect(pipeline.metrics.lateFrames == 1)
    let restored = hop(0.5, late: false)
    #expect(abs((restored.last ?? 0) + 0.5) < 1e-6)
    pipeline.setBypass(true)
    let bypassed = hop(0.9, late: true)
    #expect(abs((bypassed.last ?? 0) - 0.9) < 1e-6)
}

private final class FakeCaptureSource: AudioCaptureSource, @unchecked Sendable {
    let format = AudioStreamFormat(sampleRate: 500, hopFrames: 10)

    private let lock = NSLock()
    private var handler: (@Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void)?

    func start(
        _ onHop: @escaping @Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void
    ) throws {
        lock.withLock { handler = onHop }
    }

    func stop() {
        lock.withLock { handler = nil }
    }

    func deliver(_ frames: [Float], hostTime: UInt64) {
        let callback = lock.withLock { handler }
        frames.withUnsafeBufferPointer { callback?($0, hostTime) }
    }
}

private final class FakeRenderSink: AudioRenderSink, @unchecked Sendable {
    let format = AudioStreamFormat(sampleRate: 500, hopFrames: 10)

    private let lock = NSLock()
    private var handler: (@Sendable (UnsafeMutableBufferPointer<Float>, UInt64) -> Void)?

    func start(
        _ render: @escaping @Sendable (UnsafeMutableBufferPointer<Float>, UInt64) -> Void
    ) throws {
        lock.withLock { handler = render }
    }

    func stop() {
        lock.withLock { handler = nil }
    }

    func deliver(frames: Int, hostTime: UInt64) -> [Float] {
        var output = [Float](repeating: 0, count: frames)
        let callback = lock.withLock { handler }
        output.withUnsafeMutableBufferPointer { callback?($0, hostTime) }
        return output
    }
}

private func testMeter(deviceLatencyMs: Double = 0) -> LatencyMeter {
    LatencyMeter(
        deviceLatencyMs: deviceLatencyMs,
        clock: HostClock(ticksPerSecond: 1_000_000)
    )
}

private func makePipeline(
    inputRate: Int = 500,
    tierRate: Int = 500,
    outputRate: Int = 500,
    restorer: any PipelineRestorer = FixedRestorer(hopFrames: 10, invert: true),
    latency: LatencyMeter = testMeter()
) -> Pipeline {
    Pipeline(
        inputRate: inputRate,
        tierRate: tierRate,
        outputRate: outputRate,
        restorer: restorer,
        latency: latency
    )
}

private func write(_ frames: [Float], to pipeline: Pipeline) {
    frames.withUnsafeBufferPointer { _ = pipeline.inputRing.write($0) }
}

private func readOutput(_ count: Int, from pipeline: Pipeline) -> [Float] {
    var frames = [Float](repeating: 0, count: count)
    frames.withUnsafeMutableBufferPointer { _ = pipeline.outputRing.read(into: $0) }
    return frames
}

@Test
func pipelineStartsWaitingAndRunsACompleteHop() {
    let pipeline = makePipeline()
    #expect(pipeline.metrics.status == .waiting)
    #expect(pipeline.metrics.hops == 0)

    write([Float](repeating: 0.5, count: 10), to: pipeline)
    pipeline.runHop()

    let output = readOutput(10, from: pipeline)
    #expect(output.allSatisfy { abs($0 + 0.5) < 1e-6 })
    #expect(pipeline.metrics.status == .running)
    #expect(pipeline.metrics.hops == 1)
    #expect(pipeline.metrics.lateFrames == 0)
}

@Test
func pipelinePadsAnEmptyInputAndCountsTheLateFrame() {
    let pipeline = makePipeline()
    pipeline.runHop()

    #expect(readOutput(10, from: pipeline) == [Float](repeating: 0, count: 10))
    #expect(pipeline.metrics.status == .waiting)
    #expect(pipeline.metrics.lateFrames == 1)
}

@Test
func aSilenceHeartbeatKeepsTheVirtualMicFedAndCountsItsHop() {
    let pipeline = makePipeline()

    pipeline.heartbeat()

    #expect(readOutput(10, from: pipeline) == [Float](repeating: 0, count: 10))
    #expect(pipeline.metrics.status == .waiting)
    #expect(pipeline.metrics.hops == 1)
    #expect(pipeline.metrics.processedHops == 0)

    pipeline.heartbeat()

    #expect(pipeline.metrics.hops == 2)
}

@Test
func aSignalledThreadRunsTheHopWaitingInTheRing() async throws {
    let pipeline = makePipeline()
    write([Float](repeating: 0.5, count: 10), to: pipeline)
    pipeline.signalHop()
    pipeline.start()
    defer { pipeline.stop() }

    // Silence hops also advance `hops` while the test thread is descheduled, so count the hops
    // that processed input: the one signal must produce exactly one.
    for _ in 0..<2000 where pipeline.metrics.processedHops == 0 {
        try await Task.sleep(for: .milliseconds(5))
    }

    #expect(pipeline.metrics.processedHops == 1)
    #expect(readOutput(10, from: pipeline).allSatisfy { abs($0 + 0.5) < 1e-6 })
}

@Test
func pipelineFadesBypassWithoutAStep() {
    // 1 kHz gives the 5 ms fade five frames to move through; a hop is then 20 frames.
    let pipeline = makePipeline(
        inputRate: 1000,
        tierRate: 1000,
        outputRate: 1000,
        restorer: FixedRestorer(hopFrames: 20, invert: true)
    )
    write([Float](repeating: 0.5, count: 20), to: pipeline)
    pipeline.runHop()
    _ = readOutput(20, from: pipeline)

    pipeline.setBypass(true)
    write([Float](repeating: 0.5, count: 20), to: pipeline)
    pipeline.runHop()
    let fading = readOutput(20, from: pipeline)

    #expect(pipeline.metrics.status == .bypassed)
    #expect(abs(fading[0] + 0.5) < 1e-6)
    #expect(abs(fading[19] - 0.5) < 1e-6)
    var largestStep: Float = 0
    for index in 1..<fading.count {
        largestStep = max(largestStep, abs(fading[index] - fading[index - 1]))
    }
    #expect(largestStep < 0.25)
}

@Test
func pipelineCrossfadeKeepsUnitPowerAcrossTheFade() {
    let dryPipeline = makePipeline(restorer: FixedRestorer(hopFrames: 10))
    let wetPipeline = makePipeline(restorer: FixedRestorer(hopFrames: 10, value: 1))
    for pipeline in [dryPipeline, wetPipeline] {
        pipeline.setBypass(true)
        write([Float](repeating: pipeline === dryPipeline ? 1 : 0, count: 10), to: pipeline)
        pipeline.runHop()
    }

    let dry = readOutput(10, from: dryPipeline)
    let wet = readOutput(10, from: wetPipeline)
    for index in 0..<10 {
        #expect(abs(dry[index] * dry[index] + wet[index] * wet[index] - 1) < 1e-5)
    }
    // The first frame still belongs to the restored path and the last to the direct path.
    #expect(abs(dry[0]) < 1e-6)
    #expect(abs(wet[0] - 1) < 1e-6)
    #expect(abs(dry[9] - 1) < 1e-6)
    #expect(abs(wet[9]) < 1e-6)
}

@Test
func pipelinePublishesTheLatencyReadout() {
    let meter = testMeter(deviceLatencyMs: 2)
    let pipeline = makePipeline(latency: meter)
    meter.noteInputCompletion(0)
    meter.noteOutputPull(30_000)

    write([Float](repeating: 0.25, count: 10), to: pipeline)
    pipeline.runHop()

    #expect(pipeline.metrics.addedLatencyMs == 32)
}

@Test
func pipelineResamplesBetweenDifferentRates() {
    let pipeline = makePipeline(
        inputRate: 1000,
        tierRate: 500,
        outputRate: 1000,
        restorer: FixedRestorer(hopFrames: 10, invert: true)
    )
    var largest: Float = 0
    for _ in 0..<200 {
        write([Float](repeating: 0.25, count: 20), to: pipeline)
        pipeline.runHop()
        let output = readOutput(20, from: pipeline)
        #expect(output.allSatisfy { $0.isFinite })
        for value in output {
            largest = max(largest, abs(value))
        }
    }

    #expect(largest > 0.01)
    #expect(pipeline.metrics.hops == 200)
}

@Test
func pipelineFillsTheVirtualMicThroughTheCaptureStage() {
    let meter = testMeter()
    let pipeline = makePipeline(latency: meter)
    let source = FakeCaptureSource()
    let capture = InputCapture(source: source, ring: pipeline.inputRing, latency: meter)
    let sink = FakeRenderSink()
    let output = VirtualMicOutput(
        sink: sink,
        ring: pipeline.outputRing,
        hopFrames: 10,
        latency: meter
    )

    try? capture.start()
    try? output.start()
    source.deliver([Float](repeating: 0.25, count: 10), hostTime: 0)
    write([Float](repeating: 0.25, count: 10), to: pipeline)
    pipeline.runHop()
    pipeline.runHop()
    let frames = sink.deliver(frames: 10, hostTime: 10_000)
    pipeline.runHop()

    #expect(frames.allSatisfy { abs($0 + 0.25) < 1e-5 })
    #expect(output.underflowCount == 0)
    #expect(pipeline.metrics.addedLatencyMs == 10)
}

@MainActor
@Test
func statusMonitorReadsTheCountersIntoASnapshot() {
    let pipeline = makePipeline()
    let output = VirtualMicOutput(
        sink: FakeRenderSink(),
        ring: pipeline.outputRing,
        hopFrames: 10,
        latency: testMeter()
    )
    var snapshots: [PipelineSnapshot] = []
    let monitor = PipelineStatusMonitor(pipeline: pipeline, virtualMic: output) {
        snapshots.append($0)
    }

    monitor.publish()

    #expect(snapshots.count == 1)
    #expect(snapshots[0].metrics.hops == 0)
    #expect(snapshots[0].underflows == 0)
}

@Suite(.serialized)
struct PipelineAllocationTests {
    @Test
    func fullHopsDoNotGrowTheHeapAfterInit() {
        let pipeline = makePipeline(
            inputRate: 48_000,
            tierRate: 16_000,
            outputRate: 48_000,
            restorer: FixedRestorer(hopFrames: 320, invert: true)
        )
        let input = [Float](repeating: 0.1, count: 960)
        var drain = [Float](repeating: 0, count: 960)

        func hop() {
            input.withUnsafeBufferPointer { _ = pipeline.inputRing.write($0) }
            pipeline.runHop()
            drain.withUnsafeMutableBufferPointer { _ = pipeline.outputRing.read(into: $0) }
        }

        // The first hops touch every page of the scratch space, so the measurement below sees
        // only what the hop path itself allocates.
        for _ in 0..<100 {
            hop()
        }

        // Other tests allocate while this suite runs, which can only add to the footprint. A hop
        // that allocated would grow it in every trial, so the smallest growth is the hop's own.
        var grown = Int64.max
        for _ in 0..<5 where grown > 0 {
            let before = Int64(footprint())
            for _ in 0..<1000 {
                hop()
            }
            grown = min(grown, Int64(footprint()) - before)
        }
        #expect(grown <= 0, "the heap grew by \(grown) bytes over 1000 hops")
    }
}

/// The bytes the process holds, which grows by at least a page when a hop allocates.
private func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(result == KERN_SUCCESS, "task_info did not report the footprint")
    return info.phys_footprint
}
