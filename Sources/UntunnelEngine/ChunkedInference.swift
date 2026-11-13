import Foundation

/// How a long signal is cut into the chunks a whole-signal model can run at once.
///
/// Neighbouring chunks share `overlapSamples` samples, so every join has a stretch where both
/// chunks hold a result and the two can be blended instead of butted together.
public struct ChunkPlan: Sendable, Equatable {
    /// The samples every chunk covers, except a shorter last one.
    public let chunkSamples: Int
    /// The samples two neighbouring chunks share.
    public let overlapSamples: Int

    /// Requires a positive chunk and a nominal overlap between zero and half the chunk.
    public init?(chunkSamples: Int, overlapSamples: Int) {
        guard chunkSamples > 0, overlapSamples >= 0, 2 * overlapSamples <= chunkSamples else {
            return nil
        }
        self.chunkSamples = chunkSamples
        self.overlapSamples = overlapSamples
    }

    /// The samples between the starts of two chunks.
    public var strideSamples: Int {
        chunkSamples - overlapSamples
    }

    /// The chunks that cover `total` samples, in order.
    ///
    /// The last full chunk is anchored to the end, as in the publisher's `inference_chunk.py`.
    /// Only a signal shorter than one chunk produces a short chunk.
    public func ranges(total: Int) -> [Range<Int>] {
        guard total > 0 else {
            return []
        }
        var ranges: [Range<Int>] = []
        var start = 0
        while true {
            let end = min(start + chunkSamples, total)
            ranges.append(start..<end)
            if end == total {
                return ranges
            }
            start = min(start + strideSamples, total - chunkSamples)
        }
    }
}

/// Runs a model that handles one chunk at a time over a whole signal.
public enum ChunkedInference {
    /// Cuts `samples` by `plan`, runs `process` on each chunk and blends the shared stretches.
    ///
    /// The publisher weights whole chunks by a periodic Hann clamped to 1e-7 and divides by
    /// the accumulated weights. `process` must return as many samples as it is given.
    public static func run(
        _ samples: [Float],
        plan: ChunkPlan,
        process: ([Float]) -> [Float]
    ) -> [Float] {
        let ranges = plan.ranges(total: samples.count)
        var output = [Float](repeating: 0, count: samples.count)
        var weightSum = [Float](repeating: 0, count: samples.count)
        let window = (0..<plan.chunkSamples).map { index in
            max(Float(0.5 - 0.5 * cos(2 * .pi * Double(index) / Double(plan.chunkSamples))), 1e-7)
        }

        for range in ranges {
            let restored = process(Array(samples[range]))
            precondition(
                restored.count == range.count,
                "the model returned \(restored.count) samples for a chunk of \(range.count)"
            )
            for offset in 0..<range.count {
                let index = range.lowerBound + offset
                output[index] += window[offset] * restored[offset]
                weightSum[index] += window[offset]
            }
        }
        for index in output.indices { output[index] /= weightSum[index] }
        return output
    }
}
