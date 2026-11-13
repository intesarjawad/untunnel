import CoreAudio
import Foundation
import Testing

@testable import UntunnelAudio

/// The calling application: one process reads the microphone, another plays the call.
private let zoomReader = AudioProcessObject(
    objectID: 11,
    pid: 900,
    bundleID: "us.zoom.xos",
    name: "zoom.us",
    isRunningInput: true
)
private let zoomPlayer = AudioProcessObject(
    objectID: 12,
    pid: 900,
    bundleID: "us.zoom.xos",
    name: "zoom.us",
    isRunningOutput: true
)

/// A call in Chrome reads and plays from the browser's helper process.
private let chromeReader = AudioProcessObject(
    objectID: 21,
    pid: 300,
    bundleID: "com.google.Chrome.helper",
    name: "Google Chrome Helper",
    isRunningInput: true
)
private let chromePlayer = AudioProcessObject(
    objectID: 22,
    pid: 301,
    bundleID: "com.google.Chrome.helper",
    name: "Google Chrome Helper (Audio)",
    isRunningOutput: true
)

private let airPods = device(
    "airpods",
    transport: .bluetooth,
    nominalSampleRate: 48_000
)
private let speakers = device(
    "built-in-speakers",
    transport: .builtIn,
    nominalSampleRate: 48_000,
    dataSource: .speakers
)
private let headphoneJack = device(
    "built-in-headphones",
    transport: .builtIn,
    nominalSampleRate: 48_000,
    dataSource: .headphones
)

@Suite
struct IncomingTapTests {
    @Test
    func aClientOnTheVirtualMicTapsItsOutputProcesses() {
        let rig = makeRig(processes: [zoomReader, zoomPlayer], isEnabled: true)

        rig.engine.handle(.restoring(client: "zoom.us"))

        #expect(rig.tapDevice.starts.count == 1)
        #expect(rig.tapDevice.starts.first?.target.processObjectIDs == [12])
        #expect(rig.tapDevice.starts.first?.outputUID == "airpods")
        #expect(rig.engine.outcome == .tapping(pid: 900, name: "zoom.us"))
    }

    @Test
    func releasingTheMicrophonePathTearsTheTapDown() {
        let rig = makeRig(processes: [zoomReader, zoomPlayer], isEnabled: true)
        rig.engine.handle(.restoring(client: "zoom.us"))

        rig.engine.handle(.standby)

        #expect(rig.tapDevice.stops == 1)
        #expect(rig.engine.outcome == .off)
    }

    @Test
    func theToggleOffNeverTaps() {
        let rig = makeRig(processes: [zoomReader, zoomPlayer], isEnabled: false)

        rig.engine.handle(.restoring(client: "zoom.us"))

        #expect(rig.tapDevice.starts.isEmpty)
        #expect(rig.tapDevice.stops == 0)
        #expect(rig.engine.outcome == .off)
    }

    @Test
    func turningTheToggleOffTearsARunningTapDown() {
        let rig = makeRig(processes: [zoomReader, zoomPlayer], isEnabled: true)
        rig.engine.handle(.restoring(client: "zoom.us"))

        rig.engine.update(IncomingTap.Settings(isEnabled: false))

        #expect(rig.tapDevice.stops == 1)
        #expect(rig.engine.outcome == .off)
    }

    @Test
    func theTappedProcessQuittingTearsTheTapDown() {
        let rig = makeRig(processes: [zoomReader, zoomPlayer], isEnabled: true)
        rig.engine.handle(.restoring(client: "zoom.us"))

        rig.processes.exit(pid: 900)

        #expect(rig.tapDevice.stops == 1)
        #expect(rig.engine.outcome == .off)
    }

    @Test
    func stoppingTheEngineTearsTheTapDownAndStopsWatchingProcesses() {
        let rig = makeRig(processes: [zoomReader, zoomPlayer], isEnabled: true)
        rig.engine.handle(.restoring(client: "zoom.us"))
        #expect(rig.processes.isObserved)

        rig.engine.stop()

        #expect(rig.tapDevice.stops == 1)
        #expect(!rig.processes.isObserved)
        #expect(rig.engine.outcome == .off)
    }

