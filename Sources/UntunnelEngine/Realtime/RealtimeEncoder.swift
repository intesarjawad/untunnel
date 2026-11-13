/// The encoder of the real-time model: spectrum columns in, 64-wide features at half the bins.
///
/// Its first layer spans three frames. Which three depends on the look-ahead `a`: frames
/// `t - 2 + a` through `t + a`, with a separately trained layer for each `a`. A stream cannot
/// see ahead, so the encoder answers for frame `t` when frame `t + a` arrives and writes
/// nothing for the first `a` frames.
final class RealtimeEncoder {
    /// Bins per input frame.
    let binCount: Int
    /// Bins per output frame.
    let modelBins: Int
    let lookAhead: Int

    private static let width = RealtimeModel.width
    private static let taps = RealtimeModel.kernelTaps
    private static let inputChannels = RealtimeModel.inputChannels

    private let entry: NormalizedConv
    private let dense: DenseStack
    private let reduction: NormalizedConv
    /// The last three padded input frames, `[bin][magnitude, phase]`.
    private let ring: Scratch
    private let entryPatches: Scratch
    private let entered: Scratch
    private let densified: Scratch
    private let innerBins: Int
    private let slotSize: Int
    private var cursor = 0
    private var framesSeen = 0

    init(weights: RealtimeEncoderWeights, binCount: Int, lookAhead: Int) {
        precondition(binCount > 0, "an encoder needs at least one bin")
        precondition(
            (0...RealtimeModel.maximumLookAhead).contains(lookAhead),
            "the model has no first layer for a look-ahead of \(lookAhead) frames"
        )
        self.binCount = binCount
        self.lookAhead = lookAhead
        innerBins = binCount + RealtimeModel.appendedBins
        modelBins = RealtimeModel.modelBins(binCount: binCount)

        entry = NormalizedConv(weights: weights.entry[lookAhead])
        dense = DenseStack(weights: weights.dense, bins: innerBins)
        reduction = NormalizedConv(weights: weights.reduction)
        slotSize = (innerBins + 2) * Self.inputChannels
        ring = Scratch(count: Self.taps * slotSize)
        entryPatches = Scratch(count: innerBins * entry.patchWidth)
        entered = Scratch(count: innerBins * Self.width)
        densified = Scratch(count: innerBins * Self.width)
    }

    func reset() {
        ring.clear()
        dense.reset()
        cursor = 0
        framesSeen = 0
    }

    /// Takes the next frame and writes `modelBins` rows of 64 channels once the look-ahead
    /// has filled.
    /// - Returns: Whether `output` was written.
    func process(
        magnitudes: UnsafePointer<Float>,
        phases: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>
    ) -> Bool {
        let channels = Self.inputChannels
        let slot = ring.pointer + cursor * slotSize
        for bin in 0..<binCount {
            slot[(bin + 1) * channels] = magnitudes[bin]
            slot[(bin + 1) * channels + 1] = phases[bin]
        }
        defer {
            cursor = (cursor + 1) % Self.taps
        }
        guard framesSeen >= lookAhead else {
            framesSeen += 1
            return false
        }

        let span = Self.taps * channels
        for timeTap in 0..<Self.taps {
            let back = Self.taps - 1 - timeTap
            let frame = ring.pointer + ((cursor + Self.taps - back) % Self.taps) * slotSize
            for bin in 0..<innerBins {
                (entryPatches.pointer + bin * entry.patchWidth + timeTap * span)
                    .update(from: frame + bin * channels, count: span)
            }
        }
        entry.apply(
            input: entryPatches.pointer, stride: entry.patchWidth, positions: innerBins,
            output: entered.pointer)
        dense.process(input: entered.pointer, output: densified.pointer)

        // Stride two with no padding: output bin `w` reads bins `2w` through `2w + 2`.
        reduction.apply(
            input: densified.pointer, stride: 2 * Self.width, positions: modelBins,
            output: output)
        return true
    }
}
