import Foundation
import Testing

@testable import Untunnel

private let exampleHome = URL(fileURLWithPath: "/Users/example")

private final class FakeSetupSystem: SetupSystem {
    let paths = InstalledPaths(home: exampleHome)

    var isAppleSilicon = true
    var macOSMajorVersion = 15
    var homebrewPrefix: URL?
    var launchedFromInstalledApp = true

    var systemDriverVersion: String? = "1"
    var bundleDriverVersion: String? = "1"
    var inputClients: [String] = []
    var clearClientsOnSleep = false
    var driverError: Error?
    var blackHoleError: Error?
    var modelDetail = "already installed"
    var modelError: Error?

    var installDriverCalls = 0
    var installBlackHoleCalls = 0
    var sleeps = 0
    var linkKind: ApplicationLinkKind = .missing
    var linkedSource: URL?
    var loginProgram: String?
    var writtenLoginProgram: String?
    var appRunning = false
    var openCalls = 0
    var tierReportCalls = 0
    var tierReportError: Error?
    var openError: Error?
    var confirmAnswer = true

    func driverVersionInSystem() -> String? {
        systemDriverVersion
    }

    func driverVersionInBundle() -> String? {
        bundleDriverVersion
    }

    func runningInputClientNames() -> [String] {
        inputClients
    }

    func installOwnDriver() throws {
        installDriverCalls += 1
        if let driverError {
            throw driverError
        }
    }

    func installBlackHole() throws {
        installBlackHoleCalls += 1
        if let blackHoleError {
            throw blackHoleError
        }
    }

    var modelNotes: [String] = []

    func ensureModel(note: (String) -> Void) throws -> String {
        modelNotes.forEach(note)
        if let modelError {
            throw modelError
        }
        return modelDetail
    }

    func applicationLinkKind() -> ApplicationLinkKind {
        linkKind
    }

    func linkApplication(source: URL, destination: URL) throws {
        linkedSource = source
        linkKind = .link
    }

    func loginAgentProgram() -> String? {
        loginProgram
    }

    func writeLoginAgent(program: String) throws {
        writtenLoginProgram = program
    }

    func isApplicationRunning() -> Bool {
        appRunning
    }

    func openApplication() throws {
        openCalls += 1
        if let openError { throw openError }
    }

    func ensureTierReport() throws -> String {
        tierReportCalls += 1
        if let tierReportError { throw tierReportError }
        return "measured 48000:7:1"
    }

    func sleep(seconds: TimeInterval) {
        sleeps += 1
        if clearClientsOnSleep {
            inputClients = []
        }
    }

    func confirm(_ question: String) -> Bool {
        confirmAnswer
    }
}

private struct ZeroClock: SetupClock {
    func now() -> TimeInterval {
        0
    }
}

private final class StepClock: SetupClock {
    private var values: [TimeInterval]

    init(values: [TimeInterval]) {
        self.values = values
    }

    func now() -> TimeInterval {
        values.isEmpty ? 0 : values.removeFirst()
    }
}

private func successfulSetup() -> FakeSetupSystem {
    let system = FakeSetupSystem()
    system.systemDriverVersion = "1"
    system.bundleDriverVersion = "1"
    return system
}

@Test
func setupPrintsTheTimedStepsForAnExistingInstall() {
    let result = Setup.perform(
        arguments: ["--yes"],
        system: successfulSetup(),
        clock: ZeroClock()
    )

    #expect(result.status == 0)
    let expected =
        [
            "Untunnel setup",
            "",
            "[1/7] Check this Mac ... Apple silicon on macOS 15 (0.00 s)",
            "[2/7] Install the audio plug-in ... already current (0.00 s)",
            "[3/7] Download the model ... already installed (0.00 s)",
            "Tier benchmark: synthetic weights and sine input, not call acceptance.",
            "[4/7] Measure restore tiers ... measured 48000:7:1 (0.00 s)",
            "[5/7] Link the app into ~/Applications ... already in place (0.00 s)",
            "[6/7] Install the login item ... installed (0.00 s)",
            "[7/7] Open Untunnel ... opened with Hear Yourself (F13) (0.00 s)",
            "",
            "Setup complete.",
            "To update: run the same install line again",
        ].joined(separator: "\n") + "\n"
    #expect(result.output.text == expected)
    #expect(result.output.errorText.isEmpty)
}

@Test
func setupWritesTheLoginAgentForTheInstalledExecutable() {
    let system = successfulSetup()

    let result = Setup.perform(arguments: ["--yes"], system: system, clock: ZeroClock())

    #expect(result.status == 0)
    #expect(
        system.writtenLoginProgram
            == "/Users/example/Applications/Untunnel.app/Contents/MacOS/Untunnel"
    )
}

