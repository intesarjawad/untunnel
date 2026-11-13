import AVFoundation
import CoreAudio
import Foundation
import UntunnelAudio

/// The microphone permission the app can act on.
enum AudioPermission: Equatable, Sendable {
    case authorized
    case notDetermined
    case denied
    case restricted

    var isAuthorized: Bool {
        self == .authorized
    }

    /// Reads the current status without raising the prompt.
    static func current() -> AudioPermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .authorized
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .denied
        }
    }
}

/// The stored state a launch starts from.
struct AutoRouteLaunch: Equatable, Sendable {
    var cleanExit: Bool
    var permission: AudioPermission
    var connectedUIDs: Set<String>
    var currentDefaultUID: String?
    var sourceHeadsetUID: String?
    var previousDefaultUID: String?
    var autoRouteEnabled: Bool
}

/// One device or preference change the routing machine reacts to.
enum AutoRouteEvent: Equatable, Sendable {
    case launch(AutoRouteLaunch)
    case deviceAppeared(uid: String, transport: AudioTransport, at: TimeInterval)
    case defaultInputChanged(uid: String, at: TimeInterval)
    case headsetDisconnected(uid: String, at: TimeInterval)
    case toggle(enabled: Bool, at: TimeInterval)
    case quit(at: TimeInterval)
    case wake(AudioPermission)
    case permissionChanged(AudioPermission, at: TimeInterval)
}

/// What the shell should do after one event.
struct AutoRouteDecision: Equatable, Sendable {
    var defaultInputUID: String?
    var requestPermission = false
    var showsPermissionLine = false
    var isEngaged = false
    var isEnabled = true
    var isAuthorized = true

    static let none = AutoRouteDecision()
}

/// Decides whether the default input should be the app's microphone.
///
/// macOS changes the default to a Bluetooth headset by itself when it connects. A change
/// within three seconds of that headset appearing is therefore the system's, and the app
/// follows it; any later change is the person's and ends routing until the next connect.
struct AutoRoute: Sendable {
    static let connectWindowSeconds: TimeInterval = 3
    static let virtualInputUID = VirtualMicDevices.inputUID

    private var enabled: Bool
    private var authorized: Bool
    private var engaged = false
    private var appearances: [String: TimeInterval] = [:]
    private var bluetoothUIDs: Set<String> = []
    private var lastDefaultUID: String?
    private var sourceHeadsetUID: String?
    private var previousDefaultUID: String?
    private(set) var cleanExit = false

    init(enabled: Bool = true, permission: AudioPermission = .authorized) {
        self.enabled = enabled
        authorized = permission.isAuthorized
    }

    var isEngaged: Bool {
        engaged
    }

    /// The headset the current route follows, for the next launch to re-assert.
    var storedSourceHeadsetUID: String? {
        sourceHeadsetUID
    }

    /// The default the route replaced, for the next launch to restore.
    var storedPreviousDefaultUID: String? {
        previousDefaultUID
    }

