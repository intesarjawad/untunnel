import Foundation
import Testing
import UntunnelEngine

@testable import Untunnel
@testable import UntunnelAudio

private let fineTier = Tier(sampleRate: 48_000, exitLayer: 7, lookAhead: 1)

private func publish(_ feed: MonitorFeed, columns: Int, db: Float) {
    let column = [Float](repeating: db, count: MonitorLayout.rowCount)
    for _ in 0..<columns {
        column.withUnsafeBufferPointer {
            feed.input.publish($0)
            feed.output.publish($0)
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double]

    init(_ values: [Double]) {
        self.values = values
    }

    func next() -> Double {
        lock.withLock { values.count > 1 ? values.removeFirst() : (values.first ?? 0) }
    }
}

@MainActor
private func model(
    state: AppState,
    feeds: [MonitorPath: MonitorFeed] = [:],
    capture: MonitorModel.Capture? = nil,
    directory: URL = FileManager.default.temporaryDirectory,
    lateFrames: (@Sendable () -> UInt64)? = nil,
    clock: Counter = Counter([0]),
    cpu: Counter = Counter([0])
) -> MonitorModel {
    MonitorModel(
        appState: state,
        feeds: feeds,
        directory: directory,
        capture: capture,
        lateFrames: lateFrames,
        motion: { MonitorMotion(reduceMotion: false) },
        stamp: { "T" },
        clock: { clock.next() },
        cpuSeconds: { cpu.next() }
    )
}

@Test
func readoutsNameTierLatencyLateFramesAndCPU() {
    let readouts = MonitorReadouts(
        tier: fineTier,
        addedLatencyMs: 23.456,
        lateFrames: 3,
        cpuPercent: 12.4
    )

    #expect(
        readouts.rows == [
            .init(label: "Tier", value: "48 kHz, exit layer 7, look-ahead 1"),
            .init(label: "Added latency", value: "23.5 ms"),
            .init(label: "Late frames", value: "3"),
            .init(label: "CPU", value: "12 %"),
        ]
    )
}

@Test
func readoutsSayWhenNothingWasMeasured() {
    #expect(
        MonitorReadouts().rows.map(\.value)
            == ["Not running", "Not measured", "Not measured", "Not measured"]
    )
    #expect(
        MonitorReadouts.tierText(Tier(sampleRate: 22_050, exitLayer: 2, lookAhead: 0))
            == "22050 Hz, exit layer 2, look-ahead 0"
    )
}

@Test
func reducedMotionStopsScrollingAndRedrawsEveryHalfSecond() {
    let reduced = MonitorMotion(reduceMotion: true)
    let normal = MonitorMotion(reduceMotion: false)

    #expect(reduced.scrolls == false)
    #expect(reduced.interval == 0.5)
    #expect(reduced.historyMode == .sweeping)
    #expect(normal.scrolls)
    #expect(normal.interval == 1.0 / 30)
    #expect(normal.historyMode == .scrolling)
}

@Test
func cpuPercentIsCPUTimeOverWallTime() {
    #expect(ProcessCPU.percent(cpuSeconds: 2.5, since: 2.0, wallSeconds: 1.0) == 50)
    #expect(ProcessCPU.percent(cpuSeconds: 2.0, since: 2.5, wallSeconds: 1.0) == 0)
    #expect(ProcessCPU.percent(cpuSeconds: 3, since: 2, wallSeconds: 0) == nil)
}

@Test
func stateFollowsRecordingThenThePath() {
    func state(
        _ micPath: AppState.MicPath,
        recording: Bool = false,
        saved: Bool = false,
        audio: Bool = true
    ) -> MonitorState {
        MonitorModel.state(
            micPath: micPath,
            isRecording: recording,
            hasSaved: saved,
            hasAudio: audio
        )
    }

    #expect(state(.restoring(fineTier)) == .live)
    #expect(state(.standby, audio: false) == .idle)
    #expect(state(.bypass) == .bypassed)
    #expect(state(.waiting(deviceName: "Headset")) == .waiting)
    #expect(state(.bypass, recording: true) == .recording)
    #expect(state(.restoring(fineTier), saved: true) == .saved)
    #expect(state(.restoring(fineTier), recording: true, saved: true) == .recording)
}

