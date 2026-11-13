import Accelerate

/// Restores a whole mono signal with the offline model.
///
/// The model analyses 40 ms frames every 5 ms: 320 and 40 samples at 8 kHz. Its normalisations
/// take their statistics from everything they are given and its blocks read time in both
/// directions, so a chunk is restored as one piece. A signal longer than one chunk is cut by
/// the `ChunkPlan`, restored chunk by chunk and crossfaded where neighbouring chunks overlap.
///
/// The output has as many samples as the input, at the same rate and without delay.
public final class OfflineRestorer {
    /// The rate the model runs at, in hertz.
    public let sampleRate: Int
    /// The frame length in samples.
    public let windowLength: Int
    /// The samples between two frame starts.
    public let hopLength: Int
    /// The frequency bins per analysed frame.
    public let binCount: Int
    /// How a signal is cut into chunks.
    public let plan: ChunkPlan

    private let weights: OfflineRestorerWeights
    private let encoder: OfflineEncoder
    private let magnitudeDecoder: OfflineDecoder
    private let phaseDecoder: OfflineDecoder
    private let synthesis: OverlapAddSynthesis

    /// Creates a restorer for `sampleRate`, which must give a frame the system's DFT supports.
    public init(weights: OfflineRestorerWeights, sampleRate: Int, plan: ChunkPlan) {
        self.sampleRate = sampleRate
        windowLength = OfflineModel.windowLength(sampleRate: sampleRate)
        hopLength = OfflineModel.hopLength(sampleRate: sampleRate)
        binCount = windowLength / 2 + 1
        self.plan = plan
        self.weights = weights
        encoder = OfflineEncoder(weights: weights.encoder)
        magnitudeDecoder = OfflineDecoder(weights: weights.magnitude)
        phaseDecoder = OfflineDecoder(weights: weights.phase)
        synthesis = OverlapAddSynthesis(windowLength: windowLength, hopLength: hopLength)
    }

    /// Restores `samples` and returns as many samples back.
    public func restore(_ samples: [Float]) -> [Float] {
        ChunkedInference.run(samples, plan: plan, process: restoreChunk)
    }

    /// Restores one chunk of at most `plan.chunkSamples` samples as a single sequence.
    ///
    /// Reflection padding needs more samples than half a frame, so a shorter chunk is padded
    /// with silence first. The output is cut or padded with silence to the chunk's length; the
    /// transform covers whole hops only, so a chunk that is not a whole number of hops ends in
    /// silence, as the publisher's inference does.
    func restoreChunk(_ samples: [Float]) -> [Float] {
        precondition(
            samples.count <= plan.chunkSamples,
            "a chunk holds at most \(plan.chunkSamples) samples"
        )
        let shortest = windowLength / 2 + 1
        let signal = samples + [Float](repeating: 0, count: max(0, shortest - samples.count))
        let (magnitudes, phases) = analyze(signal)
        let restored = restore(magnitudes: magnitudes, phases: phases)
        return Array(restored.prefix(samples.count))
            + [Float](repeating: 0, count: max(0, samples.count - restored.count))
    }

    /// Restores analysed frames, `binCount` `log1p` magnitudes and phases per frame, into the
    /// `hopLength * (frames - 1)` samples between the first and the last frame's centre.
    func restore(magnitudes: [Float], phases: [Float]) -> [Float] {
        precondition(
            magnitudes.count == phases.count && magnitudes.count.isMultiple(of: binCount),
            "the frames need one magnitude and one phase per bin"
        )
        let frames = magnitudes.count / binCount
        var restoredMagnitudes = [Float](repeating: 0, count: magnitudes.count)
        var restoredPhases = [Float](repeating: 0, count: phases.count)
        magnitudes.withUnsafeBufferPointer { magnitudes in
            phases.withUnsafeBufferPointer { phases in
                restoredMagnitudes.withUnsafeMutableBufferPointer { restoredMagnitudes in
                    restoredPhases.withUnsafeMutableBufferPointer { restoredPhases in
                        run(
                            magnitudes: magnitudes, phases: phases, frames: frames,
                            restoredMagnitudes: restoredMagnitudes, restoredPhases: restoredPhases)
                    }
                }
            }
        }
        return synthesis.synthesize(
            magnitudes: restoredMagnitudes, phases: restoredPhases, frames: frames)
    }

    /// The centred transform of `signal`, one frame per hop and one more, as the publisher
    /// analyses a file.
    func analyze(_ signal: [Float]) -> (magnitudes: [Float], phases: [Float]) {
        let stft = StreamingSTFT(
            sampleRate: sampleRate, windowLength: windowLength, hopLength: hopLength,
            float32Window: true)
        let frames = signal.count / hopLength + 1
        var magnitudes = [Float](repeating: 0, count: frames * binCount)
        var phases = [Float](repeating: 0, count: frames * binCount)
        var written = 0
        signal.withUnsafeBufferPointer { input in
            magnitudes.withUnsafeMutableBufferPointer { columns in
                phases.withUnsafeMutableBufferPointer { angles in
                    written = stft.process(input, magnitudes: columns, phases: angles)
                    written += stft.finish(
                        magnitudes: UnsafeMutableBufferPointer(
                            rebasing: columns[(written * binCount)...]),
                        phases: UnsafeMutableBufferPointer(
                            rebasing: angles[(written * binCount)...])
                    )
                }
            }
        }
        precondition(written == frames, "the transform made \(written) of \(frames) frames")
        return (magnitudes, phases)
    }

