import Testing
import UntunnelDSP

@testable import UntunnelAudio

@Test
func monitorTapKeepsPairsAndReportsOverflow() {
    let tap = PipelineTap(sampleRate: 100)
    let before: [Float] = [0.25, 0.5]
    let after: [Float] = [-0.25, -0.5]
    var output = [Float](repeating: 0, count: 4)
    func publish() {
        before.withUnsafeBufferPointer { raw in
            after.withUnsafeBufferPointer { tap.publish(raw, after: $0) }
        }
    }
    publish()
    #expect(output.withUnsafeMutableBufferPointer { tap.read(into: $0) } == 0)
    tap.setEnabled(true)
    for _ in 0..<101 { publish() }
    #expect(tap.droppedFrames == 2)
    for _ in 0..<100 {
        #expect(output.withUnsafeMutableBufferPointer { tap.read(into: $0) } == 4)
        #expect(output == [0.25, -0.25, 0.5, -0.5])
    }
    #expect(output.withUnsafeMutableBufferPointer { tap.read(into: $0) } == 0)
}

@Suite(.serialized)
struct FramePathThreads {
    @Test(.enabled(if: !isDebugBuild))
    func pipelineHopWithMonitorEnabledAllocatesNothing() {
        let latency = LatencyMeter()
        let pipeline = Pipeline(
            inputRate: 48_000, tierRate: 48_000, outputRate: 48_000,
            restorer: TapPassThrough(), latency: latency, measuresProcessingLatency: true)
        pipeline.monitorTap.setEnabled(true)
        let samples = UnsafeMutableBufferPointer<Float>.allocate(capacity: 960)
        let pairs = UnsafeMutableBufferPointer<Float>.allocate(capacity: 1920)
        samples.initialize(repeating: 0.25)
        pairs.initialize(repeating: 0)
        defer { samples.deallocate(); pairs.deallocate() }
        func hop() {
            pipeline.inputRing.write(UnsafeBufferPointer(samples))
            latency.noteInputCompletion(0)
            pipeline.runHop(now: { 0 })
            _ = pipeline.outputRing.read(into: samples)
            _ = pipeline.monitorTap.read(into: pairs)
        }
        for _ in 0..<10 { hop() }
        let allocations = AllocationProbe.allocations {
            for _ in 0..<100 { hop() }
        }
        #expect(allocations == 0)
    }

    @Test(.enabled(if: !isDebugBuild))
    func monitorTapAllocatesNothingIncludingOverflow() {
        let tap = PipelineTap(sampleRate: 48_000)
        tap.setEnabled(true)
        let input = UnsafeMutableBufferPointer<Float>.allocate(capacity: 960)
        let output = UnsafeMutableBufferPointer<Float>.allocate(capacity: 1920)
        input.initialize(repeating: 0.25)
        output.initialize(repeating: 0)
        defer { input.deallocate(); output.deallocate() }
        tap.publish(UnsafeBufferPointer(input), after: UnsafeBufferPointer(input))
        _ = tap.read(into: output)
        let allocations = AllocationProbe.allocations {
            for _ in 0..<500 {
                tap.publish(UnsafeBufferPointer(input), after: UnsafeBufferPointer(input))
                _ = tap.read(into: output)
            }
            for _ in 0..<110 {
                tap.publish(UnsafeBufferPointer(input), after: UnsafeBufferPointer(input))
            }
        }
        #expect(allocations == 0)
        #expect(tap.droppedFrames == 9600)
    }
}

#if DEBUG
    private let isDebugBuild = true
#else
    private let isDebugBuild = false
#endif

private final class TapPassThrough: PipelineRestorer {
    let hopFrames = 960
    func process(
        _ input: UnsafeBufferPointer<Float>, into output: UnsafeMutableBufferPointer<Float>
    ) -> Int {
        for index in input.indices { output[index] = input[index] }
        return input.count
    }
    func reset() {}
}
