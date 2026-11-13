import Foundation
import Testing
import UntunnelAudio

@testable import Untunnel

private let headsetUID = "bluetooth-headset"
private let previousUID = "built-in"

private final class RouteFakeSource: DeviceSource, @unchecked Sendable {
    private let lock = NSLock()
    private var storedDevices: [AudioDevice]
    private var storedDefaultInput: String?

    init(devices: [AudioDevice] = [], defaultInputUID: String? = nil) {
        storedDevices = devices
        storedDefaultInput = defaultInputUID
    }

    var devices: [AudioDevice] {
        lock.withLock { storedDevices }
    }

    var defaultInputDeviceUID: String? {
        lock.withLock { storedDefaultInput }
    }

    var defaultOutputDeviceUID: String? {
        nil
    }

    func observe(
        _ onChange: @escaping @Sendable () -> Void
    ) -> any DeviceObservation {
        _ = onChange
        return EmptyObservation()
    }
}

private final class EmptyObservation: DeviceObservation {
    func cancel() {}
}

private final class FakeDefaultInput: DefaultInputSetter, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var applied: [String] {
        lock.withLock { stored }
    }

    func setDefaultInput(uid: String) -> Bool {
        lock.withLock { stored.append(uid) }
        return true
    }
}

private func device(_ uid: String, transport: AudioTransport) -> AudioDevice {
    AudioDevice(
        uid: uid,
        name: uid,
        transport: transport,
        hasInput: true,
        hasOutput: false,
        nominalSampleRate: 48_000,
        dataSource: .none
    )
}

private func launch(
    cleanExit: Bool = false,
    permission: AudioPermission = .authorized,
    connected: Set<String> = [headsetUID, previousUID],
    currentDefault: String? = headsetUID,
    sourceHeadset: String? = headsetUID,
    previousDefault: String? = previousUID,
    enabled: Bool = true
) -> AutoRouteLaunch {
    AutoRouteLaunch(
        cleanExit: cleanExit,
        permission: permission,
        connectedUIDs: connected,
        currentDefaultUID: currentDefault,
        sourceHeadsetUID: sourceHeadset,
        previousDefaultUID: previousDefault,
        autoRouteEnabled: enabled
    )
}

@Test
func aDeviceAppearingDoesNotChangeTheDefaultByItself() {
    var route = AutoRoute()

    let decision = route.handle(
        .deviceAppeared(uid: headsetUID, transport: .bluetooth, at: 10)
    )

    #expect(decision.defaultInputUID == nil)
    #expect(route.isEngaged == false)
}

@Test
func aDefaultChangeTwoPointNineSecondsAfterTheConnectIsAutomatic() {
    var route = AutoRoute()
    _ = route.handle(.deviceAppeared(uid: headsetUID, transport: .bluetooth, at: 10))

    let decision = route.handle(.defaultInputChanged(uid: headsetUID, at: 12.9))

    #expect(decision.defaultInputUID == AutoRoute.virtualInputUID)
    #expect(route.isEngaged)
}

@Test
func aDefaultChangeThreePointOneSecondsAfterTheConnectIsThePersonsChoice() {
    var route = AutoRoute()
    _ = route.handle(.deviceAppeared(uid: headsetUID, transport: .bluetooth, at: 10))

    let decision = route.handle(.defaultInputChanged(uid: headsetUID, at: 13.1))

    #expect(decision.defaultInputUID == nil)
    #expect(route.isEngaged == false)
}

@Test
func aHeadsetChosenByHandWhileConnectedIsNeverOverridden() {
    var route = AutoRoute()
    _ = route.handle(.deviceAppeared(uid: headsetUID, transport: .bluetooth, at: 10))
    _ = route.handle(.defaultInputChanged(uid: headsetUID, at: 11))
    #expect(route.isEngaged)

    let chosen = route.handle(.defaultInputChanged(uid: previousUID, at: 20))
    #expect(chosen.defaultInputUID == nil)

    let again = route.handle(.defaultInputChanged(uid: headsetUID, at: 21))
    #expect(again.defaultInputUID == nil)
    #expect(route.isEngaged == false)
}

@Test
func aDisconnectedHeadsetEndsTheRoute() {
    var route = AutoRoute()
    _ = route.handle(.deviceAppeared(uid: headsetUID, transport: .bluetooth, at: 10))
    _ = route.handle(.defaultInputChanged(uid: headsetUID, at: 11))

    let decision = route.handle(.headsetDisconnected(uid: headsetUID, at: 20))

    #expect(decision.defaultInputUID == nil)
    #expect(route.isEngaged == false)
}

@Test
func turningAutoRouteOffEndsItUntilTheNextConnect() {
    var route = AutoRoute()
    _ = route.handle(.deviceAppeared(uid: headsetUID, transport: .bluetooth, at: 10))
    _ = route.handle(.defaultInputChanged(uid: headsetUID, at: 11))

    #expect(route.handle(.toggle(enabled: false, at: 12)).isEngaged == false)
    #expect(
        route.handle(.defaultInputChanged(uid: headsetUID, at: 13)).defaultInputUID == nil
    )

    _ = route.handle(.toggle(enabled: true, at: 14))
    _ = route.handle(.deviceAppeared(uid: headsetUID, transport: .bluetooth, at: 20))
    #expect(
        route.handle(.defaultInputChanged(uid: headsetUID, at: 21)).defaultInputUID
            == AutoRoute.virtualInputUID
    )
}

