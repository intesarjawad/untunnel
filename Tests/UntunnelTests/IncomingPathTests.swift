import CoreAudio
import Foundation
import Synchronization
import Testing
import UntunnelAudio

@testable import Untunnel

private let zoomOutput = AudioProcessObject(
    objectID: 12,
    pid: 900,
    bundleID: "us.zoom.xos",
    name: "zoom.us",
    isRunningOutput: true
)
private let zoomInput = AudioProcessObject(
    objectID: 11,
    pid: 900,
    bundleID: "us.zoom.xos",
    name: "zoom.us",
    isRunningInput: true
)

final class FakeProcesses: AudioProcessObjectSource, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AudioProcessObject]
    private var listener: (@Sendable () -> Void)?

    init(_ processes: [AudioProcessObject]) {
        stored = processes
    }

    var processes: [AudioProcessObject] {
        lock.withLock { stored }
    }

    func observe(_ onChange: @escaping @Sendable () -> Void) -> any DeviceObservation {
        lock.withLock { listener = onChange }
        return Token()
    }

    func set(_ processes: [AudioProcessObject]) {
        let notify = lock.withLock { () -> (@Sendable () -> Void)? in
            stored = processes
            return listener
        }
        notify?()
    }
}

final class FakeTap: ProcessTapDevice, @unchecked Sendable {
    static let aggregateUID = "fake-aggregate"

    private let lock = NSLock()
    private var recordedStarts = 0
    private var recordedStops = 0
    private var failure: TapError?

    var starts: Int { lock.withLock { recordedStarts } }
    var stops: Int { lock.withLock { recordedStops } }

    func fail(with error: TapError?) {
        lock.withLock { failure = error }
    }

    func start(_ target: TapTarget, outputUID: String) throws -> String {
        try lock.withLock {
            if let failure {
                throw failure
            }
            recordedStarts += 1
        }
        return Self.aggregateUID
    }

    func stop() {
        lock.withLock { recordedStops += 1 }
    }
}

private let speakers = AudioDevice(
    uid: "built-in-speakers",
    name: "MacBook Speakers",
    transport: .builtIn,
    hasInput: false,
    hasOutput: true,
    nominalSampleRate: Double(tierRate),
    dataSource: .speakers
)

private func output(_ uid: String, _ name: String, _ transport: AudioTransport) -> AudioDevice {
    AudioDevice(
        uid: uid,
        name: name,
        transport: transport,
        hasInput: false,
        hasOutput: true,
        nominalSampleRate: Double(tierRate),
        dataSource: .none
    )
}

private let usbDac = output("usb-dac", "USB Headset", .usb)

/// A call that is engaged on a headset, with the toggle on and no virtual microphone installed,
/// so the fake hardware serves only the incoming path.
@MainActor
private func engagedCall(
    output: String? = "airpods",
    enabled: Bool = true,
    model: MicModel = .unavailable(.modelMissing)
) -> Harness {
    let harness = Harness(devices: [builtIn, airPods, speakers, usbDac], defaultOutput: output)
    harness.processes.set([zoomInput, zoomOutput])
    harness.controller.start(cleanExit: true)
    harness.controller.modelLoaded(model)
    if enabled {
        harness.controller.setRestoreOther(true)
    }
    harness.controller.apply(.restoring(client: "zoom.us"))
    return harness
}

@MainActor
private func settled(_ harness: Harness, _ condition: @escaping () -> Bool) async throws -> Bool {
    try await eventually(condition)
}

@Test
@MainActor
func theToggleStartsOffAndAnEngagedCallIsNotTapped() {
    let harness = engagedCall(enabled: false)

    #expect(harness.tap.starts == 0)
    #expect(harness.hardware.captureUIDs.isEmpty)
    #expect(harness.state.incoming == .off)
    #expect(!harness.state.restoreOther)
}

@Test
@MainActor
func aCallOnHeadphonesTapsTheAppAndPlaysTheRestoredAudioOnThem() async throws {
    let harness = engagedCall()

    let showing = try await settled(harness) {
        harness.state.incoming == .restoring(pid: 900, name: "zoom.us")
    }
    #expect(showing)
    #expect(harness.tap.starts == 1)
    #expect(harness.hardware.captureUIDs == [FakeTap.aggregateUID])
    #expect(harness.hardware.sinkUIDs == ["airpods"])
    #expect(harness.hardware.capture.isRunning)
    #expect(harness.hardware.sink.isRunning)
}

@Test
@MainActor
func theChoiceIsKeptForTheNextLaunch() {
    let harness = engagedCall()

    #expect(IncomingPreferences(defaults: harness.incomingDefaults).isEnabled)
    #expect(harness.state.restoreOther)

    harness.controller.setRestoreOther(false)

    #expect(!IncomingPreferences(defaults: harness.incomingDefaults).isEnabled)
    #expect(!harness.state.restoreOther)
}

