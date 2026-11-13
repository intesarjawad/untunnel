import Accelerate
import Foundation
import Synchronization

/// The frequency axis every spectrogram shares.
///
/// Before and after panes use the same axis, so a feature sits at the same height in both. The
/// span starts below a voice's fundamental and ends at the highest tier's Nyquist rate.
public struct LogFrequencyAxis: Sendable, Equatable {
    /// The span the monitor draws.
    public static let standard = LogFrequencyAxis(lowerHz: 125, upperHz: 24_000)
    /// The octave marks the axis is labelled with.
    public static let labelledHz = [1_000, 2_000, 4_000, 8_000, 16_000]

    /// The frequency at the bottom edge.
    public let lowerHz: Double
    /// The frequency at the top edge.
    public let upperHz: Double

    /// Creates an axis from two positive frequencies, lowest first.
    public init(lowerHz: Double, upperHz: Double) {
        precondition(lowerHz > 0 && upperHz > lowerHz, "an axis needs 0 < lower < upper")
        self.lowerHz = lowerHz
        self.upperHz = upperHz
    }

    /// Where a frequency sits, from 0 at the bottom edge to 1 at the top, clamped to the axis.
    public func position(of hertz: Double) -> Double {
        guard hertz > lowerHz else {
            return 0
        }
        return min(1, log(hertz / lowerHz) / log(upperHz / lowerHz))
    }

    /// The frequency of one row boundary; boundary 0 is the lower edge, `rowCount` the upper.
    public func edgeHz(_ boundary: Int, rowCount: Int) -> Double {
        lowerHz * pow(upperHz / lowerHz, Double(boundary) / Double(rowCount))
    }

    /// The row a frequency falls in, clamped to the first and last row.
    public func row(containing hertz: Double, rowCount: Int) -> Int {
        min(rowCount - 1, Int(position(of: hertz) * Double(rowCount)))
    }

    /// The text beside an octave mark, such as `4 kHz`.
    public static func label(forHz hertz: Int) -> String {
        "\(hertz / 1_000) kHz"
    }
}

/// A 2048-point spectrum of the latest samples, folded onto a log-frequency axis.
///
/// Levels are decibels relative to a full-scale sine: a sine of amplitude one reads 0 dB at its
/// peak row. Every buffer is allocated at init so `push` and `compute` can run on the pipeline
/// thread; the type is not safe to share between threads.
public final class SpectrumAnalyzer: @unchecked Sendable {
    /// The transform length in samples.
    public static let fftLength = 2_048
    /// What a silent row reads, in decibels.
    public static let silenceDb: Float = -120

    /// Rows on the log-frequency axis.
    public let rowCount: Int
    /// The rate of the samples pushed in.
    public let sampleRate: Int

    private static let log2Length = vDSP_Length(11)
    private static let halfLength = fftLength / 2
    /// The mean of a periodic Hann window, which turns a bin magnitude into a sine amplitude.
    private static let windowGain: Float = 0.5

    private let setup: FFTSetup
    private let window: UnsafeMutablePointer<Float>
    private let recent: UnsafeMutablePointer<Float>
    private let windowed: UnsafeMutablePointer<Float>
    private let real: UnsafeMutablePointer<Float>
    private let imaginary: UnsafeMutablePointer<Float>
    private let power: UnsafeMutablePointer<Float>
    private let firstBin: [Int]
    private let lastBin: [Int]

    /// Creates an analyzer for samples at `sampleRate` and `rowCount` rows on `axis`.
    public init(sampleRate: Int, rowCount: Int, axis: LogFrequencyAxis = .standard) {
        precondition(sampleRate > 0 && rowCount > 0, "an analyzer needs a rate and rows")
        guard let setup = vDSP_create_fftsetup(Self.log2Length, FFTRadix(kFFTRadix2)) else {
            preconditionFailure("the FFT setup could not be created")
        }
        self.setup = setup
        self.sampleRate = sampleRate
        self.rowCount = rowCount

        let length = Self.fftLength
        window = .allocate(capacity: length)
        for index in 0..<length {
            window[index] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(length)))
        }
        recent = Self.zeroed(length)
        windowed = Self.zeroed(length)
        real = Self.zeroed(Self.halfLength)
        imaginary = Self.zeroed(Self.halfLength)
        power = Self.zeroed(Self.halfLength)

        let binHz = Double(sampleRate) / Double(length)
        var first: [Int] = []
        var last: [Int] = []
        for row in 0..<rowCount {
            let low = Int((axis.edgeHz(row, rowCount: rowCount) / binHz).rounded())
            let high = Int((axis.edgeHz(row + 1, rowCount: rowCount) / binHz).rounded())
            first.append(max(1, low))
            last.append(min(Self.halfLength - 1, max(high, low, 1)))
        }
        firstBin = first
        lastBin = last
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        window.deallocate()
        recent.deallocate()
        windowed.deallocate()
        real.deallocate()
        imaginary.deallocate()
        power.deallocate()
    }

    /// Slides `hop` into the 2048-sample window; the oldest samples fall out.
    public func push(_ hop: UnsafeBufferPointer<Float>) {
        let length = Self.fftLength
        let count = min(hop.count, length)
        guard count > 0, let source = hop.baseAddress else {
            return
        }
        memmove(recent, recent + count, (length - count) * MemoryLayout<Float>.size)
        memcpy(
            recent + (length - count),
            source + (hop.count - count),
            count * MemoryLayout<Float>.size
        )
    }

    /// Writes one level per row, in decibels, lowest frequency first.
    ///
    /// A row holds the loudest bin it covers, and a row above the Nyquist rate reads silence.
    public func compute(into levels: UnsafeMutableBufferPointer<Float>) {
        precondition(levels.count >= rowCount, "levels needs one slot per row")
        let length = Self.fftLength
        vDSP_vmul(recent, 1, window, 1, windowed, 1, vDSP_Length(length))

        var split = DSPSplitComplex(realp: real, imagp: imaginary)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: Self.halfLength) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(Self.halfLength))
        }
        vDSP_fft_zrip(setup, &split, 1, Self.log2Length, FFTDirection(FFT_FORWARD))
        vDSP_zvmags(&split, 1, power, 1, vDSP_Length(Self.halfLength))

        let nyquistBin = Self.halfLength - 1
        let scale = 1 / pow(Float(length) * Self.windowGain, 2)
        for row in 0..<rowCount {
            guard firstBin[row] <= nyquistBin else {
                levels[row] = Self.silenceDb
                continue
            }
            var loudest: Float = 0
            vDSP_maxv(
                power + firstBin[row],
                1,
                &loudest,
                vDSP_Length(lastBin[row] - firstBin[row] + 1)
            )
            levels[row] = max(Self.silenceDb, 10 * log10(max(loudest * scale, 1e-12)))
        }
    }

    private static func zeroed(_ count: Int) -> UnsafeMutablePointer<Float> {
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: count)
        pointer.initialize(repeating: 0, count: count)
        return pointer
    }
}

