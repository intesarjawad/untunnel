import Carbon.HIToolbox
import Foundation
import Testing
import UntunnelEngine

@testable import Untunnel

private func temporaryPaths() -> InstalledPaths {
    InstalledPaths(
        home: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
    )
}

@Test
func hotkeyRegistrationReturnsNoErr() {
    let hotkey = GlobalHotkey()

    #expect(hotkey.register({}) == noErr)

    hotkey.unregister()
}

@Test
func loginAgentHoldsOnlyTheFourDocumentedKeys() throws {
    let paths = temporaryPaths()
    defer {
        try? FileManager.default.removeItem(at: paths.home)
    }

    try LoginAgent.write(paths: paths)

    let data = try Data(contentsOf: paths.loginAgent)
    let values = try #require(
        try PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any]
    )
    #expect(
        Set(values.keys) == [
            "Label", "ProgramArguments", "RunAtLoad", "LimitLoadToSessionType",
        ])
    #expect(values["Label"] as? String == "com.intesarjawad.untunnel")
    #expect(
        values["ProgramArguments"] as? [String]
            == ["\(paths.home.path)/Applications/Untunnel.app/Contents/MacOS/Untunnel"]
    )
    #expect(values["RunAtLoad"] as? Bool == true)
    #expect(values["LimitLoadToSessionType"] as? String == "Aqua")
}

@Test
func loginAgentReconcileRepairsAStaleProgramPath() throws {
    let paths = temporaryPaths()
    defer {
        try? FileManager.default.removeItem(at: paths.home)
    }
    try LoginAgent.write(paths: paths, program: "/old/Untunnel.app/Contents/MacOS/Untunnel")

    LoginAgent.reconcile(paths: paths)

    #expect(LoginAgent.programArgument(paths: paths) == LoginAgent.program(for: paths))
}

@Test
func loginAgentCanBeTurnedOff() throws {
    let paths = temporaryPaths()
    defer {
        try? FileManager.default.removeItem(at: paths.home)
    }
    try LoginAgent.setEnabled(true, paths: paths)
    #expect(LoginAgent.isEnabled(paths: paths))

    try LoginAgent.setEnabled(false, paths: paths)

    #expect(LoginAgent.isEnabled(paths: paths) == false)
}

@MainActor
@Test
func bypassRemembersTheMicrophonePathItReplaced() {
    let state = AppState()
    state.micPath = .restoring(Tier(sampleRate: 48_000, exitLayer: 7, lookAhead: 1))

    state.toggleBypass()

    #expect(state.isBypassed)
    #expect(state.micPath == .bypass)

    state.toggleBypass()

    #expect(state.isBypassed == false)
    #expect(
        state.micPath == .restoring(Tier(sampleRate: 48_000, exitLayer: 7, lookAhead: 1))
    )
}

@Test
func updateCheckRelaunchesOnlyFromStandbyAndOnlyOncePerMinute() {
    let app = URL(fileURLWithPath: "/Users/example/Applications/Untunnel.app")
    var spawned: [URL] = []
    var exits: [Int32] = []
    var runner = UpdateRunner(
        watcher: UpdateWatcher(
            app: app,
            currentBundleVersion: "1",
            driverVersion: "1"
        ),
        spawn: { url in
            spawned.append(url)
            return true
        },
        exit: { status in
            exits.append(status)
        }
    )
    let newer = InstalledVersionSnapshot(bundle: "2", driver: "1")

    #expect(
        runner.tick(
            now: 0,
            micPath: .restoring(Tier(sampleRate: 48_000, exitLayer: 7, lookAhead: 1)),
            versions: newer
        ) == .none
    )
    #expect(
        runner.tick(
            now: 70,
            micPath: .waiting(deviceName: "AirPods Pro"),
            versions: newer
        ) == .none
    )
    #expect(spawned.isEmpty)

    #expect(runner.tick(now: 140, micPath: .standby, versions: newer) == .relaunch(app: app))
    #expect(spawned == [app])
    #expect(exits == [0])
    #expect(
        Relaunch.arguments(for: app)
            == [
                "/bin/sh",
                "-c",
                "sleep 1; exec /usr/bin/open -n \"$1\"",
                "sh",
                app.path,
            ]
    )

    #expect(runner.tick(now: 141, micPath: .standby, versions: newer) == .none)
    #expect(spawned.count == 1)
}

@Test
func updateCheckReportsAChangedDriverVersion() {
    var watcher = UpdateWatcher(
        app: URL(fileURLWithPath: "/Users/example/Applications/Untunnel.app"),
        currentBundleVersion: "1",
        driverVersion: "1"
    )

    #expect(
        watcher.check(
            now: 0,
            micPath: .standby,
            versions: InstalledVersionSnapshot(bundle: "1", driver: "2")
        ) == .recheckDriver
    )
}

@Test
func theIncomingToggleStartsOffAndKeepsItsChoice() throws {
    let name = "RestoreOtherPerson.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer {
        defaults.removePersistentDomain(forName: name)
    }
    let preferences = IncomingPreferences(defaults: defaults)

    #expect(preferences.isEnabled == false)
    #expect(preferences.headphoneUIDs.isEmpty)

    preferences.isEnabled = true
    preferences.headphoneUIDs = ["usb-dac", "airpods"]
    let reopened = IncomingPreferences(defaults: defaults)

    #expect(reopened.isEnabled)
    #expect(reopened.headphoneUIDs == ["usb-dac", "airpods"])
}

@Test
func theMenuSaysWhenIncomingAudioPausedOnSpeakers() {
    #expect(IncomingMenuStatus.lines(path: .off, note: nil).isEmpty)
    #expect(IncomingMenuStatus.lines(path: .blockedSpeakers, note: nil) == ["Paused on speakers"])
}

@Test
func theMenuShowsTheNoteOfTheRunningTap() {
    #expect(
        IncomingMenuStatus.lines(
            path: .restoring(pid: 900, name: "zoom.us"),
            note: "Mutes all audio from Safari"
        ) == ["Mutes all audio from Safari"]
    )
}

@Test
func aDeniedCapturePermissionNamesThePaneToChoose() {
    let lines = IncomingMenuStatus.lines(path: .permissionDenied, note: nil)

    #expect(
        lines == [
            "Untunnel needs permission to capture the other person's audio.",
            "Choose System Audio Recording in Privacy & Security.",
        ])
    #expect(AudioCaptureSettings.settingsURL?.scheme == "x-apple.systempreferences")
    #expect(
        AudioCaptureSettings.settingsURL?.absoluteString.contains("Privacy_AudioCapture") == true
    )
}

@MainActor
@Test
func theStatusLineNamesTheProcessReadingTheMicrophone() {
    #expect(
        MenuView.statusLine(
            engine: .ready(Tier(sampleRate: 48_000, exitLayer: 7, lookAhead: 1)),
            incoming: .restoring(pid: 900, name: "zoom.us")
        ) == "Restoring for zoom.us"
    )
    #expect(
        MenuView.statusLine(engine: .loading, incoming: .off) == "Starting the restore engine"
    )
}
