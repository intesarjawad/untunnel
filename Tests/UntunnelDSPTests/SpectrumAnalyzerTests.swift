import Foundation
import Testing

@testable import UntunnelDSP

private func sine(
    hertz: Double,
    amplitude: Double,
    sampleRate: Int,
    count: Int = SpectrumAnalyzer.fftLength
) -> [Float] {
    (0..<count).map { Float(amplitude * sin(2 * .pi * hertz * Double($0) / Double(sampleRate))) }
}

private func levels(
    of samples: [Float],
    sampleRate: Int,
    rowCount: Int
) -> [Float] {
    let analyzer = SpectrumAnalyzer(sampleRate: sampleRate, rowCount: rowCount)
    let hop = sampleRate / 100
    samples.withUnsafeBufferPointer { buffer in
        for start in stride(from: 0, to: buffer.count, by: hop) {
            analyzer.push(
                UnsafeBufferPointer(rebasing: buffer[start..<min(start + hop, buffer.count)])
            )
        }
    }
    var result = [Float](repeating: 0, count: rowCount)
    result.withUnsafeMutableBufferPointer { analyzer.compute(into: $0) }
    return result
}

@Test
func axisPlacesTheEdgesAndSpacesOctavesEvenly() {
    let axis = LogFrequencyAxis.standard

    #expect(axis.position(of: 125) == 0)
    #expect(axis.position(of: 24_000) == 1)
    #expect(axis.position(of: 50) == 0)
    #expect(axis.position(of: 48_000) == 1)
    // log2(1000 / 125) / log2(24000 / 125) = 3 / 7.585
    #expect(abs(axis.position(of: 1_000) - 0.39551) < 1e-4)
    // each octave spans 1 / log2(192) of the axis
    let octave = 0.13184
    #expect(abs(axis.position(of: 2_000) - axis.position(of: 1_000) - octave) < 1e-4)
    #expect(abs(axis.position(of: 16_000) - axis.position(of: 8_000) - octave) < 1e-4)
}

@Test
func axisRowsFollowTheBoundariesAndClamp() {
    let axis = LogFrequencyAxis.standard

    #expect(axis.edgeHz(0, rowCount: 96) == 125)
    #expect(abs(axis.edgeHz(96, rowCount: 96) - 24_000) < 1e-6)
    #expect(axis.row(containing: 10, rowCount: 96) == 0)
    #expect(axis.row(containing: 30_000, rowCount: 96) == 95)
    // 0.39551 of 96 rows
    #expect(axis.row(containing: 1_000, rowCount: 96) == 37)
}

@Test
func axisLabelsTheOctaveMarksInKilohertz() {
    #expect(
        LogFrequencyAxis.labelledHz.map(LogFrequencyAxis.label(forHz:)) == [
            "1 kHz", "2 kHz", "4 kHz", "8 kHz", "16 kHz",
        ])
}

@Test
func aToneReadsItsAmplitudeInDecibelsInItsOwnRow() {
    let rowCount = 96
    // 1 kHz is bin 128 at 16 kHz with 2048 points; a sine of 0.5 is 20 log10(0.5) = -6.02 dB.
    let result = levels(
        of: sine(hertz: 1_000, amplitude: 0.5, sampleRate: 16_000),
        sampleRate: 16_000,
        rowCount: rowCount
    )
    let loudest = result.indices.max { result[$0] < result[$1] }

    #expect(loudest == LogFrequencyAxis.standard.row(containing: 1_000, rowCount: rowCount))
    #expect(abs(result[37] - (-6.02)) < 0.1)
    #expect(result[LogFrequencyAxis.standard.row(containing: 4_000, rowCount: rowCount)] < -70)
}

@Test
func rowsAboveTheNyquistRateReadSilence() {
    let result = levels(
        of: sine(hertz: 1_000, amplitude: 0.5, sampleRate: 16_000),
        sampleRate: 16_000,
        rowCount: 96
    )

    #expect(result[LogFrequencyAxis.standard.row(containing: 16_000, rowCount: 96)] == -120)
    #expect(result[95] == -120)
}

@Test
func silenceReadsTheFloorInEveryRow() {
    let result = levels(of: [Float](repeating: 0, count: 2_048), sampleRate: 48_000, rowCount: 96)

    #expect(result.allSatisfy { $0 == SpectrumAnalyzer.silenceDb })
}

@Test
func publisherPublishesAtMostThirtyColumnsASecond() {
    let analyzer = SpectrumAnalyzer(sampleRate: 16_000, rowCount: 8)
    let mailbox = SpectrumMailbox(rowCount: 8)
    let publisher = SpectrumPublisher(analyzer: analyzer, mailbox: mailbox)
    let hop = [Float](repeating: 0.1, count: 160)

    var published = 0
    for index in 0..<100 {
        let took = hop.withUnsafeBufferPointer {
            publisher.consume($0, now: Double(index) / 100)
        }
        published += took ? 1 : 0
    }

    // Ten-millisecond hops against a 33.3 ms gate publish at 0, 40, 80, ... 960 ms.
    #expect(published == 25)
    #expect(mailbox.published == 25)
}

@Test
func mailboxKeepsTheNewestColumnsAndCountsWhatWasLost() {
    let mailbox = SpectrumMailbox(rowCount: 2, capacity: 3)
    for value in 0..<5 {
        let column: [Float] = [Float(value), Float(value) + 0.5]
        column.withUnsafeBufferPointer { mailbox.publish($0) }
    }

    let all = mailbox.columns(since: 0)
    #expect(all.levels == [2, 2.5, 3, 3.5, 4, 4.5])
    #expect(all.position == 5)
    #expect(all.dropped == 2)

    let recent = mailbox.columns(since: 3)
    #expect(recent.levels == [3, 3.5, 4, 4.5])
    #expect(recent.dropped == 0)

    #expect(mailbox.columns(since: 5).levels.isEmpty)
}
