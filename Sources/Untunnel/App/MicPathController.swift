import AVFoundation
import AppKit
import Foundation
import UntunnelAudio
import UntunnelEngine

/// The device changes auto-route reacts to, read from two consecutive device snapshots.
enum AutoRouteEvents {
    static func between(
        _ old: AudioDevices.Snapshot,
        _ new: AudioDevices.Snapshot,
        at time: TimeInterval
    ) -> [AutoRouteEvent] {
        let oldUIDs = Set(old.devices.map(\.uid))
        let newUIDs = Set(new.devices.map(\.uid))
        var events: [AutoRouteEvent] = []
        for device in new.devices where !oldUIDs.contains(device.uid) {
            events.append(.deviceAppeared(uid: device.uid, transport: device.transport, at: time))
        }
        for device in old.devices
        where device.transport == .bluetooth && !newUIDs.contains(device.uid) {
            events.append(.headsetDisconnected(uid: device.uid, at: time))
        }
        // After the appearances, so a headset macOS switches to on connect is already known.
        if let uid = new.defaultInputUID, uid != old.defaultInputUID {
            events.append(.defaultInputChanged(uid: uid, at: time))
        }
        return events
    }
}

/// Connects the live microphone path to the app.
///
/// Another app reading Untunnel Microphone engages the path: the headset is captured, run
/// through the model and written to the feed device until the reader leaves. Everything that
/// touches hardware sits behind `MicPathHardware`, `DefaultInputSetter` and `HeartbeatSink`,
/// so the decisions here run in tests without a device, a driver or a headset.
@MainActor
final class MicPathController {
    private let state: AppState
    private let deviceSource: any DeviceSource
    private let devices: AudioDevices
    private let hardware: any MicPathHardware
    private let probe: HALProbeResults
    private let permission: () -> AudioPermission
    private let incomingPreferences: IncomingPreferences
    private let incomingPlayback: IncomingPlayback
    private let incoming: IncomingTap
    private var incomingSettings: IncomingTap.Settings
    private let clock: () -> TimeInterval
    private let makeAutoRoute: (_ enabled: Bool) -> AutoRouteShell
    private var autoRoute: AutoRouteShell?
    private var autoRouteWanted = true
    private var lastSnapshot: AudioDevices.Snapshot
    private var isEngaged = false
    private var monitorCapture: MonitorCapture?
    private var monitoring = false
    private var monitorStart: Task<Void, Never>?
    private var monitorFailed = false
    private var engageFailed = false
    private var micRecovery: TierRecovery?
    private var incomingRecovery: TierRecovery?
    private var activeMicModel: MicModel?
    private(set) var session: MicPathSession?
    let model: LoadedModel
    private(set) var heartbeat: HeartbeatMonitor?
    /// Registrations the live app keeps for as long as the controller runs.
    var retained: [AnyObject] = []

    init(
        state: AppState,
        deviceSource: any DeviceSource,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        hardware: any MicPathHardware,
        processes: any AudioProcessObjectSource,
        tap: any ProcessTapDevice,
        incomingPreferences: IncomingPreferences,
        model: LoadedModel = LoadedModel(),
        probe: HALProbeResults = .recorded,
        heartbeatSink: any HeartbeatSink,
        permission: @escaping () -> AudioPermission = AudioPermission.current,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        makeAutoRoute: @escaping (_ enabled: Bool) -> AutoRouteShell
    ) {
        self.state = state
        self.deviceSource = deviceSource
        let devices = AudioDevices(source: deviceSource, environment: environment)
        self.devices = devices
        self.hardware = hardware
        self.model = model
        self.probe = probe
        self.permission = permission
        self.incomingPreferences = incomingPreferences
        let playback = IncomingPlayback(tap: tap, hardware: hardware, model: model)
        let settings = IncomingTap.Settings(
            isEnabled: incomingPreferences.isEnabled,
            headphoneUIDs: incomingPreferences.headphoneUIDs,
            environment: environment
        )
        incomingSettings = settings
        incomingPlayback = playback
        incoming = IncomingTap(
            processes: processes,
            devices: devices,
            tap: playback,
            settings: settings,
            onOutcome: { outcome in
                Task { @MainActor in
                    state.incomingChanged(outcome)
                }
            }
        )
        self.clock = clock
        self.makeAutoRoute = makeAutoRoute
        lastSnapshot = devices.snapshot
        heartbeat = HeartbeatMonitor(
            sink: heartbeatSink,
            hops: { [weak self] in
                guard let self else {
                    return 0
                }
                return self.heartbeatHops
            },
            status: { [weak self] in self?.session?.pipeline.metrics.status ?? .waiting },
            prerequisites: { [weak self] in
                self?.prerequisites
                    ?? HALProbeResults.recorded.prerequisites(
                        virtualMic: nil,
                        permission: .denied
                    )
            }
        )
    }

