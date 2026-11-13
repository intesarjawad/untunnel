import Foundation
import Testing

@testable import Untunnel

private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    withUnsafeBytes(of: value.littleEndian) { Array($0) }
}

private func chunk(_ name: String, _ body: [UInt8]) -> [UInt8] {
    Array(name.utf8) + littleEndian(UInt32(body.count)) + body
}

private func wav(chunks: [[UInt8]]) -> Data {
    let body = Array("WAVE".utf8) + chunks.flatMap { $0 }
    return Data(Array("RIFF".utf8) + littleEndian(UInt32(body.count)) + body)
}

private func format(tag: UInt16, channels: UInt16, rate: UInt32, bits: UInt16) -> [UInt8] {
    chunk(
        "fmt ",
        littleEndian(tag) + littleEndian(channels) + littleEndian(rate)
            + littleEndian(rate * UInt32(channels) * UInt32(bits / 8))
            + littleEndian(channels * bits / 8) + littleEndian(bits)
    )
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

@Test
func encodedWAVHasTheCanonicalMonoPCMHeader() {
    let data = WAVFile(sampleRate: 8_000, samples: [0, 0.5, -0.5, 1.5, -2]).encoded()

    let expectedHeader: [UInt8] =
        Array("RIFF".utf8) + [46, 0, 0, 0] + Array("WAVEfmt ".utf8)
        + [16, 0, 0, 0, 1, 0, 1, 0]
        + [0x40, 0x1F, 0, 0]  // 8000 Hz
        + [0x80, 0x3E, 0, 0]  // 16000 bytes a second
        + [2, 0, 16, 0] + Array("data".utf8) + [10, 0, 0, 0]
    #expect(Array(data.prefix(44)) == expectedHeader)
    // 0.5 and -0.5 round to +-16384, and anything past full scale clips to +-32767.
    #expect(
        Array(data.dropFirst(44))
            == [0, 0, 0x00, 0x40, 0x00, 0xC0, 0xFF, 0x7F, 0x01, 0x80]
    )
}

@Test
func decodingReadsBackWhatWasEncodedWithinOneQuantisationStep() throws {
    let original = WAVFile(sampleRate: 16_000, samples: [0, 0.5, -0.5, 1.5, -2])

    let decoded = try WAVFile(decoding: original.encoded())

    // Typed apart from the comparison: inside #expect the literal took the type checker too long.
    let expected: [Float] = [0, 0.5, -0.5, 32_767.0 / 32_768, -32_767.0 / 32_768]
    #expect(decoded.sampleRate == 16_000)
    #expect(decoded.samples == expected)
}

@Test
func decodingAveragesFloatChannelsAndSkipsOtherChunks() throws {
    let samples: [Float] = [0.5, -0.5, 1, 0.5]
    let data = wav(chunks: [
        format(tag: 3, channels: 2, rate: 48_000, bits: 32),
        chunk("LIST", [1, 2, 3, 4]),
        chunk("data", samples.flatMap { littleEndian($0.bitPattern) }),
    ])

    let decoded = try WAVFile(decoding: data)

    #expect(decoded.sampleRate == 48_000)
    #expect(decoded.samples == [0, 0.75])
}

@Test
func decodingRejectsWhatItCannotReadWithAReason() {
    #expect(throws: WAVFile.ReadError.notWAV) {
        try WAVFile(decoding: Data("not audio at all".utf8))
    }
    #expect(throws: WAVFile.ReadError.unsupported("format 1 with 24 bits")) {
        try WAVFile(
            decoding: wav(chunks: [
                format(tag: 1, channels: 1, rate: 16_000, bits: 24),
                chunk("data", [0, 0, 0]),
            ])
        )
    }
    #expect(throws: WAVFile.ReadError.empty) {
        try WAVFile(
            decoding: wav(chunks: [
                format(tag: 1, channels: 1, rate: 16_000, bits: 16),
                chunk("data", []),
            ])
        )
    }
}

@Test
func abTakeWritesBothSidesOfTheSameTake() throws {
    let directory = temporaryDirectory()
    defer {
        try? FileManager.default.removeItem(at: directory)
    }
    let take = ABTake(
        sampleRate: 16_000,
        before: [0.25, -0.25, 0.5],
        after: [0.5, -0.5, 0.25]
    )

    let urls = try take.write(into: directory, stamp: "20260101-120000")

    #expect(urls.before.lastPathComponent == "before-20260101-120000.wav")
    #expect(urls.after.lastPathComponent == "after-20260101-120000.wav")
    let before = try WAVFile(decoding: Data(contentsOf: urls.before))
    let after = try WAVFile(decoding: Data(contentsOf: urls.after))
    #expect(before.sampleRate == 16_000)
    #expect(after.sampleRate == 16_000)
    #expect(before.samples == [0.25, -0.25, 0.5])
    #expect(after.samples == [0.5, -0.5, 0.25])
}
