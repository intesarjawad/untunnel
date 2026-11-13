import CoreAudio
import Dispatch
import Foundation
import Synchronization
import UntunnelDSP

/// A render device that asks for mono frames on its own real-time thread.
///
/// The block runs inside the device callback and must fill every frame without allocating.
public protocol AudioRenderSink: AnyObject, Sendable {
    var format: AudioStreamFormat { get }
    func start(
        _ render: @escaping @Sendable (UnsafeMutableBufferPointer<Float>, UInt64) -> Void
    ) throws
    func stop()
}

/// Why an output device could not start.
public enum AudioOutputError: Error, CustomStringConvertible {
    case unsupportedDevice
    case failed(operation: String, status: OSStatus)

    public var description: String {
        switch self {
        case .unsupportedDevice:
            return "the output device reports no usable sample rate or buffer size"
        case .failed(let operation, let status):
            return "output device \(operation) failed with OSStatus \(status)"
        }
    }
}

/// Feeds the virtual microphone from the pipeline ring through the drift resampler.
///
/// The callback asks for whatever buffer size its device uses, while the controller works in
/// fixed pipeline hops, so completed hops wait in a small owned buffer and are copied out on
/// demand. A hop that the ring cannot fill is handed to the device as silence and counted, which
/// keeps the readout honest about drops instead of hiding them.
public final class VirtualMicOutput: @unchecked Sendable {
    /// The output format the device reports.
    public let format: AudioStreamFormat

    private let sink: any AudioRenderSink
    private let ring: RingBuffer
    private let latency: LatencyMeter
    private let resampler: DriftResampler
    private let hop: UnsafeMutableBufferPointer<Float>
    private var hopStart = 0
    private var hopCount = 0
    private let underflows = Atomic<UInt64>(0)

    /// Creates an output stage for a device that asks in `format`'s buffer size.
    ///
    /// `hopFrames` is one pipeline hop at the virtual device's rate, the unit the drift
    /// controller steers; it is not the device's callback size.
    public init(
        sink: any AudioRenderSink,
        ring: RingBuffer,
        hopFrames: Int,
        latency: LatencyMeter
    ) {
        self.sink = sink
        self.ring = ring
        self.latency = latency
        format = sink.format
        resampler = DriftResampler(hopSize: hopFrames)
        hop = .allocate(capacity: hopFrames)
        hop.initialize(repeating: 0)
    }

    deinit {
        hop.deallocate()
    }

    /// The hops the ring could not fill.
    public var underflowCount: UInt64 {
        underflows.load(ordering: .acquiring)
    }

    /// Starts delivering hops.
    public func start() throws {
        try sink.start { [weak self] frames, hostTime in
            self?.render(into: frames, hostTime: hostTime)
        }
    }

    /// Stops delivering hops.
    public func stop() {
        sink.stop()
    }

    /// Fills `frames` from completed hops, pulling a new hop only when the last one runs out.
    public func render(into frames: UnsafeMutableBufferPointer<Float>, hostTime: UInt64) {
        var written = 0
        while written < frames.count {
            if hopStart == hopCount {
                pullHop(hostTime: hostTime)
            }
            let take = min(frames.count - written, hopCount - hopStart)
            for index in 0..<take {
                frames[written + index] = hop[hopStart + index]
            }
            written += take
            hopStart += take
        }
    }

    private func pullHop(hostTime: UInt64) {
        let produced = resampler.pullHop(from: ring, into: hop)
        if produced < hop.count {
            for index in produced..<hop.count {
                hop[index] = 0
            }
            _ = underflows.wrappingAdd(1, ordering: .relaxed)
        }
        hopStart = 0
        hopCount = hop.count
        latency.noteOutputPull(hostTime)
    }
}

/// Writes the virtual microphone into a Core Audio device through an IOProc.
public final class HALRenderSink: AudioRenderSink, @unchecked Sendable {
    /// The device's output format.
    public let format: AudioStreamFormat

    private let device: AudioObjectID
    private let queue = DispatchQueue(label: "com.intesarjawad.untunnel.render")
    private let mono: UnsafeMutableBufferPointer<Float>
    private var procID: AudioDeviceIOProcID?

    /// Creates a sink for an open output device.
    public init(device: AudioObjectID) throws {
        let rate = CoreAudioProperties.float64(device, kAudioDevicePropertyNominalSampleRate) ?? 0
        let bufferFrames =
            CoreAudioProperties.uint32(device, kAudioDevicePropertyBufferFrameSize) ?? 0
        guard rate > 0, bufferFrames > 0 else {
            throw AudioOutputError.unsupportedDevice
        }
        self.device = device
        format = AudioStreamFormat(
            sampleRate: Int(rate.rounded()),
            hopFrames: Int(bufferFrames)
        )
        mono = .allocate(capacity: Int(bufferFrames))
        mono.initialize(repeating: 0)
    }

    deinit {
        stop()
        mono.deallocate()
    }

    public func start(
        _ render: @escaping @Sendable (UnsafeMutableBufferPointer<Float>, UInt64) -> Void
    ) throws {
        guard procID == nil else {
            return
        }
        var identifier: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&identifier, device, queue) {
            [mono] _, _, _, output, _ in
            guard output.pointee.mNumberBuffers > 0 else {
                return
            }
            let buffer = output.pointee.mBuffers
            guard let data = buffer.mData else {
                return
            }
            let channels = max(1, Int(buffer.mNumberChannels))
            let frames = min(
                Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels),
                mono.count
            )
            render(mono, AudioGetCurrentHostTime())
            let samples = data.assumingMemoryBound(to: Float.self)
            for index in 0..<frames {
                for channel in 0..<channels {
                    samples[index * channels + channel] = mono[index]
                }
            }
        }
        guard status == noErr, let identifier else {
            throw AudioOutputError.failed(operation: "IOProc creation", status: status)
        }
        procID = identifier
        let started = AudioDeviceStart(device, identifier)
        guard started == noErr else {
            AudioDeviceDestroyIOProcID(device, identifier)
            procID = nil
            throw AudioOutputError.failed(operation: "start", status: started)
        }
    }

    public func stop() {
        guard let identifier = procID else {
            return
        }
        AudioDeviceStop(device, identifier)
        AudioDeviceDestroyIOProcID(device, identifier)
        procID = nil
    }
}
