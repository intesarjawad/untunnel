import Foundation
import Synchronization
import Testing
import UntunnelKernels

@testable import UntunnelEngine

/// One counter per chunk. A chunk of a job runs on one thread and jobs follow each other, so
/// the counters need no synchronisation unless the pool is wrong, which the counts then show.
private final class Tally: Sendable {
    nonisolated(unsafe) let hits: UnsafeMutablePointer<Int>
    let chunks: Int

    init(chunks: Int) {
        self.chunks = chunks
        hits = .allocate(capacity: chunks)
        hits.initialize(repeating: 0, count: chunks)
    }

    deinit {
        hits.deallocate()
    }

    var counts: [Int] {
        Array(UnsafeBufferPointer(start: hits, count: chunks))
    }
}

/// Allocation counts and time bounds describe the optimised build that ships. An unoptimised
/// build allocates a frame for each step of a `for` loop over a range and runs several times
/// slower, more so under a sanitizer.
#if DEBUG
    let measuresShippingBuild = false
#else
    let measuresShippingBuild = true
#endif

/// Everything that starts pool threads or counts allocations runs in turn: a thread allocates
/// while it starts, which the allocation probe would count against the frame path.
@Suite(.serialized)
struct FramePathThreads {
    @Test(arguments: [0, 1, 3])
    func everyChunkRunsExactlyOncePerJob(workers: Int) {
        let pool = WorkerPool(workers: workers)
        let chunks = 13
        let jobs = 2_000
        let tally = Tally(chunks: chunks)
        for _ in 0..<jobs {
            pool.run(chunks: chunks, context: Unmanaged.passUnretained(tally).toOpaque()) {
                context, index in
                let tally = Unmanaged<Tally>.fromOpaque(context).takeUnretainedValue()
                tally.hits[index] += 1
            }
        }
        #expect(tally.counts == [Int](repeating: jobs, count: chunks))
    }

