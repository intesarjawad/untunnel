import Foundation
import UntunnelAudio
import UntunnelDSP
import UntunnelEngine

/// Five seconds of headset input, kept raw and restored from the same pass.
///
/// Both sides share a rate and a length, so the Before/After control swaps playback without a
/// gap or a second recording.
struct HearYourselfTake: Equatable, Sendable {
    /// The take lasts five seconds: long enough to judge a voice, short enough to repeat.
    static let seconds = 5

    enum Side: String, CaseIterable, Sendable {
        case before
        case after

        var label: String {
            switch self {
            case .before:
                return "Before"
            case .after:
                return "After"
            }
        }

        var content: String {
            switch self {
            case .before:
                return "raw input"
            case .after:
                return "restored"
            }
        }
    }

    let sampleRate: Int
    let raw: [Float]
    let restored: [Float]
    /// Why the after side is not restored, shown once playback starts.
    var afterNote: String?

    var duration: TimeInterval {
        Double(raw.count) / Double(sampleRate)
    }

    func samples(_ side: Side) -> [Float] {
        switch side {
        case .before:
            return raw
        case .after:
            return restored
        }
    }

    /// Builds both sides from one capture, restoring ten-millisecond hops in order.
    static func make(
        raw capture: [Float],
        inputRate: Int,
        tierRate: Int,
        restorer: any PipelineRestorer
    ) -> HearYourselfTake {
        precondition(inputRate > 0 && tierRate > 0, "sample rates must be positive")
        precondition(
            tierRate % Pipeline.hopsPerSecond == 0, "the tier rate must make a whole hop")
        let hopFrames = tierRate / Pipeline.hopsPerSecond
        precondition(restorer.hopFrames == hopFrames, "the restorer must consume one hop")

        let count = tierRate * seconds
        let raw =
            inputRate == tierRate
            ? Self.fitted(capture, count: count)
            : PolyphaseResampler(inputRate: inputRate, outputRate: tierRate)
                .resample(capture, count: count)

        var restored = [Float](repeating: 0, count: count)
        for start in stride(from: 0, to: count, by: hopFrames) {
            let end = min(start + hopFrames, count)
            let produced = raw.withUnsafeBufferPointer { source in
                restored.withUnsafeMutableBufferPointer { wet in
                    restorer.process(
                        UnsafeBufferPointer(rebasing: source[start..<end]),
                        into: UnsafeMutableBufferPointer(rebasing: wet[start..<end])
                    )
                }
            }
            precondition(
                produced <= end - start,
                "the restorer wrote past the hop it was given"
            )
        }
        return HearYourselfTake(sampleRate: tierRate, raw: raw, restored: restored)
    }

    /// Trims or silence-extends a capture to exactly `count` frames.
    private static func fitted(_ samples: [Float], count: Int) -> [Float] {
        guard samples.count > count else {
            return samples + [Float](repeating: 0, count: count - samples.count)
        }
        return Array(samples.prefix(count))
    }
}

/// Captures the five-second take from the headset input.
///
/// The capture callback only appends under a lock, and the caller waits for the frame count or
/// the timeout, so a device that never delivers cannot hang the window.
final class HearYourselfRecorder: @unchecked Sendable {
    /// Five seconds plus room for a device that starts slowly.
    static let captureTimeout: TimeInterval = 10

    private let source: any AudioCaptureSource
    private let tierRate: Int
    private let restorer: any PipelineRestorer
    private let neededFrames: Int
    private let filled = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var captured: [Float] = []
    private var hasSignalled = false

    init(
        source: any AudioCaptureSource,
        tierRate: Int,
        restorer: any PipelineRestorer
    ) {
        self.source = source
        self.tierRate = tierRate
        self.restorer = restorer
        neededFrames = source.format.sampleRate * HearYourselfTake.seconds
    }

    /// Records until the take is full, then restores the same frames into the after side.
    func record() throws -> HearYourselfTake {
        do {
            try source.start { [self] frames, _ in
                append(frames)
            }
        } catch {
            throw UserFacingError.audioDeviceUnavailable(String(describing: error))
        }
        _ = filled.wait(
            timeout: .now() + .milliseconds(Int(Self.captureTimeout * 1_000))
        )
        source.stop()

        let raw = lock.withLock { captured }
        guard !raw.isEmpty else {
            throw UserFacingError.audioDeviceUnavailable("the headset input")
        }
        return HearYourselfTake.make(
            raw: raw,
            inputRate: source.format.sampleRate,
            tierRate: tierRate,
            restorer: restorer
        )
    }

