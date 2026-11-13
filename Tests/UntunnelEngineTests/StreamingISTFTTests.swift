import Foundation
import Testing
import UntunnelEngine

private let sampleRates = [16_000, 24_000, 32_000, 48_000]

@Test(arguments: sampleRates)
func streamingISTFTReconstructsReferenceSignal(sampleRate: Int) throws {
    let reference = try #require(
        try loadSTFTReference().first { $0.sampleRate == sampleRate }
    )
    let transform = StreamingISTFT(
        tier: Tier(sampleRate: sampleRate, exitLayer: 0, lookAhead: 0)
    )

    let output = synthesizedSamples(reference.frames, with: transform)

    #expect(output.count == reference.signal.count)
    #expect(maximumError(output, reference.signal) <= 1e-5)
}

@Test(arguments: roundTripCases)
func streamingRoundTripReconstructsRandomAudio(_ testCase: RoundTripCase) {
    let tier = Tier(sampleRate: testCase.sampleRate, exitLayer: 0, lookAhead: 0)
    let stft = StreamingSTFT(tier: tier)
    let istft = StreamingISTFT(tier: tier)

    var generator = SplitMix64(seed: testCase.seed)
    let length = 6 * stft.hopLength
    var signal = [Float](repeating: 0, count: length)
    for index in signal.indices {
        signal[index] = Float.random(in: -0.8...0.8, using: &generator)
    }

    let frames = analyzedFrames(signal, with: stft)
    #expect(frames.count == length / stft.hopLength + 1)
    let output = synthesizedSamples(frames, with: istft)

    #expect(output.count == signal.count)
    #expect(maximumError(output, signal) <= 1e-5)
}

struct RoundTripCase: Sendable {
    let seed: UInt64
    let sampleRate: Int
}

extension RoundTripCase: CustomTestStringConvertible {
    var testDescription: String {
        "seed \(seed) at \(sampleRate) Hz"
    }
}

let roundTripCases = [UInt64(0), 1, 2, 3].flatMap { seed in
    sampleRates.map { RoundTripCase(seed: seed, sampleRate: $0) }
}

private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
