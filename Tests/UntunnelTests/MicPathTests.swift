import Foundation
import Synchronization
import Testing
import UntunnelAudio
import UntunnelEngine

@testable import Untunnel

let tierRate = 16_000
let hopFrames = tierRate / Pipeline.hopsPerSecond

final class FakeCapture: AudioCaptureSource, @unchecked Sendable {
    let format = AudioStreamFormat(sampleRate: tierRate, hopFrames: hopFrames)
    var startError: Error?
    private let lock = NSLock()
    private var onHop: (@Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void)?
    private var stopCount = 0

    func start(
        _ onHop: @escaping @Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void
    ) throws {
        if let startError {
            throw startError
        }
        lock.withLock { self.onHop = onHop }
    }

    func stop() {
        lock.withLock {
            onHop = nil
            stopCount += 1
        }
    }

    var isRunning: Bool {
        lock.withLock { onHop != nil }
    }

    var stops: Int {
        lock.withLock { stopCount }
    }

    func deliver(_ samples: [Float]) {
        let onHop = lock.withLock { self.onHop }
        samples.withUnsafeBufferPointer { onHop?($0, HostClock.now()) }
    }
}

final class FakeSink: AudioRenderSink, @unchecked Sendable {
    let format = AudioStreamFormat(sampleRate: tierRate, hopFrames: hopFrames)
    private let lock = NSLock()
    private var render: (@Sendable (UnsafeMutableBufferPointer<Float>, UInt64) -> Void)?
    private var stopCount = 0

    func start(
        _ render: @escaping @Sendable (UnsafeMutableBufferPointer<Float>, UInt64) -> Void
    ) throws {
        lock.withLock { self.render = render }
    }

    func stop() {
        lock.withLock {
            render = nil
            stopCount += 1
        }
    }

    var isRunning: Bool {
        lock.withLock { render != nil }
    }

    var stops: Int {
        lock.withLock { stopCount }
    }

    func pull(_ count: Int) -> [Float] {
        var frames = [Float](repeating: 0, count: count)
        let render = lock.withLock { self.render }
        frames.withUnsafeMutableBufferPointer { render?($0, HostClock.now()) }
        return frames
    }
}

final class FakeHardware: MicPathHardware, @unchecked Sendable {
    let capture = FakeCapture()
    let sink = FakeSink()
    private let opened = Mutex<(captures: [String], sinks: [String])>(([], []))

    /// The device UIDs the session asked to capture from and to play to, in order.
    var captureUIDs: [String] { opened.withLock { $0.captures } }
    var sinkUIDs: [String] { opened.withLock { $0.sinks } }

    func captureSource(uid: String) throws -> any AudioCaptureSource {
        opened.withLock { $0.captures.append(uid) }
        return capture
    }

    func renderSink(uid: String) throws -> any AudioRenderSink {
        opened.withLock { $0.sinks.append(uid) }
        return sink
    }

    func deviceLatencyMs(inputUID: String, outputUID: String) -> Double {
        0
    }
}

final class Token: DeviceObservation {
    func cancel() {}
}

final class FakeDevices: DeviceSource, @unchecked Sendable {
    var devices: [AudioDevice]
    var defaultInputDeviceUID: String?
    var defaultOutputDeviceUID: String?
    private var onChange: (@Sendable () -> Void)?

    init(devices: [AudioDevice], defaultInput: String?) {
        self.devices = devices
        defaultInputDeviceUID = defaultInput
    }

    func observe(_ onChange: @escaping @Sendable () -> Void) -> any DeviceObservation {
        self.onChange = onChange
        return Token()
    }

    func change(_ update: (FakeDevices) -> Void) {
        update(self)
        onChange?()
    }
}

final class CountingHeartbeat: HeartbeatSink, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func setHeartbeat() {
        lock.withLock { count += 1 }
    }

    var beats: Int {
        lock.withLock { count }
    }
}

final class RecordingSetter: DefaultInputSetter, @unchecked Sendable {
    private let lock = NSLock()
    private var uids: [String] = []

    func setDefaultInput(uid: String) -> Bool {
        lock.withLock { uids.append(uid) }
        return true
    }

    var set: [String] {
        lock.withLock { uids }
    }
}

