import Foundation
import Testing
import UntunnelAudio
import UntunnelEngine

@testable import Untunnel

private let profileJSON = """
    {
      "SPBluetoothDataType": [
        {
          "controller_properties": { "controller_vendorID": "0x004C (Apple)" },
          "device_connected": [
            {
              "Example Buds": {
                "device_firmwareVersion": "3.1.5",
                "device_productID": "0x0F8A",
                "device_vendorID": "0x054C"
              }
            },
            {
              "No Ids": { "device_address": "AA:BB:CC:DD:EE:FF" }
            }
          ],
          "device_not_connected": [
            {
              "Sample Headset": {
                "device_productID": "0x2000",
                "device_vendorID": "0x004c (Apple)"
              }
            },
            {
              "Example Buds": {
                "device_productID": "0x0001",
                "device_vendorID": "0x0002"
              }
            }
          ]
        }
      ]
    }
    """

private func tones(_ components: [(hz: Double, amplitude: Double)], rate: Int) -> [Float] {
    (0..<(rate * 5)).map { index in
        let time = Double(index) / Double(rate)
        return Float(
            components.reduce(0) { $0 + $1.amplitude * sin(2 * .pi * $1.hz * time) }
        )
    }
}

private func demoCapture(name: String = "Example Buds") -> HeadsetCapture {
    let demo = HearYourselfDemo.take()
    return HeadsetCapture(
        take: ABTake(sampleRate: demo.sampleRate, before: demo.raw, after: demo.restored),
        headsetName: name,
        inputRateHz: 16_000,
        outputRateHz: 16_000,
        tier: Tier(sampleRate: 24_000, exitLayer: 5, lookAhead: 1),
        addedLatencyMs: 42.5
    )
}

private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func requestURL(
    _ path: String,
    scheme: String = "untunnel",
    host: String = "headset-report"
) -> URL {
    let encoded = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? path
    return URL(string: "\(scheme)://\(host)?out=\(encoded)") ?? URL(fileURLWithPath: "/")
}

@Test
func rolloffOfTheDemoTakeSitsAtItsHighestTone() throws {
    let demo = HearYourselfDemo.take()

    let raw = try Rolloff.hz(samples: demo.raw, sampleRate: demo.sampleRate)
    let restored = try Rolloff.hz(samples: demo.restored, sampleRate: demo.sampleRate)

    // The highest tone is 3000 Hz; a row is about half a percent wide.
    #expect((2_990...3_040).contains(raw))
    #expect((2_990...3_040).contains(restored))
}

@Test
func rolloffIgnoresComponentsMoreThanFortyDecibelsDown() throws {
    let samples = tones(
        [(hz: 1_000, amplitude: 1), (hz: 5_000, amplitude: 0.1), (hz: 7_000, amplitude: 0.001)],
        rate: 16_000
    )

    let rolloff = try Rolloff.hz(samples: samples, sampleRate: 16_000)

    #expect((4_990...5_050).contains(rolloff))
}

@Test
func rolloffIncludesAComponentJustInsideFortyDecibels() throws {
    let samples = tones(
        [(hz: 1_000, amplitude: 1), (hz: 7_000, amplitude: 0.012)],
        rate: 16_000
    )

    let rolloff = try Rolloff.hz(samples: samples, sampleRate: 16_000)

    #expect((6_990...7_060).contains(rolloff))
}

private struct NarrowbandFixture: Decodable {
    let sampleRate: Int
    let rolloff40db: Int

    enum CodingKeys: String, CodingKey {
        case sampleRate = "sample_rate_hz"
        case rolloff40db = "rolloff_40db_hz"
    }
}

@Test
func callMicFixtureRolloffMatchesTheCommittedValue() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let wav = try WAVFile(
        decoding: Data(contentsOf: root.appendingPathComponent("fixtures/narrowband/sample.wav"))
    )
    let fixture = try JSONDecoder().decode(
        NarrowbandFixture.self,
        from: Data(
            contentsOf: root.appendingPathComponent("fixtures/narrowband/sample.rolloff.json")
        )
    )

    let measured = try Rolloff.hz(samples: wav.samples, sampleRate: wav.sampleRate)

    #expect(wav.sampleRate == fixture.sampleRate)
    #expect(measured == fixture.rolloff40db)
}

