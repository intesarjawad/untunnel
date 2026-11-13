import Accelerate

/// One time-frequency block of the offline model over a whole `[frame][bin]` map.
///
/// With `x` the map, each branch is
///
///     x = x + norm(linear([forward(x) + x, backward(x) + x]))
///
/// first along time, one sequence per bin, then along frequency, one sequence per frame.
/// `forward` and `backward` are two separately trained recurrences that walk the sequence in
/// opposite directions from a zero state.
final class OfflineBlock {
    let frames: Int
    let bins: Int

    private static let width = RealtimeModel.width

    private let timeForward: SelectiveScan
    private let timeBackward: SelectiveScan
    private let timeHead: BranchHead
    private let frequencyForward: SelectiveScan
    private let frequencyBackward: SelectiveScan
    private let frequencyHead: BranchHead

    /// - Parameters:
    ///   - timeWorkspace: Shared by every time recurrence, which run one after another.
    ///   - frequencyWorkspace: Shared by every frequency recurrence.
    init(
        weights: OfflineBlockWeights,
        frames: Int,
        bins: Int,
        timeWorkspace: ScanWorkspace,
        frequencyWorkspace: ScanWorkspace
    ) {
        self.frames = frames
        self.bins = bins
        timeForward = SelectiveScan(
            weights: weights.timeForward, positions: frames, keepsHistory: false,
            workspace: timeWorkspace)
        timeBackward = SelectiveScan(
            weights: weights.timeBackward, positions: frames, keepsHistory: false,
            workspace: timeWorkspace)
        timeHead = BranchHead(weights: weights.timeHead)
        frequencyForward = SelectiveScan(
            weights: weights.frequencyForward, positions: bins, keepsHistory: false,
            workspace: frequencyWorkspace)
        frequencyBackward = SelectiveScan(
            weights: weights.frequencyBackward, positions: bins, keepsHistory: false,
            workspace: frequencyWorkspace)
        frequencyHead = BranchHead(weights: weights.frequencyHead)
    }

    /// Runs both branches over `frames` x `bins` rows of 64 channels, in place.
    func process(_ map: UnsafeMutablePointer<Float>) {
        let width = Self.width
        let sequence = Scratch(count: frames * width)
        let branch = Branch(length: frames)
        for bin in 0..<bins {
            for frame in 0..<frames {
                (sequence.pointer + frame * width)
                    .update(from: map + (frame * bins + bin) * width, count: width)
            }
            branch.run(
                sequence.pointer, forward: timeForward, backward: timeBackward, head: timeHead)
            // The bin's sequence was copied out, so its residual can be added in place.
            for frame in 0..<frames {
                let row = map + (frame * bins + bin) * width
                vDSP_vadd(
                    row, 1, branch.output.pointer + frame * width, 1, row, 1, vDSP_Length(width))
            }
        }

        let frequencyBranch = Branch(length: bins)
        for frame in 0..<frames {
            let rows = map + frame * bins * width
            frequencyBranch.run(
                rows, forward: frequencyForward, backward: frequencyBackward,
                head: frequencyHead)
            vDSP_vadd(
                rows, 1, frequencyBranch.output.pointer, 1, rows, 1, vDSP_Length(bins * width))
        }
    }
}

/// The arrays one branch computes a sequence in.
private final class Branch {
    let length: Int
    let output: Scratch
    private let forwardOutput: Scratch
    private let backwardOutput: Scratch
    private let joined: Scratch

    init(length: Int) {
        let width = RealtimeModel.width
        self.length = length
        output = Scratch(count: length * width)
        forwardOutput = Scratch(count: length * width)
        backwardOutput = Scratch(count: length * width)
        joined = Scratch(count: length * 2 * width)
    }

    /// Writes `norm(linear([forward(x) + x, backward(x) + x]))` for the `length` rows of `x`
    /// to `output`.
    func run(
        _ input: UnsafePointer<Float>,
        forward: SelectiveScan,
        backward: SelectiveScan,
        head: BranchHead
    ) {
        let width = RealtimeModel.width
        forward.sweep(input: input, output: forwardOutput.pointer, downwards: false)
        backward.sweep(input: input, output: backwardOutput.pointer, downwards: true)
        for position in 0..<length {
            let residual = input + position * width
            let row = joined.pointer + 2 * position * width
            vDSP_vadd(
                forwardOutput.pointer + position * width, 1, residual, 1, row, 1,
                vDSP_Length(width))
            vDSP_vadd(
                backwardOutput.pointer + position * width, 1, residual, 1, row + width, 1,
                vDSP_Length(width))
        }
        head.apply(input: joined.pointer, rows: length, output: output.pointer)
    }
}
