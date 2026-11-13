import Foundation
import UntunnelEngine

/// One tensor of a synthetic checkpoint.
struct ModelTensor {
    let name: String
    let shape: [Int]
    let values: [Float]
}

/// A splitmix64 stream, so a failing comparison reproduces from the seed alone.
struct ModelRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    private mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var bits = state
        bits = (bits ^ (bits >> 30)) &* 0xBF58_476D_1CE4_E5B9
        bits = (bits ^ (bits >> 27)) &* 0x94D0_49BB_1331_11EB
        return bits ^ (bits >> 31)
    }

    /// Uniform in 0...1.
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    /// Uniform in -limit...limit.
    mutating func values(count: Int, limit: Float) -> [Float] {
        (0..<count).map { _ in Float(unit()) * 2 * limit - limit }
    }

    /// Uniform in -limit + 1...limit + 1, which keeps a normalisation scale near one.
    mutating func scales(count: Int, limit: Float) -> [Float] {
        values(count: count, limit: limit).map { $0 + 1 }
    }
}

/// Builds a SafeTensors file in memory from the tensors the model asks for.
///
/// Writing the file here rather than calling the code under test keeps the loader on its normal
/// path: it parses a real header, checks every offset and copies real bytes.
func modelCheckpoint(_ tensors: [ModelTensor]) -> Data {
    var payload: [UInt8] = []
    var entries: [String] = []

    for tensor in tensors {
        let start = payload.count
        for value in tensor.values {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { payload.append(contentsOf: $0) }
        }
        let shape = tensor.shape.map(String.init).joined(separator: ",")
        entries.append(
            """
            "\(tensor.name)":{"dtype":"F32","shape":[\(shape)],\
            "data_offsets":[\(start),\(payload.count)]}
            """
        )
    }

    let header = "{" + entries.joined(separator: ",") + "}"
    let headerBytes = Array(header.utf8)
    let prefix = (0..<8).map {
        UInt8(truncatingIfNeeded: UInt64(headerBytes.count) >> (8 * UInt64($0)))
    }
    return Data(prefix + headerBytes + payload)
}

/// Loads a checkpoint, builds the weights and fails if any tensor was left unread.
func load<T>(
    _ tensors: [ModelTensor],
    build: (inout WeightMap) throws -> T
) throws -> T {
    var map = WeightMap(try SafeTensors(data: modelCheckpoint(tensors)))
    let value = try build(&map)
    try map.finish()
    return value
}

/// The largest absolute difference between two equally sized buffers.
func largestGap(_ lhs: [Float], _ rhs: [Float]) -> Float {
    precondition(lhs.count == rhs.count, "the buffers hold different numbers of values")
    var largest: Float = 0
    for index in lhs.indices {
        largest = max(largest, abs(lhs[index] - rhs[index]))
    }
    return largest
}

/// A checkpoint in the published real-time layout with `blockCount` blocks, drawn from `seed`.
func realtimeTensors(blockCount: Int, seed: UInt64) -> [ModelTensor] {
    drawnTensors(RealtimeModelLayout.tensors(blockCount: blockCount), seed: seed)
}

/// A checkpoint in the published offline layout with `blockCount` blocks, drawn from `seed`.
func offlineTensors(blockCount: Int, seed: UInt64) -> [ModelTensor] {
    drawnTensors(OfflineModelLayout.tensors(blockCount: blockCount), seed: seed)
}

/// Small values for every tensor of `layout`, with normalisation scales near one.
private func drawnTensors(_ layout: [RealtimeModelLayout.Tensor], seed: UInt64) -> [ModelTensor] {
    var random = ModelRandom(seed: seed)
    return layout.map { tensor in
        let count = tensor.shape.reduce(1, *)
        return ModelTensor(
            name: tensor.name,
            shape: tensor.shape,
            values: isNormScale(tensor)
                ? random.scales(count: count, limit: 0.1)
                : random.values(count: count, limit: 0.1)
        )
    }
}

/// Whether `tensor` scales a normalisation: named so in the real-time layout, and the second
/// entry of a convolution's `Sequential` in the offline one.
private func isNormScale(_ tensor: RealtimeModelLayout.Tensor) -> Bool {
    tensor.name.hasSuffix("norm.weight")
        || (tensor.shape.count == 1 && tensor.name.hasSuffix(".1.weight"))
}