    @Test
    func aBrowserCallTapsItsOutputHelper() {
        let rig = makeRig(processes: [chromeReader, chromePlayer], isEnabled: true)

        rig.engine.handle(.restoring(client: "Google Chrome Helper"))

        #expect(rig.tapDevice.starts.first?.target.processObjectIDs == [22])
        #expect(rig.tapDevice.starts.first?.target.isSharedHelper == true)
        #expect(rig.tapDevice.starts.first?.target.note == "Mutes all audio from Google Chrome")
        #expect(rig.engine.outcome == .tapping(pid: 301, name: "Google Chrome"))
    }

    @Test
    func anAppWithoutOutputProcessesIsNotTapped() {
        let rig = makeRig(processes: [zoomReader], isEnabled: true)

        rig.engine.handle(.restoring(client: "zoom.us"))

        #expect(rig.tapDevice.starts.isEmpty)
        #expect(rig.engine.outcome == .off)
    }

    @Test
    func movingTheCallToSpeakersPausesAndHeadphonesBringItBack() {
        let rig = makeRig(processes: [zoomReader, zoomPlayer], isEnabled: true)
        rig.engine.handle(.restoring(client: "zoom.us"))

        rig.source.setDefaultOutput("built-in-speakers")

        #expect(rig.tapDevice.stops == 1)
        #expect(rig.engine.outcome == .pausedOnSpeakers)

        rig.source.setDefaultOutput("airpods")

        #expect(rig.tapDevice.starts.count == 2)
        #expect(rig.engine.outcome == .tapping(pid: 900, name: "zoom.us"))
    }

    @Test
    func aRefusedPermissionIsReportedAndLeavesNothingRunning() {
        let rig = makeRig(
            processes: [zoomReader, zoomPlayer],
            isEnabled: true,
            failure: .permissionDenied
        )

        rig.engine.handle(.restoring(client: "zoom.us"))

        #expect(rig.engine.outcome == .permissionDenied)
        #expect(rig.tapDevice.stops == 0)
    }

    @Test
    func aTapThatCannotPlayBackIsReportedWithItsReason() {
        let rig = makeRig(
            processes: [zoomReader, zoomPlayer],
            isEnabled: true,
            failure: .playbackFailed("no output")
        )

        rig.engine.handle(.restoring(client: "zoom.us"))

        #expect(
            rig.engine.outcome == .failed("the restored audio could not be played: no output")
        )
    }

    @Test
    func aMeasurementOverrideAllowsOneLoopbackOutput() {
        let loopback = device(
            "loopback-output",
            transport: .virtual,
            nominalSampleRate: 48_000
        )
        let rig = makeRig(
            processes: [zoomReader, zoomPlayer],
            isEnabled: true,
            output: loopback,
            settings: IncomingTap.Settings(
                isEnabled: true,
                environment: [IncomingTap.Settings.allowOutputKey: "loopback-output"]
            )
        )

        rig.engine.handle(.restoring(client: "zoom.us"))

        #expect(rig.tapDevice.starts.first?.outputUID == "loopback-output")
    }

    @Test
    func theTapNamesWhatItMutesAndSaysWhenTheHeadsetIsInCallMode() {
        let browser = makeRig(processes: [chromeReader, chromePlayer], isEnabled: true)
        #expect(browser.engine.note == nil)

        browser.engine.handle(.restoring(client: "Google Chrome Helper"))
        #expect(browser.engine.note == "Mutes all audio from Google Chrome")

        let callMode = makeRig(
            processes: [zoomReader, zoomPlayer],
            isEnabled: true,
            output: device("airpods-call", transport: .bluetooth, nominalSampleRate: 16_000)
        )
        callMode.engine.handle(.restoring(client: "zoom.us"))

        #expect(
            callMode.engine.note
                == "Your headset is in call mode (16 kHz): restoring clarity, not bandwidth"
        )
    }

    @Test
    func theSameTargetIsNotRestartedOnEveryChange() {
        let rig = makeRig(processes: [zoomReader, zoomPlayer], isEnabled: true)
        rig.engine.handle(.restoring(client: "zoom.us"))

        rig.engine.handle(.restoring(client: "zoom.us"))
        rig.engine.refresh()

        #expect(rig.tapDevice.starts.count == 1)
    }
}

