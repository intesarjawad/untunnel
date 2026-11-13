import Foundation
import Synchronization
import Testing

@testable import UntunnelAudio

private let virtualMicUID = "com.intesarjawad.untunnel.microphone"
private let appPID: pid_t = 4_242
private let appBundleID = "com.intesarjawad.untunnel"
private let zoom = AudioProcessClient(
    pid: 900,
    bundleID: "us.zoom.xos",
    name: "zoom.us",
    isRunningInput: true,
    inputDeviceUIDs: [virtualMicUID]
)

@Test
func aClientOnTheVirtualMicEngagesImmediately() {
    let source = FakeProcessSource(processes: [zoom])
    let recorder = EngagementRecorder()
    let watcher = makeWatcher(source: source, recorder: recorder)

    watcher.start()

    #expect(watcher.engagement == .restoring(client: "zoom.us"))
    #expect(recorder.engagements == [.restoring(client: "zoom.us")])
}

@Test
func selfIsExcludedByPidAndBundleIdentifier() {
    let byPID = AudioProcessClient(
        pid: appPID,
        bundleID: "com.example.helper",
        name: "helper",
        isRunningInput: true,
        inputDeviceUIDs: [virtualMicUID]
    )
    let byBundle = AudioProcessClient(
        pid: 901,
        bundleID: appBundleID,
        name: "Untunnel",
        isRunningInput: true,
        inputDeviceUIDs: [virtualMicUID]
    )
    let source = FakeProcessSource(processes: [byPID, byBundle])
    let recorder = EngagementRecorder()
    let watcher = makeWatcher(source: source, recorder: recorder)

    watcher.start()

    #expect(watcher.engagement == .standby)
    #expect(recorder.engagements.isEmpty)
}

@Test
func inputOnAnotherDeviceDoesNotEngage() {
    let source = FakeProcessSource(processes: [
        AudioProcessClient(
            pid: 902,
            name: "Audacity",
            isRunningInput: true,
            inputDeviceUIDs: ["built-in-microphone"]
        )
    ])
    let recorder = EngagementRecorder()
    let watcher = makeWatcher(source: source, recorder: recorder)

    watcher.start()

    #expect(watcher.engagement == .standby)
    #expect(recorder.engagements.isEmpty)
}

@Test
func aClientThatIsNotRunningInputDoesNotEngage() {
    let source = FakeProcessSource(processes: [
        AudioProcessClient(
            pid: 903,
            name: "Music",
            isRunningInput: false,
            inputDeviceUIDs: [virtualMicUID]
        )
    ])
    let recorder = EngagementRecorder()
    let watcher = makeWatcher(source: source, recorder: recorder)

    watcher.start()

    #expect(watcher.engagement == .standby)
}

@Test
func thePathIsReleasedTwoSecondsAfterTheLastClientStops() {
    let source = FakeProcessSource(processes: [zoom])
    let scheduler = ManualScheduler()
    let recorder = EngagementRecorder()
    let watcher = makeWatcher(source: source, scheduler: scheduler, recorder: recorder)
    watcher.start()

    source.set([])
    scheduler.advance(by: 1.9)
    #expect(watcher.engagement == .restoring(client: "zoom.us"))
    #expect(recorder.engagements == [.restoring(client: "zoom.us")])

    scheduler.advance(by: 0.2)
    #expect(watcher.engagement == .standby)
    #expect(recorder.engagements == [.restoring(client: "zoom.us"), .standby])
}

@Test
func aClientThatReturnsInsideTheReleaseWindowKeepsThePathOpen() {
    let source = FakeProcessSource(processes: [zoom])
    let scheduler = ManualScheduler()
    let recorder = EngagementRecorder()
    let watcher = makeWatcher(source: source, scheduler: scheduler, recorder: recorder)
    watcher.start()

    source.set([])
    scheduler.advance(by: 1)
    source.set([zoom])
    scheduler.advance(by: 5)

    #expect(watcher.engagement == .restoring(client: "zoom.us"))
    #expect(recorder.engagements == [.restoring(client: "zoom.us")])
}

