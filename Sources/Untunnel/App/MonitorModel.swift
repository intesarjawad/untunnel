import Foundation
import Observation
import UntunnelAudio
import UntunnelDSP
import UntunnelEngine

/// The mailboxes the pipeline publishes one path's spectrum columns into.
struct MonitorFeed: Sendable {
    let input = SpectrumMailbox(rowCount: MonitorLayout.rowCount)
    let output = SpectrumMailbox(rowCount: MonitorLayout.rowCount)
}

/// The monitor window's state: it turns app state, spectrum columns and the clock into a screen.
@MainActor
@Observable
final class MonitorModel {
    /// Blocks for five seconds and returns both sides of one capture.
    typealias Capture = @Sendable () throws -> ABTake

    private struct PaneHistory {
        var input: SpectrogramHistory
        var output: SpectrogramHistory
        var inputPosition = 0
        var outputPosition = 0
    }

    private(set) var screen: MonitorScreen

    /// The mailboxes the pipeline publishes into; a path with no feed shows no audio.
    let feeds: [MonitorPath: MonitorFeed]

    private let appState: AppState
    private let motionProvider: @MainActor () -> MonitorMotion
    private let lateFrames: (@Sendable () -> UInt64)?
    private let capture: Capture?
    private let pipelines: (() -> [MonitorPath: Pipeline])?
    private let monitoring: ((Bool) -> Void)?
    private var streams: [MonitorPath: MonitorStream] = [:]
    private let directory: URL
    private let stamp: @Sendable () -> String
    private let clock: () -> TimeInterval
    private let cpuSeconds: () -> Double
    private var motion: MonitorMotion
    private var histories: [MonitorPath: PaneHistory] = [:]
    private var isRecording = false
    private var recordingNote: String?
    private var hasSavedRecording = false
    private var lastCPU: (cpu: Double, wall: TimeInterval)
    private var cpuPercent: Double?

    init(
        appState: AppState,
        feeds: [MonitorPath: MonitorFeed],
        directory: URL,
        capture: Capture? = nil,
        pipelines: (() -> [MonitorPath: Pipeline])? = nil,
        monitoring: ((Bool) -> Void)? = nil,
        lateFrames: (@Sendable () -> UInt64)? = nil,
        motion: @escaping @MainActor () -> MonitorMotion = { .system },
        stamp: @escaping @Sendable () -> String = MonitorModel.timestamp,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        cpuSeconds: @escaping () -> Double = ProcessCPU.seconds
    ) {
        self.appState = appState
        self.feeds = feeds
        self.directory = directory
        self.capture = capture
        self.pipelines = pipelines
        self.monitoring = monitoring
        self.lateFrames = lateFrames
        motionProvider = motion
        self.stamp = stamp
        self.clock = clock
        self.cpuSeconds = cpuSeconds
        self.motion = motion()
        lastCPU = (cpuSeconds(), clock())
        screen = MonitorScreen(
            state: .idle,
            readouts: MonitorReadouts(),
            panes: [],
            note: nil,
            canRecord: false
        )
        refresh()
    }

    static func live(appState: AppState, controller: MicPathController) -> MonitorModel {
        MonitorModel(
            appState: appState,
            feeds: [.mic: MonitorFeed(), .incoming: MonitorFeed()],
            directory: InstalledPaths.current.support.appendingPathComponent("recordings"),
            pipelines: { controller.monitorPipelines() },
            monitoring: { controller.setMonitoring($0) }
        )
    }

    nonisolated static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    /// Redraws at the interval the current motion setting asks for, until cancelled.
    func run() async {
        monitoring?(true)
        defer {
            monitoring?(false)
            streams = [:]
            histories = [:]
        }
        while !Task.isCancelled {
            tick()
            do {
                try await Task.sleep(for: .seconds(motion.interval))
            } catch {
                return
            }
        }
    }

    /// Drains new columns and rebuilds the screen.
    func tick() {
        if let pipelines {
            let current = pipelines()
            for path in MonitorPath.allCases {
                guard let pipeline = current[path], let feed = feeds[path] else {
                    streams[path]?.pipeline.monitorTap.setEnabled(false)
                    streams[path] = nil
                    histories[path] = nil
                    continue
                }
                if streams[path]?.pipeline !== pipeline {
                    streams[path]?.pipeline.monitorTap.setEnabled(false)
                    streams[path] = MonitorStream(pipeline: pipeline, feed: feed)
                    histories[path] = nil
                }
                streams[path]?.drain()
            }
        }
        let current = motionProvider()
        if current != motion {
            motion = current
            histories = [:]
        }
        for path in activePaths {
            drain(path)
        }
        let now = clock()
        let cpu = cpuSeconds()
        cpuPercent = ProcessCPU.percent(
            cpuSeconds: cpu,
            since: lastCPU.cpu,
            wallSeconds: now - lastCPU.wall
        )
        lastCPU = (cpu, now)
        refresh()
    }

