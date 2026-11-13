/// Follows a device clock that drifts against the pipeline clock.
///
/// The consumer runs at a fixed rate while the producer's device clock runs a little fast or
/// slow. A fixed 1:1 read would drain or overfill the ring within minutes, so a PI controller
/// nudges a fractional read ratio within ±0.5 % to hold the fill near 1.5 hops. The ratio moves
/// slowly enough that linear interpolation between the two neighbouring frames is enough; the
/// polyphase stage after this one does the real rate conversion.
public final class DriftResampler {
    /// Frames in one hop, the unit in which the pipeline exchanges audio.
    public let hopSize: Int
    /// The fill the controller steers towards, in hops.
    public let targetFillHops: Double
    /// The largest ratio correction the controller may apply in either direction.
    public let ratioLimit: Double

    /// The fill integrates the ratio error once per hop, so proportional plus integral control
    /// gives a second-order loop. A natural frequency of 0.05 rad/hop at a damping ratio of 0.9
    /// settles within roughly 60 hops and overshoots by well under a tenth of a hop.
    private static let naturalFrequency = 0.05
    private static let dampingRatio = 0.9
    private static let proportionalGain = 2 * dampingRatio * naturalFrequency
    private static let integralGain = naturalFrequency * naturalFrequency

    private var ratio = 1.0
    private var integral = 0.0
    private var phase = 0.0
    private var current: Float = 0
    private var next: Float = 0
    private var primed = false

    /// Creates a resampler that exchanges audio in hops of `hopSize` frames.
    public init(hopSize: Int, targetFillHops: Double = 1.5, ratioLimit: Double = 0.005) {
        precondition(hopSize > 1, "a hop needs at least two frames to interpolate between")
        precondition(targetFillHops > 0, "the target fill must be positive")
        precondition(ratioLimit > 0 && ratioLimit < 1, "the ratio limit must stay below 100 %")
        self.hopSize = hopSize
        self.targetFillHops = targetFillHops
        self.ratioLimit = ratioLimit
    }

    /// Reads one hop through the fractional position and returns the frames written.
    ///
    /// Call it once per hop so the controller sees a single fill measurement per hop. A short
    /// return means the ring ran dry partway through; the unread part of the hop is simply not
    /// delivered, and the next call resumes at the same fractional position.
    @discardableResult
    public func pullHop(
        from ring: RingBuffer,
        into output: UnsafeMutableBufferPointer<Float>
    ) -> Int {
        if !primed {
            guard ring.availableToRead >= 2, let first = ring.pop(), let second = ring.pop() else {
                return 0
            }
            current = first
            next = second
            primed = true
        }

        let count = min(output.count, hopSize)
        var produced = 0
        hop: while produced < count {
            while phase >= 1 {
                guard let frame = ring.pop() else {
                    break hop
                }
                current = next
                next = frame
                phase -= 1
            }
            output[produced] = current + (next - current) * Float(phase)
            produced += 1
            phase += ratio
        }

        // The fill is sampled after the hop has been consumed, so the measurement and the target
        // mean the same thing from hop to hop, and the correction applies to the next hop.
        updateRatio(fillHops: Double(ring.availableToRead) / Double(hopSize))
        return produced
    }

    private func updateRatio(fillHops: Double) {
        let error = fillHops - targetFillHops
        integral += error
        let integralLimit = ratioLimit / Self.integralGain
        integral = min(max(integral, -integralLimit), integralLimit)
        let correction = Self.proportionalGain * error + Self.integralGain * integral
        ratio = 1 + min(max(correction, -ratioLimit), ratioLimit)
    }
}
