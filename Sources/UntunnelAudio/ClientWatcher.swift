import CoreAudio
import Darwin
import Foundation
import Synchronization

/// One application the audio system reports as a client of a device.
///
/// The bundle identifier is what macOS publishes for an audio process; the executable name is
/// only a fallback for the process object's human-readable label.
public struct AudioProcessClient: Equatable, Sendable {
    public let pid: pid_t
    public let bundleID: String?
    public let name: String?
    public let isRunningInput: Bool
    public let inputDeviceUIDs: [String]

    public init(
        pid: pid_t,
        bundleID: String? = nil,
        name: String? = nil,
        isRunningInput: Bool,
        inputDeviceUIDs: [String]
    ) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.isRunningInput = isRunningInput
        self.inputDeviceUIDs = inputDeviceUIDs
    }

    /// The label the menu shows for a client that is waiting for the microphone.
    public var displayName: String {
        name ?? bundleID ?? "process \(pid)"
    }
}

/// A platform source of the applications that use audio devices.
///
/// The protocol keeps the engagement decision testable without Core Audio, the way
/// `DeviceSource` does for the device list.
public protocol AudioProcessSource: AnyObject, Sendable {
    var processes: [AudioProcessClient] { get }

    /// Starts reporting process-list and per-process input changes until the result is cancelled.
    func observe(_ onChange: @escaping @Sendable () -> Void) -> any DeviceObservation
}

/// What the microphone path should be doing because of other applications.
public enum ClientEngagement: Equatable, Sendable {
    case standby
    case restoring(client: String)

    /// The menu line for the current engagement.
    public var menuText: String {
        switch self {
        case .standby:
            return "Standby"
        case .restoring(let client):
            return "Restoring for \(client)"
        }
    }
}

/// Schedules the delayed release without blocking the caller.
///
/// It is a protocol so tests can release on command instead of waiting two seconds.
protocol EngagementScheduler: Sendable {
    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @Sendable () -> Void
    ) -> any DeviceObservation
}

/// Starts the microphone path while another application uses the virtual microphone.
///
/// The decision is made from the process list alone: a process that is running input on the
/// virtual microphone is a client, and the path stays open until every such process has stopped
/// for the release delay. A client that starts again inside that window cancels the release, so
/// an application that reopens its stream does not make the headset flap between rates.
public final class ClientWatcher: Sendable {
    /// How long the path stays open after the last client stops.
    public static let releaseDelay: TimeInterval = 2

    private struct Release {
        let token: UUID
        let observation: any DeviceObservation
    }

    private struct State {
        var engagement = ClientEngagement.standby
        var observation: (any DeviceObservation)?
        var release: Release?
        var isStarted = false
        /// Counts engagements so a release scheduled before one cannot attach itself after it.
        var revision = 0
    }

    private let source: any AudioProcessSource
    private let virtualMicUID: String
    private let selfPID: pid_t
    private let selfBundleIdentifiers: Set<String>
    private let scheduler: any EngagementScheduler
    private let onEngagement: @Sendable (ClientEngagement) -> Void
    private let state = Mutex(State())

    /// Creates a watcher that reports engagement changes through `onEngagement`.
    ///
    /// The current process is always excluded, and any bundle identifier in
    /// `selfBundleIdentifiers` is excluded as well because the audio process may belong to a
    /// helper with a different pid.
    public convenience init(
        source: any AudioProcessSource,
        virtualMicUID: String,
        selfPID: pid_t = getpid(),
        selfBundleIdentifiers: Set<String> = ClientWatcher.ownBundleIdentifiers,
        onEngagement: @escaping @Sendable (ClientEngagement) -> Void = { _ in }
    ) {
        self.init(
            source: source,
            virtualMicUID: virtualMicUID,
            selfPID: selfPID,
            selfBundleIdentifiers: selfBundleIdentifiers,
            scheduler: DispatchEngagementScheduler(),
            onEngagement: onEngagement
        )
    }

    init(
        source: any AudioProcessSource,
        virtualMicUID: String,
        selfPID: pid_t,
        selfBundleIdentifiers: Set<String>,
        scheduler: any EngagementScheduler,
        onEngagement: @escaping @Sendable (ClientEngagement) -> Void
    ) {
        self.source = source
        self.virtualMicUID = virtualMicUID
        self.selfPID = selfPID
        self.selfBundleIdentifiers = selfBundleIdentifiers
        self.scheduler = scheduler
        self.onEngagement = onEngagement
    }

