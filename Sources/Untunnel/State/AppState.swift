import Darwin
import Foundation
import Observation
import UntunnelAudio
import UntunnelEngine

/// Everything the menu shows about the running app.
@MainActor
@Observable
final class AppState {
    enum EngineStatus: Equatable {
        case loading
        case ready(Tier)
        case failed(String)
    }

    enum MicPath: Equatable {
        case off
        case standby
        case restoring(Tier)
        case waiting(deviceName: String)
        case bypass
    }

    enum IncomingPath: Equatable {
        case off
        case restoring(pid: pid_t, name: String)
        case blockedSpeakers
        case permissionDenied
        case failed(String)
    }

    var engine = EngineStatus.loading
    var micPath = MicPath.off
    var incoming = IncomingPath.off
    /// The line under the incoming status: a browser-wide mute or the headset's call mode.
    var incomingNote: String?
    var tierNote: String?
    /// The control that marks the current output as headphones, or takes the mark back.
    var headphoneChoice: HeadphoneChoice?
    var addedLatencyMs: Double?
    var isBypassed = false
    var driverNeedsSetup = false
    var openAtLogin = false
    var restoreOther = false
    var loginError: UserFacingError?
    /// What keeps the microphone path from restoring: a missing model or a failed engage.
    var micError: UserFacingError?
    var autoRoute = AutoRouteMenuStatus.default
    var permission = AudioPermission.authorized
    private var micPathBeforeBypass: MicPath?

    /// Toggles bypass without losing the path the microphone was using.
    func toggleBypass() {
        if isBypassed {
            micPath = micPathBeforeBypass ?? .standby
            micPathBeforeBypass = nil
            isBypassed = false
        } else {
            micPathBeforeBypass = micPath
            micPath = .bypass
            isBypassed = true
        }
    }

    /// Shows what the incoming tap reported.
    func incomingChanged(_ outcome: IncomingTapOutcome) {
        switch outcome {
        case .off:
            incoming = .off
        case .tapping(let pid, let name):
            incoming = .restoring(pid: pid, name: name)
        case .pausedOnSpeakers:
            incoming = .blockedSpeakers
        case .permissionDenied:
            incoming = .permissionDenied
        case .failed(let detail):
            incoming = .failed(detail)
        }
    }

    /// Starts listening with the restore path, which is also what raises the microphone prompt.
    func hearYourself() {
        if isBypassed {
            micPath = micPathBeforeBypass ?? .standby
            micPathBeforeBypass = nil
            isBypassed = false
        }
        micPath = .standby
    }

    /// The engine and incoming-audio line the menu shows above the microphone path.
    nonisolated static func statusText(
        engine: EngineStatus,
        incoming: IncomingPath
    ) -> String {
        switch incoming {
        case .off:
            switch engine {
            case .loading:
                return "Starting the restore engine"
            case .ready(let tier):
                let limit = tier.sampleRate == 16_000 ? "; limited band below 8 kHz" : ""
                return "Restore engine ready at \(rateText(tier.sampleRate))\(limit)"
            case .failed(let message):
                return "Restore engine failed: \(message)"
            }
        case .restoring(let pid, let name):
            return "Restoring incoming audio for \(name) (process \(pid))"
        case .blockedSpeakers:
            return "Microphone blocked while the speakers are in use"
        case .permissionDenied:
            return "Microphone permission denied"
        case .failed:
            return "Incoming audio could not start"
        }
    }

    /// The microphone path line, kept separate from the engine status because it changes often.
    nonisolated static func micPathText(_ path: MicPath) -> String {
        switch path {
        case .off:
            return "Microphone off"
        case .standby:
            return "Microphone on standby"
        case .restoring(let tier):
            return "Restoring at \(rateText(tier.sampleRate))"
        case .waiting(let deviceName):
            return "Waiting for \(deviceName)"
        case .bypass:
            return "Microphone bypassed"
        }
    }

    private nonisolated static func rateText(_ sampleRate: Int) -> String {
        guard sampleRate >= 1_000, sampleRate % 1_000 == 0 else {
            return "\(sampleRate) Hz"
        }
        return "\(sampleRate / 1_000) kHz"
    }
}
