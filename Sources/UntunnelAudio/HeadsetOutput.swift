import CoreAudio
import Foundation
import Synchronization
import UntunnelDSP

/// A headphone output that plays one recorded take at a time.
///
/// The protocol lets the monitor's tests record the sides it plays without opening a device.
public protocol HeadphoneOutput: AnyObject, Sendable {
    /// Plays `samples` from their start, replacing anything already playing.
    func play(_ samples: [Float], sampleRate: Int) throws
    /// Stops playback and releases the device.
    func stop()
}

/// Decides whether the other person's audio may play on the current output.
///
/// A tapped call that is played on speakers is heard in the room, which is worse than not
/// restoring it, so only a Bluetooth headset, the built-in headphone jack, or a device the
/// person marked as headphones is allowed. Everything else pauses the incoming path until the
/// output changes back, and the call itself keeps running.
public enum HeadphoneGuard {
    public static func allows(
        _ output: AudioDevice?,
        headphones: Set<String>,
        allowedOutputUID: String?
    ) -> Bool {
        guard let output else {
            return false
        }
        if output.transport == .bluetooth {
            return true
        }
        if output.transport == .builtIn && output.dataSource == .headphones {
            return true
        }
        if headphones.contains(output.uid) {
            return true
        }
        return output.uid == allowedOutputUID
    }
}

/// Reads the call mode a headset drops into while its microphone is open.
///
/// A narrowband output still carries the call, so restoration keeps running as a repair; only
/// the bandwidth above the headset's ceiling is missing, and the menu says so instead of
/// promising clarity the headset cannot deliver.
public enum HeadsetCallMode {
    /// The highest output rate a headset keeps for a call.
    public static let ceilingHz: Double = 16_000

    /// The note the menu shows, or nil when the output has its full rate.
    public static func note(rateHz: Double?) -> String? {
        guard let rateHz, rateHz > 0, rateHz <= ceilingHz else {
            return nil
        }
        return
            "Your headset is in call mode (\(rateText(rateHz))): restoring clarity, not bandwidth"
    }

    /// A rate as a person reads it: whole kilohertz when it is a round thousand.
    static func rateText(_ rateHz: Double) -> String {
        let hertz = Int(rateHz.rounded())
        guard hertz >= 1_000, hertz % 1_000 == 0 else {
            return "\(hertz) Hz"
        }
        return "\(hertz / 1_000) kHz"
    }
}

/// Plays a take into a headset output through an IOProc.
///
/// The take is resampled once, before the device starts, so the callback only copies frames and
/// advances an atomic position. Playback stops when the caller stops it; the remaining frames of
/// a finished take render as silence.
public final class HeadsetOutput: HeadphoneOutput, @unchecked Sendable {
    /// The frames a running IOProc reads in order.
    private final class Playback: @unchecked Sendable {
        let frames: UnsafeMutableBufferPointer<Float>
        let position = Atomic<Int>(0)

        init(frames: UnsafeMutableBufferPointer<Float>) {
            self.frames = frames
        }

        deinit {
            frames.deallocate()
        }
    }

    private let uid: String
    private var sink: HALRenderSink?
    private var playback: Playback?

    public init(uid: String) {
        self.uid = uid
    }

    deinit {
        stop()
    }

    public func play(_ samples: [Float], sampleRate: Int) throws {
        stop()
        guard let device = CoreAudioProperties.deviceID(forUID: uid) else {
            throw AudioOutputError.unsupportedDevice
        }
        let sink = try HALRenderSink(device: device)
        let frames = Self.resampled(samples, from: sampleRate, to: sink.format.sampleRate)
        let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: frames.count)
        buffer.initialize(repeating: 0)
        frames.withUnsafeBufferPointer { source in
            guard let destination = buffer.baseAddress, let start = source.baseAddress else {
                return
            }
            destination.update(from: start, count: source.count)
        }

        let playback = Playback(frames: buffer)
        try sink.start { [playback] output, _ in
            var index = playback.position.load(ordering: .relaxed)
            for slot in output.indices {
                output[slot] = index < playback.frames.count ? playback.frames[index] : 0
                index += 1
            }
            playback.position.store(index, ordering: .relaxed)
        }
        self.sink = sink
        self.playback = playback
    }

    public func stop() {
        sink?.stop()
        sink = nil
        playback = nil
    }

    private static func resampled(
        _ samples: [Float],
        from inputRate: Int,
        to outputRate: Int
    ) -> [Float] {
        guard inputRate != outputRate else {
            return samples
        }
        let count = Int(
            (Double(samples.count) * Double(outputRate) / Double(inputRate)).rounded()
        )
        return PolyphaseResampler(inputRate: inputRate, outputRate: outputRate)
            .resample(samples, count: count)
    }
}
