import Testing
import UntunnelDSP

@Test
func driftResamplerHoldsFillAgainstAFastProducer() {
    let hopSize = 512
    let ring = RingBuffer(capacity: 8 * hopSize)
    let resampler = DriftResampler(hopSize: hopSize)
    let consumerRate = 48_000.0
    let producerRate = consumerRate * (1 + 500 / 1_000_000)
    let warmUpHops = 100
    let hops = 60 * 60 * 48_000 / hopSize

    let source = [Float](repeating: 0, count: 2 * hopSize)
    let prime = Int(resampler.targetFillHops * Double(hopSize))
    _ = source.withUnsafeBufferPointer { ring.write(UnsafeBufferPointer(rebasing: $0[0..<prime])) }

    var output = [Float](repeating: 0, count: hopSize)
    var producerDebt = 0.0
    var lowestFill = Double.infinity
    var highestFill = 0.0
    var underflows = 0

    for hop in 0..<hops {
        producerDebt += Double(hopSize) * producerRate / consumerRate
        let frames = Int(producerDebt)
        producerDebt -= Double(frames)
        _ = source.withUnsafeBufferPointer {
            ring.write(UnsafeBufferPointer(rebasing: $0[0..<frames]))
        }

        let produced = output.withUnsafeMutableBufferPointer {
            resampler.pullHop(from: ring, into: $0)
        }
        guard hop >= warmUpHops else {
            continue
        }
        if produced < hopSize {
            underflows += 1
        }
        let fill = Double(ring.availableToRead) / Double(hopSize)
        lowestFill = min(lowestFill, fill)
        highestFill = max(highestFill, fill)
    }

    #expect(underflows == 0)
    #expect(lowestFill >= 0.5)
    #expect(highestFill <= 2.5)
}