    func setMonitoring(_ enabled: Bool) {
        monitoring = enabled
        monitorFailed = false
        if !enabled {
            stopMonitorCapture()
            session?.pipeline.monitorTap.setEnabled(false)
            incomingPlayback.pipeline?.monitorTap.setEnabled(false)
            if session == nil { state.micPath = .standby }
        }
    }

    func monitorPipelines() -> [MonitorPath: Pipeline] {
        guard monitoring else { return [:] }
        if session != nil {
            stopMonitorCapture()
        } else if monitorCapture == nil, monitorStart == nil, !monitorFailed {
            startMonitorCapture()
        }
        var paths: [MonitorPath: Pipeline] = [:]
        paths[.mic] = session?.pipeline ?? monitorCapture?.pipeline
        paths[.incoming] = incomingPlayback.pipeline
        return paths
    }

    private func startMonitorCapture() {
        guard permission().isAuthorized else {
            state.micError = .audioDeviceUnavailable("microphone permission is required")
            return
        }
        guard let input = devices.snapshot.selection.input else { return }
        let current = model.current ?? .unavailable(.modelMissing)
        state.micPath = .waiting(deviceName: input.name)
        monitorStart = Task { [weak self, hardware] in
            do {
                let capture = try await Task.detached(priority: .userInitiated) {
                    try MonitorCapture(
                        source: hardware.captureSource(uid: input.uid), model: current)
                }.value
                guard !Task.isCancelled, let self, monitoring, session == nil else {
                    capture.stop()
                    return
                }
                monitorCapture = capture
                state.micPath = current.tier.map { .restoring($0) } ?? .bypass
                monitorStart = nil
            } catch {
                guard !Task.isCancelled, let self else { return }
                state.micError = .audioDeviceUnavailable(String(describing: error))
                monitorFailed = true
                monitorStart = nil
            }
        }
    }
    private func stopMonitorCapture() {
        monitorStart?.cancel()
        monitorStart = nil
        monitorCapture?.stop()
        monitorCapture = nil
        monitorFailed = false
    }

    /// The heartbeat's view of the pipeline: nil in Standby, the hop counter while engaged,
    /// and a frozen counter when an engage failed, so the plug-in hides the microphone and
    /// macOS moves the call to a real one instead of leaving it on silence.
    var heartbeatHops: UInt64? {
        if let session {
            return session.pipeline.metrics.hops
        }
        return engageFailed ? 0 : nil
    }

    var prerequisites: Heartbeat.Prerequisites {
        probe.prerequisites(
            virtualMic: devices.snapshot.selection.virtualMic,
            permission: permission()
        )
    }

    /// The selection and devices as of the last change.
    var snapshot: AudioDevices.Snapshot {
        devices.snapshot
    }

    /// Starts in Standby, routes the default input when the checks allow it, and restores a
    /// route a crash interrupted. `cleanExit` is the flag the previous run left.
    func start(cleanExit: Bool) {
        state.micPath = .standby
        state.permission = permission()
        state.restoreOther = incomingPreferences.isEnabled
        incoming.start()
        refreshAutoRoute()
        _ = autoRoute?.launch(
            cleanExit: cleanExit,
            permission: state.permission,
            source: deviceSource
        )
    }

    /// Records the model the launch loaded; an engaged path switches to it at once.
    func modelLoaded(_ loaded: MicModel) {
        stopMonitorCapture()
        model.current = loaded
        resetTiers()
        switch loaded {
        case .ready(_, let tier):
            state.engine = .ready(tier)
        case .unavailable(let error):
            state.engine = .failed(error.message)
        }
        if !engageFailed {
            state.micError = loaded.failure
        }
        if isEngaged {
            release()
            engage()
        }
        restartIncoming()
    }

    private func resetTiers() {
        let loaded = model.current
        activeMicModel = loaded
        micRecovery = loaded?.tier.map {
            TierRecovery(preferred: $0, tiers: model.recoveryTiers, at: clock())
        }
        incomingRecovery = model.incoming?.tier.map {
            TierRecovery(preferred: $0, tiers: model.recoveryTiers, at: clock())
        }
        incomingPlayback.selectTier(nil)
        state.tierNote = nil
    }

    /// Applies the menu toggle and keeps it for the next launch.
    func setRestoreOther(_ enabled: Bool) {
        state.restoreOther = enabled
        incomingPreferences.isEnabled = enabled
        incomingSettings.isEnabled = enabled
        incoming.update(incomingSettings)
    }