@MainActor
@Test
func tickDrainsPublishedColumnsIntoTheMicrophonePane() {
    let appState = AppState()
    appState.micPath = .restoring(fineTier)
    appState.addedLatencyMs = 12.5
    let feed = MonitorFeed()
    let monitor = model(state: appState, feeds: [.mic: feed], lateFrames: { 7 })
    #expect(monitor.screen.state == .idle)

    publish(feed, columns: 3, db: -30)
    monitor.tick()

    #expect(monitor.screen.state == .live)
    #expect(monitor.screen.panes.map(\.path) == [.mic])
    #expect(monitor.screen.panes.first?.source == .live)
    #expect(monitor.screen.panes.first?.input.columnsReceived == 3)
    #expect(monitor.screen.panes.first?.output.columnsReceived == 3)
    #expect(monitor.screen.readouts.tier == fineTier)
    #expect(monitor.screen.readouts.addedLatencyMs == 12.5)
    #expect(monitor.screen.readouts.lateFrames == 7)

    publish(feed, columns: 2, db: -30)
    monitor.tick()
    #expect(monitor.screen.panes.first?.input.columnsReceived == 5)
}

@MainActor
@Test
func panesExistOnlyForActivePaths() {
    let appState = AppState()
    let feeds: [MonitorPath: MonitorFeed] = [.mic: MonitorFeed(), .incoming: MonitorFeed()]
    let monitor = model(state: appState, feeds: feeds)

    monitor.tick()
    #expect(monitor.screen.panes.isEmpty)

    appState.micPath = .standby
    appState.incoming = .restoring(pid: 42, name: "QuickTime Player")
    monitor.tick()
    #expect(monitor.screen.panes.map(\.path) == [.mic, .incoming])

    appState.incoming = .blockedSpeakers
    monitor.tick()
    #expect(monitor.screen.panes.map(\.path) == [.mic])
}

@MainActor
@Test
func cpuReadoutComesFromTwoTicks() {
    let appState = AppState()
    let monitor = model(
        state: appState,
        clock: Counter([10, 11]),
        cpu: Counter([1.0, 1.5])
    )

    monitor.tick()

    #expect(monitor.screen.readouts.cpuPercent == 50)
}

@MainActor
@Test
func recordingIsUnavailableUntilACaptureExists() async {
    let monitor = model(state: AppState())

    #expect(monitor.screen.canRecord == false)
    #expect(monitor.screen.note == MonitorModel.unavailableNote)
    await monitor.recordAB()
    #expect(monitor.screen.state == .idle)
}

@MainActor
@Test
func recordingWritesBothFilesAndSaysWhereTheyWent() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }
    let monitor = model(
        state: AppState(),
        capture: { ABTake(sampleRate: 16_000, before: [0.25, 0.5], after: [0.5, 0.25]) },
        directory: directory
    )
    #expect(monitor.screen.canRecord)

    await monitor.recordAB()

    #expect(monitor.screen.state == .saved)
    #expect(monitor.screen.note?.contains("before-T.wav and after-T.wav") == true)
    #expect(monitor.screen.note?.contains(directory.path) == true)
    let before = try WAVFile(
        decoding: Data(contentsOf: directory.appendingPathComponent("before-T.wav"))
    )
    #expect(before.samples == [0.25, 0.5])
}

@MainActor
@Test
func aFailedCaptureReportsTheErrorAndSavesNothing() async {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let monitor = model(
        state: AppState(),
        capture: { throw UserFacingError.audioDeviceUnavailable("the headset input") },
        directory: directory
    )

    await monitor.recordAB()

    #expect(monitor.screen.state != .saved)
    #expect(
        monitor.screen.note == UserFacingError.audioDeviceUnavailable("the headset input").message
    )
    #expect(FileManager.default.fileExists(atPath: directory.path) == false)
}

@Test
func everyReplayPaneIsHeadedAsAReplay() {
    for state in MonitorState.allCases {
        let screen = MonitorScreen.replay(
            state: state,
            path: .mic,
            motion: MonitorMotion(reduceMotion: false),
            take: HearYourselfDemo.take()
        )

        #expect(screen.panes.map(\.source.header) == ["Replayed recording"])
        #expect(screen.state == state)
        #expect(screen.canRecord == false)
    }
}

