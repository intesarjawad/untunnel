import Foundation
import Testing

@testable import UntunnelAudio

final class RecordingDeviceSource: DeviceSource, @unchecked Sendable {
    private let lock = NSLock()
    private var storedDevices: [AudioDevice]
    private var storedDefaultInput: String?
    private var storedDefaultOutput: String?
    private var listener: (@Sendable () -> Void)?

    init(
        devices: [AudioDevice] = [],
        defaultInputUID: String? = nil,
        defaultOutputUID: String? = nil
    ) {
        storedDevices = devices
        storedDefaultInput = defaultInputUID
        storedDefaultOutput = defaultOutputUID
    }

    var devices: [AudioDevice] {
        lock.withLock { storedDevices }
    }

    var defaultInputDeviceUID: String? {
        lock.withLock { storedDefaultInput }
    }

    var defaultOutputDeviceUID: String? {
        lock.withLock { storedDefaultOutput }
    }

    func observe(
        _ onChange: @escaping @Sendable () -> Void
    ) -> any DeviceObservation {
        lock.withLock { listener = onChange }
        return RecordingObservation { [weak self] in
            guard let self else {
                return
            }
            self.lock.withLock { self.listener = nil }
        }
    }

    func add(_ device: AudioDevice) {
        lock.withLock { storedDevices.append(device) }
        notify()
    }

    func remove(uid: String) {
        lock.withLock { storedDevices.removeAll { $0.uid == uid } }
        notify()
    }

    func rename(uid: String, to name: String) {
        lock.withLock {
            storedDevices = storedDevices.map { device in
                guard device.uid == uid else {
                    return device
                }
                return AudioDevice(
                    uid: device.uid,
                    name: name,
                    transport: device.transport,
                    hasInput: device.hasInput,
                    hasOutput: device.hasOutput,
                    nominalSampleRate: device.nominalSampleRate,
                    dataSource: device.dataSource
                )
            }
        }
        notify()
    }

    func setDefaultInput(_ uid: String?) {
        lock.withLock { storedDefaultInput = uid }
        notify()
    }

    func setDefaultOutput(_ uid: String?) {
        lock.withLock { storedDefaultOutput = uid }
        notify()
    }

    private func notify() {
        let callback = lock.withLock { listener }
        callback?()
    }
}

final class RecordingObservation: DeviceObservation {
    private let cancelHandler: @Sendable () -> Void

    init(cancel: @escaping @Sendable () -> Void) {
        cancelHandler = cancel
    }

    func cancel() {
        cancelHandler()
    }
}

private final class SnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AudioDevices.Snapshot] = []

    var snapshots: [AudioDevices.Snapshot] {
        lock.withLock { stored }
    }

    func append(_ snapshot: AudioDevices.Snapshot) {
        lock.withLock { stored.append(snapshot) }
    }
}

@Test
func devicesTrackAnAddedDevice() {
    let source = RecordingDeviceSource(devices: [fixtureDevice("built-in", transport: .builtIn)])
    let devices = AudioDevices(source: source, environment: [:])
    let recorder = SnapshotRecorder()
    let observation = devices.onChange { recorder.append($0) }

    source.add(fixtureDevice("usb", transport: .usb, hasInput: true))

    #expect(devices.snapshot.devices.map(\.uid) == ["built-in", "usb"])
    #expect(recorder.snapshots.count == 1)
    #expect(recorder.snapshots.last?.devices.count == 2)
    observation.cancel()
}

@Test
func devicesTrackARemovedDevice() {
    let source = RecordingDeviceSource(devices: [
        fixtureDevice("built-in", transport: .builtIn),
        fixtureDevice("usb", transport: .usb, hasInput: true),
    ])
    let devices = AudioDevices(source: source, environment: [:])
    let recorder = SnapshotRecorder()
    let observation = devices.onChange { recorder.append($0) }

    source.remove(uid: "usb")

    #expect(devices.snapshot.devices.map(\.uid) == ["built-in"])
    #expect(recorder.snapshots.last?.devices.map(\.uid) == ["built-in"])
    observation.cancel()
}

@Test
func devicesTrackARename() {
    let source = RecordingDeviceSource(devices: [
        fixtureDevice("usb", transport: .usb, hasInput: true)
    ])
    let devices = AudioDevices(source: source, environment: [:])
    let recorder = SnapshotRecorder()
    let observation = devices.onChange { recorder.append($0) }

    source.rename(uid: "usb", to: "Studio Microphone")

    #expect(devices.snapshot.devices.first?.name == "Studio Microphone")
    #expect(recorder.snapshots.last?.devices.first?.name == "Studio Microphone")
    observation.cancel()
}

@Test
func devicesTrackADefaultInputChange() {
    let builtIn = fixtureDevice("built-in", transport: .builtIn, hasInput: true)
    let usb = fixtureDevice("usb", transport: .usb, hasInput: true)
    let source = RecordingDeviceSource(
        devices: [builtIn, usb],
        defaultInputUID: builtIn.uid
    )
    let devices = AudioDevices(source: source, environment: [:])
    let recorder = SnapshotRecorder()
    let observation = devices.onChange { recorder.append($0) }

    #expect(devices.snapshot.selection.input?.uid == "built-in")

    source.setDefaultInput("usb")

    #expect(devices.snapshot.defaultInputUID == "usb")
    #expect(devices.snapshot.selection.input?.uid == "usb")
    #expect(recorder.snapshots.last?.selection.input?.uid == "usb")
    observation.cancel()
}

