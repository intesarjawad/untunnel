import Accelerate
import Foundation

/// A streaming inverse short-time Fourier transform for one tier.
///
/// The transform rebuilds the centred frames made by `StreamingSTFT`: the first reflected hop
/// is trimmed, each later frame releases one hop of output, and every sample is divided by the
/// summed squared window that covers it. The setup and every buffer are allocated at init so
/// `process` does not allocate.
public final class StreamingISTFT {
    /// The tier rate in hertz.
    public let sampleRate: Int
    /// The frame length in samples, and the number of points in the inverse real DFT.
    public let windowLength: Int
    /// The number of samples released per frame once output starts.
    public let hopLength: Int
    /// The number of frequency bins per frame, counting DC and Nyquist.
    public let binCount: Int

    private let setup: vDSP_DFT_Setup
    private let window: UnsafeMutablePointer<Float>
    private let spectrumReal: UnsafeMutablePointer<Float>
    private let spectrumImaginary: UnsafeMutablePointer<Float>
    private let timeReal: UnsafeMutablePointer<Float>
    private let timeImaginary: UnsafeMutablePointer<Float>
    private let frame: UnsafeMutablePointer<Float>
    private let accumulator: UnsafeMutablePointer<Float>
    private let windowSum: UnsafeMutablePointer<Float>

    private var frameCount = 0

    /// Creates a transform for `tier`.
    public init(tier: Tier) {
        precondition(tier.sampleRate > 0, "a sample rate must be positive")
        let windowLength = STFTGeometry.windowLength(for: tier)
        let hopLength = STFTGeometry.hopLength(for: tier)
        precondition(
            windowLength % 2 == 0 && hopLength == windowLength / 2,
            "a tier rate must produce an even frame with a half-frame hop"
        )
        guard
            let setup = vDSP_DFT_zrop_CreateSetup(
                nil,
                vDSP_Length(windowLength),
                .INVERSE
            )
        else {
            preconditionFailure(
                "vDSP has no inverse DFT for a \(windowLength)-sample frame at \(tier.sampleRate) Hz"
            )
        }

        self.sampleRate = tier.sampleRate
        self.windowLength = windowLength
        self.hopLength = hopLength
        binCount = windowLength / 2 + 1
        self.setup = setup

        window = UnsafeMutablePointer<Float>.allocate(capacity: windowLength)
        for index in 0..<windowLength {
            let phase = 2 * Double.pi * Double(index) / Double(windowLength)
            window[index] = Float(0.5 - 0.5 * cos(phase))
        }
        spectrumReal = UnsafeMutablePointer<Float>.allocate(capacity: windowLength / 2)
        spectrumImaginary = UnsafeMutablePointer<Float>.allocate(capacity: windowLength / 2)
        timeReal = UnsafeMutablePointer<Float>.allocate(capacity: windowLength / 2)
        timeImaginary = UnsafeMutablePointer<Float>.allocate(capacity: windowLength / 2)
        frame = UnsafeMutablePointer<Float>.allocate(capacity: windowLength)
        accumulator = UnsafeMutablePointer<Float>.allocate(capacity: windowLength)
        windowSum = UnsafeMutablePointer<Float>.allocate(capacity: windowLength)
        spectrumReal.initialize(repeating: 0, count: windowLength / 2)
        spectrumImaginary.initialize(repeating: 0, count: windowLength / 2)
        timeReal.initialize(repeating: 0, count: windowLength / 2)
        timeImaginary.initialize(repeating: 0, count: windowLength / 2)
        frame.initialize(repeating: 0, count: windowLength)
        accumulator.initialize(repeating: 0, count: windowLength)
        windowSum.initialize(repeating: 0, count: windowLength)
    }

    deinit {
        vDSP_DFT_DestroySetup(setup)
        window.deallocate()
        spectrumReal.deallocate()
        spectrumImaginary.deallocate()
        timeReal.deallocate()
        timeImaginary.deallocate()
        frame.deallocate()
        accumulator.deallocate()
        windowSum.deallocate()
    }

    /// Starts a new stream with the same geometry, keeping every buffer.
    public func reset() {
        accumulator.update(repeating: 0, count: windowLength)
        windowSum.update(repeating: 0, count: windowLength)
        frameCount = 0
    }

    /// Adds one frame and writes the hop it completes.
    ///
    /// The first centred hop lies in the left padding and is trimmed, so the first call returns
    /// zero. Every later call returns `hopLength` samples. Feed the frames in stream order.
    /// - Returns: The number of samples written, either zero or `hopLength`.
    @discardableResult
    public func process(
        magnitudes: UnsafeBufferPointer<Float>,
        phases: UnsafeBufferPointer<Float>,
        samples: UnsafeMutableBufferPointer<Float>
    ) -> Int {
        precondition(
            magnitudes.count >= binCount && phases.count >= binCount,
            "a frame needs \(binCount) magnitude and phase values"
        )
        precondition(
            frameCount == 0 || samples.count >= hopLength,
            "an output buffer needs room for one hop"
        )

        synthesize(magnitudes: magnitudes, phases: phases)
        for index in 0..<windowLength {
            accumulator[index] += frame[index]
            windowSum[index] += window[index] * window[index]
        }
        frameCount += 1

        guard frameCount > 1 else {
            shiftBuffers()
            return 0
        }
        for index in 0..<hopLength {
            let denominator = windowSum[index]
            samples[index] = denominator > 0 ? accumulator[index] / denominator : 0
        }
        shiftBuffers()
        return hopLength
    }

    private func synthesize(
        magnitudes: UnsafeBufferPointer<Float>,
        phases: UnsafeBufferPointer<Float>
    ) {
        let half = windowLength / 2
        spectrumReal[0] = decompressed(magnitudes[0]) * cos(phases[0])
        spectrumImaginary[0] = decompressed(magnitudes[half]) * cos(phases[half])
        for bin in 1..<half {
            let amplitude = decompressed(magnitudes[bin])
            spectrumReal[bin] = amplitude * cos(phases[bin])
            spectrumImaginary[bin] = amplitude * sin(phases[bin])
        }

        vDSP_DFT_Execute(
            setup,
            spectrumReal,
            spectrumImaginary,
            timeReal,
            timeImaginary
        )

        // The inverse real DFT sums the spectrum without the 1/N of an inverse FFT.
        let scale = 1 / Float(windowLength)
        for index in 0..<half {
            frame[2 * index] = timeReal[index] * scale * window[2 * index]
            frame[2 * index + 1] = timeImaginary[index] * scale * window[2 * index + 1]
        }
    }

    /// The model stores `log1p` magnitude, and negatives are noise rather than energy.
    private func decompressed(_ magnitude: Float) -> Float {
        expm1f(max(magnitude, 0))
    }

    private func shiftBuffers() {
        for index in 0..<windowLength where index + hopLength < windowLength {
            accumulator[index] = accumulator[index + hopLength]
            windowSum[index] = windowSum[index + hopLength]
        }
        for index in (windowLength - hopLength)..<windowLength {
            accumulator[index] = 0
            windowSum[index] = 0
        }
    }
}
