import CryptoKit
import Foundation
import Testing
import UntunnelEngine

@testable import Untunnel

private final class FakeFetcher: ModelFetcher {
    var served: [String: Data] = [:]
    private(set) var requested: [String] = []

    func fetch(_ url: URL, to destination: URL) throws {
        requested.append(url.absoluteString)
        guard let data = served[url.absoluteString] else {
            throw ModelFetchError.status(404)
        }
        try data.write(to: destination)
    }
}

private final class FailingFetcher: ModelFetcher {
    let error: Error
    private(set) var requests = 0

    init(_ error: Error) {
        self.error = error
    }

    func fetch(_ url: URL, to destination: URL) throws {
        requests += 1
        try Data("partial".utf8).write(to: destination)
        throw error
    }
}

private struct Run {
    let outcome: Download.Outcome
    let lines: [String]

    var errorText: String {
        outcome.errors.errorText
    }
}

private func makeHome() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

private func run(
    _ arguments: [String],
    home: URL,
    pins: ModelPins = ModelPins(streaming: nil, offline: nil),
    fetcher: any ModelFetcher,
    availableBytes: @escaping (URL) -> Int64? = { _ in nil }
) -> Run {
    var lines: [String] = []
    let outcome = Download.perform(
        arguments: arguments,
        paths: InstalledPaths(home: home),
        pins: pins,
        fetcher: fetcher,
        availableBytes: availableBytes,
        emit: { lines.append($0) }
    )
    return Run(outcome: outcome, lines: lines)
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func url(_ repo: String, _ revision: String, _ file: String) -> String {
    "https://huggingface.co/\(repo)/resolve/\(revision)/\(file)"
}

private func storedFiles(in home: URL) -> [String] {
    let models = InstalledPaths(home: home).models
    let enumerator = FileManager.default.enumerator(atPath: models.path)
    return (enumerator?.allObjects as? [String] ?? []).sorted()
}

/// The shapes of a one-block model in the published layout, which the engine's parity suite
/// checks against the header of the real checkpoint.
func modelShapes() -> [String: [Int]] {
    Dictionary(
        uniqueKeysWithValues: RealtimeModelLayout.tensors(blockCount: 1).map {
            ($0.name, $0.shape)
        })
}

func checkpoint(_ shapes: [String: [Int]]) -> Data {
    var offset = 0
    var entries: [String] = []
    for (name, shape) in shapes.sorted(by: { $0.key < $1.key }) {
        let size = shape.reduce(1, *) * 4
        let dimensions = shape.map(String.init).joined(separator: ",")
        entries.append(
            "\"\(name)\":{\"dtype\":\"F32\",\"shape\":[\(dimensions)],"
                + "\"data_offsets\":[\(offset),\(offset + size)]}"
        )
        offset += size
    }
    let header = Array(("{" + entries.joined(separator: ",") + "}").utf8)
    let prefix = (0..<8).map { UInt8(truncatingIfNeeded: UInt64(header.count) >> (8 * UInt64($0))) }
    return Data(prefix + header + [UInt8](repeating: 0, count: offset))
}

private let configData = Data(#"{"exit_layer":1}"#.utf8)

private func serve(
    _ fetcher: FakeFetcher,
    repo: String,
    revision: String,
    checkpoint: Data,
    config: Data = configData
) {
    fetcher.served[url(repo, revision, "model.safetensors")] = checkpoint
    fetcher.served[url(repo, revision, "config.json")] = config
}

@Test
func downloadingAndReusingTheOfflineModelKeepsTheLiveStreamingSelection() throws {
    let home = makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let data = Data("checkpoint".utf8)
    let config = Data("{}".utf8)
    func pin(_ name: String) -> ModelPin {
        ModelPin(
            repo: "example/\(name)", revision: "r1",
            files: [
                ModelPinFile(name: "model.safetensors", sha256: sha256(data), size: data.count),
                ModelPinFile(name: "config.json", sha256: sha256(config), size: config.count),
            ], licence: nil)
    }
    let pins = ModelPins(streaming: pin("stream"), offline: pin("offline"))
    let fetcher = FakeFetcher()
    for name in ["stream", "offline"] {
        serve(fetcher, repo: "example/\(name)", revision: "r1", checkpoint: data, config: config)
    }
    #expect(run([], home: home, pins: pins, fetcher: fetcher).outcome.failure == nil)
    for _ in 0..<2 {
        #expect(
            run(["--offline-model"], home: home, pins: pins, fetcher: fetcher).outcome.failure
                == nil)
        #expect(
            Doctor.report(offline: true, paths: InstalledPaths(home: home)).model.repo
                == "example/stream")
    }
    #expect(
        FileManager.default.fileExists(
            atPath: InstalledPaths(home: home).models.appendingPathComponent(
                "example/offline@r1/model.safetensors"
            ).path))
}

