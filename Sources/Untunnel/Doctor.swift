import CryptoKit
import Foundation
import UntunnelAudio

/// A doctor invocation that cannot be parsed.
struct DoctorOptions: Equatable {
    var json = false
    var offline = false
    var markdown = false
    var devices = false
    var headsetReport = false

    init(arguments: [String]) throws {
        for argument in arguments {
            switch argument {
            case "--json":
                json = true
            case "--offline":
                offline = true
            case "--markdown":
                markdown = true
            case "--devices":
                devices = true
            case "--headset-report":
                headsetReport = true
            default:
                throw UserFacingError.usage("unknown doctor option '\(argument)'")
            }
        }
        guard !(json && markdown) else {
            throw UserFacingError.usage("choose either --json or --markdown")
        }
        guard !headsetReport || arguments == ["--headset-report"] else {
            throw UserFacingError.usage("--headset-report takes no other option")
        }
    }
}

struct DoctorInstalledReport: Codable, Equatable {
    let path: String
    let version: String?
    let build: String?
    let binaryOk: Bool
    let signatureOk: Bool

    enum CodingKeys: String, CodingKey {
        case path
        case version
        case build
        case binaryOk = "binary_ok"
        case signatureOk = "signature_ok"
    }
}

struct DoctorVirtualMicReport: Codable, Equatable {
    let kind: String
    let present: Bool
}

struct DoctorToggle: Codable, Equatable {
    let enabled: Bool
}

struct DoctorModelFile: Codable, Equatable {
    let path: String
    let sha256Ok: Bool

    enum CodingKeys: String, CodingKey {
        case path
        case sha256Ok = "sha256_ok"
    }
}

struct DoctorModelReport: Codable, Equatable {
    let present: Bool
    let repo: String
    let revision: String
    let path: String?
    let sha256Ok: Bool
    let files: [DoctorModelFile]

    enum CodingKeys: String, CodingKey {
        case present
        case repo
        case revision
        case path
        case sha256Ok = "sha256_ok"
        case files
    }
}

struct DoctorTier: Codable, Equatable {
    let sampleRate: Int
    let exitLayer: Int
    let lookAhead: Int

    enum CodingKeys: String, CodingKey {
        case sampleRate = "sample_rate"
        case exitLayer = "exit_layer"
        case lookAhead = "look_ahead"
    }
}

/// One complete `doctor` document, in the shape both the text and the JSON report use.
struct DoctorReport: Codable, Equatable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let offline: Bool
    let macOS: String
    let architecture: String
    let installed: DoctorInstalledReport
    let devices: [AudioDevice]?
    let virtualMic: DoctorVirtualMicReport
    let autoRoute: DoctorToggle
    let autoEngage: DoctorToggle
    let model: DoctorModelReport
    let tiers: [DoctorTier]
    let strayTaps: [String]
    let strayAggregates: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case offline
        case macOS = "macos"
        case architecture
        case installed
        case devices
        case virtualMic = "virtual_mic"
        case autoRoute = "auto_route"
        case autoEngage = "auto_engage"
        case model
        case tiers
        case strayTaps = "stray_taps"
        case strayAggregates = "stray_aggregates"
    }
}

/// The two preferences doctor reports; a missing or unreadable file means both are on.
struct Preferences: Codable, Equatable {
    var autoRoute = true
    var autoEngage = true

    enum CodingKeys: String, CodingKey {
        case autoRoute = "auto_route"
        case autoEngage = "auto_engage"
    }

    static func load(from url: URL) -> Preferences {
        guard
            let data = try? Data(contentsOf: url),
            let preferences = try? JSONDecoder().decode(Preferences.self, from: data)
        else {
            return Preferences()
        }
        return preferences
    }
}

struct ModelManifest: Codable, Equatable {
    let repo: String
    let revision: String
    let files: [ModelManifestFile]
}

struct ModelManifestFile: Codable, Equatable {
    let path: String
    let sha256: String
}

