import Darwin
import Foundation
import UntunnelDSP
import UntunnelEngine

/// Why a headset report could not be made or its request was refused.
enum HeadsetReportError: Error, Equatable, CustomStringConvertible {
    case badRequest(String)
    case recordingUnavailable
    case silentTake
    case tooShort
    case headsetNotFound(String)
    case buildUnavailable

    var description: String {
        switch self {
        case .badRequest(let detail):
            return "the headset report request was refused: \(detail)"
        case .recordingUnavailable:
            return "the headset recording is not available in this build of Untunnel"
        case .silentTake:
            return "the recording was silent; read the passage aloud with the headset on"
        case .tooShort:
            return "the recording was too short to measure"
        case .headsetNotFound(let name):
            return "macOS lists no vendor and product ID for '\(name)'"
        case .buildUnavailable:
            return "macOS did not report its build number"
        }
    }
}

/// The headset section of a report, as `system_profiler` names it.
struct HeadsetIdentity: Codable, Equatable, Sendable {
    let name: String
    let vendorID: String
    let productID: String
    let firmware: String?

    enum CodingKeys: String, CodingKey {
        case name
        case vendorID = "vendor_id"
        case productID = "product_id"
        case firmware
    }
}

/// The rates the headset runs at during a call, which are what a raw recording is limited by.
struct HeadsetCallMode: Codable, Equatable {
    let inputRateHz: Int
    let outputRateHz: Int

    enum CodingKeys: String, CodingKey {
        case inputRateHz = "input_rate_hz"
        case outputRateHz = "output_rate_hz"
    }
}

/// The frequency above which a take stays 40 dB under its loudest part, raw and restored.
struct HeadsetRolloff: Codable, Equatable {
    let raw: Int
    let untunnel: Int
}

/// The one JSON object `untunnel doctor --headset-report` prints, version 1 of the schema in
/// `docs/headset-report.schema.json`. It holds numbers and device names; no audio.
struct HeadsetReport: Codable, Equatable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let headset: HeadsetIdentity
    let callMode: HeadsetCallMode
    let tier: DoctorTier
    let addedLatencyMs: Double
    let macOSBuild: String
    let rolloff40dbHz: HeadsetRolloff

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case headset
        case callMode = "call_mode"
        case tier
        case addedLatencyMs = "added_latency_ms"
        case macOSBuild = "macos_build"
        case rolloff40dbHz = "rolloff_40db_hz"
    }
}

/// What the app measured during the take, before the report is assembled.
struct HeadsetCapture: Sendable {
    let take: ABTake
    let headsetName: String
    let inputRateHz: Int
    let outputRateHz: Int
    let tier: Tier
    let addedLatencyMs: Double
    var identity: HeadsetIdentity? = nil
    var rawInput: [Float]? = nil
}

/// What the app leaves in the output file when it cannot make a report.
struct HeadsetReportFailure: Codable, Equatable {
    let error: String
}

/// The spectral rolloff of a take, measured with the monitor's analyzer.
enum Rolloff {
    /// How far under the loudest row a row may sit and still count as signal.
    static let dropDb: Float = 40
    static let rowCount = 1_024
    /// Under this a take holds no voice: it is a muted or disconnected microphone.
    static let minimumPeakDb: Float = -80

    private static let hop = 1_024

