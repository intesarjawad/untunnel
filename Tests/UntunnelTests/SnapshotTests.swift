import Foundation
import Testing

@testable import Untunnel

private func temporaryFile(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent(name)
}

private func isPNG(_ url: URL) -> Bool {
    let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    return (try? Data(contentsOf: url))?.prefix(8).elementsEqual(signature) == true
}

private func parse(_ arguments: [String]) throws -> SnapshotTarget {
    try SnapshotOptions(arguments: arguments).target
}

@Test
func snapshotOptionsReadTheHearWindowAndOneState() throws {
    #expect(try parse(["--window", "hear", "--state", "ready"]) == .hear(.ready))
}

@Test
func snapshotRejectsAnUnknownState() {
    #expect(throws: UserFacingError.self) {
        try SnapshotOptions(arguments: ["--window", "hear", "--state", "paused"])
    }
    #expect(throws: UserFacingError.self) {
        try SnapshotOptions(
            arguments: ["--window", "monitor", "--state", "ready", "--out", "m.png"]
        )
    }
}

@Test
func snapshotRejectsAnotherWindow() {
    #expect(throws: UserFacingError.self) {
        try SnapshotOptions(arguments: ["--window", "settings", "--state", "idle"])
    }
}

@Test
func snapshotRejectsOptionsThatNeedTheMonitorWindow() {
    for extra in [["--out", "x.png"], ["--reduced-motion"], ["--path", "mic"]] {
        #expect(throws: UserFacingError.self) {
            try SnapshotOptions(arguments: ["--window", "hear", "--state", "idle"] + extra)
        }
    }
    #expect(throws: UserFacingError.self) {
        try SnapshotOptions(arguments: ["--window", "menu", "--bench-draw", "5"])
    }
}

@Test
func monitorOptionsDefaultToTheLiveMicrophone() throws {
    let target = try parse(["--window", "monitor", "--out", "m.png"])

    #expect(
        target
            == .monitor(
                MonitorSnapshot(
                    state: .live,
                    path: .mic,
                    incomingInput: nil,
                    reducedMotion: false,
                    benchDraw: nil,
                    out: "m.png"
                )
            )
    )
}

@Test
func monitorOptionsReadEveryFlag() throws {
    let target = try parse([
        "--window", "monitor", "--state", "bypassed", "--path", "incoming",
        "--incoming-input", "call.wav", "--reduced-motion", "--bench-draw", "600",
    ])

    #expect(
        target
            == .monitor(
                MonitorSnapshot(
                    state: .bypassed,
                    path: .incoming,
                    incomingInput: "call.wav",
                    reducedMotion: true,
                    benchDraw: 600,
                    out: nil
                )
            )
    )
}

@Test
func monitorOptionsRejectInconsistentFlags() {
    let rejected: [[String]] = [
        ["--window", "monitor"],
        ["--window", "monitor", "--out", "m.png", "--path", "incoming"],
        ["--window", "monitor", "--out", "m.png", "--incoming-input", "call.wav"],
        ["--window", "monitor", "--out", "m.png", "--path", "speaker"],
        ["--window", "monitor", "--bench-draw", "0"],
        ["--window", "monitor", "--bench-draw", "many"],
        ["--window", "monitor", "--out"],
        ["--window", "monitor", "--out", "m.png", "--colour", "red"],
    ]
    for arguments in rejected {
        #expect(throws: UserFacingError.self) {
            try SnapshotOptions(arguments: arguments)
        }
    }
}

@MainActor
@Test
func snapshotRendersEveryHearState() {
    #expect(HearYourselfState.allCases.count == 5)

    for state in HearYourselfState.allCases {
        let text = HearYourselfScreen.demo(state: state).text()
        #expect(text.contains("State: \(state.rawValue)"))
        #expect(text.contains(state.summary))
        #expect(Snapshot.run(arguments: ["--window", "hear", "--state", state.rawValue]) == 0)
    }
}

