import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UntunnelAudio

/// What a snapshot invocation renders.
enum SnapshotTarget: Equatable {
    case hear(HearYourselfState)
    case monitor(MonitorSnapshot)
    case menu
}

/// The monitor options a snapshot needs, already checked against each other.
struct MonitorSnapshot: Equatable {
    var state: MonitorState
    var path: MonitorPath
    var incomingInput: String?
    var reducedMotion: Bool
    var benchDraw: Int?
    var out: String?
}

/// A snapshot invocation that cannot be parsed.
struct SnapshotOptions: Equatable {
    var target: SnapshotTarget

    init(arguments: [String]) throws {
        var window: String?
        var stateName: String?
        var values: [String: String] = [:]
        var reducedMotion = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--reduced-motion":
                reducedMotion = true
                index += 1
            case "--window", "--state", "--out", "--path", "--incoming-input", "--bench-draw":
                guard index + 1 < arguments.count else {
                    throw UserFacingError.usage("\(argument) needs a value")
                }
                let value = arguments[index + 1]
                if argument == "--window" {
                    window = value
                } else if argument == "--state" {
                    stateName = value
                } else {
                    values[argument] = value
                }
                index += 2
            default:
                throw UserFacingError.usage(
                    "unknown snapshot option '\(argument)'"
                )
            }
        }
        guard let window else {
            throw UserFacingError.usage("snapshot needs --window monitor|hear|menu")
        }
        let given = values.keys.sorted() + (reducedMotion ? ["--reduced-motion"] : [])
        switch window {
        case "hear":
            if let option = given.first {
                throw UserFacingError.usage("\(option) is not used with --window hear")
            }
            guard let stateName else {
                throw UserFacingError.usage("snapshot needs --state")
            }
            guard let state = HearYourselfState(rawValue: stateName) else {
                throw UserFacingError.usage("unknown hear state '\(stateName)'")
            }
            target = .hear(state)
        case "menu":
            if let option = given.first(where: { $0 != "--out" }) {
                throw UserFacingError.usage("\(option) is not used with --window menu")
            }
            target = .menu
        case "monitor":
            target = .monitor(
                try Self.monitor(
                    stateName: stateName,
                    values: values,
                    reducedMotion: reducedMotion
                )
            )
        default:
            throw UserFacingError.usage("unknown snapshot window '\(window)'")
        }
    }

    private static func monitor(
        stateName: String?,
        values: [String: String],
        reducedMotion: Bool
    ) throws -> MonitorSnapshot {
        var state = MonitorState.live
        if let stateName {
            guard let parsed = MonitorState(rawValue: stateName) else {
                throw UserFacingError.usage("unknown monitor state '\(stateName)'")
            }
            state = parsed
        }
        var path = MonitorPath.mic
        if let name = values["--path"] {
            guard let parsed = MonitorPath(rawValue: name) else {
                throw UserFacingError.usage("--path needs mic or incoming, not '\(name)'")
            }
            path = parsed
        }
        var benchDraw: Int?
        if let count = values["--bench-draw"] {
            guard let frames = Int(count), frames > 0 else {
                throw UserFacingError.usage("--bench-draw needs a positive frame count")
            }
            benchDraw = frames
        }
        let incomingInput = values["--incoming-input"]
        switch (path, incomingInput) {
        case (.incoming, nil):
            throw UserFacingError.usage("--path incoming needs --incoming-input PATH")
        case (.mic, .some):
            throw UserFacingError.usage("--incoming-input needs --path incoming")
        default:
            break
        }
        let out = values["--out"]
        guard out != nil || benchDraw != nil else {
            throw UserFacingError.usage("snapshot needs --out PATH or --bench-draw N")
        }
        return MonitorSnapshot(
            state: state,
            path: path,
            incomingInput: incomingInput,
            reducedMotion: reducedMotion,
            benchDraw: benchDraw,
            out: out
        )
    }
}

/// Renders one window state without opening a window or the microphone.
enum Snapshot {
    @MainActor
    static func run(arguments: [String]) -> Int32 {
        let options: SnapshotOptions
        do {
            options = try SnapshotOptions(arguments: arguments)
        } catch let error as UserFacingError {
            var output = CommandOutput()
            output.error(error)
            output.write()
            printUsage()
            return 2
        } catch {
            var output = CommandOutput()
            output.error(.unexpected(String(describing: error)))
            output.write()
            return 1
        }

        switch options.target {
        case .hear(let state):
            print(HearYourselfScreen.demo(state: state).text())
            return 0
        case .menu:
            var output = CommandOutput()
            output.error(
                "The menu is an NSMenu, which a snapshot cannot render; capture it on screen."
            )
            output.write()
            return 2
        case .monitor(let monitor):
            return renderMonitor(monitor)
        }
    }

