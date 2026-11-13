import CoreAudio
import Foundation

/// Reports the nominal rate of the headset output, which a call drops to narrowband.
///
/// The protocol keeps the monitor's wait rule a pure decision over a rate and a time, so the
/// rule is tested without a device.
public protocol HeadsetRateSource: AnyObject, Sendable {
    /// The output's nominal rate in hertz, or nil when the device is not present.
    func outputRateHz() -> Double?
}

/// Reads one device's rate through Core Audio.
public final class CoreAudioHeadsetRateSource: HeadsetRateSource {
    private let uid: String

    public init(uid: String) {
        self.uid = uid
    }

    public func outputRateHz() -> Double? {
        guard let device = CoreAudioProperties.deviceID(forUID: uid) else {
            return nil
        }
        return CoreAudioProperties.float64(device, kAudioDevicePropertyNominalSampleRate)
    }
}