    deinit {
        stop()
    }

    /// The engagement as of the last process change.
    public var engagement: ClientEngagement {
        state.withLock { $0.engagement }
    }

    /// The bundle identifiers the app can run under; the process identifier covers the rest.
    public static var ownBundleIdentifiers: Set<String> {
        Set([Bundle.main.bundleIdentifier].compactMap { $0 })
    }

    /// Starts observing the process list and announces the engagement already in effect.
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
        let observation = source.observe { [weak self] in
            self?.refresh()
        }
        state.withLock { $0.observation = observation }
        refresh()
    }

    /// Stops observing and cancels a pending release.
    public func stop() {
        let (observation, release) = state.withLock {
            state -> ((any DeviceObservation)?, (any DeviceObservation)?) in
            let result = (state.observation, state.release?.observation)
            state.observation = nil
            state.release = nil
            state.isStarted = false
            return result
        }
        observation?.cancel()
        release?.cancel()
    }

    /// Recomputes which client, if any, is using the virtual microphone.
    public func refresh() {
        if let client = activeClients().first {
            engage(client)
        } else {
            scheduleRelease()
        }
    }

    private func engage(_ client: AudioProcessClient) {
        let engagement = ClientEngagement.restoring(client: client.displayName)
        let (changed, pending) = state.withLock {
            state -> (Bool, (any DeviceObservation)?) in
            let pending = state.release?.observation
            state.release = nil
            state.revision &+= 1
            let changed = state.engagement != engagement
            state.engagement = engagement
            return (changed, pending)
        }
        pending?.cancel()
        guard changed else {
            return
        }
        onEngagement(engagement)
    }

    private func scheduleRelease() {
        let scheduled = state.withLock { state -> (Bool, Int) in
            guard case .restoring = state.engagement else {
                return (false, state.revision)
            }
            return (state.release == nil, state.revision)
        }
        guard scheduled.0 else {
            return
        }

        let token = UUID()
        let observation = scheduler.schedule(after: Self.releaseDelay) { [weak self] in
            self?.release(token: token)
        }
        let outdated = state.withLock { state -> Bool in
            guard state.revision == scheduled.1, state.release == nil,
                case .restoring = state.engagement
            else {
                return true
            }
            state.release = Release(token: token, observation: observation)
            return false
        }
        if outdated {
            observation.cancel()
        }
    }

    private func release(token: UUID) {
        let isCurrent = state.withLock { $0.release?.token == token }
        guard isCurrent else {
            return
        }
        // A process can start again without the watcher seeing a change first, so the live
        // process list decides; a client that came back cancels this release.
        guard activeClients().isEmpty else {
            refresh()
            return
        }
        let changed = state.withLock { state -> Bool in
            guard state.release?.token == token, case .restoring = state.engagement else {
                return false
            }
            state.release = nil
            state.engagement = .standby
            return true
        }
        guard changed else {
            return
        }
        onEngagement(.standby)
    }

    private func activeClients() -> [AudioProcessClient] {
        source.processes
            .filter(isExternalInputOnVirtualMic)
            .sorted {
                ($0.displayName, $0.pid) < ($1.displayName, $1.pid)
            }
    }

    private func isExternalInputOnVirtualMic(_ client: AudioProcessClient) -> Bool {
        guard client.isRunningInput, client.pid != selfPID else {
            return false
        }
        if let bundleID = client.bundleID, selfBundleIdentifiers.contains(bundleID) {
            return false
        }
        return client.inputDeviceUIDs.contains(virtualMicUID)
    }
}

/// Fires the release after the delay on a private queue and can be cancelled before it runs.
private final class DispatchEngagementScheduler: EngagementScheduler {
    private let queue = DispatchQueue(label: "com.intesarjawad.untunnel.engagement")

    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @Sendable () -> Void
    ) -> any DeviceObservation {
        let cancelled = Atomic<Bool>(false)
        queue.asyncAfter(deadline: .now() + delay) {
            guard !cancelled.load(ordering: .acquiring) else {
                return
            }
            action()
        }
        return ScheduledObservation { cancelled.store(true, ordering: .releasing) }
    }
}