@Test
func downloadParsesTheModelAndItsHash() throws {
    let hash = String(repeating: "AB", count: 32)

    let options = try DownloadOptions(arguments: ["--model", "owner/name@main", "--sha256", hash])

    #expect(options.model == (try ModelReference(parsing: "owner/name@main")))
    #expect(options.sha256 == hash.lowercased())
    #expect(try DownloadOptions(arguments: ["--offline-model"]).offlineModel)
}

@Test
func downloadRefusesOptionsThatDoNotFit() {
    let hash = String(repeating: "a", count: 64)
    let bad: [[String]] = [
        ["--model", "owner/name@main"],
        ["--sha256", hash],
        ["--model", "owner/name@main", "--sha256", hash, "--offline-model"],
        ["--model", "owner/name@main", "--sha256", "abc"],
        ["--model", "../name@main", "--sha256", hash],
        ["--model", "owner/name@a/b", "--sha256", hash],
        ["--model", "owner/name", "--sha256", hash],
        ["--model"],
        ["--unknown"],
    ]
    for arguments in bad {
        #expect(throws: UserFacingError.self, "\(arguments)") {
            _ = try DownloadOptions(arguments: arguments)
        }
    }
}

@Test
func downloadWithoutARecordedCheckpointSaysSoAndWritesNothing() {
    let home = makeHome()
    defer {
        try? FileManager.default.removeItem(at: home)
    }
    let fetcher = FakeFetcher()

    let result = run([], home: home, fetcher: fetcher)

    #expect(result.errorText.contains("No download is recorded for the streaming model."))
    #expect(result.errorText.contains("--model <repo>@<revision> --sha256 <hex>"))
    #expect(fetcher.requested.isEmpty)
    #expect(storedFiles(in: home).isEmpty)
}

@Test
func downloadStoresAVerifiedCheckpointAndAnnouncesItsLicenceOnce() throws {
    let home = makeHome()
    defer {
        try? FileManager.default.removeItem(at: home)
    }
    let weights = Data("weights".utf8)
    let config = Data("{}".utf8)
    let pin = ModelPin(
        repo: "example/stream",
        revision: "r1",
        files: [
            ModelPinFile(name: "model.safetensors", sha256: sha256(weights), size: weights.count),
            ModelPinFile(name: "config.json", sha256: nil, size: nil),
        ],
        licence: "Licence: example terms."
    )
    let fetcher = FakeFetcher()
    serve(fetcher, repo: "example/stream", revision: "r1", checkpoint: weights, config: config)

    let result = run(
        [],
        home: home,
        pins: ModelPins(streaming: pin, offline: nil),
        fetcher: fetcher
    )

    #expect(result.errorText.isEmpty)
    #expect(
        fetcher.requested == [
            "https://huggingface.co/example/stream/resolve/r1/model.safetensors",
            "https://huggingface.co/example/stream/resolve/r1/config.json",
        ]
    )
    #expect(result.lines.filter { $0.hasPrefix("Licence:") } == ["Licence: example terms."])
    let stored = InstalledPaths(home: home).models.appendingPathComponent("example/stream@r1")
    #expect(try Data(contentsOf: stored.appendingPathComponent("model.safetensors")) == weights)
    #expect(
        storedFiles(in: home).sorted() == [
            "example", "example/stream@r1", "example/stream@r1/config.json",
            "example/stream@r1/manifest.json", "example/stream@r1/model.safetensors",
        ]
    )

    let report = Doctor.report(offline: true, paths: InstalledPaths(home: home))
    #expect(report.model.repo == "example/stream")
    #expect(report.model.revision == "r1")
    #expect(report.model.sha256Ok)
}