@Suite
struct HeadphoneGuardTests {
    @Test
    func bluetoothAndTheBuiltInJackAreHeadphones() {
        #expect(HeadphoneGuard.allows(airPods, headphones: [], allowedOutputUID: nil))
        #expect(HeadphoneGuard.allows(headphoneJack, headphones: [], allowedOutputUID: nil))
    }

    @Test
    func speakersAreRefused() {
        #expect(!HeadphoneGuard.allows(speakers, headphones: [], allowedOutputUID: nil))
        #expect(!HeadphoneGuard.allows(nil, headphones: [], allowedOutputUID: nil))
    }

    @Test
    func aListedDeviceCountsAsHeadphones() {
        let usb = device("usb-dac", transport: .usb, nominalSampleRate: 48_000)

        #expect(!HeadphoneGuard.allows(usb, headphones: [], allowedOutputUID: nil))
        #expect(HeadphoneGuard.allows(usb, headphones: ["usb-dac"], allowedOutputUID: nil))
    }

    @Test
    func theMeasurementOverrideAllowsOnlyItsOwnDevice() {
        let usb = device("usb-dac", transport: .usb, nominalSampleRate: 48_000)

        #expect(HeadphoneGuard.allows(usb, headphones: [], allowedOutputUID: "usb-dac"))
        #expect(!HeadphoneGuard.allows(usb, headphones: [], allowedOutputUID: "other-dac"))
    }
}

@Suite
struct HeadsetCallModeTests {
    @Test
    func aFullRateOutputHasNoNote() {
        #expect(HeadsetCallMode.note(rateHz: 48_000) == nil)
        #expect(HeadsetCallMode.note(rateHz: nil) == nil)
    }

    @Test
    func aNarrowbandOutputSaysWhatRestorationCanDo() {
        #expect(
            HeadsetCallMode.note(rateHz: 16_000)
                == "Your headset is in call mode (16 kHz): restoring clarity, not bandwidth"
        )
        #expect(
            HeadsetCallMode.note(rateHz: 8_000)
                == "Your headset is in call mode (8 kHz): restoring clarity, not bandwidth"
        )
        #expect(HeadsetCallMode.note(rateHz: 24_000) == nil)
    }
}

@Suite
struct ProcessTapAggregateTests {
    @Test
    func theAggregateIsThePrivateTapDevice() {
        let description = CoreAudioProcessTap.aggregateDescription(
            tapUID: "tap-uid",
            aggregateUID: "aggregate-uid"
        )

        #expect(description[kAudioAggregateDeviceNameKey as String] as? String == "Untunnel Tap")
        #expect(description[kAudioAggregateDeviceIsPrivateKey as String] as? Bool == true)
        #expect(description[kAudioAggregateDeviceTapAutoStartKey as String] as? Bool == true)
        let taps = description[kAudioAggregateDeviceTapListKey as String] as? [[String: Any]]
        #expect(taps?.count == 1)
        #expect(taps?.first?[kAudioSubTapUIDKey as String] as? String == "tap-uid")
        #expect(description[kAudioAggregateDeviceUIDKey as String] as? String == "aggregate-uid")
    }
}

@Suite
struct ProcessTapDescriptionTests {
    @Test
    func theTapIsPrivateAndMutesTheAppWhileItIsRead() {
        let target = TapTarget(
            appBundleID: "us.zoom.xos",
            name: "zoom.us",
            processes: [zoomPlayer],
            isSharedHelper: false
        )

        let description = CoreAudioProcessTap.description(of: target)

        #expect(description.muteBehavior == .mutedWhenTapped)
        #expect(description.isPrivate)
        #expect(description.processes == [12])
    }
}

