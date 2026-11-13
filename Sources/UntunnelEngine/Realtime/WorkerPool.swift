import Darwin
import Foundation
import Synchronization

/// A fixed set of threads that share the chunks of one job with the thread that submits it.
///
/// The submitting thread is an audio thread, so nothing here may block it or allocate: a job
/// is two pointers and a count published through one atomic word, chunks are claimed with a
/// compare-and-swap, and sleeping workers are woken with a Mach semaphore, whose signal never
/// waits. The submitter claims chunks like any worker, so a worker that wakes late costs
/// speed and nothing else. When a second thread submits while a job is running, its job runs
/// on that thread alone.
///
/// A frame is many jobs with a matrix product of the submitter's between each two. Between
/// `beginFrame` and `endFrame` the workers stay awake, because waking one takes longer than
/// the product it would sleep through.
///
/// The workers ask for the time-constraint scheduling class that audio threads run in
/// (`RealtimeThread`). With an ordinary priority they lose their cores to any busy
/// application, and the submitter then waits for them.
final class WorkerPool: Sendable {
    /// One chunk of a job: the job's context and the chunk's index.
    typealias Body = @convention(c) (UnsafeMutableRawPointer, Int) -> Void

    /// The pool every restorer shares, one worker per performance core beyond the caller's.
    static let shared = WorkerPool(workers: min(3, performanceCores() - 1))

    private static let indexBits: UInt64 = 16
    private static let indexMask: UInt64 = (1 << indexBits) - 1
    /// How often an idle worker looks for a new job before it sleeps, outside a frame. A
    /// sleeping worker costs a system call to wake, but a worker that keeps looking holds a
    /// core.
    private static let idleChecks = 2_000
    /// How often a thread that is only waiting, a worker for a job or the submitter for its
    /// last chunks, looks before it yields its core. Time-constraint threads are not
    /// preempted for each other until a quantum of several milliseconds runs out, so when
    /// there are more of them than cores a waiting thread that never yielded would keep a
    /// thread with work off a core for that long, once per job.
    private static let checksPerYield = 256

    /// `[generation 32][chunk count 16][next chunk 16]`. A claim only succeeds while the
    /// generation it read is current, which is what makes the job it read alongside valid.
    private let ticket = Atomic<UInt64>(0)
    private let finished = Atomic<Int>(0)
    private let busy = Atomic<Bool>(false)
    private let openFrames = Atomic<Int>(0)
    /// The job's function and context. A claimer may read them while the next job is being
    /// published, and then its claim fails on the generation, so the pair it read is unused.
    private let body = Atomic<UInt>(0)
    private let context = Atomic<UInt>(0)
    private nonisolated(unsafe) let sleeping: UnsafeMutablePointer<Atomic<Bool>>
    private nonisolated(unsafe) let wake: UnsafeMutablePointer<semaphore_t>
    private let workers: Int

    init(workers: Int) {
        let workers = max(workers, 0)
        self.workers = workers
        sleeping = .allocate(capacity: max(workers, 1))
        wake = .allocate(capacity: max(workers, 1))
        for index in 0..<workers {
            (sleeping + index).initialize(to: Atomic(false))
            var semaphore = semaphore_t()
            let result = semaphore_create(mach_task_self_, &semaphore, SYNC_POLICY_FIFO, 0)
            precondition(result == KERN_SUCCESS, "the worker pool could not create a semaphore")
            (wake + index).initialize(to: semaphore)
        }
        for index in 0..<workers {
            let thread = Thread { [self] in
                RealtimeThread.requestTimeConstraint()
                work(index)
            }
            thread.name = "untunnel.engine.worker.\(index)"
            thread.qualityOfService = .userInteractive
            thread.start()
        }
    }

    /// Keeps the workers looking for work until `endFrame`, and wakes those asleep.
    func beginFrame() {
        openFrames.add(1, ordering: .sequentiallyConsistent)
        wakeWorkers(workers)
    }

