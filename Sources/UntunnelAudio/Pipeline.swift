import Darwin
import Dispatch
import Foundation
import Synchronization
import UntunnelDSP

/// One restoration stage the pipeline calls from its own thread.
///
/// The buffer API keeps the hop path free of array allocation; a stage that needs the model's
/// spectral state owns that state rather than the pipeline.
public protocol PipelineRestorer: AnyObject {
    /// Frames the stage consumes and produces per hop.
    var hopFrames: Int { get }
    /// Model delay in samples at the tier rate, for time-aligned late-frame substitution.
    var latencySamples: Int { get }
    /// Processes one hop, returning the frames written.
    func process(
        _ input: UnsafeBufferPointer<Float>,
        into output: UnsafeMutableBufferPointer<Float>
    ) -> Int
    /// Clears the streaming state, which a gap in the input invalidates.
    func reset()
    /// Runs once on the pipeline thread before its first hop, for a stage whose timing depends
    /// on how the thread that calls it is scheduled.
    func prepareCallingThread()
}

extension PipelineRestorer {
    public var latencySamples: Int { 0 }
    public func prepareCallingThread() {}
}

/// The route the microphone path is on at the end of the last hop.
public enum PipelineStatus: UInt32, Sendable {
    case waiting
    case running
    case bypassed
}

/// The values the pipeline publishes from its own thread.
public struct PipelineMetrics: Equatable, Sendable {
    /// Whether the last hop had a full input and where bypass stood.
    public let status: PipelineStatus
    /// Median hop delay plus device latency, once an output pull has matched an input.
    public let addedLatencyMs: Double?
    /// Hops with missing input or a missed model deadline.
    public let lateFrames: UInt64
    /// Model hops that exceeded the 20 ms budget, excluding missing-device heartbeats.
    public let deadlineMisses: UInt64
    /// Model calls, excluding silence heartbeats, for CPU recovery windows.
    public let processedHops: UInt64
    /// Hops the pipeline has run.
    public let hops: UInt64
}

/// The pipeline's counters plus the output stage's underflows.
public struct PipelineSnapshot: Equatable, Sendable {
    /// The counters the pipeline thread published.
    public let metrics: PipelineMetrics
    /// Hops the virtual microphone had to fill with silence.
    public let underflows: UInt64
}

/// The real-time path from the headset input ring to the virtual microphone ring.
///
/// The device rates are the ones the audio layer reported, so the two resampling stages bridge
/// the headset, the tier and the virtual device. Everything the hop path uses is allocated at
/// init; the pipeline thread only reads and writes those buffers and publishes atomics, and the
/// ten-hertz monitor turns those into app state on the main thread.
public final class Pipeline: @unchecked Sendable {
    /// The time one hop spans, the unit the model and the drift controller share. It is the
    /// hop the real-time model was trained with.
    public static let hopMilliseconds = 20
    /// Hops per second; a rate must be a multiple of it to make a hop of whole frames.
    public static let hopsPerSecond = 1000 / hopMilliseconds
    /// The crossfade between bypassed and restored audio.
    public static let crossfadeMilliseconds: Double = 5
    /// How long the thread waits for input before it writes a silence hop instead.
    ///
    /// Two hops, so the jitter of a device that is still delivering never looks like a stop.
    public static let heartbeatMilliseconds = 2 * hopMilliseconds

    /// The headset input rate.
    public let inputRate: Int
    /// The restoration rate.
    public let tierRate: Int
    /// The virtual microphone rate.
    public let outputRate: Int
    /// Device frames one hop consumes.
    public let inputFramesPerHop: Int
    /// Tier frames one hop carries.
    public let tierFramesPerHop: Int
    /// Virtual device frames one hop carries.
    public let outputFramesPerHop: Int
    /// The capture callback's destination.
    public let inputRing: RingBuffer
    /// The virtual microphone callback's source.
    public let outputRing: RingBuffer
    /// Before/after tier samples for one non-realtime consumer.
    public let monitorTap: PipelineTap

    private let restorer: any PipelineRestorer
    private let latency: LatencyMeter
    private let measuresProcessingLatency: Bool
    private let inputResampler: PolyphaseResampler?
    private let outputResampler: PolyphaseResampler?
    private let tierPending: UnsafeMutableBufferPointer<Float>?
    private var tierPendingCount = 0
    private let outputPending: UnsafeMutableBufferPointer<Float>?
    private var outputPendingCount = 0
    private let tierInput: UnsafeMutableBufferPointer<Float>
    private let tierWet: UnsafeMutableBufferPointer<Float>
    private let tierMixed: UnsafeMutableBufferPointer<Float>
    private let alignedRaw: UnsafeMutableBufferPointer<Float>
    private let rawDelay: UnsafeMutableBufferPointer<Float>
    private var rawDelayIndex = 0
    private var lateFadeLevel = 0
    private let outputHop: UnsafeMutableBufferPointer<Float>
    private let fadeWet: UnsafeMutableBufferPointer<Float>
    private let fadeDry: UnsafeMutableBufferPointer<Float>
    private let crossfadeFrames: Int
    private var fadeLevel: Int

