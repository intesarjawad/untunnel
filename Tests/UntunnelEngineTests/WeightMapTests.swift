import Foundation
import Testing
import UntunnelEngine

@Test
func readingATensorTwiceThrows() throws {
    var map = WeightMap(
        try SafeTensors(
            data: modelCheckpoint([ModelTensor(name: "a", shape: [2], values: [1, 2])])
        )
    )
    _ = try map.take("a", shape: [2])

    let error = #expect(throws: WeightMapError.self) {
        _ = try map.take("a", shape: [2])
    }
    #expect(error == .repeatedRead(name: "a"))
}

@Test
func missingTensorThrows() throws {
    var map = WeightMap(
        try SafeTensors(
            data: modelCheckpoint([ModelTensor(name: "a", shape: [2], values: [1, 2])])
        )
    )

    let error = #expect(throws: WeightMapError.self) {
        _ = try map.take("b", shape: [2])
    }
    #expect(error == .missingTensor(name: "b"))
    #expect(error?.description.contains("'b'") == true)
}

@Test
func shapeMismatchThrows() throws {
    var map = WeightMap(
        try SafeTensors(
            data: modelCheckpoint([ModelTensor(name: "a", shape: [2], values: [1, 2])])
        )
    )

    let error = #expect(throws: WeightMapError.self) {
        _ = try map.take("a", shape: [1, 2])
    }
    #expect(error == .shapeMismatch(name: "a", expected: [1, 2], actual: [2]))
}

@Test
func leftoverTensorThrows() throws {
    var map = WeightMap(
        try SafeTensors(
            data: modelCheckpoint([
                ModelTensor(name: "a", shape: [2], values: [1, 2]),
                ModelTensor(name: "b", shape: [1], values: [3]),
            ])
        )
    )
    _ = try map.take("a", shape: [2])

    let error = #expect(throws: WeightMapError.self) {
        try map.finish()
    }
    #expect(error == .unconsumed(names: ["b"]))
}

@Test
func valuesKeepTheCheckpointsOrderAndSign() throws {
    var map = WeightMap(
        try SafeTensors(
            data: modelCheckpoint([
                ModelTensor(name: "a", shape: [3], values: [1, -2.5, 3.25])
            ])
        )
    )

    #expect(try map.take("a", shape: [3]) == [1, -2.5, 3.25])
}

@Test
func realtimeModelLoadsAtTheDeepestExitItCarries() throws {
    let checkpoint = try SafeTensors(data: modelCheckpoint(realtimeTensors(blocks: 2)))

    try WeightMap.validateRealtimeModel(checkpoint)
}

@Test
func realtimeModelLoadsAtAShallowerExitAndConsumesTheDeeperOnes() throws {
    let checkpoint = try SafeTensors(data: modelCheckpoint(realtimeTensors(blocks: 2)))

    try WeightMap.validateRealtimeModel(checkpoint, exitLayer: 1)
}

@Test
func realtimeModelRejectsAChangedShapeNamingTheTensor() throws {
    let tensors = realtimeTensors(blocks: 2).map { tensor -> ModelTensor in
        guard tensor.name == "TSMamba.1.time_mamba.output_proj.weight" else {
            return tensor
        }
        return ModelTensor(
            name: tensor.name, shape: [64, 63], values: Array(repeating: 0, count: 64 * 63))
    }
    let checkpoint = try SafeTensors(data: modelCheckpoint(tensors))

    let error = #expect(throws: WeightMapError.self) {
        try WeightMap.validateRealtimeModel(checkpoint)
    }

    #expect(
        error
            == .shapeMismatch(
                name: "TSMamba.1.time_mamba.output_proj.weight",
                expected: [64, 64],
                actual: [64, 63]
            )
    )
    #expect(error?.description.contains("'TSMamba.1.time_mamba.output_proj.weight'") == true)
}

@Test
func realtimeModelRejectsAMissingTensor() throws {
    let tensors = realtimeTensors(blocks: 2).filter {
        $0.name != "phase_decoder_list.1.phase_conv_i.bias"
    }
    let checkpoint = try SafeTensors(data: modelCheckpoint(tensors))

    let error = #expect(throws: WeightMapError.self) {
        try WeightMap.validateRealtimeModel(checkpoint)
    }

    #expect(error == .missingTensor(name: "phase_decoder_list.1.phase_conv_i.bias"))
}

@Test
func realtimeModelRejectsATensorNobodyReads() throws {
    let tensors =
        realtimeTensors(blocks: 2) + [ModelTensor(name: "extra", shape: [1], values: [0])]
    let checkpoint = try SafeTensors(data: modelCheckpoint(tensors))

    let error = #expect(throws: WeightMapError.self) {
        try WeightMap.validateRealtimeModel(checkpoint)
    }

    #expect(error == .unconsumed(names: ["extra"]))
}

@Test
func realtimeModelRejectsACheckpointWithNoBlocks() throws {
    let checkpoint = try SafeTensors(
        data: modelCheckpoint([ModelTensor(name: "a", shape: [1], values: [0])])
    )

    let error = #expect(throws: WeightMapError.self) {
        try WeightMap.validateRealtimeModel(checkpoint)
    }

    #expect(error == .missingTensor(name: "dense_encoder.dense_conv_1_1.0.weight"))
}

/// A checkpoint with `blocks` time-frequency blocks and one decoder pair per exit depth.
private func realtimeTensors(blocks: Int) -> [ModelTensor] {
    realtimeTensors(blockCount: blocks, seed: 0xACE0_0002)
}
