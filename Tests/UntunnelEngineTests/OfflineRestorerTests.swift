import Accelerate
import Foundation
import Testing

@testable import UntunnelEngine

/// A rate whose frame, 64 samples, keeps a model run on a random checkpoint fast.
private let testSampleRate = 1_600
private let testBlocks = 2
private let testSeed: UInt64 = 0x0FF1_0001

@Test
func theTransformScalesFromFortyMillisecondFramesEveryFiveMilliseconds() {
    #expect(OfflineModel.hopMilliseconds == 5)
    #expect(OfflineModel.windowLength(sampleRate: 8_000) == 320)
    #expect(OfflineModel.hopLength(sampleRate: 8_000) == 40)
    #expect(OfflineModel.windowLength(sampleRate: 16_000) == 640)
    #expect(OfflineModel.hopLength(sampleRate: 48_000) == 240)
    #expect(OfflineModel.windowLength(sampleRate: testSampleRate) == 64)
    #expect(OfflineModel.hopLength(sampleRate: testSampleRate) == 8)
}

@Test
func theBlocksSeeAQuarterOfTheFramesAndHalfTheBins() {
    // Two zero frames are appended, and the encoder steps four frames without padding.
    #expect(OfflineModel.modelFrames(frames: 21) == 6)
    #expect(OfflineModel.modelFrames(frames: 2) == 1)
    #expect(OfflineModel.modelFrames(frames: 3) == 2)
    #expect(OfflineModel.modelBins(binCount: 161) == 81)
}

@Test
func instanceNormalisationUsesEachChannelsStatisticsOverEveryRow() {
    let width = RealtimeModel.width
    let rows = 3
    var values = (0..<(rows * width)).map { Float($0 % width) * Float($0 / width + 1) }
    let scale = [Float](repeating: 2, count: width)
    let shift = [Float](repeating: 0.5, count: width)

    let expected = (0..<(rows * width)).map { index -> Float in
        let channel = index % width
        let column = (0..<rows).map { Float(channel) * Float($0 + 1) }
        let mean = column.reduce(0, +) / Float(rows)
        let variance = column.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(rows)
        return (values[index] - mean) / (variance + RealtimeModel.normEpsilon).squareRoot() * 2
            + 0.5
    }
    values.withUnsafeMutableBufferPointer { buffer in
        normalizeInstance(buffer.baseAddress!, rows: rows, scale: scale, shift: shift)
    }

    #expect(largestGap(values, expected) < 1e-4)
}

@Test
func overlapAddInvertsTheCentredTransform() throws {
    let restorer = try makeRestorer(chunkSamples: 400, overlapSamples: 0)
    var random = ModelRandom(seed: 0x0FF1_0003)
    let signal = random.values(count: 320, limit: 0.5)

    let (magnitudes, phases) = restorer.analyze(signal)
    let synthesis = OverlapAddSynthesis(
        windowLength: restorer.windowLength, hopLength: restorer.hopLength)
    let restored = synthesis.synthesize(
        magnitudes: magnitudes, phases: phases, frames: magnitudes.count / restorer.binCount)

    #expect(restored.count == signal.count)
    #expect(largestGap(restored, signal) < 1e-4)
}

@Test
func restoredSignalKeepsItsLength() throws {
    let restorer = try makeRestorer(chunkSamples: 400, overlapSamples: 80)

    for count in [1, 7, 33, 64, 399, 400, 401, 1_000] {
        let signal = randomSignal(count: count, seed: testSeed &+ UInt64(count))
        #expect(restorer.restore(signal).count == count)
    }
    #expect(restorer.restore([]).isEmpty)
}

@Test
func restorerIsDeterministicAcrossCalls() throws {
    let restorer = try makeRestorer(chunkSamples: 400, overlapSamples: 80)
    let signal = randomSignal(count: 900, seed: 0x0FF1_0002)

    let first = restorer.restore(signal)

    #expect(first.contains { $0 != 0 })
    #expect(restorer.restore(signal) == first)
}

@Test
func offlineValidationRejectsATensorTheModelNeverReads() throws {
    let tensors =
        offlineTensors(blockCount: testBlocks, seed: testSeed)
        + [ModelTensor(name: "extra.weight", shape: [1], values: [0])]
    let checkpoint = try SafeTensors(data: modelCheckpoint(tensors))

    #expect(throws: WeightMapError.unconsumed(names: ["extra.weight"])) {
        try WeightMap.validateOfflineModel(checkpoint, blockCount: testBlocks)
    }
}

@Test
func offlineValidationRejectsARealtimeCheckpoint() throws {
    let checkpoint = try SafeTensors(
        data: modelCheckpoint(realtimeTensors(blockCount: testBlocks, seed: testSeed)))

    #expect(throws: WeightMapError.self) {
        try WeightMap.validateOfflineModel(checkpoint, blockCount: testBlocks)
    }
}

@Test
func offlineValidationAcceptsItsOwnLayout() throws {
    let checkpoint = try SafeTensors(
        data: modelCheckpoint(offlineTensors(blockCount: testBlocks, seed: testSeed)))

    try WeightMap.validateOfflineModel(checkpoint, blockCount: testBlocks)
}

private func makeRestorer(chunkSamples: Int, overlapSamples: Int) throws -> OfflineRestorer {
    // Small random weights leave about half of each frame's magnitudes negative, which the
    // restorer clears as an empty frame; a positive readout bias keeps the frames audible.
    let tensors = offlineTensors(blockCount: testBlocks, seed: testSeed).map { tensor in
        tensor.name == "mask_decoder.final_conv.bias"
            ? ModelTensor(name: tensor.name, shape: tensor.shape, values: [1]) : tensor
    }
    let weights = try load(tensors) {
        try OfflineRestorerWeights(map: &$0, blockCount: testBlocks)
    }
    let plan = try #require(
        ChunkPlan(chunkSamples: chunkSamples, overlapSamples: overlapSamples)
    )
    return OfflineRestorer(weights: weights, sampleRate: testSampleRate, plan: plan)
}

private func randomSignal(count: Int, seed: UInt64) -> [Float] {
    var random = ModelRandom(seed: seed)
    return random.values(count: count, limit: 0.8)
}