    private let bypass = Atomic<Bool>(false)
    private let status = Atomic<UInt32>(PipelineStatus.waiting.rawValue)
    private let publishedLatency = Atomic<Int64>(-1)
    private let lateFrames = Atomic<UInt64>(0)
    private let deadlineMisses = Atomic<UInt64>(0)
    private let processedHops = Atomic<UInt64>(0)
    private let hopCount = Atomic<UInt64>(0)
    private let running = Atomic<Bool>(false)
    private let hopSignal = DispatchSemaphore(value: 0)
    private var thread: Thread?

    /// Creates a pipeline with rings large enough for `ringCapacityHops` hops each side.
    public init(
        inputRate: Int,
        tierRate: Int,
        outputRate: Int,
        restorer: any PipelineRestorer,
        latency: LatencyMeter,
        ringCapacityHops: Int = 8,
        measuresProcessingLatency: Bool = false
    ) {
        for rate in [inputRate, tierRate, outputRate] {
            precondition(
                rate > 0 && rate % Self.hopsPerSecond == 0,
                "every rate must make a \(Self.hopMilliseconds) ms hop of whole frames"
            )
        }
        precondition(ringCapacityHops >= 2, "each ring needs room for two hops")

        self.inputRate = inputRate
        self.tierRate = tierRate
        self.outputRate = outputRate
        monitorTap = PipelineTap(sampleRate: tierRate)
        inputFramesPerHop = inputRate / Self.hopsPerSecond
        tierFramesPerHop = tierRate / Self.hopsPerSecond
        outputFramesPerHop = outputRate / Self.hopsPerSecond
        precondition(
            restorer.hopFrames == tierFramesPerHop,
            "the restorer must consume one tier hop"
        )
        self.restorer = restorer
        self.latency = latency
        self.measuresProcessingLatency = measuresProcessingLatency

        inputRing = RingBuffer(capacity: inputFramesPerHop * ringCapacityHops)
        outputRing = RingBuffer(capacity: outputFramesPerHop * ringCapacityHops)

        inputResampler =
            inputRate == tierRate
            ? nil
            : PolyphaseResampler(inputRate: inputRate, outputRate: tierRate)
        outputResampler =
            tierRate == outputRate
            ? nil
            : PolyphaseResampler(inputRate: tierRate, outputRate: outputRate)
        tierPending =
            inputResampler == nil
            ? nil
            : Self.floats(2 * inputFramesPerHop + 8)
        outputPending =
            outputResampler == nil
            ? nil
            : Self.floats(2 * tierFramesPerHop + 8)
        tierInput = Self.floats(tierFramesPerHop)
        tierWet = Self.floats(tierFramesPerHop)
        tierMixed = Self.floats(tierFramesPerHop)
        alignedRaw = Self.floats(tierFramesPerHop)
        rawDelay = Self.floats(restorer.latencySamples)
        outputHop = Self.floats(outputFramesPerHop)

        crossfadeFrames = max(1, tierRate * 5 / 1000)
        let wet = Self.floats(crossfadeFrames + 1)
        let dry = Self.floats(crossfadeFrames + 1)
        for level in 0...crossfadeFrames {
            let position = Double(level) / Double(crossfadeFrames)
            wet[level] = Float(sin(position * Double.pi / 2))
            dry[level] = Float(cos(position * Double.pi / 2))
        }
        fadeWet = wet
        fadeDry = dry
        fadeLevel = crossfadeFrames
    }

    deinit {
        stop()
        tierPending?.deallocate()
        outputPending?.deallocate()
        tierInput.deallocate()
        tierWet.deallocate()
        tierMixed.deallocate()
        alignedRaw.deallocate()
        rawDelay.deallocate()
        outputHop.deallocate()
        fadeWet.deallocate()
        fadeDry.deallocate()
    }

    /// Sets whether the microphone path is bypassed.
    ///
    /// The flag is read once per hop, so a change never splits a hop between the two paths.
    public func setBypass(_ enabled: Bool) {
        bypass.store(enabled, ordering: .releasing)
    }

    /// Whether the path is currently bypassed.
    public var isBypassed: Bool {
        bypass.load(ordering: .acquiring)
    }

