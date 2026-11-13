import Testing
import UntunnelEngine

@testable import Untunnel

private let low = Tier(sampleRate: 16_000, exitLayer: 4, lookAhead: 0)
private let middle = Tier(sampleRate: 24_000, exitLayer: 5, lookAhead: 0)
private let high = Tier(sampleRate: 48_000, exitLayer: 7, lookAhead: 0)

@Test
func lateFramesStepDownOnlyAboveTwoPercentInTenSeconds() {
    var recovery = TierRecovery(preferred: high, tiers: [low, middle, high], at: 0)
    #expect(recovery.update(hops: 500, late: 10, at: 10) == nil)
    #expect(recovery.update(hops: 999, late: 21, at: 19.9) == nil)
    #expect(recovery.update(hops: 1000, late: 21, at: 20) == middle)
    #expect(recovery.isReduced)
    recovery.restarted(at: 20)
    #expect(recovery.update(hops: 500, late: 11, at: 30) == low)
    recovery.restarted(at: 30)
    #expect(recovery.update(hops: 500, late: 11, at: 40) == nil)
}

@Test
func recoveryRequiresSixtySecondsWithoutAnotherLateFrame() {
    var recovery = TierRecovery(preferred: high, tiers: [low, middle, high], at: 0)
    #expect(recovery.update(hops: 500, late: 11, at: 10) == middle)
    recovery.restarted(at: 10)
    #expect(recovery.update(hops: 1000, late: 1, at: 30) == nil)
    #expect(recovery.update(hops: 3950, late: 1, at: 89) == nil)
    #expect(recovery.update(hops: 4000, late: 1, at: 90) == high)
    #expect(!recovery.isReduced)
}

@Test
func anIdleOrRestartedPipelineDoesNotTriggerRecoveryOrUnderflowCounters() {
    var recovery = TierRecovery(preferred: high, tiers: [low, high], at: 0)
    #expect(recovery.update(hops: 0, late: 0, at: 100) == nil)
    #expect(recovery.update(hops: 500, late: 11, at: 110) == low)
    #expect(recovery.update(hops: 0, late: 0, at: 111) == nil)
    #expect(recovery.update(hops: 0, late: 0, at: 180) == nil)
    #expect(recovery.update(hops: 1, late: 0, at: 181) == nil)
}

@Test
func waitingAndBypassRestartTheObservationWindow() {
    var recovery = TierRecovery(preferred: high, tiers: [low, high], at: 0)
    #expect(recovery.update(hops: 500, late: 0, at: 10) == nil)
    #expect(recovery.update(hops: 500, late: 0, at: 39, isRunning: false) == nil)
    #expect(recovery.update(hops: 503, late: 1, at: 40) == nil)
    #expect(recovery.update(hops: 1000, late: 1, at: 49) == nil)
    #expect(recovery.update(hops: 1500, late: 30, at: 59, isRunning: false) == nil)
    #expect(recovery.update(hops: 1503, late: 31, at: 60) == nil)
    #expect(recovery.update(hops: 2000, late: 31, at: 69) == nil)
    #expect(recovery.update(hops: 2500, late: 42, at: 79) == low)
}

@Test
func loweringTheRateNeverIncreasesTheExitDepth() {
    let expensiveLow = Tier(sampleRate: 16_000, exitLayer: 12, lookAhead: 0)
    var recovery = TierRecovery(preferred: high, tiers: [high, middle, low, expensiveLow], at: 0)
    #expect(recovery.update(hops: 500, late: 11, at: 10) == middle)
    recovery.restarted(at: 10)
    #expect(recovery.update(hops: 500, late: 11, at: 20) == low)
}