/// Holds the pipeline thread inside `process` until released, as a hung model would.
private final class StallingRestorer: PipelineRestorer, @unchecked Sendable {
    let hopFrames = tierRate / Pipeline.hopsPerSecond
    private let gate = DispatchSemaphore(value: 0)
    private let entered = DispatchSemaphore(value: 0)

    func process(
        _ input: UnsafeBufferPointer<Float>,
        into output: UnsafeMutableBufferPointer<Float>
    ) -> Int {
        entered.signal()
        gate.wait()
        return 0
    }

    func waitUntilStalled() -> Bool {
        entered.wait(timeout: .now() + 5) == .success
    }

    func reset() {}

    func release() {
        for _ in 0..<64 {
            gate.signal()
        }
    }
}

func device(
    _ uid: String,
    _ name: String,
    _ transport: AudioTransport,
    input: Bool,
    output: Bool
) -> AudioDevice {
    AudioDevice(
        uid: uid,
        name: name,
        transport: transport,
        hasInput: input,
        hasOutput: output,
        nominalSampleRate: Double(tierRate),
        dataSource: .none
    )
}

let airPods = device("airpods", "AirPods", .bluetooth, input: true, output: true)
let builtIn = device("builtin", "MacBook Microphone", .builtIn, input: true, output: true)
let feed = device(
    VirtualMicDevices.feedUID, "Untunnel Feed", .virtual, input: false, output: true)
let microphone = device(
    VirtualMicDevices.inputUID,
    "Untunnel Microphone",
    .virtual,
    input: true,
    output: false
)

let everyProbePassed = HALProbeResults(
    fallbackOK: true,
    livenessHeartbeat: true,
    sleepClean: true
)

@MainActor
struct Harness {
    let state: AppState
    let devices: FakeDevices
    let hardware: FakeHardware
    let setter: RecordingSetter
    let processes = FakeProcesses([])
    let tap = FakeTap()
    let incomingDefaults: UserDefaults
    let controller: MicPathController

    init(
        devices: [AudioDevice] = [builtIn, airPods, feed, microphone],
        defaultInput: String? = "airpods",
        defaultOutput: String? = "airpods",
        probe: HALProbeResults = everyProbePassed,
        clock: @escaping () -> TimeInterval = { 0 }
    ) {
        let source = FakeDevices(devices: devices, defaultInput: defaultInput)
        source.defaultOutputDeviceUID = defaultOutput
        let state = AppState()
        let hardware = FakeHardware()
        let setter = RecordingSetter()
        self.devices = source
        self.state = state
        self.hardware = hardware
        self.setter = setter
        let store = AutoRouteStore(
            defaults: UserDefaults(suiteName: UUID().uuidString) ?? .standard)
        let incomingDefaults = UserDefaults(suiteName: UUID().uuidString) ?? .standard
        self.incomingDefaults = incomingDefaults
        controller = MicPathController(
            state: state,
            deviceSource: source,
            environment: [:],
            hardware: hardware,
            processes: processes,
            tap: tap,
            incomingPreferences: IncomingPreferences(defaults: incomingDefaults),
            probe: probe,
            heartbeatSink: CountingHeartbeat(),
            permission: { .authorized },
            clock: clock,
            makeAutoRoute: { enabled in
                AutoRouteShell(
                    setter: setter, store: store, enabled: enabled, permission: .authorized)
            }
        )
    }
}

func sine(hop: Int) -> [Float] {
    (0..<hopFrames).map { index in
        Float(0.5 * sin(2 * Double.pi * 440 * Double(hop * hopFrames + index) / Double(tierRate)))
    }
}

func rms(_ samples: ArraySlice<Float>) -> Float {
    (samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, samples.count))).squareRoot()
}

