import Foundation
import Synchronization
import os

/// Keeps the microphone path alive while its input device is away.
///
/// The device is pinned by the UID the path was opened on. Losing it stops capture and clears
/// the restorer's streaming state; only the same UID returning, and not a substitute device,
/// resumes the path. The pipeline's silence heartbeat runs in between, so a call app keeps its
/// microphone device while the headset is gone.
public final class ReconnectRecovery: @unchecked Sendable {
    /// What the microphone path is doing after the last device change.
    public enum State: Equatable, Sendable {
        case running(deviceName: String)
        case waiting(deviceName: String)
    }

    /// The log line written when the watched device goes away.
    public static let lostMessage = "input_device_lost"
    /// The log line written when it comes back.
    public static let restoredMessage = "input_device_restored"

    private static let logger = Logger(subsystem: "com.intesarjawad.untunnel", category: "audio")

    private struct Status {
        /// Whether the pinned device is gone and the path waits for its return.
        var recovering = false
        var isStarted = false
        var observation: (any DeviceObservation)?
    }

    private enum Transition {
        case lost
        case restored
    }

    private let devices: AudioDevices
    private let capture: InputCapture
    private let restorer: any PipelineRestorer
    private let uid: String?
    private let deviceName: String
    private let log: @Sendable (String) -> Void
    private let onState: @Sendable (State) -> Void
    private let status = Mutex(Status())

    /// Creates a recovery for the input device `devices` selects now.
    ///
    /// The restorer must be the stage the pipeline runs, because clearing its state is what
    /// keeps the first hops after a reconnect from carrying audio from before the gap.
    public init(
        devices: AudioDevices,
        capture: InputCapture,
        restorer: any PipelineRestorer,
        log: (@Sendable (String) -> Void)? = nil,
        onState: @escaping @Sendable (State) -> Void = { _ in }
    ) {
        self.devices = devices
        self.capture = capture
        self.restorer = restorer
        let input = devices.snapshot.selection.input
        uid = input?.uid
        deviceName = input?.name ?? ""
        self.log = log ?? Self.writeToLog
        self.onState = onState
    }

    deinit {
        status.withLock { $0.observation?.cancel() }
    }

    /// Starts watching the pinned device.
    public func start() {
        guard uid != nil else {
            return
        }
        let alreadyStarted = status.withLock { status -> Bool in
            guard !status.isStarted else {
                return true
            }
            status.isStarted = true
            return false
        }
        guard !alreadyStarted else {
            return
        }
        let observation = devices.onChange { [weak self] snapshot in
            self?.apply(snapshot)
        }
        status.withLock { $0.observation = observation }
    }

    /// Stops watching the device.
    public func stop() {
        let observation = status.withLock { status -> (any DeviceObservation)? in
            let observation = status.observation
            status.observation = nil
            status.isStarted = false
            return observation
        }
        observation?.cancel()
    }

    private func apply(_ snapshot: AudioDevices.Snapshot) {
        guard let uid else {
            return
        }
        let present = snapshot.devices.contains { $0.uid == uid }
        let transition = status.withLock { status -> Transition? in
            if present {
                guard status.recovering else {
                    return nil
                }
                status.recovering = false
                return .restored
            }
            guard !status.recovering else {
                return nil
            }
            status.recovering = true
            return .lost
        }
        switch transition {
        case .lost:
            lose()
        case .restored:
            restore()
        case nil:
            break
        }
    }

    private func lose() {
        capture.stop()
        restorer.reset()
        log(Self.lostMessage)
        onState(.waiting(deviceName: deviceName))
    }

    private func restore() {
        do {
            try capture.start()
        } catch {
            // The device can be listed before its streams are ready; the next change retries.
            status.withLock { $0.recovering = true }
            return
        }
        log(Self.restoredMessage)
        onState(.running(deviceName: deviceName))
    }

    private static func writeToLog(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }
}