/// Spectrum columns handed from the pipeline thread to the main thread.
///
/// Storage is a fixed ring allocated at init, so publishing never allocates; a reader that falls
/// more than `capacity` columns behind loses the oldest ones and is told how many.
public final class SpectrumMailbox: Sendable {
    /// Columns the ring holds.
    public let capacity: Int
    /// Levels per column.
    public let rowCount: Int

    private struct Storage {
        var levels: [Float]
        var written = 0
    }

    private let storage: Mutex<Storage>

    /// Creates an empty mailbox.
    public init(rowCount: Int, capacity: Int = 64) {
        precondition(rowCount > 0 && capacity > 0, "a mailbox needs rows and room")
        self.rowCount = rowCount
        self.capacity = capacity
        storage = Mutex(Storage(levels: [Float](repeating: 0, count: rowCount * capacity)))
    }

    /// Columns published in total.
    public var published: Int {
        storage.withLock { $0.written }
    }

    /// Copies one column into the ring.
    public func publish(_ column: UnsafeBufferPointer<Float>) {
        precondition(column.count == rowCount, "a column needs one level per row")
        storage.withLock { storage in
            let base = storage.written % capacity * rowCount
            for row in 0..<rowCount {
                storage.levels[base + row] = column[row]
            }
            storage.written += 1
        }
    }

    /// The columns published after `position`, oldest first, flattened row by row.
    ///
    /// Pass the returned position back on the next call; `dropped` counts columns that were
    /// overwritten before they could be read.
    public func columns(since position: Int) -> (levels: [Float], position: Int, dropped: Int) {
        storage.withLock { storage in
            let available = storage.written - position
            guard available > 0 else {
                return ([], storage.written, 0)
            }
            let count = min(available, capacity)
            var levels: [Float] = []
            levels.reserveCapacity(count * rowCount)
            for index in (storage.written - count)..<storage.written {
                let base = index % capacity * rowCount
                levels.append(contentsOf: storage.levels[base..<(base + rowCount)])
            }
            return (levels, storage.written, available - count)
        }
    }
}

/// Feeds the analyzer every hop and publishes a column at most thirty times a second.
///
/// The window slides on every hop so a published column always reflects the latest 2048 samples,
/// but the transform only runs when a column will be published. One thread owns it.
public final class SpectrumPublisher: @unchecked Sendable {
    /// The most columns the monitor receives in a second.
    public static let maxPublishesPerSecond = 30.0

    private let analyzer: SpectrumAnalyzer
    private let mailbox: SpectrumMailbox
    private let levels: UnsafeMutableBufferPointer<Float>
    private var lastPublishAt: TimeInterval?

    /// Creates a publisher; the mailbox must have one level per analyzer row.
    public init(analyzer: SpectrumAnalyzer, mailbox: SpectrumMailbox) {
        precondition(analyzer.rowCount == mailbox.rowCount, "rows must match")
        self.analyzer = analyzer
        self.mailbox = mailbox
        levels = .allocate(capacity: analyzer.rowCount)
        levels.initialize(repeating: SpectrumAnalyzer.silenceDb)
    }

    deinit {
        levels.deallocate()
    }

    /// Takes one hop at time `now` in seconds and reports whether a column was published.
    @discardableResult
    public func consume(_ hop: UnsafeBufferPointer<Float>, now: TimeInterval) -> Bool {
        analyzer.push(hop)
        if let lastPublishAt, now - lastPublishAt < 1 / Self.maxPublishesPerSecond {
            return false
        }
        lastPublishAt = now
        analyzer.compute(into: levels)
        mailbox.publish(UnsafeBufferPointer(levels))
        return true
    }
}