    /// Lets the workers sleep again once no frame is open.
    func endFrame() {
        openFrames.subtract(1, ordering: .sequentiallyConsistent)
    }

    private func wakeWorkers(_ count: Int) {
        for index in 0..<count
        where (sleeping + index).pointee.exchange(false, ordering: .sequentiallyConsistent) {
            semaphore_signal(wake[index])
        }
    }

    /// Runs `body(context, 0)` to `body(context, chunks - 1)`, each once, and returns when all
    /// have finished. The chunks must not depend on each other or on the thread they run on.
    func run(chunks: Int, context: UnsafeMutableRawPointer, body: Body) {
        precondition(chunks >= 0 && UInt64(chunks) <= Self.indexMask, "too many chunks")
        guard
            chunks > 1, workers > 0,
            busy.compareExchange(expected: false, desired: true, ordering: .sequentiallyConsistent)
                .exchanged
        else {
            for index in 0..<chunks {
                body(context, index)
            }
            return
        }

        self.body.store(unsafeBitCast(body, to: UInt.self), ordering: .sequentiallyConsistent)
        self.context.store(UInt(bitPattern: context), ordering: .sequentiallyConsistent)
        finished.store(0, ordering: .sequentiallyConsistent)
        let generationShift = 2 * Self.indexBits
        let generation = (ticket.load(ordering: .sequentiallyConsistent) >> generationShift) &+ 1
        ticket.store(
            generation << generationShift | UInt64(chunks) << Self.indexBits,
            ordering: .sequentiallyConsistent
        )
        wakeWorkers(min(workers, chunks - 1))

        claimChunks()
        // Every chunk is claimed; the last ones are running on workers.
        var checks = 0
        while finished.load(ordering: .sequentiallyConsistent) < chunks {
            checks += 1
            if checks.isMultiple(of: Self.checksPerYield) {
                Self.yieldCore()
            }
        }
        busy.store(false, ordering: .sequentiallyConsistent)
    }

    /// Lets a thread of the same class that is ready to run have this core. Returns at once
    /// when there is none.
    private static func yieldCore() {
        thread_switch(mach_port_name_t(MACH_PORT_NULL), SWITCH_OPTION_NONE, 0)
    }

    /// Claims and runs chunks of the current job until none is left.
    /// - Returns: Whether this thread ran at least one chunk.
    @discardableResult
    private func claimChunks() -> Bool {
        var ranAny = false
        while true {
            let seen = ticket.load(ordering: .sequentiallyConsistent)
            let index = seen & Self.indexMask
            guard index < (seen >> Self.indexBits) & Self.indexMask else {
                return ranAny
            }
            let body = body.load(ordering: .sequentiallyConsistent)
            let context = context.load(ordering: .sequentiallyConsistent)
            guard
                ticket.compareExchange(
                    expected: seen, desired: seen + 1, ordering: .sequentiallyConsistent
                ).exchanged,
                let context = UnsafeMutableRawPointer(bitPattern: context)
            else {
                continue
            }
            unsafeBitCast(body, to: Body.self)(context, Int(index))
            finished.add(1, ordering: .sequentiallyConsistent)
            ranAny = true
        }
    }

    private func work(_ index: Int) {
        var idle = 0
        while true {
            if claimChunks() {
                idle = 0
                continue
            }
            idle += 1
            guard
                idle >= Self.idleChecks,
                openFrames.load(ordering: .sequentiallyConsistent) == 0
            else {
                if idle.isMultiple(of: Self.checksPerYield) {
                    Self.yieldCore()
                }
                continue
            }
            idle = 0
            (sleeping + index).pointee.store(true, ordering: .sequentiallyConsistent)
            // A job published or a frame opened before the flag went up was not signalled,
            // so look once more.
            if claimChunks() || openFrames.load(ordering: .sequentiallyConsistent) > 0 {
                continue
            }
            semaphore_wait(wake[index])
        }
    }

    private static func performanceCores() -> Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.perflevel0.physicalcpu", &count, &size, nil, 0) == 0 else {
            return 1
        }
        return Int(count)
    }
}
