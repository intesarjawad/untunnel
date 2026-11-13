import Foundation
import Synchronization
import Testing
import UntunnelAudio

@testable import Untunnel

private final class FakeCaptureSource: AudioCaptureSource, @unchecked Sendable {
    let format: AudioStreamFormat
    private let frames: [Float]

    init(frames: [Float], sampleRate: Int = 1_000) {
        self.frames = frames
        format = AudioStreamFormat(
            sampleRate: sampleRate, hopFrames: sampleRate / Pipeline.hopsPerSecond)
    }

    func start(
        _ onHop: @escaping @Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void
    ) throws {
        frames.withUnsafeBufferPointer { onHop($0, 0) }
    }

    func stop() {}
}

private final class HalvingRestorer: PipelineRestorer {
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
            output[index] = input[index] * 0.5
        }
        return count
    }

    func reset() {}
}

private final class FakeHeadphoneOutput: HeadphoneOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(samples: [Float], sampleRate: Int)] = []

    var played: [[Float]] {
        lock.withLock { stored.map(\.samples) }
    }

    func play(_ samples: [Float], sampleRate: Int) throws {
        lock.withLock { stored.append((samples, sampleRate)) }
    }

    func stop() {}
}

private final class FixedHeadsetRateSource: HeadsetRateSource, @unchecked Sendable {
    private let rate: Double?

    init(rate: Double?) {
        self.rate = rate
    }

    func outputRateHz() -> Double? {
        rate
    }
}

@Test
func takeTrimsAndRestoresTheSameFiveSecondPass() throws {
    let recorder = HearYourselfRecorder(
        source: FakeCaptureSource(frames: [Float](repeating: 1, count: 6_000)),
        tierRate: 1_000,
        restorer: HalvingRestorer(hopFrames: 20)
    )

    let take = try recorder.record()

    #expect(take.sampleRate == 1_000)
    #expect(take.duration == 5)
    #expect(take.raw.count == 5_000)
    #expect(take.restored.count == 5_000)
    #expect(take.raw.allSatisfy { $0 == 1 })
    #expect(take.restored.allSatisfy { $0 == 0.5 })
    #expect(take.samples(.before) == take.raw)
    #expect(take.samples(.after) == take.restored)
}

@Test
func takePadsAShortCaptureWithSilence() {
    let take = HearYourselfTake.make(
        raw: [Float](repeating: 1, count: 1_000),
        inputRate: 1_000,
        tierRate: 1_000,
        restorer: HalvingRestorer(hopFrames: 20)
    )

    #expect(take.raw.count == 5_000)
    #expect(take.restored.count == 5_000)
    #expect(take.raw[999] == 1)
    #expect(take.raw[1_000] == 0)
    #expect(take.restored[1_500] == 0)
}

@Test
func demoTakeKeepsBothSidesOfOnePass() {
    let take = HearYourselfDemo.take()

    #expect(take.sampleRate == 8_000)
    #expect(take.duration == 5)
    #expect(take.raw.count == 40_000)
    #expect(take.restored.count == 40_000)
    #expect(take.restored != take.raw)
}

@Test
func demoAfterTakeCarriesMoreEnergyInTheUpperShelf() {
    let analysis = HearYourselfAnalysis(take: HearYourselfDemo.take())
    let upper = analysis.before.shelf.firstIndex { $0 >= 3_000 } ?? 0

    let before = analysis.before.levels[upper].max() ?? 0
    let after = analysis.after.levels[upper].max() ?? 0
    #expect(after > before)
}

@Test
func spectrogramPutsAToneInItsOwnShelf() {
    let sampleRate = 8_000
    let tone = (0..<sampleRate).map { index in
        Float(0.5 * sin(2 * .pi * 900 * Double(index) / Double(sampleRate)))
    }

    let spectrogram = Spectrogram.analyse(tone, sampleRate: sampleRate)
    let loudest = spectrogram.levels.enumerated().max { lhs, rhs in
        (lhs.element.max() ?? 0) < (rhs.element.max() ?? 0)
    }?.offset

    #expect(spectrogram.shelf == [125, 250, 500, 1_000, 2_000, 3_000, 3_500, 4_000])
    #expect(loudest == 3)
}

