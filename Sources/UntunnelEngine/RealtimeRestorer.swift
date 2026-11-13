import Accelerate

/// Enhances a mono stream one hop at a time with the spectral model.
///
/// The path is the published real-time model's: a centred `StreamingSTFT`, the encoder,
/// `exitLayer` time-frequency blocks, the magnitude and phase decoders trained for that depth
/// and a `StreamingISTFT`. Every frame is run on its own, and each layer keeps its state across
/// hops, so the stream matches a whole-signal pass.
///
/// The output keeps the input's indexing: sample `k` is the restored input sample `k - latency`,
/// and the first `latency` samples are silence while the transform and the look-ahead fill.
public final class RealtimeRestorer {
    /// The tier rate in hertz.
    public let sampleRate: Int
    /// The frame length in samples.
    public let windowLength: Int
    /// The samples between two frame starts.
    public let hopLength: Int
    /// The frequency bins per analysed frame.
    public let binCount: Int
    /// The bins per frame the encoder and both decoders work at.
    public let modelBins: Int
    /// The future frames the model waits for, capped at the most it was trained with.
    public let lookAhead: Int
    /// The silence at the start of the stream, in samples.
    public let latencySamples: Int

    private let stft: StreamingSTFT
    private let istft: StreamingISTFT
    private let encoder: RealtimeEncoder
    private let blocks: [RealtimeBlock]
    private let magnitudeDecoder: RealtimeDecoder
    private let phaseDecoder: RealtimeDecoder
    private let pool = WorkerPool.shared

    private let features: Scratch
    /// The magnitude column, then the real and imaginary columns the phase is taken from.
    private let decoded: Scratch
    private let magnitudeColumns: [UnsafeMutablePointer<Float>]
    private let phaseColumns: [UnsafeMutablePointer<Float>]
    private let phaseFrame: UnsafeMutablePointer<Float>
    private let silentFrame: Scratch
    private let stftMagnitudes: UnsafeMutablePointer<Float>
    private let stftPhases: UnsafeMutablePointer<Float>
    private let istftSamples: UnsafeMutablePointer<Float>

    /// Restored samples produced but not yet released, starting at `pendingStart`.
    private var pending: [Float] = []
    private var pendingStart = 0
    /// Input samples that do not yet fill a hop.
    private var partial: [Float] = []
    private var leadingZeros: Int
    private var finished = false

    /// Creates a stream for `tier` from the weights of its exit depth.
    public init(weights: RealtimeRestorerWeights, tier: Tier) {
        let stft = StreamingSTFT(tier: tier, float32Window: true)
        let istft = StreamingISTFT(tier: tier)
        let lookAhead = min(max(tier.lookAhead, 0), RealtimeModel.maximumLookAhead)
        let encoder = RealtimeEncoder(
            weights: weights.encoder,
            binCount: stft.binCount,
            lookAhead: lookAhead
        )
        let modelBins = encoder.modelBins

        sampleRate = stft.sampleRate
        windowLength = stft.windowLength
        hopLength = stft.hopLength
        binCount = stft.binCount
        self.modelBins = modelBins
        self.lookAhead = lookAhead
        latencySamples = stft.windowLength + lookAhead * stft.hopLength
        self.stft = stft
        self.istft = istft
        self.encoder = encoder
        let workspace = BlockWorkspace(bins: modelBins)
        blocks = weights.blocks.map {
            RealtimeBlock(weights: $0, bins: modelBins, workspace: workspace)
        }
        magnitudeDecoder = RealtimeDecoder(weights: weights.magnitude, bins: modelBins)
        phaseDecoder = RealtimeDecoder(weights: weights.phase, bins: modelBins)

        // The decoders write one bin more than an odd spectrum has; the extra one is ignored.
        let decodedBins = magnitudeDecoder.outputBins
        precondition(decodedBins >= stft.binCount, "the decoders cover fewer bins than a frame")
        features = Scratch(count: RealtimeModel.width * modelBins)
        decoded = Scratch(count: 3 * decodedBins)
        magnitudeColumns = [decoded.pointer]
        phaseColumns = [decoded.pointer + decodedBins, decoded.pointer + 2 * decodedBins]
        phaseFrame = Self.floats(decodedBins)
        silentFrame = Scratch(count: stft.binCount)
        // A hop can complete two frames on the call that closes the first window.
        stftMagnitudes = Self.floats(2 * stft.binCount)
        stftPhases = Self.floats(2 * stft.binCount)
        istftSamples = Self.floats(stft.hopLength)
        leadingZeros = latencySamples
        partial.reserveCapacity(stft.hopLength)
        // A hop that closes the first window releases two hops of samples at once.
        pending.reserveCapacity(2 * stft.windowLength)
    }

