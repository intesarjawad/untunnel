import Foundation

/// The states the Hear Yourself window and its snapshot render.
enum HearYourselfState: String, CaseIterable, Sendable {
    case idle
    case recording
    case releasing
    case ready
    case narrowband

    var summary: String {
        switch self {
        case .idle:
            return "Record five seconds to hear your voice before and after restoration."
        case .recording:
            return "Recording five seconds through the microphone path."
        case .releasing:
            return
                "Waiting for the headset output to leave call mode; playback starts as soon "
                + "as it does."
        case .ready:
            return "The headset is back at its normal sample rate."
        case .narrowband:
            return "The headset stayed in call mode, so playback is narrowband."
        }
    }
}

/// Everything the monitor shows for one state.
struct HearYourselfScreen: Equatable {
    let state: HearYourselfState
    let side: HearYourselfTake.Side
    let analysis: HearYourselfAnalysis?
    let note: String?

    func text() -> String {
        var lines = ["Hear Yourself", "", "State: \(state.rawValue)", state.summary]
        if showsSide {
            lines.append("Playing: \(side.label) (\(side.content))")
        }
        if let note {
            lines.append("Note: \(note)")
        }
        if let analysis {
            lines.append("")
            lines.append(
                "Take: \(HearYourselfTake.seconds) s at \(analysis.take.sampleRate) Hz"
            )
            lines.append(analysis.before.legend)
            lines.append("")
            lines.append("Before (raw input)")
            lines.append(contentsOf: analysis.before.lines())
            lines.append("")
            lines.append("After (restored)")
            lines.append(contentsOf: analysis.after.lines())
        }
        return lines.joined(separator: "\n")
    }

    private var showsSide: Bool {
        state == .ready || state == .narrowband
    }
}

extension HearYourselfScreen {
    /// The screen the snapshot command renders for one state.
    ///
    /// It uses the demo take, because a snapshot must not open the microphone; the states before
    /// a take exists show no spectrogram.
    static func demo(state: HearYourselfState) -> HearYourselfScreen {
        let showsTake = state == .ready || state == .narrowband
        return HearYourselfScreen(
            state: state,
            side: .before,
            analysis: showsTake ? HearYourselfAnalysis(take: HearYourselfDemo.take()) : nil,
            note: state == .narrowband ? HeadsetRelease.narrowbandNote : nil
        )
    }
}

/// The launch flag `setup` passes so the first run opens the monitor.
enum HearYourselfLaunch {
    static let argument = "--hear-yourself"

    static func requested(arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains(argument)
    }
}