@Test
func quittingRestoresThePreviousDefaultAndMarksACleanExit() {
    var route = AutoRoute()
    _ = route.handle(
        .launch(
            launch(
                cleanExit: true,
                currentDefault: previousUID,
                sourceHeadset: nil,
                previousDefault: nil
            )
        )
    )
    _ = route.handle(.deviceAppeared(uid: headsetUID, transport: .bluetooth, at: 10))
    _ = route.handle(.defaultInputChanged(uid: headsetUID, at: 11))

    let decision = route.handle(.quit(at: 20))

    #expect(decision.defaultInputUID == previousUID)
    #expect(decision.isEngaged == false)
    #expect(route.cleanExit)
}

@Test
func anUncleanLaunchReassertsWhenTheHeadsetIsStillTheDefault() {
    var route = AutoRoute()

    let decision = route.handle(.launch(launch(cleanExit: false, currentDefault: headsetUID)))

    #expect(decision.defaultInputUID == AutoRoute.virtualInputUID)
    #expect(route.isEngaged)
}

@Test
func anUncleanLaunchReassertsWhenTheDefaultFellBackToTheStoredOne() {
    var route = AutoRoute()

    let decision = route.handle(.launch(launch(cleanExit: false, currentDefault: previousUID)))

    #expect(decision.defaultInputUID == AutoRoute.virtualInputUID)
}

@Test
func anUncleanLaunchLeavesTheDefaultAloneWhenTheHeadsetIsGone() {
    var route = AutoRoute()

    let decision = route.handle(
        .launch(launch(cleanExit: false, connected: [previousUID], currentDefault: previousUID))
    )

    #expect(decision.defaultInputUID == nil)
    #expect(route.isEngaged == false)
}

@Test
func anUncleanLaunchLeavesAnUnrelatedDefaultAlone() {
    var route = AutoRoute()

    let decision = route.handle(.launch(launch(cleanExit: false, currentDefault: "usb-mic")))

    #expect(decision.defaultInputUID == nil)
    #expect(route.isEngaged == false)
}

@Test
func aCleanLaunchLeavesTheDefaultAlone() {
    var route = AutoRoute()

    let decision = route.handle(.launch(launch(cleanExit: true, currentDefault: headsetUID)))

    #expect(decision.defaultInputUID == nil)
    #expect(route.isEngaged == false)
}

@Test
func aDefaultChangeToTheVirtualMicrophoneKeepsTheRoute() {
    var route = AutoRoute()
    _ = route.handle(.deviceAppeared(uid: headsetUID, transport: .bluetooth, at: 10))
    _ = route.handle(.defaultInputChanged(uid: headsetUID, at: 11))

    let decision = route.handle(
        .defaultInputChanged(uid: AutoRoute.virtualInputUID, at: 12)
    )

    #expect(decision.defaultInputUID == nil)
    #expect(route.isEngaged)
}

@Test
func notDeterminedPermissionAsksForThePromptAndKeepsRoutingOff() {
    var route = AutoRoute()

    let decision = route.handle(.launch(launch(permission: .notDetermined)))

    #expect(decision.requestPermission)
    #expect(decision.showsPermissionLine == false)
    #expect(decision.isEngaged == false)
}

@Test
func deniedPermissionShowsTheLineAndTurnsRoutingOff() {
    var route = AutoRoute()
    let decision = route.handle(.permissionChanged(.denied, at: 10))

    #expect(decision.requestPermission == false)
    #expect(decision.showsPermissionLine)
    #expect(decision.isAuthorized == false)

    _ = route.handle(.deviceAppeared(uid: headsetUID, transport: .bluetooth, at: 11))
    #expect(
        route.handle(.defaultInputChanged(uid: headsetUID, at: 12)).defaultInputUID == nil
    )
}

@Test
func wakingWithAnUndecidedPermissionAsksForThePrompt() {
    var route = AutoRoute()

    let decision = route.handle(.wake(.notDetermined))

    #expect(decision.requestPermission)
    #expect(decision.showsPermissionLine == false)
}

@Test
func theShellAppliesTheRouteAndKeepsTheRelaunchState() throws {
    let suite = "AutoRouteTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
    }
    let store = AutoRouteStore(defaults: defaults)
    store.save(cleanExit: false, sourceHeadsetUID: headsetUID, previousDefaultUID: previousUID)
    let setter = FakeDefaultInput()
    let source = RouteFakeSource(
        devices: [device(headsetUID, transport: .bluetooth)],
        defaultInputUID: headsetUID
    )
    let shell = AutoRouteShell(setter: setter, store: store)

    let decision = shell.launch(cleanExit: false, permission: .authorized, source: source)

    #expect(decision.defaultInputUID == AutoRoute.virtualInputUID)
    #expect(setter.applied == [AutoRoute.virtualInputUID])
    #expect(store.sourceHeadsetUID == headsetUID)
    #expect(store.previousDefaultUID == previousUID)
    #expect(store.cleanExit == false)
}

@Test
func aDifferentPlugInVersionIsOutdated() {
    #expect(DriverVersion.isOutdated(installed: "1.0", bundled: "2.0"))
    #expect(DriverVersion.isOutdated(installed: "2.0", bundled: "1.0"))
    #expect(DriverVersion.isOutdated(installed: "1.0", bundled: "1.0") == false)
    #expect(DriverVersion.isOutdated(installed: nil, bundled: "1.0") == false)
    #expect(UserFacingError.driverOutdated == .driverVersionChanged)
}
