import Accelerate
import UntunnelKernels

/// One Mamba recurrence over a set of 64-wide positions.
///
/// The block projects each position to 512 values, convolves the first half causally over four
/// positions, and runs a diagonal linear recurrence whose decay, input and readout all depend
/// on the convolved signal (Gu and Dao, "Mamba", arXiv 2312.00752):
///
///     h = exp(dt * A) * h + dt * B * x
///     y = h . C + D * x
///
/// with the second half of the projection gating `y`. The projections are batched over the
/// positions; only the recurrence walks them one at a time.
///
/// The same weights serve two uses. `advance` treats the positions as independent sequences
/// that each move one step and keep their history, which is the model's time direction.
/// `sweep` treats them as one sequence walked from a zero state, which is its frequency
/// direction.
///
/// Both are also offered in stages, because a frame is shared between threads in two
/// different ways. The matrix products run whole on the calling thread: the matrix unit they
/// use is shared by a cluster of cores, so splitting them gains nothing. Everything between
/// them is split. Positions do not depend on each other outside the recurrence, and inside
/// it the channels do not, so a sweep is shared by ranges of channels with no change to its
/// arithmetic.
final class SelectiveScan {
    static let mixWidth = RealtimeModel.stepRank + 2 * RealtimeModel.stateSize

    let positions: Int

    private static let width = RealtimeModel.width
    private static let inner = RealtimeModel.innerWidth
    private static let states = RealtimeModel.stateSize
    private static let rank = RealtimeModel.stepRank
    private static let taps = RealtimeModel.scanTaps
    private static let stateWidth = states * inner
    /// `softplus` equals its argument to single precision well below this, and `exp` of a
    /// larger value overflows.
    private static let softplusLinearAbove: Float = 80

    private let inProjection: Scratch
    private let convolution: Scratch
    private let convolutionBias: Scratch
    /// `[inner][step rank 4, drive 16, readout 16]`: the one projection the published model
    /// splits three ways.
    private let mix: Scratch
    private let stepProjection: Scratch
    private let stepBias: Scratch
    private let decay: Scratch
    private let skip: Scratch
    private let outProjection: Scratch

    private let projected: Scratch
    private let signal: Scratch
    private let mixed: Scratch
    private let step: Scratch
    private let drivenSignal: Scratch
    private let readout: Scratch
    private let wide: Scratch
    /// `[inner][state]` per sequence, so one channel's sixteen lanes are one vector.
    private let state: Scratch
    /// The three positions before the current one, per sequence; `advance` only.
    private let history: Scratch
    private var oldestHistory = 0

    /// - Parameters:
    ///   - keepsHistory: Whether each position is its own sequence that `advance` moves
    ///     along; a scan used only with `sweep` needs one state and no history.
    ///   - workspace: The arrays the scan computes a frame in. Scans that never run at the
    ///     same time share one.
    init(
        weights: SelectiveScanWeights,
        positions: Int,
        keepsHistory: Bool,
        workspace: ScanWorkspace? = nil
    ) {
        precondition(positions > 0, "a scan needs at least one position")
        self.positions = positions
        inProjection = Scratch(copying: weights.inProjection)
        convolution = Scratch(copying: weights.convolution)
        convolutionBias = Scratch(copying: weights.convolutionBias)
        var mix = [Float]()
        mix.reserveCapacity(Self.inner * Self.mixWidth)
        let driveAndReadout = 2 * Self.states
        for channel in 0..<Self.inner {
            mix += weights.stepMix[(channel * Self.rank)..<((channel + 1) * Self.rank)]
            mix += weights.stateMix[(channel * driveAndReadout)..<((channel + 1) * driveAndReadout)]
        }
        self.mix = Scratch(copying: mix)
        stepProjection = Scratch(copying: weights.stepProjection)
        stepBias = Scratch(copying: weights.stepBias)
        // The recurrence kernel raises two to a power, so the rate carries `log2(e)`.
        decay = Scratch(copying: weights.decay.map { $0 * Float(M_LOG2E) })
        skip = Scratch(copying: weights.skip)
        outProjection = Scratch(copying: weights.outProjection)

        let inner = Self.inner
        let workspace = workspace ?? ScanWorkspace(positions: positions)
        precondition(workspace.positions >= positions, "the workspace is smaller than the scan")
        projected = workspace.projected
        signal = workspace.signal
        mixed = workspace.mixed
        step = workspace.step
        drivenSignal = workspace.drivenSignal
        readout = workspace.readout
        wide = workspace.wide
        state = Scratch(count: (keepsHistory ? positions : 1) * Self.stateWidth)
        history = Scratch(count: keepsHistory ? (Self.taps - 1) * positions * inner : 0)
    }

