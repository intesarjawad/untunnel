import Darwin
import Foundation
import UntunnelAudio

/// The paths Untunnel installs, all derived from one home directory.
///
/// `all` is the single list the uninstall command and the documentation copy, so a new file
/// cannot be written without also being removable.
struct InstalledPaths: Equatable {
    let home: URL

    var app: URL {
        home.appendingPathComponent("Applications/Untunnel.app")
    }

    var executable: URL {
        app.appendingPathComponent("Contents/MacOS/Untunnel")
    }

    var bundledDriver: URL {
        app.appendingPathComponent("Contents/Resources/Untunnel.driver")
    }

    var driver: URL {
        URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/Untunnel.driver")
    }

    var loginAgent: URL {
        home.appendingPathComponent("Library/LaunchAgents/\(LoginAgent.fileName)")
    }

    var support: URL {
        home.appendingPathComponent("Library/Application Support/Untunnel")
    }

    var tierReport: URL {
        support.appendingPathComponent("bench.json")
    }

    var models: URL {
        support.appendingPathComponent("models")
    }

    /// The active model: a link to one directory under `models`.
    var model: URL {
        support.appendingPathComponent("model")
    }

    var modelManifest: URL {
        model.appendingPathComponent("manifest.json")
    }

    var preferences: URL {
        support.appendingPathComponent("preferences.json")
    }

    var all: [URL] {
        [app, loginAgent, support, driver]
    }

    static var all: [URL] {
        current.all
    }

    static var current: InstalledPaths {
        InstalledPaths(home: FileManager.default.homeDirectoryForCurrentUser)
    }
}

/// The login item, a plain property list because its registered path can then be read back.
enum LoginAgent {
    static let label = "com.intesarjawad.untunnel"
    static let fileName = "com.intesarjawad.untunnel.plist"

    static func program(for paths: InstalledPaths) -> String {
        paths.app.appendingPathComponent("Contents/MacOS/Untunnel").path
    }

    static func contents(program: String) throws -> Data {
        let propertyList: [String: Any] = [
            "Label": label,
            "ProgramArguments": [program],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
    }

    static func write(paths: InstalledPaths, program: String? = nil) throws {
        let url = paths.loginAgent
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents(program: program ?? self.program(for: paths)).write(
            to: url,
            options: .atomic
        )
    }

    static func remove(paths: InstalledPaths) throws {
        if FileManager.default.fileExists(atPath: paths.loginAgent.path) {
            try FileManager.default.removeItem(at: paths.loginAgent)
        }
    }

    static func isEnabled(paths: InstalledPaths) -> Bool {
        FileManager.default.fileExists(atPath: paths.loginAgent.path)
    }

    static func setEnabled(_ enabled: Bool, paths: InstalledPaths) throws {
        if enabled {
            try write(paths: paths)
        } else {
            try remove(paths: paths)
        }
    }

    static func programArgument(paths: InstalledPaths) -> String? {
        guard
            let data = try? Data(contentsOf: paths.loginAgent),
            let propertyList = try? PropertyListSerialization.propertyList(
                from: data,
                format: nil
            ) as? [String: Any],
            let arguments = propertyList["ProgramArguments"] as? [String]
        else {
            return nil
        }
        return arguments.first
    }

    /// Repairs a login item left by an older or differently located copy of the app.
    ///
    /// A launch must not fail because the login item cannot be rewritten, so the repair is
    /// best effort and the next setup run reports a real permission problem.
    static func reconcile(paths: InstalledPaths) {
        guard isEnabled(paths: paths) else {
            return
        }
        let expected = program(for: paths)
        guard programArgument(paths: paths) != expected else {
            return
        }
        try? write(paths: paths, program: expected)
    }
}

/// A setup invocation that cannot be parsed.
struct SetupOptions: Equatable {
    var yes = false
    var driver = false
    var timingsPath: String?

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--yes":
                yes = true
                index += 1
            case "--driver":
                driver = true
                index += 1
            case "--timings-json":
                let next = index + 1
                guard next < arguments.count else {
                    throw UserFacingError.usage("--timings-json needs a path")
                }
                timingsPath = arguments[next]
                index = next + 1
            default:
                throw UserFacingError.usage("unknown setup option '\(argument)'")
            }
        }
    }
}

protocol SetupClock {
    func now() -> TimeInterval
}