@Test
func devicesTrackADefaultOutputChange() {
    let builtIn = fixtureDevice("built-in", transport: .builtIn, hasOutput: true)
    let usb = fixtureDevice("usb", transport: .usb, hasOutput: true)
    let source = RecordingDeviceSource(
        devices: [builtIn, usb],
        defaultOutputUID: builtIn.uid
    )
    let devices = AudioDevices(source: source, environment: [:])
    let recorder = SnapshotRecorder()
    let observation = devices.onChange { recorder.append($0) }

    #expect(devices.snapshot.selection.output?.uid == "built-in")

    source.setDefaultOutput("usb")

    #expect(devices.snapshot.defaultOutputUID == "usb")
    #expect(devices.snapshot.selection.output?.uid == "usb")
    #expect(recorder.snapshots.last?.selection.output?.uid == "usb")
    observation.cancel()
}

@Test
func aCancelledObserverStopsReceivingSnapshots() {
    let source = RecordingDeviceSource(devices: [fixtureDevice("built-in", transport: .builtIn)])
    let devices = AudioDevices(source: source, environment: [:])
    let recorder = SnapshotRecorder()
    let observation = devices.onChange { recorder.append($0) }

    observation.cancel()
    source.add(fixtureDevice("usb", transport: .usb, hasInput: true))

    #expect(recorder.snapshots.isEmpty)
}

@Test
func theFallbackLoopbackIsNeverTheSelectedInput() {
    let devices = [
        fixtureDevice(
            "BlackHole2ch_UID",
            transport: .virtual,
            hasInput: true,
            hasOutput: true
        )
    ]

    let selection = AudioDevicePolicy.select(
        devices: devices,
        defaultInputUID: "BlackHole2ch_UID",
        defaultOutputUID: "BlackHole2ch_UID"
    )

    #expect(selection.virtualMic?.usesFallback == true)
    #expect(selection.virtualMic?.feedUID == "BlackHole2ch_UID")
    #expect(selection.virtualMic?.inputUID == "BlackHole2ch_UID")
    #expect(selection.input == nil)
    #expect(selection.output?.uid == "BlackHole2ch_UID")
}

@Test
func theOwnPairIsPreferredOverTheFallbackLoopback() {
    let devices = [
        fixtureDevice("com.intesarjawad.untunnel.feed", transport: .virtual),
        fixtureDevice(
            "com.intesarjawad.untunnel.microphone", transport: .virtual, hasInput: true),
        fixtureDevice("BlackHole2ch_UID", transport: .virtual, hasInput: true, hasOutput: true),
        fixtureDevice("built-in", transport: .builtIn, hasInput: true),
    ]

    let selection = AudioDevicePolicy.select(
        devices: devices,
        defaultInputUID: "com.intesarjawad.untunnel.microphone",
        defaultOutputUID: nil
    )

    #expect(selection.virtualMic?.usesFallback == false)
    #expect(selection.virtualMic?.feedUID == "com.intesarjawad.untunnel.feed")
    #expect(selection.virtualMic?.inputUID == "com.intesarjawad.untunnel.microphone")
    #expect(selection.input?.uid == "built-in")
}

@Test
func theDefaultHeadsetIsTheFirstBluetoothDeviceWithInput() {
    let devices = [
        fixtureDevice("usb", transport: .usb, hasInput: true),
        fixtureDevice("first-bluetooth", transport: .bluetooth, hasInput: true),
        fixtureDevice("second-bluetooth", transport: .bluetooth, hasInput: true),
    ]

    let selection = AudioDevicePolicy.select(
        devices: devices,
        defaultInputUID: "usb",
        defaultOutputUID: nil
    )

    #expect(selection.headset?.uid == "first-bluetooth")
    #expect(selection.input?.uid == "first-bluetooth")
}

@Test
func aTestPinChoosesTheLoopbackInput() {
    let devices = [
        fixtureDevice("built-in", transport: .builtIn, hasInput: true),
        fixtureDevice("BlackHole2ch_UID", transport: .virtual, hasInput: true),
    ]

    let selection = AudioDevicePolicy.select(
        devices: devices,
        defaultInputUID: "built-in",
        defaultOutputUID: nil,
        testInputUID: "BlackHole2ch_UID"
    )

    #expect(selection.input?.uid == "BlackHole2ch_UID")
}

@Test
func theOutputFollowsTheSystemDefaultWhenItCanPlay() {
    let devices = [
        fixtureDevice("built-in", transport: .builtIn, hasOutput: true),
        fixtureDevice("usb", transport: .usb, hasOutput: true),
    ]

    let selection = AudioDevicePolicy.select(
        devices: devices,
        defaultInputUID: nil,
        defaultOutputUID: "usb"
    )

    #expect(selection.output?.uid == "usb")
}

func fixtureDevice(
    _ uid: String,
    transport: AudioTransport,
    hasInput: Bool = false,
    hasOutput: Bool = false
) -> AudioDevice {
    AudioDevice(
        uid: uid,
        name: "Fixture \(uid)",
        transport: transport,
        hasInput: hasInput,
        hasOutput: hasOutput,
        nominalSampleRate: 48_000,
        dataSource: .none
    )
}
