import CoreAudio
import Foundation
import Synchronization

/// A capture or playback device as the app needs to route audio.
///
/// Streams decide whether a device can be used on a path; the transport and the data source
/// decide which device the app prefers. `uid` is the stable identity, because a device ID
/// changes when the device is unplugged and a name is not unique.
public struct AudioDevice: Codable, Sendable, Equatable, Identifiable {
    public let uid: String
    public let name: String
    public let transport: AudioTransport
    public let hasInput: Bool
    public let hasOutput: Bool
    public let nominalSampleRate: Double
    public let dataSource: AudioDataSource

    public var id: String {
        uid
    }

    public init(
        uid: String,
        name: String,
        transport: AudioTransport,
        hasInput: Bool,
        hasOutput: Bool,
        nominalSampleRate: Double,
        dataSource: AudioDataSource
    ) {
        self.uid = uid
        self.name = name
        self.transport = transport
        self.hasInput = hasInput
        self.hasOutput = hasOutput
        self.nominalSampleRate = nominalSampleRate
        self.dataSource = dataSource
    }

    private enum CodingKeys: String, CodingKey {
        case uid
        case name
        case transport
        case hasInput = "has_input"
        case hasOutput = "has_output"
        case nominalSampleRate = "nominal_sample_rate"
        case dataSource = "data_source"
    }
}

/// How a device reaches the machine, reduced to the cases that change routing.
public enum AudioTransport: String, Codable, Sendable {
    case builtIn
    case bluetooth
    case usb
    case aggregate
    case virtual
    case other
}

/// The jack or speaker a built-in output currently selects.
///
/// Only devices that publish a data source report one; everything else is `none`.
public enum AudioDataSource: String, Codable, Sendable {
    case headphones
    case speakers
    case none
}

/// The two devices that make the app's microphone visible to other applications.
///
/// The app writes into the hidden feed and readers capture from the visible input. The
/// fallback uses one loopback device for both when the app's own devices are not installed.
public struct VirtualMic: Codable, Sendable, Equatable {
    public let feedUID: String
    public let inputUID: String
    public let usesFallback: Bool

    public init(feedUID: String, inputUID: String, usesFallback: Bool) {
        self.feedUID = feedUID
        self.inputUID = inputUID
        self.usesFallback = usesFallback
    }

    private enum CodingKeys: String, CodingKey {
        case feedUID = "feed_uid"
        case inputUID = "input_uid"
        case usesFallback = "uses_fallback"
    }
}

/// The devices a running session would use, derived from one enumeration.
public struct DeviceSelection: Sendable, Equatable {
    public let virtualMic: VirtualMic?
    public let headset: AudioDevice?
    public let input: AudioDevice?
    public let output: AudioDevice?

    public init(
        virtualMic: VirtualMic?,
        headset: AudioDevice?,
        input: AudioDevice?,
        output: AudioDevice?
    ) {
        self.virtualMic = virtualMic
        self.headset = headset
        self.input = input
        self.output = output
    }
}

/// A platform source of devices and of the system's default input and output.
///
/// The protocol exists so routing and change handling can run without Core Audio or hardware.
public protocol DeviceSource: AnyObject, Sendable {
    var devices: [AudioDevice] { get }
    var defaultInputDeviceUID: String? { get }
    var defaultOutputDeviceUID: String? { get }

    /// Starts reporting device-list and default-device changes until the result is cancelled.
    func observe(_ onChange: @escaping @Sendable () -> Void) -> any DeviceObservation
}

/// A live registration with a `DeviceSource`.
public protocol DeviceObservation: AnyObject, Sendable {
    func cancel()
}

/// The stable identifiers the app's own audio devices and the fallback loopback use.
public enum VirtualMicDevices {
    public static let feedUID = "com.intesarjawad.untunnel.feed"
    public static let inputUID = "com.intesarjawad.untunnel.microphone"
    public static let fallbackUID = "BlackHole2ch_UID"
}

