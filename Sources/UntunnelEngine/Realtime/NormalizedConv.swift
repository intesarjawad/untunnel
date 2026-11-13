import Accelerate
import UntunnelKernels

/// Floats allocated once and zeroed, because nothing on the audio path may allocate.
final class Scratch {
    let pointer: UnsafeMutablePointer<Float>
    let count: Int

    init(count: Int) {
        self.count = count
        pointer = .allocate(capacity: max(count, 1))
        pointer.initialize(repeating: 0, count: max(count, 1))
    }

    convenience init(copying values: [Float]) {
        self.init(count: values.count)
        pointer.update(from: values, count: values.count)
    }

    deinit {
        pointer.deallocate()
    }

    func clear() {
        pointer.update(repeating: 0, count: count)
    }
}

/// Normalises every `width`-wide row over its channels, then scales and shifts it.
///
/// This is `nn.LayerNorm` over the channel axis: the variance is the biased one and the floor
/// sits inside the square root.
func normalizeRows(
    _ values: UnsafeMutablePointer<Float>,
    rows: Int,
    scale: UnsafePointer<Float>,
    shift: UnsafePointer<Float>
) {
    untunnel_layer_norm(values, scale, shift, RealtimeModel.normEpsilon, RealtimeModel.width, rows)
}

/// A convolution with its bias, normalisation and PReLU.
///
/// The kernel's rows are its taps, each `inputChannels` rows deep. A caller whose taps sit
/// side by side in memory hands them over as one window per output position; one whose taps
/// come from different frames or bins adds them a block at a time, straight from where they
/// are stored. Either way the sum runs over the taps in kernel order.
final class NormalizedConv {
    let outputChannels: Int
    /// Values per output position, `taps * inputChannels`.
    let patchWidth: Int

    private let kernel: Scratch
    private let bias: Scratch
    private let normScale: Scratch
    private let normShift: Scratch
    /// `slope - 1`, so the activation is `x + (slope - 1) * min(x, 0)`.
    private let slopeBelowUnity: Scratch

    init(weights: NormalizedConvWeights) {
        outputChannels = weights.outputChannels
        patchWidth = weights.taps * weights.inputChannels
        kernel = Scratch(copying: weights.kernel)
        bias = Scratch(copying: weights.bias)
        normScale = Scratch(copying: weights.normScale)
        normShift = Scratch(copying: weights.normShift)
        slopeBelowUnity = Scratch(copying: weights.slope.map { $0 - 1 })
    }

    /// Writes `positions` rows of `outputChannels` values, each from the `patchWidth` values
    /// that start `stride` apart in `input`.
    func apply(
        input: UnsafePointer<Float>,
        stride: Int,
        positions: Int,
        output: UnsafeMutablePointer<Float>
    ) {
        accumulate(
            input, stride: stride, depth: patchWidth, kernelRow: 0, positions: positions,
            into: output, first: true)
        finish(positions: positions, output: output)
    }

    /// Adds the kernel rows `kernelRow..<kernelRow + depth` applied to `positions` rows of
    /// `depth` values `stride` apart, or starts the sum with them when `first`. Blocks are
    /// added in kernel order, and `finish` follows the last.
    func accumulate(
        _ input: UnsafePointer<Float>,
        stride: Int,
        depth: Int,
        kernelRow: Int,
        positions: Int,
        into output: UnsafeMutablePointer<Float>,
        first: Bool
    ) {
        untunnel_matmul(
            input, stride, kernel.pointer + kernelRow * outputChannels, outputChannels, output,
            outputChannels, positions, depth, !first)
    }

    /// Adds the bias, normalises and activates the summed rows.
    ///
    /// The normalisation and the activation treat the output as rows of `RealtimeModel.width`
    /// channels, which is what turns a 128-channel layer into two interleaved bins.
    func finish(positions: Int, output: UnsafeMutablePointer<Float>) {
        addBias(positions: positions, output: output)

        let width = RealtimeModel.width
        let rows = positions * outputChannels / width
        normalizeRows(output, rows: rows, scale: normScale.pointer, shift: normShift.pointer)

        untunnel_prelu(output, slopeBelowUnity.pointer, width, rows)
    }

    /// Adds the bias to `positions` rows of `outputChannels` values.
    func addBias(positions: Int, output: UnsafeMutablePointer<Float>) {
        for position in 0..<positions {
            let row = output + position * outputChannels
            vDSP_vadd(row, 1, bias.pointer, 1, row, 1, vDSP_Length(outputChannels))
        }
    }

    /// Normalises `rows` rows of `RealtimeModel.width` channels as one instance, then
    /// activates them; the offline model's layers finish this way once their bias is added.
    func normalizeInstanceAndActivate(rows: Int, output: UnsafeMutablePointer<Float>) {
        normalizeInstance(output, rows: rows, scale: normScale.pointer, shift: normShift.pointer)
        untunnel_prelu(output, slopeBelowUnity.pointer, RealtimeModel.width, rows)
    }
}

/// Normalises each of the `RealtimeModel.width` channels over all `rows` rows, then scales and
/// shifts it.
///
/// This is `nn.InstanceNorm2d` with affine parameters over a whole feature map: the variance is
/// the biased one, the floor sits inside the square root, and the mean is removed before the
/// variance is taken so a large mean costs no precision.
func normalizeInstance(
    _ values: UnsafeMutablePointer<Float>,
    rows: Int,
    scale: UnsafePointer<Float>,
    shift: UnsafePointer<Float>
) {
    let width = RealtimeModel.width
    let count = vDSP_Length(rows)
    for channel in 0..<width {
        let column = values + channel
        var mean: Float = 0
        vDSP_meanv(column, width, &mean, count)
        var negatedMean = -mean
        vDSP_vsadd(column, width, &negatedMean, column, width, count)
        var variance: Float = 0
        vDSP_measqv(column, width, &variance, count)
        var factor = scale[channel] / (variance + RealtimeModel.normEpsilon).squareRoot()
        var offset = shift[channel]
        vDSP_vsmsa(column, width, &factor, &offset, column, width, count)
    }
}
