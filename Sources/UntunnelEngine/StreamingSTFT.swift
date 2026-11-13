import Accelerate
import Foundation

/// The frame geometry shared by the streaming transforms.
///
/// A frame is always twice its hop. The streaming tiers analyse 40 ms frames with a 20 ms hop,
/// the sizes that model was trained with, so a 48 kHz tier uses 1920-sample frames over
/// 960-sample hops.
enum STFTGeometry {
    /// Milliseconds in one second.
    static let millisecondsPerSecond = 1000

    static func windowLength(for tier: Tier) -> Int {
        2 * hopLength(for: tier)
    }

    static func hopLength(for tier: Tier) -> Int {
        tier.sampleRate * tier.hopMilliseconds / millisecondsPerSecond
    }
}

/// A streaming short-time Fourier transform.
///
/// Frames are centred with reflection padding, so frame zero starts before the first input
/// sample and `finish()` produces the final frame. Magnitudes are compressed with `log1p` and
/// phases with `atan2`, matching the columns the model consumes. The setup and every buffer are
/// allocated at init so `process` does not allocate for hop-sized input.
public final class StreamingSTFT {
    /// The sample rate in hertz.
    public let sampleRate: Int
    /// The frame length in samples, and the number of points in the real DFT.
    public let windowLength: Int
    /// The number of samples between frame starts.
    public let hopLength: Int
    /// The number of frequency bins per frame, counting DC and Nyquist.
    public let binCount: Int

    private let setup: vDSP_DFT_SetupD
    private let window: UnsafeMutablePointer<Double>
    private let float32Window: Bool
    private let windowed: UnsafeMutablePointer<Double>
    private let evenInput: UnsafeMutablePointer<Double>
    private let oddInput: UnsafeMutablePointer<Double>
    private let realOutput: UnsafeMutablePointer<Double>
    private let imaginaryOutput: UnsafeMutablePointer<Double>

    /// Input samples not yet discarded, starting at global index `pendingStart`.
    private var pending: [Float] = []
    private var pendingStart = 0
    private var totalReceived = 0
    private var nextFrame = 0

    /// Creates a transform for `tier`.
    public convenience init(tier: Tier, float32Window: Bool = false) {
        let windowLength = STFTGeometry.windowLength(for: tier)
        let hopLength = STFTGeometry.hopLength(for: tier)
        precondition(
            windowLength % 2 == 0 && hopLength == windowLength / 2,
            "a tier rate must produce an even frame with a half-frame hop"
        )
        self.init(
            sampleRate: tier.sampleRate, windowLength: windowLength, hopLength: hopLength,
            float32Window: float32Window)
    }

    /// Creates a transform of even `windowLength`-sample frames that start `hopLength` apart,
    /// a hop being at most half a frame.
    /// `float32Window` matches the publisher's model preprocessing; the default retains double
    /// precision for standalone transform comparisons and round trips.
    public init(sampleRate: Int, windowLength: Int, hopLength: Int, float32Window: Bool = false) {
        precondition(sampleRate > 0, "a sample rate must be positive")
        precondition(
            windowLength % 2 == 0 && hopLength > 0 && hopLength <= windowLength / 2,
            "a frame must be even and at least two hops long"
        )
        guard
            let setup = vDSP_DFT_zrop_CreateSetupD(
                nil,
                vDSP_Length(windowLength),
                .FORWARD
            )
        else {
            preconditionFailure(
                "vDSP has no DFT for a \(windowLength)-sample frame at \(sampleRate) Hz"
            )
        }

        self.sampleRate = sampleRate
        self.windowLength = windowLength
        self.hopLength = hopLength
        binCount = windowLength / 2 + 1
        self.setup = setup
        self.float32Window = float32Window

        window = UnsafeMutablePointer<Double>.allocate(capacity: windowLength)
        let phaseStep = Float(2 * Double.pi / Double(windowLength))
        for index in 0..<windowLength {
            if float32Window {
                let phase = Float(index) * phaseStep
                window[index] = Double(0.5 - 0.5 * cos(phase))
            } else {
                let phase = 2 * Double.pi * Double(index) / Double(windowLength)
                window[index] = 0.5 - 0.5 * cos(phase)
            }
        }
        windowed = UnsafeMutablePointer<Double>.allocate(capacity: windowLength)
        evenInput = UnsafeMutablePointer<Double>.allocate(capacity: windowLength / 2)
        oddInput = UnsafeMutablePointer<Double>.allocate(capacity: windowLength / 2)
        realOutput = UnsafeMutablePointer<Double>.allocate(capacity: windowLength / 2)
        imaginaryOutput = UnsafeMutablePointer<Double>.allocate(capacity: windowLength / 2)
        windowed.initialize(repeating: 0, count: windowLength)
        evenInput.initialize(repeating: 0, count: windowLength / 2)
        oddInput.initialize(repeating: 0, count: windowLength / 2)
        realOutput.initialize(repeating: 0, count: windowLength / 2)
        imaginaryOutput.initialize(repeating: 0, count: windowLength / 2)
        pending.reserveCapacity(windowLength + hopLength)
    }