    /// The latest counters, safe to read from the main thread.
    public var metrics: PipelineMetrics {
        let rawStatus = status.load(ordering: .acquiring)
        let microseconds = publishedLatency.load(ordering: .acquiring)
        return PipelineMetrics(
            status: PipelineStatus(rawValue: rawStatus) ?? .waiting,
            addedLatencyMs: microseconds >= 0 ? Double(microseconds) / 1000 : nil,
            lateFrames: lateFrames.load(ordering: .acquiring),
            deadlineMisses: deadlineMisses.load(ordering: .acquiring),
            processedHops: processedHops.load(ordering: .acquiring),
            hops: hopCount.load(ordering: .acquiring)
        )
    }

    /// Starts the pipeline thread.
    public func start() {
        guard thread == nil else {
            return
        }
        running.store(true, ordering: .releasing)
        let thread = Thread { [self] in
            restorer.prepareCallingThread()
            while running.load(ordering: .acquiring) {
                waitForWork()
            }
        }
        thread.name = "untunnel.pipeline"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
    }

    /// Asks the pipeline thread to stop.
    public func stop() {
        running.store(false, ordering: .releasing)
        hopSignal.signal()
        thread = nil
    }

    /// Wakes the thread after a capture callback wrote to the input ring.
    public func signalHop() {
        hopSignal.signal()
    }

    /// Waits for input and beats a silence hop when the device stopped delivering.
    ///
    /// The timeout is what lets the virtual microphone keep receiving frames while the input
    /// device is away; without it the call app would see its device run dry.
    private func waitForWork() {
        let signalled =
            hopSignal.wait(timeout: .now() + .milliseconds(Self.heartbeatMilliseconds))
            == .success
        guard inputRing.availableToRead >= inputFramesPerHop else {
            if !signalled {
                heartbeat()
            }
            return
        }
        runHop()
    }

    /// Writes one silence hop and publishes the waiting state.
    ///
    /// The hop counter advances so the call app keeps a live stream from the virtual microphone
    /// even though no input arrived.
    func heartbeat() {
        outputHop.update(repeating: 0)
        _ = outputRing.write(UnsafeBufferPointer(outputHop))
        _ = hopCount.wrappingAdd(1, ordering: .relaxed)
        _ = lateFrames.wrappingAdd(1, ordering: .relaxed)
        status.store(PipelineStatus.waiting.rawValue, ordering: .releasing)
    }

    /// Runs one hop: read the input ring, resample, restore, mix and write the output ring.
    func runHop(now: () -> UInt64 = HostClock.now) {
        let bypassed = bypass.load(ordering: .acquiring)
        let complete = fillTierInput()
        for index in 0..<tierFramesPerHop {
            if rawDelay.isEmpty {
                alignedRaw[index] = tierInput[index]
            } else {
                alignedRaw[index] = rawDelay[rawDelayIndex]
                rawDelay[rawDelayIndex] = tierInput[index]
                rawDelayIndex = (rawDelayIndex + 1) % rawDelay.count
            }
        }

        let started = now()
        let produced = restorer.process(
            UnsafeBufferPointer(tierInput),
            into: tierWet
        )
        let missedDeadline =
            HostClock.system.milliseconds(since: started, until: now())
            > Double(Self.hopMilliseconds)
        _ = processedHops.wrappingAdd(1, ordering: .relaxed)
        if missedDeadline { _ = deadlineMisses.wrappingAdd(1, ordering: .relaxed) }
        if produced < tierFramesPerHop {
            tierWet[produced...].update(repeating: 0)
        }

        if measuresProcessingLatency { latency.noteOutputPull(now()) }
        mix(bypassed: bypassed, late: missedDeadline)
        monitorTap.publish(UnsafeBufferPointer(tierInput), after: UnsafeBufferPointer(tierMixed))
        writeOutput()

        _ = hopCount.wrappingAdd(1, ordering: .relaxed)
        if !complete || missedDeadline {
            _ = lateFrames.wrappingAdd(1, ordering: .relaxed)
        }
        let published: PipelineStatus =
            bypassed ? .bypassed : complete ? .running : .waiting
        status.store(published.rawValue, ordering: .releasing)
        if let added = latency.addedLatencyMs {
            publishedLatency.store(Int64((added * 1000).rounded()), ordering: .releasing)
        }
    }