    /// Runs the model on `frames` frames and writes its magnitudes and phases, cut back to the
    /// spectrum's frames and bins, with every mostly empty frame cleared.
    private func run(
        magnitudes: UnsafeBufferPointer<Float>,
        phases: UnsafeBufferPointer<Float>,
        frames: Int,
        restoredMagnitudes: UnsafeMutableBufferPointer<Float>,
        restoredPhases: UnsafeMutableBufferPointer<Float>
    ) {
        guard let magnitudes = magnitudes.baseAddress, let phases = phases.baseAddress else {
            return
        }
        let modelFrames = OfflineModel.modelFrames(frames: frames)
        let modelBins = OfflineModel.modelBins(binCount: binCount)
        let features = Scratch(count: modelFrames * modelBins * RealtimeModel.width)
        encoder.process(
            magnitudes: magnitudes, phases: phases, frames: frames, binCount: binCount,
            output: features.pointer)

        let timeWorkspace = ScanWorkspace(positions: modelFrames)
        let frequencyWorkspace = ScanWorkspace(positions: modelBins)
        for weights in weights.blocks {
            OfflineBlock(
                weights: weights, frames: modelFrames, bins: modelBins,
                timeWorkspace: timeWorkspace, frequencyWorkspace: frequencyWorkspace
            ).process(features.pointer)
        }

        let decodedFrames = OfflineModel.timeStride * modelFrames
        let decodedBins = OfflineModel.frequencyStride * modelBins
        let decodedCount = decodedFrames * decodedBins
        let magnitudeMap = Scratch(count: decodedCount)
        let real = Scratch(count: decodedCount)
        let imaginary = Scratch(count: decodedCount)
        magnitudeDecoder.process(
            input: features.pointer, frames: modelFrames, bins: modelBins,
            maps: [magnitudeMap.pointer])
        phaseDecoder.process(
            input: features.pointer, frames: modelFrames, bins: modelBins,
            maps: [real.pointer, imaginary.pointer])
        var count = Int32(decodedCount)
        vvatan2f(imaginary.pointer, imaginary.pointer, real.pointer, &count)

        for frame in 0..<frames {
            let target = frame * binCount
            let source = frame * decodedBins
            for bin in 0..<binCount {
                restoredMagnitudes[target + bin] = magnitudeMap.pointer[source + bin]
                restoredPhases[target + bin] = imaginary.pointer[source + bin]
            }
            RealtimeRestorer.suppressSweepArtifact(
                UnsafeMutableBufferPointer(
                    rebasing: restoredMagnitudes[target..<(target + binCount)]))
        }
    }
}

/// The inverse of a centred transform over a whole signal, as `torch.istft` computes it.
///
/// Each frame's inverse DFT is windowed and added at its hop, the sum is divided by the summed
/// squared window, and half a frame is cut from each end, which leaves the samples between the
/// first and the last frame's centre.
final class OverlapAddSynthesis {
    let windowLength: Int
    let hopLength: Int

    private let setup: vDSP_DFT_Setup
    private let window: [Float]

    init(windowLength: Int, hopLength: Int) {
        precondition(
            windowLength.isMultiple(of: 2) && hopLength > 0 && hopLength <= windowLength / 2,
            "a frame must be even and at least two hops long")
        guard let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(windowLength), .INVERSE)
        else {
            preconditionFailure("vDSP has no inverse DFT for a \(windowLength)-sample frame")
        }
        self.windowLength = windowLength
        self.hopLength = hopLength
        self.setup = setup
        window = (0..<windowLength).map { index in
            Float(0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(windowLength)))
        }
    }

    deinit {
        vDSP_DFT_DestroySetup(setup)
    }

    /// `frames` frames of `log1p` magnitudes and phases, `windowLength / 2 + 1` per frame.
    func synthesize(magnitudes: [Float], phases: [Float], frames: Int) -> [Float] {
        let half = windowLength / 2
        let bins = half + 1
        var sum = [Float](repeating: 0, count: windowLength + hopLength * (frames - 1))
        var envelope = sum
        var spectrumReal = [Float](repeating: 0, count: half)
        var spectrumImaginary = [Float](repeating: 0, count: half)
        var timeReal = [Float](repeating: 0, count: half)
        var timeImaginary = [Float](repeating: 0, count: half)
        // The inverse real DFT sums the spectrum without the 1/N of an inverse FFT.
        let scale = 1 / Float(windowLength)

        for frame in 0..<frames {
            let column = frame * bins
            func amplitude(_ bin: Int) -> Float {
                expm1f(max(magnitudes[column + bin], 0))
            }
            // The packed format carries the real Nyquist value in the first imaginary slot.
            spectrumReal[0] = amplitude(0) * cos(phases[column])
            spectrumImaginary[0] = amplitude(half) * cos(phases[column + half])
            for bin in 1..<half {
                spectrumReal[bin] = amplitude(bin) * cos(phases[column + bin])
                spectrumImaginary[bin] = amplitude(bin) * sin(phases[column + bin])
            }
            vDSP_DFT_Execute(setup, spectrumReal, spectrumImaginary, &timeReal, &timeImaginary)

            let start = frame * hopLength
            for index in 0..<half {
                let even = 2 * index
                sum[start + even] += timeReal[index] * scale * window[even]
                sum[start + even + 1] += timeImaginary[index] * scale * window[even + 1]
                envelope[start + even] += window[even] * window[even]
                envelope[start + even + 1] += window[even + 1] * window[even + 1]
            }
        }
        return (0..<(hopLength * (frames - 1))).map { index in
            let denominator = envelope[half + index]
            return denominator > 0 ? sum[half + index] / denominator : 0
        }
    }
}
