import Foundation

/// A mono WAV file: 16-bit PCM when written, 16-bit PCM or 32-bit float when read.
struct WAVFile: Equatable {
    let sampleRate: Int
    let samples: [Float]

    private static let pcmFormat: UInt16 = 1
    private static let floatFormat: UInt16 = 3
    private static let headerBytes = 44

    enum ReadError: Error, Equatable, CustomStringConvertible {
        case notWAV
        case unsupported(String)
        case empty

        var description: String {
            switch self {
            case .notWAV:
                return "the file is not a WAV file"
            case .unsupported(let detail):
                return "the WAV file uses an unsupported format: \(detail)"
            case .empty:
                return "the WAV file has no audio"
            }
        }
    }

    /// Writes 16-bit PCM, clipping anything outside -1...1.
    func encoded() -> Data {
        let dataBytes = samples.count * 2
        var data = Data(capacity: Self.headerBytes + dataBytes)
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(littleEndian: UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        data.append(littleEndian: UInt32(16))
        data.append(littleEndian: Self.pcmFormat)
        data.append(littleEndian: UInt16(1))
        data.append(littleEndian: UInt32(sampleRate))
        data.append(littleEndian: UInt32(sampleRate * 2))
        data.append(littleEndian: UInt16(2))
        data.append(littleEndian: UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        data.append(littleEndian: UInt32(dataBytes))
        for sample in samples {
            let clipped = min(1, max(-1, sample))
            data.append(littleEndian: UInt16(bitPattern: Int16((clipped * 32_767).rounded())))
        }
        return data
    }

    /// Reads the first chunks of a WAV file; several channels are averaged into one.
    init(decoding data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 12,
            Array(bytes[0..<4]) == Array("RIFF".utf8),
            Array(bytes[8..<12]) == Array("WAVE".utf8)
        else {
            throw ReadError.notWAV
        }
        var format: (tag: UInt16, channels: Int, rate: Int, bits: Int)?
        var offset = 12
        while offset + 8 <= bytes.count {
            let name = Array(bytes[offset..<(offset + 4)])
            let size = Int(Self.uint32(bytes, at: offset + 4))
            let body = offset + 8
            let available = min(size, bytes.count - body)
            if name == Array("fmt ".utf8), available >= 16 {
                format = (
                    Self.uint16(bytes, at: body),
                    Int(Self.uint16(bytes, at: body + 2)),
                    Int(Self.uint32(bytes, at: body + 4)),
                    Int(Self.uint16(bytes, at: body + 14))
                )
            } else if name == Array("data".utf8) {
                guard let format else {
                    throw ReadError.notWAV
                }
                self = try Self.samples(
                    Array(bytes[body..<(body + available)]),
                    tag: format.tag,
                    channels: format.channels,
                    rate: format.rate,
                    bits: format.bits
                )
                return
            }
            offset = body + size + size % 2
        }
        throw ReadError.notWAV
    }

    init(sampleRate: Int, samples: [Float]) {
        self.sampleRate = sampleRate
        self.samples = samples
    }

    private static func samples(
        _ body: [UInt8],
        tag: UInt16,
        channels: Int,
        rate: Int,
        bits: Int
    ) throws -> WAVFile {
        guard (tag == pcmFormat && bits == 16) || (tag == floatFormat && bits == 32) else {
            throw ReadError.unsupported("format \(tag) with \(bits) bits")
        }
        guard channels > 0, rate > 0 else {
            throw ReadError.unsupported("\(channels) channels at \(rate) Hz")
        }
        let width = bits / 8
        let frames = body.count / (width * channels)
        guard frames > 0 else {
            throw ReadError.empty
        }
        var mono = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels {
                let at = (frame * channels + channel) * width
                if bits == 16 {
                    sum += Float(Int16(bitPattern: uint16(body, at: at))) / 32_768
                } else {
                    sum += Float(bitPattern: uint32(body, at: at))
                }
            }
            mono[frame] = sum / Float(channels)
        }
        return WAVFile(sampleRate: rate, samples: mono)
    }

    private static func uint16(_ bytes: [UInt8], at index: Int) -> UInt16 {
        UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
    }

    private static func uint32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        UInt32(uint16(bytes, at: index)) | UInt32(uint16(bytes, at: index + 2)) << 16
    }
}

extension Data {
    fileprivate mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

/// Five seconds of one path's input and output, kept sample for sample.
///
/// Both sides come from the same capture, so a listener comparing the two files hears the
/// restoration and nothing else.
struct ABTake: Equatable, Sendable {
    static let seconds = 5

    let sampleRate: Int
    let before: [Float]
    let after: [Float]

    init(sampleRate: Int, before: [Float], after: [Float]) {
        precondition(before.count == after.count, "both sides must come from the same take")
        self.sampleRate = sampleRate
        self.before = before
        self.after = after
    }

    /// Writes `before-STAMP.wav` and `after-STAMP.wav` into `directory`, creating it first.
    func write(into directory: URL, stamp: String) throws -> (before: URL, after: URL) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let beforeURL = directory.appendingPathComponent("before-\(stamp).wav")
        let afterURL = directory.appendingPathComponent("after-\(stamp).wav")
        try WAVFile(sampleRate: sampleRate, samples: before).encoded()
            .write(to: beforeURL, options: .atomic)
        try WAVFile(sampleRate: sampleRate, samples: after).encoded()
            .write(to: afterURL, options: .atomic)
        return (beforeURL, afterURL)
    }
}