@Test
func snapshotShowsBothSpectrogramsOnceATakeExists() {
    let ready = HearYourselfScreen.demo(state: .ready).text()
    #expect(ready.contains("Before (raw input)"))
    #expect(ready.contains("After (restored)"))
    #expect(ready.contains("Shelves:"))
    #expect(ready.contains("Playing: Before (raw input)"))

    let idle = HearYourselfScreen.demo(state: .idle).text()
    #expect(idle.contains("Shelves:") == false)
}

@Test
func snapshotNamesTheNarrowbandNote() {
    let text = HearYourselfScreen.demo(state: .narrowband).text()

    #expect(text.contains(HeadsetRelease.narrowbandNote))
    #expect(text.contains("Playing: Before (raw input)"))
}

@MainActor
@Test
func snapshotWritesAPNGForEveryMonitorState() {
    for state in MonitorState.allCases {
        let file = temporaryFile("\(state.rawValue).png")
        defer {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }

        let status = Snapshot.run(
            arguments: ["--window", "monitor", "--state", state.rawValue, "--out", file.path]
        )

        #expect(status == 0)
        #expect(isPNG(file))
    }
}

@MainActor
@Test
func snapshotWritesAReducedMotionMonitor() {
    let file = temporaryFile("reduced.png")
    defer {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    let status = Snapshot.run(
        arguments: ["--window", "monitor", "--reduced-motion", "--out", file.path]
    )

    #expect(status == 0)
    #expect(isPNG(file))
}

@MainActor
@Test
func snapshotRendersTheIncomingPairFromARecordedCall() throws {
    let directory = temporaryFile("call").deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }
    let call = (0..<16_000).map { Float(0.3 * sin(2 * .pi * 500 * Double($0) / 16_000)) }
    let input = directory.appendingPathComponent("call.wav")
    try WAVFile(sampleRate: 16_000, samples: call).encoded().write(to: input)
    let out = directory.appendingPathComponent("incoming.png")

    let status = Snapshot.run(
        arguments: [
            "--window", "monitor", "--path", "incoming",
            "--incoming-input", input.path, "--out", out.path,
        ]
    )

    #expect(status == 0)
    #expect(isPNG(out))
}

@MainActor
@Test
func snapshotRefusesAnUnreadableOrOddRateCall() throws {
    let directory = temporaryFile("call").deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: directory)
    }
    let out = directory.appendingPathComponent("incoming.png").path
    let odd = directory.appendingPathComponent("odd.wav")
    try WAVFile(sampleRate: 44_110, samples: [0, 0.1, 0.2]).encoded().write(to: odd)

    for input in [directory.appendingPathComponent("missing.wav").path, odd.path] {
        let status = Snapshot.run(
            arguments: [
                "--window", "monitor", "--path", "incoming", "--incoming-input", input,
                "--out", out,
            ]
        )
        #expect(status == 2)
    }
    #expect(FileManager.default.fileExists(atPath: out) == false)
}

@MainActor
@Test
func snapshotCannotRenderTheMenuBecauseItIsAnNSMenu() {
    #expect(Snapshot.run(arguments: ["--window", "menu", "--out", "menu.png"]) == 2)
}

@MainActor
@Test
func benchDrawTimesEveryFrameItRenders() throws {
    let screen = MonitorScreen.replay(
        state: .live,
        path: .mic,
        motion: MonitorMotion(reduceMotion: false),
        take: HearYourselfDemo.take()
    )

    let times = try Snapshot.drawTimes(screen: screen, frames: 5)

    #expect(times.milliseconds.count == 5)
    #expect(times.milliseconds.allSatisfy { $0 > 0 })
    #expect(times.summary.hasPrefix("draw 5 frames: p50 "))
    #expect(Snapshot.run(arguments: ["--window", "monitor", "--bench-draw", "3"]) == 0)
}

@Test
func drawTimesUseNearestRankPercentiles() {
    let times = DrawTimes(milliseconds: (1...100).map(Double.init).reversed())

    #expect(times.percentile(0.5) == 50)
    #expect(times.percentile(0.99) == 99)
    #expect(
        times.summary
            == "draw 100 frames: p50 50.000 ms, p95 95.000 ms, p99 99.000 ms, max 100.000 ms"
    )
}