@Test
func setupWaitsForTheCallToEndBeforeCopyingTheDriver() {
    let system = FakeSetupSystem()
    system.systemDriverVersion = "1"
    system.bundleDriverVersion = "2"
    system.inputClients = ["FaceTime"]
    system.clearClientsOnSleep = true

    let result = Setup.perform(arguments: ["--yes"], system: system, clock: ZeroClock())

    #expect(result.status == 0)
    #expect(system.sleeps == 1)
    #expect(system.installDriverCalls == 1)
    #expect(result.output.text.contains("so macOS asks for your password."))
    let lines = result.output.text.split(separator: "\n").map(String.init)
    let waiting = lines.firstIndex(of: "Waiting for your call to end")
    let step = lines.firstIndex { $0.hasPrefix("[2/7]") }
    #expect(waiting != nil)
    #expect(step != nil)
    #expect((waiting ?? 0) < (step ?? 0))
}

@Test
func setupKeepsTheDriverWhenItsVersionMatches() {
    let system = successfulSetup()
    system.inputClients = ["FaceTime"]

    let result = Setup.perform(arguments: ["--yes"], system: system, clock: ZeroClock())

    #expect(result.status == 0)
    #expect(system.installDriverCalls == 0)
    #expect(system.sleeps == 0)
    #expect(result.output.text.contains("already current"))
}

@Test
func setupRefusesAnIntelMac() {
    let system = successfulSetup()
    system.isAppleSilicon = false

    let result = Setup.perform(arguments: ["--yes"], system: system, clock: ZeroClock())

    #expect(result.status == 1)
    #expect(result.output.errorText.contains("Untunnel needs an Apple silicon Mac."))
    #expect(result.output.errorText.contains("Fix: Open the Apple menu > About This Mac"))
    #expect(system.installDriverCalls == 0)
}

@Test
func setupRefusesMacOSBeforeFifteen() {
    let system = successfulSetup()
    system.macOSMajorVersion = 14

    let result = Setup.perform(arguments: ["--yes"], system: system, clock: ZeroClock())

    #expect(result.status == 1)
    #expect(result.output.errorText.contains("Untunnel needs macOS 15 or later."))
}

@Test
func setupStopsWhenTheInstallScriptOwnsTheApp() {
    let system = successfulSetup()
    system.launchedFromInstalledApp = false
    system.homebrewPrefix = URL(fileURLWithPath: "/opt/homebrew")
    system.linkKind = .bundle
    system.systemDriverVersion = nil
    system.bundleDriverVersion = "2"

    let result = Setup.perform(arguments: ["--yes"], system: system, clock: ZeroClock())

    #expect(result.status == 1)
    #expect(
        result.output.errorText.contains("Untunnel is already installed by the install script.")
    )
    #expect(result.output.errorText.contains("untunnel setup"))
    #expect(system.installDriverCalls == 0)
    #expect(system.writtenLoginProgram == nil)
    #expect(system.openCalls == 0)
}

@Test
func setupLinksTheStableHomebrewOptPath() {
    let system = successfulSetup()
    system.launchedFromInstalledApp = false
    system.homebrewPrefix = URL(fileURLWithPath: "/opt/homebrew")
    system.linkKind = .link

    let result = Setup.perform(arguments: ["--yes"], system: system, clock: ZeroClock())

    #expect(result.status == 0)
    #expect(system.linkedSource?.path == "/opt/homebrew/opt/untunnel/Untunnel.app")
    #expect(result.output.text.hasSuffix("To update: run `brew upgrade untunnel`\n"))
}

@Test
func setupInstallsBlackHoleWhenAsked() {
    let system = successfulSetup()

    let result = Setup.perform(
        arguments: ["--yes", "--driver"],
        system: system,
        clock: ZeroClock()
    )

    #expect(result.status == 0)
    #expect(system.installBlackHoleCalls == 1)
    #expect(system.installDriverCalls == 0)
    #expect(result.output.text.contains("... BlackHole 2ch"))
}

@Test
func setupFallsBackToBlackHoleWhenTheOwnDriverDoesNotLoad() {
    let system = successfulSetup()
    system.systemDriverVersion = nil
    system.driverError = DriverInstallError.doesNotLoad

    let result = Setup.perform(arguments: ["--yes"], system: system, clock: ZeroClock())

    #expect(result.status == 0)
    #expect(system.installBlackHoleCalls == 1)
    #expect(result.output.text.contains("... BlackHole 2ch"))
}