    deinit {
        phaseFrame.deallocate()
        stftMagnitudes.deallocate()
        stftPhases.deallocate()
        istftSamples.deallocate()
    }

    /// Adds `input` to the stream and returns one output sample for each input sample.
    ///
    /// The returned samples belong to the delayed output timeline, so the first `latency` of them
    /// are silence. Call `finish` once the input ends to release the remaining delayed samples.
    public func process(_ input: [Float]) -> [Float] {
        var output = [Float](repeating: 0, count: input.count)
        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                process(source, into: destination)
            }
        }
        return output
    }

    /// Writes one output sample into `output` for each sample of `input`.
    ///
    /// This is the form a real-time thread calls: once the internal buffers have grown to one
    /// frame, which the first few hops do, a call allocates nothing.
    public func process(
        _ input: UnsafeBufferPointer<Float>,
        into output: UnsafeMutableBufferPointer<Float>
    ) {
        precondition(!finished, "the stream already ended; create a new restorer")
        precondition(output.count >= input.count, "the output needs one slot per input sample")
        var offset = 0

        while offset < input.count {
            let missing = hopLength - partial.count
            let take = min(missing, input.count - offset)
            partial.append(
                contentsOf: UnsafeBufferPointer(rebasing: input[offset..<(offset + take)]))

            if partial.count == hopLength {
                feed(partial)
                partial.removeAll(keepingCapacity: true)
            }
            for index in offset..<(offset + take) {
                output[index] = nextSample()
            }
            offset += take
        }
        compactPending()
    }

    /// Forgets the stream so far, as a gap in the input requires, and keeps every buffer.
    ///
    /// The next sample is treated as the first of a new stream: the leading silence comes back
    /// and no layer remembers a frame from before the call.
    public func reset() {
        stft.reset()
        istft.reset()
        encoder.reset()
        for block in blocks {
            block.reset()
        }
        magnitudeDecoder.reset()
        phaseDecoder.reset()
        pending.removeAll(keepingCapacity: true)
        pendingStart = 0
        partial.removeAll(keepingCapacity: true)
        leadingZeros = latencySamples
        finished = false
    }

    /// Releases the delayed tail and ends the stream.
    ///
    /// The tail holds the last `latency` samples of the output timeline, so `process` plus
    /// `finish` returns `input.count + latency` samples. A shorter stream is padded with silence
    /// so the count still holds.
    public func finish() -> [Float] {
        precondition(!finished, "the stream already ended; create a new restorer")
        finished = true

        if !partial.isEmpty {
            partial.append(contentsOf: repeatElement(0, count: hopLength - partial.count))
            feed(partial)
            partial.removeAll(keepingCapacity: true)
        }
        drainTransform()
        releaseLookAhead()

        var tail = [Float](repeating: 0, count: latencySamples)
        for index in tail.indices {
            tail[index] = nextSample()
        }
        compactPending()
        return tail
    }

    /// Restores a whole stream from analysed frames, `binCount` values per frame, and ends it.
    ///
    /// Frames isolate model arithmetic from window and FFT rounding near the phase branch cut;
    /// the raw-sample path is checked separately with the publisher's float32 preprocessing.
    /// - Returns: The restored samples without the leading latency.
    func restore(magnitudes: [Float], phases: [Float]) -> [Float] {
        precondition(!finished, "the stream already ended; create a new restorer")
        precondition(
            magnitudes.count == phases.count && magnitudes.count.isMultiple(of: binCount),
            "the frames need one magnitude and one phase per bin"
        )
        finished = true
        let count = magnitudes.count
        magnitudes.withUnsafeBufferPointer { magnitudes in
            phases.withUnsafeBufferPointer { phases in
                guard let magnitudes = magnitudes.baseAddress, let phases = phases.baseAddress
                else {
                    return
                }
                for start in stride(from: 0, to: count, by: binCount) {
                    restore(magnitudes: magnitudes + start, phases: phases + start)
                }
            }
        }
        releaseLookAhead()
        defer { pending.removeAll(keepingCapacity: true) }
        return Array(pending[pendingStart...])
    }

    /// Collects the frames the model was holding back for its look-ahead; the reference pads
    /// the spectrum with that many empty frames to do the same.
    private func releaseLookAhead() {
        for _ in 0..<lookAhead {
            restore(magnitudes: silentFrame.pointer, phases: silentFrame.pointer)
        }
    }

    /// Clears a frame whose magnitudes are mostly non-positive.
    ///
    /// The reference inference clears those frames instead of passing the decoder's noise in
    /// them into the overlap-add. It leaves the stream's very first frame alone, which reads as
    /// an oversight; every frame is treated the same here.
    static func suppressSweepArtifact(_ magnitudes: UnsafeMutableBufferPointer<Float>) {
        var nonPositive = 0
        for value in magnitudes where value <= 0 {
            nonPositive += 1
        }
        guard nonPositive * 2 > magnitudes.count else {
            return
        }
        magnitudes.update(repeating: 0)
    }

    private func nextSample() -> Float {
        if leadingZeros > 0 {
            leadingZeros -= 1
            return 0
        }
        guard pendingStart < pending.count else {
            return 0
        }
        let sample = pending[pendingStart]
        pendingStart += 1
        return sample
    }

    private func compactPending() {
        guard pendingStart > 0 else {
            return
        }
        pending.removeFirst(pendingStart)
        pendingStart = 0
    }

    /// Runs one hop of input through the transform and every frame it completes.
    private func feed(_ samples: [Float]) {
        let count = samples.withUnsafeBufferPointer { input in
            stft.process(
                input,
                magnitudes: UnsafeMutableBufferPointer(
                    start: stftMagnitudes,
                    count: 2 * binCount
                ),
                phases: UnsafeMutableBufferPointer(start: stftPhases, count: 2 * binCount)
            )
        }
        for frame in 0..<count {
            restoreFrame(frame)
        }
    }

    /// Flushes the transform's reflected final frame and the frames it completes.
    private func drainTransform() {
        while true {
            let count = stft.finish(
                magnitudes: UnsafeMutableBufferPointer(
                    start: stftMagnitudes,
                    count: 2 * binCount
                ),
                phases: UnsafeMutableBufferPointer(start: stftPhases, count: 2 * binCount)
            )
            guard count > 0 else {
                return
            }
            for frame in 0..<count {
                restoreFrame(frame)
            }
        }
    }

    /// Encodes, restores and synthesises one spectral frame of the transform's output.
    private func restoreFrame(_ frame: Int) {
        restore(
            magnitudes: stftMagnitudes + frame * binCount,
            phases: stftPhases + frame * binCount
        )
    }

    private func restore(magnitudes: UnsafePointer<Float>, phases: UnsafePointer<Float>) {
        // The workers stay awake from here to the last decoder, between the jobs of the frame.
        pool.beginFrame()
        defer { pool.endFrame() }
        guard encoder.process(magnitudes: magnitudes, phases: phases, output: features.pointer)
        else {
            return
        }
        for block in blocks {
            block.process(input: features.pointer, output: features.pointer)
        }
        magnitudeDecoder.process(input: features.pointer, columns: magnitudeColumns)
        phaseDecoder.process(input: features.pointer, columns: phaseColumns)

        var count = Int32(binCount)
        vvatan2f(phaseFrame, phaseColumns[1], phaseColumns[0], &count)
        let magnitudeFrame = UnsafeMutableBufferPointer(start: decoded.pointer, count: binCount)
        Self.suppressSweepArtifact(magnitudeFrame)

        let written = istft.process(
            magnitudes: UnsafeBufferPointer(magnitudeFrame),
            phases: UnsafeBufferPointer(start: phaseFrame, count: binCount),
            samples: UnsafeMutableBufferPointer(start: istftSamples, count: hopLength)
        )
        if written > 0 {
            pending.append(contentsOf: UnsafeBufferPointer(start: istftSamples, count: written))
        }
    }

    private static func floats(_ count: Int) -> UnsafeMutablePointer<Float> {
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: count)
        buffer.initialize(repeating: 0, count: count)
        return buffer
    }
}