@Test
@MainActor
func incomingOffStaysOffAcrossProcessAndOutputChanges() async throws {
    let harness = engagedCall()
    #expect(try await settled(harness) { harness.hardware.sink.isRunning })
    harness.controller.setRestoreOther(false)
    #expect(try await settled(harness) { harness.state.incoming == .off })
    let starts = harness.tap.starts
    harness.devices.change { $0.defaultOutputDeviceUID = "usb-dac" }
    harness.controller.setHeadphones(uid: "usb-dac", marked: true)
    harness.processes.set([zoomInput, zoomOutput])
    harness.controller.refresh()
    #expect(harness.tap.starts == starts)
    #expect(harness.tap.stops == 1)
    #expect(!harness.hardware.capture.isRunning)
    #expect(!harness.hardware.sink.isRunning)
    #expect(harness.state.incomingNote == nil)
    #expect(!harness.state.restoreOther)
}

@Test
@MainActor
func speakersAreRefusedBeforeAnythingIsTappedOrMuted() async throws {
    let harness = engagedCall(output: "built-in-speakers")

    let showing = try await settled(harness) { harness.state.incoming == .blockedSpeakers }
    #expect(showing)
    #expect(harness.tap.starts == 0)
    #expect(harness.hardware.captureUIDs.isEmpty)
}

@Test
@MainActor
func movingTheCallToSpeakersMidCallTearsDownAndHeadphonesBringItBack() async throws {
    let harness = engagedCall()
    _ = try await settled(harness) { harness.hardware.sink.isRunning }

    harness.devices.change { $0.defaultOutputDeviceUID = "built-in-speakers" }

    let paused = try await settled(harness) { harness.state.incoming == .blockedSpeakers }
    #expect(paused)
    #expect(harness.tap.stops == 1)
    #expect(harness.hardware.capture.stops == 1)
    #expect(harness.hardware.sink.stops == 1)
    #expect(!harness.hardware.sink.isRunning)

    harness.devices.change { $0.defaultOutputDeviceUID = "airpods" }

    let resumed = try await settled(harness) {
        harness.state.incoming == .restoring(pid: 900, name: "zoom.us")
    }
    #expect(resumed)
    #expect(harness.tap.starts == 2)
    #expect(harness.hardware.sink.isRunning)
}

@Test
@MainActor
func withoutAModelTheOtherPersonStillComesThroughRawNeverSilence() async throws {
    let harness = engagedCall()
    _ = try await settled(harness) { harness.hardware.capture.isRunning }
    var input: [Float] = []
    var output: [Float] = []

    for hop in 0..<60 {
        let samples = sine(hop: hop)
        input += samples
        harness.hardware.capture.deliver(samples)
        try await Task.sleep(for: .milliseconds(25))
        output += harness.hardware.sink.pull(hopFrames)
    }

    #expect(rms(output.suffix(20 * hopFrames)) > 0.8 * rms(input.suffix(20 * hopFrames)))
}

@Test
@MainActor
func aSessionThatCannotStartDestroysTheTapSoTheAppIsNotLeftMuted() async throws {
    let harness = Harness(devices: [builtIn, airPods, speakers])
    harness.processes.set([zoomInput, zoomOutput])
    harness.hardware.capture.startError = AudioCaptureError.unsupportedDevice
    harness.controller.start(cleanExit: true)
    harness.controller.setRestoreOther(true)

    harness.controller.apply(.restoring(client: "zoom.us"))

    let failed = try await settled(harness) {
        if case .failed = harness.state.incoming { return true }
        return false
    }
    #expect(failed)
    #expect(harness.tap.stops == 1)
    #expect(harness.hardware.sink.stops == 1)
    #expect(!harness.hardware.sink.isRunning)
}

@Test
@MainActor
func aRefusedPermissionIsShownAndStartsNothing() async throws {
    let harness = Harness(devices: [builtIn, airPods, speakers])
    harness.processes.set([zoomInput, zoomOutput])
    harness.tap.fail(with: .permissionDenied)
    harness.controller.start(cleanExit: true)
    harness.controller.setRestoreOther(true)

    harness.controller.apply(.restoring(client: "zoom.us"))

    let denied = try await settled(harness) { harness.state.incoming == .permissionDenied }
    #expect(denied)
    #expect(harness.hardware.captureUIDs.isEmpty)
}