@Test
func theLastOfSeveralClientsStartsTheReleaseWindow() {
    let alpha = AudioProcessClient(
        pid: 910,
        name: "alpha",
        isRunningInput: true,
        inputDeviceUIDs: [virtualMicUID]
    )
    let beta = AudioProcessClient(
        pid: 911,
        name: "beta",
        isRunningInput: true,
        inputDeviceUIDs: [virtualMicUID]
    )
    let source = FakeProcessSource(processes: [beta, alpha])
    let scheduler = ManualScheduler()
    let recorder = EngagementRecorder()
    let watcher = makeWatcher(source: source, scheduler: scheduler, recorder: recorder)
    watcher.start()

    #expect(watcher.engagement == .restoring(client: "alpha"))

    source.set([beta])
    scheduler.advance(by: 3)
    #expect(watcher.engagement == .restoring(client: "beta"))

    source.set([])
    scheduler.advance(by: 2)
    #expect(watcher.engagement == .standby)
}

@Test
func aReleaseThatHasFiredDoesNotReportStandbyTwice() {
    let source = FakeProcessSource(processes: [zoom])
    let scheduler = ManualScheduler()
    let recorder = EngagementRecorder()
    let watcher = makeWatcher(source: source, scheduler: scheduler, recorder: recorder)
    watcher.start()

    source.set([])
    scheduler.advance(by: 2)
    scheduler.advance(by: 2)

    #expect(recorder.engagements == [.restoring(client: "zoom.us"), .standby])
}

@Test
func theMenuTextNamesTheClientThatIsWaiting() {
    #expect(ClientEngagement.standby.menuText == "Standby")
    #expect(ClientEngagement.restoring(client: "zoom.us").menuText == "Restoring for zoom.us")
}

private func makeWatcher(
    source: FakeProcessSource,
    scheduler: ManualScheduler = ManualScheduler(),
    recorder: EngagementRecorder
) -> ClientWatcher {
    ClientWatcher(
        source: source,
        virtualMicUID: virtualMicUID,
        selfPID: appPID,
        selfBundleIdentifiers: [appBundleID],
        scheduler: scheduler,
        onEngagement: recorder.record
    )
}

private final class FakeProcessSource: AudioProcessSource, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AudioProcessClient]
    private var listener: (@Sendable () -> Void)?

    init(processes: [AudioProcessClient]) {
        stored = processes
    }

    var processes: [AudioProcessClient] {
        lock.withLock { stored }
    }

    func observe(
        _ onChange: @escaping @Sendable () -> Void
    ) -> any DeviceObservation {
        lock.withLock { listener = onChange }
        return FakeObservation { [weak self] in
            guard let self else {
                return
            }
            self.lock.withLock { self.listener = nil }
        }
    }

    func set(_ processes: [AudioProcessClient]) {
        let callback = lock.withLock { () -> (@Sendable () -> Void)? in
            stored = processes
            return listener
        }
        callback?()
    }
}

private final class ManualScheduler: EngagementScheduler, @unchecked Sendable {
    private final class Task: @unchecked Sendable {
        var remaining: TimeInterval
        let action: @Sendable () -> Void
        let cancelled = Atomic<Bool>(false)

        init(remaining: TimeInterval, action: @escaping @Sendable () -> Void) {
            self.remaining = remaining
            self.action = action
        }
    }

    private let lock = NSLock()
    private var tasks: [Task] = []

    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @Sendable () -> Void
    ) -> any DeviceObservation {
        let task = Task(remaining: delay, action: action)
        lock.withLock { tasks.append(task) }
        return FakeObservation { task.cancelled.store(true, ordering: .releasing) }
    }

    func advance(by seconds: TimeInterval) {
        let due = lock.withLock { () -> [Task] in
            for task in tasks {
                task.remaining -= seconds
            }
            let ready = tasks.filter { $0.remaining <= 0 }
            tasks.removeAll { $0.remaining <= 0 }
            return ready
        }
        for task in due where !task.cancelled.load(ordering: .acquiring) {
            task.action()
        }
    }
}

private final class EngagementRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ClientEngagement] = []

    var engagements: [ClientEngagement] {
        lock.withLock { stored }
    }

    func record(_ engagement: ClientEngagement) {
        lock.withLock { stored.append(engagement) }
    }
}

private final class FakeObservation: DeviceObservation {
    private let cancelHandler: @Sendable () -> Void

    init(cancel: @escaping @Sendable () -> Void) {
        cancelHandler = cancel
    }

    func cancel() {
        cancelHandler()
    }
}
