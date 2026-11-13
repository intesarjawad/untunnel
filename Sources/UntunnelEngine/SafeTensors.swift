import Foundation

/// One tensor read from a SafeTensors checkpoint.
public struct SafeTensor: Sendable {
    /// The tensor name as written in the file header.
    public let key: String
    /// The dimensions in row-major order; empty for a scalar.
    public let shape: [Int]
    /// The F32 payload, a view into the checkpoint buffer rather than a copy.
    public let bytes: Data

    /// The number of F32 elements the shape describes.
    public var elementCount: Int {
        shape.reduce(1, *)
    }
}

/// The tensors of one SafeTensors checkpoint, read in place.
public struct SafeTensors: Sendable {
    /// Every tensor in the checkpoint, keyed by its header name.
    public let tensors: [String: SafeTensor]

    /// Reads the header and checks every tensor against the bytes it claims.
    ///
    /// Tensor payloads are slices of `data`, so loading a checkpoint copies nothing and the
    /// caller keeps ownership of the buffer.
    public init(data: Data) throws {
        guard data.count >= Self.lengthPrefixSize else {
            throw SafeTensorsError.truncatedHeader(available: data.count)
        }

        let headerLength = Self.headerLength(in: data)
        let bytesAfterPrefix = data.count - Self.lengthPrefixSize
        guard headerLength <= UInt64(bytesAfterPrefix) else {
            throw SafeTensorsError.headerPastEOF(
                headerLength: headerLength,
                available: bytesAfterPrefix
            )
        }

        let headerStart = data.startIndex + Self.lengthPrefixSize
        let payloadStart = headerStart + Int(headerLength)
        let payloadSize = bytesAfterPrefix - Int(headerLength)
        let header = try Self.decodeHeader(data[headerStart..<payloadStart])

        var tensors: [String: SafeTensor] = [:]
        var occupied: [(key: String, range: Range<Int>)] = []

        for (key, entry) in header.sorted(by: { $0.key < $1.key }) where key != Self.metadataKey {
            guard let dtype = entry.dtype, let shape = entry.shape, let offsets = entry.dataOffsets
            else {
                throw SafeTensorsError.incompleteTensor(key: key)
            }
            guard dtype == Self.supportedDataType else {
                throw SafeTensorsError.unsupportedDataType(key: key, dataType: dtype)
            }

            var elementCount = 1
            for dimension in shape {
                let (product, overflow) = elementCount.multipliedReportingOverflow(by: dimension)
                guard dimension >= 0, !overflow else {
                    throw SafeTensorsError.invalidShape(key: key)
                }
                elementCount = product
            }
            let (expectedBytes, overflow) = elementCount.multipliedReportingOverflow(
                by: Self.elementSize
            )
            guard !overflow else {
                throw SafeTensorsError.invalidShape(key: key)
            }

            guard offsets.count == 2, offsets[0] >= 0, offsets[0] <= offsets[1] else {
                throw SafeTensorsError.invalidDataOffsets(key: key)
            }
            let start = offsets[0]
            let end = offsets[1]
            guard end <= payloadSize else {
                throw SafeTensorsError.dataPastEOF(key: key, end: end, available: payloadSize)
            }
            guard end - start == expectedBytes else {
                throw SafeTensorsError.sizeMismatch(
                    key: key,
                    expected: expectedBytes,
                    actual: end - start
                )
            }

            tensors[key] = SafeTensor(
                key: key,
                shape: shape,
                bytes: data[(payloadStart + start)..<(payloadStart + end)]
            )
            occupied.append((key: key, range: start..<end))
        }

        let ordered = occupied.sorted { $0.range.lowerBound < $1.range.lowerBound }
        for index in ordered.indices.dropFirst() {
            let previous = ordered[index - 1]
            let current = ordered[index]
            guard previous.range.upperBound <= current.range.lowerBound else {
                throw SafeTensorsError.overlappingTensors(
                    key: current.key,
                    overlapsWith: previous.key
                )
            }
        }

        self.tensors = tensors
    }

    private static let lengthPrefixSize = 8
    private static let elementSize = MemoryLayout<Float32>.size
    private static let supportedDataType = "F32"
    private static let metadataKey = "__metadata__"

    private struct HeaderEntry: Decodable {
        let dtype: String?
        let shape: [Int]?
        let dataOffsets: [Int]?

        private enum CodingKeys: String, CodingKey {
            case dtype
            case shape
            case dataOffsets = "data_offsets"
        }
    }

    private static func headerLength(in data: Data) -> UInt64 {
        let raw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt64.self) }
        return UInt64(littleEndian: raw)
    }

    private static func decodeHeader(_ bytes: Data) throws -> [String: HeaderEntry] {
        do {
            return try JSONDecoder().decode([String: HeaderEntry].self, from: bytes)
        } catch {
            throw SafeTensorsError.malformedHeader
        }
    }
}

/// Why a checkpoint cannot be read, worded for the person who has to fix the file.
public enum SafeTensorsError: Error, Equatable, Sendable, CustomStringConvertible {
    case truncatedHeader(available: Int)
    case headerPastEOF(headerLength: UInt64, available: Int)
    case malformedHeader
    case incompleteTensor(key: String)
    case unsupportedDataType(key: String, dataType: String)
    case invalidShape(key: String)
    case invalidDataOffsets(key: String)
    case dataPastEOF(key: String, end: Int, available: Int)
    case sizeMismatch(key: String, expected: Int, actual: Int)
    case overlappingTensors(key: String, overlapsWith: String)

    public var description: String {
        switch self {
        case .truncatedHeader(let available):
            return """
                the checkpoint is \(available) bytes but starts with an 8-byte header length; \
                the file is truncated; download it again
                """
        case .headerPastEOF(let headerLength, let available):
            return """
                the header claims \(headerLength) bytes but only \(available) follow the length \
                prefix; the file is truncated; download it again
                """
        case .malformedHeader:
            return """
                the header is not JSON mapping tensor names to dtype, shape and data_offsets; \
                the file is not a SafeTensors checkpoint; download it again
                """
        case .incompleteTensor(let key):
            return """
                tensor '\(key)' has no dtype, shape or data_offsets in the header; the header is \
                corrupt; download the checkpoint again
                """
        case .unsupportedDataType(let key, let dataType):
            return """
                tensor '\(key)' uses dtype '\(dataType)' but only F32 is supported; convert the \
                checkpoint to F32 or choose an F32 checkpoint
                """
        case .invalidShape(let key):
            return """
                tensor '\(key)' has a shape with a negative or overflowing dimension; the header \
                is corrupt; download the checkpoint again
                """
        case .invalidDataOffsets(let key):
            return """
                tensor '\(key)' has data_offsets that are not two non-negative increasing \
                integers; the header is corrupt; download the checkpoint again
                """
        case .dataPastEOF(let key, let end, let available):
            return """
                tensor '\(key)' ends \(end) bytes into the payload but the payload is only \
                \(available) bytes; the file is truncated; download it again
                """
        case .sizeMismatch(let key, let expected, let actual):
            return """
                tensor '\(key)' needs \(expected) bytes for its shape but its data_offsets cover \
                \(actual); the header and payload disagree; download the checkpoint again
                """
        case .overlappingTensors(let key, let overlapsWith):
            return """
                tensor '\(key)' shares bytes with '\(overlapsWith)'; the checkpoint is corrupt; \
                download it again
                """
        }
    }
}
