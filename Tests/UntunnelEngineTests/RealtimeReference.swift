import CryptoKit
import Foundation
import Testing

@testable import UntunnelEngine

/// What every fixture manifest names: the checkpoint that produced it and its array files.
protocol ReferenceManifest: Decodable, Sendable {
    var repository: String { get }
    var revision: String { get }
    var checkpointSha256: String { get }
    /// The array files, which together hold every stored input and output.
    var files: [String] { get }
}

/// A reference implementation's outputs and the pinned checkpoint that produced them.
///
/// The generators in `tools/reference` write the fixtures; they hold inputs and outputs but no
/// weights, so a comparison also needs the checkpoint `untunnel download` stores.
struct ModelReference<Manifest: ReferenceManifest>: Sendable {
    enum Failure: Error, CustomStringConvertible {
        case checkpointMissing(download: String)
        case wrongCheckpoint(path: String, sha256: String, expected: String)
        case missingArray(name: String)

        var description: String {
            switch self {
            case .checkpointMissing(let download):
                return "no pinned checkpoint; run `\(download)`"
            case .wrongCheckpoint(let path, let sha256, let expected):
                return "\(path) has SHA-256 \(sha256), but the fixtures came from \(expected)"
            case .missingArray(let name):
                return "the reference fixtures hold no array '\(name)'; regenerate them"
            }
        }
    }

    /// Where the fixtures of one model are and how its checkpoint is found.
    struct Source: Sendable {
        /// The manifest's name without `.json` under `fixtures/model`.
        let stem: String
        /// An environment variable that points at the checkpoint instead.
        let checkpointVariable: String
        /// The command that stores the checkpoint where the suites look.
        let download: String

        var unavailableReason: Comment {
            "the pinned checkpoint is not downloaded; run `\(download)`"
        }

        /// The environment variable's path when set, else where `untunnel download` stores
        /// the revision the fixtures name.
        var checkpointURL: URL? {
            let files = FileManager.default
            if let override = ProcessInfo.processInfo.environment[checkpointVariable] {
                return files.fileExists(atPath: override) ? URL(fileURLWithPath: override) : nil
            }
            guard
                let manifest = try? readManifest(),
                let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                    .first
            else {
                return nil
            }
            let url =
                support
                .appendingPathComponent("Untunnel/models")
                .appendingPathComponent("\(manifest.repository)@\(manifest.revision)")
                .appendingPathComponent("model.safetensors")
            return files.fileExists(atPath: url.path) ? url : nil
        }

        func readManifest() throws -> Manifest {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(
                Manifest.self, from: Data(contentsOf: fixture("\(stem).json")))
        }
    }

    let manifest: Manifest
    let checkpoint: SafeTensors
    private let arrays: [String: SafeTensor]

    init(_ source: Source) throws {
        manifest = try source.readManifest()
        guard let url = source.checkpointURL else {
            throw Failure.checkpointMissing(download: source.download)
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == manifest.checkpointSha256 else {
            throw Failure.wrongCheckpoint(
                path: url.path, sha256: digest, expected: manifest.checkpointSha256)
        }
        checkpoint = try SafeTensors(data: data)
        arrays = try manifest.files.reduce(into: [:]) { arrays, file in
            let part = try SafeTensors(data: Data(contentsOf: fixture(file)))
            arrays.merge(part.tensors) { first, _ in first }
        }
    }

    /// The values and shape of one stored array.
    func array(_ name: String) throws -> (values: [Float], shape: [Int]) {
        guard let tensor = arrays[name] else {
            throw Failure.missingArray(name: name)
        }
        let values = tensor.bytes.withUnsafeBytes { bytes in
            (0..<tensor.elementCount).map {
                Float(
                    bitPattern: UInt32(
                        littleEndian: bytes.loadUnaligned(
                            fromByteOffset: $0 * MemoryLayout<UInt32>.size, as: UInt32.self)))
            }
        }
        return (values, tensor.shape)
    }
}

private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("fixtures/model/\(name)")
}

/// The real-time model's fixtures, from `tools/reference/realtime_goldens.py`.
enum RealtimeReference {
    struct Manifest: ReferenceManifest {
        let repository: String
        let revision: String
        let checkpointSha256: String
        let files: [String]
        let intermediates: Intermediates
        let goldens: [Golden]
    }

    struct Intermediates: Decodable, Sendable {
        let sampleRate: Int
        let exitLayer: Int
        let lookAhead: Int
        let frames: Int
    }

    struct Golden: Decodable, Sendable {
        let name: String
        let sampleRate: Int
        let exitLayer: Int
        let lookAhead: Int
    }

    static let source = ModelReference<Manifest>.Source(
        stem: "realtime-goldens", checkpointVariable: "UNTUNNEL_REALTIME_CHECKPOINT",
        download: "untunnel download")

    /// Whether the pinned checkpoint is on this machine, which decides if parity can run.
    static let isAvailable = source.checkpointURL != nil
    static let unavailableReason = source.unavailableReason
    /// Loaded once: reading and hashing the checkpoint takes longer than any comparison.
    static let shared = Result { try ModelReference(source) }
}

extension ModelReference where Manifest == RealtimeReference.Manifest {
    /// The weights of a stream that exits after `exitLayer` blocks.
    func weights(exitLayer: Int) throws -> RealtimeRestorerWeights {
        var map = WeightMap(checkpoint)
        let weights = try RealtimeRestorerWeights(map: &map, exitLayer: exitLayer)
        try map.finish()
        return weights
    }
}

/// The offline model's fixtures, from `tools/reference/offline_goldens.py`.
enum OfflineReference {
    struct Manifest: ReferenceManifest {
        let repository: String
        let revision: String
        let checkpointSha256: String
        let files: [String]
        let intermediates: Intermediates
        let goldens: [Golden]
    }

    struct Intermediates: Decodable, Sendable {
        let sampleRate: Int
        /// The blocks whose outputs are stored.
        let blocks: [Int]
    }

    struct Golden: Decodable, Sendable {
        let name: String
        let sampleRate: Int
    }

    static let source = ModelReference<Manifest>.Source(
        stem: "offline-goldens", checkpointVariable: "UNTUNNEL_OFFLINE_CHECKPOINT",
        download: "untunnel download --offline-model")

    static let isAvailable = source.checkpointURL != nil
    static let unavailableReason = source.unavailableReason
    static let shared = Result { try ModelReference(source) }
}

extension ModelReference where Manifest == OfflineReference.Manifest {
    /// Every weight of the published offline model.
    func weights() throws -> OfflineRestorerWeights {
        var map = WeightMap(checkpoint)
        let weights = try OfflineRestorerWeights(map: &map)
        try map.finish()
        return weights
    }
}
