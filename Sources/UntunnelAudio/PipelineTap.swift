import Synchronization
import UntunnelDSP

/// Paired before/after hops handed to one non-realtime consumer. A full ring drops a whole
/// pair, never blocks the audio thread, and reports the gap so recordings cannot hide it.
public final class PipelineTap: @unchecked Sendable {
    public let sampleRate: Int
    private let ring: RingBuffer
    private let pair: UnsafeMutableBufferPointer<Float>
    private let lost = Atomic<Int>(0)
    private let enabled = Atomic<Bool>(false)

    public init(sampleRate: Int) {
        precondition(sampleRate > 0 && sampleRate % Pipeline.hopsPerSecond == 0)
        self.sampleRate = sampleRate
        pair = .allocate(capacity: sampleRate / Pipeline.hopsPerSecond * 2)
        pair.initialize(repeating: 0)
        ring = RingBuffer(capacity: sampleRate * 4)
    }

    deinit { pair.deallocate() }

    public func setEnabled(_ value: Bool) {
        enabled.store(value, ordering: .releasing)
    }

    public var droppedFrames: Int { lost.load(ordering: .acquiring) }

    public func publish(_ before: UnsafeBufferPointer<Float>, after: UnsafeBufferPointer<Float>) {
        guard enabled.load(ordering: .acquiring) else { return }
        precondition(before.count == after.count)
        guard ring.availableToWrite >= before.count * 2 else {
            lost.wrappingAdd(before.count, ordering: .relaxed)
            return
        }
        precondition(before.count * 2 <= pair.count)
        for index in before.indices {
            pair[index * 2] = before[index]
            pair[index * 2 + 1] = after[index]
        }
        ring.write(UnsafeBufferPointer(rebasing: pair[..<(before.count * 2)]))
    }

    /// Interleaved before/after frames. The buffer length must be even.
    public func read(into buffer: UnsafeMutableBufferPointer<Float>) -> Int {
        precondition(buffer.count % 2 == 0)
        let count = min(buffer.count, ring.availableToRead / 2 * 2)
        return ring.read(into: UnsafeMutableBufferPointer(rebasing: buffer[..<count]))
    }
}