/// Chooses the devices a session uses from one enumeration.
public enum AudioDevicePolicy {
    /// The app's hidden feed and visible input, or the loopback fallback when either is absent.
    public static func virtualMic(in devices: [AudioDevice]) -> VirtualMic? {
        let hasFeed = devices.contains { $0.uid == VirtualMicDevices.feedUID }
        let hasInput = devices.contains { $0.uid == VirtualMicDevices.inputUID }
        if hasFeed && hasInput {
            return VirtualMic(
                feedUID: VirtualMicDevices.feedUID,
                inputUID: VirtualMicDevices.inputUID,
                usesFallback: false
            )
        }
        if devices.contains(where: { $0.uid == VirtualMicDevices.fallbackUID }) {
            return VirtualMic(
                feedUID: VirtualMicDevices.fallbackUID,
                inputUID: VirtualMicDevices.fallbackUID,
                usesFallback: true
            )
        }
        return nil
    }

    /// Picks the headset, input and output for a session.
    ///
    /// A Bluetooth device with capture is the default headset. A test pin overrides the input
    /// so a loopback can be watched deterministically; otherwise the headset wins over the
    /// system default. The virtual microphone is never an input unless a test pins it, because
    /// capturing from it would create a feedback loop.
    public static func select(
        devices: [AudioDevice],
        defaultInputUID: String?,
        defaultOutputUID: String?,
        testInputUID: String? = nil
    ) -> DeviceSelection {
        let virtualMic = virtualMic(in: devices)
        let virtualUIDs: Set<String> = [
            VirtualMicDevices.feedUID,
            VirtualMicDevices.inputUID,
            VirtualMicDevices.fallbackUID,
        ]
        let headset = devices.first {
            $0.transport == .bluetooth && $0.hasInput && !virtualUIDs.contains($0.uid)
        }

        let input: AudioDevice?
        if let testInputUID {
            input = devices.first { $0.uid == testInputUID && $0.hasInput }
        } else if let headset {
            input = headset
        } else if let defaultInputUID,
            let device = devices.first(where: {
                $0.uid == defaultInputUID && $0.hasInput && !virtualUIDs.contains($0.uid)
            })
        {
            input = device
        } else {
            input = devices.first { $0.hasInput && !virtualUIDs.contains($0.uid) }
        }

        let output =
            defaultOutputUID.flatMap { uid in
                devices.first { $0.uid == uid && $0.hasOutput }
            } ?? devices.first { $0.hasOutput }

        return DeviceSelection(
            virtualMic: virtualMic,
            headset: headset,
            input: input,
            output: output
        )
    }
}

/// Tracks the current devices and notifies observers when routing-relevant state changes.
public final class AudioDevices: Sendable {
    /// The device list, system defaults and selection at one point in time.
    public struct Snapshot: Sendable, Equatable {
        public let devices: [AudioDevice]
        public let defaultInputUID: String?
        public let defaultOutputUID: String?
        public let selection: DeviceSelection

        public init(
            devices: [AudioDevice],
            defaultInputUID: String?,
            defaultOutputUID: String?,
            selection: DeviceSelection
        ) {
            self.devices = devices
            self.defaultInputUID = defaultInputUID
            self.defaultOutputUID = defaultOutputUID
            self.selection = selection
        }
    }

    /// The input override reserved for automated tests; it is not a user setting.
    static let testInputUIDKey = "UNTUNNEL_TEST_INPUT_UID"

    private struct State: Sendable {
        var snapshot: Snapshot
        var observers: [UUID: @Sendable (Snapshot) -> Void] = [:]
        var observation: (any DeviceObservation)?
    }

    private let source: any DeviceSource
    private let testInputUID: String?
    private let state: Mutex<State>

