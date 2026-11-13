import Accelerate
import UntunnelKernels

// Every map here is time-major, `[frame][bin][channel]` with 64 channels, the layout a
// real-time frame has, so the layers share `NormalizedConv` and its matrix product. Each layer
// normalises over the whole map, so none of them can be streamed and each allocates its maps
// per call.

/// A dense block over a whole map: four 3x3 layers with time dilations 1, 2, 4 and 8, padded
/// by the dilation on both sides in time and by one bin in frequency.
///
/// Layer `i` reads the block input and every earlier layer's output, newest first, which is
/// the order the publisher concatenates in. They share one zero-padded map whose row is
/// `[layer 2][layer 1][layer 0][input]` per position, so each layer reads a suffix of every
/// row and each of its nine taps is a window of rows.
final class OfflineDenseBlock {
    private static let width = RealtimeModel.width
    private static let rowWidth = RealtimeModel.denseDepth * width
    /// The widest dilation, which is also the time padding.
    private static let reach = 1 << (RealtimeModel.denseDepth - 1)

    private let layers: [NormalizedConv]

    init(weights: DenseStackWeights) {
        layers = weights.layers.map(NormalizedConv.init)
    }

    /// Reads `frames` x `bins` rows of 64 channels and writes as many.
    func process(
        input: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>,
        frames: Int,
        bins: Int
    ) {
        let width = Self.width
        let rowWidth = Self.rowWidth
        let taps = RealtimeModel.kernelTaps
        let paddedBins = bins + 2
        let rows = frames * bins
        let stack = Scratch(count: (frames + 2 * Self.reach) * paddedBins * rowWidth)
        let stage = Scratch(count: rows * width)

        func row(frame: Int, bin: Int) -> UnsafeMutablePointer<Float> {
            stack.pointer + ((frame + Self.reach) * paddedBins + bin + 1) * rowWidth
        }
        func store(_ map: UnsafePointer<Float>, at offset: Int) {
            for frame in 0..<frames {
                for bin in 0..<bins {
                    (row(frame: frame, bin: bin) + offset)
                        .update(from: map + (frame * bins + bin) * width, count: width)
                }
            }
        }

        store(input, at: rowWidth - width)
        for (index, layer) in layers.enumerated() {
            let channels = width * (index + 1)
            let offset = rowWidth - channels
            let dilation = 1 << index
            let written = index == layers.count - 1 ? output : stage.pointer
            for frame in 0..<frames {
                for timeTap in 0..<taps {
                    let source = frame + (timeTap - 1) * dilation
                    for frequencyTap in 0..<taps {
                        layer.accumulate(
                            row(frame: source, bin: frequencyTap - 1) + offset, stride: rowWidth,
                            depth: channels, kernelRow: (timeTap * taps + frequencyTap) * channels,
                            positions: bins, into: written + frame * bins * width,
                            first: timeTap == 0 && frequencyTap == 0)
                    }
                }
            }
            layer.addBias(positions: rows, output: written)
            layer.normalizeInstanceAndActivate(rows: rows, output: written)
            if index < layers.count - 1 {
                store(written, at: offset - width)
            }
        }
    }
}

/// The encoder: magnitude and phase in, `modelFrames` x `modelBins` rows of 64 channels out.
///
/// Two zero frames and two zero bins are appended to the spectrum, as the publisher's forward
/// pass does before encoding; they take part in every normalisation. A 1x1 layer widens the
/// two inputs to 64 channels, the dense block follows, and a 1x3 layer that steps four frames
/// and two bins, without padding, reduces the map.
final class OfflineEncoder {
    private let entry: NormalizedConv
    private let dense: OfflineDenseBlock
    private let reduction: NormalizedConv

    init(weights: OfflineEncoderWeights) {
        entry = NormalizedConv(weights: weights.entry)
        dense = OfflineDenseBlock(weights: weights.dense)
        reduction = NormalizedConv(weights: weights.reduction)
    }

    /// Encodes `frames` frames of `binCount` magnitudes and phases, each `[frame][bin]`.
    func process(
        magnitudes: UnsafePointer<Float>,
        phases: UnsafePointer<Float>,
        frames: Int,
        binCount: Int,
        output: UnsafeMutablePointer<Float>
    ) {
        let width = RealtimeModel.width
        let inputs = RealtimeModel.inputChannels
        let paddedFrames = frames + OfflineModel.appendedFrames
        let paddedBins = binCount + RealtimeModel.appendedBins
        let positions = paddedFrames * paddedBins

        let spectrum = Scratch(count: positions * inputs)
        for frame in 0..<frames {
            for bin in 0..<binCount {
                let position = spectrum.pointer + (frame * paddedBins + bin) * inputs
                position[0] = magnitudes[frame * binCount + bin]
                position[1] = phases[frame * binCount + bin]
            }
        }
        let widened = Scratch(count: positions * width)
        entry.accumulate(
            spectrum.pointer, stride: inputs, depth: inputs, kernelRow: 0, positions: positions,
            into: widened.pointer, first: true)
        entry.addBias(positions: positions, output: widened.pointer)
        entry.normalizeInstanceAndActivate(rows: positions, output: widened.pointer)

        let densified = Scratch(count: positions * width)
        dense.process(
            input: widened.pointer, output: densified.pointer, frames: paddedFrames,
            bins: paddedBins)

        let modelFrames = OfflineModel.modelFrames(frames: frames)
        let modelBins = OfflineModel.modelBins(binCount: binCount)
        let frequencyStride = OfflineModel.frequencyStride
        for frame in 0..<modelFrames {
            let source = densified.pointer + frame * OfflineModel.timeStride * paddedBins * width
            for tap in 0..<RealtimeModel.kernelTaps {
                reduction.accumulate(
                    source + tap * width, stride: frequencyStride * width, depth: width,
                    kernelRow: tap * width, positions: modelBins,
                    into: output + frame * modelBins * width, first: tap == 0)
            }
        }
        let rows = modelFrames * modelBins
        reduction.addBias(positions: rows, output: output)
        reduction.normalizeInstanceAndActivate(rows: rows, output: output)
    }
}

