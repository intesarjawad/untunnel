import Foundation
import Testing
import UntunnelAudio

@testable import Untunnel

private let exampleHome = URL(fileURLWithPath: "/Users/example")

private func sampleReport() -> DoctorReport {
    DoctorReport(
        schemaVersion: DoctorReport.schemaVersion,
        offline: true,
        macOS: "15.4",
        architecture: "arm64",
        installed: DoctorInstalledReport(
            path: "/Users/example/Applications/Untunnel.app",
            version: "0.1.0",
            build: "1",
            binaryOk: true,
            signatureOk: true
        ),
        devices: nil,
        virtualMic: DoctorVirtualMicReport(kind: "own", present: true),
        autoRoute: DoctorToggle(enabled: true),
        autoEngage: DoctorToggle(enabled: false),
        model: DoctorModelReport(
            present: true,
            repo: "nvidia/re-use",
            revision: "abc123",
            path: "/Users/example/Library/Application Support/Untunnel/model",
            sha256Ok: true,
            files: [DoctorModelFile(path: "model.safetensors", sha256Ok: true)]
        ),
        tiers: [
            DoctorTier(sampleRate: 16_000, exitLayer: 4, lookAhead: 0),
            DoctorTier(sampleRate: 24_000, exitLayer: 5, lookAhead: 1),
            DoctorTier(sampleRate: 32_000, exitLayer: 6, lookAhead: 1),
            DoctorTier(sampleRate: 48_000, exitLayer: 7, lookAhead: 1),
        ],
        strayTaps: [],
        strayAggregates: ["Untunnel Aggregate"]
    )
}

@Test
func doctorPrintsTheOfflineReportInAStableOrder() {
    let expected =
        [
            "Untunnel doctor (offline)",
            "",
            "macOS: 15.4 (arm64)",
            "Installed: 0.1.0 (build 1) at /Users/example/Applications/Untunnel.app",
            "Binary: ok",
            "Signature: ok",
            "Virtual mic: own (present)",
            "Auto-route: on",
            "Model: nvidia/re-use at abc123",
            "Hashes: ok",
            "Auto-engage: off",
            "Tiers:",
            "  16000 Hz  exit 4  look-ahead 0",
            "  24000 Hz  exit 5  look-ahead 1",
            "  32000 Hz  exit 6  look-ahead 1",
            "  48000 Hz  exit 7  look-ahead 1",
            "Stray taps: none",
            "Stray aggregates: Untunnel Aggregate",
            "Devices: not queried (offline)",
        ].joined(separator: "\n") + "\n"

    #expect(Doctor.text(sampleReport()) == expected)
}

@Test
func doctorJSONCarriesTheVirtualMicAndModelHashes() throws {
    let data = try Output.jsonData(sampleReport())
    let object = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let virtualMic = try #require(object["virtual_mic"] as? [String: Any])
    let model = try #require(object["model"] as? [String: Any])

    #expect(object["schema_version"] as? Int == 1)
    #expect(virtualMic["present"] as? Bool == true)
    #expect(virtualMic["kind"] as? String == "own")
    #expect(model["sha256_ok"] as? Bool == true)
}

@Test
func doctorOfflineReportsNoDevicesAndNoModelWithoutAnInstall() {
    let paths = InstalledPaths(home: exampleHome)

    let report = Doctor.report(offline: true, paths: paths)

    #expect(report.devices == nil)
    #expect(report.model.sha256Ok == false)
    #expect(report.installed.version == nil)
    #expect(report.virtualMic.present == false)
}