@Test
func replayStatesShowAudioOnlyWhenTheStateHasAny() {
    func pane(_ state: MonitorState) -> MonitorPane? {
        MonitorScreen.replay(
            state: state,
            path: .mic,
            motion: MonitorMotion(reduceMotion: false),
            take: HearYourselfDemo.take()
        ).panes.first
    }

    #expect(pane(.idle)?.input.columnsReceived == 0)
    #expect(pane(.waiting)?.output.columnsReceived == 0)
    #expect((pane(.live)?.input.columnsReceived ?? 0) > 0)
    #expect(pane(.live)?.input != pane(.live)?.output)
    #expect(pane(.bypassed)?.input == pane(.bypassed)?.output)
}

@MainActor
@Test
func livePipelineTapsDriveBothPanesAndSaveBothPaths() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    func pipeline() -> Pipeline {
        Pipeline(
            inputRate: 8_000, tierRate: 8_000, outputRate: 8_000,
            restorer: MonitorPassThroughRestorer(hopFrames: 160), latency: LatencyMeter())
    }
    let microphone = pipeline()
    let incoming = pipeline()
    let state = AppState()
    state.micPath = .bypass
    state.incoming = .restoring(pid: 42, name: "Call")
    let model = MonitorModel(
        appState: state, feeds: [.mic: MonitorFeed(), .incoming: MonitorFeed()],
        directory: directory, pipelines: { [.mic: microphone, .incoming: incoming] },
        stamp: { "live" })
    model.tick()
    #expect(model.screen.canRecord)
    let producer = Task { @MainActor in
        let samples = [Float](repeating: 0.25, count: 160)
        // Each iteration advances an actual pipeline hop; no mailbox fixture can satisfy this test.
        for _ in 0..<260 {
            for path in [microphone, incoming] {
                samples.withUnsafeBufferPointer { _ = path.inputRing.write($0) }
                path.runHop(now: { 0 })
            }
            model.tick()
            // Yield instead of sleeping: recordAB gives up after a wall-clock deadline, and a
            // sleeping producer overruns it when the machine is loaded.
            await Task.yield()
        }
    }
    // The producer shares the main actor with every other suite, so the take can need far
    // longer than the ten seconds a live call is given.
    await model.recordAB(giveUpAfter: .seconds(600))
    try await producer.value
    #expect(model.screen.state == .saved)
    #expect(model.screen.panes.count == 2)
    #expect(
        model.screen.panes.allSatisfy {
            $0.input.columnsReceived > 0 && $0.output.columnsReceived > 0
        })
    for path in ["mic", "incoming"] {
        let before = try WAVFile(
            decoding: Data(contentsOf: directory.appendingPathComponent("before-\(path)-live.wav")))
        let after = try WAVFile(
            decoding: Data(contentsOf: directory.appendingPathComponent("after-\(path)-live.wav")))
        #expect(before.samples.count == 40_000)
        #expect(before == after)
        #expect(before.samples.allSatisfy { abs($0 - 0.25) < 0.001 })
    }
}

@MainActor
@Test
func aMonitorRecordingRejectsDroppedOrIncompleteAudio() throws {
    let pipeline = Pipeline(
        inputRate: 100, tierRate: 100, outputRate: 100,
        restorer: MonitorPassThroughRestorer(hopFrames: 2), latency: LatencyMeter())
    let stream = MonitorStream(pipeline: pipeline, feed: MonitorFeed())
    stream.beginRecording()
    #expect(throws: UserFacingError.self) { try stream.finishRecording() }
    stream.beginRecording()
    let samples: [Float] = [0.25, 0.25]
    for _ in 0..<101 {
        samples.withUnsafeBufferPointer { _ = pipeline.inputRing.write($0) }
        pipeline.runHop(now: { 0 })
    }
    stream.drain()
    #expect(pipeline.monitorTap.droppedFrames > 0)
    #expect(throws: UserFacingError.self) { try stream.finishRecording() }
}
