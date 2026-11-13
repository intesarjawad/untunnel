import Foundation

/// A polyphase Kaiser-windowed-sinc resampler for one fixed rational rate pair.
///
/// Device and tier rates are fixed integers, so the ratio reduces to `L/M` and every output
/// frame uses one of `L` precomputed filter phases. Coefficients and history are allocated at
/// init and the history is a fixed wrap-around buffer, so `process` never allocates.
public final class PolyphaseResampler {
    /// Source frames per second.
    public let inputRate: Int
    /// Result frames per second.
    public let outputRate: Int

    /// Kaiser design attenuation in decibels. The filter realises at least 92 dB across the
    /// stopband for the audio rate pairs, so the 90 dB target keeps a little headroom.
    private static let designAttenuation = 95.0
    /// Transition width as a fraction of the source rate, about 1.9 kHz at 48 kHz.
    private static let transitionWidth = 0.04

    /// `L`: the number of filter phases, one per interpolated position.
    private let phaseCount: Int
    /// `M`: source frames advanced per output frame.
    private let step: Int
    /// Taps in each phase, and therefore the history depth.
    private let tapsPerPhase: Int
    /// Phase-major coefficients: phase `p`, tap `t` at `p * tapsPerPhase + t`.
    private let coefficients: UnsafeMutableBufferPointer<Float>
    /// The most recent source frames, newest at `historySlot - 1`.
    private let history: UnsafeMutableBufferPointer<Float>

    private var historySlot = 0
    private var pushedCount = 0
    private var outputIndex = 0

    /// Creates a resampler for `inputRate` to `outputRate`.
    public init(inputRate: Int, outputRate: Int) {
        precondition(inputRate > 0 && outputRate > 0, "sample rates must be positive")
        self.inputRate = inputRate
        self.outputRate = outputRate

        let divisor = greatestCommonDivisor(inputRate, outputRate)
        let phases = outputRate / divisor
        let step = inputRate / divisor
        let taps = Int(
            ((Self.designAttenuation - 8) / (2.285 * 2 * Double.pi * Self.transitionWidth))
                .rounded(.up)
        )
        let length = phases * taps
        let center = Double(length - 1) / 2
        let cutoff = 0.5 * min(1, Double(phases) / Double(step)) / Double(phases)
        let beta = 0.1102 * (Self.designAttenuation - 8.7)
        let windowNormalisation = besselI0(beta)

        var prototype = [Double](repeating: 0, count: length)
        var total = 0.0
        for index in 0..<length {
            let offset = Double(index) - center
            let angle = 2 * Double.pi * cutoff * offset
            let sinc = offset == 0 ? 1 : sin(angle) / angle
            let windowPosition = 2 * Double(index) / Double(length - 1) - 1
            let windowArgument = max(0, 1 - windowPosition * windowPosition).squareRoot()
            let window = besselI0(beta * windowArgument) / windowNormalisation
            prototype[index] = 2 * cutoff * sinc * window
            total += prototype[index]
        }

        // A unit-sum prototype has unity gain at the upsampled rate; scaling by L restores the
        // amplitude lost when interpolation inserts L - 1 zeros, giving each phase unity DC gain.
        let gain = Double(phases) / total

        coefficients = .allocate(capacity: length)
        coefficients.initialize(repeating: 0)
        for phase in 0..<phases {
            for tap in 0..<taps {
                coefficients[phase * taps + tap] = Float(prototype[phase + tap * phases] * gain)
            }
        }
        history = .allocate(capacity: taps)
        history.initialize(repeating: 0)
        phaseCount = phases
        self.step = step
        tapsPerPhase = taps
    }

    deinit {
        coefficients.deallocate()
        history.deallocate()
    }

    /// Resamples a whole buffer into exactly `count` frames, zero-filling any shortfall.
    ///
    /// A take that is replayed or compared needs a fixed frame count, while `process` stops
    /// when either side runs out; the exact count is settled here.
    public func resample(_ input: [Float], count: Int) -> [Float] {
        var output = [Float](repeating: 0, count: count)
        var produced = 0
        var consumed = 0
        while produced < count && consumed < input.count {
            let result = input.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { destination in
                    process(
                        UnsafeBufferPointer(rebasing: source[consumed...]),
                        into: UnsafeMutableBufferPointer(rebasing: destination[produced...])
                    )
                }
            }
            if result.produced == 0 && result.consumed == 0 {
                break
            }
            produced += result.produced
            consumed += result.consumed
        }
        return output
    }

    /// Resamples from `input` into `output`, reporting how much of each was used.
    ///
    /// Source frames that do not fit in `output` are not consumed, so the caller may hand the
    /// remainder to the next call; at the start of a stream the missing history reads as silence,
    /// which the first `tapsPerPhase` source frames ramp out of.
    public func process(
        _ input: UnsafeBufferPointer<Float>,
        into output: UnsafeMutableBufferPointer<Float>
    ) -> (consumed: Int, produced: Int) {
        var consumed = 0
        var produced = 0

        while produced < output.count {
            let base = (outputIndex * step) / phaseCount
            while pushedCount <= base {
                guard consumed < input.count else {
                    return (consumed, produced)
                }
                history[historySlot] = input[consumed]
                historySlot += 1
                if historySlot == tapsPerPhase {
                    historySlot = 0
                }
                pushedCount += 1
                consumed += 1
            }

            let phase = (outputIndex * step) % phaseCount
            let coefficientBase = phase * tapsPerPhase
            var slot = historySlot - 1
            if slot < 0 {
                slot += tapsPerPhase
            }
            var sum: Float = 0
            for tap in 0..<tapsPerPhase {
                sum += coefficients[coefficientBase + tap] * history[slot]
                slot -= 1
                if slot < 0 {
                    slot += tapsPerPhase
                }
            }
            output[produced] = sum
            produced += 1
            outputIndex += 1
        }
        return (consumed, produced)
    }
}

private func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
    var a = a
    var b = b
    while b != 0 {
        (a, b) = (b, a % b)
    }
    return a
}

/// The zeroth-order modified Bessel function of the first kind, from its power series.
private func besselI0(_ x: Double) -> Double {
    let quarterSquared = x * x / 4
    var term = 1.0
    var sum = 1.0
    var order = 1.0
    while term > sum * 1e-12 {
        term *= quarterSquared / (order * order)
        sum += term
        order += 1
    }
    return sum
}