@MainActor
func eventually(_ condition: () -> Bool) async throws -> Bool {
    for _ in 0..<300 where !condition() {
        try await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// One-block weights written as a checkpoint, the smallest model the loader accepts.
private func installModel(in home: URL) throws -> InstalledPaths {
    let paths = InstalledPaths(home: home)
    try FileManager.default.createDirectory(at: paths.model, withIntermediateDirectories: true)
    try checkpoint(modelShapes()).write(
        to: paths.model.appendingPathComponent(Download.checkpointName)
    )
    return paths
}

private func temporaryHome() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

@Test
func theModelLoadsAtTheCheapestTierItsDepthAllowsOrSaysWhyNot() throws {
    let home = temporaryHome()
    defer {
        try? FileManager.default.removeItem(at: home)
    }
    #expect(MicModel.load(paths: InstalledPaths(home: home)).failure == .modelMissing)

    let paths = try installModel(in: home)
    let loaded = MicModel.load(paths: paths)
    #expect(loaded.tier == Tier(sampleRate: 16_000, exitLayer: 1, lookAhead: 0))

    try Data("not a checkpoint".utf8).write(
        to: paths.model.appendingPathComponent(Download.checkpointName)
    )
    guard case .modelRejected = MicModel.load(paths: paths).failure else {
        Issue.record("an unreadable checkpoint must be rejected with the reason")
        return
    }
}

@Test
func unmeasuredLaunchKeepsBothPathsAtTheSafeTier() throws {
    let home = temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let paths = try installModel(in: home)
    let loaded = LoadedModel()
    let primary = loaded.load(paths: paths, tierReport: home.appendingPathComponent("missing.json"))
    loaded.current = primary
    #expect(primary.tier?.sampleRate == 16_000)
    #expect(loaded.incoming?.tier == primary.tier)
    let high = Tier(sampleRate: 48_000, exitLayer: 1, lookAhead: 0)
    let stage = try #require(loaded.incoming).makeRestorer(fallbackRate: 48_000)
    #expect(stage.rate == 16_000)
    #expect(stage.restorer.latencySamples == 640)
    #expect(loaded.atTier(high) == nil)
}

/// The engine tests' smallest tier, so a debug build runs the model in milliseconds.
private let smallTier = Tier(sampleRate: 800, exitLayer: 1, lookAhead: 0)

private func fixtureWeights(in home: URL) throws -> RealtimeRestorerWeights {
    guard case .ready(let weights, _) = MicModel.load(paths: try installModel(in: home)) else {
        throw UserFacingError.modelMissing
    }
    return weights
}

private func run(_ restorer: ModelRestorer, _ input: [Float]) -> [Float] {
    var output = [Float](repeating: 0, count: input.count)
    for start in stride(from: 0, to: input.count, by: restorer.hopFrames) {
        let end = start + restorer.hopFrames
        _ = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                restorer.process(
                    UnsafeBufferPointer(rebasing: source[start..<end]),
                    into: UnsafeMutableBufferPointer(rebasing: destination[start..<end])
                )
            }
        }
    }
    return output
}

@Test
func aResetFromTheDeviceThreadIsAppliedBeforeTheNextHop() throws {
    let home = temporaryHome()
    defer {
        try? FileManager.default.removeItem(at: home)
    }
    let weights = try fixtureWeights(in: home)
    let used = ModelRestorer(weights: weights, tier: smallTier)
    let tone = (0..<(used.hopFrames * 12)).map { Float(0.4 * sin(Double($0) * 0.31)) }
    _ = run(used, Array(tone.reversed()))

    used.reset()

    #expect(run(used, tone) == run(ModelRestorer(weights: weights, tier: smallTier), tone))
}

@Test
@MainActor
func withoutAModelACallStillHearsTheRawHeadsetNeverSilence() async throws {
    let harness = Harness()
    harness.controller.start(cleanExit: true)
    harness.controller.modelLoaded(.unavailable(.modelMissing))

    harness.controller.apply(.restoring(client: "zoom.us"))

    #expect(harness.state.micPath == .bypass)
    #expect(harness.state.micError == .modelMissing)
    #expect(harness.hardware.capture.isRunning)
    #expect(harness.hardware.sink.isRunning)
    var input: [Float] = []
    var output: [Float] = []
    let pipeline = try #require(harness.controller.session?.pipeline)
    for hop in 0..<60 {
        let samples = sine(hop: hop)
        input += samples
        harness.hardware.capture.deliver(samples)
        _ = try await eventually { pipeline.outputRing.availableToRead >= hopFrames }
        output += harness.hardware.sink.pull(hopFrames)
    }
    let tail = output.suffix(20 * hopFrames)
    #expect(rms(tail) > 0.8 * rms(input.suffix(20 * hopFrames)))
}

