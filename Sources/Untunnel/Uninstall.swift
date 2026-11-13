import Darwin
import Foundation

struct UninstallOptions: Equatable {
    var dryRun = false
    var yes = false

    init(arguments: [String]) throws {
        for argument in arguments {
            switch argument {
            case "--dry-run":
                dryRun = true
            case "--yes":
                yes = true
            default:
                throw UserFacingError.usage("unknown uninstall option '\(argument)'")
            }
        }
    }
}

struct UninstallResult: Equatable {
    let status: Int32
    let output: CommandOutput
}

/// Everything uninstall removes, behind a protocol so a test never deletes a real file.
protocol UninstallSystem: AnyObject {
    var paths: InstalledPaths { get }
    var userID: uid_t { get }
    func remove(_ url: URL) throws
    func removeDriver() throws
    func stopLoginAgent() throws
    func confirm(_ question: String) -> Bool
}

enum Uninstall {
    static func run(arguments: [String]) -> Int32 {
        let result = perform(arguments: arguments, system: LiveUninstallSystem())
        result.output.write()
        return result.status
    }

    static func perform(arguments: [String], system: any UninstallSystem) -> UninstallResult {
        var output = CommandOutput()
        let options: UninstallOptions
        do {
            options = try UninstallOptions(arguments: arguments)
        } catch let error as UserFacingError {
            output.error(error)
            return UninstallResult(status: 2, output: output)
        } catch {
            output.error(.unexpected(String(describing: error)))
            return UninstallResult(status: 1, output: output)
        }

        let paths = system.paths
        if options.dryRun {
            output.line("Untunnel uninstall (dry run)")
            output.line()
            output.line("Would remove:")
            for path in paths.all {
                output.line("  \(path.path)")
            }
            output.line()
            output.line("Would run:")
            for command in commands(system: system) {
                output.line("  \(command)")
            }
            output.line()
            output.line("Nothing was changed.")
            return UninstallResult(status: 0, output: output)
        }

        guard options.yes || system.confirm("Remove Untunnel and its files?") else {
            output.line("Nothing was changed.")
            return UninstallResult(status: 0, output: output)
        }

        output.line("Untunnel uninstall")
        do {
            try system.stopLoginAgent()
            try system.removeDriver()
            output.line("Removed \(paths.driver.path)")
            // Keep the executable available to retry if removing a user file fails.
            let userFiles = paths.all.filter { $0 != paths.driver && $0 != paths.app }
            for path in userFiles + [paths.app] {
                try system.remove(path)
                output.line("Removed \(path.path)")
            }
        } catch let error as UserFacingError {
            output.error(error)
            return UninstallResult(status: 1, output: output)
        } catch {
            output.error(.uninstallFailed(String(describing: error)))
            return UninstallResult(status: 1, output: output)
        }
        output.line("Untunnel is uninstalled.")
        return UninstallResult(status: 0, output: output)
    }

    private static func commands(system: any UninstallSystem) -> [String] {
        [
            "launchctl bootout gui/\(system.userID)/\(LoginAgent.label)",
            "sudo rm -rf \(system.paths.driver.path)",
            "sudo killall coreaudiod",
        ]
    }
}

final class LiveUninstallSystem: UninstallSystem {
    let paths: InstalledPaths

    init(paths: InstalledPaths = .current) {
        self.paths = paths
    }

    var userID: uid_t {
        getuid()
    }

    func remove(_ url: URL) throws {
        let isLink =
            (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
        guard isLink || FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }

    func removeDriver() throws {
        // Retry the daemon restart even if an earlier attempt already removed the bundle.
        try runSudo(["/bin/rm", "-rf", paths.driver.path])
        try runSudo(["/usr/bin/killall", "coreaudiod"])
    }

    func stopLoginAgent() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = [
            "bootout", "gui/\(getuid())/\(LoginAgent.label)",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    func confirm(_ question: String) -> Bool {
        print("\(question) [y/N] ", terminator: "")
        guard let answer = readLine() else {
            return false
        }
        return answer.lowercased().hasPrefix("y")
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
            throw UserFacingError.uninstallFailed(
                "sudo exited with status \(process.terminationStatus)"
            )
        }
    }
}
