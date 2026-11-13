import Foundation

/// Collects the lines one command prints.
///
/// Commands build their output here before writing it, so a golden test can compare the exact
/// text and a failed step can still be reported after the work that produced it.
struct CommandOutput: Equatable {
    private(set) var lines: [String] = []
    private(set) var errorLines: [String] = []

    mutating func line(_ text: String = "") {
        lines.append(text)
    }

    mutating func error(_ text: String) {
        errorLines.append(text)
    }

    mutating func error(_ error: UserFacingError) {
        errorLines.append(error.message)
        errorLines.append("Fix: \(error.fix)")
    }

    var text: String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    var errorText: String {
        errorLines.isEmpty ? "" : errorLines.joined(separator: "\n") + "\n"
    }

    func write() {
        FileHandle.standardOutput.write(Data(text.utf8))
        FileHandle.standardError.write(Data(errorText.utf8))
    }
}

/// One timed step of a command that changes the machine.
struct StepTiming: Codable, Equatable {
    let step: Int
    let name: String
    let seconds: Double
}

/// The document `--timings-json` writes, so a slow step can be found without reading a terminal.
struct TimingsDocument: Codable, Equatable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let steps: [StepTiming]

    init(steps: [StepTiming]) {
        schemaVersion = Self.schemaVersion
        self.steps = steps
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case steps
    }
}

enum Output {
    static func seconds(_ value: Double) -> String {
        String(format: "%.2f s", value)
    }

    static func jsonData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    static func writeJSON<T: Encodable>(_ value: T, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try jsonData(value).write(to: url, options: .atomic)
    }
}
