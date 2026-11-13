/// A dense block of four time-dilated 3x3 layers, run one frame at a time.
///
/// Layer `i` reads the block input and the outputs of every earlier layer at the current frame
/// and at `2^i` and `2 * 2^i` frames back. Those rows are kept once, in a ring of frames whose
/// row is `[layer 2][layer 1][layer 0][input]` per bin: each layer reads a suffix of it, newest
/// channels first, which is the order the published block concatenates in. Frames before the
/// start of a stream read as zero, the block's causal padding.
///
/// A layer's taps are read where the ring holds them: each of its nine is a window of the
/// rows of one frame, so nothing is gathered before the product.
final class DenseStack {
    let bins: Int

    private static let width = RealtimeModel.width
    private static let rowWidth = RealtimeModel.denseDepth * width
    private static let reach = 2 << (RealtimeModel.denseDepth - 1)
    private static let depth = reach + 1

    private let layers: [NormalizedConv]
    private let ring: Scratch
    private let stage: Scratch
    private let slotSize: Int
    private var cursor = 0

    init(weights: DenseStackWeights, bins: Int) {
        precondition(bins > 0, "a dense block needs at least one bin")
        self.bins = bins
        layers = weights.layers.map(NormalizedConv.init)
        // One zero bin on each side is the block's frequency padding.
        slotSize = (bins + 2) * Self.rowWidth
        ring = Scratch(count: Self.depth * slotSize)
        stage = Scratch(count: bins * Self.width)
    }

    func reset() {
        ring.clear()
        cursor = 0
    }

    /// Reads `bins` rows of 64 channels and writes as many.
    func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>) {
        let width = Self.width
        let rowWidth = Self.rowWidth
        let slot = ring.pointer + cursor * slotSize
        for bin in 0..<bins {
            (slot + (bin + 1) * rowWidth + rowWidth - width)
                .update(from: input + bin * width, count: width)
        }

        let taps = RealtimeModel.kernelTaps
        for (index, layer) in layers.enumerated() {
            let written = index == layers.count - 1 ? output : stage.pointer
            let channels = width * (index + 1)
            let offset = rowWidth - channels
            let dilation = 1 << index
            for timeTap in 0..<taps {
                let back = (taps - 1 - timeTap) * dilation
                let frame = ring.pointer + ((cursor + Self.depth - back) % Self.depth) * slotSize
                for frequencyTap in 0..<taps {
                    layer.accumulate(
                        frame + frequencyTap * rowWidth + offset, stride: rowWidth,
                        depth: channels, kernelRow: (timeTap * taps + frequencyTap) * channels,
                        positions: bins, into: written, first: timeTap == 0 && frequencyTap == 0)
                }
            }
            layer.finish(positions: bins, output: written)

            // A layer reads the channels after its own, so storing its output changes
            // nothing it has read.
            guard index < layers.count - 1 else {
                break
            }
            for bin in 0..<bins {
                (slot + (bin + 1) * rowWidth + offset - width)
                    .update(from: written + bin * width, count: width)
            }
        }
        cursor = (cursor + 1) % Self.depth
    }
}
