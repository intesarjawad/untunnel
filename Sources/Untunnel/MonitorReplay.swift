import Foundation

extension MonitorScreen {
    /// A monitor screen built from a recorded take instead of the running pipeline.
    ///
    /// The take goes through the same analyzer and publisher the live path uses, and every pane is
    /// marked as a replay. Readouts stay unmeasured because nothing was running to measure.
    static func replay(
        state: MonitorState,
        path: MonitorPath,
        motion: MonitorMotion,
        take: HearYourselfTake
    ) -> MonitorScreen {
        let showsAudio = [.live, .bypassed, .recording, .saved].contains(state)
        func history(_ samples: [Float]?) -> SpectrogramHistory {
            guard let samples else {
                return SpectrogramHistory(
                    rowCount: MonitorLayout.rowCount,
                    columnCount: MonitorLayout.columnCount,
                    mode: motion.historyMode
                )
            }
            return SpectrogramHistory.replay(
                samples,
                sampleRate: take.sampleRate,
                rowCount: MonitorLayout.rowCount,
                columnCount: MonitorLayout.columnCount,
                mode: motion.historyMode
            )
        }
        let output = state == .bypassed ? take.raw : take.restored
        return MonitorScreen(
            state: state,
            readouts: MonitorReadouts(),
            panes: [
                MonitorPane(
                    path: path,
                    source: .replay,
                    input: history(showsAudio ? take.raw : nil),
                    output: history(showsAudio ? output : nil)
                )
            ],
            note: note(for: state),
            canRecord: false
        )
    }

    private static func note(for state: MonitorState) -> String? {
        switch state {
        case .waiting:
            return "Waiting for the headset microphone."
        case .saved:
            return "Saved the before and after recordings."
        case .idle, .live, .bypassed, .recording:
            return nil
        }
    }
}