    /// The upper edge, in hertz, of the highest row whose mean level is within `dropDb` of the
    /// loudest row, never above the Nyquist rate.
    static func hz(samples: [Float], sampleRate: Int) throws -> Int {
        let analyzer = SpectrumAnalyzer(sampleRate: sampleRate, rowCount: rowCount)
        var levels = [Float](repeating: SpectrumAnalyzer.silenceDb, count: rowCount)
        var power = [Double](repeating: 0, count: rowCount)
        var frames = 0
        var pushed = 0
        for start in stride(from: 0, to: samples.count, by: hop) {
            let end = min(start + hop, samples.count)
            samples.withUnsafeBufferPointer {
                analyzer.push(UnsafeBufferPointer(rebasing: $0[start..<end]))
            }
            pushed += end - start
            guard pushed >= SpectrumAnalyzer.fftLength else {
                continue
            }
            levels.withUnsafeMutableBufferPointer { analyzer.compute(into: $0) }
            for row in 0..<rowCount {
                power[row] += pow(10, Double(levels[row]) / 10)
            }
            frames += 1
        }
        guard frames > 0 else {
            throw HeadsetReportError.tooShort
        }

        let meanDb = power.map { Float(10 * log10($0 / Double(frames))) }
        let peak = meanDb.max() ?? SpectrumAnalyzer.silenceDb
        guard peak >= minimumPeakDb else {
            throw HeadsetReportError.silentTake
        }
        let top = meanDb.lastIndex { $0 >= peak - dropDb } ?? 0
        let edge = LogFrequencyAxis.standard.edgeHz(top + 1, rowCount: rowCount)
        return Int(min(edge, Double(sampleRate) / 2).rounded())
    }
}

/// Reads one headset's identity out of `system_profiler SPBluetoothDataType -json`.
enum BluetoothProfile {
    /// The device called `name`, preferring a connected one, or nil without a vendor and product ID.
    static func identity(named name: String, in data: Data) -> HeadsetIdentity? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let controllers = root["SPBluetoothDataType"] as? [[String: Any]]
        else {
            return nil
        }
        for key in ["device_connected", "device_not_connected"] {
            let devices = controllers.flatMap { $0[key] as? [[String: [String: Any]]] ?? [] }
            for properties in devices.compactMap({ $0[name] }) {
                guard
                    let vendor = (properties["device_vendorID"] as? String).flatMap(normalizedID),
                    let product = (properties["device_productID"] as? String).flatMap(normalizedID)
                else {
                    continue
                }
                return HeadsetIdentity(
                    name: name,
                    vendorID: vendor,
                    productID: product,
                    firmware: properties["device_firmwareVersion"] as? String
                )
            }
        }
        return nil
    }

    /// `0x004C (Apple)` and `0x4c` both become `0x004C`.
    static func normalizedID(_ text: String) -> String? {
        let token = text.split(separator: " ").first.map(String.init) ?? ""
        guard
            token.lowercased().hasPrefix("0x"),
            let value = UInt16(token.dropFirst(2), radix: 16)
        else {
            return nil
        }
        return "0x" + String(format: "%04X", value)
    }

    static func read() throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }
}

extension HeadsetReport {
    /// Assembles the report; `profile` is the `system_profiler` document.
    static func make(
        capture: HeadsetCapture,
        profile: Data,
        macOSBuild: String
    ) throws -> HeadsetReport {
        guard
            let headset = capture.identity
                ?? BluetoothProfile.identity(named: capture.headsetName, in: profile)
        else {
            throw HeadsetReportError.headsetNotFound(capture.headsetName)
        }
        let rate = capture.take.sampleRate
        return HeadsetReport(
            schemaVersion: schemaVersion,
            headset: headset,
            callMode: HeadsetCallMode(
                inputRateHz: capture.inputRateHz,
                outputRateHz: capture.outputRateHz
            ),
            tier: DoctorTier(
                sampleRate: capture.tier.sampleRate,
                exitLayer: capture.tier.exitLayer,
                lookAhead: capture.tier.lookAhead
            ),
            addedLatencyMs: capture.addedLatencyMs,
            macOSBuild: macOSBuild,
            rolloff40dbHz: HeadsetRolloff(
                raw: min(
                    capture.inputRateHz / 2,
                    try Rolloff.hz(
                        samples: capture.rawInput ?? capture.take.before,
                        sampleRate: capture.rawInput == nil ? rate : capture.inputRateHz)),
                untunnel: try Rolloff.hz(samples: capture.take.after, sampleRate: rate)
            )
        )
    }

