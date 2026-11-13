import Foundation

/// Why a checkpoint does not fit the model, worded for whoever has to fix the file.
public enum WeightMapError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingTensor(name: String)
    case repeatedRead(name: String)
    case shapeMismatch(name: String, expected: [Int], actual: [Int])
    case unconsumed(names: [String])

    public var description: String {
        switch self {
        case .missingTensor(let name):
            return """
                the checkpoint has no tensor '\(name)'; it is not the checkpoint this model \
                loads; download the matching one
                """
        case .repeatedRead(let name):
            return """
                two layers both claim tensor '\(name)'; the model would read the same weights \
                twice, so the checkpoint cannot be matched to it
                """
        case .shapeMismatch(let name, let expected, let actual):
            return """
                tensor '\(name)' has shape \(actual) but the layer needs \(expected); the \
                checkpoint does not match the model
                """
        case .unconsumed(let names):
            return """
                the checkpoint holds \(names.count) tensor(s) the model never reads, starting \
                with '\(names[0])'; it belongs to a different model
                """
        }
    }
}

/// Hands the tensors of a checkpoint to the layers that need them, each exactly once.
///
/// Loading is a two-sided check: a layer fails when its tensor is absent, and `finish` fails
/// when a tensor is left over. Together they mean the checkpoint and the model describe the
/// same set of weights, so a renamed or extra tensor cannot pass as a successful load.
public struct WeightMap {
    private let tensors: [String: SafeTensor]
    private var consumed: Set<String> = []

    public init(_ checkpoint: SafeTensors) {
        tensors = checkpoint.tensors
    }

    /// The names read so far.
    public var consumedNames: Set<String> {
        consumed
    }

    /// The names the checkpoint holds.
    public var availableNames: Set<String> {
        Set(tensors.keys)
    }

    /// The time-frequency blocks the checkpoint holds: one more than the highest index it names.
    public var blockCount: Int {
        let prefix = "TSMamba."
        let indices = tensors.keys.compactMap { name -> Int? in
            guard name.hasPrefix(prefix) else {
                return nil
            }
            return name.dropFirst(prefix.count).split(separator: ".").first.flatMap { Int($0) }
        }
        return (indices.max() ?? -1) + 1
    }

    /// Reads one tensor and checks it against the shape the layer expects.
    ///
    /// The values come back as a copy, because the layers keep their own transposed and
    /// precomputed copies and the checkpoint buffer belongs to the caller.
    public mutating func take(_ name: String, shape: [Int]) throws -> [Float] {
        Self.values(of: try claim(name, shape: shape))
    }

    /// Accounts for a tensor the caller does not compute with, checking its shape without
    /// copying its values.
    public mutating func check(_ name: String, shape: [Int]) throws {
        _ = try claim(name, shape: shape)
    }

    private mutating func claim(_ name: String, shape: [Int]) throws -> SafeTensor {
        guard let tensor = tensors[name] else {
            throw WeightMapError.missingTensor(name: name)
        }
        guard consumed.insert(name).inserted else {
            throw WeightMapError.repeatedRead(name: name)
        }
        guard tensor.shape == shape else {
            throw WeightMapError.shapeMismatch(name: name, expected: shape, actual: tensor.shape)
        }
        return tensor
    }

    /// Throws unless every tensor in the checkpoint was read.
    public func finish() throws {
        let leftover = Set(tensors.keys).subtracting(consumed)
        guard leftover.isEmpty else {
            throw WeightMapError.unconsumed(names: leftover.sorted())
        }
    }

    /// Loads every tensor the real-time model reads and fails on the first one that does not fit.
    ///
    /// `exitLayer` is the depth the stream runs at; without it the deepest block the checkpoint
    /// carries is used. Nothing is kept: the call answers whether the checkpoint can be the model.
    public static func validateRealtimeModel(
        _ checkpoint: SafeTensors,
        exitLayer: Int? = nil
    ) throws {
        var map = WeightMap(checkpoint)
        let depth = exitLayer ?? max(1, map.blockCount)
        _ = try RealtimeRestorerWeights(map: &map, exitLayer: depth)
        try map.finish()
    }

    /// Loads every tensor the offline model reads and fails on the first one that does not fit,
    /// or on any tensor left over once the model has read what it needs.
    public static func validateOfflineModel(
        _ checkpoint: SafeTensors,
        blockCount: Int = OfflineModel.blockCount
    ) throws {
        var map = WeightMap(checkpoint)
        _ = try OfflineRestorerWeights(map: &map, blockCount: blockCount)
        try map.finish()
    }

    private static func values(of tensor: SafeTensor) -> [Float] {
        let elementSize = MemoryLayout<UInt32>.size
        return tensor.bytes.withUnsafeBytes { bytes in
            var values = [Float](repeating: 0, count: tensor.elementCount)
            for index in values.indices {
                let bits = bytes.loadUnaligned(
                    fromByteOffset: index * elementSize,
                    as: UInt32.self
                )
                values[index] = Float(bitPattern: UInt32(littleEndian: bits))
            }
            return values
        }
    }
}
