import CoreGraphics
import Foundation
import SwiftUI
import UntunnelAudio
import UntunnelDSP

/// The decibel range and colour ramp every spectrogram uses.
///
/// There is one scale for the whole window, so a before pane and an after pane show the same
/// level in the same colour; the comparison is only honest while that holds.
enum SpectrogramScale {
    /// Quieter than this reads as the darkest colour.
    static let floorDb: Float = -90
    /// A full-scale sine at its peak.
    static let ceilingDb: Float = 0

    /// Maps decibels onto 0...1, clamped to the range.
    static func level(db: Float) -> Float {
        min(1, max(0, (db - floorDb) / (ceilingDb - floorDb)))
    }

    /// Dark blue through magenta and orange to pale yellow, so brightness rises with level.
    private static let stops: [(red: Float, green: Float, blue: Float)] = [
        (0.02, 0.02, 0.18),
        (0.30, 0.05, 0.45),
        (0.70, 0.18, 0.35),
        (0.96, 0.52, 0.12),
        (0.99, 0.96, 0.62),
    ]

    static func rgb(level: Float) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let clamped = min(1, max(0, level)) * Float(stops.count - 1)
        let lower = min(stops.count - 2, Int(clamped))
        let fraction = clamped - Float(lower)
        func mix(_ low: Float, _ high: Float) -> UInt8 {
            UInt8(((low + (high - low) * fraction) * 255).rounded())
        }
        return (
            mix(stops[lower].red, stops[lower + 1].red),
            mix(stops[lower].green, stops[lower + 1].green),
            mix(stops[lower].blue, stops[lower + 1].blue)
        )
    }
}

/// The spectrum columns one pane shows, as decibels per row.
///
/// Scrolling shifts older columns left so the newest sits at the right edge. Sweeping keeps every
/// column where it was written and moves the write position instead, which is what reduced
/// motion needs: the picture never slides.
struct SpectrogramHistory: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case scrolling
        case sweeping
    }

    let rowCount: Int
    let columnCount: Int
    let mode: Mode
    private var levels: [Float]
    private var nextSlot = 0
    private(set) var columnsReceived = 0

    init(rowCount: Int, columnCount: Int, mode: Mode) {
        precondition(rowCount > 0 && columnCount > 0, "a history needs rows and columns")
        self.rowCount = rowCount
        self.columnCount = columnCount
        self.mode = mode
        levels = [Float](repeating: SpectrogramScale.floorDb, count: rowCount * columnCount)
    }

    /// Adds columns given as flat levels, oldest first, `rowCount` values each.
    mutating func append(_ flat: [Float]) {
        precondition(flat.count % rowCount == 0, "columns need one level per row")
        for start in stride(from: 0, to: flat.count, by: rowCount) {
            let base = nextSlot * rowCount
            levels.replaceSubrange(base..<(base + rowCount), with: flat[start..<(start + rowCount)])
            nextSlot = (nextSlot + 1) % columnCount
            columnsReceived += 1
        }
    }

    /// The level at a display column (0 is the left edge) and row (0 is the lowest frequency).
    func db(column: Int, row: Int) -> Float {
        let slot = mode == .scrolling ? (nextSlot + column) % columnCount : column
        return levels[slot * rowCount + row]
    }

    /// The loudest level shown, or nil before any column arrived.
    var peakDb: Float? {
        columnsReceived == 0 ? nil : levels.max()
    }

    /// Runs `samples` through the analyzer hop by hop, the way the pipeline feeds it.
    static func replay(
        _ samples: [Float],
        sampleRate: Int,
        rowCount: Int,
        columnCount: Int,
        mode: Mode
    ) -> SpectrogramHistory {
        let analyzer = SpectrumAnalyzer(sampleRate: sampleRate, rowCount: rowCount)
        let mailbox = SpectrumMailbox(rowCount: rowCount)
        let publisher = SpectrumPublisher(analyzer: analyzer, mailbox: mailbox)
        var history = SpectrogramHistory(rowCount: rowCount, columnCount: columnCount, mode: mode)
        let hopFrames = sampleRate * Pipeline.hopMilliseconds / 1_000
        var position = 0
        samples.withUnsafeBufferPointer { buffer in
            for (hop, start) in stride(from: 0, to: buffer.count, by: hopFrames).enumerated() {
                let end = min(start + hopFrames, buffer.count)
                publisher.consume(
                    UnsafeBufferPointer(rebasing: buffer[start..<end]),
                    now: Double(hop * Pipeline.hopMilliseconds) / 1_000
                )
                let drained = mailbox.columns(since: position)
                position = drained.position
                history.append(drained.levels)
            }
        }
        return history
    }
}

/// Renders a history to pixels with the shared scale.
enum SpectrogramImage {
    static func make(_ history: SpectrogramHistory) -> CGImage? {
        let width = history.columnCount
        let height = history.rowCount
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for column in 0..<width {
            for row in 0..<height {
                let level = SpectrogramScale.level(db: history.db(column: column, row: row))
                let color = SpectrogramScale.rgb(level: level)
                let offset = ((height - 1 - row) * width + column) * 4
                pixels[offset] = color.red
                pixels[offset + 1] = color.green
                pixels[offset + 2] = color.blue
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else {
            return nil
        }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

/// One spectrogram with its log-frequency labels.
struct SpectrogramView: View {
    static let height: CGFloat = 110
    private static let labelWidth: CGFloat = 46

    let title: String
    let history: SpectrogramHistory

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            axisLabels
                .frame(width: Self.labelWidth, height: Self.height)
            picture
                .frame(height: Self.height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText(title: title, peakDb: history.peakDb))
    }

    @ViewBuilder
    private var picture: some View {
        if let image = SpectrogramImage.make(history) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.none)
        } else {
            Color.black
        }
    }

    private var axisLabels: some View {
        ZStack(alignment: .topTrailing) {
            ForEach(LogFrequencyAxis.labelledHz, id: \.self) { hertz in
                Text(LogFrequencyAxis.label(forHz: hertz))
                    .font(.caption2)
                    .monospacedDigit()
                    .position(
                        x: Self.labelWidth - 18,
                        y: Self.height
                            * (1 - LogFrequencyAxis.standard.position(of: Double(hertz)))
                    )
            }
        }
    }

    /// What VoiceOver reads for a spectrogram, which is otherwise only colour.
    nonisolated static func accessibilityText(title: String, peakDb: Float?) -> String {
        guard let peakDb else {
            return "\(title) spectrogram, no audio yet"
        }
        return "\(title) spectrogram, loudest level \(Int(peakDb.rounded())) decibels"
    }
}
