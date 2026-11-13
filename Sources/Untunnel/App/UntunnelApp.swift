import AppKit
import Darwin
import SwiftUI
import UntunnelAudio

/// The menu bar app. The CLI starts it when `untunnel` runs without a subcommand.
struct UntunnelApp: App {
    // No property-wrapper state: SwiftUI's macros need Xcode, and the sources must build with the
    // Command Line Tools alone. SwiftUI creates the app value once, so plain references keep
    // these alive.
    @NSApplicationDelegateAdaptor(HeadsetReportAppDelegate.self) private var delegate
    private let state: AppState
    private let micPath: MicPathController
    private let hearYourself: HearYourselfModel
    private let monitor: MonitorModel
    private let hotkey = GlobalHotkey()
    private let termination = TerminationSignal()

    init() {
        let state = AppState()
        self.state = state
        let model = LoadedModel()
        // Before the controller, which may start a tap of its own at launch.
        StrayTapSweep.run()
        micPath = MicPathController.live(state: state, model: model)
        hearYourself = HearYourselfModel.live(model: model)
        monitor = MonitorModel.live(appState: state, controller: micPath)
        LoginAgent.reconcile(paths: .current)
        delegate.model = model
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(
                state: state,
                autoRoute: state.autoRoute,
                permission: state.permission,
                incoming: IncomingMenuStatus(note: state.incomingNote),
                onAutoRouteToggle: { [micPath] enabled in
                    Task { @MainActor in
                        micPath.setAutoRoute(enabled)
                    }
                },
                onRestoreOtherToggle: { [micPath] enabled in
                    Task { @MainActor in
                        micPath.setRestoreOther(enabled)
                    }
                },
                onHeadphoneChoice: { [micPath] choice in
                    Task { @MainActor in
                        micPath.setHeadphones(uid: choice.uid, marked: !choice.isMarked)
                    }
                }
            )
        } label: {
            Image(systemName: "waveform")
                .accessibilityLabel("Untunnel")
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSApplication.willTerminateNotification
                    )
                ) { _ in
                    hotkey.unregister()
                    hearYourself.stop()
                    micPath.stop()
                }
                .task {
                    _ = hotkey.register {
                        state.toggleBypass()
                    }
                    defer {
                        hotkey.unregister()
                    }
                    await watchForUpdates()
                }
        }
        .menuBarExtraStyle(.menu)

        Window("Hear Yourself", id: HearYourselfView.windowID) {
            HearYourselfView(model: hearYourself)
        }
        .defaultSize(width: 520, height: 560)
        .defaultLaunchBehavior(
            HearYourselfLaunch.requested() ? .presented : .suppressed
        )

        Window("Monitor", id: MonitorWindow.windowID) {
            MonitorWindow(model: monitor)
        }
        .defaultSize(width: 640, height: 720)
        .defaultLaunchBehavior(.suppressed)
    }

    /// The only relaunch path: a newer bundle on disk replaces this process from Standby.
    @MainActor
    private func watchForUpdates() async {
        var updateRunner = UpdateRunner.live()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(UpdateWatcher.interval))
            let action = updateRunner.tick(
                now: Date().timeIntervalSinceReferenceDate,
                micPath: state.micPath,
                versions: UpdateReader.snapshot()
            )
            if case .recheckDriver = action {
                state.driverNeedsSetup = true
            }
        }
    }
}

/// Turns SIGTERM from the CLI into the same orderly exit as the Quit item.
@MainActor
private final class TerminationSignal {
    private var source: DispatchSourceSignal?

    init() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                NSApplication.shared.terminate(nil)
            }
        }
        source.resume()
        self.source = source
    }
}