@Test
func rolloffRefusesASilentOrTooShortTake() {
    #expect(throws: HeadsetReportError.silentTake) {
        try Rolloff.hz(samples: [Float](repeating: 0, count: 16_000), sampleRate: 16_000)
    }
    #expect(throws: HeadsetReportError.tooShort) {
        try Rolloff.hz(samples: [Float](repeating: 0.5, count: 1_000), sampleRate: 16_000)
    }
}

@Test
func bluetoothProfilePrefersAConnectedDeviceAndNormalisesIDs() {
    let data = Data(profileJSON.utf8)

    #expect(
        BluetoothProfile.identity(named: "Example Buds", in: data)
            == HeadsetIdentity(
                name: "Example Buds",
                vendorID: "0x054C",
                productID: "0x0F8A",
                firmware: "3.1.5"
            )
    )
    #expect(
        BluetoothProfile.identity(named: "Sample Headset", in: data)
            == HeadsetIdentity(
                name: "Sample Headset",
                vendorID: "0x004C",
                productID: "0x2000",
                firmware: nil
            )
    )
}

@Test
func bluetoothProfileFindsNothingWithoutIDsOrAName() {
    let data = Data(profileJSON.utf8)

    #expect(BluetoothProfile.identity(named: "No Ids", in: data) == nil)
    #expect(BluetoothProfile.identity(named: "Missing", in: data) == nil)
    #expect(BluetoothProfile.identity(named: "Example Buds", in: Data("[]".utf8)) == nil)
}

@Test
func hexIDsAreFourUppercaseDigits() {
    #expect(BluetoothProfile.normalizedID("0x4a43") == "0x4A43")
    #expect(BluetoothProfile.normalizedID("0x004C (Apple)") == "0x004C")
    #expect(BluetoothProfile.normalizedID("4A43") == nil)
    #expect(BluetoothProfile.normalizedID("0x12345") == nil)
    #expect(BluetoothProfile.normalizedID("0xZZ") == nil)
    #expect(BluetoothProfile.normalizedID("") == nil)
}

@Test
func reportCarriesTheCaptureTheProfileAndTheBuild() throws {
    let report = try HeadsetReport.make(
        capture: demoCapture(),
        profile: Data(profileJSON.utf8),
        macOSBuild: "26A1234"
    )

    #expect(report.schemaVersion == 1)
    #expect(report.headset.productID == "0x0F8A")
    #expect(report.callMode == HeadsetCallMode(inputRateHz: 16_000, outputRateHz: 16_000))
    #expect(report.tier == DoctorTier(sampleRate: 24_000, exitLayer: 5, lookAhead: 1))
    #expect(report.addedLatencyMs == 42.5)
    #expect(report.macOSBuild == "26A1234")
    #expect((2_990...3_040).contains(report.rolloff40dbHz.raw))
    #expect((2_990...3_040).contains(report.rolloff40dbHz.untunnel))
}

@Test
func reportJSONUsesTheSchemaKeys() throws {
    let report = try HeadsetReport.make(
        capture: demoCapture(),
        profile: Data(profileJSON.utf8),
        macOSBuild: "26A1234"
    )

    let object = try #require(
        try JSONSerialization.jsonObject(with: Output.jsonData(report)) as? [String: Any]
    )
    let headset = try #require(object["headset"] as? [String: Any])
    let rolloff = try #require(object["rolloff_40db_hz"] as? [String: Any])

    #expect(
        Set(object.keys)
            == [
                "schema_version", "headset", "call_mode", "tier", "added_latency_ms",
                "macos_build", "rolloff_40db_hz",
            ]
    )
    #expect(Set(headset.keys) == ["name", "vendor_id", "product_id", "firmware"])
    #expect(Set(rolloff.keys) == ["raw", "untunnel"])
}

@Test
func reportRefusesAHeadsetMacOSDoesNotList() {
    #expect(throws: HeadsetReportError.headsetNotFound("Other")) {
        try HeadsetReport.make(
            capture: demoCapture(name: "Other"),
            profile: Data(profileJSON.utf8),
            macOSBuild: "26A1234"
        )
    }
}

@Test
func requestAcceptsANewFileUnderTheTemporaryDirectory() throws {
    let root = try makeDirectory()
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let expected = root.resolvingSymlinksInPath().appendingPathComponent("a b.json").path

    let request = try HeadsetReportRequest(
        url: requestURL(root.appendingPathComponent("a b.json").path),
        temporaryDirectory: root
    )

    #expect(request.out.path == expected)
}

