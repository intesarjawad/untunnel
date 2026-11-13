import Foundation
import Testing
import UntunnelEngine

@Test
func safeTensorsReadsEveryTensorInPlace() throws {
    let file = checkpoint(
        header: """
            {"a":{"dtype":"F32","shape":[2],"data_offsets":[0,8]},\
            "b":{"dtype":"F32","shape":[1,2],"data_offsets":[8,16]}}
            """,
        payload: [
            0x00, 0x00, 0x80, 0x3F, 0x00, 0x00, 0x00, 0x40,
            0x00, 0x00, 0x00, 0x3F, 0x00, 0x00, 0x00, 0x3F,
        ]
    )

    let parsed = try SafeTensors(data: file)

    #expect(parsed.tensors.keys.sorted() == ["a", "b"])
    #expect(parsed.tensors["a"]?.shape == [2])
    #expect(parsed.tensors["a"]?.elementCount == 2)
    #expect(
        parsed.tensors["a"]?.bytes
            == Data([0x00, 0x00, 0x80, 0x3F, 0x00, 0x00, 0x00, 0x40])
    )
    #expect(parsed.tensors["b"]?.shape == [1, 2])
    #expect(
        parsed.tensors["b"]?.bytes
            == Data([0x00, 0x00, 0x00, 0x3F, 0x00, 0x00, 0x00, 0x3F])
    )
}

@Test
func safeTensorsRejectsFileShorterThanLengthPrefix() {
    let error = #expect(throws: SafeTensorsError.self) {
        _ = try SafeTensors(data: Data([0x01, 0x02, 0x03]))
    }

    #expect(error == .truncatedHeader(available: 3))
}

@Test
func safeTensorsRejectsHeaderLengthPastEOF() {
    let error = #expect(throws: SafeTensorsError.self) {
        _ = try SafeTensors(data: Data(littleEndianBytes(64)))
    }

    #expect(error == .headerPastEOF(headerLength: 64, available: 0))
}

@Test
func safeTensorsRejectsUnknownDataType() {
    let file = checkpoint(
        header: #"{"w":{"dtype":"BF16","shape":[2],"data_offsets":[0,4]}}"#,
        payload: [0x00, 0x00, 0x80, 0x3F]
    )

    let error = #expect(throws: SafeTensorsError.self) {
        _ = try SafeTensors(data: file)
    }

    #expect(error == .unsupportedDataType(key: "w", dataType: "BF16"))
    #expect(error?.description.contains("'w'") == true)
    #expect(error?.description.contains("F32") == true)
}

@Test
func safeTensorsRejectsOverlappingTensors() {
    let file = checkpoint(
        header: """
            {"a":{"dtype":"F32","shape":[2],"data_offsets":[0,8]},\
            "b":{"dtype":"F32","shape":[2],"data_offsets":[4,12]}}
            """,
        payload: [UInt8](repeating: 0, count: 12)
    )

    let error = #expect(throws: SafeTensorsError.self) {
        _ = try SafeTensors(data: file)
    }

    #expect(error == .overlappingTensors(key: "b", overlapsWith: "a"))
}

@Test
func safeTensorsRejectsDataOffsetPastEOF() {
    let file = checkpoint(
        header: #"{"a":{"dtype":"F32","shape":[4],"data_offsets":[0,16]}}"#,
        payload: [UInt8](repeating: 0, count: 8)
    )

    let error = #expect(throws: SafeTensorsError.self) {
        _ = try SafeTensors(data: file)
    }

    #expect(error == .dataPastEOF(key: "a", end: 16, available: 8))
}

@Test
func safeTensorsRejectsPayloadThatDisagreesWithShape() {
    let file = checkpoint(
        header: #"{"a":{"dtype":"F32","shape":[2],"data_offsets":[0,4]}}"#,
        payload: [UInt8](repeating: 0, count: 8)
    )

    let error = #expect(throws: SafeTensorsError.self) {
        _ = try SafeTensors(data: file)
    }

    #expect(error == .sizeMismatch(key: "a", expected: 8, actual: 4))
}

@Test
func safeTensorsRejectsOffsetsThatDoNotIncrease() {
    let file = checkpoint(
        header: #"{"a":{"dtype":"F32","shape":[2],"data_offsets":[8,0]}}"#,
        payload: [UInt8](repeating: 0, count: 8)
    )

    let error = #expect(throws: SafeTensorsError.self) {
        _ = try SafeTensors(data: file)
    }

    #expect(error == .invalidDataOffsets(key: "a"))
}

@Test
func safeTensorsRejectsTensorWithoutOffsets() {
    let file = checkpoint(
        header: #"{"a":{"dtype":"F32","shape":[1]}}"#,
        payload: [0x00, 0x00, 0x80, 0x3F]
    )

    let error = #expect(throws: SafeTensorsError.self) {
        _ = try SafeTensors(data: file)
    }

    #expect(error == .incompleteTensor(key: "a"))
}

@Test
func safeTensorsRejectsHeaderThatIsNotJSON() {
    let error = #expect(throws: SafeTensorsError.self) {
        _ = try SafeTensors(data: checkpoint(header: "not json", payload: []))
    }

    #expect(error == .malformedHeader)
}

private func checkpoint(header: String, payload: [UInt8]) -> Data {
    let headerBytes = Array(header.utf8)
    return Data(littleEndianBytes(UInt64(headerBytes.count)) + headerBytes + payload)
}

/// Little-endian byte order, so the fixture does not depend on the host.
private func littleEndianBytes(_ value: UInt64) -> [UInt8] {
    (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
}