    func reset() {
        state.clear()
        history.clear()
        oldestHistory = 0
    }

    /// Moves every position's own sequence one step: `positions` rows of 64 in and out.
    func advance(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>) {
        let all = 0..<positions
        project(input)
        convolveStep(all)
        mixSignals()
        advanceRecurrence(all)
        rotateHistory()
        finish(output)
    }

    /// Walks the positions as one sequence from a zero state, upwards or downwards, and
    /// writes each position's readout at that position.
    func sweep(
        input: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>,
        downwards: Bool
    ) {
        let all = 0..<positions
        project(input)
        convolveSweep(all, downwards: downwards)
        mixSignals()
        prepareRecurrence(all)
        sweepRecurrence(channels: 0..<Self.inner, downwards: downwards)
        finish(output)
    }

    /// Stage one, on the calling thread: projects every position.
    func project(_ input: UnsafePointer<Float>) {
        untunnel_matmul(
            input, Self.width, inProjection.pointer, 2 * Self.inner, projected.pointer,
            2 * Self.inner, positions, Self.width, false)
    }

    /// Stage two of `advance` for the sequences of `range`: convolves each over its own
    /// history, which it then extends. `rotateHistory` follows once every range is done.
    func convolveStep(_ range: Range<Int>) {
        precondition(history.count > 0, "this scan was built without per-position history")
        let inner = Self.inner
        let past = Self.taps - 1
        for position in range {
            let current = projected.pointer + position * 2 * inner
            let convolved = signal.pointer + position * inner
            convolved.update(from: convolutionBias.pointer, count: inner)
            for tap in 0..<past {
                let slot = (oldestHistory + tap) % past
                accumulate(
                    history.pointer + (slot * positions + position) * inner,
                    tap: tap, into: convolved)
            }
            accumulate(current, tap: past, into: convolved)
            (history.pointer + (oldestHistory * positions + position) * inner)
                .update(from: current, count: inner)
        }
        activate(range)
    }

    /// Makes the frame just advanced the newest one in every sequence's history.
    func rotateHistory() {
        oldestHistory = (oldestHistory + 1) % (Self.taps - 1)
    }

    /// Stage two of a sweep for the positions of `range`: convolves along the walking
    /// direction.
    func convolveSweep(_ range: Range<Int>, downwards: Bool) {
        let inner = Self.inner
        let past = Self.taps - 1
        let direction = downwards ? -1 : 1
        for position in range {
            let convolved = signal.pointer + position * inner
            convolved.update(from: convolutionBias.pointer, count: inner)
            for tap in 0...past {
                let source = position - direction * (past - tap)
                guard source >= 0 && source < positions else {
                    continue
                }
                accumulate(projected.pointer + source * 2 * inner, tap: tap, into: convolved)
            }
        }
        activate(range)
    }

    /// Stage three, on the calling thread: the step, drive and readout mixes of every position.
    func mixSignals() {
        untunnel_matmul(
            signal.pointer, Self.inner, mix.pointer, Self.mixWidth, mixed.pointer,
            Self.mixWidth, positions, Self.inner, false)
    }

    /// Stage four of `advance` for the sequences of `range`: one step of each recurrence.
    func advanceRecurrence(_ range: Range<Int>) {
        prepareRecurrence(range)
        let inner = Self.inner
        for position in range {
            recur(
                position: position, channels: 0..<inner,
                state: state.pointer + position * Self.stateWidth)
        }
        gate(range, channels: 0..<inner)
    }

    /// Stage four of a sweep for the positions of `range`.
    func prepareRecurrence(_ range: Range<Int>) {
        let inner = Self.inner
        let first = range.lowerBound
        let count = range.count * inner
        let signal = signal.pointer + first * inner
        let step = step.pointer + first * inner

        // Four values deep, so the vector loop that any thread may run is the right one.
        untunnel_matmul_portable(
            mixed.pointer + first * Self.mixWidth, Self.mixWidth, stepProjection.pointer, inner,
            step, inner, range.count, Self.rank, false)
        for position in range {
            let row = self.step.pointer + position * inner
            vDSP_vadd(row, 1, stepBias.pointer, 1, row, 1, vDSP_Length(inner))
            vDSP_vmul(
                self.signal.pointer + position * inner, 1, skip.pointer, 1,
                readout.pointer + position * inner, 1, vDSP_Length(inner)
            )
        }
        softplus(step, scratch: wide.pointer + first * inner, count: count)
        vDSP_vmul(
            step, 1, signal, 1, drivenSignal.pointer + first * inner, 1, vDSP_Length(count))
    }

