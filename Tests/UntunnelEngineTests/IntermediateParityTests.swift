import Foundation
import Testing

@testable import UntunnelEngine

/// The most a module's output may differ from the reference implementation's at any value.
private let moduleTolerance: Float = 1e-4

/// Drives each module of the real-time model with the input the reference implementation fed
/// its own module, frame by frame from the start of a stream, and compares the outputs.
///
/// Feeding reference inputs rather than the previous module's output keeps a fault where it
/// is: a wrong block fails alone instead of failing everything after it.
@Suite(.enabled(if: RealtimeReference.isAvailable, RealtimeReference.unavailableReason))
struct IntermediateParity {
    private let reference: ModelReference<RealtimeReference.Manifest>
    private let weights: RealtimeRestorerWeights
    private let frames: Int
    private let binCount: Int
    private let modelBins: Int

    init() throws {
        reference = try RealtimeReference.shared.get()
        let stream = reference.manifest.intermediates
        weights = try reference.weights(exitLayer: stream.exitLayer)
        frames = stream.frames
        binCount = try reference.array("intermediates.input.magnitude").shape[1]
        modelBins = RealtimeModel.modelBins(binCount: binCount)
    }

    @Test
    func theLayoutNamesEveryTensorOfThePublishedCheckpoint() {
        let published = reference.checkpoint.tensors.mapValues(\.shape)
        let layout = RealtimeModelLayout.tensors(blockCount: 12)

        #expect(layout.count == published.count)
        for tensor in layout {
            #expect(published[tensor.name] == tensor.shape, "tensor '\(tensor.name)'")
        }
    }

    @Test
    func theModelWorksAtHalfTheBinsPlusOne() {
        #expect(binCount == 161)
        #expect(modelBins == 81)
        #expect(RealtimeModel.modelBins(binCount: 321) == 161)
        #expect(RealtimeModel.modelBins(binCount: 961) == 481)
    }

    @Test
    func theEncoderMatches() throws {
        let magnitudes = Scratch(
            copying: try reference.array("intermediates.input.magnitude").values)
        let phases = Scratch(copying: try reference.array("intermediates.input.phase").values)
        let expected = try reference.array("intermediates.encoder").values
        let encoder = RealtimeEncoder(
            weights: weights.encoder,
            binCount: binCount,
            lookAhead: reference.manifest.intermediates.lookAhead
        )

        let produced = Scratch(count: frames * rowCount)
        withExtendedLifetime((magnitudes, phases)) {
            for frame in 0..<frames {
                let wrote = encoder.process(
                    magnitudes: magnitudes.pointer + frame * binCount,
                    phases: phases.pointer + frame * binCount,
                    output: produced.pointer + frame * rowCount
                )
                #expect(wrote)
            }
        }

        #expect(largestGap(produced.values, expected) < moduleTolerance)
    }

    @Test(arguments: 0..<12)
    func aBlockMatches(index: Int) throws {
        let input = Scratch(
            copying: try reference.array(
                index == 0 ? "intermediates.encoder" : "intermediates.block\(index - 1)"
            ).values)
        let expected = try reference.array("intermediates.block\(index)").values
        let block = RealtimeBlock(weights: weights.blocks[index], bins: modelBins)

        let produced = Scratch(count: frames * rowCount)
        withExtendedLifetime(input) {
            for frame in 0..<frames {
                block.process(
                    input: input.pointer + frame * rowCount,
                    output: produced.pointer + frame * rowCount
                )
            }
        }

        #expect(largestGap(produced.values, expected) < moduleTolerance)
    }

    @Test
    func theMagnitudeDecoderMatches() throws {
        let expected = try reference.array("intermediates.magnitude").values
        let produced = try decode(weights.magnitude, readouts: 1)

        #expect(largestGap(produced[0], expected) < moduleTolerance)
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

    /// Runs a decoder over the last block's reference output and returns each readout's
    /// columns for every frame.
    private func decode(_ weights: RealtimeDecoderWeights, readouts: Int) throws -> [[Float]] {
        let last = reference.manifest.intermediates.exitLayer - 1
        let input = Scratch(copying: try reference.array("intermediates.block\(last)").values)
        let decoder = RealtimeDecoder(weights: weights, bins: modelBins)
        let columns = (0..<readouts).map { _ in Scratch(count: decoder.outputBins) }

        var produced = [[Float]](repeating: [], count: readouts)
        withExtendedLifetime(input) {
            for frame in 0..<frames {
                decoder.process(
                    input: input.pointer + frame * rowCount, columns: columns.map(\.pointer))
                for readout in 0..<readouts {
                    produced[readout] += columns[readout].values
                }
            }
        }
        return produced
    }

    private var rowCount: Int {
        modelBins * RealtimeModel.width
    }
}

extension Scratch {
    /// A copy of the buffer. Reading it also keeps the buffer alive up to this point, which a
    /// test that only passed `pointer` around would not.
    var values: [Float] {
        Array(UnsafeBufferPointer(start: pointer, count: count))
    }
}
