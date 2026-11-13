import Accelerate
import UntunnelKernels

/// One spectral decoder of the real-time model: 64-wide features in, one column per readout.
///
/// A dense block, then a 1x3 layer whose 128 channels are two bins of 64 side by side, which
/// doubles the bins without a transposed convolution, then a layer of three taps along time,
/// then one 1x1 readout per column. The magnitude decoder has one readout; the phase decoder
/// has a real and an imaginary one.
final class RealtimeDecoder {
    /// Bins per input frame.
    let bins: Int
    /// Bins per readout, `2 * bins`; the caller keeps as many as the spectrum has.
    let outputBins: Int

    private static let width = RealtimeModel.width
    private static let taps = RealtimeModel.kernelTaps

    private let dense: DenseStack
    private let widen: NormalizedConv
    private let smooth: NormalizedConv
    private let readouts: [Scratch]
    private let readoutBiases: [Float]
    private let densified: Scratch
    /// The dense block's output with one zero bin on each side.
    private let padded: Scratch
    /// The last three widened frames, each `outputBins` rows of 64 channels.
    private let ring: Scratch
    private let smoothed: Scratch
    private let slotSize: Int
    private var cursor = 0

    init(weights: RealtimeDecoderWeights, bins: Int) {
        precondition(bins > 0, "a decoder needs at least one bin")
        self.bins = bins
        outputBins = 2 * bins
        dense = DenseStack(weights: weights.dense, bins: bins)
        widen = NormalizedConv(weights: weights.widen)
        smooth = NormalizedConv(weights: weights.smooth)
        readouts = weights.readouts.map(Scratch.init(copying:))
        readoutBiases = weights.readoutBiases

        densified = Scratch(count: bins * Self.width)
        padded = Scratch(count: (bins + 2) * Self.width)
        slotSize = outputBins * Self.width
        ring = Scratch(count: Self.taps * slotSize)
        smoothed = Scratch(count: slotSize)
    }

    func reset() {
        dense.reset()
        ring.clear()
        cursor = 0
    }

    /// Decodes one frame; `columns[i]` receives `outputBins` values of readout `i`.
    func process(input: UnsafePointer<Float>, columns: [UnsafeMutablePointer<Float>]) {
        let width = Self.width
        dense.process(input: input, output: densified.pointer)

        (padded.pointer + width).update(from: densified.pointer, count: bins * width)
        let slot = ring.pointer + cursor * slotSize
        widen.apply(input: padded.pointer, stride: width, positions: bins, output: slot)

        for timeTap in 0..<Self.taps {
            let back = Self.taps - 1 - timeTap
            let frame = ring.pointer + ((cursor + Self.taps - back) % Self.taps) * slotSize
            smooth.accumulate(
                frame, stride: width, depth: width, kernelRow: timeTap * width,
                positions: outputBins, into: smoothed.pointer, first: timeTap == 0)
        }
        cursor = (cursor + 1) % Self.taps
        smooth.finish(positions: outputBins, output: smoothed.pointer)

        for (index, readout) in readouts.enumerated() {
            untunnel_matmul(
                smoothed.pointer, width, readout.pointer, 1, columns[index], 1, outputBins,
                width, false)
            var bias = readoutBiases[index]
            vDSP_vsadd(columns[index], 1, &bias, columns[index], 1, vDSP_Length(outputBins))
        }
    }
}
