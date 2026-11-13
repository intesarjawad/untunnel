import Testing
import UntunnelDSP

@Test
func ringBufferPreservesOrderAcrossWrapAround() {
    let ring = RingBuffer(capacity: 8)

    func write(_ values: [Float]) -> Int {
        values.withUnsafeBufferPointer { ring.write($0) }
    }

    func read(_ count: Int) -> [Float] {
        var result = [Float](repeating: 0, count: count)
        let read = result.withUnsafeMutableBufferPointer { ring.read(into: $0) }
        #expect(read == count)
        return result
    }

    #expect(write([0, 1, 2, 3, 4, 5]) == 6)
    #expect(read(4) == [0, 1, 2, 3])
    #expect(write([6, 7, 8, 9, 10, 11]) == 6)
    #expect(read(8) == [4, 5, 6, 7, 8, 9, 10, 11])
}

@Test
func ringBufferReturnsOnlyAvailableFramesOnUnderflow() {
    let ring = RingBuffer(capacity: 4)
    _ = [1, 2].withUnsafeBufferPointer { ring.write($0) }

    var frames = [Float](repeating: 0, count: 4)
    let firstRead = frames.withUnsafeMutableBufferPointer { ring.read(into: $0) }
    #expect(firstRead == 2)
    #expect(frames == [1, 2, 0, 0])
    #expect(ring.availableToRead == 0)

    let secondRead = frames.withUnsafeMutableBufferPointer { ring.read(into: $0) }
    #expect(secondRead == 0)
    #expect(ring.pop() == nil)
}

@Test
func ringBufferDropsFramesBeyondCapacity() {
    let ring = RingBuffer(capacity: 4)
    let written = [1, 2, 3, 4, 5, 6].withUnsafeBufferPointer { ring.write($0) }
    #expect(written == 4)
    #expect(ring.availableToWrite == 0)

    var frames = [Float](repeating: 0, count: 6)
    let read = frames.withUnsafeMutableBufferPointer { ring.read(into: $0) }
    #expect(read == 4)
    #expect(frames == [1, 2, 3, 4, 0, 0])
}

@Test
func ringBufferCanBeFilledAndDrainedRepeatedly() {
    let ring = RingBuffer(capacity: 3)
    var frames = [Float](repeating: 0, count: 3)

    for round in 0..<4 {
        let values = (0..<3).map { Float(round * 3 + $0) }
        #expect(values.withUnsafeBufferPointer { ring.write($0) } == 3)
        let read = frames.withUnsafeMutableBufferPointer { ring.read(into: $0) }
        #expect(read == 3)
        #expect(frames == values)
    }
}