@Test
func headsetReleaseWaitsUntilTheOutputReturnsToItsIdleRate() {
    let release = HeadsetRelease(idleRateHz: 48_000, startedAt: 10)

    #expect(release.decide(rateHz: 16_000, now: 10.5) == .waiting)
    #expect(release.decide(rateHz: 48_000, now: 11) == .ready)
}

@Test
func headsetReleasePlaysAnywayAtTheEightSecondTimeout() {
    let release = HeadsetRelease(idleRateHz: 48_000, startedAt: 10)

    #expect(release.decide(rateHz: 24_000, now: 17.99) == .waiting)
    #expect(release.decide(rateHz: 24_000, now: 18) == .timedOut)
    #expect(release.decide(rateHz: 48_000, now: 18) == .ready)
    #expect(
        HeadsetRelease(idleRateHz: nil, startedAt: 0).decide(rateHz: nil, now: 8)
            == .timedOut
    )
}

@MainActor
@Test
func monitorWaitsForTheHeadsetThenPlaysBeforeAndAfter() async {
    let take = HearYourselfDemo.take()
    let output = FakeHeadphoneOutput()
    let model = HearYourselfModel(
        recorder: { take },
        output: { output },
        rates: { FixedHeadsetRateSource(rate: 48_000) },
        clock: { 0 }
    )

    await model.record()
    #expect(model.state == .releasing)

    model.poll(rateHz: 16_000, now: 4)
    #expect(model.state == .releasing)
    #expect(output.played.isEmpty)

    model.poll(rateHz: 48_000, now: 4.25)
    #expect(model.state == .ready)
    #expect(model.side == .before)
    #expect(output.played == [take.samples(.before)])

    model.select(.after)
    #expect(model.side == .after)
    #expect(output.played == [take.samples(.before), take.samples(.after)])
}

@MainActor
@Test
func monitorPlaysNarrowbandAnywayAfterTheTimeout() async {
    let take = HearYourselfDemo.take()
    let output = FakeHeadphoneOutput()
    let model = HearYourselfModel(
        recorder: { take },
        output: { output },
        rates: { FixedHeadsetRateSource(rate: 48_000) },
        clock: { 100 }
    )

    await model.record()
    model.poll(rateHz: 16_000, now: 107.9)
    #expect(model.state == .releasing)
    #expect(output.played.isEmpty)

    model.poll(rateHz: 16_000, now: 108)
    #expect(model.state == .narrowband)
    #expect(model.note == HeadsetRelease.narrowbandNote)
    #expect(output.played == [take.samples(.before)])
}

@Test
func hearYourselfLaunchIsOnlyRequestedByItsFlag() {
    #expect(HearYourselfLaunch.requested(arguments: ["untunnel"]) == false)
    #expect(
        HearYourselfLaunch.requested(arguments: ["untunnel", "--hear-yourself"])
    )
}

@MainActor
@Test
func hearYourselfReselectsCaptureAndPlaybackAfterDeviceChanges() async {
    let selectedUID = Mutex("launch")
    let capturedUIDs = Mutex<[String]>([])
    var outputUIDs: [String] = []
    var rateUIDs: [String] = []
    let model = HearYourselfModel.live(
        model: LoadedModel(),
        selection: {
            let uid = selectedUID.withLock { $0 }
            let device = AudioDevice(
                uid: uid, name: uid, transport: .bluetooth, hasInput: true, hasOutput: true,
                nominalSampleRate: 8_000, dataSource: .none)
            return DeviceSelection(virtualMic: nil, headset: device, input: device, output: device)
        },
        capture: { uid in
            capturedUIDs.withLock { $0.append(uid) }
            return FakeCaptureSource(
                frames: [Float](repeating: 0, count: 40_000), sampleRate: 8_000)
        },
        output: { uid in
            outputUIDs.append(uid)
            return FakeHeadphoneOutput()
        },
        rates: { uid in
            rateUIDs.append(uid)
            return FixedHeadsetRateSource(rate: 48_000)
        }
    )
    selectedUID.withLock { $0 = "connected" }
    await model.record()
    #expect(capturedUIDs.withLock { $0 } == ["connected"])
    selectedUID.withLock { $0 = "playback" }
    model.poll()
    #expect(outputUIDs.last == "playback")
    selectedUID.withLock { $0 = "replacement" }
    await model.record()
    #expect(capturedUIDs.withLock { $0 } == ["connected", "replacement"])
    #expect(rateUIDs == ["connected", "playback", "replacement"])
}