    /// Reads a device hop, converts it to the tier rate and reports whether it was complete.
    ///
    /// The resampler may leave a few source frames unused at a hop boundary; they move to the
    /// front of the pending buffer instead of being dropped, so the rate conversion stays exact.
    private func fillTierInput() -> Bool {
        guard let resampler = inputResampler, let pending = tierPending else {
            let read = inputRing.read(into: tierInput)
            if read < tierFramesPerHop {
                Self.zero(tierInput, from: read)
                return false
            }
            return true
        }
        guard let source = pending.baseAddress else {
            return false
        }
        let room = pending.count - tierPendingCount
        let read = inputRing.read(
            into: UnsafeMutableBufferPointer(
                start: source + tierPendingCount,
                count: room
            )
        )
        let available = tierPendingCount + read
        let result = resampler.process(
            UnsafeBufferPointer(start: source, count: available),
            into: tierInput
        )
        if result.produced < tierFramesPerHop {
            Self.zero(tierInput, from: result.produced)
        }
        let remaining = available - result.consumed
        if remaining > 0 && result.consumed > 0 {
            memmove(
                source,
                source + result.consumed,
                remaining * MemoryLayout<Float>.size
            )
        }
        tierPendingCount = remaining
        return result.produced == tierFramesPerHop
    }

    /// Mixes the restored and direct hops with the equal-power fade and converts to the output rate.
    private func mix(bypassed: Bool, late: Bool) {
        let target = bypassed ? 0 : crossfadeFrames
        let lateTarget = late ? crossfadeFrames : 0
        for index in 0..<tierFramesPerHop {
            let restored =
                tierWet[index] * fadeWet[crossfadeFrames - lateFadeLevel]
                + alignedRaw[index] * fadeDry[crossfadeFrames - lateFadeLevel]
            let wet = fadeWet[fadeLevel]
            let dry = fadeDry[fadeLevel]
            tierMixed[index] = restored * wet + tierInput[index] * dry
            if fadeLevel != target {
                fadeLevel += fadeLevel < target ? 1 : -1
            }
            if lateFadeLevel != lateTarget {
                lateFadeLevel += lateFadeLevel < lateTarget ? 1 : -1
            }
        }
    }

    private func writeOutput() {
        guard let mixed = tierMixed.baseAddress, let hop = outputHop.baseAddress else {
            return
        }
        if let resampler = outputResampler, let pending = outputPending {
            guard let source = pending.baseAddress else {
                return
            }
            let byteCount = tierFramesPerHop * MemoryLayout<Float>.size
            memcpy(source + outputPendingCount, mixed, byteCount)
            let available = outputPendingCount + tierFramesPerHop
            let result = resampler.process(
                UnsafeBufferPointer(start: source, count: available),
                into: outputHop
            )
            if result.produced < outputFramesPerHop {
                Self.zero(outputHop, from: result.produced)
            }
            let remaining = available - result.consumed
            if remaining > 0 && result.consumed > 0 {
                memmove(
                    source,
                    source + result.consumed,
                    remaining * MemoryLayout<Float>.size
                )
            }
            outputPendingCount = remaining
        } else {
            for index in 0..<outputFramesPerHop {
                hop[index] = tierMixed[index]
            }
        }
        _ = outputRing.write(UnsafeBufferPointer(outputHop))
    }

    private static func floats(_ count: Int) -> UnsafeMutableBufferPointer<Float> {
        let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: count)
        buffer.initialize(repeating: 0)
        return buffer
    }

    private static func zero(_ buffer: UnsafeMutableBufferPointer<Float>, from start: Int) {
        guard start < buffer.count else {
            return
        }
        for index in start..<buffer.count {
            buffer[index] = 0
        }
    }
}

/// Copies the pipeline's atomics into app state ten times a second.
///
/// Reading the atomics on the main thread keeps the pipeline thread free of allocations and
/// actor hops; the app maps the snapshot's readout into the value the menu shows.
@MainActor
public final class PipelineStatusMonitor {
    /// How often the main thread refreshes the readout.
    public static let interval: TimeInterval = 0.1

    private let pipeline: Pipeline
    private let virtualMic: VirtualMicOutput?
    private let onSnapshot: (PipelineSnapshot) -> Void
    private var timer: Timer?

    /// Creates a monitor for a running pipeline and its optional output stage.
    public init(
        pipeline: Pipeline,
        virtualMic: VirtualMicOutput? = nil,
        onSnapshot: @escaping (PipelineSnapshot) -> Void
    ) {
        self.pipeline = pipeline
        self.virtualMic = virtualMic
        self.onSnapshot = onSnapshot
    }

    /// Starts the ten-hertz refresh.
    public func start() {
        guard timer == nil else {
            return
        }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.publish()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops refreshing.
    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Reads the counters once and hands them to the app.
    public func publish() {
        onSnapshot(currentSnapshot())
    }

    /// The counters as they stand now.
    public func currentSnapshot() -> PipelineSnapshot {
        PipelineSnapshot(
            metrics: pipeline.metrics,
            underflows: virtualMic?.underflowCount ?? 0
        )
    }
}