/// Reports the installed build, the audio routing and the model without changing anything.
enum Doctor {
    static func run(arguments: [String], paths: InstalledPaths = .current) -> Int32 {
        let options: DoctorOptions
        do {
            options = try DoctorOptions(arguments: arguments)
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

        if options.headsetReport {
            return HeadsetReportCommand.run()
        }

        let report = self.report(offline: options.offline, paths: paths)
        do {
            if options.json {
                FileHandle.standardOutput.write(try Output.jsonData(report))
            } else if options.markdown {
                print(markdown(report))
            } else {
                print(text(report))
            }
        } catch {
            var output = CommandOutput()
            output.error(.unexpected("doctor could not encode the report: \(error)"))
            output.write()
            return 1
        }
        return 0
    }

    static func printUsage() {
        let message =
            "Usage: untunnel doctor [--json | --markdown] [--offline] [--devices]\n"
            + "       untunnel doctor --headset-report\n"
        FileHandle.standardError.write(Data(message.utf8))
    }

    /// Reads the local state, and the device list only when the report is not offline.
    static func report(offline: Bool, paths: InstalledPaths = .current) -> DoctorReport {
        let snapshot: AudioDevices.Snapshot? =
            offline ? nil : AudioDevices(source: CoreAudioDeviceSource()).snapshot
        let preferences = Preferences.load(from: paths.preferences)
        return DoctorReport(
            schemaVersion: DoctorReport.schemaVersion,
            offline: offline,
            macOS: macOSVersion,
            architecture: architecture,
            installed: installed(paths: paths),
            devices: snapshot?.devices,
            virtualMic: virtualMic(paths: paths, snapshot: snapshot),
            autoRoute: DoctorToggle(enabled: preferences.autoRoute),
            autoEngage: DoctorToggle(enabled: preferences.autoEngage),
            model: model(paths: paths),
            tiers: BenchTiers.all.map {
                DoctorTier(
                    sampleRate: $0.sampleRate,
                    exitLayer: $0.exitLayer,
                    lookAhead: $0.lookAhead
                )
            },
            strayTaps: strayTaps(snapshot),
            strayAggregates: strayAggregates(snapshot)
        )
    }

    static func text(_ report: DoctorReport) -> String {
        var lines = [
            report.offline ? "Untunnel doctor (offline)" : "Untunnel doctor",
            "",
            "macOS: \(report.macOS) (\(report.architecture))",
        ]
        if let version = report.installed.version, let build = report.installed.build {
            lines.append(
                "Installed: \(version) (build \(build)) at \(report.installed.path)"
            )
        } else {
            lines.append("Installed: not installed")
        }
        lines.append("Binary: \(report.installed.binaryOk ? "ok" : "missing")")
        lines.append("Signature: \(report.installed.signatureOk ? "ok" : "not verified")")
        lines.append(
            "Virtual mic: \(report.virtualMic.kind) "
                + "(\(report.virtualMic.present ? "present" : "not present"))"
        )
        lines.append("Auto-route: \(report.autoRoute.enabled ? "on" : "off")")
        if report.model.sha256Ok {
            lines.append("Model: \(report.model.repo) at \(report.model.revision)")
            lines.append("Hashes: ok")
        } else if report.model.present {
            lines.append("Model: \(report.model.repo) at \(report.model.revision)")
            lines.append("Hashes: mismatch")
        } else {
            lines.append("Model: not installed")
            lines.append("Hashes: not checked")
        }
        lines.append("Auto-engage: \(report.autoEngage.enabled ? "on" : "off")")
        lines.append("Tiers:")
        for tier in report.tiers {
            lines.append(
                "  \(tier.sampleRate) Hz  exit \(tier.exitLayer)  "
                    + "look-ahead \(tier.lookAhead)"
            )
        }
        lines.append("Stray taps: \(list(report.strayTaps))")
        lines.append("Stray aggregates: \(list(report.strayAggregates))")
        if let devices = report.devices {
            lines.append("Devices: \(devices.count)")
            for device in devices {
                lines.append(
                    "  \(device.uid)\t\(device.name)\t\(device.transport.rawValue)\t"
                        + "\(device.hasInput ? "input" : "")"
                        + "\(device.hasInput && device.hasOutput ? "/" : "")"
                        + "\(device.hasOutput ? "output" : "")"
                )
            }
        } else {
            lines.append("Devices: not queried (offline)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func markdown(_ report: DoctorReport) -> String {
        """
        # Untunnel doctor report

        ```text
        \(text(report))```

        ## Good first issue

        - [ ] Say what you expected and what happened.
        - [ ] Paste this report into the issue.
        - [ ] Name your Mac model and the macOS version above.
        """
    }

    private static var macOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }

    private static var architecture: String {
        #if arch(arm64)
            return "arm64"
        #elseif arch(x86_64)
            return "x86_64"
        #else
            return "unknown"
        #endif
    }

    private static func installed(paths: InstalledPaths) -> DoctorInstalledReport {
        let plist = paths.app.appendingPathComponent("Contents/Info.plist")
        let values = bundleValues(at: plist)
        let binary = paths.executable
        let binaryOk =
            FileManager.default.isExecutableFile(atPath: binary.path)
            && FileManager.default.fileExists(atPath: paths.app.path)
        return DoctorInstalledReport(
            path: paths.app.path,
            version: values?["CFBundleShortVersionString"] as? String,
            build: values?["CFBundleVersion"] as? String,
            binaryOk: binaryOk,
            signatureOk: binaryOk && signatureIsValid(paths.app)
        )
    }

    private static func bundleValues(at plist: URL) -> [String: Any]? {
        guard
            let data = try? Data(contentsOf: plist),
            let values = try? PropertyListSerialization.propertyList(
                from: data,
                format: nil
            ) as? [String: Any]
        else {
            return nil
        }
        return values
    }

    private static func signatureIsValid(_ app: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        return process.terminationStatus == 0
    }

    private static func virtualMic(
        paths: InstalledPaths,
        snapshot: AudioDevices.Snapshot?
    ) -> DoctorVirtualMicReport {
        if let selection = snapshot?.selection.virtualMic {
            return DoctorVirtualMicReport(
                kind: selection.usesFallback ? "blackhole" : "own",
                present: true
            )
        }
        let own = FileManager.default.fileExists(atPath: paths.driver.path)
        let blackhole = FileManager.default.fileExists(
            atPath: "/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver"
        )
        return DoctorVirtualMicReport(
            kind: own ? "own" : blackhole ? "blackhole" : "none",
            present: false
        )
    }

    private static func model(paths: InstalledPaths) -> DoctorModelReport {
        let missing = DoctorModelReport(
            present: false,
            repo: "none",
            revision: "none",
            path: nil,
            sha256Ok: false,
            files: []
        )
        guard
            let data = try? Data(contentsOf: paths.modelManifest),
            let manifest = try? JSONDecoder().decode(ModelManifest.self, from: data)
        else {
            return missing
        }

        var files: [DoctorModelFile] = []
        var allPresent = true
        var allMatch = true
        for file in manifest.files {
            let url = paths.model.appendingPathComponent(file.path)
            let exists = FileManager.default.fileExists(atPath: url.path)
            let digest = exists ? try? FileDigest.hex(of: url) : nil
            let matches = digest?.caseInsensitiveCompare(file.sha256) == .orderedSame
            allPresent = allPresent && exists
            allMatch = allMatch && matches
            files.append(DoctorModelFile(path: file.path, sha256Ok: matches))
        }
        let present = !manifest.files.isEmpty && allPresent
        return DoctorModelReport(
            present: present,
            repo: manifest.repo,
            revision: manifest.revision,
            path: paths.model.path,
            sha256Ok: present && allMatch,
            files: files
        )
    }

    /// Any device under the tap's name, whatever its transport: a live tap is private and
    /// unlisted, so one that shows up is left over from a run that did not clean up.
    static func strayTaps(_ snapshot: AudioDevices.Snapshot?) -> [String] {
        snapshot?.devices
            .filter { $0.name == CoreAudioProcessTap.aggregateName }
            .map(\.name) ?? []
    }

    static func strayAggregates(_ snapshot: AudioDevices.Snapshot?) -> [String] {
        snapshot?.devices
            .filter {
                $0.transport == .aggregate
                    && $0.name != CoreAudioProcessTap.aggregateName
                    && $0.name.localizedCaseInsensitiveContains("untunnel")
            }
            .map(\.name) ?? []
    }

    private static func list(_ values: [String]) -> String {
        values.isEmpty ? "none" : values.joined(separator: ", ")
    }
}

enum FileDigest {
    static func hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
