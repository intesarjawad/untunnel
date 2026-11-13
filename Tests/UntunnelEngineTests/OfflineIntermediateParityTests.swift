import Foundation
import Testing

@testable import UntunnelEngine

/// The most a module's output may differ from the reference implementation's at any value.
private let moduleTolerance: Float = 1e-4

/// Drives each module of the offline model with the input the reference implementation fed
/// its own module and compares the outputs, so a wrong block fails alone.
@Suite(.enabled(if: OfflineReference.isAvailable, OfflineReference.unavailableReason))
struct OfflineIntermediateParity {
    private let reference: ModelReference<OfflineReference.Manifest>
    private let weights: OfflineRestorerWeights
    private let frames: Int
    private let binCount: Int
    private let modelFrames: Int
    private let modelBins: Int

    init() throws {
        reference = try OfflineReference.shared.get()
        weights = try reference.weights()
        let input = try reference.array("intermediates.input.magnitude").shape
        frames = input[0]
        binCount = input[1]
        modelFrames = OfflineModel.modelFrames(frames: frames)
        modelBins = OfflineModel.modelBins(binCount: binCount)
    }

    @Test
    func theLayoutNamesEveryTensorOfThePublishedCheckpoint() {
        let published = reference.checkpoint.tensors.mapValues(\.shape)
        let layout = OfflineModelLayout.tensors(blockCount: OfflineModel.blockCount)

        #expect(layout.count == published.count)
        for tensor in layout {
            #expect(published[tensor.name] == tensor.shape, "tensor '\(tensor.name)'")
        }
    }

    @Test
    func theTransformScalesWithTheRate() {
        #expect(reference.manifest.intermediates.sampleRate == 8_000)
        #expect(binCount == OfflineModel.windowLength(sampleRate: 8_000) / 2 + 1)
        #expect(OfflineModel.windowLength(sampleRate: 8_000) == 320)
        #expect(OfflineModel.hopLength(sampleRate: 8_000) == 40)
        #expect(OfflineModel.windowLength(sampleRate: 48_000) == 1_920)
        #expect(OfflineModel.hopLength(sampleRate: 48_000) == 240)
    }

    @Test
    func theEncoderMatches() throws {
        let magnitudes = Scratch(
            copying: try reference.array("intermediates.input.magnitude").values)
        let phases = Scratch(copying: try reference.array("intermediates.input.phase").values)
        let expected = try reference.array("intermediates.encoder")
        #expect(expected.shape == [modelFrames, modelBins, RealtimeModel.width])

        let produced = Scratch(count: mapCount)
        withExtendedLifetime((magnitudes, phases)) {
            OfflineEncoder(weights: weights.encoder).process(
                magnitudes: magnitudes.pointer, phases: phases.pointer, frames: frames,
                binCount: binCount, output: produced.pointer)
        }

        #expect(largestGap(produced.values, expected.values) < moduleTolerance)
    }

    /// Each tapped block whose input was tapped too: the first block reads the encoder.
    @Test(arguments: [0, 1, 15, 29])
    func aBlockMatches(index: Int) throws {
        let map = Scratch(
            copying: try reference.array(
                index == 0 ? "intermediates.encoder" : "intermediates.block\(index - 1)"
            ).values)
        let expected = try reference.array("intermediates.block\(index)").values
        let block = OfflineBlock(
            weights: weights.blocks[index], frames: modelFrames, bins: modelBins,
            timeWorkspace: ScanWorkspace(positions: modelFrames),
            frequencyWorkspace: ScanWorkspace(positions: modelBins))

        block.process(map.pointer)

        #expect(largestGap(map.values, expected) < moduleTolerance)
    }

    @Test
    func theMagnitudeDecoderMatches() throws {
        let expected = try reference.array("intermediates.magnitude")
        #expect(
            expected.shape == [
                OfflineModel.timeStride * modelFrames, OfflineModel.frequencyStride * modelBins,
            ])
        let produced = try decode(weights.magnitude, readouts: 1)

        #expect(largestGap(produced[0], expected.values) < moduleTolerance)
    }

    @Test
    func thePhaseDecoderMatches() throws {
        let expected = try reference.array("intermediates.phase").values
        let produced = try decode(weights.phase, readouts: 2)
        let phases = zip(produced[1], produced[0]).map { atan2($0, $1) }

        // A phase next to the branch cut may land on either side of it.
        let gap = zip(phases, expected).map { produced, expected -> Float in
            let difference = abs(produced - expected)
            return min(difference, 2 * .pi - difference)
        }
        #expect(gap.max() ?? .infinity < moduleTolerance)
    }

    /// Runs a decoder over the last block's reference output and returns each readout's map.
    private func decode(_ weights: OfflineDecoderWeights, readouts: Int) throws -> [[Float]] {
        let last = OfflineModel.blockCount - 1
        let input = Scratch(copying: try reference.array("intermediates.block\(last)").values)
        let decodedCount =
            OfflineModel.timeStride * modelFrames * OfflineModel.frequencyStride * modelBins
        let maps = (0..<readouts).map { _ in Scratch(count: decodedCount) }
        withExtendedLifetime(input) {
            OfflineDecoder(weights: weights).process(
                input: input.pointer, frames: modelFrames, bins: modelBins,
                maps: maps.map(\.pointer))
        }
        return maps.map(\.values)
    }

    private var mapCount: Int {
        modelFrames * modelBins * RealtimeModel.width
    }
}
