import CoreAudio
import Foundation
import Synchronization

/// One process object Core Audio reports, with both directions it may be using.
///
/// A tap can only name a process object, so the object identifier comes from the same listing
/// as the bundle identifier; looking it up again at engagement time would race the app.
public struct AudioProcessObject: Equatable, Sendable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    public let name: String?
    public let isRunningInput: Bool
    public let isRunningOutput: Bool

    public init(
        objectID: AudioObjectID,
        pid: pid_t,
        bundleID: String? = nil,
        name: String? = nil,
        isRunningInput: Bool = false,
        isRunningOutput: Bool = false
    ) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
    }

    /// The label `ClientWatcher` engages this process under.
    public var displayName: String {
        name ?? bundleID ?? "process \(pid)"
    }
}

/// A platform source of the running processes, for the incoming tap.
///
/// It lists the same process objects `AudioProcessSource` does, but keeps the object identifier
/// and the output state a tap needs; the protocol keeps the decision testable without Core Audio.
public protocol AudioProcessObjectSource: AnyObject, Sendable {
    var processes: [AudioProcessObject] { get }

    /// Starts reporting process-list changes until the result is cancelled.
    func observe(_ onChange: @escaping @Sendable () -> Void) -> any DeviceObservation
}

/// The playing audio of one application, grouped under the app that reads the microphone.
public struct TapTarget: Equatable, Sendable {
    /// The application the processes belong to, with a browser helper folded into its browser.
    public let appBundleID: String
    /// The label the menu shows for the app.
    public let name: String
    /// The processes running output, in the order the system listed them.
    public let processes: [AudioProcessObject]
    /// Whether every window of one browser engine plays through the same process.
    public let isSharedHelper: Bool

    public init(
        appBundleID: String,
        name: String,
        processes: [AudioProcessObject],
        isSharedHelper: Bool
    ) {
        self.appBundleID = appBundleID
        self.name = name
        self.processes = processes
        self.isSharedHelper = isSharedHelper
    }

    public var processObjectIDs: [AudioObjectID] {
        processes.map(\.objectID)
    }

    /// The note the menu adds when the tap mutes more than the call.
    public var note: String? {
        guard isSharedHelper else {
            return nil
        }
        return "Mutes all audio from \(name)"
    }
}

/// Groups the processes that play audio under the app that reads the microphone.
public enum ProcessTapTargets {
    /// Browser audio processes that play every tab and window of one engine.
    ///
    /// A tap on one of these mutes the whole browser, which the menu says out loud.
    static let sharedHelperBundleIDs: Set<String> = [
        "com.google.Chrome.helper",
        "com.apple.WebKit.GPU",
    ]

    /// The browser each shared helper belongs to.
    static let sharedHelperNames: [String: String] = [
        "com.google.Chrome.helper": "Google Chrome",
        "com.apple.WebKit.GPU": "Safari",
    ]

    /// The application a bundle identifier belongs to, with a browser helper folded in.
    public static func appBundleID(_ bundleID: String) -> String {
        let suffix = ".helper"
        return bundleID.hasSuffix(suffix) ? String(bundleID.dropLast(suffix.count)) : bundleID
    }

    /// Finds every output process of the app `client` that `ClientWatcher` engaged.
    ///
    /// The client is matched by the label the watcher reports, and the processes are then
    /// grouped by bundle identifier, so a browser call taps the helper that plays its audio.
    public static func target(
        processes: [AudioProcessObject],
        client: String
    ) -> TapTarget? {
        let readers = Set(
            processes.filter { $0.displayName == client }.map(appKey)
        )
        guard !readers.isEmpty else {
            return nil
        }
        let playing = processes.filter { $0.isRunningOutput && readers.contains(appKey($0)) }
        guard let first = playing.first else {
            return nil
        }
        let helper = playing.compactMap(\.bundleID).first { sharedHelperBundleIDs.contains($0) }
        return TapTarget(
            appBundleID: appKey(first),
            name: helper.flatMap { sharedHelperNames[$0] } ?? first.name ?? appKey(first),
            processes: playing,
            isSharedHelper: helper != nil
        )
    }

    private static func appKey(_ process: AudioProcessObject) -> String {
        process.bundleID.map(appBundleID) ?? process.name ?? "process \(process.pid)"
    }
}

/// Why the incoming tap could not start.
public enum TapError: Error, Equatable, CustomStringConvertible {
    /// macOS has not allowed the app to capture system audio.
    case permissionDenied
    case failed(operation: String, status: OSStatus)
    /// The tap started but its audio could not be restored and played, so it was torn down.
    case playbackFailed(String)

