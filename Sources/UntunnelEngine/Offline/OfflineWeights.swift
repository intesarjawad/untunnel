/// The fixed sizes of the published offline model, from its `config.json` and the module
/// definitions recorded in ADR-0013. The widths of its layers are the real-time model's.
public enum OfflineModel {
    /// The time-frequency blocks the published checkpoint stacks.
    public static let blockCount = 30
    /// The milliseconds between two analysis frames: 40 samples at the 8 kHz base rate.
    public static let hopMilliseconds = 5

    /// The transform at the base rate; both lengths scale with the rate.
    static let baseRate = 8_000
    static let baseWindowLength = 320
    static let baseHopLength = 40
    /// Zero frames appended to the spectrum before the encoder, beside the zero bins.
    static let appendedFrames = 2
    /// The frames the encoder's last layer steps over, and the frames each decoder makes of one.
    static let timeStride = 4
    /// The bins each decoder makes of one.
    static let frequencyStride = 2

    /// The frame length at `sampleRate`, scaled from the base rate and rounded up to even as
    /// the publisher's inference does.
    public static func windowLength(sampleRate: Int) -> Int {
        roundedUpToEven(baseWindowLength * sampleRate / baseRate)
    }

    /// The hop at `sampleRate`, scaled the same way.
    public static func hopLength(sampleRate: Int) -> Int {
        roundedUpToEven(baseHopLength * sampleRate / baseRate)
    }

    /// The frames the blocks see for a spectrum of `frames` frames.
    static func modelFrames(frames: Int) -> Int {
        (frames + appendedFrames - 1) / timeStride + 1
    }

    /// The bins the blocks see for a spectrum of `binCount` bins.
    static func modelBins(binCount: Int) -> Int {
        RealtimeModel.modelBins(binCount: binCount)
    }

    private static func roundedUpToEven(_ value: Int) -> Int {
        value.isMultiple(of: 2) ? value : value + 1
    }
}

/// The encoder: a 1x1 layer, a dense block and a layer that steps four frames and two bins.
public struct OfflineEncoderWeights: Sendable {
    public let entry: NormalizedConvWeights
    public let dense: DenseStackWeights
    public let reduction: NormalizedConvWeights

    init(map: inout WeightMap) throws {
        let prefix = "dense_encoder"
        let width = RealtimeModel.width
        entry = try offlineConv(
            &map, "\(prefix).dense_conv_1", outputChannels: width,
            inputChannels: RealtimeModel.inputChannels, timeTaps: 1, frequencyTaps: 1)
        dense = try offlineDenseStack(&map, prefix: prefix)
        reduction = try offlineConv(
            &map, "\(prefix).dense_conv_2", outputChannels: width, inputChannels: width,
            timeTaps: 1, frequencyTaps: RealtimeModel.kernelTaps)
    }
}

/// One time-frequency block: a pair of recurrences in each direction along time and along
/// frequency, and the head that closes each branch.
public struct OfflineBlockWeights: Sendable {
    public let timeForward: SelectiveScanWeights
    public let timeBackward: SelectiveScanWeights
    public let timeHead: BranchHeadWeights
    public let frequencyForward: SelectiveScanWeights
    public let frequencyBackward: SelectiveScanWeights
    public let frequencyHead: BranchHeadWeights

    init(map: inout WeightMap, prefix: String) throws {
        let joinedWidth = 2 * RealtimeModel.width
        timeForward = try SelectiveScanWeights(
            map: &map, prefix: "\(prefix).time_mamba.forward_blocks")
        timeBackward = try SelectiveScanWeights(
            map: &map, prefix: "\(prefix).time_mamba.backward_blocks")
        timeHead = try BranchHeadWeights(
            map: &map, prefix: "\(prefix).time_mamba", inputWidth: joinedWidth)
        frequencyForward = try SelectiveScanWeights(
            map: &map, prefix: "\(prefix).freq_mamba.forward_blocks")
        frequencyBackward = try SelectiveScanWeights(
            map: &map, prefix: "\(prefix).freq_mamba.backward_blocks")
        frequencyHead = try BranchHeadWeights(
            map: &map, prefix: "\(prefix).freq_mamba", inputWidth: joinedWidth)
    }
}

/// One spectral decoder; the magnitude decoder has one readout and the phase decoder two.
public struct OfflineDecoderWeights: Sendable {
    public let dense: DenseStackWeights
    /// The 1x3 layer whose 128 channels interleave into twice the bins.
    public let widen: NormalizedConvWeights
    /// The layer of three taps along time whose 256 channels interleave into four times the
    /// frames.
    public let lengthen: NormalizedConvWeights
    /// One `[width]` row and one bias per readout.
    public let readouts: [[Float]]
    public let readoutBiases: [Float]

    init(map: inout WeightMap, prefix: String, readoutNames: [String]) throws {
        let width = RealtimeModel.width
        let taps = RealtimeModel.kernelTaps
        dense = try offlineDenseStack(&map, prefix: prefix)
        widen = try offlineConv(
            &map, "\(prefix).up_conv1", convModule: "0.conv",
            outputChannels: OfflineModel.frequencyStride * width, inputChannels: width,
            timeTaps: 1, frequencyTaps: taps)
        // The publisher runs this layer on a map with time and frequency exchanged, so its
        // kernel's three taps sit on the axis a kernel otherwise uses for frequency.
        lengthen = try offlineConv(
            &map, "\(prefix).up_conv2", convModule: "0.conv",
            outputChannels: OfflineModel.timeStride * width, inputChannels: width,
            timeTaps: taps, frequencyTaps: 1, tapsAreTimeLast: true)
        readouts = try readoutNames.map {
            try map.take("\(prefix).\($0).weight", shape: [1, width, 1, 1])
        }
        readoutBiases = try readoutNames.map {
            try map.take("\(prefix).\($0).bias", shape: [1])[0]
        }
    }
}