    mutating func handle(_ event: AutoRouteEvent) -> AutoRouteDecision {
        var decision = AutoRouteDecision()
        switch event {
        case .launch(let launch):
            enabled = launch.autoRouteEnabled
            lastDefaultUID = launch.currentDefaultUID
            sourceHeadsetUID = launch.sourceHeadsetUID
            previousDefaultUID = launch.previousDefaultUID
            apply(permission: launch.permission, to: &decision)
            if !launch.cleanExit, enabled, authorized,
                let source = launch.sourceHeadsetUID,
                launch.connectedUIDs.contains(source),
                let current = launch.currentDefaultUID,
                current == source || current == launch.previousDefaultUID
            {
                engaged = true
                decision.defaultInputUID = Self.virtualInputUID
            } else {
                engaged = false
            }

        case .deviceAppeared(let uid, let transport, let at):
            appearances[uid] = at
            if transport == .bluetooth {
                bluetoothUIDs.insert(uid)
            }

        case .defaultInputChanged(let uid, let at):
            let prior = lastDefaultUID
            lastDefaultUID = uid
            guard uid != Self.virtualInputUID else {
                break
            }
            if enabled, authorized,
                let appeared = appearances[uid],
                bluetoothUIDs.contains(uid),
                at >= appeared,
                at - appeared <= Self.connectWindowSeconds
            {
                engaged = true
                sourceHeadsetUID = uid
                if let prior, prior != Self.virtualInputUID {
                    previousDefaultUID = prior
                }
                decision.defaultInputUID = Self.virtualInputUID
            } else {
                engaged = false
            }

        case .headsetDisconnected(let uid, _):
            appearances.removeValue(forKey: uid)
            bluetoothUIDs.remove(uid)
            if uid == sourceHeadsetUID {
                engaged = false
                sourceHeadsetUID = nil
                previousDefaultUID = nil
            }

        case .toggle(let enabled, _):
            self.enabled = enabled
            if !enabled {
                engaged = false
            }

        case .quit:
            cleanExit = true
            decision.defaultInputUID = engaged ? previousDefaultUID : nil
            engaged = false

        case .wake(let permission):
            apply(permission: permission, to: &decision)
            if !authorized {
                engaged = false
            }

        case .permissionChanged(let permission, _):
            apply(permission: permission, to: &decision)
            if !authorized {
                engaged = false
            }
        }
        decision.isEngaged = engaged
        decision.isEnabled = enabled
        decision.isAuthorized = authorized
        return decision
    }

    private mutating func apply(
        permission: AudioPermission,
        to decision: inout AutoRouteDecision
    ) {
        authorized = permission.isAuthorized
        switch permission {
        case .notDetermined:
            decision.requestPermission = true
        case .denied, .restricted:
            decision.showsPermissionLine = true
        case .authorized:
            break
        }
    }
}

/// Applies the default input the machine chose.
///
/// Changing another application's default input is a system setting, so it is behind this
/// protocol and never runs in a unit test.
protocol DefaultInputSetter: AnyObject, Sendable {
    func setDefaultInput(uid: String) -> Bool
}

/// The live setter, which writes `kAudioHardwarePropertyDefaultInputDevice` by device UID.
final class CoreAudioDefaultInput: DefaultInputSetter, @unchecked Sendable {
    func setDefaultInput(uid: String) -> Bool {
        guard let device = CoreAudioDeviceLookup.deviceID(for: uid) else {
            return false
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = device
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &value
        ) == noErr
    }
}

/// The state a relaunch needs after the process died without a clean exit.
final class AutoRouteStore {
    static let cleanExitKey = "AutoRouteCleanExit"
    static let sourceHeadsetKey = "AutoRouteSourceHeadsetUID"
    static let previousDefaultKey = "AutoRoutePreviousDefaultUID"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var cleanExit: Bool {
        defaults.bool(forKey: Self.cleanExitKey)
    }

    var sourceHeadsetUID: String? {
        defaults.string(forKey: Self.sourceHeadsetKey)
    }

    var previousDefaultUID: String? {
        defaults.string(forKey: Self.previousDefaultKey)
    }

    func save(cleanExit: Bool, sourceHeadsetUID: String?, previousDefaultUID: String?) {
        defaults.set(cleanExit, forKey: Self.cleanExitKey)
        defaults.set(sourceHeadsetUID, forKey: Self.sourceHeadsetKey)
        defaults.set(previousDefaultUID, forKey: Self.previousDefaultKey)
    }
}

/// Runs the state machine, applies its answer and keeps the relaunch state on disk.
final class AutoRouteShell {
    private let setter: any DefaultInputSetter
    private let store: AutoRouteStore
    private let enabled: Bool
    private var machine: AutoRoute

    init(
        setter: any DefaultInputSetter = CoreAudioDefaultInput(),
        store: AutoRouteStore = AutoRouteStore(),
        enabled: Bool = true,
        permission: AudioPermission = .current()
    ) {
        self.setter = setter
        self.store = store
        self.enabled = enabled
        machine = AutoRoute(enabled: enabled, permission: permission)
    }

