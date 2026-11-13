import Darwin
import Foundation
import UntunnelAudio

@main
struct UntunnelMain {
    /// What the command line asks for, before any work starts.
    enum Invocation: Equatable {
        case app
        case help
        case bench([String])
        case doctor([String])
        case download([String])
        case enhance([String])
        case snapshot([String])
        case setup([String])
        case uninstall([String])
        case quit(force: Bool)
        case usage(reason: String)
    }

    @MainActor
    static func main() {
        switch invocation(for: Array(CommandLine.arguments.dropFirst())) {
        case .app:
            UntunnelApp.main()
        case .help:
            printUsage()
        case .bench(let arguments):
            exit(Bench.run(arguments: arguments))
        case .doctor(let arguments):
            exit(Doctor.run(arguments: arguments))
        case .download(let arguments):
            exit(Download.run(arguments: arguments))
        case .enhance(let arguments):
            exit(Enhance.run(arguments: arguments))
        case .snapshot(let arguments):
            exit(Snapshot.run(arguments: arguments))
        case .setup(let arguments):
            exit(Setup.run(arguments: arguments))
        case .uninstall(let arguments):
            exit(Uninstall.run(arguments: arguments))
        case .quit(let force):
            exit(Quit.run(force: force))
        case .usage(let reason):
            standardError(reason)
            printUsage()
            exit(2)
        }
    }

    static func invocation(for arguments: [String]) -> Invocation {
        guard let command = arguments.first else {
            return .app
        }
        let rest = Array(arguments.dropFirst())
        switch command {
        case HearYourselfLaunch.argument where rest.isEmpty:
            return .app
        case "--help" where rest.isEmpty:
            return .help
        case "bench":
            return .bench(rest)
        case "doctor":
            return .doctor(rest)
        case "download":
            return .download(rest)
        case "enhance":
            return .enhance(rest)
        case "snapshot":
            return .snapshot(rest)
        case "setup":
            return .setup(rest)
        case "uninstall":
            return .uninstall(rest)
        case "quit":
            guard rest.isEmpty || rest == ["--force"] else {
                return .usage(reason: "quit takes only --force")
            }
            return .quit(force: rest == ["--force"])
        default:
            return .usage(reason: "unknown command '\(command)'")
        }
    }

    private static func printUsage() {
        standardError("Usage: untunnel                       open the menu bar app")
        standardError("       untunnel setup [--yes] [--driver] [--timings-json PATH]")
        Download.printUsage()
        Enhance.printUsage()
        standardError("       untunnel snapshot --window monitor|hear --state STATE [--out PATH]")
        standardError("       untunnel uninstall [--dry-run]")
        standardError("       untunnel quit [--force]")
        Bench.printUsage()
        Doctor.printUsage()
    }

    private static func standardError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// What `quit` needs from the machine, behind a protocol so a test never signals a process.
protocol QuitSystem {
    func runningPIDs() -> [pid_t]
    func inputClientNames() -> [String]
    func terminate(_ pid: pid_t)
    func isRunning(_ pid: pid_t) -> Bool
    func sleep(seconds: TimeInterval)
}

/// Stops the running menu bar app through the same signal its Quit item sends.
enum Quit {
    /// The bundle executable and the CLI binary are both ways to run the app.
    static let processNames = ["Untunnel", "untunnel"]
    /// How long a normal quit waits for the app to close before reporting a failure.
    static let terminationTimeout: TimeInterval = 5

    static func run(force: Bool) -> Int32 {
        let result = perform(force: force, system: LiveQuitSystem())
        result.output.write()
        return result.status
    }

    /// Refuses while another application is recording from the virtual microphone, because
    /// stopping the app would cut that recording off; `--force` is the explicit override.
    static func perform(
        force: Bool,
        system: any QuitSystem,
        timeout: TimeInterval = terminationTimeout
    ) -> (status: Int32, output: CommandOutput) {
        var output = CommandOutput()
        let targets = system.runningPIDs().filter { $0 != getpid() }
        guard !targets.isEmpty else {
            output.line("Untunnel is not running.")
            return (0, output)
        }

        if !force {
            let clients = system.inputClientNames()
            guard clients.isEmpty else {
                output.error(
                    "Untunnel Microphone is in use by \(clients.joined(separator: ", "))."
                )
                output.error("Fix: stop recording in that app, or run `untunnel quit --force`.")
                return (1, output)
            }
        }

        for pid in targets {
            system.terminate(pid)
        }
        guard !force else {
            return (0, output)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, targets.contains(where: system.isRunning) {
            system.sleep(seconds: 0.05)
        }
        let survivors = targets.filter(system.isRunning)
        guard survivors.isEmpty else {
            let listed = survivors.map(String.init).joined(separator: ", ")
            output.error("Untunnel did not stop (pids \(listed)); retry with --force")
            return (1, output)
        }
        return (0, output)
    }
}

struct LiveQuitSystem: QuitSystem {
    func runningPIDs() -> [pid_t] {
        Quit.processNames.flatMap(pids(named:))
    }

    func inputClientNames() -> [String] {
        let virtualMicUIDs: Set<String> = [
            VirtualMicDevices.inputUID,
            VirtualMicDevices.fallbackUID,
        ]
        return CoreAudioProcessSource().processes
            .filter {
                $0.pid != getpid()
                    && $0.isRunningInput
                    && $0.inputDeviceUIDs.contains(where: virtualMicUIDs.contains)
            }
            .map(\.displayName)
            .sorted()
    }

    func terminate(_ pid: pid_t) {
        kill(pid, SIGTERM)
    }

    func isRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    func sleep(seconds: TimeInterval) {
        usleep(UInt32(seconds * 1_000_000))
    }

    private func pids(named name: String) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        process.waitUntilExit()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: output, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0) }
    }
}