@Test
@MainActor
func aCallRunsTheModelUntilItsReaderLeaves() async throws {
    let home = temporaryHome()
    defer {
        try? FileManager.default.removeItem(at: home)
    }
    let harness = Harness()
    harness.controller.start(cleanExit: true)
    let loaded = MicModel.load(paths: try installModel(in: home))
    harness.controller.modelLoaded(loaded)

    harness.controller.apply(.restoring(client: "zoom.us"))
    let tier = try #require(loaded.tier)
    #expect(harness.state.micPath == .restoring(tier))
    #expect(harness.state.micError == nil)
    #expect(harness.controller.session?.restorer is ModelRestorer)

    harness.controller.apply(.standby)
    #expect(harness.state.micPath == .standby)
    #expect(harness.controller.session == nil)
    #expect(!harness.hardware.capture.isRunning)
    #expect(!harness.hardware.sink.isRunning)
}

@Test
@MainActor
func anEngageThatCannotOpenTheHeadsetStopsTheHeartbeatAndClosesTheFeed() {
    let harness = Harness()
    harness.controller.start(cleanExit: true)
    harness.controller.modelLoaded(.unavailable(.modelMissing))
    let heartbeat = harness.controller.heartbeat
    #expect(heartbeat?.tick() == true)

    harness.hardware.capture.startError = AudioCaptureError.unsupportedDevice
    harness.controller.apply(.restoring(client: "zoom.us"))

    guard case .audioDeviceUnavailable = harness.state.micError else {
        Issue.record("the failed engage must say which device could not open")
        return
    }
    #expect(harness.controller.session == nil)
    #expect(harness.hardware.sink.stops == 1)
    #expect(heartbeat?.tick() == false)
    #expect(heartbeat?.tick() == false)

    harness.controller.apply(.standby)
    #expect(heartbeat?.tick() == true)
}

@Test
@MainActor
func aMissingVirtualMicrophoneIsReportedInsteadOfEngaging() {
    let harness = Harness(devices: [builtIn, airPods])
    harness.controller.start(cleanExit: true)

    harness.controller.apply(.restoring(client: "zoom.us"))

    #expect(
        harness.state.micError
            == .audioDeviceUnavailable("Untunnel Microphone is not installed")
    )
    #expect(!harness.hardware.capture.isRunning)
}

@Test
@MainActor
func aHeadsetThatLeavesMidCallWaitsAndKeepsBeatingOnSilenceHops() async throws {
    let harness = Harness()
    harness.controller.start(cleanExit: true)
    harness.controller.modelLoaded(.unavailable(.modelMissing))
    harness.controller.apply(.restoring(client: "zoom.us"))
    let heartbeat = try #require(harness.controller.heartbeat)

    harness.devices.change { $0.devices.removeAll { $0.uid == "airpods" } }

    let waited = try await eventually {
        harness.state.micPath == .waiting(deviceName: "AirPods")
    }
    #expect(waited)
    #expect(!harness.hardware.capture.isRunning)
    #expect(harness.hardware.sink.isRunning)
    // Wait on the silence hops themselves: under load the pipeline thread can lag any fixed sleep.
    func nextHop() async throws -> Bool {
        let seen = harness.controller.heartbeatHops
        return try await eventually { harness.controller.heartbeatHops != seen }
    }
    heartbeat.tick()
    #expect(try await nextHop())
    let first = heartbeat.tick()
    #expect(try await nextHop())
    let second = heartbeat.tick()
    #expect(first && second)
    harness.controller.apply(.standby)
}