    /// Starts listening for device changes and derives the first selection.
    ///
    /// Passing an environment makes the test override visible to unit tests; the app uses the
    /// process environment. The override is announced because it silently changes routing.
    public init(
        source: any DeviceSource,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.source = source
        let testInputUID = environment[Self.testInputUIDKey]
        self.testInputUID = testInputUID
        if let testInputUID {
            let message =
                "warning: \(Self.testInputUIDKey) pins audio input to \(testInputUID); "
                + "unset it outside tests\n"
            FileHandle.standardError.write(Data(message.utf8))
        }

        let devices = source.devices
        let defaultInputUID = source.defaultInputDeviceUID
        let defaultOutputUID = source.defaultOutputDeviceUID
        let selection = AudioDevicePolicy.select(
            devices: devices,
            defaultInputUID: defaultInputUID,
            defaultOutputUID: defaultOutputUID,
            testInputUID: testInputUID
        )
        let snapshot = Snapshot(
            devices: devices,
            defaultInputUID: defaultInputUID,
            defaultOutputUID: defaultOutputUID,
            selection: selection
        )
        state = Mutex(State(snapshot: snapshot))

        let observation = source.observe { [weak self] in
            self?.refresh()
        }
        state.withLock { $0.observation = observation }
    }

    deinit {
        state.withLock { $0.observation?.cancel() }
    }

    /// The latest enumeration and selection.
    public var snapshot: Snapshot {
        state.withLock { $0.snapshot }
    }

    /// Reports a new snapshot after the next change, until the result is cancelled.
    public func onChange(
        _ observer: @escaping @Sendable (Snapshot) -> Void
    ) -> any DeviceObservation {
        let id = UUID()
        state.withLock { $0.observers[id] = observer }
        return Observation { [weak self] in
            _ = self?.state.withLock { $0.observers.removeValue(forKey: id) }
        }
    }

    /// Re-enumerates the source and notifies observers only when the snapshot differs.
    public func refresh() {
        let devices = source.devices
        let defaultInputUID = source.defaultInputDeviceUID
        let defaultOutputUID = source.defaultOutputDeviceUID
        let selection = AudioDevicePolicy.select(
            devices: devices,
            defaultInputUID: defaultInputUID,
            defaultOutputUID: defaultOutputUID,
            testInputUID: testInputUID
        )
        let snapshot = Snapshot(
            devices: devices,
            defaultInputUID: defaultInputUID,
            defaultOutputUID: defaultOutputUID,
            selection: selection
        )

        let observers: [@Sendable (Snapshot) -> Void] = state.withLock { state in
            guard state.snapshot != snapshot else {
                return []
            }
            state.snapshot = snapshot
            return Array(state.observers.values)
        }
        for observer in observers {
            observer(snapshot)
        }
    }
}

/// Removes one observer when the caller cancels it.
private final class Observation: DeviceObservation {
    private let remove: @Sendable () -> Void

    init(remove: @escaping @Sendable () -> Void) {
        self.remove = remove
    }

    func cancel() {
        remove()
    }
}

/// Reads the running system's devices through Core Audio.
public final class CoreAudioDeviceSource: DeviceSource {
    public init() {}

    public var devices: [AudioDevice] {
        Self.enumerateDevices()
    }

    public var defaultInputDeviceUID: String? {
        Self.defaultDeviceUID(kAudioHardwarePropertyDefaultInputDevice)
    }

    public var defaultOutputDeviceUID: String? {
        Self.defaultDeviceUID(kAudioHardwarePropertyDefaultOutputDevice)
    }

    public func observe(
        _ onChange: @escaping @Sendable () -> Void
    ) -> any DeviceObservation {
        let addresses = [
            Self.address(kAudioHardwarePropertyDevices),
            Self.address(kAudioHardwarePropertyDefaultInputDevice),
            Self.address(kAudioHardwarePropertyDefaultOutputDevice),
        ]
        return CoreAudioObservation(addresses: addresses, onChange: onChange)
    }