/// The parameters of the offline model: the encoder, every block and the one decoder pair.
public struct OfflineRestorerWeights: Sendable {
    public let encoder: OfflineEncoderWeights
    public let blocks: [OfflineBlockWeights]
    public let magnitude: OfflineDecoderWeights
    public let phase: OfflineDecoderWeights

    /// Reads a checkpoint of `blockCount` blocks; the published one has `OfflineModel.blockCount`.
    public init(map: inout WeightMap, blockCount: Int = OfflineModel.blockCount) throws {
        precondition(blockCount > 0, "the model needs at least one time-frequency block")
        encoder = try OfflineEncoderWeights(map: &map)
        blocks = try (0..<blockCount).map {
            try OfflineBlockWeights(map: &map, prefix: "TSMamba.\($0)")
        }
        magnitude = try OfflineDecoderWeights(
            map: &map, prefix: "mask_decoder",
            readoutNames: RealtimeDecoderWeights.magnitudeReadouts)
        phase = try OfflineDecoderWeights(
            map: &map, prefix: "phase_decoder",
            readoutNames: RealtimeDecoderWeights.phaseReadouts)
    }
}

/// The name and shape of every tensor an offline checkpoint holds.
public enum OfflineModelLayout {
    public static func tensors(blockCount: Int) -> [RealtimeModelLayout.Tensor] {
        typealias Tensor = RealtimeModelLayout.Tensor
        let width = RealtimeModel.width
        let taps = RealtimeModel.kernelTaps
        var tensors: [Tensor] = []

        tensors += conv("dense_encoder.dense_conv_1", [width, RealtimeModel.inputChannels, 1, 1])
        tensors += denseStack("dense_encoder")
        tensors += conv("dense_encoder.dense_conv_2", [width, width, 1, taps])
        for block in 0..<blockCount {
            for branch in ["time_mamba", "freq_mamba"] {
                let prefix = "TSMamba.\(block).\(branch)"
                tensors += RealtimeModelLayout.scan("\(prefix).forward_blocks")
                tensors += RealtimeModelLayout.scan("\(prefix).backward_blocks")
                tensors += RealtimeModelLayout.branchHead(prefix, inputWidth: 2 * width)
            }
        }
        for (prefix, readouts) in [
            ("mask_decoder", RealtimeDecoderWeights.magnitudeReadouts),
            ("phase_decoder", RealtimeDecoderWeights.phaseReadouts),
        ] {
            tensors += denseStack(prefix)
            tensors += conv(
                "\(prefix).up_conv1", [OfflineModel.frequencyStride * width, width, 1, taps],
                convModule: "0.conv")
            tensors += conv(
                "\(prefix).up_conv2", [OfflineModel.timeStride * width, width, 1, taps],
                convModule: "0.conv")
            for readout in readouts {
                tensors += [
                    Tensor(name: "\(prefix).\(readout).weight", shape: [1, width, 1, 1]),
                    Tensor(name: "\(prefix).\(readout).bias", shape: [1]),
                ]
            }
        }
        return tensors
    }

    /// A layer stored as a `Sequential` of the convolution, its instance normalisation and
    /// its PReLU.
    private static func conv(
        _ prefix: String, _ shape: [Int], convModule: String = "0"
    ) -> [RealtimeModelLayout.Tensor] {
        typealias Tensor = RealtimeModelLayout.Tensor
        let width = RealtimeModel.width
        return [
            Tensor(name: "\(prefix).\(convModule).weight", shape: shape),
            Tensor(name: "\(prefix).\(convModule).bias", shape: [shape[0]]),
            Tensor(name: "\(prefix).1.weight", shape: [width]),
            Tensor(name: "\(prefix).1.bias", shape: [width]),
            Tensor(name: "\(prefix).2.weight", shape: [width]),
        ]
    }

    private static func denseStack(_ prefix: String) -> [RealtimeModelLayout.Tensor] {
        let width = RealtimeModel.width
        let taps = RealtimeModel.kernelTaps
        return (0..<RealtimeModel.denseDepth).flatMap {
            conv("\(prefix).dense_block.dense_block.\($0)", [width, width * ($0 + 1), taps, taps])
        }
    }
}

/// Reads one layer stored as a `Sequential` of a convolution, an instance normalisation and a
/// PReLU, the form every offline layer takes.
private func offlineConv(
    _ map: inout WeightMap,
    _ prefix: String,
    convModule: String = "0",
    outputChannels: Int,
    inputChannels: Int,
    timeTaps: Int,
    frequencyTaps: Int,
    tapsAreTimeLast: Bool = false
) throws -> NormalizedConvWeights {
    try NormalizedConvWeights(
        map: &map,
        conv: "\(prefix).\(convModule)",
        norm: "\(prefix).1",
        slope: "\(prefix).2",
        outputChannels: outputChannels,
        inputChannels: inputChannels,
        timeTaps: timeTaps,
        frequencyTaps: frequencyTaps,
        tapsAreTimeLast: tapsAreTimeLast
    )
}

private func offlineDenseStack(_ map: inout WeightMap, prefix: String) throws -> DenseStackWeights {
    DenseStackWeights(
        layers: try (0..<RealtimeModel.denseDepth).map { index in
            try offlineConv(
                &map, "\(prefix).dense_block.dense_block.\(index)",
                outputChannels: RealtimeModel.width,
                inputChannels: RealtimeModel.width * (index + 1),
                timeTaps: RealtimeModel.kernelTaps, frequencyTaps: RealtimeModel.kernelTaps)
        })
}
