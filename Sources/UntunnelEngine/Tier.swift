/// The processing rate and model configuration for one restoration stream.
public struct Tier: Sendable, Hashable {
    /// The hop, in milliseconds, the streaming model was trained with.
    public static let streamingHopMilliseconds = 20

    /// The processing sample rate in hertz.
    public let sampleRate: Int
    /// The number of model layers used for inference.
    public let exitLayer: Int
    /// The number of future frames available to the model.
    public let lookAhead: Int
    /// The milliseconds between two analysis frames; the frame itself is twice as long.
    public let hopMilliseconds: Int

    /// Creates a configuration selected by the measured tier rule.
    public init(
        sampleRate: Int, exitLayer: Int, lookAhead: Int,
        hopMilliseconds: Int = Tier.streamingHopMilliseconds
    ) {
        self.sampleRate = sampleRate
        self.exitLayer = exitLayer
        self.lookAhead = lookAhead
        self.hopMilliseconds = hopMilliseconds
    }
}
