import Foundation
import SwiftUI
import UntunnelAudio
import os

/// The Hear Yourself window's state and playback controls.
@MainActor
@Observable
final class HearYourselfModel {
    /// How often the view asks the headset for its rate while playback waits.
    static let pollInterval = Duration.milliseconds(250)
    private static let logger = Logger(subsystem: "com.intesarjawad.untunnel", category: "audio")

    private(set) var state = HearYourselfState.idle
    private(set) var side = HearYourselfTake.Side.before
    private(set) var analysis: HearYourselfAnalysis?
    private(set) var note: String?

    private let recorder: @Sendable () throws -> HearYourselfTake
    private let output: () -> (any HeadphoneOutput)?
    private let rates: () -> (any HeadsetRateSource)?
    private var playingOutput: (any HeadphoneOutput)?
    private let clock: @Sendable () -> TimeInterval
    private var release: HeadsetRelease?
    private var playedAfter = false

    init(
        recorder: @escaping @Sendable () throws -> HearYourselfTake,
        output: @escaping () -> (any HeadphoneOutput)?,
        rates: @escaping () -> (any HeadsetRateSource)?,
        clock: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.recorder = recorder
        self.output = output
        self.rates = rates
        self.clock = clock
    }

    /// Builds the monitor around the selected headset, or around the system defaults.
    ///
    /// The after side runs through the model the app loaded, at its tier. Without a model it
    /// is the raw take, and the take says why.
    static func live(
        model: LoadedModel,
        selection: @escaping @Sendable () -> DeviceSelection = {
            AudioDevices(source: CoreAudioDeviceSource()).snapshot.selection
        },
        capture: @escaping @Sendable (String) throws -> any AudioCaptureSource = {
            try HALCaptureSource(uid: $0)
        },
        output: @escaping (String) -> any HeadphoneOutput = { HeadsetOutput(uid: $0) },
        rates: @escaping (String) -> any HeadsetRateSource = { CoreAudioHeadsetRateSource(uid: $0) }
    ) -> HearYourselfModel {
        return HearYourselfModel(
            recorder: {
                let currentSelection = selection()
                guard let input = currentSelection.input ?? currentSelection.headset else {
                    throw UserFacingError.audioDeviceUnavailable("the headset input")
                }
                let source = try capture(input.uid)
                let rate = source.format.sampleRate
                let current = model.current
                let stage = (current ?? .unavailable(.modelMissing))
                    .makeRestorer(fallbackRate: rate)
                guard stage.rate % 100 == 0 else {
                    throw UserFacingError.audioDeviceUnavailable(
                        "a \(rate) Hz headset input"
                    )
                }
                var take = try HearYourselfRecorder(
                    source: source,
                    tierRate: stage.rate,
                    restorer: stage.restorer
                ).record()
                take.afterNote = HearYourselfModel.afterNote(for: current)
                return take
            },
            output: {
                let current = selection()
                return (current.headset ?? current.output).map { output($0.uid) }
            },
            rates: {
                let current = selection()
                return (current.headset ?? current.output).map { rates($0.uid) }
            }
        )
    }

    /// Records five seconds, then waits for the headset to leave call mode.
    func record() async {
        guard state != .recording else {
            return
        }
        state = .recording
        note = nil
        analysis = nil
        stop()
        let idleRate = rates()?.outputRateHz()
        let recorder = recorder
        do {
            let analysis = try await Task.detached(priority: .userInitiated) {
                HearYourselfAnalysis(take: try recorder())
            }.value
            self.analysis = analysis
            side = .before
            release = HeadsetRelease(idleRateHz: idleRate, startedAt: clock())
            state = .releasing
        } catch {
            note = Self.message(for: error)
            state = .idle
        }
    }

    /// Asks the headset for its rate once and moves on when the wait is over.
    func poll() {
        poll(rateHz: rates()?.outputRateHz(), now: clock())
    }

    /// Applies one reading of the headset rate and the current time.
    func poll(rateHz: Double?, now: TimeInterval) {
        guard let release else {
            return
        }
        switch release.decide(rateHz: rateHz, now: now) {
        case .waiting:
            return
        case .ready:
            finishRelease(note: nil)
        case .timedOut:
            finishRelease(note: HeadsetRelease.narrowbandNote)
        }
    }

    /// Switches the side and plays it, which is the Before/After control's only action.
    func select(_ side: HearYourselfTake.Side) {
        self.side = side
        play()
    }

    /// Stops the headset output.
    func stop() {
        playingOutput?.stop()
    }

    /// Polls until the wait ends; the view owns the loop so the model stays free of timers.
    func pollWhileReleasing() async {
        while state == .releasing {
            do {
                try await Task.sleep(for: Self.pollInterval)
            } catch {
                return
            }
            poll()
        }
    }

    private func finishRelease(note: String?) {
        release = nil
        self.note = note ?? analysis?.take.afterNote
        state = note == nil ? .ready : .narrowband
        play()
    }

    /// The line that tells a listener After is their raw voice, or nil when the model ran.
    nonisolated static func afterNote(for model: MicModel?) -> String? {
        switch model {
        case .ready:
            return nil
        case .unavailable(let error):
            return "After is your raw voice: \(error.message) \(error.fix)"
        case nil:
            return "After is your raw voice because the restore model was still loading; "
                + "record again."
        }
    }

    private func play() {
        guard let analysis else {
            return
        }
        playingOutput?.stop()
        playingOutput = output()
        guard let output = playingOutput else {
            note = UserFacingError.audioDeviceUnavailable("the headset output").message
            return
        }
        do {
            try output.play(
                analysis.take.samples(side),
                sampleRate: analysis.take.sampleRate
            )
            // The cold-start measurement stops its clock at this event.
            if side == .after, !playedAfter {
                playedAfter = true
                Self.logger.notice("first_ab_played")
            }
        } catch {
            note = UserFacingError.audioDeviceUnavailable(String(describing: error)).message
        }
    }

    private static func message(for error: Error) -> String {
        if let error = error as? UserFacingError {
            return error.message
        }
        return UserFacingError.unexpected(String(describing: error)).message
    }
}

struct HearYourselfView: View {
    static let windowID = "hear-yourself"

    @Bindable var model: HearYourselfModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Hear Yourself")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(model.state.summary)
                if let note = model.note {
                    Text(note)
                }
                controls
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 460, minHeight: 320)
        .task(id: model.state) {
            await model.pollWhileReleasing()
        }
        .onDisappear {
            model.stop()
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch model.state {
        case .idle:
            Button("Record five seconds") {
                Task { await model.record() }
            }
        case .recording:
            Label(
                "Recording five seconds through the microphone path",
                systemImage: "waveform"
            )
        case .releasing:
            Label("Waiting for the headset to leave call mode", systemImage: "hourglass")
        case .ready, .narrowband:
            comparison
        }
    }

    private var comparison: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(
                "Compare",
                selection: Binding(
                    get: { model.side },
                    set: { model.select($0) }
                )
            ) {
                ForEach(HearYourselfTake.Side.allCases, id: \.self) { side in
                    Text(side.label).tag(side)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.analysis == nil)

            if let analysis = model.analysis {
                Text(analysis.before.legend)
                    .font(.caption)
                spectrogram("Before (raw input)", analysis.before)
                spectrogram("After (restored)", analysis.after)
            }

            Button("Record again") {
                Task { await model.record() }
            }
        }
    }

    private func spectrogram(_ title: String, _ spectrogram: Spectrogram) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(spectrogram.lines().joined(separator: "\n"))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityLabel("\(title) spectrogram. \(spectrogram.legend)")
        }
    }
}
