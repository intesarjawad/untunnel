import Testing

@testable import UntunnelEngine

@Test
func planRejectsWhatItCannotFollow() {
    #expect(ChunkPlan(chunkSamples: 0, overlapSamples: 0) == nil)
    #expect(ChunkPlan(chunkSamples: 8, overlapSamples: -1) == nil)
    #expect(ChunkPlan(chunkSamples: 8, overlapSamples: 5) == nil)
    #expect(ChunkPlan(chunkSamples: 8, overlapSamples: 4)?.strideSamples == 4)
    #expect(ChunkPlan(chunkSamples: 8, overlapSamples: 0)?.strideSamples == 8)
}

@Test
func chunksStartOneStrideApartAndEndAtTheSignal() throws {
    let plan = try #require(ChunkPlan(chunkSamples: 8, overlapSamples: 2))

    // The publisher anchors the final full chunk to the end instead of shortening it.
    #expect(plan.ranges(total: 22) == [0..<8, 6..<14, 12..<20, 14..<22])
    #expect(plan.ranges(total: 20) == [0..<8, 6..<14, 12..<20])
    #expect(plan.ranges(total: 8) == [0..<8])
    #expect(plan.ranges(total: 3) == [0..<3])
    #expect(plan.ranges(total: 0).isEmpty)
}

@Test
func lastChunkAlwaysReachesPastItsOverlap() throws {
    let plan = try #require(ChunkPlan(chunkSamples: 10, overlapSamples: 4))

    for total in 1...60 {
        let ranges = plan.ranges(total: total)
        #expect(ranges.last?.upperBound == total)
        if ranges.count > 1 {
            #expect(ranges[ranges.count - 1].count > plan.overlapSamples)
        }
    }
}

@Test
func unchangedChunksComeBackUnchanged() throws {
    var random = ModelRandom(seed: 0xC4E1_0001)
    let signal = random.values(count: 101, limit: 1)
    let plan = try #require(ChunkPlan(chunkSamples: 16, overlapSamples: 5))

    let output = ChunkedInference.run(signal, plan: plan) { $0 }

    #expect(largestGap(output, signal) < 1e-6)
}

@Test
func joinsUseThePublishersNormalisedClampedPeriodicHann() throws {
    let plan = try #require(ChunkPlan(chunkSamples: 8, overlapSamples: 4))
    var chunk = 0
    let output = ChunkedInference.run([Float](repeating: 0, count: 12), plan: plan) { samples in
        chunk += 1
        return [Float](repeating: chunk == 1 ? 1 : 3, count: samples.count)
    }

    let expected: [Float] = [1, 1, 1, 1, 1, 1.2928932, 2, 2.7071068, 3, 3, 3, 3]
    #expect(largestGap(output, expected) < 1e-6)
}

@Test
func theFinalChunkRemainsFullEvenWithZeroNominalOverlap() throws {
    let plan = try #require(ChunkPlan(chunkSamples: 3, overlapSamples: 0))
    var chunk = 0

    let output = ChunkedInference.run([Float](repeating: 0, count: 7), plan: plan) { samples in
        chunk += 1
        return [Float](repeating: Float(chunk), count: samples.count)
    }

    #expect(largestGap(output, [1, 1, 1, 2, 2, 2.5, 3]) < 1e-6)
}
