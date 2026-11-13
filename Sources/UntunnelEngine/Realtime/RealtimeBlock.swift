import Accelerate
import UntunnelKernels

/// One time-frequency block of the real-time model, run one frame at a time.
///
/// With `x` the frame's `bins` rows of 64 channels:
///
///     u = x + norm(linear(time(x) + x))
///     y = u + norm(linear([up(u) + u, down(u) + u]))
///
/// `time` is one causal recurrence per bin that carries its state from frame to frame. `up`
/// and `down` are two separately trained recurrences that walk the bins of the current frame
/// in opposite directions from a zero state, so the frequency branch holds no state at all.
///
/// Each recurrence runs in the stages `SelectiveScan` offers: its matrix products on the
/// calling thread, and everything between them on the worker pool in chunks.
final class RealtimeBlock {
    let bins: Int

    private static let width = RealtimeModel.width
    /// More chunks than threads, so a thread that starts late leaves little for the others
    /// to wait on.
    private static let chunksPerScan = 8

    private enum Stage {
        case convolveStep, advance, convolveSweeps, prepareSweeps, sweep
    }

    private let time: SelectiveScan
    private let up: SelectiveScan
    private let down: SelectiveScan
    private let timeHead: BranchHead
    private let frequencyHead: BranchHead
    private let scanned: Scratch
    private let scannedDown: Scratch
    private let joined: Scratch
    private let afterTime: Scratch
    private let branch: Scratch
    private let pool: WorkerPool
    /// The stage being processed, for the chunks that run on other threads.
    private var stage = Stage.convolveStep

    /// - Parameter workspace: What the block computes a frame in. The blocks of a stream run
    ///   one after another and share one.
    init(
        weights: RealtimeBlockWeights,
        bins: Int,
        pool: WorkerPool = .shared,
        workspace: BlockWorkspace? = nil
    ) {
        let workspace = workspace ?? BlockWorkspace(bins: bins)
        precondition(workspace.bins == bins, "the workspace is for another number of bins")
        self.bins = bins
        self.pool = pool
        time = SelectiveScan(
            weights: weights.time, positions: bins, keepsHistory: true,
            workspace: workspace.upwards)
        up = SelectiveScan(
            weights: weights.frequencyUp, positions: bins, keepsHistory: false,
            workspace: workspace.upwards)
        down = SelectiveScan(
            weights: weights.frequencyDown, positions: bins, keepsHistory: false,
            workspace: workspace.downwards)
        timeHead = BranchHead(weights: weights.timeHead)
        frequencyHead = BranchHead(weights: weights.frequencyHead)
        scanned = workspace.scanned
        scannedDown = workspace.scannedDown
        joined = workspace.joined
        afterTime = workspace.afterTime
        branch = workspace.branch
    }

    /// Forgets the time branch's history and state.
    func reset() {
        time.reset()
    }

