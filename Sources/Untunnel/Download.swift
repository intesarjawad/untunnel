import Darwin
import Foundation
import UntunnelEngine

/// One file of a checkpoint and what it must match before it is kept.
struct ModelPinFile: Equatable {
    let name: String
    let sha256: String?
    let size: Int?
}

/// A checkpoint at a fixed revision, with the licence its download is announced under.
struct ModelPin: Equatable {
    let repo: String
    let revision: String
    let files: [ModelPinFile]
    let licence: String?
}

/// The checkpoints a bare `download` and `download --offline-model` fetch.
///
/// Every size and hash below was read from the Hugging Face API file listing at that exact
/// revision (`/api/models/<repo>/tree/<revision>`); the `config.json` hashes come from the files
/// themselves, because the listing gives small files only a Git object id.
struct ModelPins: Equatable {
    var streaming: ModelPin?
    var offline: ModelPin?

    static let recorded = ModelPins(
        streaming: ModelPin(
            repo: "nvidia/Real-time_RE-USE",
            revision: "4c0c186272ca853cd18d832fc5c28777b62f32d1",
            files: [
                ModelPinFile(
                    name: Download.checkpointName,
                    sha256: "6eac4e8cc721f99a22cde7eac3c9f8e2826ced5dc8a4234fd1977de1ec0d3ade",
                    size: 54_055_764
                ),
                ModelPinFile(
                    name: Download.configName,
                    sha256: "7c46c3279c4edbb3ae9b190905f90683f8db6ec38dea45da007e87b7d8b5621d",
                    size: 856
                ),
            ],
            licence: streamingLicence
        ),
        offline: ModelPin(
            repo: "nvidia/NVIDIA-NemotronLabs-RE-USE",
            revision: "31f82f2efad1095034492f236e8dac9239ba713b",
            files: [
                ModelPinFile(
                    name: Download.checkpointName,
                    sha256: "06badaf4029b297f97f7fe48d62990b48d5482608210df577354e0d4e0ed70e1",
                    size: 38_592_940
                ),
                ModelPinFile(
                    name: Download.configName,
                    sha256: "e69986483774f01893d2727503addc49ef201d19e6e1a266b8d4e971e28c478d",
                    size: 830
                ),
            ],
            licence: offlineLicence
        )
    )

    static let streamingLicence = """
        Licence: the streaming model is released under the NVIDIA One-Way Noncommercial \
        License (NSCLv1), for research and development only, so it is not for commercial use. \
        This download does not change its terms. To use another checkpoint with the same \
        architecture: untunnel download --model <owner>/<name>@<revision> --sha256 <hex>
        """
    static let offlineLicence = """
        Licence: the offline model is released under OpenMDW-1.1. This download does not \
        change its terms.
        """
}

/// A `repo@revision` pair that is safe to use as a URL path and as a directory name.
struct ModelReference: Equatable {
    let repo: String
    let revision: String

    init(parsing text: String) throws {
        guard let separator = text.lastIndex(of: "@") else {
            throw UserFacingError.usage("--model needs <repo>@<revision>, such as owner/name@main")
        }
        let repo = String(text[..<separator])
        let revision = String(text[text.index(after: separator)...])
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy(Self.isSafe), Self.isSafe(Substring(revision))
        else {
            throw UserFacingError.usage(
                "--model '\(text)' is not <owner>/<name>@<revision> made of letters, digits, '.', '_' and '-'"
            )
        }
        self.repo = repo
        self.revision = revision
    }

    var directoryName: String {
        "\(repo)@\(revision)"
    }

    private static func isSafe(_ part: Substring) -> Bool {
        !part.isEmpty && part != "." && part != ".."
            && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }
}

/// A download invocation that cannot be parsed.
struct DownloadOptions: Equatable {
    var offlineModel = false
    var model: ModelReference?
    var sha256: String?

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--offline-model":
                offlineModel = true
                index += 1
            case "--model":
                model = try ModelReference(parsing: try Self.value(after: index, in: arguments))
                index += 2
            case "--sha256":
                sha256 = try Self.value(after: index, in: arguments).lowercased()
                index += 2
            default:
                throw UserFacingError.usage("unknown download option '\(argument)'")
            }
        }
        guard (model == nil) == (sha256 == nil) else {
            throw UserFacingError.usage("--model and --sha256 go together")
        }
        guard !(offlineModel && model != nil) else {
            throw UserFacingError.usage("choose either --offline-model or --model")
        }
        if let sha256, !Self.isHex64(sha256) {
            throw UserFacingError.usage("--sha256 needs 64 hexadecimal characters")
        }
    }

    private static func value(after index: Int, in arguments: [String]) throws -> String {
        guard index + 1 < arguments.count else {
            throw UserFacingError.usage("\(arguments[index]) needs a value")
        }
        return arguments[index + 1]
    }

    private static func isHex64(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isASCII && $0.isHexDigit }
    }
}

