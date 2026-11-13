import Foundation
import UntunnelEngine

struct STFTReference: Decodable {
    let cases: [STFTReferenceCase]
}

struct STFTReferenceCase: Decodable, Sendable {
    let sampleRate: Int
    let windowLength: Int
    let hopLength: Int
    let signal: [Float]
    let frames: [STFTColumns]

    private enum CodingKeys: String, CodingKey {
        case sampleRate = "sample_rate"
        case windowLength = "window_length"
        case hopLength = "hop_length"
        case signal
        case frames
    }
}

struct STFTColumns: Decodable, Sendable {
    let magnitudes: [Float]
    let phases: [Float]
}

func loadSTFTReference() throws -> [STFTReferenceCase] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("fixtures/stft/reference.json")
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(STFTReference.self, from: data).cases
}

/// Runs a whole signal through the transform and returns the frames it produced.
func analyzedFrames(_ signal: [Float], with transform: StreamingSTFT) -> [STFTColumns] {
    let bins = transform.binCount
    let hopLength = transform.hopLength
    var frameMagnitudes = [Float](repeating: 0, count: 2 * bins)
    var framePhases = [Float](repeating: 0, count: 2 * bins)
    var frames: [STFTColumns] = []

    for start in stride(from: 0, to: signal.count, by: hopLength) {
        let count = signal.withUnsafeBufferPointer { input in
            frameMagnitudes.withUnsafeMutableBufferPointer { magnitudes in
                framePhases.withUnsafeMutableBufferPointer { phases in
                    transform.process(
                        UnsafeBufferPointer(rebasing: input[start..<start + hopLength]),
                        magnitudes: magnitudes,
                        phases: phases
                    )
                }
            }
        }
        frames.append(contentsOf: columns(frameMagnitudes, framePhases, bins: bins, count: count))
    }

    let tail = frameMagnitudes.withUnsafeMutableBufferPointer { magnitudes in
        framePhases.withUnsafeMutableBufferPointer { phases in
            transform.finish(magnitudes: magnitudes, phases: phases)
        }
    }
    frames.append(contentsOf: columns(frameMagnitudes, framePhases, bins: bins, count: tail))
    return frames
}

/// Runs frames through the inverse transform and returns the samples it released.
func synthesizedSamples(_ frames: [STFTColumns], with transform: StreamingISTFT) -> [Float] {
    var samples = [Float](repeating: 0, count: transform.hopLength)
    var output: [Float] = []
    for frame in frames {
        let count = frame.magnitudes.withUnsafeBufferPointer { magnitudes in
            frame.phases.withUnsafeBufferPointer { phases in
                samples.withUnsafeMutableBufferPointer { buffer in
                    transform.process(magnitudes: magnitudes, phases: phases, samples: buffer)
                }
            }
        }
        output.append(contentsOf: samples[0..<count])
    }
    return output
}

func maximumError(_ lhs: [Float], _ rhs: [Float]) -> Float {
    zip(lhs, rhs).map { abs($0 - $1) }.max() ?? 0
}

/// The signal-to-noise ratio, in decibels, of the difference between a reference and an estimate.
func differenceSNR(_ reference: [Float], _ estimate: [Float]) -> Double {
    var signal = 0.0
    var noise = 0.0
    for index in reference.indices {
        let expected = Double(reference[index])
        let difference = expected - Double(estimate[index])
        signal += expected * expected
        noise += difference * difference
    }
    guard noise > 0 else {
        return .infinity
    }
    return 10 * log10(signal / noise)
}

/// The lag, within `maxLag` samples, at which the normalised cross-correlation of two signals peaks.
func correlationPeakLag(
    _ lhs: [Float],
    _ rhs: [Float],
    maxLag: Int
) -> Int {
    var bestLag = 0
    var bestScore = -Double.infinity
    for lag in -maxLag...maxLag {
        var product = 0.0
        var leftEnergy = 0.0
        var rightEnergy = 0.0
        let start = max(0, lag)
        let end = min(lhs.count, rhs.count + lag)
        for index in start..<end {
            let left = Double(lhs[index])
            let right = Double(rhs[index - lag])
            product += left * right
            leftEnergy += left * left
            rightEnergy += right * right
        }
        let denominator = (leftEnergy * rightEnergy).squareRoot()
        let score = denominator > 0 ? product / denominator : -Double.infinity
        if score > bestScore {
            bestScore = score
            bestLag = lag
        }
    }
    return bestLag
}

/// Compares phases on the circle so a value next to the branch cut still matches.
func maximumPhaseError(_ lhs: [Float], _ rhs: [Float]) -> Float {
    zip(lhs, rhs)
        .map { difference in
            let wrapped = Double(difference.0 - difference.1)
            return Float(abs(atan2(sin(wrapped), cos(wrapped))))
        }
        .max() ?? 0
}

func columns(
    _ magnitudes: [Float],
    _ phases: [Float],
    bins: Int,
    count: Int
) -> [STFTColumns] {
    (0..<count).map { frame in
        let start = frame * bins
        return STFTColumns(
            magnitudes: Array(magnitudes[start..<start + bins]),
            phases: Array(phases[start..<start + bins])
        )
    }
}