/// One spectral decoder: `frames` x `bins` rows of 64 channels in, one map of
/// `timeStride * frames` x `frequencyStride * bins` values per readout out.
///
/// A dense block, then a 1x3 layer whose 128 channels are two neighbouring bins, then a layer
/// of three taps along time whose 256 channels are four consecutive frames: channel `64j + c`
/// of frame `t` becomes channel `c` of frame `4t + j`. Each is padded by one on both sides,
/// and a 1x1 readout per map closes it. The caller keeps the frames and bins its spectrum has.
final class OfflineDecoder {
    private let dense: OfflineDenseBlock
    private let widen: NormalizedConv
    private let lengthen: NormalizedConv
    private let readouts: [Scratch]
    private let readoutBiases: [Float]

    init(weights: OfflineDecoderWeights) {
        dense = OfflineDenseBlock(weights: weights.dense)
        widen = NormalizedConv(weights: weights.widen)
        lengthen = NormalizedConv(weights: weights.lengthen)
        readouts = weights.readouts.map(Scratch.init(copying:))
        readoutBiases = weights.readoutBiases
    }

    func process(
        input: UnsafePointer<Float>,
        frames: Int,
        bins: Int,
        maps: [UnsafeMutablePointer<Float>]
    ) {
        let width = RealtimeModel.width
        let taps = RealtimeModel.kernelTaps
        let rows = frames * bins
        let paddedBins = bins + 2
        let wideBins = OfflineModel.frequencyStride * bins
        let longFrames = OfflineModel.timeStride * frames
        let lengthenChannels = OfflineModel.timeStride * width

        // The dense block's output with a zero bin on each side of every frame.
        let padded = Scratch(count: frames * paddedBins * width)
        let densified = Scratch(count: rows * width)
        dense.process(input: input, output: densified.pointer, frames: frames, bins: bins)
        for frame in 0..<frames {
            (padded.pointer + (frame * paddedBins + 1) * width)
                .update(from: densified.pointer + frame * bins * width, count: bins * width)
        }

        // A zero frame on each side of the widened map.
        let widened = Scratch(count: (frames + 2) * wideBins * width)
        let widenedFrames = widened.pointer + wideBins * width
        for frame in 0..<frames {
            widen.accumulate(
                padded.pointer + frame * paddedBins * width, stride: width,
                depth: widen.patchWidth, kernelRow: 0, positions: bins,
                into: widenedFrames + frame * wideBins * width, first: true)
        }
        widen.addBias(positions: rows, output: widenedFrames)
        widen.normalizeInstanceAndActivate(rows: frames * wideBins, output: widenedFrames)

        let stacked = Scratch(count: frames * wideBins * lengthenChannels)
        for frame in 0..<frames {
            for tap in 0..<taps {
                lengthen.accumulate(
                    widened.pointer + (frame + tap) * wideBins * width, stride: width,
                    depth: width, kernelRow: tap * width, positions: wideBins,
                    into: stacked.pointer + frame * wideBins * lengthenChannels, first: tap == 0)
            }
        }
        lengthen.addBias(positions: frames * wideBins, output: stacked.pointer)
        let lengthened = Scratch(count: longFrames * wideBins * width)
        for frame in 0..<frames {
            for bin in 0..<wideBins {
                let source = stacked.pointer + (frame * wideBins + bin) * lengthenChannels
                for step in 0..<OfflineModel.timeStride {
                    let target = OfflineModel.timeStride * frame + step
                    (lengthened.pointer + (target * wideBins + bin) * width)
                        .update(from: source + step * width, count: width)
                }
            }
        }
        lengthen.normalizeInstanceAndActivate(
            rows: longFrames * wideBins, output: lengthened.pointer)

        for (index, readout) in readouts.enumerated() {
            untunnel_matmul(
                lengthened.pointer, width, readout.pointer, 1, maps[index], 1,
                longFrames * wideBins, width, false)
            var bias = readoutBiases[index]
            vDSP_vsadd(maps[index], 1, &bias, maps[index], 1, vDSP_Length(longFrames * wideBins))
        }
    }
}
