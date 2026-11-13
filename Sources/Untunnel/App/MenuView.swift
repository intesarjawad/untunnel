import AppKit
import Carbon.HIToolbox
import Darwin
import SwiftUI
import UntunnelAudio

/// Registers Control-Option-H with Carbon, because a SwiftUI menu shortcut only fires while
/// the menu is open and a global shortcut needs no Accessibility permission.
final class GlobalHotkey: @unchecked Sendable {
    static let keyCode = UInt32(kVK_ANSI_H)
    static let modifiers = UInt32(controlKey | optionKey)
    private static let signature = OSType(0x4846_4D43)

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var action: (@MainActor () -> Void)?

    /// Returns `noErr` once both the handler and the hot key are registered.
    @discardableResult
    func register(_ action: @escaping @MainActor () -> Void) -> OSStatus {
        unregister()
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else {
                    return OSStatus(eventNotHandledErr)
                }
                let hotkey = Unmanaged<GlobalHotkey>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                MainActor.assumeIsolated {
                    hotkey.invoke()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard handlerStatus == noErr else {
            self.action = nil
            return handlerStatus
        }

        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            Self.keyCode,
            Self.modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr else {
            unregister()
            return status
        }
        return noErr
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        action = nil
    }

    @MainActor
    private func invoke() {
        action?()
    }
}

/// A dotted version that compares numerically, so `1.10` is newer than `1.9`.
struct UpdateVersion: Comparable {
    private let parts: [Int]

    init(_ value: String) {
        parts = value.split(separator: ".").map { Int($0) ?? 0 }
    }

    static func < (lhs: UpdateVersion, rhs: UpdateVersion) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }
}

struct InstalledVersionSnapshot: Equatable {
    let bundle: String?
    let driver: String?
}

enum UpdateAction: Equatable {
    case none
    case recheckDriver
    case relaunch(app: URL)
}

/// Decides whether the bundle on disk should replace the running one.
///
/// Only Standby is safe: restoring or waiting means a call is using the microphone, and a
/// relaunch would cut it. The one-minute gate keeps a slow disk from being read on every tick.
struct UpdateWatcher {
    static let interval: TimeInterval = 60

    let app: URL
    let currentBundleVersion: String?
    private var lastCheckAt: TimeInterval?
    private var lastDriverVersion: String?

    init(app: URL, currentBundleVersion: String?, driverVersion: String?) {
        self.app = app
        self.currentBundleVersion = currentBundleVersion
        lastDriverVersion = driverVersion
    }

    mutating func check(
        now: TimeInterval,
        micPath: AppState.MicPath,
        versions: InstalledVersionSnapshot
    ) -> UpdateAction {
        guard micPath == .standby else {
            return .none
        }
        if let lastCheckAt, now - lastCheckAt < Self.interval {
            return .none
        }
        lastCheckAt = now

        if let bundle = versions.bundle,
            let currentBundleVersion,
            UpdateVersion(bundle) > UpdateVersion(currentBundleVersion)
        {
            return .relaunch(app: app)
        }
        if let driver = versions.driver, driver != lastDriverVersion {
            lastDriverVersion = driver
            return .recheckDriver
        }
        return .none
    }
}

/// Applies an update decision and records the version that was read on the way through.
struct UpdateRunner {
    var watcher: UpdateWatcher
    let spawn: (URL) -> Bool
    let exit: (Int32) -> Void

    static func live() -> UpdateRunner {
        let paths = InstalledPaths.current
        return UpdateRunner(
            watcher: UpdateWatcher(
                app: paths.app,
                currentBundleVersion: UpdateReader.bundleVersion(at: paths.app),
                driverVersion: UpdateReader.bundleVersion(at: paths.driver)
            ),
            spawn: { Relaunch.spawn($0) },
            exit: { Darwin.exit($0) }
        )
    }

    mutating func tick(
        now: TimeInterval,
        micPath: AppState.MicPath,
        versions: InstalledVersionSnapshot
    ) -> UpdateAction {
        let action = watcher.check(now: now, micPath: micPath, versions: versions)
        if case .relaunch(let app) = action, spawn(app) {
            exit(0)
        }
        return action
    }
}