@Test
func requestRefusesEveryPathOutsideTheTemporaryDirectory() throws {
    let root = try makeDirectory()
    let outside = try makeDirectory()
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }
    let paths = [
        "/etc/passwd",
        "/tmp/report.json",
        outside.appendingPathComponent("report.json").path,
        root.path + "/../escape.json",
        root.path,
        root.path + "/",
        root.path + "/nested/",
        "report.json",
        "",
    ]

    for path in paths {
        #expect(throws: HeadsetReportError.self, "\(path)") {
            try HeadsetReportRequest(url: requestURL(path), temporaryDirectory: root)
        }
    }
}

@Test
func requestRefusesASymbolicLinkOnTheWayOrAtTheEnd() throws {
    let root = try makeDirectory()
    let outside = try makeDirectory()
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }
    let directoryLink = root.appendingPathComponent("link")
    let fileLink = root.appendingPathComponent("report.json")
    try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: outside)
    try FileManager.default.createSymbolicLink(
        at: fileLink,
        withDestinationURL: outside.appendingPathComponent("target.json")
    )

    #expect(throws: HeadsetReportError.self) {
        try HeadsetReportRequest(
            url: requestURL(directoryLink.appendingPathComponent("report.json").path),
            temporaryDirectory: root
        )
    }
    #expect(throws: HeadsetReportError.self) {
        try HeadsetReportRequest(url: requestURL(fileLink.path), temporaryDirectory: root)
    }
}

@Test
func requestRefusesAnotherAddressOrAnAmbiguousOut() throws {
    let root = try makeDirectory()
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let path = root.appendingPathComponent("report.json").path
    let encoded = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? path
    let urls = [
        requestURL(path, scheme: "https"),
        requestURL(path, host: "other"),
        URL(string: "untunnel://headset-report"),
        URL(string: "untunnel://headset-report?path=\(encoded)"),
        URL(string: "untunnel://headset-report?out=\(encoded)&out=\(encoded)"),
    ]

    for url in urls.compactMap({ $0 }) {
        #expect(throws: HeadsetReportError.self, "\(url)") {
            try HeadsetReportRequest(url: url, temporaryDirectory: root)
        }
    }
}

@Test
func requestAddressRoundTripsAPathWithSpecialCharacters() throws {
    let root = try makeDirectory()
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let out = root.appendingPathComponent("a b+c&d.json")

    let request = try HeadsetReportRequest(
        url: HeadsetReportRequest.url(out: out),
        temporaryDirectory: root
    )

    #expect(request.out.path == root.resolvingSymlinksInPath().path + "/a b+c&d.json")
}

@Test
func handlerWritesTheReportToTheRequestedFile() async throws {
    let root = try makeDirectory()
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let out = root.appendingPathComponent("report.json")

    try await HeadsetReportHandler.handle(
        url: HeadsetReportRequest.url(out: out),
        capture: { demoCapture() },
        profile: { Data(profileJSON.utf8) },
        macOSBuild: { "26A1234" },
        temporaryDirectory: root
    )

    let report = try JSONDecoder().decode(HeadsetReport.self, from: Data(contentsOf: out))
    #expect(report.headset.name == "Example Buds")
    #expect(report.macOSBuild == "26A1234")
}

@Test
func handlerWritesTheReasonWhenTheTakeFails() async throws {
    let root = try makeDirectory()
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let out = root.appendingPathComponent("report.json")
    let silent = HeadsetCapture(
        take: ABTake(
            sampleRate: 16_000,
            before: [Float](repeating: 0, count: 16_000),
            after: [Float](repeating: 0, count: 16_000)
        ),
        headsetName: "Example Buds",
        inputRateHz: 16_000,
        outputRateHz: 16_000,
        tier: Tier(sampleRate: 24_000, exitLayer: 5, lookAhead: 1),
        addedLatencyMs: 40
    )

    try await HeadsetReportHandler.handle(
        url: HeadsetReportRequest.url(out: out),
        capture: { silent },
        profile: { Data(profileJSON.utf8) },
        macOSBuild: { "26A1234" },
        temporaryDirectory: root
    )
    let failure = try JSONDecoder().decode(
        HeadsetReportFailure.self,
        from: Data(contentsOf: out)
    )

    #expect(failure.error == HeadsetReportError.silentTake.description)
}

@Test
func handlerWithoutARecordingPathSaysSo() async throws {
    let root = try makeDirectory()
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let out = root.appendingPathComponent("report.json")

    try await HeadsetReportHandler.handle(
        url: HeadsetReportRequest.url(out: out),
        capture: nil,
        temporaryDirectory: root
    )
    let failure = try JSONDecoder().decode(
        HeadsetReportFailure.self,
        from: Data(contentsOf: out)
    )

    #expect(failure.error == HeadsetReportError.recordingUnavailable.description)
}