@Test
func downloadRunsAgainWithoutFetchingWhenTheStoredFilesStillMatch() {
    let home = makeHome()
    defer {
        try? FileManager.default.removeItem(at: home)
    }
    let weights = Data("weights".utf8)
    let pin = ModelPin(
        repo: "example/stream",
        revision: "r1",
        files: [ModelPinFile(name: "model.safetensors", sha256: sha256(weights), size: nil)],
        licence: nil
    )
    let fetcher = FakeFetcher()
    serve(fetcher, repo: "example/stream", revision: "r1", checkpoint: weights)
    let pins = ModelPins(streaming: pin, offline: nil)
    _ = run([], home: home, pins: pins, fetcher: fetcher)
    let first = fetcher.requested.count

    let result = run([], home: home, pins: pins, fetcher: fetcher)

    #expect(result.errorText.isEmpty)
    #expect(fetcher.requested.count == first)
    #expect(result.lines.contains { $0.hasPrefix("Already downloaded") })
}

@Test
func downloadWithACorruptedByteFailsAndLeavesNothingInPlace() {
    let home = makeHome()
    defer {
        try? FileManager.default.removeItem(at: home)
    }
    let weights = Data("weights".utf8)
    var corrupted = weights
    corrupted[3] ^= 0x01
    let pin = ModelPin(
        repo: "example/stream",
        revision: "r1",
        files: [
            ModelPinFile(name: "model.safetensors", sha256: sha256(weights), size: weights.count)
        ],
        licence: nil
    )
    let fetcher = FakeFetcher()
    serve(fetcher, repo: "example/stream", revision: "r1", checkpoint: corrupted)

    let result = run(
        [],
        home: home,
        pins: ModelPins(streaming: pin, offline: nil),
        fetcher: fetcher
    )

    #expect(result.errorText.contains("failed its check and was discarded"))
    #expect(result.errorText.contains(sha256(weights)))
    #expect(storedFiles(in: home).isEmpty)
    #expect(Doctor.report(offline: true, paths: InstalledPaths(home: home)).model.present == false)
}

@Test
func downloadRejectsAFileOfTheWrongSize() {
    let home = makeHome()
    defer {
        try? FileManager.default.removeItem(at: home)
    }
    let weights = Data("weights".utf8)
    let pin = ModelPin(
        repo: "example/stream",
        revision: "r1",
        files: [
            ModelPinFile(name: "model.safetensors", sha256: sha256(weights), size: 99)
        ],
        licence: nil
    )
    let fetcher = FakeFetcher()
    serve(fetcher, repo: "example/stream", revision: "r1", checkpoint: weights)

    let result = run(
        [],
        home: home,
        pins: ModelPins(streaming: pin, offline: nil),
        fetcher: fetcher
    )

    #expect(result.errorText.contains("is 7 bytes but 99 were expected"))
    #expect(storedFiles(in: home).isEmpty)
}

@Test
func downloadReportsAServerErrorAndLeavesNothingInPlace() {
    let home = makeHome()
    defer {
        try? FileManager.default.removeItem(at: home)
    }
    let pin = ModelPin(
        repo: "example/stream",
        revision: "r1",
        files: [ModelPinFile(name: "model.safetensors", sha256: nil, size: nil)],
        licence: nil
    )

    let result = run(
        [],
        home: home,
        pins: ModelPins(streaming: pin, offline: nil),
        fetcher: FakeFetcher()
    )

    #expect(result.errorText.contains("model.safetensors: the server answered HTTP 404"))
    #expect(storedFiles(in: home).isEmpty)
}