    /// Reads `bins` rows of 64 channels and writes as many; the two may be the same memory.
    func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>) {
        let width = Self.width
        let count = vDSP_Length(bins * width)

        time.project(input)
        run(.convolveStep, chunks: Self.chunksPerScan)
        time.mixSignals()
        run(.advance, chunks: Self.chunksPerScan)
        time.rotateHistory()
        time.finish(scanned.pointer)
        vDSP_vadd(scanned.pointer, 1, input, 1, scanned.pointer, 1, count)
        timeHead.apply(input: scanned.pointer, rows: bins, output: branch.pointer)
        vDSP_vadd(branch.pointer, 1, input, 1, afterTime.pointer, 1, count)

        up.project(afterTime.pointer)
        down.project(afterTime.pointer)
        run(.convolveSweeps, chunks: 2 * Self.chunksPerScan)
        up.mixSignals()
        down.mixSignals()
        run(.prepareSweeps, chunks: 2 * Self.chunksPerScan)
        run(.sweep, chunks: 2 * Self.chunksPerScan)
        up.finish(scanned.pointer)
        down.finish(scannedDown.pointer)
        // Each direction's output, with its residual, is that direction's half of every
        // joined row.
        for bin in 0..<bins {
            let residual = afterTime.pointer + bin * width
            let row = joined.pointer + 2 * bin * width
            vDSP_vadd(scanned.pointer + bin * width, 1, residual, 1, row, 1, vDSP_Length(width))
            vDSP_vadd(
                scannedDown.pointer + bin * width, 1, residual, 1, row + width, 1,
                vDSP_Length(width))
        }
        frequencyHead.apply(input: joined.pointer, rows: bins, output: branch.pointer)
        vDSP_vadd(branch.pointer, 1, afterTime.pointer, 1, output, 1, count)
    }

    private func run(_ stage: Stage, chunks: Int) {
        self.stage = stage
        pool.run(chunks: chunks, context: Unmanaged.passUnretained(self).toOpaque()) {
            context, chunk in
            Unmanaged<RealtimeBlock>.fromOpaque(context).takeUnretainedValue().runChunk(chunk)
        }
    }

    /// Chunks of a time stage are ranges of bins. Chunks of a sweep stage alternate between
    /// the two directions, and `chunk / 2` is the part of that direction's work: a range of
    /// bins, or for the walk itself a range of channels.
    private func runChunk(_ chunk: Int) {
        let parts = Self.chunksPerScan
        let downwards = chunk % 2 == 1
        let scan = downwards ? down : up
        switch stage {
        case .convolveStep:
            time.convolveStep(Self.part(chunk, of: parts, in: 0..<bins))
        case .advance:
            time.advanceRecurrence(Self.part(chunk, of: parts, in: 0..<bins))
        case .convolveSweeps:
            scan.convolveSweep(
                Self.part(chunk / 2, of: parts, in: 0..<bins), downwards: downwards)
        case .prepareSweeps:
            scan.prepareRecurrence(Self.part(chunk / 2, of: parts, in: 0..<bins))
        case .sweep:
            scan.sweepRecurrence(
                channels: Self.part(chunk / 2, of: parts, in: 0..<RealtimeModel.innerWidth),
                downwards: downwards)
        }
    }

    /// The `index`-th of `count` consecutive parts of `range`, which is empty when the range
    /// has fewer elements than parts.
    private static func part(_ index: Int, of count: Int, in range: Range<Int>) -> Range<Int> {
        let size = (range.count + count - 1) / count
        let lower = min(range.lowerBound + index * size, range.upperBound)
        return lower..<min(lower + size, range.upperBound)
    }
}

/// The arrays one block computes a frame in, none of which outlives the frame.
final class BlockWorkspace {
    let bins: Int
    /// The time branch and the upward sweep run one after the other and share this one.
    let upwards: ScanWorkspace
    /// The downward sweep runs beside the upward one.
    let downwards: ScanWorkspace
    let scanned: Scratch
    let scannedDown: Scratch
    let joined: Scratch
    let afterTime: Scratch
    let branch: Scratch

    init(bins: Int) {
        let width = RealtimeModel.width
        self.bins = bins
        upwards = ScanWorkspace(positions: bins)
        downwards = ScanWorkspace(positions: bins)
        scanned = Scratch(count: bins * width)
        scannedDown = Scratch(count: bins * width)
        joined = Scratch(count: bins * 2 * width)
        afterTime = Scratch(count: bins * width)
        branch = Scratch(count: bins * width)
    }
}

/// The linear layer and normalisation that close a branch.
final class BranchHead {
    private let projection: Scratch
    private let bias: Scratch
    private let normScale: Scratch
    private let normShift: Scratch
    private let inputWidth: Int

    init(weights: BranchHeadWeights) {
        projection = Scratch(copying: weights.projection)
        bias = Scratch(copying: weights.bias)
        normScale = Scratch(copying: weights.normScale)
        normShift = Scratch(copying: weights.normShift)
        inputWidth = weights.inputWidth
    }

    func apply(input: UnsafePointer<Float>, rows: Int, output: UnsafeMutablePointer<Float>) {
        let width = RealtimeModel.width
        untunnel_matmul(
            input, inputWidth, projection.pointer, width, output, width, rows, inputWidth, false)
        for row in 0..<rows {
            let channels = output + row * width
            vDSP_vadd(channels, 1, bias.pointer, 1, channels, 1, vDSP_Length(width))
        }
        normalizeRows(output, rows: rows, scale: normScale.pointer, shift: normShift.pointer)
    }
}
