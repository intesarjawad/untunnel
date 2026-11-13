import Darwin
import Synchronization

/// Counts the heap allocations the frame path makes while a closure runs.
///
/// libmalloc reports every allocation in the process to `malloc_logger` when it is set. The
/// probe counts the reports that come from the thread that armed it and from the worker
/// pool's threads, so allocations by tests running at the same time are left out, and one
/// allocation that is freed again still counts, which a heap-growth measurement misses.
enum AllocationProbe {
    private typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// `MALLOC_LOG_TYPE_ALLOCATE` of libmalloc's `stack_logging.h`; a reallocation carries it too.
    private static let allocateFlag: UInt32 = 2
    private static let workerNamePrefix: StaticString = "untunnel.engine.worker."
    private static let nameCapacity = 64

    private static let counted = Atomic<Int>(0)
    private static let armedThread = Atomic<UInt>(0)

    /// The allocations made by the calling thread and by pool workers during `body`.
    /// Only one caller at a time may use the probe.
    static func allocations(during body: () -> Void) -> Int {
        // Test targets may run together; libmalloc has only one process-wide logger.
        let gate = open("/tmp/untunnel-allocation-probe.lock", O_CREAT | O_RDWR, 0o600)
        precondition(gate >= 0 && flock(gate, LOCK_EX) == 0)
        defer { close(gate) }
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else {
            preconditionFailure("libmalloc exports no malloc_logger")
        }
        let slot = symbol.assumingMemoryBound(to: Logger?.self)
        let previous = slot.pointee
        counted.store(0, ordering: .sequentiallyConsistent)
        armedThread.store(UInt(bitPattern: pthread_self()), ordering: .sequentiallyConsistent)
        slot.pointee = { type, _, _, _, _, _ in
            guard type & AllocationProbe.allocateFlag != 0, AllocationProbe.isWatchedThread() else {
                return
            }
            AllocationProbe.counted.add(1, ordering: .sequentiallyConsistent)
        }
        body()
        slot.pointee = previous
        armedThread.store(0, ordering: .sequentiallyConsistent)
        return counted.load(ordering: .sequentiallyConsistent)
    }

    /// Runs inside the allocator's report, so it must not allocate.
    private static func isWatchedThread() -> Bool {
        let current = pthread_self()
        if UInt(bitPattern: current) == armedThread.load(ordering: .sequentiallyConsistent) {
            return true
        }
        return withUnsafeTemporaryAllocation(of: CChar.self, capacity: nameCapacity) { name in
            guard
                let start = name.baseAddress,
                pthread_getname_np(current, start, nameCapacity) == 0
            else {
                return false
            }
            return memcmp(
                start, workerNamePrefix.utf8Start, workerNamePrefix.utf8CodeUnitCount) == 0
        }
    }
}