enum UpdateReader {
    static func snapshot(paths: InstalledPaths = .current) -> InstalledVersionSnapshot {
        InstalledVersionSnapshot(
            bundle: bundleVersion(at: paths.app),
            driver: bundleVersion(at: paths.driver)
        )
    }

    static func bundleVersion(at url: URL) -> String? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard
            let data = try? Data(contentsOf: plist),
            let values = try? PropertyListSerialization.propertyList(
                from: data,
                format: nil
            ) as? [String: Any]
        else {
            return nil
        }
        return values["CFBundleVersion"] as? String
    }
}

/// Starts a new copy after the current process exits, in its own session.
enum Relaunch {
    static let shell = "/bin/sh"
    static let script = "sleep 1; exec /usr/bin/open -n \"$1\""

    static func arguments(for app: URL) -> [String] {
        [shell, "-c", script, "sh", app.path]
    }

    /// Returns false when the process could not be started; the caller stays alive then.
    @discardableResult
    static func spawn(_ app: URL) -> Bool {
        var arguments = arguments(for: app).map { strdup($0) }
        arguments.append(nil)
        defer {
            for argument in arguments {
                if let argument {
                    free(argument)
                }
            }
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawnattr_destroy(&attributes)
        }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID)) == 0 else {
            return false
        }

        var pid: pid_t = 0
        return posix_spawn(&pid, shell, nil, &attributes, arguments, environ) == 0
    }
}

/// What the menu adds under the status line for the other person's audio.
struct IncomingMenuStatus: Equatable {
    /// The line the tap or the output rate adds, such as a browser-wide mute or call mode.
    var note: String?

    static let `default` = IncomingMenuStatus()

    /// The lines under the status line, in the order a person reads them.
    static func lines(path: AppState.IncomingPath, note: String?) -> [String] {
        switch path {
        case .off:
            return []
        case .restoring:
            return note.map { [$0] } ?? []
        case .blockedSpeakers:
            return ["Paused on speakers"]
        case .permissionDenied:
            return [
                "Untunnel needs permission to capture the other person's audio.",
                "Choose System Audio Recording in Privacy & Security.",
            ]
        case .failed(let detail):
            return [
                "The other person's audio could not be restored: \(detail)",
                "Turn \"Also restore the other person\" off and on to try again.",
            ]
        }
    }
}

/// The "These are headphones" control for the current output.
///
/// Only a USB output can be marked: a built-in speaker, a display or an AirPlay receiver is
/// refused for good, because restored audio played there would reach the call as echo. A marked
/// output keeps its control so the choice can be taken back.
struct HeadphoneChoice: Equatable {
    let uid: String
    let name: String
    let isMarked: Bool

    var title: String {
        isMarked ? "\(name) is not headphones" : "Treat \(name) as headphones"
    }

    static func offer(
        output: AudioDevice?,
        path: AppState.IncomingPath,
        marked: Set<String>
    ) -> HeadphoneChoice? {
        guard let output else {
            return nil
        }
        if marked.contains(output.uid) {
            return HeadphoneChoice(uid: output.uid, name: output.name, isMarked: true)
        }
        guard path == .blockedSpeakers, output.transport == .usb else {
            return nil
        }
        return HeadphoneChoice(uid: output.uid, name: output.name, isMarked: false)
    }
}

/// The Settings pane that grants capture of another application's audio.
///
/// The anchor is the one other audio apps open; Apple does not document it, so the fallback
/// opens the Privacy and Security root and the line above names the pane to choose.
enum AudioCaptureSettings {
    static let paneAnchor =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
    static let fallbackAnchor = "x-apple.systempreferences:com.apple.preference.security?Privacy"

    static var settingsURL: URL? {
        URL(string: paneAnchor) ?? URL(string: fallbackAnchor)
    }
}