struct SystemSetupClock: SetupClock {
    func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

enum ApplicationLinkKind: Equatable {
    case missing
    case link
    case bundle
}

enum DriverInstallError: Error, Equatable {
    case doesNotLoad
}

enum SetupSystemError: Error, Equatable {
    case homebrewMissing
    case blackHoleInstallFailed
}

/// Everything setup touches on the machine.
///
/// The driver copy, the audio daemon restart and the app launch all live behind this protocol,
/// so the command's logic and its tests never install anything or prompt for a password.
protocol SetupSystem: AnyObject {
    var paths: InstalledPaths { get }
    var isAppleSilicon: Bool { get }
    var macOSMajorVersion: Int { get }
    var homebrewPrefix: URL? { get }
    var launchedFromInstalledApp: Bool { get }

    func driverVersionInSystem() -> String?
    func driverVersionInBundle() -> String?
    func runningInputClientNames() -> [String]
    func installOwnDriver() throws
    func installBlackHole() throws
    /// Downloads and verifies the pinned model unless it is already in place; `note` prints a
    /// line at once, so the size and licence appear before the download starts.
    func ensureModel(note: (String) -> Void) throws -> String

    func ensureTierReport() throws -> String
    func applicationLinkKind() -> ApplicationLinkKind
    func linkApplication(source: URL, destination: URL) throws
    func loginAgentProgram() -> String?
    func writeLoginAgent(program: String) throws
    func isApplicationRunning() -> Bool
    func openApplication() throws
    func sleep(seconds: TimeInterval)
    func confirm(_ question: String) -> Bool
}

struct SetupResult: Equatable {
    let status: Int32
    let output: CommandOutput
    let timings: [StepTiming]
}

/// Installs or upgrades Untunnel, printing one timed line per step.
enum Setup {
    static let stepCount = 7

    static func run(arguments: [String]) -> Int32 {
        let result = perform(
            arguments: arguments,
            system: LiveSetupSystem(),
            clock: SystemSetupClock(),
            echo: { print($0) }
        )
        FileHandle.standardError.write(Data(result.output.errorText.utf8))
        return result.status
    }

    /// Runs every step; `echo` receives each output line as it is produced, because a download
    /// or a password prompt must not wait behind lines that are only printed at the end.
    static func perform(
        arguments: [String],
        system: any SetupSystem,
        clock: any SetupClock,
        echo: @escaping (String) -> Void = { _ in }
    ) -> SetupResult {
        let recorder = StepRecorder(clock: clock, echo: echo)
        let options: SetupOptions
        do {
            options = try SetupOptions(arguments: arguments)
        } catch let error as UserFacingError {
            recorder.output.error(error)
            return SetupResult(status: 2, output: recorder.output, timings: [])
        } catch {
            recorder.output.error(.unexpected(String(describing: error)))
            return SetupResult(status: 1, output: recorder.output, timings: [])
        }

        guard options.yes || system.confirm("Continue?") else {
            recorder.line("Setup cancelled.")
            return SetupResult(status: 0, output: recorder.output, timings: [])
        }

        recorder.line("Untunnel setup")
        recorder.line()

        do {
            try recorder.step(1, "Check this Mac") { _ in
                guard system.isAppleSilicon else {
                    throw UserFacingError.unsupportedIntel
                }
                guard system.macOSMajorVersion >= 15 else {
                    throw UserFacingError.unsupportedMacOS
                }
                guard system.launchedFromInstalledApp || system.applicationLinkKind() != .bundle
                else {
                    throw UserFacingError.installedByScript
                }
                return "Apple silicon on macOS \(system.macOSMajorVersion)"
            }

            try recorder.step(2, "Install the audio plug-in") { note in
                if options.driver {
                    try installBlackHole(using: system)
                    return "BlackHole 2ch"
                }
                let current = system.driverVersionInSystem()
                let bundled = system.driverVersionInBundle()
                if current != nil, current == bundled {
                    return "already current"
                }
                if !system.runningInputClientNames().isEmpty {
                    note("Waiting for your call to end")
                    while !system.runningInputClientNames().isEmpty {
                        system.sleep(seconds: 1)
                    }
                }
                note(
                    "The audio plug-in goes in /Library/Audio/Plug-Ins/HAL, "
                        + "so macOS asks for your password."
                )
                do {
                    try system.installOwnDriver()
                } catch DriverInstallError.doesNotLoad {
                    try installBlackHole(using: system)
                    return "BlackHole 2ch"
                } catch let error as UserFacingError {
                    throw error
                } catch {
                    throw UserFacingError.driverInstallFailed(String(describing: error))
                }
                return "installed"
            }

            try recorder.step(3, "Download the model") { note in
                do {
                    return try system.ensureModel(note: note)
                } catch let error as UserFacingError {
                    throw error
                } catch {
                    throw UserFacingError.modelMissing
                }
            }

            try recorder.step(4, "Measure restore tiers") { note in
                note("Tier benchmark: synthetic weights and sine input, not call acceptance.")
                return try system.ensureTierReport()
            }

            try recorder.step(5, "Link the app into ~/Applications") { _ in
                if system.launchedFromInstalledApp {
                    return "already in place"
                }
                guard system.applicationLinkKind() != .bundle else {
                    throw UserFacingError.installedByScript
                }
                guard let prefix = system.homebrewPrefix else {
                    guard system.applicationLinkKind() != .missing else {
                        throw UserFacingError.applicationLinkFailed(
                            "the app bundle is missing from ~/Applications"
                        )
                    }
                    return "already in place"
                }
                let source = prefix.appendingPathComponent("opt/untunnel/Untunnel.app")
                do {
                    try system.linkApplication(source: source, destination: system.paths.app)
                } catch {
                    throw UserFacingError.applicationLinkFailed(String(describing: error))
                }
                return "linked from Homebrew"
            }

            try recorder.step(6, "Install the login item") { _ in
                let program = LoginAgent.program(for: system.paths)
                if system.loginAgentProgram() != program {
                    do {
                        try system.writeLoginAgent(program: program)
                    } catch {
                        throw UserFacingError.loginAgentFailed(String(describing: error))
                    }
                }
                return "installed"
            }

            try recorder.step(7, "Open Untunnel") { _ in
                if system.isApplicationRunning() {
                    return "already running"
                }
                do {
                    try system.openApplication()
                } catch {
                    throw UserFacingError.applicationLinkFailed(String(describing: error))
                }
                return "opened with Hear Yourself (F13)"
            }
        } catch let error as UserFacingError {
            recorder.output.error(error)
            writeTimings(options.timingsPath, recorder.timings, to: &recorder.output)
            return SetupResult(status: 1, output: recorder.output, timings: recorder.timings)
        } catch {
            recorder.output.error(.unexpected(String(describing: error)))
            writeTimings(options.timingsPath, recorder.timings, to: &recorder.output)
            return SetupResult(status: 1, output: recorder.output, timings: recorder.timings)
        }

        recorder.line()
        recorder.line("Setup complete.")
        let update =
            system.homebrewPrefix == nil
            ? "run the same install line again"
            : "run `brew upgrade untunnel`"
        recorder.line("To update: \(update)")
        writeTimings(options.timingsPath, recorder.timings, to: &recorder.output)
        return SetupResult(status: 0, output: recorder.output, timings: recorder.timings)
    }