    /// The Darwin build string `sw_vers -buildVersion` prints.
    static func currentMacOSBuild() throws -> String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 else {
            throw HeadsetReportError.buildUnavailable
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else {
            throw HeadsetReportError.buildUnavailable
        }
        return String(
            decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
}

/// The `untunnel://headset-report?out=PATH` request the CLI sends the running app.
///
/// The app writes to `PATH`, so a request is only honoured for a new file under the temporary
/// directory, with no symbolic link on the way, and never for any other place on disk.
struct HeadsetReportRequest: Equatable {
    static let scheme = "untunnel"
    static let host = "headset-report"
    static let bundleIdentifier = "com.intesarjawad.untunnel"

    let out: URL

    init(url: URL, temporaryDirectory: URL = FileManager.default.temporaryDirectory) throws {
        guard
            url.scheme == Self.scheme,
            url.host == Self.host,
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else {
            throw HeadsetReportError.badRequest("not a \(Self.scheme)://\(Self.host) address")
        }
        let paths = items.filter { $0.name == "out" }.compactMap(\.value)
        guard paths.count == 1, let path = paths.first, path.hasPrefix("/"), !path.hasSuffix("/")
        else {
            throw HeadsetReportError.badRequest("out must be one absolute file path")
        }

        let requested = URL(fileURLWithPath: path).standardizedFileURL
        let name = requested.lastPathComponent
        let directory = requested.deletingLastPathComponent().resolvingSymlinksInPath().path
        let root = temporaryDirectory.resolvingSymlinksInPath().path
        guard directory == root || directory.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        else {
            throw HeadsetReportError.badRequest("out must be under the temporary directory")
        }
        let file = URL(fileURLWithPath: directory).appendingPathComponent(name)
        let type = try? FileManager.default.attributesOfItem(atPath: file.path)[.type]
        guard (type as? FileAttributeType) != .typeSymbolicLink else {
            throw HeadsetReportError.badRequest("out must not be a symbolic link")
        }
        out = file
    }

    /// The address that asks the app to write its report to `out`.
    static func url(out: URL) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.percentEncodedQueryItems = [
            URLQueryItem(
                name: "out",
                value: out.path.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            )
        ]
        return components.url ?? URL(fileURLWithPath: out.path)
    }
}

/// The app's side of a request: records through `capture`, then writes the report or the reason
/// it could not be made to the output file the CLI is waiting on.
enum HeadsetReportHandler {
    /// Throws only when the request itself is refused, because then there is no file to write to.
    static func handle(
        url: URL,
        capture: (@Sendable () async throws -> HeadsetCapture)?,
        profile: () throws -> Data = BluetoothProfile.read,
        macOSBuild: () throws -> String = HeadsetReport.currentMacOSBuild,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) async throws {
        let request = try HeadsetReportRequest(url: url, temporaryDirectory: temporaryDirectory)
        let data: Data
        do {
            guard let capture else {
                throw HeadsetReportError.recordingUnavailable
            }
            let measured = try await capture()
            let report = try HeadsetReport.make(
                capture: measured,
                profile: measured.identity == nil ? try profile() : Data(),
                macOSBuild: try macOSBuild()
            )
            data = try Output.jsonData(report)
        } catch {
            let reason = (error as? UserFacingError)?.message ?? String(describing: error)
            data = try Output.jsonData(HeadsetReportFailure(error: reason))
        }
        try data.write(to: request.out, options: .atomic)
    }
}

/// What `doctor --headset-report` needs from the machine, behind a protocol so a test never
/// opens an application.
protocol HeadsetReportSystem {
    var temporaryDirectory: URL { get }
    func isAppRunning() -> Bool
    func launchApp() throws
    func open(_ url: URL) throws
    func read(_ url: URL) -> Data?
    func remove(_ url: URL)
    func sleep(seconds: TimeInterval)
}

/// Asks the running app to record and prints what it wrote.
///
/// The CLI never opens the microphone: macOS would attribute the request to the terminal. It
/// opens an address instead, and the app, which owns the permission, does the recording.
enum HeadsetReportCommand {
    static let launchTimeout: TimeInterval = 10
    /// The reading takes five seconds; the rest is room for the person to begin.
    static let reportTimeout: TimeInterval = 120
    static let pollInterval: TimeInterval = 0.25