    /// Marks or unmarks an output as headphones, keeps it for the next launch, and lets the
    /// guard decide again at once.
    func setHeadphones(uid: String, marked: Bool) {
        var uids = incomingPreferences.headphoneUIDs
        if marked {
            uids.insert(uid)
        } else {
            uids.remove(uid)
        }
        incomingPreferences.headphoneUIDs = uids
        incomingSettings.headphoneUIDs = uids
        incoming.update(incomingSettings)
        refreshHeadphoneChoice()
    }

    private func refreshHeadphoneChoice() {
        state.headphoneChoice = HeadphoneChoice.offer(
            output: devices.snapshot.selection.output,
            path: state.incoming,
            marked: incomingPreferences.headphoneUIDs
        )
    }

    /// Starts the tap over so it picks up a model that finished loading after the call began.
    private func restartIncoming() {
        guard case .tapping = incoming.outcome else {
            return
        }
        var paused = incomingSettings
        paused.isEnabled = false
        incoming.update(paused)
        incoming.update(incomingSettings)
    }

    func apply(_ engagement: ClientEngagement) {
        incoming.handle(engagement)
        switch engagement {
        case .restoring:
            if !isEngaged { incomingRecovery?.restarted(at: clock()) }
            isEngaged = true
            engage()
        case .standby:
            isEngaged = false
            release()
            resetTiers()
        }
    }

    func apply(_ recovery: ReconnectRecovery.State) {
        guard session != nil else {
            return
        }
        switch recovery {
        case .waiting(let deviceName):
            state.micPath = .waiting(deviceName: deviceName)
        case .running:
            state.micPath = engagedPath
        }
    }

    /// Copies the pipeline's counters into the menu and applies the bypass choice; the
    /// ten-hertz timer calls it on the main thread.
    func refresh() {
        adaptTiers(
            microphone: session?.pipeline.metrics, incomingMetrics: incomingPlayback.metrics,
            at: clock())
        incomingPlayback.setBypass(state.isBypassed || model.current?.tier == nil)
        state.incomingNote = incoming.note
        refreshHeadphoneChoice()
        monitorCapture?.pipeline.setBypass(state.isBypassed || model.current?.tier == nil)
        guard let session else {
            state.addedLatencyMs = monitorCapture?.latency.addedLatencyMs
            return
        }
        session.pipeline.setBypass(state.isBypassed || model.current?.tier == nil)
        state.addedLatencyMs = session.pipeline.metrics.addedLatencyMs
    }

    func adaptTiers(
        microphone: PipelineMetrics?, incomingMetrics: PipelineMetrics?, at time: TimeInterval
    ) {
        if let metrics = microphone,
            let tier = micRecovery?.update(
                hops: metrics.processedHops, late: metrics.deadlineMisses, at: time,
                isRunning: !state.isBypassed && metrics.status == .running),
            let selected = model.atTier(tier)
        {
            activeMicModel = selected
            release()
            if isEngaged { engage() }
            micRecovery?.restarted(at: time)
        }
        if let metrics = incomingMetrics,
            let tier = incomingRecovery?.update(
                hops: metrics.processedHops, late: metrics.deadlineMisses, at: time,
                isRunning: !state.isBypassed && metrics.status == .running)
        {
            incomingPlayback.selectTier(tier)
            restartIncoming()
            incomingRecovery?.restarted(at: time)
        }
        state.tierNote =
            (microphone != nil && micRecovery?.isReduced == true)
                || (incomingMetrics != nil && incomingRecovery?.isReduced == true)
            ? "Reduced quality tier (CPU busy)" : nil
    }

    func devicesChanged(_ snapshot: AudioDevices.Snapshot) {
        if snapshot.selection.input != lastSnapshot.selection.input {
            stopMonitorCapture()
        }
        let events = AutoRouteEvents.between(lastSnapshot, snapshot, at: clock())
        lastSnapshot = snapshot
        for event in events {
            autoRoute?.handle(event)
        }
    }

    func setAutoRoute(_ enabled: Bool) {
        autoRouteWanted = enabled
        autoRoute?.handle(.toggle(enabled: enabled, at: clock()))
        refreshAutoRoute()
    }

    /// Re-reads the permission after sleep, which macOS may have reset during an upgrade.
    func wake() {
        state.permission = permission()
        refreshAutoRoute()
        autoRoute?.handle(.wake(state.permission))
    }

    /// Stops the path and hands the default input back, as quit must.
    func stop() {
        setMonitoring(false)
        heartbeat?.stop()
        incoming.stop()
        release()
        resetTiers()
        autoRoute?.handle(.quit(at: clock()))
    }

    private var engagedPath: AppState.MicPath {
        if state.isBypassed {
            return .bypass
        }
        guard let tier = (activeMicModel ?? model.current)?.tier else {
            return .bypass
        }
        return .restoring(tier)
    }