/// Fetches one URL to a file, behind a protocol so a test never touches the network.
protocol ModelFetcher {
    func fetch(_ url: URL, to destination: URL) throws
}

enum ModelFetchError: Error, LocalizedError {
    case status(Int)
    case noResponse

    var errorDescription: String? {
        switch self {
        case .status(let code):
            return "the server answered HTTP \(code)"
        case .noResponse:
            return "the server sent no response"
        }
    }
}

private final class FetchOutcome: @unchecked Sendable {
    var error: Error?
}

/// Downloads through `URLSession`, which follows the host's redirect to its file store.
struct LiveModelFetcher: ModelFetcher {
    func fetch(_ url: URL, to destination: URL) throws {
        let finished = DispatchSemaphore(value: 0)
        let outcome = FetchOutcome()
        let task = URLSession.shared.downloadTask(with: url) { location, response, error in
            defer {
                finished.signal()
            }
            if let error {
                outcome.error = error
                return
            }
            guard let http = response as? HTTPURLResponse, let location else {
                outcome.error = ModelFetchError.noResponse
                return
            }
            guard http.statusCode == 200 else {
                outcome.error = ModelFetchError.status(http.statusCode)
                return
            }
            do {
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                outcome.error = error
            }
        }
        task.resume()
        finished.wait()
        if let error = outcome.error {
            throw error
        }
    }
}

/// The part of `config.json` the swap check reads.
private struct ModelConfig: Decodable {
    let exitLayer: Int?

    private enum CodingKeys: String, CodingKey {
        case exitLayer = "exit_layer"
    }
}

/// Fetches a checkpoint, verifies it and makes it the model `doctor` reports.
///
/// Every file is verified in a staging directory and only moved into
/// `models/<repo>@<revision>` once all of them pass, so a failed run leaves no file behind and
/// the previous model stays active. The active model is the `model` link next to `models`.
enum Download {
    static let checkpointName = "model.safetensors"
    static let configName = "config.json"

    static func run(arguments: [String]) -> Int32 {
        let result = perform(
            arguments: arguments,
            paths: .current,
            pins: .recorded,
            fetcher: LiveModelFetcher(),
            emit: { print($0) }
        )
        result.errors.write()
        if result.usage {
            printUsage()
            return 2
        }
        return result.failure == nil ? 0 : 1
    }

    struct Outcome {
        let failure: UserFacingError?
        let usage: Bool

        var errors: CommandOutput {
            var output = CommandOutput()
            if let failure {
                output.error(failure)
            }
            return output
        }
    }

    static func perform(
        arguments: [String],
        paths: InstalledPaths,
        pins: ModelPins,
        fetcher: any ModelFetcher,
        availableBytes: (URL) -> Int64? = Download.availableBytes,
        emit: (String) -> Void
    ) -> Outcome {
        let options: DownloadOptions
        do {
            options = try DownloadOptions(arguments: arguments)
        } catch let error as UserFacingError {
            return Outcome(failure: error, usage: true)
        } catch {
            return Outcome(failure: .unexpected(String(describing: error)), usage: false)
        }

        do {
            let (pin, swap) = try resolve(options, pins: pins)
            try install(
                pin,
                swap: swap,
                activateModel: !options.offlineModel,
                paths: paths,
                fetcher: fetcher,
                availableBytes: availableBytes,
                emit: emit
            )
        } catch let error as UserFacingError {
            return Outcome(failure: error, usage: false)
        } catch let error as SafeTensorsError {
            return Outcome(failure: .modelRejected(error.description), usage: false)
        } catch let error as WeightMapError {
            return Outcome(failure: .modelRejected(error.description), usage: false)
        } catch {
            return Outcome(failure: storageFailure(error) ?? .unexpected("\(error)"), usage: false)
        }
        return Outcome(failure: nil, usage: false)
    }

