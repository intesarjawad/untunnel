import AppKit
import Darwin
import Foundation
import SwiftUI
import UntunnelEngine

/// The two audio paths the monitor can show.
enum MonitorPath: String, CaseIterable, Sendable {
    case mic
    case incoming

    var title: String {
        switch self {
        case .mic:
            return "Microphone"
        case .incoming:
            return "Incoming audio"
        }
    }
}

/// The states the monitor window and its snapshot render.
enum MonitorState: String, CaseIterable, Sendable {
    case idle
    case live
    case bypassed
    case waiting
    case recording
    case saved

    var summary: String {
        switch self {
        case .idle:
            return "Waiting for audio. The spectrograms fill in once the restore path is running."
        case .live:
            return "Showing the audio before and after restoration."
        case .bypassed:
            return "Restore is bypassed, so before and after are the same audio."
        case .waiting:
            return "Waiting for the microphone."
        case .recording:
            return "Recording \(ABTake.seconds) seconds of before and after audio."
        case .saved:
            return "The recording is saved."
        }
    }
}

/// Whether a pane shows the running pipeline or a file played back through it.
enum MonitorSource: Equatable, Sendable {
    case live
    case replay

    /// A replay says so, so a screenshot of it cannot pass for the live path.
    var header: String {
        switch self {
        case .live:
            return "Live"
        case .replay:
            return "Replayed recording"
        }
    }
}

/// How the window moves, which the system's reduce-motion setting changes.
struct MonitorMotion: Equatable, Sendable {
    /// Thirty redraws a second matches the most columns the pipeline publishes.
    static let redrawInterval: TimeInterval = 1.0 / 30
    static let reducedRedrawInterval: TimeInterval = 0.5

    let reduceMotion: Bool

    var scrolls: Bool {
        !reduceMotion
    }

    var interval: TimeInterval {
        reduceMotion ? Self.reducedRedrawInterval : Self.redrawInterval
    }

    var historyMode: SpectrogramHistory.Mode {
        reduceMotion ? .sweeping : .scrolling
    }

    @MainActor
    static var system: MonitorMotion {
        MonitorMotion(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }
}

/// The window's fixed grid, shared by every pane so panes stay comparable.
enum MonitorLayout {
    static let rowCount = 96
    static let columnCount = 240
}

/// Tier, added latency, late frames and CPU; a value that was not measured says so.
struct MonitorReadouts: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        let label: String
        let value: String
    }

    var tier: Tier?
    var addedLatencyMs: Double?
    var lateFrames: UInt64?
    var cpuPercent: Double?

    static let notMeasured = "Not measured"

    var rows: [Row] {
        [
            Row(label: "Tier", value: tier.map(Self.tierText) ?? "Not running"),
            Row(
                label: "Added latency",
                value: addedLatencyMs.map { String(format: "%.1f ms", $0) } ?? Self.notMeasured
            ),
            Row(
                label: "Late frames",
                value: lateFrames.map { "\($0)" } ?? Self.notMeasured
            ),
            Row(
                label: "CPU",
                value: cpuPercent.map { String(format: "%.0f %%", $0) } ?? Self.notMeasured
            ),
        ]
    }

    static func tierText(_ tier: Tier) -> String {
        let rate =
            tier.sampleRate % 1_000 == 0
            ? "\(tier.sampleRate / 1_000) kHz" : "\(tier.sampleRate) Hz"
        return "\(rate), exit layer \(tier.exitLayer), look-ahead \(tier.lookAhead)"
    }
}

/// Process CPU use between two readings.
enum ProcessCPU {
    /// User plus system time this process has used, in seconds.
    static func seconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func total(_ value: timeval) -> Double {
            Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
        }
        return total(usage.ru_utime) + total(usage.ru_stime)
    }

    /// CPU time over wall time as a percentage of one core, or nil without elapsed time.
    static func percent(cpuSeconds: Double, since previous: Double, wallSeconds: Double) -> Double?
    {
        guard wallSeconds > 0 else {
            return nil
        }
        return max(0, (cpuSeconds - previous) / wallSeconds * 100)
    }
}

/// One path's input and output spectrograms.
struct MonitorPane: Equatable, Sendable {
    let path: MonitorPath
    let source: MonitorSource
    let input: SpectrogramHistory
    let output: SpectrogramHistory
}

/// Everything the monitor shows at one moment.
struct MonitorScreen: Equatable, Sendable {
    var state: MonitorState
    var readouts: MonitorReadouts
    var panes: [MonitorPane]
    var note: String?
    var canRecord: Bool
}

/// A drawn button, because the system button styles are AppKit controls that `ImageRenderer`
/// replaces with a placeholder, which would leave the snapshot without the control.
struct MonitorButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary, lineWidth: 1)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.5)
            .contentShape(Rectangle())
    }
}

/// The window's content; the snapshot renders this same view.
struct MonitorView: View {
    let screen: MonitorScreen
    var onRecord: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Monitor")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text(screen.state.summary)
            readouts
            ForEach(screen.panes, id: \.path) { pane in
                paneView(pane)
            }
            Button("Record \(ABTake.seconds) s A/B") {
                onRecord()
            }
            .buttonStyle(MonitorButtonStyle())
            .disabled(!screen.canRecord)
            if let note = screen.note {
                Text(note)
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 640, maxWidth: .infinity, alignment: .leading)
    }

    private var readouts: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(screen.readouts.rows, id: \.label) { row in
                HStack {
                    Text(row.label)
                    Spacer()
                    Text(row.value)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func paneView(_ pane: MonitorPane) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(pane.path.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(pane.source.header)
                .font(.caption)
            Text("Before (raw input)")
                .font(.subheadline)
            SpectrogramView(
                title: "\(pane.path.title) before (raw input)",
                history: pane.input
            )
            Text("After (restored)")
                .font(.subheadline)
            SpectrogramView(
                title: "\(pane.path.title) after (restored)",
                history: pane.output
            )
        }
    }
}

/// The Monitor window: it drains the pipeline's columns at the redraw interval.
struct MonitorWindow: View {
    static let windowID = "monitor"

    let model: MonitorModel

    var body: some View {
        ScrollView {
            MonitorView(
                screen: model.screen,
                onRecord: { Task { await model.recordAB() } }
            )
        }
        .frame(minWidth: 580, minHeight: 480)
        .task {
            await model.run()
        }
    }
}