    public var description: String {
        switch self {
        case .permissionDenied:
            return "macOS does not allow capturing the system audio"
        case .playbackFailed(let detail):
            return "the restored audio could not be played: \(detail)"
        case .failed(let operation, let status):
            return "process tap \(operation) failed with OSStatus \(status)"
        }
    }
}

/// Creates the tap and the private aggregate device that carries it to the headphones.
///
/// The protocol keeps the engagement and guard decisions testable without Core Audio or the
/// system-audio permission, the way `DeviceSource` does for the device list.
public protocol ProcessTapDevice: AnyObject, Sendable {
    /// Starts tapping `target` and returns the UID of the aggregate device its audio is read from.
    func start(_ target: TapTarget, outputUID: String) throws -> String
    func stop()
}

/// Creates the tap through Core Audio and destroys it with its aggregate device.
///
/// The tap is private, muted while it is read, and restored by bundle identifier on macOS 26,
/// so a call app that restarts during the call comes back on the same tap.
public final class CoreAudioProcessTap: ProcessTapDevice, @unchecked Sendable {
    /// The name of the private aggregate device the audio system shows under it.
    public static let aggregateName = "Untunnel Tap"

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)

    public init() {}

    deinit {
        stop()
    }

    public func start(_ target: TapTarget, outputUID: String) throws -> String {
        stop()
        let description = Self.description(of: target)
        var tap = AudioObjectID(kAudioObjectUnknown)
        let created = AudioHardwareCreateProcessTap(description, &tap)
        guard created == noErr, tap != kAudioObjectUnknown else {
            throw Self.error(operation: "creation", status: created)
        }
        tapID = tap

        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let aggregateUID = "com.intesarjawad.untunnel.tap.\(UUID().uuidString)"
        let device = Self.createAggregate(
            tapUID: description.uuid.uuidString,
            aggregateUID: aggregateUID,
            into: &aggregate
        )
        guard device == noErr, aggregate != kAudioObjectUnknown else {
            stop()
            throw Self.error(operation: "aggregate device", status: device)
        }
        aggregateID = aggregate
        return aggregateUID
    }

    public func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// The description the tap is created from.
    static func description(of target: TapTarget) -> CATapDescription {
        let description = CATapDescription(
            stereoMixdownOfProcesses: target.processObjectIDs
        )
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        if #available(macOS 26, *) {
            description.bundleIDs = target.processes.compactMap(\.bundleID)
            description.isProcessRestoreEnabled = true
        }
        return description
    }

    /// The aggregate device that carries the tap, built from the tap's UID.
    static func aggregateDescription(tapUID: String, aggregateUID: String) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey as String: aggregateName,
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUID,
                    kAudioSubTapDriftCompensationKey as String: true,
                ]
            ],
        ]
    }

    private static func createAggregate(
        tapUID: String,
        aggregateUID: String,
        into identifier: inout AudioObjectID
    ) -> OSStatus {
        AudioHardwareCreateAggregateDevice(
            aggregateDescription(tapUID: tapUID, aggregateUID: aggregateUID) as CFDictionary,
            &identifier
        )
    }

    private static func error(operation: String, status: OSStatus) -> TapError {
        switch status {
        case kAudioDevicePermissionsError, kAudioHardwareIllegalOperationError:
            return .permissionDenied
        default:
            return .failed(operation: operation, status: status)
        }
    }
}

/// Destroys the tap aggregate devices a run that was killed left behind.
///
/// The tap's own aggregate is private and goes away with its process, so this finds nothing in
/// the normal case; it is the launch-time backstop for a device that survived a crash.
public enum StrayTapSweep {
    /// The devices named like the tap's aggregate, which are the ones to destroy.
    static func strays(
        in devices: [(id: AudioObjectID, name: String)]
    ) -> [AudioObjectID] {
        devices.filter { $0.name == CoreAudioProcessTap.aggregateName }.map(\.id)
    }

    /// Destroys every stray and returns how many Core Audio accepted.
    @discardableResult
    public static func run() -> Int {
        let devices = CoreAudioProcessListing.objects(
            of: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices
        ).compactMap { device in
            CoreAudioProcessListing.string(device, selector: kAudioObjectPropertyName)
                .map { (id: device, name: $0) }
        }
        return strays(in: devices).filter { AudioHardwareDestroyAggregateDevice($0) == noErr }
            .count
    }
}