    private static func enumerateDevices() -> [AudioDevice] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
            ) == noErr,
            size > 0
        else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var identifiers = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        let status = identifiers.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else {
                return kAudioHardwareBadObjectError
            }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, base
            )
        }
        guard status == noErr else {
            return []
        }

        return identifiers.compactMap(device)
    }

    private static func device(_ identifier: AudioObjectID) -> AudioDevice? {
        guard identifier != kAudioObjectUnknown,
            let uid = string(
                identifier,
                selector: kAudioDevicePropertyDeviceUID
            ),
            !uid.isEmpty
        else {
            return nil
        }
        let name =
            string(identifier, selector: kAudioObjectPropertyName)
            ?? uid
        let transport = Self.transport(
            uint32(
                identifier,
                selector: kAudioDevicePropertyTransportType
            ) ?? 0
        )
        let nominalSampleRate =
            float64(
                identifier,
                selector: kAudioDevicePropertyNominalSampleRate
            ) ?? 0
        return AudioDevice(
            uid: uid,
            name: name,
            transport: transport,
            hasInput: streamCount(identifier, scope: kAudioDevicePropertyScopeInput) > 0,
            hasOutput: streamCount(identifier, scope: kAudioDevicePropertyScopeOutput) > 0,
            nominalSampleRate: nominalSampleRate,
            dataSource: dataSource(identifier)
        )
    }

    private static func transport(_ raw: UInt32) -> AudioTransport {
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        case kAudioDeviceTransportTypeUSB:
            return .usb
        case kAudioDeviceTransportTypeAggregate:
            return .aggregate
        case kAudioDeviceTransportTypeVirtual:
            return .virtual
        default:
            return .other
        }
    }

    private static func dataSource(_ identifier: AudioObjectID) -> AudioDataSource {
        guard
            let raw = uint32(
                identifier,
                selector: kAudioDevicePropertyDataSource,
                scope: kAudioDevicePropertyScopeOutput
            )
        else {
            return .none
        }
        switch raw {
        case Self.headphonesSource:
            return .headphones
        case Self.speakersSource:
            return .speakers
        default:
            return .none
        }
    }

    /// `'hdpn'`, the built-in output's headphone jack.
    private static let headphonesSource: UInt32 = 0x6864_706E
    /// `'ispk'`, the built-in output's internal speakers.
    private static let speakersSource: UInt32 = 0x6973_706B

    private static func defaultDeviceUID(
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = Self.address(selector)
        var identifier = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &identifier
            ) == noErr,
            identifier != kAudioObjectUnknown
        else {
            return nil
        }
        return string(identifier, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func streamCount(
        _ identifier: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> Int {
        var address = Self.address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(identifier, &address, 0, nil, &size)
                == noErr
        else {
            return 0
        }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    private static func string(
        _ identifier: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = Self.address(selector)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(
                identifier, &address, 0, nil, &size, pointer
            )
        }
        guard status == noErr else {
            return nil
        }
        return value as String
    }

    private static func uint32(
        _ identifier: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> UInt32? {
        var address = Self.address(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard
            AudioObjectGetPropertyData(
                identifier, &address, 0, nil, &size, &value
            ) == noErr
        else {
            return nil
        }
        return value
    }

    private static func float64(
        _ identifier: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> Float64? {
        var address = Self.address(selector)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard
            AudioObjectGetPropertyData(
                identifier, &address, 0, nil, &size, &value
            ) == noErr
        else {
            return nil
        }
        return value
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

/// Listens to the system object's device-list and default-device properties.
private final class CoreAudioObservation: DeviceObservation, @unchecked Sendable {
    private struct Registration {
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private var registrations: [Registration] = []
    private let queue = DispatchQueue(label: "com.intesarjawad.untunnel.audio.devices")

    init(
        addresses: [AudioObjectPropertyAddress],
        onChange: @escaping @Sendable () -> Void
    ) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            onChange()
        }
        for var address in addresses {
            if AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, queue, block
            ) == noErr {
                registrations.append(Registration(address: address, block: block))
            }
        }
    }

    func cancel() {
        for registration in registrations {
            var address = registration.address
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, queue, registration.block
            )
        }
        registrations.removeAll()
    }
}