@Test
func setupReportsAMissingHomebrewAsACommandToRun() {
    let system = successfulSetup()
    system.systemDriverVersion = nil
    system.driverError = DriverInstallError.doesNotLoad
    system.blackHoleError = SetupSystemError.homebrewMissing

    let result = Setup.perform(arguments: ["--yes"], system: system, clock: ZeroClock())

    #expect(result.status == 1)
    #expect(result.output.errorText.contains("Homebrew is not installed"))
    #expect(result.output.errorText.contains("brew install --cask blackhole-2ch"))
}

@Test
func setupWritesEveryStepToTheTimingsFile() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("timings.json")
    defer {
        try? FileManager.default.removeItem(at: path.deletingLastPathComponent())
    }
    let clock = StepClock(values: (0..<14).map { Double($0) * 0.25 })

    let result = Setup.perform(
        arguments: ["--yes", "--timings-json", path.path],
        system: successfulSetup(),
        clock: clock
    )

    #expect(result.status == 0)
    let document = try JSONDecoder().decode(
        TimingsDocument.self,
        from: Data(contentsOf: path)
    )
    #expect(document.steps.map(\.step) == [1, 2, 3, 4, 5, 6, 7])
    #expect(document.steps.map(\.seconds) == Array(repeating: 0.25, count: 7))
}

@Test
func setupCancelsWithoutTouchingTheMachine() {
    let system = successfulSetup()
    system.confirmAnswer = false

    let result = Setup.perform(arguments: [], system: system, clock: ZeroClock())

    #expect(result.status == 0)
    #expect(result.output.text == "Setup cancelled.\n")
    #expect(system.installDriverCalls == 0)
    #expect(system.writtenLoginProgram == nil)
}

@Test
func setupRejectsAnUnknownOption() {
    let result = Setup.perform(
        arguments: ["--quiet"],
        system: successfulSetup(),
        clock: ZeroClock()
    )

    #expect(result.status == 2)
    #expect(result.output.errorText.contains("unknown setup option '--quiet'"))
}

@Test
func setupStreamsTheModelLinesBeforeTheStepFinishes() {
    let system = successfulSetup()
    system.modelNotes = ["Download size: 54.1 MB", ModelPins.streamingLicence]
    system.modelDetail = "verified"
    var echoed: [String] = []

    let result = Setup.perform(
        arguments: ["--yes"],
        system: system,
        clock: ZeroClock(),
        echo: { echoed.append($0) }
    )

    #expect(result.status == 0)
    #expect(echoed == result.output.lines)
    let size = echoed.firstIndex(of: "Download size: 54.1 MB")
    let licence = echoed.firstIndex(of: ModelPins.streamingLicence)
    let step = echoed.firstIndex { $0.hasPrefix("[3/7] Download the model ... verified") }
    #expect(size != nil && licence != nil && step != nil)
    #expect((size ?? .max) < (step ?? 0))
    #expect((licence ?? .max) < (step ?? 0))
}

@Test
func setupStopsAtTheModelStepWithTheDownloadError() {
    for failure in [
        UserFacingError.modelDownloadOffline,
        .diskFull("the model needs 54.1 MB and 12.0 MB are free"),
        .modelDownloadCorrupt("model.safetensors has SHA-256 00 but 6e was expected"),
    ] {
        let system = successfulSetup()
        system.modelError = failure

        let result = Setup.perform(arguments: ["--yes"], system: system, clock: ZeroClock())

        #expect(result.status == 1)
        #expect(result.output.errorLines == [failure.message, "Fix: \(failure.fix)"])
        #expect(result.output.text.contains("[3/7] Download the model ... failed"))
        #expect(system.writtenLoginProgram == nil)
        #expect(system.openCalls == 0)
    }
}

@Test
func setupMeasuresTiersBeforeLaunchingAndReportsMeasurementFailures() {
    let system = successfulSetup()
    #expect(Setup.perform(arguments: ["--yes"], system: system, clock: ZeroClock()).status == 0)
    #expect(system.tierReportCalls == 1)
    system.tierReportError = UserFacingError.permissionDenied("writing bench.json")
    system.openCalls = 0
    #expect(Setup.perform(arguments: ["--yes"], system: system, clock: ZeroClock()).status == 1)
    #expect(system.openCalls == 0)
}

@Test
func setupDoesNotClaimCompletionWhenLaunchFails() {
    let system = successfulSetup()
    system.openError = UserFacingError.applicationLinkFailed("open exited 1")
    let result = Setup.perform(arguments: ["--yes"], system: system, clock: ZeroClock())
    #expect(result.status == 1)
    #expect(!result.output.text.contains("Setup complete."))
}

@Test
func setupChecksTheRealLaunchersExitStatus() {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let system = LiveSetupSystem(paths: InstalledPaths(home: home))
    #expect(throws: UserFacingError.self) { try system.openApplication() }
}
