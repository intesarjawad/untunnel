import Foundation
import Testing
import UntunnelDSP

@testable import UntunnelAudio

private final class FakeCaptureSource: AudioCaptureSource, @unchecked Sendable {
    let format = AudioStreamFormat(sampleRate: 500, hopFrames: 4)

    private let lock = NSLock()
    private(set) var handler: (@Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void)?

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

private func testMeter() -> LatencyMeter {
    LatencyMeter(clock: HostClock(ticksPerSecond: 1_000_000))
}

@Test
func inputCaptureWritesEveryDeliveredHopIntoTheRing() {
    let source = FakeCaptureSource()
    let ring = RingBuffer(capacity: 16)
    let capture = InputCapture(source: source, ring: ring, latency: testMeter())

    try? capture.start()
    source.deliver([1, 2, 3, 4], hostTime: 0)
    source.deliver([5, 6, 7, 8], hostTime: 4000)

    var frames = [Float](repeating: 0, count: 8)
    let read = frames.withUnsafeMutableBufferPointer { ring.read(into: $0) }
    #expect(read == 8)
    #expect(frames == [1, 2, 3, 4, 5, 6, 7, 8])
}

@Test
func inputCaptureStampsOncePerHop() {
    let source = FakeCaptureSource()
    let ring = RingBuffer(capacity: 16)
    let meter = testMeter()
    let capture = InputCapture(source: source, ring: ring, latency: meter)

    try? capture.start()
    source.deliver([0, 0, 0, 0], hostTime: 0)
    source.deliver([0, 0, 0, 0], hostTime: 4000)
    meter.noteOutputPull(30_000)
    #expect(meter.medianHopLatencyMs == nil)

    source.deliver([0, 0, 0, 0], hostTime: 8000)
    meter.noteOutputPull(28_000)
    #expect(meter.medianHopLatencyMs == 20)
}

@Test
func inputCaptureDropsFramesBeyondTheRingInsteadOfBlocking() {
    let source = FakeCaptureSource()
    let ring = RingBuffer(capacity: 4)
    let capture = InputCapture(source: source, ring: ring, latency: testMeter())

    try? capture.start()
    source.deliver([1, 2, 3, 4], hostTime: 0)
    source.deliver([5, 6, 7, 8], hostTime: 4000)

    #expect(ring.availableToRead == 4)
}

@Test
func inputRecordingKeepsNativeFramesEvenWhenThePipelineRingIsFull() throws {
    let source = FakeCaptureSource()
    let ring = RingBuffer(capacity: 4)
    let recording = RingBuffer(capacity: 8)
    let capture = InputCapture(
        source: source, ring: ring, latency: testMeter(), recordingRing: recording)
    try capture.start()
    defer { capture.stop() }
    source.deliver([1, 2, 3, 4], hostTime: 0)
    source.deliver([5, 6, 7, 8], hostTime: 4000)
    source.deliver([9, 10, 11, 12], hostTime: 8000)
    var frames = [Float](repeating: 0, count: 8)
    #expect(frames.withUnsafeMutableBufferPointer { recording.read(into: $0) } == 8)
    #expect(frames == [1, 2, 3, 4, 5, 6, 7, 8])
    #expect(ring.availableToRead == 4)
}

#if !DEBUG
    extension FramePathThreads {
        @Test
        func nativeRecordingTapAllocatesNothingInTheCaptureCallback() throws {
            let source = FakeCaptureSource()
            let ring = RingBuffer(capacity: 16)
            let recording = RingBuffer(capacity: 16)
            let capture = InputCapture(
                source: source, ring: ring, latency: testMeter(), recordingRing: recording)
            try capture.start()
            defer { capture.stop() }
            let callback = try #require(source.handler)
            let frames = UnsafeMutableBufferPointer<Float>.allocate(capacity: 4)
            frames.initialize(repeating: 0.25)
            defer { frames.deallocate() }
            callback(UnsafeBufferPointer(frames), 0)
            let allocations = AllocationProbe.allocations {
                for _ in 0..<100 {
                    callback(UnsafeBufferPointer(frames), 0)
                    _ = ring.read(into: frames)
                    _ = recording.read(into: frames)
                }
            }
            #expect(allocations == 0)
        }
    }
#endif
