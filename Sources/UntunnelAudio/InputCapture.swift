import CoreAudio
import Dispatch
import Foundation
import Synchronization
import UntunnelDSP

/// The streaming format a device uses for one direction.
public struct AudioStreamFormat: Equatable, Sendable {
    /// Frames per second.
    public let sampleRate: Int
    /// Frames the device delivers or requests in one callback.
    public let hopFrames: Int

    /// Creates a format from a device's nominal rate and buffer size.
    public init(sampleRate: Int, hopFrames: Int) {
        precondition(sampleRate > 0, "a stream needs a positive rate")
        precondition(hopFrames > 0, "a stream needs at least one frame per callback")
        self.sampleRate = sampleRate
        self.hopFrames = hopFrames
    }
}

/// A capture device that delivers mono hops on its own real-time thread.
///
/// The block runs inside the device callback, so it may only copy samples and read a host time.
public protocol AudioCaptureSource: AnyObject, Sendable {
    var format: AudioStreamFormat { get }
    func start(_ onHop: @escaping @Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void) throws
    func stop()
}

/// Why a capture device could not start.
public enum AudioCaptureError: Error, CustomStringConvertible {
    case unsupportedDevice
    case failed(operation: String, status: OSStatus)

    public var description: String {
        switch self {
        case .unsupportedDevice:
            return "the capture device reports no usable sample rate or buffer size"
        case .failed(let operation, let status):
            return "capture device \(operation) failed with OSStatus \(status)"
        }
    }
}

/// Copies the headset input into the pipeline ring and stamps each completed hop.
///
/// The device callback owns no state of its own: writing the ring and pushing the host stamp are
/// both non-blocking, and the pipeline thread is the only reader. Devices deliver their own buffer
/// sizes, so the stamp counts delivered frames and marks the end of each ten-millisecond hop,
/// which is the cadence the virtual microphone pulls at.
public final class InputCapture: @unchecked Sendable {
    /// The input format the device reports.
    public let format: AudioStreamFormat

    private let source: any AudioCaptureSource
    private let ring: RingBuffer
    private let latency: LatencyMeter
    private let recordingRing: RingBuffer?
    private let hopFrames: Int
    private let signal: (@Sendable () -> Void)?
    private let delivered = FrameCounter()

    /// Creates a capture stage that fills `ring` and stamps `latency`.
    ///
    /// `signal` wakes the pipeline thread after every callback; the ring decides whether a whole
    /// hop is ready, so a device with small buffers still needs no polling.
    public init(
        source: any AudioCaptureSource,
        ring: RingBuffer,
        latency: LatencyMeter,
        recordingRing: RingBuffer? = nil,
        signal: (@Sendable () -> Void)? = nil
    ) {
        self.source = source
        self.ring = ring
        self.latency = latency
        self.recordingRing = recordingRing
        self.signal = signal
        format = source.format
        hopFrames = max(1, format.sampleRate * Pipeline.hopMilliseconds / 1000)
    }

    /// Starts delivering hops.
    public func start() throws {
        try source.start {
            [ring, recordingRing, latency, hopFrames, signal, counter = delivered] frames, hostTime
            in
            _ = ring.write(frames)
            _ = recordingRing?.write(frames)
            signal?()
            guard counter.advance(by: frames.count, hopFrames: hopFrames) else {
                return
            }
            latency.noteInputCompletion(hostTime)
        }
    }

    /// Stops delivering hops.
    public func stop() {
        source.stop()
    }
}

/// Counts delivered frames between real-time callbacks without allocating.
private final class FrameCounter: @unchecked Sendable {
    private let value = Atomic<UInt64>(0)

    /// Adds one callback's frames and reports whether a whole hop just completed.
    func advance(by frames: Int, hopFrames: Int) -> Bool {
        let total = value.wrappingAdd(UInt64(frames), ordering: .relaxed).newValue
        guard total >= UInt64(hopFrames) else {
            return false
        }
        value.store(total % UInt64(hopFrames), ordering: .relaxed)
        return true
    }
}

/// Reads a Core Audio device's input through an IOProc.
public final class HALCaptureSource: AudioCaptureSource, @unchecked Sendable {
    /// The device's input format.
    public let format: AudioStreamFormat

    private let device: AudioObjectID
    private let queue = DispatchQueue(label: "com.intesarjawad.untunnel.capture")
    private let mono: UnsafeMutableBufferPointer<Float>
    private var procID: AudioDeviceIOProcID?

    /// Opens a device by the stable UID the app selects it with.
    public convenience init(uid: String) throws {
        guard let device = CoreAudioProperties.deviceID(forUID: uid) else {
            throw AudioCaptureError.unsupportedDevice
        }
        try self.init(device: device)
    }

    /// Creates a source for an open input device.
    public init(device: AudioObjectID) throws {
        let rate = CoreAudioProperties.float64(device, kAudioDevicePropertyNominalSampleRate) ?? 0
        let bufferFrames =
            CoreAudioProperties.uint32(device, kAudioDevicePropertyBufferFrameSize) ?? 0
        guard rate > 0, bufferFrames > 0 else {
            throw AudioCaptureError.unsupportedDevice
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
        _ onHop: @escaping @Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void
    ) throws {
        guard procID == nil else {
            return
        }
        var identifier: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&identifier, device, queue) {
            [mono] _, input, _, _, _ in
            guard input.pointee.mNumberBuffers > 0 else {
                return
            }
            let buffer = input.pointee.mBuffers
            guard let data = buffer.mData else {
                return
            }
            let channels = max(1, Int(buffer.mNumberChannels))
            let frames = min(
                Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels),
                mono.count
            )
            let samples = data.assumingMemoryBound(to: Float.self)
            for index in 0..<frames {
                mono[index] = samples[index * channels]
            }
            onHop(UnsafeBufferPointer(mono), AudioGetCurrentHostTime())
        }
        guard status == noErr, let identifier else {
            throw AudioCaptureError.failed(operation: "IOProc creation", status: status)
        }
        procID = identifier
        let started = AudioDeviceStart(device, identifier)
        guard started == noErr else {
            AudioDeviceDestroyIOProcID(device, identifier)
            procID = nil
            throw AudioCaptureError.failed(operation: "start", status: started)
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

/// The Core Audio property reads the audio layer needs.
///
/// The existing device enumeration keeps its readers private, so this small copy serves the
/// capture, output and latency stages without widening that API.
enum CoreAudioProperties {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func deviceID(forUID uid: String) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var string = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &string) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                pointer,
                &size,
                &device
            )
        }
        guard status == noErr, device != kAudioObjectUnknown else {
            return nil
        }
        return device
    }

    static func streamIDs(
        _ device: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> [AudioStreamID] {
        var address = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
            size > 0
        else {
            return []
        }
        var identifiers = [AudioStreamID](
            repeating: kAudioObjectUnknown,
            count: Int(size) / MemoryLayout<AudioStreamID>.size
        )
        let status = identifiers.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else {
                return kAudioHardwareBadObjectError
            }
            return AudioObjectGetPropertyData(
                device,
                &address,
                0,
                nil,
                &size,
                base
            )
        }
        guard status == noErr else {
            return []
        }
        return identifiers
    }

    static func uint32(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> UInt32? {
        var address = address(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
        else {
            return nil
        }
        return value
    }

    static func float64(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> Float64? {
        var address = address(selector, scope: scope)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
        else {
            return nil
        }
        return value
    }
}