private final class ScheduledObservation: DeviceObservation {
    private let cancelHandler: @Sendable () -> Void

    init(cancel: @escaping @Sendable () -> Void) {
        cancelHandler = cancel
    }

    func cancel() {
        cancelHandler()
    }
}

/// Reads the running system's audio clients through Core Audio.
public final class CoreAudioProcessSource: AudioProcessSource {
    public init() {}

    public var processes: [AudioProcessClient] {
        AudioProcessProperties.objects(
            of: AudioProcessProperties.systemObject,
            selector: kAudioHardwarePropertyProcessObjectList
        ).compactMap { process in
            guard let pid = AudioProcessProperties.pid(process) else {
                return nil
            }
            let devices = AudioProcessProperties.objects(
                of: process,
                selector: kAudioProcessPropertyDevices,
                scope: kAudioObjectPropertyScopeInput
            )
            return AudioProcessClient(
                pid: pid,
                bundleID: AudioProcessProperties.bundleID(process),
                name: AudioProcessProperties.name(pid: pid),
                isRunningInput: (CoreAudioProperties.uint32(
                    process,
                    kAudioProcessPropertyIsRunningInput
                ) ?? 0) != 0,
                inputDeviceUIDs: devices.compactMap(AudioProcessProperties.deviceUID)
            )
        }
    }

    public func observe(
        _ onChange: @escaping @Sendable () -> Void
    ) -> any DeviceObservation {
        CoreAudioProcessObservation(onChange: onChange)
    }
}

/// Listens to the process object list and to each process's input state.
private final class CoreAudioProcessObservation: DeviceObservation, @unchecked Sendable {
    private struct Registration {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private let queue = DispatchQueue(label: "com.intesarjawad.untunnel.audio.processes")
    private let onChange: @Sendable () -> Void
    private var processList: Registration?
    private var registrations: [Registration] = []
    private var cancelled = false

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        var address = CoreAudioProperties.address(kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshRegistrations()
        }
        if AudioObjectAddPropertyListenerBlock(
            AudioProcessProperties.systemObject, &address, queue, block
        ) == noErr {
            processList = Registration(
                object: AudioProcessProperties.systemObject,
                address: address,
                block: block
            )
        }
        queue.sync {
            refreshRegistrations()
        }
    }

    func cancel() {
        queue.sync {
            guard !cancelled else {
                return
            }
            cancelled = true
            for registration in registrations {
                remove(registration)
            }
            registrations.removeAll()
            if let processList {
                remove(processList)
            }
            processList = nil
        }
    }

    /// Re-registers every process because a process object disappears with its client.
    private func refreshRegistrations() {
        guard !cancelled else {
            return
        }
        for registration in registrations {
            remove(registration)
        }
        registrations.removeAll()
        let processes = AudioProcessProperties.objects(
            of: AudioProcessProperties.systemObject,
            selector: kAudioHardwarePropertyProcessObjectList
        )
        for process in processes {
            if let registration = add(
                process,
                selector: kAudioProcessPropertyIsRunningInput
            ) {
                registrations.append(registration)
            }
            if let registration = add(
                process,
                selector: kAudioProcessPropertyDevices,
                scope: kAudioObjectPropertyScopeInput
            ) {
                registrations.append(registration)
            }
        }
        onChange()
    }

    private func add(
        _ object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> Registration? {
        var address = CoreAudioProperties.address(selector, scope: scope)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onChange()
        }
        guard
            AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr
        else {
            return nil
        }
        return Registration(object: object, address: address, block: block)
    }

    private func remove(_ registration: Registration) {
        var address = registration.address
        AudioObjectRemovePropertyListenerBlock(
            registration.object, &address, queue, registration.block
        )
    }
}

/// The Core Audio property reads the process list needs.
private enum AudioProcessProperties {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func objects(
        of object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID] {
        var address = CoreAudioProperties.address(selector, scope: scope)
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
            return AudioObjectGetPropertyData(
                object, &address, 0, nil, &size, base
            )
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

    static func bundleID(_ object: AudioObjectID) -> String? {
        string(object, selector: kAudioProcessPropertyBundleID)
    }

    static func deviceUID(_ object: AudioObjectID) -> String? {
        string(object, selector: kAudioDevicePropertyDeviceUID)
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

    private static func string(
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
}
