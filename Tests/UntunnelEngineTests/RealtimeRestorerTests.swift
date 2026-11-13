import Foundation
import Testing

@testable import UntunnelEngine

private let testSampleRate = 400
private let testWindowLength = 16
private let testHopLength = 8
private let testExitLayer = 2
private let testSeed: UInt64 = 0x0E51_0001

@Test
func restorerReportsTheTierLatency() throws {
    let weights = try restorerWeights(exitLayer: testExitLayer, seed: testSeed)

    for lookAhead in 0...2 {
        let restorer = makeRestorer(weights, lookAhead: lookAhead)

        #expect(restorer.windowLength == testWindowLength)
        #expect(restorer.hopLength == testHopLength)
        #expect(restorer.binCount == 9)
        #expect(restorer.modelBins == 5)
        #expect(restorer.lookAhead == lookAhead)
        // One frame of transform latency and one hop per buffered future frame.
        #expect(restorer.latencySamples == testWindowLength + lookAhead * testHopLength)
    }

    let clamped = makeRestorer(weights, lookAhead: 1_000)
    #expect(clamped.lookAhead == RealtimeModel.maximumLookAhead)
    let clampedLatency = testWindowLength + RealtimeModel.maximumLookAhead * testHopLength
    #expect(clamped.latencySamples == clampedLatency)
}

@Test
func restorerUsesAWholeFrameOfLatencyAtFortyEightKilohertz() throws {
    let weights = try restorerWeights(exitLayer: testExitLayer, seed: testSeed)
    let restorer = RealtimeRestorer(
        weights: weights,
        tier: Tier(sampleRate: 48_000, exitLayer: testExitLayer, lookAhead: 1)
    )

    #expect(restorer.windowLength == 1_920)
    #expect(restorer.hopLength == 960)
    #expect(restorer.binCount == 961)
    #expect(restorer.modelBins == 481)
    #expect(restorer.latencySamples == 1_920 + 960)
}

@Test
func restorerReadsTheDecoderPairForItsExitDepth() throws {
    let weights = try restorerWeights(exitLayer: testExitLayer, seed: testSeed)
    #expect(weights.blocks.count == testExitLayer)

    // Without the pair trained for this depth the checkpoint cannot be read at this depth,
    // which proves the initialiser selects the pair by exit layer.
    let pair = "decoder_list.\(testExitLayer - 1)."
    let tensors = realtimeTensors(blockCount: testExitLayer, seed: testSeed)
        .filter { !$0.name.contains(pair) }

    #expect(throws: WeightMapError.self) {
        try load(tensors) { map in
            try RealtimeRestorerWeights(map: &map, exitLayer: testExitLayer)
        }
    }
}

@Test
func restorerAccountsForDeeperExitsButKeepsTheRequestedDepth() throws {
    let weights = try load(realtimeTensors(blockCount: 3, seed: 0x0E51_0006)) { map in
        try RealtimeRestorerWeights(map: &map, exitLayer: 2)
    }

    #expect(weights.blocks.count == 2)
}

@Test
func restorerEmitsOneSilentSamplePerLatencySample() throws {
    let weights = try restorerWeights(exitLayer: testExitLayer, seed: testSeed)

    for lookAhead in 0...2 {
        let restorer = makeRestorer(weights, lookAhead: lookAhead)
        let input = randomSignal(count: restorer.latencySamples, seed: 0x0E51_0002)
        let output = restorer.process(input)

        #expect(output.count == input.count)
        #expect(output.allSatisfy { $0 == 0 })
        #expect(restorer.finish().count == restorer.latencySamples)
    }
}

@Test
func everyLookAheadReturnsTheWholeStream() throws {
    let weights = try restorerWeights(exitLayer: testExitLayer, seed: testSeed)
    let signal = randomSignal(count: 8 * testHopLength, seed: 0x0E51_0003)

    var outputs: [[Float]] = []
    for lookAhead in 0...RealtimeModel.maximumLookAhead {
        let restorer = makeRestorer(weights, lookAhead: lookAhead)
        var output = restorer.process(signal)
        output.append(contentsOf: restorer.finish())

        #expect(output.count == signal.count + restorer.latencySamples)
        // The frames held back for the look-ahead are collected when the stream ends.
        #expect(output.suffix(testHopLength).contains { $0 != 0 })
        outputs.append(Array(output.dropFirst(restorer.latencySamples)))
    }

    // Each look-ahead has its own first layer, so the three streams are different estimates.
    #expect(outputs[0] != outputs[1])
    #expect(outputs[1] != outputs[2])
}

@Test
func chunkedPushesMatchOneWholePush() throws {
    let weights = try restorerWeights(exitLayer: testExitLayer, seed: testSeed)
    let restorer = makeRestorer(weights, lookAhead: 1)
    let signal = randomSignal(count: 16 * testHopLength, seed: 0x0E51_0004)

    var whole = restorer.process(signal)
    whole.append(contentsOf: restorer.finish())

    let streamed = push(
        signal,
        through: makeRestorer(weights, lookAhead: 1),
        chunks: [1, 3, 7, 8, 4]
    )

    #expect(streamed.count == signal.count + restorer.latencySamples)
    #expect(whole.contains { $0 != 0 })
    #expect(largestGap(streamed, whole) == 0)
}

@Test
func sweepArtifactRuleClearsFramesWithMostlyNonPositiveMagnitudes() {
    var mostlyNegative: [Float] = [-1, 2, -3, -4, 5]
    mostlyNegative.withUnsafeMutableBufferPointer {
        RealtimeRestorer.suppressSweepArtifact($0)
    }
    #expect(mostlyNegative == [0, 0, 0, 0, 0])

    var halfNegative: [Float] = [-1, 2, -3, 4]
    halfNegative.withUnsafeMutableBufferPointer {
        RealtimeRestorer.suppressSweepArtifact($0)
    }
    #expect(halfNegative == [-1, 2, -3, 4])

    var positive: [Float] = [1, 2, 3]
    positive.withUnsafeMutableBufferPointer {
        RealtimeRestorer.suppressSweepArtifact($0)
    }
    #expect(positive == [1, 2, 3])
}

