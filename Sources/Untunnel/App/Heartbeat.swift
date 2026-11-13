import CoreAudio
import Foundation
import UntunnelAudio

/// Whether the app may keep the feed device's watchdog property alive.
///
/// The property only makes sense on the app's own plug-in, and only when the checks that
/// prove the fallback and the sleep behaviour still pass. The menu shows the reason whenever
/// one of those conditions is false.
enum Heartbeat {
    /// The property the driver watches for a live pipeline.
    static let propertySelector: AudioObjectPropertySelector = 0x6862_7420
    static let interval: TimeInterval = 1

    struct Prerequisites: Equatable, Sendable {
        var virtualMicKind: String
        var fallbackOK: Bool
        var livenessHeartbeat: Bool
        var sleepClean: Bool
        var permission: AudioPermission

        var rejectionReason: String? {
            if virtualMicKind != "own" {
                return "The Untunnel audio plug-in is not installed"
            }
            if !fallbackOK {
                return "The fallback check has not passed"
            }
            if !livenessHeartbeat {
                return "The liveness check has not passed"
            }
            if !sleepClean {
                return "The sleep check has not passed"
            }
            if !permission.isAuthorized {
                return "Microphone permission is not granted"
            }
            return nil
        }

        var isEligible: Bool {
            rejectionReason == nil
        }
    }

    static func isEligible(_ prerequisites: Prerequisites) -> Bool {
        prerequisites.isEligible
    }
}

/// What the plug-in probe printed on a Mac with the driver installed (ADR-0001).
///
/// Each value starts false and changes only when `hal_probe.sh` has printed `FALLBACK_OK`,
/// `LIVENESS heartbeat` and `SLEEP_CLEAN` and ADR-0001 records it. Until then the heartbeat
/// stays off, so the plug-in never arms its watchdog, and auto-route shows off with the reason.
struct HALProbeResults: Equatable, Sendable {
    var fallbackOK: Bool
    var livenessHeartbeat: Bool
    var sleepClean: Bool

    static let recorded = HALProbeResults(
        fallbackOK: false,
        livenessHeartbeat: false,
        sleepClean: false
    )

    func prerequisites(
        virtualMic: VirtualMic?,
        permission: AudioPermission
    ) -> Heartbeat.Prerequisites {
        Heartbeat.Prerequisites(
            virtualMicKind: virtualMic.map { $0.usesFallback ? "blackhole" : "own" } ?? "none",
            fallbackOK: fallbackOK,
            livenessHeartbeat: livenessHeartbeat,
            sleepClean: sleepClean,
            permission: permission
        )
    }
}

/// Decides whether the next one-second tick should refresh the property.
///
/// `hops` is nil in Standby, where no pipeline runs and a tick on the main run loop is the
/// proof of life. While engaged, a silence hop still advances the pipeline counter, so routing
/// in `waiting` keeps beating; a counter that did not move means a stalled pipeline, and the
/// driver must then stop seeing a live app so macOS falls back to a real microphone.
struct HeartbeatTicker {
    private var lastHops: UInt64?

    mutating func tick(
        hops: UInt64?,
        status: PipelineStatus,
        prerequisites: Heartbeat.Prerequisites
    ) -> Bool {
        defer { lastHops = hops }
        guard prerequisites.isEligible else {
            return false
        }
        guard let hops else {
            return true
        }
        guard status == .waiting || status == .running || status == .bypassed else {
            return false
        }
        guard let lastHops else {
            return hops > 0
        }
        return hops != lastHops
    }
}

/// Writes the live marker on the feed device.
///
/// It changes a system audio property, so the app reaches it through this protocol and tests
/// use a fake instead.
protocol HeartbeatSink: AnyObject, Sendable {
    func setHeartbeat()
}

/// The live sink, which writes `'hbt '` on the device with the feed UID.
final class CoreAudioHeartbeatSink: HeartbeatSink, @unchecked Sendable {
    private let feedUID: String

    init(feedUID: String) {
        self.feedUID = feedUID
    }

    func setHeartbeat() {
        guard let device = CoreAudioDeviceLookup.deviceID(for: feedUID) else {
            return
        }
        var address = AudioObjectPropertyAddress(
            mSelector: Heartbeat.propertySelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // A plug-in's custom property carries a property list, which the HAL passes by reference.
        var value: CFPropertyList = 1 as CFNumber
        _ = withUnsafeMutablePointer(to: &value) {
            AudioObjectSetPropertyData(
                device,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<CFPropertyList>.size),
                $0
            )
        }
    }
}

/// Ticks the heartbeat on the main run loop once a second.
@MainActor
final class HeartbeatMonitor {
    private let sink: any HeartbeatSink
    private let hops: () -> UInt64?
    private let status: () -> PipelineStatus
    private let prerequisites: () -> Heartbeat.Prerequisites
    private var ticker = HeartbeatTicker()
    private var timer: Timer?
    private(set) var isBeating = false

    init(
        sink: any HeartbeatSink,
        hops: @escaping () -> UInt64?,
        status: @escaping () -> PipelineStatus,
        prerequisites: @escaping () -> Heartbeat.Prerequisites
    ) {
        self.sink = sink
        self.hops = hops
        self.status = status
        self.prerequisites = prerequisites
    }

    /// Reads the hop counter and status the pipeline already publishes.
    convenience init(
        pipeline: Pipeline,
        sink: any HeartbeatSink,
        prerequisites: @escaping () -> Heartbeat.Prerequisites
    ) {
        self.init(
            sink: sink,
            hops: { pipeline.metrics.hops },
            status: { pipeline.metrics.status },
            prerequisites: prerequisites
        )
    }

    func start() {
        guard timer == nil else {
            return
        }
        let timer = Timer(timeInterval: Heartbeat.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isBeating = false
    }

    @discardableResult
    func tick() -> Bool {
        let beat = ticker.tick(
            hops: hops(),
            status: status(),
            prerequisites: prerequisites()
        )
        if beat {
            sink.setHeartbeat()
        }
        isBeating = beat
        return beat
    }
}