    static func printUsage() {
        let hear = HearYourselfState.allCases.map(\.rawValue).joined(separator: "|")
        let monitor = MonitorState.allCases.map(\.rawValue).joined(separator: "|")
        let message =
            """
            Usage: untunnel snapshot --window hear --state <\(hear)>
                   untunnel snapshot --window monitor [--state <\(monitor)>] \
            [--path mic|incoming] [--incoming-input PATH] [--reduced-motion] \
            (--out PATH | --bench-draw N)

            """
        FileHandle.standardError.write(Data(message.utf8))
    }

    /// Draws the monitor's real view tree to a PNG, or times spectrogram frames.
    @MainActor
    private static func renderMonitor(_ options: MonitorSnapshot) -> Int32 {
        var output = CommandOutput()
        do {
            let screen =
                MonitorScreen.replay(
                    state: options.state,
                    path: options.path,
                    motion: MonitorMotion(reduceMotion: options.reducedMotion),
                    take: try take(for: options)
                )
            if let frames = options.benchDraw {
                output.line(try drawTimes(screen: screen, frames: frames).summary)
            } else if let path = options.out {
                try writePNG(MonitorView(screen: screen).background(.background), to: path)
            }
            output.write()
            return 0
        } catch let error as UserFacingError {
            output.error(error)
            output.write()
            return 2
        } catch {
            output.error(.unexpected(String(describing: error)))
            output.write()
            return 1
        }
    }

    private static func take(for options: MonitorSnapshot) throws -> HearYourselfTake {
        guard let path = options.incomingInput else {
            return HearYourselfDemo.take()
        }
        let wav: WAVFile
        do {
            wav = try WAVFile(decoding: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            throw UserFacingError.usage("--incoming-input '\(path)': \(error)")
        }
        guard wav.sampleRate % Pipeline.hopsPerSecond == 0 else {
            throw UserFacingError.usage(
                "--incoming-input '\(path)' is \(wav.sampleRate) Hz, which does not make "
                    + "a whole \(Pipeline.hopMilliseconds) ms hop"
            )
        }
        return HearYourselfTake.make(
            raw: wav.samples,
            inputRate: wav.sampleRate,
            tierRate: wav.sampleRate,
            restorer: DemoShelfRestorer(hopFrames: wav.sampleRate / Pipeline.hopsPerSecond)
        )
    }

    @MainActor
    private static func writePNG(_ view: some View, to path: String) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else {
            throw UserFacingError.unexpected("the window rendered no image")
        }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            throw UserFacingError.unexpected("'\(path)' cannot be written")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw UserFacingError.unexpected("'\(path)' cannot be written")
        }
    }

    /// Renders `frames` scrolling spectrogram frames off-screen, one new column each.
    @MainActor
    static func drawTimes(screen: MonitorScreen, frames: Int) throws -> DrawTimes {
        guard let source = screen.panes.first?.input else {
            throw UserFacingError.unexpected("the screen has no spectrogram to draw")
        }
        var history = SpectrogramHistory(
            rowCount: source.rowCount,
            columnCount: source.columnCount,
            mode: .scrolling
        )
        let renderer = ImageRenderer(
            content: SpectrogramView(title: "Benchmark", history: history)
        )
        var milliseconds: [Double] = []
        milliseconds.reserveCapacity(frames)
        for frame in 0..<frames {
            let column = frame % source.columnCount
            history.append((0..<source.rowCount).map { source.db(column: column, row: $0) })
            renderer.content = SpectrogramView(title: "Benchmark", history: history)
            let began = DispatchTime.now().uptimeNanoseconds
            let image = renderer.cgImage
            let ended = DispatchTime.now().uptimeNanoseconds
            guard image != nil else {
                throw UserFacingError.unexpected("frame \(frame) rendered no image")
            }
            milliseconds.append(Double(ended - began) / 1_000_000)
        }
        return DrawTimes(milliseconds: milliseconds)
    }
}

/// Draw times for a run of frames, summarised by nearest-rank percentiles.
struct DrawTimes: Equatable {
    let milliseconds: [Double]

    func percentile(_ fraction: Double) -> Double {
        Bench.percentile(milliseconds.sorted(), fraction)
    }

    var summary: String {
        let sorted = milliseconds.sorted()
        return String(
            format: "draw %d frames: p50 %.3f ms, p95 %.3f ms, p99 %.3f ms, max %.3f ms",
            sorted.count,
            Bench.percentile(sorted, 0.5),
            Bench.percentile(sorted, 0.95),
            Bench.percentile(sorted, 0.99),
            sorted.last ?? 0
        )
    }
}
