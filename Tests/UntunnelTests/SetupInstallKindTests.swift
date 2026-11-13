import Foundation
import Testing

@testable import Untunnel

/// How setup tells a script install from a Homebrew install, checked against real links in a
/// temporary home directory instead of a scripted link kind.
@Suite("SetupInstallKind")
struct SetupInstallKindTests {
    @Test
    func aRealBundleIsAScriptInstall() throws {
        let home = try TemporaryHome()
        try home.makeBundle()

        #expect(LiveSetupSystem(paths: home.paths).applicationLinkKind() == .bundle)
    }

    @Test
    func aWorkingOrDanglingLinkIsAHomebrewInstall() throws {
        let home = try TemporaryHome()
        try home.makeLink(to: home.url.appendingPathComponent("Cellar/Untunnel.app"))
        let system = LiveSetupSystem(paths: home.paths)

        #expect(system.applicationLinkKind() == .link)
        try FileManager.default.createDirectory(
            at: home.url.appendingPathComponent("Cellar/Untunnel.app"),
            withIntermediateDirectories: true
        )
        #expect(system.applicationLinkKind() == .link)
    }

    @Test
    func nothingInstalledIsMissing() throws {
        let home = try TemporaryHome()

        #expect(LiveSetupSystem(paths: home.paths).applicationLinkKind() == .missing)
    }

    @Test
    func aScriptInstallUnderAHomebrewPrefixIsRefusedAndNothingIsWritten() throws {
        let home = try TemporaryHome()
        try home.makeBundle()
        let marker = home.paths.app.appendingPathComponent("Contents/marker")
        try Data("script".utf8).write(to: marker)
        let system = FilesystemSetupSystem(paths: home.paths)

        let result = Setup.perform(arguments: ["--yes"], system: system, clock: FixedClock())

        #expect(result.status == 1)
        #expect(
            result.output.errorText.contains(
                "Untunnel is already installed by the install script."
            )
        )
        #expect(system.linkedSources.isEmpty)
        #expect(system.openCalls == 0)
        #expect(!FileManager.default.fileExists(atPath: home.paths.loginAgent.path))
        #expect(try String(contentsOf: marker, encoding: .utf8) == "script")
        #expect(
            (try? FileManager.default.destinationOfSymbolicLink(atPath: home.paths.app.path))
                == nil
        )
    }

    @Test
    func aDanglingLinkIsReplacedByTheOptLink() throws {
        let home = try TemporaryHome()
        try home.makeLink(to: home.url.appendingPathComponent("removed/Untunnel.app"))
        let system = FilesystemSetupSystem(paths: home.paths)

        let result = Setup.perform(arguments: ["--yes"], system: system, clock: FixedClock())

        #expect(result.status == 0)
        let opt = "/opt/homebrew/opt/untunnel/Untunnel.app"
        #expect(system.linkedSources.map(\.path) == [opt])
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: home.paths.app.path) == opt
        )
        #expect(result.output.text.contains("linked from Homebrew"))
    }
}

/// A home directory under the temporary directory, removed when the test ends.
private final class TemporaryHome {
    let url: URL
    let paths: InstalledPaths

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SetupInstallKind-\(UUID().uuidString)")
        paths = InstalledPaths(home: url)
        try FileManager.default.createDirectory(
            at: paths.app.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func makeBundle() throws {
        try FileManager.default.createDirectory(
            at: paths.app.appendingPathComponent("Contents"),
            withIntermediateDirectories: true
        )
    }

    func makeLink(to target: URL) throws {
        try FileManager.default.createSymbolicLink(at: paths.app, withDestinationURL: target)
    }
}

/// The live link and login-item code on a temporary home; the driver, model and app launch
/// are answered without touching the machine.
private final class FilesystemSetupSystem: SetupSystem {
    let paths: InstalledPaths
    private let live: LiveSetupSystem

    let isAppleSilicon = true
    let macOSMajorVersion = 15
    let homebrewPrefix: URL? = URL(fileURLWithPath: "/opt/homebrew")
    let launchedFromInstalledApp = false

    var linkedSources: [URL] = []
    var openCalls = 0

    init(paths: InstalledPaths) {
        self.paths = paths
        live = LiveSetupSystem(paths: paths)
    }

    func driverVersionInSystem() -> String? {
        "1"
    }

    func driverVersionInBundle() -> String? {
        "1"
    }

    func runningInputClientNames() -> [String] {
        []
    }

    func installOwnDriver() throws {}

    func installBlackHole() throws {}

    func ensureModel(note: (String) -> Void) throws -> String {
        "already installed"
    }

    func ensureTierReport() throws -> String { "measured 48000:7:1" }

    func applicationLinkKind() -> ApplicationLinkKind {
        live.applicationLinkKind()
    }

    func linkApplication(source: URL, destination: URL) throws {
        linkedSources.append(source)
        try live.linkApplication(source: source, destination: destination)
    }

    func loginAgentProgram() -> String? {
        live.loginAgentProgram()
    }

    func writeLoginAgent(program: String) throws {
        try live.writeLoginAgent(program: program)
    }

    func isApplicationRunning() -> Bool {
        false
    }

    func openApplication() throws {
        openCalls += 1
    }

    func sleep(seconds: TimeInterval) {}

    func confirm(_ question: String) -> Bool {
        true
    }
}

private struct FixedClock: SetupClock {
    func now() -> TimeInterval {
        0
    }
}
