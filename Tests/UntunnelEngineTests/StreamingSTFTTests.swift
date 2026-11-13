import Foundation
import Testing
import UntunnelEngine

private let sampleRates = [16_000, 24_000, 32_000, 48_000]

@Test(arguments: sampleRates)
func streamingSTFTMatchesReferenceColumns(sampleRate: Int) throws {
    let reference = try #require(
        try loadSTFTReference().first { $0.sampleRate == sampleRate }
    )
    let transform = StreamingSTFT(
        tier: Tier(sampleRate: sampleRate, exitLayer: 0, lookAhead: 0)
    )

    #expect(transform.windowLength == reference.windowLength)
    #expect(transform.hopLength == reference.hopLength)
    let frames = analyzedFrames(reference.signal, with: transform)
    #expect(frames.count == reference.frames.count)

    for (actual, expected) in zip(frames, reference.frames) {
        #expect(maximumError(actual.magnitudes, expected.magnitudes) <= 1e-5)
        #expect(maximumPhaseError(actual.phases, expected.phases) <= 1e-5)
    }
}

@Test(arguments: sampleRates)
func streamingSTFTCompressesAConstantSignal(sampleRate: Int) {
    let transform = StreamingSTFT(
        tier: Tier(sampleRate: sampleRate, exitLayer: 0, lookAhead: 0)
    )
    let bins = transform.binCount
    let hop = [Float](repeating: 1, count: transform.hopLength)
    var magnitudes = [Float](repeating: 0, count: 2 * bins)
    var phases = [Float](repeating: 0, count: 2 * bins)
    var frames: [STFTColumns] = []

    for _ in 0..<2 {
        let count = hop.withUnsafeBufferPointer { input in
            magnitudes.withUnsafeMutableBufferPointer { magnitudeBuffer in
                phases.withUnsafeMutableBufferPointer { phaseBuffer in
                    transform.process(input, magnitudes: magnitudeBuffer, phases: phaseBuffer)
                }
            }
        }
        frames.append(contentsOf: columns(magnitudes, phases, bins: bins, count: count))
    }

    // A periodic Hann window sums to N/2 and its first side bin has magnitude N/4, so a
    // constant frame carries log1p(N/2) at DC, log1p(N/4) at bin one, and nothing above.
    let dc = log1p(Float(transform.windowLength) / 2)
    let side = log1p(Float(transform.windowLength) / 4)
    #expect(frames.count == 2)
    let zeroBins = [Float](repeating: 0, count: bins - 2)
    for frame in frames {
        #expect(abs(frame.magnitudes[0] - dc) <= 1e-5)
        #expect(abs(frame.magnitudes[1] - side) <= 1e-5)
        #expect(maximumError(Array(frame.magnitudes[2...]), zeroBins) <= 1e-4)
    }
}