    /// Stage five of a sweep: walks every position for the channels of `channels`, from a
    /// zero state. A channel's state depends on no other channel, so disjoint ranges of
    /// channels may run at once.
    func sweepRecurrence(channels: Range<Int>, downwards: Bool) {
        let lanes = Self.states
        (state.pointer + channels.lowerBound * lanes)
            .update(repeating: 0, count: channels.count * lanes)
        for index in 0..<positions {
            recur(
                position: downwards ? positions - 1 - index : index, channels: channels,
                state: state.pointer)
        }
        gate(0..<positions, channels: channels)
    }

    /// The last stage, on the calling thread: projects every position's readout into `output`.
    func finish(_ output: UnsafeMutablePointer<Float>) {
        untunnel_matmul(
            readout.pointer, Self.inner, outProjection.pointer, Self.width, output, Self.width,
            positions, Self.inner, false)
    }

    private func accumulate(
        _ source: UnsafePointer<Float>,
        tap: Int,
        into convolved: UnsafeMutablePointer<Float>
    ) {
        vDSP_vma(
            source, 1, convolution.pointer + tap * Self.inner, 1, convolved, 1, convolved, 1,
            vDSP_Length(Self.inner)
        )
    }

    /// The activations of the convolved signal and of the gate.
    private func activate(_ range: Range<Int>) {
        let inner = Self.inner
        untunnel_silu(signal.pointer + range.lowerBound * inner, range.count * inner)
        for position in range {
            untunnel_silu(projected.pointer + position * 2 * inner + inner, inner)
        }
    }

    /// One step of the recurrence at `position` for `channels` of the state it belongs to.
    private func recur(position: Int, channels: Range<Int>, state: UnsafeMutablePointer<Float>) {
        let row = position * Self.inner + channels.lowerBound
        untunnel_scan_step(
            step.pointer + row,
            drivenSignal.pointer + row,
            decay.pointer + channels.lowerBound * Self.states,
            mixed.pointer + position * Self.mixWidth + Self.rank,
            state + channels.lowerBound * Self.states,
            readout.pointer + row,
            channels.count
        )
    }

    private func gate(_ range: Range<Int>, channels: Range<Int>) {
        let inner = Self.inner
        for position in range {
            let row = readout.pointer + position * inner + channels.lowerBound
            vDSP_vmul(
                row, 1, projected.pointer + position * 2 * inner + inner + channels.lowerBound, 1,
                row, 1, vDSP_Length(channels.count)
            )
        }
    }

    /// `log(1 + exp(x))` in place.
    private func softplus(
        _ values: UnsafeMutablePointer<Float>,
        scratch: UnsafeMutablePointer<Float>,
        count: Int
    ) {
        var length = Int32(count)
        var floor = -Float.greatestFiniteMagnitude
        var ceiling = Self.softplusLinearAbove
        vDSP_vclip(values, 1, &floor, &ceiling, scratch, 1, vDSP_Length(count))
        untunnel_exp(scratch, count)
        vvlog1pf(scratch, scratch, &length)
        vDSP_vmax(scratch, 1, values, 1, values, 1, vDSP_Length(count))
    }
}

/// The arrays one scan computes a frame in, none of which outlives the frame.
///
/// A scan fills and reads all of them once per frame. Scans that run one after another share
/// a workspace, so the memory they work in is still in the cache instead of each scan
/// bringing in its own.
final class ScanWorkspace {
    let positions: Int
    /// `[position][signal 256, gate 256]`.
    let projected: Scratch
    let signal: Scratch
    /// `[position][step input 4, drive 16, readout 16]`.
    let mixed: Scratch
    let step: Scratch
    let drivenSignal: Scratch
    let readout: Scratch
    let wide: Scratch

    init(positions: Int) {
        let inner = RealtimeModel.innerWidth
        self.positions = positions
        projected = Scratch(count: positions * 2 * inner)
        signal = Scratch(count: positions * inner)
        mixed = Scratch(count: positions * SelectiveScan.mixWidth)
        step = Scratch(count: positions * inner)
        drivenSignal = Scratch(count: positions * inner)
        readout = Scratch(count: positions * inner)
        wide = Scratch(count: positions * inner)
    }
}
