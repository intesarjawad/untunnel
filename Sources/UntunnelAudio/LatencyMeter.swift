import CoreAudio
import Darwin
import Synchronization

/// How host ticks map to wall time.
///
/// The tick rate differs between Intel machines and Apple silicon, so the conversion stays a
/// value that tests can replace instead of a hard-coded nanosecond assumption.
public struct HostClock: Sendable {
    /// Host ticks in one second.
    public let ticksPerSecond: Double

    /// Creates a clock from a tick rate a device timestamp uses.
    public init(ticksPerSecond: Double) {
        precondition(ticksPerSecond > 0, "a clock needs a positive tick rate")
        self.ticksPerSecond = ticksPerSecond
    }

    /// The running machine's clock.
    public static let system = HostClock(ticksPerSecond: systemTicksPerSecond())

    /// The current host time.
    public static func now() -> UInt64 {
        mach_absolute_time()
    }

    /// The milliseconds between two host stamps, clamped at zero for out-of-order stamps.
    public func milliseconds(since earlier: UInt64, until later: UInt64) -> Double {
        guard later >= earlier else {
            return 0
        }
        return Double(later - earlier) * 1000 / ticksPerSecond
    }

    private static func systemTicksPerSecond() -> Double {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        guard timebase.denom > 0 else {
            return 1_000_000_000
        }
        return 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer)
    }
}

/// The latency one device adds between its converter and the host.
///
/// Core Audio reports the converter latency, the safety offset and each stream's own latency in
/// frames. Summing them per direction gives the delay the app must add to its own measurement.
public struct AudioLatency: Equatable, Sendable {
    /// Seconds the input path adds.
    public let inputSeconds: Double
    /// Seconds the output path adds.
    public let outputSeconds: Double

    /// Creates a latency from the two directional totals.
    public init(inputSeconds: Double, outputSeconds: Double) {
        precondition(inputSeconds >= 0 && outputSeconds >= 0, "device latency cannot be negative")
        self.inputSeconds = inputSeconds
        self.outputSeconds = outputSeconds
    }

    /// Both directions together, in milliseconds.
    public var totalMilliseconds: Double {
        (inputSeconds + outputSeconds) * 1000
    }
}

/// Reads the latency a device reports, behind a protocol so latency arithmetic runs without it.
public protocol DeviceLatencySource: Sendable {
    func latency(deviceUID: String) -> AudioLatency?
}

/// Measures the host time a hop spends between input completion and output pull.
///
/// The input and output callbacks run on two different real-time threads, so the stamps travel
/// through a single-producer, single-consumer ring and the consumer owns the median window. No
/// lock, allocation or logging happens on either callback: the published median is one atomic
/// that the pipeline thread reads and republishes with its other counters.
public final class LatencyMeter: @unchecked Sendable {
    /// How many hop latencies the median covers.
    public static let windowSize = 50

    /// The stamps are one per hop; this leaves room for a stalled consumer without unbounded memory.
    private static let stampCapacity = 64

    /// The device latency the readout adds to the measured hop latency.
    public let deviceLatencyMs: Double

    private let clock: HostClock
    private let stamps: UnsafeMutableBufferPointer<UInt64>
    private let stampWrite = Atomic<UInt64>(0)
    private let stampRead = Atomic<UInt64>(0)
    private let samples: UnsafeMutableBufferPointer<Double>
    private let scratch: UnsafeMutableBufferPointer<Double>
    private var sampleIndex = 0
    private var sampleCount = 0
    private let publishedMicroseconds = Atomic<Int64>(-1)

    /// Creates a meter whose readout adds `deviceLatencyMs` to the measured hops.
    public init(deviceLatencyMs: Double = 0, clock: HostClock = .system) {
        precondition(deviceLatencyMs >= 0, "device latency cannot be negative")
        self.deviceLatencyMs = deviceLatencyMs
        self.clock = clock
        stamps = .allocate(capacity: Self.stampCapacity)
        stamps.initialize(repeating: 0)
        samples = .allocate(capacity: Self.windowSize)
        samples.initialize(repeating: 0)
        scratch = .allocate(capacity: Self.windowSize)
        scratch.initialize(repeating: 0)
    }