    private static func installBlackHole(using system: any SetupSystem) throws {
        do {
            try system.installBlackHole()
        } catch SetupSystemError.homebrewMissing {
            throw UserFacingError.homebrewMissing
        } catch {
            throw UserFacingError.driverInstallFailed("BlackHole 2ch could not be installed")
        }
    }

    private static func writeTimings(
        _ path: String?,
        _ timings: [StepTiming],
        to output: inout CommandOutput
    ) {
        guard let path else {
            return
        }
        do {
            try Output.writeJSON(TimingsDocument(steps: timings), to: path)
        } catch {
            output.error(.unexpected("could not write the timings file: \(error)"))
        }
    }
}

private final class StepRecorder {
    let clock: any SetupClock
    let echo: (String) -> Void
    var output = CommandOutput()
    var timings: [StepTiming] = []

    init(clock: any SetupClock, echo: @escaping (String) -> Void) {
        self.clock = clock
        self.echo = echo
    }

    func line(_ text: String = "") {
        output.line(text)
        echo(text)
    }

    func step(
        _ number: Int,
        _ name: String,
        _ body: ((String) -> Void) throws -> String
    ) throws {
        let started = clock.now()
        do {
            let detail = try body { self.line($0) }
            let seconds = clock.now() - started
            line(
                "[\(number)/\(Setup.stepCount)] \(name) ... \(detail) "
                    + "(\(Output.seconds(seconds)))"
            )
            timings.append(StepTiming(step: number, name: name, seconds: seconds))
        } catch {
            let seconds = clock.now() - started
            line(
                "[\(number)/\(Setup.stepCount)] \(name) ... failed "
                    + "(\(Output.seconds(seconds)))"
            )
            timings.append(StepTiming(step: number, name: name, seconds: seconds))
            throw error
        }
    }
}

/// The real machine, where every step is a file operation or a process.
final class LiveSetupSystem: SetupSystem {
    let paths: InstalledPaths

    init(paths: InstalledPaths = .current) {
        self.paths = paths
    }

    var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 else {
            return false
        }
        return value == 1
    }