    @Test
    func aSecondSubmitterRunsItsJobOnItsOwnThread() async {
        let pool = WorkerPool(workers: 2)
        let chunks = 5
        let jobs = 500
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    let tally = Tally(chunks: chunks)
                    for _ in 0..<jobs {
                        pool.run(
                            chunks: chunks, context: Unmanaged.passUnretained(tally).toOpaque()
                        ) {
                            context, index in
                            let tally = Unmanaged<Tally>.fromOpaque(context).takeUnretainedValue()
                            tally.hits[index] += 1
                        }
                    }
                    #expect(tally.counts == [Int](repeating: jobs, count: chunks))
                }
            }
        }
    }

    @Test(.enabled(if: measuresShippingBuild))
    func theProbeCountsAnAllocationOnTheCallingThread() {
        let allocations = AllocationProbe.allocations {
            allocateAndFree()
        }
        #expect(allocations == 1)
    }

    /// Two chunks that each wait for the other to start cannot both run on the submitter, so
    /// one of the two allocations is a worker's.
    @Test(.enabled(if: measuresShippingBuild))
    func theProbeCountsAnAllocationOnAWorker() {
        let pool = WorkerPool(workers: 1)
        let meeting = Meeting()
        func meet(allocating: Bool) {
            meeting.allocates.store(allocating, ordering: .sequentiallyConsistent)
            meeting.arrived.store(0, ordering: .sequentiallyConsistent)
            pool.run(chunks: 2, context: Unmanaged.passUnretained(meeting).toOpaque()) {
                context, _ in
                let meeting = Unmanaged<Meeting>.fromOpaque(context).takeUnretainedValue()
                meeting.arrived.add(1, ordering: .sequentiallyConsistent)
                while meeting.arrived.load(ordering: .sequentiallyConsistent) < 2 {}
                if meeting.allocates.load(ordering: .sequentiallyConsistent) {
                    allocateAndFree()
                }
            }
        }

        // The worker's thread allocates while it starts; the first job waits that out.
        meet(allocating: false)
        let allocations = AllocationProbe.allocations {
            meet(allocating: true)
        }
        #expect(allocations == 2)
    }

    /// The microphone and the incoming path each submit from a time-constraint thread while
    /// threads of the highest ordinary priority keep every core busy. A submitter only waits
    /// for chunks that are running, so no job may outlast the computation a worker declares
    /// for one period, a quarter of a hop.
    @Test(.enabled(if: measuresShippingBuild))
    func noJobOutlastsAWorkersTimeSliceWhileEveryCoreIsBusy() {
        let pool = WorkerPool(workers: 3)
        let stop = Atomic<Bool>(false)
        let slowestNanoseconds = Atomic<UInt64>(0)
        let done = DispatchGroup()

        for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
            done.enter()
            let busy = Thread {
                var value = 1.0
                while !stop.load(ordering: .sequentiallyConsistent) {
                    value = value * 1.000_000_1 + 0.5
                }
                done.leave()
            }
            busy.qualityOfService = .userInteractive
            busy.start()
        }

        let submitters = DispatchGroup()
        for _ in 0..<2 {
            submitters.enter()
            let submitter = Thread {
                RealtimeThread.requestTimeConstraint()
                let work = KernelWork(chunks: 8)
                for _ in 0..<400 {
                    let began = DispatchTime.now().uptimeNanoseconds
                    pool.run(chunks: 8, context: Unmanaged.passUnretained(work).toOpaque()) {
                        context, index in
                        Unmanaged<KernelWork>.fromOpaque(context).takeUnretainedValue()
                            .run(chunk: index)
                    }
                    let taken = DispatchTime.now().uptimeNanoseconds - began
                    slowestNanoseconds.max(taken, ordering: .sequentiallyConsistent)
                    // Long enough for the workers to fall asleep, as they do between hops.
                    usleep(1_000)
                }
                submitters.leave()
            }
            submitter.start()
        }
        submitters.wait()
        stop.store(true, ordering: .sequentiallyConsistent)
        done.wait()

        let sliceNanoseconds = UInt64(Tier.streamingHopMilliseconds) * 1_000_000 / 4
        #expect(slowestNanoseconds.load(ordering: .sequentiallyConsistent) < sliceNanoseconds)
    }

    /// Inside a frame the workers wait awake. With more of them than cores, a waiting thread
    /// that never gave up its core would hold off the ones with work for a scheduling
    /// quantum at a time, so the bound is the same quarter of a hop.
    @Test(.enabled(if: measuresShippingBuild))
    func waitingThreadsBeyondTheCoresDoNotHoldUpAFrame() {
        let pool = WorkerPool(workers: 2 * ProcessInfo.processInfo.activeProcessorCount)
        let slowestNanoseconds = Atomic<UInt64>(0)
        let done = DispatchSemaphore(value: 0)
        let submitter = Thread {
            RealtimeThread.requestTimeConstraint()
            let work = KernelWork(chunks: 8)
            for _ in 0..<10 {
                pool.beginFrame()
                for _ in 0..<200 {
                    let began = DispatchTime.now().uptimeNanoseconds
                    pool.run(chunks: 8, context: Unmanaged.passUnretained(work).toOpaque()) {
                        context, index in
                        Unmanaged<KernelWork>.fromOpaque(context).takeUnretainedValue()
                            .run(chunk: index)
                    }
                    let taken = DispatchTime.now().uptimeNanoseconds - began
                    slowestNanoseconds.max(taken, ordering: .sequentiallyConsistent)
                    // The submitter's own work between two jobs, with the workers waiting.
                    work.run(chunk: 0)
                }
                pool.endFrame()
                usleep(1_000)
            }
            done.signal()
        }
        submitter.start()
        done.wait()

        let sliceNanoseconds = UInt64(Tier.streamingHopMilliseconds) * 1_000_000 / 4
        #expect(slowestNanoseconds.load(ordering: .sequentiallyConsistent) < sliceNanoseconds)
    }
}

/// A chunk of arithmetic the size of a frame stage's, on memory of its own.
private final class KernelWork: Sendable {
    private static let valuesPerChunk = 4_096
    private static let passes = 32
    nonisolated(unsafe) private let values: UnsafeMutablePointer<Float>

    init(chunks: Int) {
        values = .allocate(capacity: chunks * Self.valuesPerChunk)
        values.initialize(repeating: 0.5, count: chunks * Self.valuesPerChunk)
    }

    deinit {
        values.deallocate()
    }

    func run(chunk: Int) {
        for _ in 0..<Self.passes {
            untunnel_silu(values + chunk * Self.valuesPerChunk, Self.valuesPerChunk)
        }
    }
}

/// One allocation the optimiser cannot remove, which it does to a `malloc` it sees freed.
private func allocateAndFree() {
    let zone = malloc_default_zone()
    malloc_zone_free(zone, malloc_zone_malloc(zone, 64))
}

/// What two chunks share to wait for each other.
private final class Meeting: Sendable {
    let arrived = Atomic<Int>(0)
    let allocates = Atomic<Bool>(false)
}
