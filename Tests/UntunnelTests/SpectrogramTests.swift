import CoreGraphics
import Foundation
import Testing

@testable import Untunnel

private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
    let data = image.dataProvider?.data as Data? ?? Data()
    let offset = y * image.bytesPerRow + x * 4
    return Array(data[offset..<(offset + 3)])
}

private func history(
    _ mode: SpectrogramHistory.Mode,
    appending columns: [Float]
) -> SpectrogramHistory {
    var history = SpectrogramHistory(rowCount: 1, columnCount: 3, mode: mode)
    history.append(columns)
    return history
}

private func shown(_ history: SpectrogramHistory) -> [Float] {
    (0..<history.columnCount).map { history.db(column: $0, row: 0) }
}

@Test
func scaleMapsTheRangeOntoZeroToOne() {
    #expect(SpectrogramScale.level(db: -90) == 0)
    #expect(SpectrogramScale.level(db: 0) == 1)
    #expect(SpectrogramScale.level(db: -45) == 0.5)
    #expect(SpectrogramScale.level(db: -120) == 0)
    #expect(SpectrogramScale.level(db: 6) == 1)
}

@Test
func paletteRunsFromDarkBlueToPaleYellow() {
    let darkest = SpectrogramScale.rgb(level: 0)
    let brightest = SpectrogramScale.rgb(level: 1)

    #expect([darkest.red, darkest.green, darkest.blue] == [5, 5, 46])
    #expect([brightest.red, brightest.green, brightest.blue] == [252, 245, 158])
}

@Test
func beforeAndAfterPanesPaintTheSameLevelTheSameColour() throws {
    let before = history(.scrolling, appending: [-30, -30, -30])
    let after = history(.sweeping, appending: [-30, -30, -30])

    let first = try #require(SpectrogramImage.make(before))
    let second = try #require(SpectrogramImage.make(after))
    // -30 dB is level 2/3, which sits two thirds of the way between the third and fourth stop.
    #expect(pixel(first, x: 1, y: 0) == [223, 104, 50])
    #expect(pixel(second, x: 1, y: 0) == pixel(first, x: 1, y: 0))
}

@Test
func imageDrawsTheLowestFrequencyAtTheBottom() throws {
    var history = SpectrogramHistory(rowCount: 2, columnCount: 1, mode: .sweeping)
    history.append([0, -90])

    let image = try #require(SpectrogramImage.make(history))
    let bright = SpectrogramScale.rgb(level: 1)

    #expect(pixel(image, x: 0, y: 1) == [bright.red, bright.green, bright.blue])
    #expect(pixel(image, x: 0, y: 0) == [5, 5, 46])
}

@Test
func scrollingHistoryShiftsOlderColumnsLeft() {
    #expect(shown(history(.scrolling, appending: [-10, -20])) == [-90, -10, -20])
    #expect(shown(history(.scrolling, appending: [-10, -20, -30, -40])) == [-20, -30, -40])
}

@Test
func sweepingHistoryKeepsEveryColumnWhereItWasWritten() {
    #expect(shown(history(.sweeping, appending: [-10, -20])) == [-10, -20, -90])
    #expect(shown(history(.sweeping, appending: [-10, -20, -30, -40])) == [-40, -20, -30])
}

@Test
func peakIsMissingUntilAColumnArrives() {
    #expect(history(.scrolling, appending: []).peakDb == nil)
    #expect(history(.scrolling, appending: [-40, -12]).peakDb == -12)
}

@Test
func replayedToneLightsTheRowOfItsFrequency() {
    let rate = 16_000
    let tone = (0..<rate).map { Float(0.5 * sin(2 * .pi * 1_000 * Double($0) / Double(rate))) }

    let replay = SpectrogramHistory.replay(
        tone,
        sampleRate: rate,
        rowCount: 96,
        columnCount: 40,
        mode: .scrolling
    )

    // One second at 10 ms hops and a 33.3 ms gate publishes 25 columns.
    #expect(replay.columnsReceived == 25)
    #expect(abs(replay.db(column: 39, row: 37) - (-6.02)) < 0.5)
    #expect(replay.db(column: 39, row: 60) < -70)
}

@Test
func spectrogramAnnouncesItsLoudestLevelOrThatNothingArrived() {
    #expect(
        SpectrogramView.accessibilityText(title: "Microphone before", peakDb: nil)
            == "Microphone before spectrogram, no audio yet"
    )
    #expect(
        SpectrogramView.accessibilityText(title: "Microphone after", peakDb: -12.4)
            == "Microphone after spectrogram, loudest level -12 decibels"
    )
}
