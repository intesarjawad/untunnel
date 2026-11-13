import Foundation

/// The fixed sizes of the published real-time model.
///
/// They come from the checkpoint's `config.json` (`hid_feature 64`, `d_state 16`, `d_conv 4`,
/// `expand 4`) and from the module definitions recorded in ADR-0010.
public enum RealtimeModel {
    /// Channels of every feature map between the encoder's first layer and the decoders' last.
    public static let width = 64
    /// Channels inside a recurrence, `expand * width`.
    public static let innerWidth = 256
    /// Recurrence states per inner channel.
    public static let stateSize = 16
    /// The rank the recurrence step is projected through, `ceil(width / 16)`.
    public static let stepRank = 4
    /// Taps of the recurrence's causal convolution, counting the current position.
    public static let scanTaps = 4
    /// Layers of every dense block; layer `i` dilates time by `2^i`.
    public static let denseDepth = 4
    /// Taps of every kernel that is not 1x1, along each axis it spans.
    public static let kernelTaps = 3
    /// Magnitude and phase.
    public static let inputChannels = 2
    /// Zero bins appended to each input frame before the encoder.
    public static let appendedBins = 2
    /// The most future frames the encoder has a first layer for.
    public static let maximumLookAhead = 2
    /// The variance floor of every layer normalisation.
    public static let normEpsilon: Float = 1e-5

    /// The bins the blocks and decoders work at for a spectrum of `binCount` bins.
    public static func modelBins(binCount: Int) -> Int {
        (binCount + appendedBins - kernelTaps) / 2 + 1
    }
}

/// A convolution with the channel normalisation and PReLU that follow it.
///
/// The kernel is stored `[timeTap][frequencyTap][input][output]`: a frame is laid out
/// `[bin][channel]`, so a patch gathered from it has its channels innermost, and the matrix
/// product that applies the kernel multiplies patches on the left.
public struct NormalizedConvWeights: Sendable {
    public let kernel: [Float]
    public let bias: [Float]
    public let normScale: [Float]
    public let normShift: [Float]
    public let slope: [Float]
    public let outputChannels: Int
    public let inputChannels: Int
    /// Kernel taps per output value, `timeTaps * frequencyTaps`.
    public let taps: Int

    /// Reads a kernel of `timeTaps` by `frequencyTaps` stored `[output][input][time][frequency]`,
    /// or with the two tap axes exchanged when `tapsAreTimeLast`. `norm` names the module that
    /// holds the normalisation's `weight` and `bias`.
    init(
        map: inout WeightMap,
        conv: String,
        norm: String,
        slope: String,
        outputChannels: Int,
        inputChannels: Int,
        timeTaps: Int,
        frequencyTaps: Int,
        tapsAreTimeLast: Bool = false
    ) throws {
        let stored = try map.take(
            "\(conv).weight",
            shape: tapsAreTimeLast
                ? [outputChannels, inputChannels, frequencyTaps, timeTaps]
                : [outputChannels, inputChannels, timeTaps, frequencyTaps]
        )
        let taps = timeTaps * frequencyTaps
        var kernel = [Float](repeating: 0, count: stored.count)
        for output in 0..<outputChannels {
            for input in 0..<inputChannels {
                for tap in 0..<taps {
                    kernel[(tap * inputChannels + input) * outputChannels + output] =
                        stored[(output * inputChannels + input) * taps + tap]
                }
            }
        }
        self.kernel = kernel
        bias = try map.take("\(conv).bias", shape: [outputChannels])
        let normWidth = RealtimeModel.width
        normScale = try map.take("\(norm).weight", shape: [normWidth])
        normShift = try map.take("\(norm).bias", shape: [normWidth])
        self.slope = try map.take("\(slope).weight", shape: [normWidth])
        self.outputChannels = outputChannels
        self.inputChannels = inputChannels
        self.taps = taps
    }
}

/// The four dilated layers of one dense block.
public struct DenseStackWeights: Sendable {
    public let layers: [NormalizedConvWeights]

    init(layers: [NormalizedConvWeights]) {
        self.layers = layers
    }

    init(map: inout WeightMap, prefix: String) throws {
        layers = try (0..<RealtimeModel.denseDepth).map { index in
            let layer = "\(prefix).dense_block.dense_block.\(index)"
            return try NormalizedConvWeights(
                map: &map,
                conv: "\(layer).1",
                norm: "\(layer).2.norm",
                slope: "\(layer).3",
                outputChannels: RealtimeModel.width,
                inputChannels: RealtimeModel.width * (index + 1),
                timeTaps: RealtimeModel.kernelTaps,
                frequencyTaps: RealtimeModel.kernelTaps
            )
        }
    }
}

/// The encoder: one first layer per look-ahead, the dense block and the stride-two layer.
public struct RealtimeEncoderWeights: Sendable {
    /// Indexed by look-ahead, 0 through `RealtimeModel.maximumLookAhead`.
    public let entry: [NormalizedConvWeights]
    public let dense: DenseStackWeights
    public let reduction: NormalizedConvWeights