/// What the incoming path is doing, which the app shows in the menu.
public enum IncomingTapOutcome: Equatable, Sendable {
    case off
    case tapping(pid: pid_t, name: String)
    /// The call is playing on an output that would leak it into the room.
    case pausedOnSpeakers
    case permissionDenied
    /// The tap or its playback failed to start; the text says why.
    case failed(String)
}

/// Taps the other person's audio while a call is on headphones.
///
/// The tap follows the microphone path: it starts when `ClientWatcher` names an app reading the
/// microphone and the output is a headphone, and it stops when either stops being true. The
/// guard is re-run on every output change, so moving the call to the speakers stops the tap
/// before the next frame and the app plays its audio out loud again.
public final class IncomingTap: Sendable {
    /// What the person chose, and which outputs they consider headphones.
    public struct Settings: Equatable, Sendable {
        /// The measurement override, which allows one loopback as the headphone output.
        public static let allowOutputKey = "UNTUNNEL_TEST_ALLOW_OUTPUT"

        /// The menu toggle "Also restore the other person"; it starts off.
        public var isEnabled: Bool
        /// The "These are headphones" list, by device UID.
        public var headphoneUIDs: Set<String>
        /// The one output a measurement run may use although it is not a headphone.
        public var allowedOutputUID: String?

        public init(
            isEnabled: Bool = false,
            headphoneUIDs: Set<String> = [],
            environment: [String: String] = [:]
        ) {
            self.isEnabled = isEnabled
            self.headphoneUIDs = headphoneUIDs
            allowedOutputUID = environment[Self.allowOutputKey]
            if let allowedOutputUID {
                let message =
                    "warning: \(Self.allowOutputKey) allows \(allowedOutputUID) as the "
                    + "headphone output; unset it outside measurements\n"
                FileHandle.standardError.write(Data(message.utf8))
            }
        }
    }

    private struct State: Sendable {
        var settings: Settings
        /// The app `ClientWatcher` engaged, or nil when the microphone path is on standby.
        var client: String?
        /// The target of the tap that is running, so the same target is not restarted.
        var target: TapTarget?
        var outcome = IncomingTapOutcome.off
        var observation: (any DeviceObservation)?
        var processObservation: (any DeviceObservation)?
        var isStarted = false
    }

    private let processes: any AudioProcessObjectSource
    private let devices: AudioDevices
    private let tap: any ProcessTapDevice
    private let onOutcome: @Sendable (IncomingTapOutcome) -> Void
    private let state: Mutex<State>
    /// Serialises start and stop so two changes cannot leave half a tap behind.
    private let apply = Mutex(())

    public init(
        processes: any AudioProcessObjectSource,
        devices: AudioDevices,
        tap: any ProcessTapDevice = CoreAudioProcessTap(),
        settings: Settings = Settings(),
        onOutcome: @escaping @Sendable (IncomingTapOutcome) -> Void = { _ in }
    ) {
        self.processes = processes
        self.devices = devices
        self.tap = tap
        self.onOutcome = onOutcome
        state = Mutex(State(settings: settings))
    }

    deinit {
        stop()
    }

    /// The incoming path as of the last change.
    public var outcome: IncomingTapOutcome {
        state.withLock { $0.outcome }
    }

    /// The menu line for the running tap: a browser-wide mute or the headset's call mode.
    public var note: String? {
        state.withLock { state in
            guard let target = state.target else {
                return nil
            }
            return target.note
                ?? HeadsetCallMode.note(
                    rateHz: devices.snapshot.selection.output?.nominalSampleRate
                )
        }
    }

    /// Starts following the output device and the process list.
    ///
    /// The process list is what tells the tap that the tapped application has quit, so the
    /// aggregate device does not outlive the process it carries.
    public func start() {
        let alreadyStarted = state.withLock { state -> Bool in
            guard !state.isStarted else {
                return true
            }
            state.isStarted = true
            return false
        }
        guard !alreadyStarted else {
            return
        }
        let observation = devices.onChange { [weak self] _ in
            self?.refresh()
        }
        let processObservation = processes.observe { [weak self] in
            self?.refresh()
        }
        state.withLock {
            $0.observation = observation
            $0.processObservation = processObservation
        }
        refresh()
    }

    /// Stops following the output and tears the tap down.
    public func stop() {
        let (observation, processObservation) = state.withLock {
            state -> ((any DeviceObservation)?, (any DeviceObservation)?) in
            let observations = (state.observation, state.processObservation)
            state.observation = nil
            state.processObservation = nil
            state.isStarted = false
            state.client = nil
            return observations
        }
        observation?.cancel()
        processObservation?.cancel()
        apply.withLock { _ in
            stopTap()
            publish(.off)
        }
    }