@Test
func swapLoadsARenamedCheckpointWithTheSameShapesAndRejectsAChangedShape() {
    let home = makeHome()
    defer {
        try? FileManager.default.removeItem(at: home)
    }
    let valid = checkpoint(modelShapes())
    var changed = modelShapes()
    changed["TSMamba.0.freq_mamba.output_proj.weight"] = [64, 127]
    let fetcher = FakeFetcher()
    serve(fetcher, repo: "first/model", revision: "v1", checkpoint: valid)
    serve(fetcher, repo: "other/renamed", revision: "v2", checkpoint: valid)
    serve(fetcher, repo: "third/resized", revision: "v3", checkpoint: checkpoint(changed))
    let paths = InstalledPaths(home: home)

    let first = run(
        ["--model", "first/model@v1", "--sha256", sha256(valid)],
        home: home,
        fetcher: fetcher
    )
    #expect(first.errorText.isEmpty)
    #expect(Doctor.report(offline: true, paths: paths).model.repo == "first/model")

    let renamed = run(
        ["--model", "other/renamed@v2", "--sha256", sha256(valid)],
        home: home,
        fetcher: fetcher
    )
    #expect(renamed.errorText.isEmpty)
    let active = Doctor.report(offline: true, paths: paths).model
    #expect(active.repo == "other/renamed")
    #expect(active.revision == "v2")
    #expect(active.sha256Ok)

    let rejected = run(
        ["--model", "third/resized@v3", "--sha256", sha256(checkpoint(changed))],
        home: home,
        fetcher: fetcher
    )
    #expect(rejected.errorText.contains("'TSMamba.0.freq_mamba.output_proj.weight'"))
    #expect(rejected.errorText.contains("[64, 127]"))
    #expect(rejected.errorText.contains("the previous model is unchanged"))
    #expect(Doctor.report(offline: true, paths: paths).model.repo == "other/renamed")
    #expect(!storedFiles(in: home).contains { $0.hasPrefix("third") })
    #expect(!storedFiles(in: home).contains { $0.hasPrefix(".staging") })
}

@Test
func swapRefusesACheckpointWhoseHashIsNotTheOneGiven() {
    let home = makeHome()
    defer {
        try? FileManager.default.removeItem(at: home)
    }
    let valid = checkpoint(modelShapes())
    let fetcher = FakeFetcher()
    serve(fetcher, repo: "first/model", revision: "v1", checkpoint: valid)

    let result = run(
        ["--model", "first/model@v1", "--sha256", String(repeating: "0", count: 64)],
        home: home,
        fetcher: fetcher
    )

    #expect(result.errorText.contains(sha256(valid)))
    #expect(storedFiles(in: home).isEmpty)
}

@Test
func swapRefusesAConfigThatIsNotJSON() {
    let home = makeHome()
    defer {
        try? FileManager.default.removeItem(at: home)
    }
    let valid = checkpoint(modelShapes())
    let fetcher = FakeFetcher()
    serve(fetcher, repo: "first/model", revision: "v1", checkpoint: valid, config: Data("no".utf8))

    let result = run(
        ["--model", "first/model@v1", "--sha256", sha256(valid)],
        home: home,
        fetcher: fetcher
    )

    #expect(result.errorText.contains("config.json is not a JSON object"))
    #expect(storedFiles(in: home).isEmpty)
}

private func sizedPin(_ weights: Data) -> ModelPins {
    ModelPins(
        streaming: ModelPin(
            repo: "example/stream",
            revision: "r1",
            files: [
                ModelPinFile(
                    name: "model.safetensors",
                    sha256: sha256(weights),
                    size: weights.count
                )
            ],
            licence: "Licence: example terms."
        ),
        offline: nil
    )
}

@Test
func theRecordedPinsNameTheExactRevisionsSizesAndHashes() throws {
    let streaming = try #require(ModelPins.recorded.streaming)
    #expect(streaming.repo == "nvidia/Real-time_RE-USE")
    #expect(streaming.revision == "4c0c186272ca853cd18d832fc5c28777b62f32d1")
    #expect(streaming.files.map(\.name) == ["model.safetensors", "config.json"])
    #expect(streaming.files.allSatisfy { $0.size != nil && $0.sha256?.count == 64 })
    #expect(streaming.licence == ModelPins.streamingLicence)

    let offline = try #require(ModelPins.recorded.offline)
    #expect(offline.repo == "nvidia/NVIDIA-NemotronLabs-RE-USE")
    #expect(offline.revision == "31f82f2efad1095034492f236e8dac9239ba713b")
    #expect(offline.files.allSatisfy { $0.size != nil && $0.sha256?.count == 64 })
    #expect(offline.licence == ModelPins.offlineLicence)
}