@Test
func aStalledEngineStopsTheHeartbeatSoTheCallFallsBackToARealMicrophone() throws {
    let hardware = FakeHardware()
    let stalling = StallingRestorer()
    let devices = AudioDevices(
        source: FakeDevices(devices: [airPods, feed, microphone], defaultInput: "airpods"),
        environment: [:]
    )
    let session = try MicPathSession(
        input: airPods,
        feedUID: VirtualMicDevices.feedUID,
        devices: devices,
        hardware: hardware,
        bypass: false,
        makeRestorer: { _ in (stalling, tierRate) },
        onRecovery: { _ in }
    )
    defer {
        stalling.release()
        session.stop()
    }
    var ticker = HeartbeatTicker()
    let checks = everyProbePassed.prerequisites(
        virtualMic: devices.snapshot.selection.virtualMic,
        permission: .authorized
    )
    func tick() -> Bool {
        let metrics = session.pipeline.metrics
        return ticker.tick(hops: metrics.hops, status: metrics.status, prerequisites: checks)
    }

    // Wait on the pipeline itself: under load a hop can take longer than any fixed sleep.
    func nextHop() -> Bool {
        let seen = session.pipeline.metrics.hops
        for _ in 0..<500 where session.pipeline.metrics.hops == seen {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return session.pipeline.metrics.hops != seen
    }

    _ = tick()
    #expect(nextHop())
    let beforeInput = tick()
    #expect(beforeInput, "silence hops before any input keep the heartbeat")

    hardware.capture.deliver(sine(hop: 0))
    #expect(stalling.waitUntilStalled())
    _ = tick()
    Thread.sleep(forTimeInterval: 0.15)
    let whileStalled = tick()
    #expect(!whileStalled, "a pipeline stuck inside the model must stop the heartbeat")
}

@Test
@MainActor
func theRecordedProbeKeepsTheHeartbeatAndAutoRouteOffWithTheReason() {
    let harness = Harness(probe: .recorded)
    harness.controller.start(cleanExit: true)

    #expect(harness.controller.heartbeat?.tick() == false)
    #expect(harness.state.autoRoute.isEnabled == false)
    #expect(harness.state.autoRoute.reason == "The fallback check has not passed")

    harness.devices.change {
        $0.devices.append(device("beats", "Beats", .bluetooth, input: true, output: true))
        $0.defaultInputDeviceUID = "beats"
    }
    harness.controller.devicesChanged(harness.controller.snapshot)
    #expect(harness.setter.set.isEmpty)
}

@Test
@MainActor
func aHeadsetMacOSSwitchesToOnConnectIsRoutedAndAHandPickedInputIsNot() {
    var now: TimeInterval = 100
    let harness = Harness(devices: [builtIn, feed, microphone], defaultInput: "builtin") { now }
    harness.controller.start(cleanExit: true)
    #expect(harness.state.autoRoute.isEnabled)

    harness.devices.change { $0.devices.append(airPods) }
    harness.controller.devicesChanged(harness.controller.snapshot)
    now = 101
    harness.devices.change { $0.defaultInputDeviceUID = "airpods" }
    harness.controller.devicesChanged(harness.controller.snapshot)
    #expect(harness.setter.set == [VirtualMicDevices.inputUID])

    now = 140
    harness.devices.change { $0.defaultInputDeviceUID = "builtin" }
    harness.controller.devicesChanged(harness.controller.snapshot)
    #expect(harness.setter.set == [VirtualMicDevices.inputUID])

    harness.controller.stop()
    #expect(harness.setter.set == [VirtualMicDevices.inputUID])
}

@Test
@MainActor
func quittingWhileRoutedHandsTheDefaultBack() {
    var now: TimeInterval = 0
    let harness = Harness(devices: [builtIn, feed, microphone], defaultInput: "builtin") { now }
    harness.controller.start(cleanExit: true)
    harness.devices.change {
        $0.devices.append(airPods)
        $0.defaultInputDeviceUID = "airpods"
    }
    now = 1
    harness.controller.devicesChanged(harness.controller.snapshot)

    harness.controller.stop()

    #expect(harness.setter.set == [VirtualMicDevices.inputUID, "builtin"])
}

@Test
func deviceSnapshotsBecomeAutoRouteEventsInTheOrderTheMachineNeeds() {
    func snapshot(_ devices: [AudioDevice], input: String?) -> AudioDevices.Snapshot {
        AudioDevices.Snapshot(
            devices: devices,
            defaultInputUID: input,
            defaultOutputUID: nil,
            selection: AudioDevicePolicy.select(
                devices: devices,
                defaultInputUID: input,
                defaultOutputUID: nil
            )
        )
    }
    let before = snapshot([builtIn], input: "builtin")
    let connected = snapshot([builtIn, airPods], input: "airpods")

    #expect(
        AutoRouteEvents.between(before, connected, at: 5) == [
            .deviceAppeared(uid: "airpods", transport: .bluetooth, at: 5),
            .defaultInputChanged(uid: "airpods", at: 5),
        ]
    )
    #expect(
        AutoRouteEvents.between(connected, before, at: 9) == [
            .headsetDisconnected(uid: "airpods", at: 9),
            .defaultInputChanged(uid: "builtin", at: 9),
        ]
    )
    #expect(AutoRouteEvents.between(before, before, at: 1).isEmpty)
}