    /// Follows the microphone path, which reports the app reading the microphone.
    public func handle(_ engagement: ClientEngagement) {
        let client: String?
        switch engagement {
        case .standby:
            client = nil
        case .restoring(let name):
            client = name
        }
        state.withLock { $0.client = client }
        refresh()
    }

    /// Applies a changed toggle or headphone list.
    public func update(_ settings: Settings) {
        state.withLock { $0.settings = settings }
        refresh()
    }

    /// Re-runs the guard and the target lookup, then starts or stops the tap to match.
    public func refresh() {
        apply.withLock { _ in
            let (settings, client) = state.withLock { ($0.settings, $0.client) }
            let output = devices.snapshot.selection.output
            let allowed = HeadphoneGuard.allows(
                output,
                headphones: settings.headphoneUIDs,
                allowedOutputUID: settings.allowedOutputUID
            )
            guard settings.isEnabled, let client else {
                return stopTapAndPublish(.off)
            }
            guard allowed, let output else {
                return stopTapAndPublish(.pausedOnSpeakers)
            }
            guard
                let target = ProcessTapTargets.target(
                    processes: processes.processes, client: client)
            else {
                return stopTapAndPublish(.off)
            }
            if state.withLock({ $0.target == target }) {
                return
            }
            stopTap()
            do {
                _ = try tap.start(target, outputUID: output.uid)
            } catch TapError.permissionDenied {
                return publish(.permissionDenied)
            } catch {
                return publish(.failed(String(describing: error)))
            }
            let pid = target.processes.first?.pid ?? 0
            state.withLock { $0.target = target }
            publish(.tapping(pid: pid, name: target.name))
        }
    }

    private func stopTapAndPublish(_ outcome: IncomingTapOutcome) {
        stopTap()
        publish(outcome)
    }

    private func stopTap() {
        let wasTapping = state.withLock { state -> Bool in
            let tapping = state.target != nil
            state.target = nil
            return tapping
        }
        guard wasTapping else {
            return
        }
        tap.stop()
    }

    private func publish(_ outcome: IncomingTapOutcome) {
        let changed = state.withLock { state -> Bool in
            guard state.outcome != outcome else {
                return false
            }
            state.outcome = outcome
            return true
        }
        guard changed else {
            return
        }
        onOutcome(outcome)
    }
}

/// Lists the running system's audio processes through Core Audio.
public final class CoreAudioProcessObjectSource: AudioProcessObjectSource {
    public init() {}

    public func observe(
        _ onChange: @escaping @Sendable () -> Void
    ) -> any DeviceObservation {
        CoreAudioProcessSource().observe(onChange)
    }

    public var processes: [AudioProcessObject] {
        CoreAudioProcessListing.objects(
            of: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList
        ).compactMap { object in
            guard let pid = CoreAudioProcessListing.pid(object) else {
                return nil
            }
            return AudioProcessObject(
                objectID: object,
                pid: pid,
                bundleID: CoreAudioProcessListing.string(
                    object,
                    selector: kAudioProcessPropertyBundleID
                ),
                name: CoreAudioProcessListing.name(pid: pid),
                isRunningInput: (CoreAudioProperties.uint32(
                    object,
                    kAudioProcessPropertyIsRunningInput
                ) ?? 0) != 0,
                isRunningOutput: (CoreAudioProperties.uint32(
                    object,
                    kAudioProcessPropertyIsRunningOutput
                ) ?? 0) != 0
            )
        }
    }
}

/// The Core Audio property reads the process listing needs.
///
/// The watcher keeps its own readers private, so this small copy serves the tap without
/// widening that API; the device helpers are shared with the rest of the audio layer.
private enum CoreAudioProcessListing {
    static func objects(
        of object: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> [AudioObjectID] {
        var address = CoreAudioProperties.address(selector)
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
            size > 0
        else {
            return []
        }
        var identifiers = [AudioObjectID](
            repeating: kAudioObjectUnknown,
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        let status = identifiers.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else {
                return kAudioHardwareBadObjectError
            }
            return AudioObjectGetPropertyData(object, &address, 0, nil, &size, base)
        }
        return status == noErr ? identifiers : []
    }

    static func pid(_ object: AudioObjectID) -> pid_t? {
        var address = CoreAudioProperties.address(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
        else {
            return nil
        }
        return value
    }

    static func string(
        _ object: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = CoreAudioProperties.address(selector)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else {
            return nil
        }
        let identifier = value as String
        return identifier.isEmpty ? nil : identifier
    }

    static func name(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            return nil
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