    init(map: inout WeightMap) throws {
        let prefix = "dense_encoder"
        entry = try (0...RealtimeModel.maximumLookAhead).map { lookAhead in
            let layer = "\(prefix).dense_conv_1_\(lookAhead + 1)"
            return try NormalizedConvWeights(
                map: &map,
                conv: "\(layer).0",
                norm: "\(layer).1.norm",
                slope: "\(layer).2",
                outputChannels: RealtimeModel.width,
                inputChannels: RealtimeModel.inputChannels,
                timeTaps: RealtimeModel.kernelTaps,
                frequencyTaps: RealtimeModel.kernelTaps
            )
        }
        dense = try DenseStackWeights(map: &map, prefix: prefix)
        reduction = try NormalizedConvWeights(
            map: &map,
            conv: "\(prefix).dense_conv_2.0",
            norm: "\(prefix).dense_conv_2.1.norm",
            slope: "\(prefix).dense_conv_2.2",
            outputChannels: RealtimeModel.width,
            inputChannels: RealtimeModel.width,
            timeTaps: 1,
            frequencyTaps: RealtimeModel.kernelTaps
        )
    }
}

/// One selective-scan recurrence.
///
/// Every projection is stored `[input][output]`, the transpose of the checkpoint's layout,
/// because a batch of positions multiplies it on the left.
public struct SelectiveScanWeights: Sendable {
    /// `[width][2 * innerWidth]`; the first half feeds the convolution, the second the gate.
    public let inProjection: [Float]
    /// `[scanTaps][innerWidth]`, oldest tap first.
    public let convolution: [Float]
    public let convolutionBias: [Float]
    /// `[innerWidth][stepRank]`, the rows of `x_proj` that produce the step.
    public let stepMix: [Float]
    /// `[innerWidth][2 * stateSize]`, the rows of `x_proj` that drive and read the state.
    public let stateMix: [Float]
    /// `[stepRank][innerWidth]`.
    public let stepProjection: [Float]
    public let stepBias: [Float]
    /// `-exp(A_log)`, `[innerWidth][stateSize]`.
    public let decay: [Float]
    public let skip: [Float]
    /// `[innerWidth][width]`.
    public let outProjection: [Float]

    init(map: inout WeightMap, prefix: String) throws {
        let width = RealtimeModel.width
        let inner = RealtimeModel.innerWidth
        let states = RealtimeModel.stateSize
        let taps = RealtimeModel.scanTaps
        let rank = RealtimeModel.stepRank
        let mixWidth = rank + 2 * states

        inProjection = transposed(
            try map.take("\(prefix).in_proj.weight", shape: [2 * inner, width]),
            rows: 2 * inner, columns: width)
        convolution = transposed(
            try map.take("\(prefix).conv1d.weight", shape: [inner, 1, taps]),
            rows: inner, columns: taps)
        convolutionBias = try map.take("\(prefix).conv1d.bias", shape: [inner])
        let mix = transposed(
            try map.take("\(prefix).x_proj.weight", shape: [mixWidth, inner]),
            rows: mixWidth, columns: inner)
        var stepMix = [Float](repeating: 0, count: inner * rank)
        var stateMix = [Float](repeating: 0, count: inner * 2 * states)
        for channel in 0..<inner {
            for column in 0..<mixWidth {
                let value = mix[channel * mixWidth + column]
                if column < rank {
                    stepMix[channel * rank + column] = value
                } else {
                    stateMix[channel * 2 * states + column - rank] = value
                }
            }
        }
        self.stepMix = stepMix
        self.stateMix = stateMix
        stepProjection = transposed(
            try map.take("\(prefix).dt_proj.weight", shape: [inner, rank]),
            rows: inner, columns: rank)
        stepBias = try map.take("\(prefix).dt_proj.bias", shape: [inner])
        decay = try map.take("\(prefix).A_log", shape: [inner, states]).map { -exp($0) }
        skip = try map.take("\(prefix).D", shape: [inner])
        outProjection = transposed(
            try map.take("\(prefix).out_proj.weight", shape: [width, inner]),
            rows: width, columns: inner)
    }
}

/// The projection and normalisation that close one branch of a block.
public struct BranchHeadWeights: Sendable {
    /// `[inputWidth][width]`.
    public let projection: [Float]
    public let bias: [Float]
    public let normScale: [Float]
    public let normShift: [Float]
    public let inputWidth: Int

    init(map: inout WeightMap, prefix: String, inputWidth: Int) throws {
        let width = RealtimeModel.width
        projection = transposed(
            try map.take("\(prefix).output_proj.weight", shape: [width, inputWidth]),
            rows: width, columns: inputWidth)
        bias = try map.take("\(prefix).output_proj.bias", shape: [width])
        normScale = try map.take("\(prefix).norm.weight", shape: [width])
        normShift = try map.take("\(prefix).norm.bias", shape: [width])
        self.inputWidth = inputWidth
    }
}