    var macOSMajorVersion: Int {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    var homebrewPrefix: URL? {
        if let prefix = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"],
            !prefix.isEmpty
        {
            return URL(fileURLWithPath: prefix)
        }
        let executable = CommandLine.arguments.first ?? ""
        guard let range = executable.range(of: "/opt/") else {
            return nil
        }
        let prefix = String(executable[..<range.lowerBound])
        return prefix.isEmpty ? nil : URL(fileURLWithPath: prefix)
    }

    var launchedFromInstalledApp: Bool {
        guard let executable = CommandLine.arguments.first else {
            return false
        }
        let resolved = URL(fileURLWithPath: executable).standardizedFileURL.path
        return resolved.hasPrefix(paths.app.path + "/")
    }

    func driverVersionInSystem() -> String? {
        bundleVersion(paths.driver)
    }

    func driverVersionInBundle() -> String? {
        guard let source = driverSource else {
            return nil
        }
        return bundleVersion(source)
    }

    func runningInputClientNames() -> [String] {
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

    func installOwnDriver() throws {
        guard let source = driverSource else {
            throw DriverInstallError.doesNotLoad
        }
        try runSudo([
            "/bin/cp", "-R", source.path,
            paths.driver.deletingLastPathComponent().path,
        ])
        try runSudo(["/usr/bin/killall", "coreaudiod"])
        guard FileManager.default.fileExists(atPath: paths.driver.path) else {
            throw DriverInstallError.doesNotLoad
        }
    }

    func installBlackHole() throws {
        guard let brew = brewBinary else {
            throw SetupSystemError.homebrewMissing
        }
        let process = Process()
        process.executableURL = brew
        process.arguments = ["install", "--cask", "blackhole-2ch"]
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SetupSystemError.blackHoleInstallFailed
        }
    }

    func ensureModel(note: (String) -> Void) throws -> String {
        let outcome = Download.perform(
            arguments: [],
            paths: paths,
            pins: .recorded,
            fetcher: LiveModelFetcher(),
            emit: note
        )
        if let failure = outcome.failure {
            throw failure
        }
        return "verified"
    }

    func ensureTierReport() throws -> String {
        let tier = try Bench.ensureTierReport(at: paths.tierReport)
        return "\(tier.sampleRate):\(tier.exitLayer):\(tier.lookAhead)"
    }

    func applicationLinkKind() -> ApplicationLinkKind {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: paths.app.path)) != nil {
            return .link
        }
        return FileManager.default.fileExists(atPath: paths.app.path) ? .bundle : .missing
    }

    func linkApplication(source: URL, destination: URL) throws {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) != nil {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: destination,
            withDestinationURL: source
        )
    }

    func loginAgentProgram() -> String? {
        LoginAgent.programArgument(paths: paths)
    }

    func writeLoginAgent(program: String) throws {
        try LoginAgent.write(paths: paths, program: program)
    }

    func isApplicationRunning() -> Bool {
        for name in ["Untunnel", "untunnel"] where isRunning(name) {
            return true
        }
        return false
    }

    func openApplication() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-n", paths.app.path, "--args", HearYourselfLaunch.argument,
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UserFacingError.applicationLinkFailed(
                "open exited with status \(process.terminationStatus)")
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if isApplicationRunning() { return }
            sleep(seconds: 0.1)
        }
        throw UserFacingError.applicationLinkFailed(
            "the app did not stay running; run untunnel setup again")
    }

    func sleep(seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    func confirm(_ question: String) -> Bool {
        print("\(question) [y/N] ", terminator: "")
        guard let answer = readLine() else {
            return false
        }
        return answer.lowercased().hasPrefix("y")
    }

    private var driverSource: URL? {
        var candidates = [paths.bundledDriver]
        if let resource = Bundle.main.resourceURL {
            candidates.append(resource.appendingPathComponent("Untunnel.driver"))
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        let bundle = executable.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(
            bundle.appendingPathComponent("Contents/Resources/Untunnel.driver")
        )
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private var brewBinary: URL? {
        if let prefix = homebrewPrefix {
            let candidate = prefix.appendingPathComponent("bin/brew")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private func bundleVersion(_ url: URL) -> String? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard
            let data = try? Data(contentsOf: plist),
            let propertyList = try? PropertyListSerialization.propertyList(
                from: data,
                format: nil
            ) as? [String: Any]
        else {
            return nil
        }
        return propertyList["CFBundleVersion"] as? String
    }

    private func runSudo(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = arguments
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UserFacingError.driverInstallFailed(
                "sudo exited with status \(process.terminationStatus)"
            )
        }
    }

    private func isRunning(_ name: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        let pids = String(decoding: output, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0) }
        return pids.contains { $0 != getpid() }
    }
}