@Test
func doctorHashesTheModelFilesItFinds() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    defer {
        try? FileManager.default.removeItem(at: home)
    }
    let paths = InstalledPaths(home: home)
    try FileManager.default.createDirectory(
        at: paths.model,
        withIntermediateDirectories: true
    )
    let payload = Data("abc".utf8)
    try payload.write(to: paths.model.appendingPathComponent("model.bin"))
    let manifest = ModelManifest(
        repo: "nvidia/re-use",
        revision: "abc123",
        files: [
            ModelManifestFile(
                path: "model.bin",
                sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
            )
        ]
    )
    try JSONEncoder().encode(manifest).write(to: paths.modelManifest)

    let report = Doctor.report(offline: true, paths: paths)

    #expect(report.model.present)
    #expect(report.model.sha256Ok)
    #expect(report.model.files == [DoctorModelFile(path: "model.bin", sha256Ok: true)])
}

@Test
func doctorMarksAChangedModelFile() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    defer {
        try? FileManager.default.removeItem(at: home)
    }
    let paths = InstalledPaths(home: home)
    try FileManager.default.createDirectory(
        at: paths.model,
        withIntermediateDirectories: true
    )
    try Data("changed".utf8).write(to: paths.model.appendingPathComponent("model.bin"))
    let manifest = ModelManifest(
        repo: "nvidia/re-use",
        revision: "abc123",
        files: [
            ModelManifestFile(
                path: "model.bin",
                sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
            )
        ]
    )
    try JSONEncoder().encode(manifest).write(to: paths.modelManifest)

    let report = Doctor.report(offline: true, paths: paths)

    #expect(report.model.present)
    #expect(report.model.sha256Ok == false)
}

@Test
func doctorReadsThePreferencesFile() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    defer {
        try? FileManager.default.removeItem(at: home)
    }
    let paths = InstalledPaths(home: home)
    try FileManager.default.createDirectory(
        at: paths.support,
        withIntermediateDirectories: true
    )
    try Data(#"{"auto_route":false,"auto_engage":true}"#.utf8)
        .write(to: paths.preferences)

    let report = Doctor.report(offline: true, paths: paths)

    #expect(report.autoRoute.enabled == false)
    #expect(report.autoEngage.enabled == true)
}

@Test
func doctorMarkdownPointsAtTheReportAndAGoodFirstIssue() {
    let markdown = Doctor.markdown(sampleReport())

    #expect(markdown.hasPrefix("# Untunnel doctor report\n"))
    #expect(markdown.contains("Untunnel doctor (offline)"))
    #expect(markdown.contains("## Good first issue"))
    #expect(markdown.contains("Paste this report into the issue."))
}

private func snapshot(
    named names: [(name: String, transport: AudioTransport)]
) -> AudioDevices.Snapshot {
    AudioDevices.Snapshot(
        devices: names.enumerated().map { index, entry in
            AudioDevice(
                uid: "fixture-\(index)",
                name: entry.name,
                transport: entry.transport,
                hasInput: true,
                hasOutput: true,
                nominalSampleRate: 48_000,
                dataSource: .none
            )
        },
        defaultInputUID: nil,
        defaultOutputUID: nil,
        selection: DeviceSelection(virtualMic: nil, headset: nil, input: nil, output: nil)
    )
}

@Test
func doctorReportsAnyDeviceNamedLikeTheTapAsAStrayTap() {
    let devices = snapshot(named: [
        (name: "MacBook Pro Microphone", transport: .builtIn),
        (name: "Untunnel Tap", transport: .aggregate),
        (name: "Untunnel Tap", transport: .other),
    ])

    #expect(Doctor.strayTaps(devices) == ["Untunnel Tap", "Untunnel Tap"])
    #expect(Doctor.strayAggregates(devices).isEmpty)
}

@Test
func doctorKeepsOtherAggregatesApartFromTheTap() {
    let devices = snapshot(named: [
        (name: "Untunnel Aggregate", transport: .aggregate),
        (name: "Studio Aggregate", transport: .aggregate),
    ])

    #expect(Doctor.strayTaps(devices).isEmpty)
    #expect(Doctor.strayAggregates(devices) == ["Untunnel Aggregate"])
    #expect(Doctor.strayTaps(nil).isEmpty)
}
