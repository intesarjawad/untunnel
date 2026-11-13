import Foundation
import Testing
import UntunnelDSP

@testable import UntunnelAudio

private final class FakeRenderSink: AudioRenderSink, @unchecked Sendable {
    let format = AudioStreamFormat(sampleRate: 1000, hopFrames: 4)

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
        var output = [Float](repeating: .nan, count: frames)
        let callback = lock.withLock { handler }
        output.withUnsafeMutableBufferPointer { callback?($0, hostTime) }
        return output
    }
}

private func testMeter() -> LatencyMeter {
    LatencyMeter(clock: HostClock(ticksPerSecond: 1_000_000))
}

private func makeOutput(
    ring: RingBuffer,
    meter: LatencyMeter,
    sink: FakeRenderSink = FakeRenderSink()
) -> VirtualMicOutput {
    VirtualMicOutput(sink: sink, ring: ring, hopFrames: 4, latency: meter)
}

@Test
func virtualMicPullsCompletedHopsThroughTheResampler() {
    let ring = RingBuffer(capacity: 64)
    _ = [Float](repeating: 0.25, count: 32).withUnsafeBufferPointer { ring.write($0) }
    let sink = FakeRenderSink()
    let output = makeOutput(ring: ring, meter: testMeter(), sink: sink)

    try? output.start()
    let frames = sink.deliver(frames: 4, hostTime: 0)

    #expect(output.underflowCount == 0)
    #expect(frames.allSatisfy { abs($0 - 0.25) < 1e-6 })
}

@Test
func virtualMicServesCallbackSizesThatDoNotMatchTheHop() {
    let ring = RingBuffer(capacity: 64)
    _ = [Float](repeating: 0.5, count: 32).withUnsafeBufferPointer { ring.write($0) }
    let sink = FakeRenderSink()
    let output = makeOutput(ring: ring, meter: testMeter(), sink: sink)

    try? output.start()
    let frames = sink.deliver(frames: 10, hostTime: 0)

    #expect(output.underflowCount == 0)
    #expect(frames.allSatisfy { abs($0 - 0.5) < 1e-6 })
}

@Test
func virtualMicZeroFillsAndCountsAnUnfillableHop() {
    let ring = RingBuffer(capacity: 64)
    let sink = FakeRenderSink()
    let output = makeOutput(ring: ring, meter: testMeter(), sink: sink)

    try? output.start()
    let frames = sink.deliver(frames: 4, hostTime: 0)

    #expect(output.underflowCount == 1)
    #expect(frames == [0, 0, 0, 0])
}

@Test
func virtualMicZeroFillsThePartOfAHopTheRingCouldNotFill() {
    let ring = RingBuffer(capacity: 64)
    _ = [0.5, 0.5].withUnsafeBufferPointer { ring.write($0) }
    let sink = FakeRenderSink()
    let output = makeOutput(ring: ring, meter: testMeter(), sink: sink)

    try? output.start()
    let frames = sink.deliver(frames: 4, hostTime: 0)

    #expect(output.underflowCount == 1)
    #expect(frames[0] == 0.5)
    #expect(frames[1] == 0)
    #expect(frames[2] == 0)
    #expect(frames[3] == 0)
}

@Test
func virtualMicStampsOneLatencySamplePerCompletedHop() {
    let ring = RingBuffer(capacity: 64)
    _ = [Float](repeating: 0.25, count: 32).withUnsafeBufferPointer { ring.write($0) }
    let meter = testMeter()
    let sink = FakeRenderSink()
    let output = makeOutput(ring: ring, meter: meter, sink: sink)

    try? output.start()
    meter.noteInputCompletion(0)
    _ = sink.deliver(frames: 4, hostTime: 10_000)

    #expect(meter.medianHopLatencyMs == 10)
}