@Test
func theBufferFormMatchesTheArrayFormHopByHop() throws {
    let weights = try restorerWeights(exitLayer: testExitLayer, seed: testSeed)
    let input = (0..<(testHopLength * 12)).map { Float(sin(Double($0) * 0.37)) * 0.5 }
    let arrayOutput = makeRestorer(weights, lookAhead: 1).process(input)

    let restorer = makeRestorer(weights, lookAhead: 1)
    var bufferOutput = [Float](repeating: .nan, count: input.count)
    input.withUnsafeBufferPointer { source in
        bufferOutput.withUnsafeMutableBufferPointer { destination in
            for start in stride(from: 0, to: input.count, by: testHopLength) {
                restorer.process(
                    UnsafeBufferPointer(rebasing: source[start..<(start + testHopLength)]),
                    into: UnsafeMutableBufferPointer(
                        rebasing: destination[start..<(start + testHopLength)]
                    )
                )
            }
        }
    }

    #expect(bufferOutput == arrayOutput)
}

@Test
func aResetRestorerStreamsExactlyLikeAFreshOne() throws {
    let weights = try restorerWeights(exitLayer: testExitLayer, seed: testSeed)
    let before = (0..<(testHopLength * 9)).map { Float(cos(Double($0) * 0.21)) * 0.4 }
    let after = (0..<(testHopLength * 10)).map { Float(sin(Double($0) * 0.53)) * 0.3 }

    let reused = makeRestorer(weights, lookAhead: 1)
    _ = reused.process(before)
    reused.reset()
    let afterReset = reused.process(after)

    #expect(afterReset == makeRestorer(weights, lookAhead: 1).process(after))
    #expect(afterReset.prefix(reused.latencySamples).allSatisfy { $0 == 0 })
}

extension FramePathThreads {
    /// The hop path includes the worker pool, so the count covers the calling thread and the
    /// pool's workers. The second rate is a tier's, where the layers are as large as in use.
    @Test(.enabled(if: measuresShippingBuild), arguments: [testSampleRate, 16_000])
    func aHopAllocatesNothingAfterTheFirstFrames(sampleRate: Int) throws {
        let weights = try restorerWeights(exitLayer: testExitLayer, seed: testSeed)
        let restorer = RealtimeRestorer(
            weights: weights,
            tier: Tier(sampleRate: sampleRate, exitLayer: testExitLayer, lookAhead: 1))
        let input = (0..<restorer.hopLength).map { Float(sin(Double($0) * 0.37)) * 0.5 }
        var output = [Float](repeating: 0, count: input.count)

        func hop() {
            input.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { restorer.process(source, into: $0) }
            }
        }

        // The first hops grow the pending buffers to a frame.
        for _ in 0..<10 {
            hop()
        }
        let allocations = AllocationProbe.allocations {
            for _ in 0..<50 {
                hop()
            }
        }
        #expect(allocations == 0)
    }
}

private func makeRestorer(
    _ weights: RealtimeRestorerWeights,
    lookAhead: Int
) -> RealtimeRestorer {
    RealtimeRestorer(weights: weights, tier: restorerTier(lookAhead: lookAhead))
}

private func restorerTier(lookAhead: Int) -> Tier {
    Tier(sampleRate: testSampleRate, exitLayer: testExitLayer, lookAhead: lookAhead)
}

private func restorerWeights(
    exitLayer: Int,
    seed: UInt64
) throws -> RealtimeRestorerWeights {
    precondition(
        exitLayer == testExitLayer && seed == testSeed,
        "these tests share one set of weights")
    return try sharedWeights.get()
}

/// Built once: drawing and loading a full-width checkpoint dominates a debug test run.
private let sharedWeights = Result {
    try load(restorerTensors(exitLayer: testExitLayer, seed: testSeed)) {
        try RealtimeRestorerWeights(map: &$0, exitLayer: testExitLayer)
    }
}

/// A checkpoint with a fixed positive magnitude readout, so a test frame can never trip the
/// silence rule while the rest of the model still varies frame by frame.
private func restorerTensors(exitLayer: Int, seed: UInt64) -> [ModelTensor] {
    let readout = "mask_decoder_list.\(exitLayer - 1).final_conv"
    return realtimeTensors(blockCount: exitLayer, seed: seed).map { tensor in
        switch tensor.name {
        case "\(readout).weight":
            return ModelTensor(
                name: tensor.name,
                shape: tensor.shape,
                values: [Float](repeating: 0, count: tensor.values.count)
            )
        case "\(readout).bias":
            return ModelTensor(name: tensor.name, shape: tensor.shape, values: [1])
        default:
            return tensor
        }
    }
}

private func randomSignal(count: Int, seed: UInt64) -> [Float] {
    var random = ModelRandom(seed: seed)
    return random.values(count: count, limit: 0.8)
}

private func push(
    _ signal: [Float],
    through restorer: RealtimeRestorer,
    chunks: [Int]
) -> [Float] {
    var output: [Float] = []
    var offset = 0
    var chunk = 0
    while offset < signal.count {
        let count = min(chunks[chunk % chunks.count], signal.count - offset)
        output.append(contentsOf: restorer.process(Array(signal[offset..<(offset + count)])))
        offset += count
        chunk += 1
    }
    output.append(contentsOf: restorer.finish())
    return output
}