    private func append(_ frames: UnsafeBufferPointer<Float>) {
        let justFilled = lock.withLock { () -> Bool in
            guard captured.count < neededFrames else {
                return false
            }
            let room = neededFrames - captured.count
            captured.append(contentsOf: frames.prefix(room))
            guard captured.count >= neededFrames, !hasSignalled else {
                return false
            }
            hasSignalled = true
            return true
        }
        if justFilled {
            filled.signal()
        }
    }
}

/// When the headset output leaves call mode after a recording.
///
/// A recording opens the headset at a narrowband rate; macOS returns it to its idle rate once
/// the call ends. Playback waits for that rate, and after the timeout it plays narrowband
/// anyway so the window never stays stuck.
struct HeadsetRelease: Equatable {
    /// The longest wait before playback starts regardless of the headset.
    static let timeout: TimeInterval = 8
    static let narrowbandNote =
        "your headset is still in call mode, so playback is narrowband"

    enum Decision: Equatable {
        case waiting
        case ready
        case timedOut
    }

    /// The rate the output had before recording began, or nil when no device was present.
    let idleRateHz: Double?
    let startedAt: TimeInterval

    func decide(rateHz: Double?, now: TimeInterval) -> Decision {
        if let idleRateHz, rateHz == idleRateHz {
            return .ready
        }
        return now - startedAt >= Self.timeout ? .timedOut : .waiting
    }
}

/// Both sides of one take with the spectrograms the window shows.
struct HearYourselfAnalysis: Equatable, Sendable {
    let take: HearYourselfTake
    let before: Spectrogram
    let after: Spectrogram

    init(take: HearYourselfTake) {
        self.take = take
        before = Spectrogram.analyse(take.raw, sampleRate: take.sampleRate)
        after = Spectrogram.analyse(take.restored, sampleRate: take.sampleRate)
    }
}

/// A coarse spectrogram: one row per frequency shelf, one column per pooled time step.
///
/// The shelf edges are display bands shared by both takes, not an audio filter, so the two
/// spectrograms can be read against each other.
struct Spectrogram: Equatable, Sendable {
    /// Upper edge of each shelf in hertz, lowest first, ending at Nyquist.
    let shelf: [Int]
    /// Row-major levels, 0 for silence and 1 at the take's loudest shelf.
    let levels: [[Float]]

    /// Columns the display pools time into; a five-second take stays readable in a window.
    static let columnCount = 48

    /// The eight shelf edges as fractions of Nyquist.
    private static let shelfFractions: [Double] = [
        1.0 / 32, 1.0 / 16, 1.0 / 8, 1.0 / 4, 1.0 / 2, 3.0 / 4, 7.0 / 8, 1,
    ]

    static func shelfEdges(sampleRate: Int) -> [Int] {
        let nyquist = Double(sampleRate) / 2
        return shelfFractions.map { Int((nyquist * $0).rounded()) }
    }

    static func analyse(_ samples: [Float], sampleRate: Int) -> Spectrogram {
        precondition(sampleRate > 0 && sampleRate % 100 == 0, "a shelf needs a tier rate")
        let shelf = shelfEdges(sampleRate: sampleRate)
        let stft = StreamingSTFT(
            tier: Tier(sampleRate: sampleRate, exitLayer: 1, lookAhead: 0)
        )
        let capacity = max(1, samples.count / stft.hopLength)
        var magnitudes = [Float](repeating: 0, count: capacity * stft.binCount)
        var phases = [Float](repeating: 0, count: capacity * stft.binCount)
        let frames = samples.withUnsafeBufferPointer { input in
            magnitudes.withUnsafeMutableBufferPointer { magnitudes in
                phases.withUnsafeMutableBufferPointer { phases in
                    stft.process(input, magnitudes: magnitudes, phases: phases)
                }
            }
        }

        var pooled = [[Float]](
            repeating: [Float](repeating: 0, count: columnCount),
            count: shelf.count
        )
        guard frames > 0 else {
            return Spectrogram(shelf: shelf, levels: pooled)
        }
        for frame in 0..<frames {
            let column = min(columnCount - 1, frame * columnCount / frames)
            for bin in 0..<stft.binCount {
                let hertz = Double(bin) * Double(sampleRate) / Double(stft.windowLength)
                let row = shelf.firstIndex { Double($0) >= hertz } ?? shelf.count - 1
                pooled[row][column] = max(
                    pooled[row][column],
                    magnitudes[frame * stft.binCount + bin]
                )
            }
        }

        let peak = pooled.flatMap { $0 }.max() ?? 0
        guard peak > 0 else {
            return Spectrogram(shelf: shelf, levels: pooled)
        }
        for row in pooled.indices {
            for column in pooled[row].indices {
                pooled[row][column] /= peak
            }
        }
        return Spectrogram(shelf: shelf, levels: pooled)
    }