    /// Starts from the devices the system reports and the state a previous run left.
    func launch(
        cleanExit: Bool,
        permission: AudioPermission,
        source: any DeviceSource
    ) -> AutoRouteDecision {
        let launch = AutoRouteLaunch(
            cleanExit: cleanExit,
            permission: permission,
            connectedUIDs: Set(source.devices.map(\.uid)),
            currentDefaultUID: source.defaultInputDeviceUID,
            sourceHeadsetUID: store.sourceHeadsetUID,
            previousDefaultUID: store.previousDefaultUID,
            autoRouteEnabled: enabled
        )
        return handle(.launch(launch))
    }

    @discardableResult
    func handle(_ event: AutoRouteEvent) -> AutoRouteDecision {
        let decision = machine.handle(event)
        if let uid = decision.defaultInputUID {
            _ = setter.setDefaultInput(uid: uid)
        }
        if case .quit = event {
            store.save(cleanExit: true, sourceHeadsetUID: nil, previousDefaultUID: nil)
        } else {
            store.save(
                cleanExit: false,
                sourceHeadsetUID: machine.storedSourceHeadsetUID,
                previousDefaultUID: machine.storedPreviousDefaultUID
            )
        }
        return decision
    }
}

/// The driver's comparison with the plug-in version bundled in the app.
enum DriverVersion {
    /// The `'vers'` custom property the plug-in publishes for its own version.
    static let versionSelector: AudioObjectPropertySelector = 0x7665_7273

    static func isOutdated(installed: String?, bundled: String?) -> Bool {
        guard let installed, let bundled else {
            return false
        }
        return UpdateVersion(installed) != UpdateVersion(bundled)
    }

    static var outdatedError: UserFacingError {
        .driverVersionChanged
    }
}

extension UserFacingError {
    /// The error the menu shows when the installed plug-in is not the bundled one.
    static var driverOutdated: UserFacingError {
        DriverVersion.outdatedError
    }
}

/// Reads the installed plug-in's version from its audio device.
final class CoreAudioDriverVersion {
    private let feedUID: String
    private let paths: InstalledPaths

    init(feedUID: String, paths: InstalledPaths = .current) {
        self.feedUID = feedUID
        self.paths = paths
    }

    func installedVersion() -> String? {
        guard let device = CoreAudioDeviceLookup.deviceID(for: feedUID) else {
            return nil
        }
        var address = AudioObjectPropertyAddress(
            mSelector: DriverVersion.versionSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else {
            return nil
        }
        return value as String
    }

    func bundledVersion() -> String? {
        UpdateReader.bundleVersion(at: paths.driver)
    }

    var isOutdated: Bool {
        DriverVersion.isOutdated(
            installed: installedVersion(),
            bundled: bundledVersion()
        )
    }
}

/// The Core Audio lookup the routing and heartbeat shells share.
enum CoreAudioDeviceLookup {
    static func deviceID(for uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
            ) == noErr,
            size > 0
        else {
            return nil
        }
        var identifiers = [AudioDeviceID](
            repeating: kAudioObjectUnknown,
            count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        let status = identifiers.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else {
                return kAudioHardwareBadObjectError
            }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, base
            )
        }
        guard status == noErr else {
            return nil
        }
        return identifiers.first {
            string(identifier: $0, selector: kAudioDevicePropertyDeviceUID) == uid
        }
    }

    private static func string(
        identifier: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(identifier, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else {
            return nil
        }
        return value as String
    }
}

/// What the menu shows for auto-route while no runtime state is connected yet.
struct AutoRouteMenuStatus: Equatable {
    var isEnabled: Bool
    var reason: String?

    static let `default` = AutoRouteMenuStatus(isEnabled: true, reason: nil)

    static func evaluate(
        prerequisites: Heartbeat.Prerequisites,
        enabled: Bool
    ) -> AutoRouteMenuStatus {
        AutoRouteMenuStatus(
            isEnabled: enabled && prerequisites.isEligible,
            reason: prerequisites.rejectionReason
        )
    }
}