@Test
func theStreamingLicenceSaysNonCommercialAndNamesTheSwapCommand() {
    #expect(ModelPins.streamingLicence.contains("Noncommercial"))
    #expect(ModelPins.streamingLicence.contains("not for commercial use"))
    #expect(
        ModelPins.streamingLicence.contains(
            "untunnel download --model <owner>/<name>@<revision> --sha256 <hex>"
        )
    )
}

@Test
func downloadAnnouncesTheSizeBeforeFetchingAnything() {
    let home = makeHome()
    defer {
        try? FileManager.default.removeItem(at: home)
    }
    let weights = Data("weights".utf8)
    let fetcher = FakeFetcher()
    serve(fetcher, repo: "example/stream", revision: "r1", checkpoint: weights)

    let result = run([], home: home, pins: sizedPin(weights), fetcher: fetcher)

    #expect(result.errorText.isEmpty)
    let size = result.lines.firstIndex(of: "Download size: 0.0 MB")
    let fetching = result.lines.firstIndex(of: "Downloading model.safetensors")
    #expect(size != nil && fetching != nil)
    #expect((size ?? .max) < (fetching ?? 0))
}

@Test
func downloadRefusesToStartWithoutRoomForTheModel() {
    let home = makeHome()
    defer {
        try? FileManager.default.removeItem(at: home)
    }
    let weights = Data(repeating: 1, count: 2_000_000)
    let fetcher = FakeFetcher()
    serve(fetcher, repo: "example/stream", revision: "r1", checkpoint: weights)

    let result = run(
        [],
        home: home,
        pins: sizedPin(weights),
        fetcher: fetcher,
        availableBytes: { _ in 1_000_000 }
    )

    #expect(
        result.outcome.failure
            == .diskFull("the model needs 2.0 MB and 1.0 MB are free")
    )
    #expect(result.outcome.errors.errorLines.count == 2)
    #expect(fetcher.requested.isEmpty)
    #expect(storedFiles(in: home).isEmpty)
}

@Test
func downloadWithoutANetworkSaysSoAndLeavesNoPartialFile() {
    let home = makeHome()
    defer {
        try? FileManager.default.removeItem(at: home)
    }
    let fetcher = FailingFetcher(URLError(.notConnectedToInternet))

    let result = run([], home: home, pins: sizedPin(Data("w".utf8)), fetcher: fetcher)

    #expect(result.outcome.failure == .modelDownloadOffline)
    #expect(
        result.outcome.errors.errorLines == [
            UserFacingError.modelDownloadOffline.message,
            "Fix: \(UserFacingError.modelDownloadOffline.fix)",
        ]
    )
    #expect(fetcher.requests == 1)
    #expect(storedFiles(in: home).isEmpty)
}

@Test
func aDiskThatFillsDuringTheDownloadIsReportedAsAFullDisk() {
    let home = makeHome()
    defer {
        try? FileManager.default.removeItem(at: home)
    }
    let full = NSError(
        domain: NSCocoaErrorDomain,
        code: NSFileWriteUnknownError,
        userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))]
    )

    let result = run([], home: home, pins: sizedPin(Data("w".utf8)), fetcher: FailingFetcher(full))

    #expect(
        result.outcome.failure == .diskFull("the disk filled while the model was being written"))
    #expect(storedFiles(in: home).isEmpty)
}

@Test
func downloadClearsAStagingFolderAnInterruptedRunLeft() throws {
    let home = makeHome()
    defer {
        try? FileManager.default.removeItem(at: home)
    }
    let models = InstalledPaths(home: home).models
    let abandoned = models.appendingPathComponent(".staging-interrupted")
    try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
    try Data("half".utf8).write(to: abandoned.appendingPathComponent("model.safetensors"))
    let weights = Data("weights".utf8)
    let fetcher = FakeFetcher()
    serve(fetcher, repo: "example/stream", revision: "r1", checkpoint: weights)

    let result = run([], home: home, pins: sizedPin(weights), fetcher: fetcher)

    #expect(result.errorText.isEmpty)
    #expect(!storedFiles(in: home).contains { $0.hasPrefix(".staging") })
}