@Test
func handlerWritesNothingForARefusedRequest() async throws {
    let root = try makeDirectory()
    let outside = try makeDirectory()
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }
    let out = outside.appendingPathComponent("report.json")

    await #expect(throws: HeadsetReportError.self) {
        try await HeadsetReportHandler.handle(
            url: requestURL(out.path),
            capture: { demoCapture() },
            profile: { Data(profileJSON.utf8) },
            macOSBuild: { "26A1234" },
            temporaryDirectory: root
        )
    }

    #expect(!FileManager.default.fileExists(atPath: out.path))
}

private final class FakeHeadsetReportSystem: HeadsetReportSystem {
    let temporaryDirectory = FileManager.default.temporaryDirectory
    var running: [Bool]
    var answer: Data?
    var readsBeforeAnswer = 0
    private(set) var launched = false
    private(set) var opened: [URL] = []
    private(set) var removed: [URL] = []
    private var reads = 0

    init(running: [Bool], answer: Data?) {
        self.running = running
        self.answer = answer
    }

    func isAppRunning() -> Bool {
        running.count > 1 ? running.removeFirst() : (running.first ?? false)
    }

    func launchApp() throws {
        launched = true
    }

    func open(_ url: URL) throws {
        opened.append(url)
    }

    func read(_ url: URL) -> Data? {
        reads += 1
        return reads > readsBeforeAnswer ? answer : nil
    }

    func remove(_ url: URL) {
        removed.append(url)
    }

    func sleep(seconds: TimeInterval) {}
}

private func reportData() throws -> Data {
    try Output.jsonData(
        HeadsetReport(
            schemaVersion: 1,
            headset: HeadsetIdentity(
                name: "Example Buds",
                vendorID: "0x054C",
                productID: "0x0F8A",
                firmware: nil
            ),
            callMode: HeadsetCallMode(inputRateHz: 16_000, outputRateHz: 16_000),
            tier: DoctorTier(sampleRate: 24_000, exitLayer: 5, lookAhead: 1),
            addedLatencyMs: 40,
            macOSBuild: "26A1234",
            rolloff40dbHz: HeadsetRolloff(raw: 3_000, untunnel: 3_100)
        )
    )
}

@Test
func commandPrintsTheReportAsOneFencedJSONBlock() throws {
    let data = try reportData()
    let system = FakeHeadsetReportSystem(running: [true], answer: data)
    system.readsBeforeAnswer = 3

    let result = HeadsetReportCommand.perform(system: system)

    let json = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    #expect(result.status == 0)
    #expect(result.output.text == "```json\n\(json)\n```\n")
    #expect(!system.launched)
    #expect(system.opened.count == 1)
    #expect(system.opened.first?.scheme == "untunnel")
    #expect(system.opened.first?.host == "headset-report")
    #expect(system.removed.count == 1)
}

@Test
func commandOpensTheAppFirstAndWaitsForItToRun() throws {
    let system = FakeHeadsetReportSystem(
        running: [false, false, false, true], answer: try reportData())

    let result = HeadsetReportCommand.perform(system: system)

    #expect(result.status == 0)
    #expect(system.launched)
    #expect(system.opened.count == 1)
}

@Test
func commandGivesUpWhenTheAppNeverStarts() throws {
    let system = FakeHeadsetReportSystem(running: [false], answer: try reportData())

    let result = HeadsetReportCommand.perform(system: system, launchTimeout: 10)

    #expect(result.status == 1)
    #expect(system.launched)
    #expect(system.opened.isEmpty)
    #expect(result.output.errorText.contains("Untunnel did not start within 10 s"))
}

@Test
func commandReportsWhyTheAppCouldNotMakeAReport() throws {
    let failure = try Output.jsonData(HeadsetReportFailure(error: "the recording was silent"))
    let system = FakeHeadsetReportSystem(running: [true], answer: failure)

    let result = HeadsetReportCommand.perform(system: system)

    #expect(result.status == 1)
    #expect(result.output.text.isEmpty)
    #expect(result.output.errorText.contains("the recording was silent"))
}

@Test
func commandReportsAnAppThatNeverAnswers() {
    let system = FakeHeadsetReportSystem(running: [true], answer: nil)

    let result = HeadsetReportCommand.perform(system: system, reportTimeout: 1)

    #expect(result.status == 1)
    #expect(result.output.errorText.contains("returned no report within 1 s"))
    #expect(system.removed.count == 1)
}