    /// Captures five seconds, writes both WAV files and says where they went. A live path that
    /// has not delivered the take by `giveUpAfter` is reported as stopped and nothing is saved.
    func recordAB(giveUpAfter patience: Duration = .seconds(ABTake.seconds + 5)) async {
        guard !isRecording, capture != nil || !streams.isEmpty else {
            return
        }
        isRecording = true
        recordingNote = nil
        hasSavedRecording = false
        refresh()
        let directory = directory
        let name = stamp()
        do {
            var takes: [String: ABTake] = [:]
            if let capture {
                takes[""] = try await Task.detached(priority: .userInitiated) { try capture() }
                    .value
            } else {
                let selected = streams
                for stream in selected.values { stream.beginRecording() }
                defer { for stream in selected.values { stream.cancelRecording() } }
                let deadline = ContinuousClock.now + patience
                while !selected.values.allSatisfy(\.complete), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                    tick()
                    guard selected.allSatisfy({ streams[$0.key] === $0.value }) else {
                        throw UserFacingError.audioDeviceUnavailable(
                            "the path changed during recording; record again")
                    }
                }
                for (path, stream) in selected {
                    takes[path.rawValue + "-"] = try stream.finishRecording()
                }
            }
            let saved = takes
            let names = try await Task.detached(priority: .utility) {
                try saved.sorted(by: { $0.key < $1.key }).map { prefix, take in
                    let urls = try take.write(into: directory, stamp: prefix + name)
                    return "\(urls.before.lastPathComponent) and \(urls.after.lastPathComponent)"
                }.joined(separator: "; ")
            }.value
            hasSavedRecording = true
            recordingNote = "Saved \(names) in \(directory.path)."
        } catch {
            recordingNote = Self.message(for: error)
        }
        isRecording = false
        refresh()
    }

    /// The paths that have a pane: the microphone unless it is off, incoming audio while restored.
    private var activePaths: [MonitorPath] {
        var paths: [MonitorPath] = []
        if appState.micPath != .off {
            paths.append(.mic)
        }
        if case .restoring = appState.incoming {
            paths.append(.incoming)
        }
        return paths
    }

    private func drain(_ path: MonitorPath) {
        guard let feed = feeds[path] else {
            return
        }
        var pane =
            histories[path]
            ?? PaneHistory(
                input: SpectrogramHistory(
                    rowCount: MonitorLayout.rowCount,
                    columnCount: MonitorLayout.columnCount,
                    mode: motion.historyMode
                ),
                output: SpectrogramHistory(
                    rowCount: MonitorLayout.rowCount,
                    columnCount: MonitorLayout.columnCount,
                    mode: motion.historyMode
                )
            )
        let input = feed.input.columns(since: pane.inputPosition)
        pane.inputPosition = input.position
        pane.input.append(input.levels)
        let output = feed.output.columns(since: pane.outputPosition)
        pane.outputPosition = output.position
        pane.output.append(output.levels)
        histories[path] = pane
    }

    private func refresh() {
        let panes = activePaths.compactMap { path -> MonitorPane? in
            histories[path].map {
                MonitorPane(path: path, source: .live, input: $0.input, output: $0.output)
            }
        }
        let hasAudio = panes.contains { $0.input.columnsReceived > 0 }
        screen = MonitorScreen(
            state: Self.state(
                micPath: appState.micPath,
                isRecording: isRecording,
                hasSaved: hasSavedRecording,
                hasAudio: hasAudio
            ),
            readouts: MonitorReadouts(
                tier: tier,
                addedLatencyMs: appState.addedLatencyMs,
                lateFrames: lateFrames?()
                    ?? (streams.isEmpty
                        ? nil : streams.values.reduce(0) { $0 + $1.pipeline.metrics.lateFrames }),
                cpuPercent: cpuPercent
            ),
            panes: panes,
            note: recordingNote
                ?? (capture == nil && streams.isEmpty
                    ? appState.micError?.message ?? Self.unavailableNote : nil),
            canRecord: (capture != nil || !streams.isEmpty) && !isRecording
        )
    }

    static let unavailableNote =
        "Record \(ABTake.seconds) s A/B needs the restore path, which is not running."

    private var tier: Tier? {
        if case .restoring(let tier) = appState.micPath {
            return tier
        }
        if case .ready(let tier) = appState.engine {
            return tier
        }
        return nil
    }

    /// The state the window is in; the recording states win over what the path is doing.
    nonisolated static func state(
        micPath: AppState.MicPath,
        isRecording: Bool,
        hasSaved: Bool,
        hasAudio: Bool
    ) -> MonitorState {
        if isRecording {
            return .recording
        }
        if hasSaved {
            return .saved
        }
        switch micPath {
        case .bypass:
            return .bypassed
        case .waiting:
            return .waiting
        case .off, .standby, .restoring:
            return hasAudio ? .live : .idle
        }
    }

    private static func message(for error: Error) -> String {
        if let error = error as? UserFacingError {
            return error.message
        }
        return UserFacingError.unexpected(String(describing: error)).message
    }
}