    deinit {
        stamps.deallocate()
        samples.deallocate()
        scratch.deallocate()
    }

    /// Records that one hop finished arriving from the capture device.
    public func noteInputCompletion(_ hostTime: UInt64) {
        let write = stampWrite.load(ordering: .relaxed)
        let read = stampRead.load(ordering: .acquiring)
        guard write - read < UInt64(Self.stampCapacity) else {
            return
        }
        stamps[Int(write % UInt64(Self.stampCapacity))] = hostTime
        stampWrite.store(write + 1, ordering: .releasing)
    }

    /// Pairs the next output pull with the oldest input completion and records the difference.
    public func noteOutputPull(_ hostTime: UInt64) {
        let write = stampWrite.load(ordering: .acquiring)
        let read = stampRead.load(ordering: .relaxed)
        guard read < write else {
            return
        }
        let stamp = stamps[Int(read % UInt64(Self.stampCapacity))]
        stampRead.store(read + 1, ordering: .releasing)
        record(clock.milliseconds(since: stamp, until: hostTime))
    }

    /// The median hop latency so far, without device latency.
    public var medianHopLatencyMs: Double? {
        let microseconds = publishedMicroseconds.load(ordering: .acquiring)
        guard microseconds >= 0 else {
            return nil
        }
        return Double(microseconds) / 1000
    }

    /// The readout the app shows: median hop latency plus the device's own delay.
    public var addedLatencyMs: Double? {
        medianHopLatencyMs.map { $0 + deviceLatencyMs }
    }

    private func record(_ milliseconds: Double) {
        samples[Int(sampleIndex)] = milliseconds
        sampleIndex = (sampleIndex + 1) % Self.windowSize
        sampleCount = min(sampleCount + 1, Self.windowSize)

        for index in 0..<sampleCount {
            scratch[index] = samples[index]
        }
        for index in 1..<sampleCount {
            let value = scratch[index]
            var slot = index
            while slot > 0 && scratch[slot - 1] > value {
                scratch[slot] = scratch[slot - 1]
                slot -= 1
            }
            scratch[slot] = value
        }

        let middle = sampleCount / 2
        let median =
            sampleCount.isMultiple(of: 2)
            ? (scratch[middle - 1] + scratch[middle]) / 2
            : scratch[middle]
        publishedMicroseconds.store(
            Int64((median * 1000).rounded()),
            ordering: .releasing
        )
    }
}

/// Reads the running system's device latency through Core Audio.
public final class CoreAudioDeviceLatencySource: DeviceLatencySource {
    public init() {}

    public func latency(deviceUID: String) -> AudioLatency? {
        guard let device = CoreAudioProperties.deviceID(forUID: deviceUID) else {
            return nil
        }
        let rate = CoreAudioProperties.float64(device, kAudioDevicePropertyNominalSampleRate) ?? 0
        guard rate > 0 else {
            return nil
        }
        let frames = Double(CoreAudioProperties.uint32(device, kAudioDevicePropertyLatency) ?? 0)
        let input =
            frames
            + Double(
                CoreAudioProperties.uint32(
                    device,
                    kAudioDevicePropertySafetyOffset,
                    scope: kAudioObjectPropertyScopeInput
                ) ?? 0
            )
            + Self.streamLatencyFrames(device, scope: kAudioObjectPropertyScopeInput)
        let output =
            frames
            + Double(
                CoreAudioProperties.uint32(
                    device,
                    kAudioDevicePropertySafetyOffset,
                    scope: kAudioObjectPropertyScopeOutput
                ) ?? 0
            )
            + Self.streamLatencyFrames(device, scope: kAudioObjectPropertyScopeOutput)
        return AudioLatency(
            inputSeconds: input / rate,
            outputSeconds: output / rate
        )
    }

    private static func streamLatencyFrames(
        _ device: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> Double {
        CoreAudioProperties.streamIDs(device, scope: scope).reduce(0) { total, stream in
            total + Double(CoreAudioProperties.uint32(stream, kAudioStreamPropertyLatency) ?? 0)
        }
    }
}