@Test
@MainActor
func theCallEndingTurningTheToggleOffTheAppQuittingAndQuittingTheCallAppAllTearDown() async throws {
    let ends: [(String, (Harness) -> Void)] = [
        ("the call ends", { $0.controller.apply(.standby) }),
        ("the toggle goes off", { $0.controller.setRestoreOther(false) }),
        ("the app quits", { $0.controller.stop() }),
        ("the call app exits", { $0.processes.set([]) }),
    ]
    for (name, end) in ends {
        let harness = engagedCall()
        let running = try await settled(harness) { harness.hardware.sink.isRunning }
        #expect(running, "\(name)")

        end(harness)

        #expect(harness.tap.stops == 1, "\(name)")
        #expect(harness.hardware.capture.stops >= 1, "\(name)")
        #expect(!harness.hardware.sink.isRunning, "\(name)")
        let cleared = try await settled(harness) { harness.state.incoming == .off }
        #expect(cleared, "\(name)")
    }
}

@Test
@MainActor
func theMenuNamesTheHeadsetCallModeWhileTheTapRuns() async throws {
    let harness = engagedCall()
    _ = try await settled(harness) { harness.hardware.sink.isRunning }

    harness.controller.refresh()

    #expect(
        harness.state.incomingNote
            == "Your headset is in call mode (16 kHz): restoring clarity, not bandwidth"
    )
}

@Test
@MainActor
func everyTapOutcomeHasAMenuState() {
    let state = AppState()
    let expected: [(IncomingTapOutcome, AppState.IncomingPath)] = [
        (.tapping(pid: 7, name: "zoom.us"), .restoring(pid: 7, name: "zoom.us")),
        (.pausedOnSpeakers, .blockedSpeakers),
        (.permissionDenied, .permissionDenied),
        (.failed("no output"), .failed("no output")),
        (.off, .off),
    ]
    for (outcome, path) in expected {
        state.incomingChanged(outcome)
        #expect(state.incoming == path)
    }
    #expect(
        IncomingMenuStatus.lines(path: .failed("no output"), note: nil).last
            == "Turn \"Also restore the other person\" off and on to try again."
    )
}

@Test
@MainActor
func anUnknownUsbOutputOffersToBeMarkedAndMarkingStartsTheTap() async throws {
    let harness = engagedCall(output: "usb-dac")
    _ = try await settled(harness) { harness.state.incoming == .blockedSpeakers }
    harness.controller.refresh()

    let choice = try #require(harness.state.headphoneChoice)
    #expect(choice == HeadphoneChoice(uid: "usb-dac", name: "USB Headset", isMarked: false))
    #expect(harness.tap.starts == 0)

    harness.controller.setHeadphones(uid: choice.uid, marked: true)

    let tapping = try await settled(harness) {
        harness.state.incoming == .restoring(pid: 900, name: "zoom.us")
    }
    #expect(tapping)
    #expect(harness.tap.starts == 1)
    #expect(IncomingPreferences(defaults: harness.incomingDefaults).headphoneUIDs == ["usb-dac"])
    #expect(harness.state.headphoneChoice?.isMarked == true)
}

@Test
@MainActor
func unmarkingAnOutputStopsTheTapAndOffersTheMarkAgain() async throws {
    let harness = engagedCall(output: "usb-dac")
    harness.controller.setHeadphones(uid: "usb-dac", marked: true)
    _ = try await settled(harness) { harness.hardware.sink.isRunning }

    harness.controller.setHeadphones(uid: "usb-dac", marked: false)

    let paused = try await settled(harness) { harness.state.incoming == .blockedSpeakers }
    #expect(paused)
    #expect(harness.tap.stops == 1)
    #expect(IncomingPreferences(defaults: harness.incomingDefaults).headphoneUIDs.isEmpty)
    harness.controller.refresh()
    #expect(harness.state.headphoneChoice?.isMarked == false)
}

@Test
@MainActor
func speakersAreNeverOfferedAsHeadphones() async throws {
    let harness = engagedCall(output: "built-in-speakers")
    _ = try await settled(harness) { harness.state.incoming == .blockedSpeakers }
    harness.controller.refresh()

    #expect(harness.state.headphoneChoice == nil)
}

@Test
func onlyAUsbOutputThatIsRefusedCanBeMarked() {
    for transport in [AudioTransport.builtIn, .aggregate, .virtual, .other] {
        #expect(
            HeadphoneChoice.offer(
                output: output("x", "Display", transport),
                path: .blockedSpeakers,
                marked: []
            ) == nil)
    }
    #expect(
        HeadphoneChoice.offer(output: usbDac, path: .off, marked: []) == nil)
    #expect(
        HeadphoneChoice.offer(output: usbDac, path: .blockedSpeakers, marked: [])?.title
            == "Treat USB Headset as headphones")
    #expect(
        HeadphoneChoice.offer(output: usbDac, path: .off, marked: ["usb-dac"])?.title
            == "USB Headset is not headphones")
}
