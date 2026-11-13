import Foundation

/// Everything the commands and the menu say when something is wrong.
///
/// Each case carries the sentence a person reads and the one action that gets them out of it.
/// Keeping both here stops a command from inventing its own wording, so the fix line always
/// names a command or a menu item.
enum UserFacingError: Error, Equatable {
    case unsupportedMacOS
    case unsupportedIntel
    case installedByScript
    case driverInstallFailed(String)
    case driverNotLoaded
    case driverVersionChanged
    case homebrewMissing
    case modelMissing
    case offlineModelMissing
    case modelHashMismatch(String)
    case modelNotPinned(String)
    case modelDownloadFailed(String)
    case modelDownloadOffline
    case modelDownloadCorrupt(String)
    case diskFull(String)
    case modelRejected(String)
    case notInstalled
    case loginAgentFailed(String)
    case applicationLinkFailed(String)
    case audioDeviceUnavailable(String)
    case permissionDenied(String)
    case uninstallFailed(String)
    case unexpected(String)
    case usage(String)

    static var allCases: [UserFacingError] {
        [
            .unsupportedMacOS,
            .unsupportedIntel,
            .installedByScript,
            .driverInstallFailed("the copy failed"),
            .driverNotLoaded,
            .driverVersionChanged,
            .homebrewMissing,
            .modelMissing,
            .offlineModelMissing,
            .modelHashMismatch("model.safetensors"),
            .modelNotPinned("streaming"),
            .modelDownloadFailed("the server answered 404"),
            .modelDownloadOffline,
            .modelDownloadCorrupt("model.safetensors has the wrong hash"),
            .diskFull("the model needs 54.1 MB and 12.0 MB are free"),
            .modelRejected("tensor 'encoder.conv0.weight' has the wrong shape"),
            .notInstalled,
            .loginAgentFailed("the plist is read-only"),
            .applicationLinkFailed("the link exists"),
            .audioDeviceUnavailable("Untunnel Microphone"),
            .permissionDenied("the microphone"),
            .uninstallFailed("the audio plug-in"),
            .unexpected("the command stopped early"),
            .usage("unknown option '--example'"),
        ]
    }

    var message: String {
        switch self {
        case .unsupportedMacOS:
            return "Untunnel needs macOS 15 or later."
        case .unsupportedIntel:
            return "Untunnel needs an Apple silicon Mac."
        case .installedByScript:
            return "Untunnel is already installed by the install script."
        case .driverInstallFailed(let detail):
            return "The Untunnel audio plug-in could not be installed: \(detail)"
        case .driverNotLoaded:
            return "The Untunnel audio plug-in was installed but macOS did not load it."
        case .driverVersionChanged:
            return "The audio plug-in changed since Untunnel started."
        case .homebrewMissing:
            return "Homebrew is not installed, and the BlackHole fallback needs it."
        case .modelMissing:
            return "The restore model is not installed."
        case .offlineModelMissing:
            return "The offline file model is not installed."
        case .modelHashMismatch(let detail):
            return "The restore model does not match its recorded hash: \(detail)"
        case .modelNotPinned(let name):
            return "No download is recorded for the \(name) model."
        case .modelDownloadFailed(let detail):
            return "The model could not be downloaded: \(detail)"
        case .modelDownloadOffline:
            return "The model could not be downloaded because this Mac is not online."
        case .modelDownloadCorrupt(let detail):
            return "The downloaded model failed its check and was discarded: \(detail)"
        case .diskFull(let detail):
            return "There is not enough free disk space for the model: \(detail)."
        case .modelRejected(let detail):
            return "The checkpoint cannot be used as the model: \(detail)"
        case .notInstalled:
            return "Untunnel is not installed."
        case .loginAgentFailed(let detail):
            return "Untunnel could not write its login item: \(detail)"
        case .applicationLinkFailed(let detail):
            return "Untunnel could not link its app into ~/Applications: \(detail)"
        case .audioDeviceUnavailable(let detail):
            return "The audio device is not available: \(detail)"
        case .permissionDenied(let detail):
            return "macOS denied \(detail)."
        case .uninstallFailed(let detail):
            return "Untunnel could not remove \(detail)."
        case .unexpected(let detail):
            return "Untunnel stopped before finishing: \(detail)"
        case .usage(let detail):
            return detail
        }
    }

    var fix: String {
        switch self {
        case .unsupportedMacOS:
            return
                "Open System Settings > General > Software Update, then run `untunnel setup` again."
        case .unsupportedIntel:
            return
                "Open the Apple menu > About This Mac to confirm the chip, then run `untunnel doctor` on an Apple silicon Mac."
        case .installedByScript:
            return
                "Run `~/Applications/Untunnel.app/Contents/MacOS/Untunnel uninstall`, then run `untunnel setup`."
        case .driverInstallFailed:
            return
                "Run `untunnel setup` again; if it still fails, reinstall `Untunnel.driver` from the app's Resources folder."
        case .driverNotLoaded:
            return
                "Run `brew install --cask blackhole-2ch`, then run `untunnel setup --driver`."
        case .driverVersionChanged:
            return "Run `untunnel setup` to install the matching plug-in."
        case .homebrewMissing:
            return
                "Run `brew install --cask blackhole-2ch`, or install Homebrew from https://brew.sh and run `untunnel setup --driver`."
        case .modelMissing:
            return "Run `untunnel setup` to download the model."
        case .offlineModelMissing:
            return "Run `untunnel download --offline-model`."
        case .modelHashMismatch:
            return "Run `untunnel setup` to download the model again."
        case .modelNotPinned:
            return
                "Run `untunnel download --model <repo>@<revision> --sha256 <hex>` with the checkpoint you want."
        case .modelDownloadFailed:
            return "Check your network connection, then run `untunnel download` again."
        case .modelDownloadOffline:
            return "Connect to the internet, then run `untunnel setup` again."
        case .modelDownloadCorrupt:
            return "Run `untunnel download` again; the previous model is unchanged."
        case .diskFull:
            return
                "Free space in System Settings > General > Storage, then run `untunnel setup` again."
        case .modelRejected:
            return
                "Run `untunnel download` with a checkpoint that matches the model; the previous model is unchanged."
        case .notInstalled:
            return "Run `untunnel setup`."
        case .loginAgentFailed, .applicationLinkFailed:
            return "Run `untunnel setup`."
        case .audioDeviceUnavailable:
            return
                "Open the Untunnel menu and choose `Hear Yourself` (F13), or run `untunnel doctor`."
        case .permissionDenied:
            return
                "Open System Settings > Privacy & Security > Microphone and allow Untunnel, then run `untunnel setup`."
        case .uninstallFailed:
            return "Run `untunnel uninstall` again, or remove the path in Finder."
        case .unexpected:
            return "Run `untunnel doctor` and share its report."
        case .usage:
            return "Run `untunnel --help`."
        }
    }

    /// The sentence and its fix, separated so a terminal and an alert can style each line.
    var rendered: String {
        "\(message)\nFix: \(fix)"
    }
}
