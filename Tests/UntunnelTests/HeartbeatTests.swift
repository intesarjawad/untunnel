import Testing
import UntunnelAudio

@testable import Untunnel

private func prerequisites(
    virtualMicKind: String = "own",
    fallbackOK: Bool = true,
    livenessHeartbeat: Bool = true,
    sleepClean: Bool = true,
    permission: AudioPermission = .authorized
) -> Heartbeat.Prerequisites {
    Heartbeat.Prerequisites(
        virtualMicKind: virtualMicKind,
        fallbackOK: fallbackOK,
        livenessHeartbeat: livenessHeartbeat,
        sleepClean: sleepClean,
        permission: permission
    )
}

@Test
func everyDocumentedCheckPassesTheHeartbeat() {
    #expect(Heartbeat.isEligible(prerequisites()))
}

@Test
func theFallbackKindsTurnTheHeartbeatOffWithAReason() {
    let blackhole = prerequisites(virtualMicKind: "blackhole")
    #expect(Heartbeat.isEligible(blackhole) == false)
    #expect(blackhole.rejectionReason == "The Untunnel audio plug-in is not installed")

    let missing = prerequisites(fallbackOK: false)
    #expect(missing.rejectionReason == "The fallback check has not passed")
    #expect(prerequisites(livenessHeartbeat: false).rejectionReason != nil)
    #expect(prerequisites(sleepClean: false).rejectionReason != nil)
    #expect(prerequisites(permission: .denied).rejectionReason != nil)
}

@Test
func silenceHopsInWaitingKeepTheHeartbeat() {
    var ticker = HeartbeatTicker()
    let ready = prerequisites()

    let first = ticker.tick(hops: 10, status: .waiting, prerequisites: ready)
    let second = ticker.tick(hops: 20, status: .waiting, prerequisites: ready)

    #expect(first)
    #expect(second)
}

@Test
func aStalledPipelineInWaitingStopsTheHeartbeat() {
    var ticker = HeartbeatTicker()
    let ready = prerequisites()

    let first = ticker.tick(hops: 10, status: .waiting, prerequisites: ready)
    let stalled = ticker.tick(hops: 10, status: .waiting, prerequisites: ready)
    let resumed = ticker.tick(hops: 11, status: .waiting, prerequisites: ready)

    #expect(first)
    #expect(stalled == false)
    #expect(resumed)
}

@Test
func deniedPermissionNeverBeats() {
    var ticker = HeartbeatTicker()

    let beat = ticker.tick(
        hops: 10,
        status: .running,
        prerequisites: prerequisites(permission: .denied)
    )

    #expect(beat == false)
}

@Test
func theDefaultMenuStatusCarriesTheReasonWhenACheckIsMissing() {
    let status = AutoRouteMenuStatus.evaluate(
        prerequisites: prerequisites(sleepClean: false),
        enabled: true
    )

    #expect(status.isEnabled == false)
    #expect(status.reason == "The sleep check has not passed")
}

@Test
func theMenuShowsAutoRouteWhenEveryCheckPasses() {
    let status = AutoRouteMenuStatus.evaluate(prerequisites: prerequisites(), enabled: true)

    #expect(status.isEnabled)
    #expect(status.reason == nil)
}
