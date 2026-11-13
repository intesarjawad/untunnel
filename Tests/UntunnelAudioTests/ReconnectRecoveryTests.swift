import Foundation
import Testing
import UntunnelDSP

@testable import UntunnelAudio

private let airpodsUID = "airpods"

private final class CountingCaptureSource: AudioCaptureSource, @unchecked Sendable {
    let format = AudioStreamFormat(sampleRate: 1000, hopFrames: 10)

    private let lock = NSLock()
    private var storedStarts = 0
    private var storedStops = 0

    var starts: Int {
        lock.withLock { storedStarts }
    }

    var stops: Int {
        lock.withLock { storedStops }
    }

    func start(
        _ onHop: @escaping @Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void
    ) throws {
        lock.withLock { storedStarts += 1 }
    }

    func stop() {
        lock.withLock { storedStops += 1 }
    }
}

private final class CountingRestorer: PipelineRestorer, @unchecked Sendable {
    let hopFrames = 20

    private let lock = NSLock()
    private var storedResets = 0

    var resets: Int {
        lock.withLock { storedResets }
    }

    func process(
        _ input: UnsafeBufferPointer<Float>,
        into output: UnsafeMutableBufferPointer<Float>
    ) -> Int {
        min(input.count, output.count)
    }

    func reset() {
        lock.withLock { storedResets += 1 }
    }
}

private final class RecoveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedStates: [ReconnectRecovery.State] = []
    private var storedMessages: [String] = []

    var states: [ReconnectRecovery.State] {
        lock.withLock { storedStates }
    }

    var messages: [String] {
        lock.withLock { storedMessages }
    }

    func record(_ state: ReconnectRecovery.State) {
        lock.withLock { storedStates.append(state) }
    }

    func log(_ message: String) {
        lock.withLock { storedMessages.append(message) }
    }
}

private struct RecoveryFixture {
    let source: RecordingDeviceSource
    let capture: CountingCaptureSource
    let restorer: CountingRestorer
    let recorder: RecoveryRecorder
    let recovery: ReconnectRecovery
}

private func makeRecovery(devices: [AudioDevice]) -> RecoveryFixture {
    let source = RecordingDeviceSource(devices: devices)
    let watched = AudioDevices(source: source, environment: [:])
    let captureSource = CountingCaptureSource()
    let capture = InputCapture(
        source: captureSource,
        ring: RingBuffer(capacity: 80),
        latency: LatencyMeter(clock: HostClock(ticksPerSecond: 1_000_000))
    )
    let restorer = CountingRestorer()
    let recorder = RecoveryRecorder()
    let recovery = ReconnectRecovery(
        devices: watched,
        capture: capture,
        restorer: restorer,
        log: { recorder.log($0) }
    ) { recorder.record($0) }
    return RecoveryFixture(
        source: source,
        capture: captureSource,
        restorer: restorer,
        recorder: recorder,
        recovery: recovery
    )
}

@Test
func losingTheInputDeviceStopsCaptureAndWaits() {
    let airpods = fixtureDevice(airpodsUID, transport: .bluetooth, hasInput: true)
    let fixture = makeRecovery(devices: [airpods])
    fixture.recovery.start()

    fixture.source.remove(uid: airpodsUID)

    #expect(fixture.capture.stops == 1)
    #expect(fixture.restorer.resets == 1)
    #expect(fixture.recorder.states == [.waiting(deviceName: "Fixture airpods")])
    #expect(fixture.recorder.messages == [ReconnectRecovery.lostMessage])
}

@Test
func theSameDeviceReturningResumesCapture() {
    let airpods = fixtureDevice(airpodsUID, transport: .bluetooth, hasInput: true)
    let fixture = makeRecovery(devices: [airpods])
    fixture.recovery.start()

    fixture.source.remove(uid: airpodsUID)
    fixture.source.add(airpods)

    #expect(fixture.capture.stops == 1)
    #expect(fixture.capture.starts == 1)
    #expect(fixture.restorer.resets == 1)
    #expect(
        fixture.recorder.states == [
            .waiting(deviceName: "Fixture airpods"),
            .running(deviceName: "Fixture airpods"),
        ]
    )
    #expect(
        fixture.recorder.messages == [
            ReconnectRecovery.lostMessage,
            ReconnectRecovery.restoredMessage,
        ]
    )
}

@Test
func aSubstituteDeviceDoesNotResumeThePath() {
    let airpods = fixtureDevice(airpodsUID, transport: .bluetooth, hasInput: true)
    let fixture = makeRecovery(devices: [airpods])
    fixture.recovery.start()

    fixture.source.remove(uid: airpodsUID)
    fixture.source.add(fixtureDevice("other", transport: .bluetooth, hasInput: true))

    #expect(fixture.capture.starts == 0)
    #expect(
        fixture.recorder.states == [
            .waiting(deviceName: "Fixture airpods")
        ]
    )
}

@Test
func unrelatedDeviceChangesDoNotRepeatTheLoss() {
    let airpods = fixtureDevice(airpodsUID, transport: .bluetooth, hasInput: true)
    let fixture = makeRecovery(devices: [airpods])
    fixture.recovery.start()

    fixture.source.remove(uid: airpodsUID)
    fixture.source.add(fixtureDevice("built-in", transport: .builtIn, hasInput: true))
    fixture.source.add(fixtureDevice("usb", transport: .usb, hasInput: true))

    #expect(fixture.recorder.messages == [ReconnectRecovery.lostMessage])
    #expect(fixture.capture.stops == 1)
}

@Test
func aStoppedRecoveryIgnoresLaterDeviceChanges() {
    let airpods = fixtureDevice(airpodsUID, transport: .bluetooth, hasInput: true)
    let fixture = makeRecovery(devices: [airpods])
    fixture.recovery.start()

    fixture.recovery.stop()
    fixture.source.remove(uid: airpodsUID)

    #expect(fixture.capture.stops == 0)
    #expect(fixture.recorder.states.isEmpty)
}