@Test
func standbyBeatsWhileEveryCheckPassesAndNeverWithoutPermission() {
    var ticker = HeartbeatTicker()
    let ready = everyProbePassed.prerequisites(
        virtualMic: VirtualMic(
            feedUID: VirtualMicDevices.feedUID,
            inputUID: VirtualMicDevices.inputUID,
            usesFallback: false
        ),
        permission: .authorized
    )

    let first = ticker.tick(hops: nil, status: .waiting, prerequisites: ready)
    let second = ticker.tick(hops: nil, status: .waiting, prerequisites: ready)
    var denied = ready
    denied.permission = .denied
    let withoutPermission = ticker.tick(hops: nil, status: .waiting, prerequisites: denied)
    #expect(first && second)
    #expect(!withoutPermission)
    #expect(
        everyProbePassed.prerequisites(virtualMic: nil, permission: .authorized).virtualMicKind
            == "none"
    )
}

@Test
func hearYourselfRestoresTheAfterSideThroughTheLoadedModel() throws {
    let home = temporaryHome()
    defer {
        try? FileManager.default.removeItem(at: home)
    }
    let loaded = MicModel.load(paths: try installModel(in: home))
    let stage = loaded.makeRestorer(fallbackRate: 48_000)
    #expect(stage.restorer is ModelRestorer)
    #expect(stage.rate == tierRate)
    #expect(HearYourselfModel.afterNote(for: loaded) == nil)

    let rate = smallTier.sampleRate
    let restorer = ModelRestorer(weights: try fixtureWeights(in: home), tier: smallTier)
    let raw = (0..<(rate * HearYourselfTake.seconds)).map {
        Float(0.3 * sin(2 * Double.pi * 90 * Double($0) / Double(rate)))
    }
    let take = HearYourselfTake.make(raw: raw, inputRate: rate, tierRate: rate, restorer: restorer)

    #expect(take.restored.count == take.raw.count)
    #expect(
        take.restored
            == run(ModelRestorer(weights: try fixtureWeights(in: home), tier: smallTier), raw))
    #expect(take.restored != take.raw)
}

@Test
func hearYourselfSaysWhenAfterIsTheRawTake() throws {
    let missing = try #require(HearYourselfModel.afterNote(for: .unavailable(.modelMissing)))
    #expect(missing.contains(UserFacingError.modelMissing.message))
    #expect(missing.contains(UserFacingError.modelMissing.fix))
    #expect(HearYourselfModel.afterNote(for: nil)?.contains("still loading") == true)

    let passThrough = MicModel.unavailable(.modelMissing).makeRestorer(fallbackRate: 48_000)
    #expect(passThrough.rate == 48_000)
    #expect(passThrough.restorer is MonitorPassThroughRestorer)
}

@MainActor
@Test
func monitorPreviewsTheMicrophoneWithoutADriverAndClosesCapture() async throws {
    let harness = Harness(devices: [builtIn], defaultInput: builtIn.uid, defaultOutput: builtIn.uid)
    harness.controller.start(cleanExit: true)
    defer { harness.controller.stop() }
    #expect(harness.controller.monitorPipelines().isEmpty)
    harness.controller.setMonitoring(true)
    _ = harness.controller.monitorPipelines()
    #expect(try await eventually { harness.controller.monitorPipelines()[.mic] != nil })
    #expect(harness.hardware.captureUIDs == [builtIn.uid])
    #expect(harness.hardware.sinkUIDs.isEmpty)
    #expect(harness.hardware.capture.isRunning)
    harness.controller.setMonitoring(false)
    #expect(!harness.hardware.capture.isRunning)
    #expect(harness.controller.monitorPipelines().isEmpty)
}

@MainActor
@Test
func monitorReusesAnEngagedMicrophoneWithoutOpeningASecondInput() {
    let harness = Harness()
    harness.controller.start(cleanExit: true)
    defer { harness.controller.stop() }
    harness.controller.apply(.restoring(client: "zoom.us"))
    harness.controller.setMonitoring(true)
    #expect(harness.controller.monitorPipelines()[.mic] === harness.controller.session?.pipeline)
    #expect(harness.hardware.captureUIDs.count == 1)
    harness.controller.setMonitoring(false)
    #expect(harness.hardware.capture.isRunning)
}