    /// The rows as plain text, so a snapshot and a screen reader get the same figure.
    func lines() -> [String] {
        let characters = Array(" .:-=+*#%@")
        return shelf.enumerated().map { row, edge in
            let label = Self.frequencyText(edge)
            let padded = label + String(repeating: " ", count: max(0, 8 - label.count))
            let body = levels[row].map { level -> String in
                let index = min(
                    characters.count - 1,
                    Int(level * Float(characters.count - 1))
                )
                return String(characters[index])
            }
            return "  \(padded) \(body.joined())"
        }
    }

    var legend: String {
        "Shelves: " + shelf.map(Self.frequencyText).joined(separator: ", ")
    }

    static func frequencyText(_ hertz: Int) -> String {
        guard hertz >= 1_000 else {
            return "\(hertz) Hz"
        }
        return String(format: "%.1f kHz", Double(hertz) / 1_000)
    }
}

/// The demo input the snapshot command and the tests record from.
///
/// No microphone and no checkpoint are available to a test or a snapshot, so the take comes
/// from three fixed tones that put energy in three different shelves.
enum HearYourselfDemo {
    /// Low enough that building a take and both spectrograms stays cheap.
    static let sampleRate = 8_000

    static func input(sampleRate: Int) -> [Float] {
        (0..<(sampleRate * HearYourselfTake.seconds)).map { index in
            let time = Double(index) / Double(sampleRate)
            return Float(
                0.4 * sin(2 * .pi * 250 * time)
                    + 0.2 * sin(2 * .pi * 1_000 * time)
                    + 0.1 * sin(2 * .pi * 3_000 * time)
            )
        }
    }

    static func take() -> HearYourselfTake {
        HearYourselfTake.make(
            raw: input(sampleRate: sampleRate),
            inputRate: sampleRate,
            tierRate: sampleRate,
            restorer: DemoShelfRestorer(hopFrames: sampleRate / Pipeline.hopsPerSecond)
        )
    }
}

/// Lifts the upper band, standing in for the model when no checkpoint is loaded.
///
/// A subtle high shelf still gives the after spectrogram its shape, so the window and the
/// snapshot show the A/B difference the model will produce.
final class DemoShelfRestorer: PipelineRestorer {
    let hopFrames: Int
    private let smoothing: Float
    private var lowpass: Float = 0

    init(hopFrames: Int, smoothing: Float = 0.02) {
        self.hopFrames = hopFrames
        self.smoothing = smoothing
    }

    func process(
        _ input: UnsafeBufferPointer<Float>,
        into output: UnsafeMutableBufferPointer<Float>
    ) -> Int {
        let count = min(input.count, output.count)
        for index in 0..<count {
            lowpass += smoothing * (input[index] - lowpass)
            output[index] = input[index] + 0.8 * (input[index] - lowpass)
        }
        return count
    }

    func reset() {
        lowpass = 0
    }
}

/// Passes the take through unchanged for the live monitor.
///
/// The window records its after side with whatever restorer the app gives it; until a checkpoint
/// is loaded the live path passes the input through, and the A/B switch plays the same audio.
final class MonitorPassThroughRestorer: PipelineRestorer {
    let hopFrames: Int

    init(hopFrames: Int) {
        self.hopFrames = hopFrames
    }

    func process(
        _ input: UnsafeBufferPointer<Float>,
        into output: UnsafeMutableBufferPointer<Float>
    ) -> Int {
        let count = min(input.count, output.count)
        for index in 0..<count {
            output[index] = input[index]
        }
        return count
    }

    func reset() {}
}