@Suite
struct StrayTapSweepTests {
    @Test
    func onlyDevicesNamedLikeTheTapAreStrays() {
        let devices: [(id: AudioObjectID, name: String)] = [
            (id: 40, name: "MacBook Pro Speakers"),
            (id: 41, name: "Untunnel Tap"),
            (id: 42, name: "Untunnel Microphone"),
            (id: 43, name: "Untunnel Tap"),
        ]

        #expect(StrayTapSweep.strays(in: devices) == [41, 43])
    }

    @Test
    func aCleanDeviceListHasNoStrays() {
        #expect(StrayTapSweep.strays(in: []).isEmpty)
    }
}

private struct Rig {
    let engine: IncomingTap
    let tapDevice: FakeTapDevice
    let source: RecordingDeviceSource
    let processes: FakeProcessObjects
}

private func makeRig(
    processes: [AudioProcessObject],
    isEnabled: Bool,
    output: AudioDevice = airPods,
    settings: IncomingTap.Settings? = nil,
    failure: TapError? = nil
) -> Rig {
    let source = RecordingDeviceSource(
        devices: [output, speakers, headphoneJack],
        defaultOutputUID: output.uid
    )
    let devices = AudioDevices(source: source, environment: [:])
    let tapDevice = FakeTapDevice(failure: failure)
    let processObjects = FakeProcessObjects(processes)
    let engine = IncomingTap(
        processes: processObjects,
        devices: devices,
        tap: tapDevice,
        settings: settings ?? IncomingTap.Settings(isEnabled: isEnabled)
    )
    engine.start()
    return Rig(engine: engine, tapDevice: tapDevice, source: source, processes: processObjects)
}

private func device(
    _ uid: String,
    transport: AudioTransport,
    nominalSampleRate: Double,
    dataSource: AudioDataSource = .none
) -> AudioDevice {
    AudioDevice(
        uid: uid,
        name: "Fixture \(uid)",
        transport: transport,
        hasInput: false,
        hasOutput: true,
        nominalSampleRate: nominalSampleRate,
        dataSource: dataSource
    )
}

private final class FakeProcessObjects: AudioProcessObjectSource, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AudioProcessObject]
    private var listener: (@Sendable () -> Void)?

    init(_ processes: [AudioProcessObject]) {
        stored = processes
    }

    var processes: [AudioProcessObject] {
        lock.withLock { stored }
    }

    var isObserved: Bool {
        lock.withLock { listener != nil }
    }

    func observe(_ onChange: @escaping @Sendable () -> Void) -> any DeviceObservation {
        lock.withLock { listener = onChange }
        return RecordingObservation { [weak self] in
            guard let self else {
                return
            }
            self.lock.withLock { self.listener = nil }
        }
    }

    func exit(pid: pid_t) {
        let notify = lock.withLock { () -> (@Sendable () -> Void)? in
            stored.removeAll { $0.pid == pid }
            return listener
        }
        notify?()
    }
}

private final class FakeTapDevice: ProcessTapDevice, @unchecked Sendable {
    struct Start: Sendable {
        let target: TapTarget
        let outputUID: String
    }

    private let lock = NSLock()
    private let failure: TapError?
    private var recordedStarts: [Start] = []
    private var recordedStops = 0

    init(failure: TapError? = nil) {
        self.failure = failure
    }

    var starts: [Start] {
        lock.withLock { recordedStarts }
    }

    var stops: Int {
        lock.withLock { recordedStops }
    }

    func start(_ target: TapTarget, outputUID: String) throws -> String {
        if let failure {
            throw failure
        }
        lock.withLock { recordedStarts.append(Start(target: target, outputUID: outputUID)) }
        return "fake-aggregate"
    }

    func stop() {
        lock.withLock { recordedStops += 1 }
    }
}