    /// The free space on the volume that will hold `url`, read from its nearest existing folder.
    static func availableBytes(at url: URL) -> Int64? {
        var folder = url
        while !FileManager.default.fileExists(atPath: folder.path), folder.path != "/" {
            folder.deleteLastPathComponent()
        }
        return try? folder.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
    }

    /// Megabytes with one decimal, the unit a model download is announced in.
    static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }

    /// Names the two failures a person can fix without reading an error code: no network and
    /// a full disk. Anything else stays a plain download failure.
    static func fetchFailure(_ error: Error, file: String) -> UserFacingError {
        if let failure = storageFailure(error) {
            return failure
        }
        if let urlError = error as? URLError, offlineCodes.contains(urlError.code) {
            return .modelDownloadOffline
        }
        return .modelDownloadFailed("\(file): \(error.localizedDescription)")
    }

    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
        .dnsLookupFailed, .timedOut, .dataNotAllowed, .internationalRoamingOff,
    ]

    private static func storageFailure(_ error: Error) -> UserFacingError? {
        var current: NSError? = error as NSError
        while let error = current {
            let full =
                (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError)
                || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC))
            if full {
                return .diskFull("the disk filled while the model was being written")
            }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }

    static func printUsage() {
        let message =
            "Usage: untunnel download [--offline-model | --model REPO@REVISION --sha256 HEX]\n"
        FileHandle.standardError.write(Data(message.utf8))
    }

    private static func resolve(
        _ options: DownloadOptions,
        pins: ModelPins
    ) throws -> (pin: ModelPin, swap: Bool) {
        if let model = options.model, let sha256 = options.sha256 {
            let pin = ModelPin(
                repo: model.repo,
                revision: model.revision,
                files: [
                    ModelPinFile(name: checkpointName, sha256: sha256, size: nil),
                    ModelPinFile(name: configName, sha256: nil, size: nil),
                ],
                licence: nil
            )
            return (pin, true)
        }
        if options.offlineModel {
            guard let pin = pins.offline else {
                throw UserFacingError.modelNotPinned("offline")
            }
            return (pin, false)
        }
        guard let pin = pins.streaming else {
            throw UserFacingError.modelNotPinned("streaming")
        }
        return (pin, false)
    }

    private static func install(
        _ pin: ModelPin,
        swap: Bool,
        activateModel: Bool,
        paths: InstalledPaths,
        fetcher: any ModelFetcher,
        availableBytes: (URL) -> Int64?,
        emit: (String) -> Void
    ) throws {
        let files = FileManager.default
        let name = "\(pin.repo)@\(pin.revision)"
        let destination = paths.models.appendingPathComponent(name)

        emit("Model: \(name)")
        emit(
            pin.licence
                ?? "Licence: not checked; read the licence of \(pin.repo) before you use it."
        )

        if let installed = try existingManifest(at: destination, matching: pin) {
            if activateModel { try activate(name: name, paths: paths) }
            emit("Already downloaded and verified: \(installed.files.count) file(s).")
            if activateModel { emit("Active model: \(name)") }
            return
        }

        let sizes = pin.files.compactMap(\.size)
        if sizes.count == pin.files.count {
            let total = Int64(sizes.reduce(0, +))
            emit("Download size: \(megabytes(total))")
            if let free = availableBytes(paths.models), free < total {
                throw UserFacingError.diskFull(
                    "the model needs \(megabytes(total)) and \(megabytes(free)) are free"
                )
            }
        }

        try files.createDirectory(at: paths.models, withIntermediateDirectories: true)
        try removeAbandonedStaging(in: paths.models)
        let staging = paths.models.appendingPathComponent(".staging-\(UUID().uuidString)")
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer {
            try? files.removeItem(at: staging)
        }

        var manifestFiles: [ModelManifestFile] = []
        for file in pin.files {
            guard
                let url = URL(
                    string:
                        "https://huggingface.co/\(pin.repo)/resolve/\(pin.revision)/\(file.name)"
                )
            else {
                throw UserFacingError.modelDownloadFailed("\(file.name) has no valid address")
            }
            let local = staging.appendingPathComponent(file.name)
            emit("Downloading \(file.name)")
            do {
                try fetcher.fetch(url, to: local)
            } catch {
                throw fetchFailure(error, file: file.name)
            }
            manifestFiles.append(
                ModelManifestFile(path: file.name, sha256: try verify(file, at: local))
            )
            emit("Verified \(file.name)")
        }

        if swap {
            try validateWeights(in: staging)
            emit("The checkpoint loads into the model.")
        }

        let manifest = ModelManifest(repo: pin.repo, revision: pin.revision, files: manifestFiles)
        try Output.jsonData(manifest).write(to: staging.appendingPathComponent("manifest.json"))

        try files.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if files.fileExists(atPath: destination.path) {
            try files.removeItem(at: destination)
        }
        try files.moveItem(at: staging, to: destination)
        if activateModel {
            try activate(name: name, paths: paths)
            emit("Active model: \(name)")
        }
    }

    /// Deletes staging folders an interrupted run left, so a half-written file never lingers.
    private static func removeAbandonedStaging(in models: URL) throws {
        let files = FileManager.default
        for name in try files.contentsOfDirectory(atPath: models.path)
        where name.hasPrefix(".staging-") {
            try files.removeItem(at: models.appendingPathComponent(name))
        }
    }

    /// The stored manifest, only when every file it lists is present and still hashes the same.
    private static func existingManifest(
        at directory: URL,
        matching pin: ModelPin
    ) throws -> ModelManifest? {
        guard
            let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
            let manifest = try? JSONDecoder().decode(ModelManifest.self, from: data),
            manifest.repo == pin.repo, manifest.revision == pin.revision
        else {
            return nil
        }
        for file in pin.files {
            guard
                let stored = manifest.files.first(where: { $0.path == file.name }),
                let actual = try? FileDigest.hex(of: directory.appendingPathComponent(file.name)),
                actual == stored.sha256,
                file.sha256 == nil || file.sha256 == actual
            else {
                return nil
            }
        }
        return manifest
    }

    /// Checks size and hash, and returns the hash so the manifest can record it.
    private static func verify(_ file: ModelPinFile, at url: URL) throws -> String {
        if let expected = file.size {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let actual = (attributes[.size] as? NSNumber)?.intValue ?? -1
            guard actual == expected else {
                throw UserFacingError.modelDownloadCorrupt(
                    "\(file.name) is \(actual) bytes but \(expected) were expected"
                )
            }
        }
        let digest = try FileDigest.hex(of: url)
        if let expected = file.sha256, digest != expected.lowercased() {
            throw UserFacingError.modelDownloadCorrupt(
                "\(file.name) has SHA-256 \(digest) but \(expected.lowercased()) was expected"
            )
        }
        return digest
    }

    private static func validateWeights(in directory: URL) throws {
        let configURL = directory.appendingPathComponent(configName)
        let config: ModelConfig
        do {
            config = try JSONDecoder().decode(
                ModelConfig.self,
                from: try Data(contentsOf: configURL)
            )
        } catch {
            throw UserFacingError.modelRejected(
                "\(configName) is not a JSON object; download the checkpoint's own config again"
            )
        }
        if let exitLayer = config.exitLayer, exitLayer < 1 {
            throw UserFacingError.modelRejected(
                "\(configName) has exit_layer \(exitLayer), which is below 1")
        }
        let data = try Data(
            contentsOf: directory.appendingPathComponent(checkpointName),
            options: .mappedIfSafe
        )
        try WeightMap.validateRealtimeModel(
            try SafeTensors(data: data), exitLayer: config.exitLayer)
    }

    /// Points `model` at the stored directory with one rename, so a reader sees either model.
    private static func activate(name: String, paths: InstalledPaths) throws {
        let files = FileManager.default
        let link = paths.model
        let pending = paths.support.appendingPathComponent(".model-\(UUID().uuidString)")
        try files.createDirectory(at: paths.support, withIntermediateDirectories: true)
        try files.createSymbolicLink(
            atPath: pending.path,
            withDestinationPath: "models/\(name)"
        )
        let isLink = (try? files.destinationOfSymbolicLink(atPath: link.path)) != nil
        if !isLink, files.fileExists(atPath: link.path) {
            try files.removeItem(at: link)
        }
        guard rename(pending.path, link.path) == 0 else {
            let code = errno
            try? files.removeItem(at: pending)
            throw UserFacingError.permissionDenied(
                "replacing the active model: \(String(cString: strerror(code)))"
            )
        }
    }
}
