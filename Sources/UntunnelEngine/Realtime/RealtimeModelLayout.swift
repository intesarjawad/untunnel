/// The name and shape of every tensor a real-time checkpoint holds.
///
/// A checkpoint is this model's exactly when it holds these tensors and no others, which is
/// what lets a swapped-in checkpoint be accepted or refused before any audio runs. The
/// benchmark also builds its zero-valued checkpoint from this list.
public enum RealtimeModelLayout {
    public struct Tensor: Sendable, Equatable {
        public let name: String
        public let shape: [Int]
    }

    /// The tensors of a checkpoint with `blockCount` blocks and one decoder pair per block.
    public static func tensors(blockCount: Int) -> [Tensor] {
        let width = RealtimeModel.width
        let taps = RealtimeModel.kernelTaps
        var tensors: [Tensor] = []

        for variant in 1...(RealtimeModel.maximumLookAhead + 1) {
            let layer = "dense_encoder.dense_conv_1_\(variant)"
            tensors += conv("\(layer).0", [width, RealtimeModel.inputChannels, taps, taps])
            tensors += normAndSlope(norm: "\(layer).1", slope: "\(layer).2")
        }
        tensors += denseStack("dense_encoder")
        tensors += conv("dense_encoder.dense_conv_2.0", [width, width, 1, taps])
        tensors += normAndSlope(
            norm: "dense_encoder.dense_conv_2.1", slope: "dense_encoder.dense_conv_2.2")

        for block in 0..<blockCount {
            let prefix = "TSMamba.\(block)"
            tensors += scan("\(prefix).time_mamba.forward_blocks")
            tensors += branchHead("\(prefix).time_mamba", inputWidth: width)
            tensors += scan("\(prefix).freq_mamba.forward_blocks")
            tensors += scan("\(prefix).freq_mamba.backward_blocks")
            tensors += branchHead("\(prefix).freq_mamba", inputWidth: 2 * width)
        }

        // The checkpoint also stores one decoder pair outside the per-exit lists; the
        // published forward pass never calls it.
        let decoderPrefixes =
            [("mask_decoder", "phase_decoder")]
            + (0..<blockCount).map { ("mask_decoder_list.\($0)", "phase_decoder_list.\($0)") }
        for (magnitude, phase) in decoderPrefixes {
            tensors += decoder(magnitude, readouts: RealtimeDecoderWeights.magnitudeReadouts)
            tensors += decoder(phase, readouts: RealtimeDecoderWeights.phaseReadouts)
        }
        return tensors
    }

    private static func conv(_ prefix: String, _ shape: [Int]) -> [Tensor] {
        [
            Tensor(name: "\(prefix).weight", shape: shape),
            Tensor(name: "\(prefix).bias", shape: [shape[0]]),
        ]
    }

    private static func normAndSlope(norm: String, slope: String) -> [Tensor] {
        let width = RealtimeModel.width
        return [
            Tensor(name: "\(norm).norm.weight", shape: [width]),
            Tensor(name: "\(norm).norm.bias", shape: [width]),
            Tensor(name: "\(slope).weight", shape: [width]),
        ]
    }

    private static func denseStack(_ prefix: String) -> [Tensor] {
        let width = RealtimeModel.width
        let taps = RealtimeModel.kernelTaps
        return (0..<RealtimeModel.denseDepth).flatMap { index -> [Tensor] in
            let layer = "\(prefix).dense_block.dense_block.\(index)"
            return conv("\(layer).1", [width, width * (index + 1), taps, taps])
                + normAndSlope(norm: "\(layer).2", slope: "\(layer).3")
        }
    }

    static func scan(_ prefix: String) -> [Tensor] {
        let width = RealtimeModel.width
        let inner = RealtimeModel.innerWidth
        let states = RealtimeModel.stateSize
        let rank = RealtimeModel.stepRank
        return [
            Tensor(name: "\(prefix).in_proj.weight", shape: [2 * inner, width]),
            Tensor(name: "\(prefix).conv1d.weight", shape: [inner, 1, RealtimeModel.scanTaps]),
            Tensor(name: "\(prefix).conv1d.bias", shape: [inner]),
            Tensor(name: "\(prefix).x_proj.weight", shape: [rank + 2 * states, inner]),
            Tensor(name: "\(prefix).dt_proj.weight", shape: [inner, rank]),
            Tensor(name: "\(prefix).dt_proj.bias", shape: [inner]),
            Tensor(name: "\(prefix).A_log", shape: [inner, states]),
            Tensor(name: "\(prefix).D", shape: [inner]),
            Tensor(name: "\(prefix).out_proj.weight", shape: [width, inner]),
        ]
    }

    static func branchHead(_ prefix: String, inputWidth: Int) -> [Tensor] {
        let width = RealtimeModel.width
        return [
            Tensor(name: "\(prefix).output_proj.weight", shape: [width, inputWidth]),
            Tensor(name: "\(prefix).output_proj.bias", shape: [width]),
            Tensor(name: "\(prefix).norm.weight", shape: [width]),
            Tensor(name: "\(prefix).norm.bias", shape: [width]),
        ]
    }

    private static func decoder(_ prefix: String, readouts: [String]) -> [Tensor] {
        let width = RealtimeModel.width
        let taps = RealtimeModel.kernelTaps
        var tensors = denseStack(prefix)
        tensors += conv("\(prefix).up_conv1.0.conv", [2 * width, width, 1, taps])
        tensors += normAndSlope(norm: "\(prefix).up_conv1.1", slope: "\(prefix).up_conv1.2")
        tensors += conv("\(prefix).up_conv2.0.conv", [width, width, 1, taps])
        tensors += normAndSlope(norm: "\(prefix).up_conv2.1", slope: "\(prefix).up_conv2.2")
        for readout in readouts {
            tensors += conv("\(prefix).\(readout)", [1, width, 1, 1])
        }
        return tensors
    }
}