    private func engage() {
        guard session == nil else {
            return
        }
        let snapshot = devices.snapshot
        guard let feedUID = snapshot.selection.virtualMic?.feedUID else {
            fail(.audioDeviceUnavailable("Untunnel Microphone is not installed"))
            return
        }
        guard let input = snapshot.selection.input else {
            fail(.audioDeviceUnavailable("no headset or microphone is connected"))
            return
        }
        stopMonitorCapture()
        let current = activeMicModel ?? model.current
        do {
            session = try MicPathSession(
                input: input,
                feedUID: feedUID,
                devices: devices,
                hardware: hardware,
                bypass: state.isBypassed || current?.tier == nil,
                makeRestorer: { feedRate in
                    (current ?? .unavailable(.modelMissing)).makeRestorer(fallbackRate: feedRate)
                },
                onRecovery: { [weak self] recovery in
                    Task { @MainActor in
                        self?.apply(recovery)
                    }
                }
            )
        } catch let error as UserFacingError {
            fail(error)
            return
        } catch {
            fail(.unexpected(String(describing: error)))
            return
        }
        engageFailed = false
        micRecovery?.restarted(at: clock())
        state.micError = current?.failure
        state.micPath = engagedPath
    }

    private func fail(_ error: UserFacingError) {
        engageFailed = true
        state.micError = error
        state.micPath = .standby
    }

    private func release() {
        session?.stop()
        session = nil
        engageFailed = false
        state.addedLatencyMs = nil
        state.micPath = .standby
    }

    private func refreshAutoRoute() {
        let checks = prerequisites
        if autoRoute == nil, checks.isEligible {
            autoRoute = makeAutoRoute(autoRouteWanted)
        }
        state.autoRoute = AutoRouteMenuStatus.evaluate(
            prerequisites: checks,
            enabled: autoRouteWanted
        )
    }
}

extension MicPathController {
    /// The controller the app runs: Core Audio devices and process list, the model on disk,
    /// and the plug-in's heartbeat. The incoming tap follows the menu toggle and the watcher.
    static func live(state: AppState, model: LoadedModel) -> MicPathController {
        let store = AutoRouteStore()
        let cleanExit = store.cleanExit
        let controller = MicPathController(
            state: state,
            deviceSource: CoreAudioDeviceSource(),
            hardware: CoreAudioMicPathHardware(),
            processes: CoreAudioProcessObjectSource(),
            tap: CoreAudioProcessTap(),
            incomingPreferences: IncomingPreferences(),
            model: model,
            heartbeatSink: CoreAudioHeartbeatSink(feedUID: VirtualMicDevices.feedUID),
            makeAutoRoute: { enabled in AutoRouteShell(store: store, enabled: enabled) }
        )
        controller.start(cleanExit: cleanExit)
        controller.requestPermissionIfUndecided()
        if controller.snapshot.selection.virtualMic?.usesFallback == false {
            state.driverNeedsSetup =
                CoreAudioDriverVersion(feedUID: VirtualMicDevices.feedUID)
                .isOutdated
        }

        let watcher = ClientWatcher(
            source: CoreAudioProcessSource(),
            virtualMicUID: controller.snapshot.selection.virtualMic?.inputUID
                ?? VirtualMicDevices.inputUID,
            onEngagement: { [weak controller] engagement in
                Task { @MainActor in
                    controller?.apply(engagement)
                }
            }
        )
        watcher.start()
        let deviceObservation = controller.devices.onChange { [weak controller] snapshot in
            Task { @MainActor in
                controller?.devicesChanged(snapshot)
            }
        }
        let refresh = Timer(timeInterval: PipelineStatusMonitor.interval, repeats: true) {
            [weak controller] _ in
            MainActor.assumeIsolated {
                controller?.refresh()
            }
        }
        RunLoop.main.add(refresh, forMode: .common)
        let wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak controller] _ in
            MainActor.assumeIsolated {
                controller?.wake()
                controller?.requestPermissionIfUndecided()
            }
        }
        controller.retained = [watcher, deviceObservation, refresh, wake]
        controller.heartbeat?.start()

        let paths = InstalledPaths.current
        Task.detached(priority: .userInitiated) { [weak controller] in
            let loaded = model.load(
                paths: paths,
                tierReport: paths.tierReport
            )
            await controller?.modelLoaded(loaded)
        }
        return controller
    }

    /// Raises the microphone prompt now, so it appears at launch rather than in the next call.
    private func requestPermissionIfUndecided() {
        guard AudioPermission.current() == .notDetermined else {
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            Task { @MainActor in
                self?.wake()
            }
        }
    }
}