    deinit {
        vDSP_DFT_DestroySetupD(setup)
        window.deallocate()
        windowed.deallocate()
        evenInput.deallocate()
        oddInput.deallocate()
        realOutput.deallocate()
        imaginaryOutput.deallocate()
    }

    /// Starts a new stream with the same geometry, keeping every buffer.
    public func reset() {
        pending.removeAll(keepingCapacity: true)
        pendingStart = 0
        totalReceived = 0
        nextFrame = 0
    }

    /// Adds `input` and writes every frame that the new samples complete.
    ///
    /// `magnitudes` and `phases` hold `binCount` values per frame. Input fed one hop at a
    /// time can complete two frames on the call that follows the first hop, because centred
    /// frame zero needs one sample past the first hop.
    /// - Returns: The number of frames written.
    @discardableResult
    public func process(
        _ input: UnsafeBufferPointer<Float>,
        magnitudes: UnsafeMutableBufferPointer<Float>,
        phases: UnsafeMutableBufferPointer<Float>
    ) -> Int {
        let capacity = min(magnitudes.count, phases.count) / binCount
        pending.append(contentsOf: input)
        totalReceived += input.count

        var written = 0
        while written < capacity && frameIsComplete(nextFrame) {
            writeFrame(
                nextFrame,
                magnitudes: magnitudes,
                phases: phases,
                frameOffset: written * binCount
            )
            nextFrame += 1
            written += 1
        }
        // The reflected final frame reaches one sample before the next frame starts.
        discardSamples(before: nextFrame * hopLength - windowLength / 2 - 1)
        return written
    }

    /// Writes the final frame using the reflected right padding.
    ///
    /// Call it once the stream ends; the frame it writes is the one that needs samples past
    /// the last input sample. Repeated calls drain any frames left by a small output buffer.
    /// - Returns: The number of frames written.
    @discardableResult
    public func finish(
        magnitudes: UnsafeMutableBufferPointer<Float>,
        phases: UnsafeMutableBufferPointer<Float>
    ) -> Int {
        guard totalReceived > hopLength else {
            return 0
        }
        let capacity = min(magnitudes.count, phases.count) / binCount
        let lastFrame = totalReceived / hopLength

        var written = 0
        while written < capacity && nextFrame <= lastFrame {
            writeFrame(
                nextFrame,
                magnitudes: magnitudes,
                phases: phases,
                frameOffset: written * binCount
            )
            nextFrame += 1
            written += 1
        }
        return written
    }

    /// Whether frame `frame` has every real sample its window needs.
    private func frameIsComplete(_ frame: Int) -> Bool {
        if frame == 0 {
            return totalReceived > windowLength / 2
        }
        return frame * hopLength + windowLength / 2 <= totalReceived
    }

    /// Reads a sample in the centred coordinate system, reflecting outside the input.
    private func sample(at index: Int) -> Float {
        if index < 0 {
            return pending[-index - pendingStart]
        }
        if index >= totalReceived {
            return pending[2 * totalReceived - 2 - index - pendingStart]
        }
        return pending[index - pendingStart]
    }

    private func discardSamples(before index: Int) {
        let keep = max(index, pendingStart)
        let count = min(keep - pendingStart, pending.count)
        guard count > 0 else {
            return
        }
        pending.removeFirst(count)
        pendingStart += count
    }

    private func writeFrame(
        _ frameIndex: Int,
        magnitudes: UnsafeMutableBufferPointer<Float>,
        phases: UnsafeMutableBufferPointer<Float>,
        frameOffset: Int
    ) {
        let half = windowLength / 2
        let start = frameIndex * hopLength - half
        for index in 0..<windowLength {
            // The model reads phase across the branch cut; the publisher's float32 window
            // and multiplication determine its first reflected frame's signs at that cut.
            let value = sample(at: start + index)
            windowed[index] =
                float32Window
                ? Double(value * Float(window[index])) : Double(value) * window[index]
        }
        for index in 0..<half {
            evenInput[index] = windowed[2 * index]
            oddInput[index] = windowed[2 * index + 1]
        }

        vDSP_DFT_ExecuteD(
            setup,
            evenInput,
            oddInput,
            realOutput,
            imaginaryOutput
        )

        // vDSP's forward real DFT returns twice the unitary spectrum, so halve it back.
        let dc = realOutput[0] * 0.5
        magnitudes[frameOffset] = Float(log1p(abs(dc)))
        phases[frameOffset] = Float(atan2(0, dc))
        for bin in 1..<half {
            let real = realOutput[bin] * 0.5
            let imaginary = imaginaryOutput[bin] * 0.5
            magnitudes[frameOffset + bin] = Float(
                log1p((real * real + imaginary * imaginary).squareRoot()))
            phases[frameOffset + bin] = Float(atan2(imaginary, real))
        }
        let nyquist = imaginaryOutput[0] * 0.5
        magnitudes[frameOffset + half] = Float(log1p(abs(nyquist)))
        phases[frameOffset + half] = Float(atan2(0, nyquist))
    }
}
