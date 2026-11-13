import Synchronization

/// A single-producer, single-consumer ring of audio frames.
///
/// The render callback writes while the pipeline thread reads, so each side owns one index and
/// the buffer needs no lock. The atomics publish only each side's own progress, and storage is
/// allocated at init because a render callback must not allocate.
public final class RingBuffer: @unchecked Sendable {
    /// The number of frames the ring holds.
    public let capacity: Int

    private let storage: UnsafeMutableBufferPointer<Float>
    /// Frames written in total. Only the producer advances it.
    private let writeCount: Atomic<Int>
    /// Frames read in total. Only the consumer advances it.
    private let readCount: Atomic<Int>

    /// Creates a ring with room for `capacity` frames.
    public init(capacity: Int) {
        precondition(capacity > 0, "a ring buffer needs room for at least one frame")
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0)
        writeCount = Atomic(0)
        readCount = Atomic(0)
    }

    deinit {
        storage.deallocate()
    }

    /// The frames waiting to be read.
    public var availableToRead: Int {
        writeCount.load(ordering: .acquiring) - readCount.load(ordering: .acquiring)
    }

    /// The frames that can be appended before the ring is full.
    public var availableToWrite: Int {
        capacity - availableToRead
    }

    /// Appends as much of `frames` as fits and returns how many frames were written.
    ///
    /// Frames beyond the free space are dropped rather than blocking the producer, because the
    /// callback cannot wait for the pipeline.
    @discardableResult
    public func write(_ frames: UnsafeBufferPointer<Float>) -> Int {
        let read = readCount.load(ordering: .acquiring)
        let write = writeCount.load(ordering: .relaxed)
        let count = min(frames.count, capacity - (write - read))
        var slot = write % capacity
        for index in 0..<count {
            storage[slot] = frames[index]
            slot += 1
            if slot == capacity {
                slot = 0
            }
        }
        writeCount.store(write + count, ordering: .releasing)
        return count
    }

    /// Copies as many frames as `frames` has room for and returns how many were read.
    @discardableResult
    public func read(into frames: UnsafeMutableBufferPointer<Float>) -> Int {
        let write = writeCount.load(ordering: .acquiring)
        let read = readCount.load(ordering: .relaxed)
        let count = min(frames.count, write - read)
        var slot = read % capacity
        for index in 0..<count {
            frames[index] = storage[slot]
            slot += 1
            if slot == capacity {
                slot = 0
            }
        }
        readCount.store(read + count, ordering: .releasing)
        return count
    }

    /// Removes and returns the oldest frame, or nil when the ring is empty.
    public func pop() -> Float? {
        let write = writeCount.load(ordering: .acquiring)
        let read = readCount.load(ordering: .relaxed)
        guard read < write else {
            return nil
        }
        let frame = storage[read % capacity]
        readCount.store(read + 1, ordering: .releasing)
        return frame
    }
}
