import Darwin
import Foundation
import Testing

@testable import Untunnel

private let exampleHome = URL(fileURLWithPath: "/Users/example")

private final class FakeUninstallSystem: UninstallSystem {
    let paths = InstalledPaths(home: exampleHome)

    var userID: uid_t {
        501
    }

    var removed: [URL] = []
    var driverRemoved = false
    var loginAgentStopped = false
    var confirmAnswer = true
    var driverError: Error?
    var events: [String] = []
    var failingPath: URL?

    func remove(_ url: URL) throws {
        events.append(url.lastPathComponent)
        if url == failingPath {
            throw UserFacingError.uninstallFailed("permission denied")
        }
        removed.append(url)
    }

    func removeDriver() throws {
        events.append("driver")
        if let driverError { throw driverError }
        driverRemoved = true
    }

    func stopLoginAgent() throws {
        loginAgentStopped = true
    }

    func confirm(_ question: String) -> Bool {
        confirmAnswer
    }
}

@Test
func uninstallRemovesTheDriverBeforeUserFilesAndKeepsTheAppUntilLast() {
    let system = FakeUninstallSystem()
    let result = Uninstall.perform(arguments: ["--yes"], system: system)
    #expect(result.status == 0)
    #expect(
        system.events == [
            "driver", system.paths.loginAgent.lastPathComponent, "Untunnel", "Untunnel.app",
        ])
    #expect(!system.removed.contains(system.paths.driver))
}

@Test
func uninstallCanRetryAfterPrivilegeOrUserFileFailure() {
    let system = FakeUninstallSystem()
    system.driverError = UserFacingError.uninstallFailed("sudo denied")
    #expect(Uninstall.perform(arguments: ["--yes"], system: system).status == 1)
    #expect(system.removed.isEmpty)
    system.driverError = nil
    system.failingPath = system.paths.support
    #expect(Uninstall.perform(arguments: ["--yes"], system: system).status == 1)
    #expect(!system.removed.contains(system.paths.app))
    system.failingPath = nil
    #expect(Uninstall.perform(arguments: ["--yes"], system: system).status == 0)
    #expect(system.removed.last == system.paths.app)
}

@Test
func uninstallDryRunListsEveryPathFromInstalledPaths() {
    let result = Uninstall.perform(
        arguments: ["--dry-run"],
        system: FakeUninstallSystem()
    )

    #expect(result.status == 0)
    let expected =
        [
            "Untunnel uninstall (dry run)",
            "",
            "Would remove:",
            "  /Users/example/Applications/Untunnel.app",
            "  /Users/example/Library/LaunchAgents/com.intesarjawad.untunnel.plist",
            "  /Users/example/Library/Application Support/Untunnel",
            "  /Library/Audio/Plug-Ins/HAL/Untunnel.driver",
            "",
            "Would run:",
            "  launchctl bootout gui/501/com.intesarjawad.untunnel",
            "  sudo rm -rf /Library/Audio/Plug-Ins/HAL/Untunnel.driver",
            "  sudo killall coreaudiod",
            "",
            "Nothing was changed.",
        ].joined(separator: "\n") + "\n"
    #expect(result.output.text == expected)
}

@Test
func uninstallRemovesEveryListedPathAfterConfirmation() {
    let system = FakeUninstallSystem()

    let result = Uninstall.perform(arguments: ["--yes"], system: system)

    #expect(result.status == 0)
    #expect(system.removed == [system.paths.loginAgent, system.paths.support, system.paths.app])
    #expect(system.driverRemoved)
    #expect(system.loginAgentStopped)
    let expected =
        [
            "Untunnel uninstall",
            "Removed /Library/Audio/Plug-Ins/HAL/Untunnel.driver",
            "Removed /Users/example/Library/LaunchAgents/com.intesarjawad.untunnel.plist",
            "Removed /Users/example/Library/Application Support/Untunnel",
            "Removed /Users/example/Applications/Untunnel.app",
            "Untunnel is uninstalled.",
        ].joined(separator: "\n") + "\n"
    #expect(result.output.text == expected)
}

@Test
func uninstallKeepsEverythingWhenConfirmationIsDeclined() {
    let system = FakeUninstallSystem()
    system.confirmAnswer = false

    let result = Uninstall.perform(arguments: [], system: system)

    #expect(result.status == 0)
    #expect(system.removed.isEmpty)
    #expect(!system.driverRemoved)
    #expect(result.output.text == "Nothing was changed.\n")
}

@Test
func uninstallRejectsAnUnknownOption() {
    let result = Uninstall.perform(
        arguments: ["--purge"],
        system: FakeUninstallSystem()
    )

    #expect(result.status == 2)
    #expect(result.output.errorText.contains("unknown uninstall option '--purge'"))
}

@Test
func howItWorksListsEveryFileUninstallRemoves() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let document = try String(
        contentsOf: root.appendingPathComponent("docs/how-it-works.md"),
        encoding: .utf8
    )
    let section = document.components(separatedBy: "\n## Files Untunnel writes\n")
    try #require(section.count == 2, "docs/how-it-works.md needs one '## Files Untunnel writes'")
    let listed = section[1]
        .components(separatedBy: "\n## ")[0]
        .split(separator: "\n")
        .filter { $0.hasPrefix("- `") && $0.hasSuffix("`") }
        .map { String($0.dropFirst(3).dropLast()) }

    let home = exampleHome.path
    let expected = InstalledPaths(home: exampleHome).all.map { url in
        url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }
    #expect(listed == expected)
}
