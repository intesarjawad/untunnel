import Testing

@testable import UntunnelEngine

private let scanPrefix = "TSMamba.0.time_mamba.forward_blocks"
private let sequenceLength = 9
private let width = RealtimeModel.width

@Test
func advancingOnePositionStepByStepMatchesSweepingTheSequence() throws {
    let weights = try scanWeights(seed: 0x5CA2_0001)
    let sequence = Scratch(copying: scanInput(seed: 0x5CA2_0002))

    let swept = Scratch(count: sequenceLength * width)
    SelectiveScan(weights: weights, positions: sequenceLength, keepsHistory: false)
        .sweep(input: sequence.pointer, output: swept.pointer, downwards: false)

    let stepped = Scratch(count: sequenceLength * width)
    let stepper = SelectiveScan(weights: weights, positions: 1, keepsHistory: true)
    withExtendedLifetime(sequence) {
        for index in 0..<sequenceLength {
            stepper.advance(
                input: sequence.pointer + index * width, output: stepped.pointer + index * width)
        }
    }

    #expect(swept.values.contains { $0 != 0 })
    #expect(largestGap(stepped.values, swept.values) < 1e-5)
}

@Test
func sweepingDownwardsIsSweepingTheReversedSequenceUpwards() throws {
    let weights = try scanWeights(seed: 0x5CA2_0003)
    let input = scanInput(seed: 0x5CA2_0004)
    let scan = SelectiveScan(weights: weights, positions: sequenceLength, keepsHistory: false)

    let forwards = Scratch(copying: input)
    let backwards = Scratch(copying: reversedRows(input))
    let down = Scratch(count: input.count)
    let up = Scratch(count: input.count)
    withExtendedLifetime((forwards, backwards)) {
        scan.sweep(input: forwards.pointer, output: down.pointer, downwards: true)
        scan.sweep(input: backwards.pointer, output: up.pointer, downwards: false)
    }

    #expect(largestGap(down.values, reversedRows(up.values)) < 1e-6)
}

@Test(arguments: [false, true])
func aSweepSharedInStagesIsTheSweepInOnePass(downwards: Bool) throws {
    let weights = try scanWeights(seed: 0x5CA2_0007)
    let input = Scratch(copying: scanInput(seed: 0x5CA2_0008))
    let whole = Scratch(count: sequenceLength * width)
    let staged = Scratch(count: sequenceLength * width)
    let scan = SelectiveScan(weights: weights, positions: sequenceLength, keepsHistory: false)
    withExtendedLifetime(input) {
        scan.sweep(input: input.pointer, output: whole.pointer, downwards: downwards)

        let halves = [0..<4, 4..<sequenceLength]
        scan.project(input.pointer)
        for range in halves.reversed() {
            scan.convolveSweep(range, downwards: downwards)
        }
        scan.mixSignals()
        for range in halves.reversed() {
            scan.prepareRecurrence(range)
        }
        for channels in [100..<RealtimeModel.innerWidth, 0..<100] {
            scan.sweepRecurrence(channels: channels, downwards: downwards)
        }
        scan.finish(staged.pointer)
    }

    #expect(whole.values.contains { $0 != 0 })
    #expect(staged.values == whole.values)
}

@Test
func aResetScanForgetsEarlierPositions() throws {
    let weights = try scanWeights(seed: 0x5CA2_0005)
    let input = Scratch(copying: scanInput(seed: 0x5CA2_0006))
    let scan = SelectiveScan(weights: weights, positions: 1, keepsHistory: true)
    let fresh = Scratch(count: width)
    let discarded = Scratch(count: width)
    let afterReset = Scratch(count: width)
    withExtendedLifetime((input, discarded)) {
        scan.advance(input: input.pointer, output: fresh.pointer)
        for index in 1..<sequenceLength {
            scan.advance(input: input.pointer + index * width, output: discarded.pointer)
        }
        scan.reset()
        scan.advance(input: input.pointer, output: afterReset.pointer)
    }

    #expect(afterReset.values == fresh.values)
}

private func scanWeights(seed: UInt64) throws -> SelectiveScanWeights {
    let tensors = realtimeTensors(blockCount: 1, seed: seed).filter {
        $0.name.hasPrefix(scanPrefix)
    }
    return try load(tensors) { try SelectiveScanWeights(map: &$0, prefix: scanPrefix) }
}

private func scanInput(seed: UInt64) -> [Float] {
    var random = ModelRandom(seed: seed)
    return random.values(count: sequenceLength * width, limit: 1)
}

private func reversedRows(_ values: [Float]) -> [Float] {
    stride(from: sequenceLength - 1, through: 0, by: -1).flatMap {
        values[($0 * width)..<(($0 + 1) * width)]
    }
}