    static func run() -> Int32 {
        FileHandle.standardError.write(
            Data(
                ("Recording five seconds from the app's selected microphone. Read aloud now: "
                    + "The quick brown fox jumps over the lazy dog. Speak clearly until the report appears.\n"
                    + "Latency is capture-to-restored-hop plus model and reported device delay, not an acoustic round trip.\n"
                    + "Built-in inputs use 0x0000 IDs to mean not reported (not Bluetooth headset IDs).\n")
                    .utf8))
        let result = perform(system: LiveHeadsetReportSystem())
        result.output.write()
        return result.status
    }

    static func perform(
        system: any HeadsetReportSystem,
        launchTimeout: TimeInterval = launchTimeout,
        reportTimeout: TimeInterval = reportTimeout
    ) -> (status: Int32, output: CommandOutput) {
        var output = CommandOutput()
        do {
            if !system.isAppRunning() {
                try system.launchApp()
                guard
                    wait(
                        system, timeout: launchTimeout,
                        until: { system.isAppRunning() ? true : nil })
                        != nil
                else {
                    output.error(
                        .unexpected("Untunnel did not start within \(Int(launchTimeout)) s")
                    )
                    return (1, output)
                }
            }
            let out = system.temporaryDirectory.appendingPathComponent(
                "untunnel-headset-report-\(UUID().uuidString).json"
            )
            try system.open(HeadsetReportRequest.url(out: out))
            defer {
                system.remove(out)
            }
            guard let data = wait(system, timeout: reportTimeout, until: { system.read(out) })
            else {
                output.error(
                    .unexpected("Untunnel returned no report within \(Int(reportTimeout)) s")
                )
                return (1, output)
            }
            if let failure = try? JSONDecoder().decode(HeadsetReportFailure.self, from: data) {
                output.error(.unexpected(failure.error))
                return (1, output)
            }
            guard (try? JSONDecoder().decode(HeadsetReport.self, from: data)) != nil else {
                output.error(.unexpected("Untunnel wrote a report this version cannot read"))
                return (1, output)
            }
            output.line("```json")
            output.line(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
            output.line("```")
            return (0, output)
        } catch let error as UserFacingError {
            output.error(error)
            return (1, output)
        } catch {
            output.error(.unexpected(String(describing: error)))
            return (1, output)
        }
    }

    private static func wait<Value>(
        _ system: any HeadsetReportSystem,
        timeout: TimeInterval,
        until check: () -> Value?
    ) -> Value? {
        var waited: TimeInterval = 0
        while true {
            if let value = check() {
                return value
            }
            guard waited < timeout else {
                return nil
            }
            system.sleep(seconds: pollInterval)
            waited += pollInterval
        }
    }
}

struct LiveHeadsetReportSystem: HeadsetReportSystem {
    var temporaryDirectory: URL {
        FileManager.default.temporaryDirectory
    }

    func isAppRunning() -> Bool {
        LiveQuitSystem().runningPIDs().contains { $0 != getpid() }
    }

    func launchApp() throws {
        try openTool(["-g", "-b", HeadsetReportRequest.bundleIdentifier])
    }

    func open(_ url: URL) throws {
        try openTool(["-g", url.absoluteString])
    }

    func read(_ url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return nil
        }
        return data
    }

    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func sleep(seconds: TimeInterval) {
        usleep(UInt32(seconds * 1_000_000))
    }

    private func openTool(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UserFacingError.unexpected("open \(arguments.joined(separator: " ")) failed")
        }
    }
}