/// The choice and headphone list the incoming path keeps between launches.
///
/// Both start empty, so a fresh install never taps another application's audio until the
/// person turns the menu item on.
struct IncomingPreferences {
    static let enabledKey = "RestoreOtherPersonEnabled"
    static let headphoneUIDsKey = "HeadphoneOutputUIDs"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    var headphoneUIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.headphoneUIDsKey) ?? []) }
        nonmutating set { defaults.set(newValue.sorted(), forKey: Self.headphoneUIDsKey) }
    }
}

struct MenuView: View {
    @Bindable var state: AppState
    var autoRoute = AutoRouteMenuStatus.default
    var permission = AudioPermission.authorized
    var incoming = IncomingMenuStatus.default
    var onAutoRouteToggle: @Sendable (Bool) -> Void = { _ in }
    var onRestoreOtherToggle: @Sendable (Bool) -> Void = { _ in }
    var onHeadphoneChoice: @Sendable (HeadphoneChoice) -> Void = { _ in }
    @Environment(\.openWindow) private var openWindow
    private let preferences = IncomingPreferences()

    var body: some View {
        Group {
            Text(Self.statusLine(engine: state.engine, incoming: state.incoming))
            Text(AppState.micPathText(state.micPath))
            if let tierNote = state.tierNote {
                Text(tierNote)
            }
            if let micError = state.micError {
                Text(micError.message)
                Text(micError.fix)
            }
            if state.driverNeedsSetup {
                Text(UserFacingError.driverOutdated.message)
                Text(UserFacingError.driverOutdated.fix)
            }
            if permission == .denied || permission == .restricted {
                Text(UserFacingError.permissionDenied("the microphone").message)
                Text(UserFacingError.permissionDenied("the microphone").fix)
            }
            Toggle(
                "Auto-route",
                isOn: Binding(
                    get: { autoRoute.isEnabled },
                    set: onAutoRouteToggle
                )
            )
            if let reason = autoRoute.reason {
                Text(reason)
            }
            Toggle("Also restore the other person", isOn: $state.restoreOther)
                .onChange(of: state.restoreOther) { _, enabled in
                    preferences.isEnabled = enabled
                    onRestoreOtherToggle(enabled)
                }
            ForEach(
                IncomingMenuStatus.lines(path: state.incoming, note: incoming.note),
                id: \.self
            ) { line in
                Text(line)
            }
            if let choice = state.headphoneChoice {
                Button(choice.title) {
                    onHeadphoneChoice(choice)
                }
            }
            if state.incoming == .permissionDenied {
                Button("Open System Settings") {
                    openAudioCaptureSettings()
                }
            }
            Divider()
            Button("Hear Yourself (F13)") {
                state.hearYourself()
                openWindow(id: HearYourselfView.windowID)
            }
            .keyboardShortcut(KeyEquivalent("\u{F70D}"), modifiers: [])
            Button("Monitor") {
                openWindow(id: MonitorWindow.windowID)
            }
            Button(state.isBypassed ? "Resume Restore" : "Bypass Restore") {
                state.toggleBypass()
            }
            .keyboardShortcut("h", modifiers: [.control, .option])
            Toggle("Open at Login", isOn: $state.openAtLogin)
                .onChange(of: state.openAtLogin) { _, enabled in
                    setOpenAtLogin(enabled)
                }
            if let loginError = state.loginError {
                Text(loginError.message)
                Text(loginError.fix)
            }
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .onAppear {
            state.openAtLogin = LoginAgent.isEnabled(paths: .current)
            state.restoreOther = preferences.isEnabled
        }
    }

    /// The engine line, unless another application is using the microphone now.
    static func statusLine(
        engine: AppState.EngineStatus,
        incoming: AppState.IncomingPath
    ) -> String {
        switch incoming {
        case .restoring(_, let name):
            return "Restoring for \(name)"
        case .blockedSpeakers:
            return "Incoming audio paused on speakers"
        case .off, .permissionDenied, .failed:
            return AppState.statusText(engine: engine, incoming: incoming)
        }
    }

    private func openAudioCaptureSettings() {
        guard let url = AudioCaptureSettings.settingsURL else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        do {
            try LoginAgent.setEnabled(enabled, paths: .current)
            state.loginError = nil
        } catch {
            state.loginError = .loginAgentFailed(String(describing: error))
        }
    }
}