@Test
func commandRefusesAnAnswerItCannotRead() {
    let system = FakeHeadsetReportSystem(running: [true], answer: Data("{}".utf8))

    let result = HeadsetReportCommand.perform(system: system)

    #expect(result.status == 1)
    #expect(result.output.errorText.contains("a report this version cannot read"))
}

@Test
func doctorHeadsetReportTakesNoOtherOption() throws {
    #expect(try DoctorOptions(arguments: ["--headset-report"]).headsetReport)
    #expect(throws: UserFacingError.self) {
        try DoctorOptions(arguments: ["--headset-report", "--json"])
    }
    #expect(throws: UserFacingError.self) {
        try DoctorOptions(arguments: ["--offline", "--headset-report"])
    }
}

@Test
func printedHeadsetReportIsAcceptedByTheSiteParser() throws {
    let system = FakeHeadsetReportSystem(running: [true], answer: try reportData())
    let result = HeadsetReportCommand.perform(system: system)
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "python3", "-c",
        "import sys; from untunnel_tools.site.headsets import check; report, errors = check(sys.stdin.read()); assert report is not None and not errors, errors",
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["PYTHONPATH"] = root.appendingPathComponent("tools/src").path
    process.environment = environment
    let pipe = Pipe()
    process.standardInput = pipe
    try process.run()
    pipe.fileHandleForWriting.write(Data(result.output.text.utf8))
    try pipe.fileHandleForWriting.close()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

@Test
func builtInIdentityIsExplicitlyUnreportedAndNeedsNoBluetoothProfile() throws {
    var capture = demoCapture(name: "Built-in Microphone")
    capture.identity = HeadsetIdentity(
        name: capture.headsetName, vendorID: "0x0000", productID: "0x0000", firmware: nil)
    let report = try HeadsetReport.make(capture: capture, profile: Data(), macOSBuild: "26A1234")
    #expect(report.headset == capture.identity)
}

@Test
func liveHeadsetReportResolvesTheSelectedInputBeforeOpeningCapture() throws {
    let model = LoadedModel()
    var map = WeightMap(try SafeTensors(data: checkpoint(modelShapes())))
    model.current = .ready(
        weights: try RealtimeRestorerWeights(map: &map, exitLayer: 1),
        tier: Tier(sampleRate: 8_000, exitLayer: 1, lookAhead: 0))
    let selected = device("built-in", "Built-in Microphone", .builtIn, input: true, output: false)
    let headset = device("buds", "Example Buds", .bluetooth, input: true, output: true)
    let expected = UserFacingError.audioDeviceUnavailable("test capture failure")
    #expect(throws: expected) {
        try HeadsetReportCapture.record(
            model: model,
            selection: {
                DeviceSelection(virtualMic: nil, headset: headset, input: selected, output: headset)
            },
            capture: { uid in
                #expect(uid == "built-in")
                throw expected
            },
            profile: {
                Issue.record("Built-in input must not query Bluetooth identity"); return Data()
            })
    }
}

@Test
func liveHeadsetReportRefusesToLabelPassThroughAsRestored() {
    let input = device("built-in", "Built-in Microphone", .builtIn, input: true, output: false)
    #expect(throws: UserFacingError.modelMissing) {
        try HeadsetReportCapture.record(
            model: LoadedModel(),
            selection: {
                DeviceSelection(virtualMic: nil, headset: nil, input: input, output: input)
            },
            capture: { _ in
                Issue.record("Missing models must fail before opening the microphone");
                return FakeCapture()
            })
    }
}

@Test
func reportMeasuresNativeInputBandwidthBeforeTierResampling() throws {
    let lowRate = 16_000
    let low = tones([(2_000, 0.4)], rate: lowRate)
    let capture = HeadsetCapture(
        take: ABTake(sampleRate: lowRate, before: low, after: low),
        headsetName: "Example Buds", inputRateHz: 48_000, outputRateHz: 48_000,
        tier: Tier(sampleRate: lowRate, exitLayer: 1, lookAhead: 0), addedLatencyMs: 40,
        rawInput: tones([(12_000, 0.4)], rate: 48_000))
    let report = try HeadsetReport.make(
        capture: capture, profile: Data(profileJSON.utf8), macOSBuild: "26A1234")
    #expect(report.rolloff40dbHz.raw > 11_000)
    #expect(report.rolloff40dbHz.untunnel < 3_000)
}