/// One time-frequency block.
public struct RealtimeBlockWeights: Sendable {
    public let time: SelectiveScanWeights
    public let timeHead: BranchHeadWeights
    public let frequencyUp: SelectiveScanWeights
    public let frequencyDown: SelectiveScanWeights
    public let frequencyHead: BranchHeadWeights

    init(map: inout WeightMap, prefix: String) throws {
        time = try SelectiveScanWeights(map: &map, prefix: "\(prefix).time_mamba.forward_blocks")
        timeHead = try BranchHeadWeights(
            map: &map, prefix: "\(prefix).time_mamba", inputWidth: RealtimeModel.width)
        frequencyUp = try SelectiveScanWeights(
            map: &map, prefix: "\(prefix).freq_mamba.forward_blocks")
        frequencyDown = try SelectiveScanWeights(
            map: &map, prefix: "\(prefix).freq_mamba.backward_blocks")
        frequencyHead = try BranchHeadWeights(
            map: &map, prefix: "\(prefix).freq_mamba", inputWidth: 2 * RealtimeModel.width)
    }
}

/// One spectral decoder; the magnitude decoder has one readout and the phase decoder two.
public struct RealtimeDecoderWeights: Sendable {
    public let dense: DenseStackWeights
    /// The 1x3 layer whose 128 channels interleave into twice the bins.
    public let widen: NormalizedConvWeights
    /// The layer of three taps along time.
    public let smooth: NormalizedConvWeights
    /// One `[width]` row and one bias per readout.
    public let readouts: [[Float]]
    public let readoutBiases: [Float]

    init(map: inout WeightMap, prefix: String, readoutNames: [String]) throws {
        let width = RealtimeModel.width
        dense = try DenseStackWeights(map: &map, prefix: prefix)
        widen = try NormalizedConvWeights(
            map: &map,
            conv: "\(prefix).up_conv1.0.conv",
            norm: "\(prefix).up_conv1.1.norm",
            slope: "\(prefix).up_conv1.2",
            outputChannels: 2 * width,
            inputChannels: width,
            timeTaps: 1,
            frequencyTaps: RealtimeModel.kernelTaps
        )
        smooth = try NormalizedConvWeights(
            map: &map,
            conv: "\(prefix).up_conv2.0.conv",
            norm: "\(prefix).up_conv2.1.norm",
            slope: "\(prefix).up_conv2.2",
            outputChannels: width,
            inputChannels: width,
            timeTaps: RealtimeModel.kernelTaps,
            frequencyTaps: 1,
            tapsAreTimeLast: true
        )
        readouts = try readoutNames.map {
            try map.take("\(prefix).\($0).weight", shape: [1, width, 1, 1])
        }
        readoutBiases = try readoutNames.map {
            try map.take("\(prefix).\($0).bias", shape: [1])[0]
        }
    }

    static let magnitudeReadouts = ["final_conv"]
    /// Real part first; the phase is `atan2(imaginary, real)`.
    static let phaseReadouts = ["phase_conv_r", "phase_conv_i"]
}

/// The parameters of one real-time restoration stream.
///
/// The checkpoint carries a decoder pair for every exit depth, so a cheaper tier stops early
/// instead of loading a smaller model. The selected depth keeps its blocks and its pair; every
/// other tensor is checked for name and shape, so a checkpoint that does not describe this
/// model fails to load, and then left in the file.
public struct RealtimeRestorerWeights: Sendable {
    public let encoder: RealtimeEncoderWeights
    /// The blocks up to the selected exit.
    public let blocks: [RealtimeBlockWeights]
    public let magnitude: RealtimeDecoderWeights
    public let phase: RealtimeDecoderWeights

    /// Reads the encoder, the first `exitLayer` blocks and the decoder pair trained to exit
    /// after them.
    public init(map: inout WeightMap, exitLayer: Int) throws {
        precondition(exitLayer > 0, "a stream needs at least one time-frequency block")
        encoder = try RealtimeEncoderWeights(map: &map)
        blocks = try (0..<exitLayer).map {
            try RealtimeBlockWeights(map: &map, prefix: "TSMamba.\($0)")
        }
        magnitude = try RealtimeDecoderWeights(
            map: &map,
            prefix: "mask_decoder_list.\(exitLayer - 1)",
            readoutNames: RealtimeDecoderWeights.magnitudeReadouts
        )
        phase = try RealtimeDecoderWeights(
            map: &map,
            prefix: "phase_decoder_list.\(exitLayer - 1)",
            readoutNames: RealtimeDecoderWeights.phaseReadouts
        )

        let layout = RealtimeModelLayout.tensors(blockCount: max(map.blockCount, exitLayer))
        for tensor in layout where !map.consumedNames.contains(tensor.name) {
            try map.check(tensor.name, shape: tensor.shape)
        }
    }
}

/// The `[columns][rows]` transpose of a row-major `[rows][columns]` matrix.
private func transposed(_ matrix: [Float], rows: Int, columns: Int) -> [Float] {
    var result = [Float](repeating: 0, count: matrix.count)
    for row in 0..<rows {
        for column in 0..<columns {
            result[column * rows + row] = matrix[row * columns + column]
        }
    }
    return result
}
