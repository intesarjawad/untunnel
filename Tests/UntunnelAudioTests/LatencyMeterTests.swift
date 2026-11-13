import Darwin
import Testing

@testable import UntunnelAudio

@Test
func systemHostClockMatchesMachTimebase() {
    var timebase = mach_timebase_info_data_t()
    #expect(mach_timebase_info(&timebase) == KERN_SUCCESS)
    let ticks: UInt64 = 2_400_000
    let expectedMs = Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
    #expect(abs(HostClock.system.milliseconds(since: 0, until: ticks) - expectedMs) < 1e-9)
}

private func testMeter(deviceLatencyMs: Double = 0) -> LatencyMeter {
    LatencyMeter(
        deviceLatencyMs: deviceLatencyMs,
        clock: HostClock(ticksPerSecond: 1_000_000)
    )
}

@Test
func latencyMeterReportsNothingBeforeAnOutputPull() {
    let meter = testMeter()
    meter.noteInputCompletion(0)
    #expect(meter.medianHopLatencyMs == nil)
    #expect(meter.addedLatencyMs == nil)
}

@Test
func latencyMeterTakesTheMedianOfMatchedHops() {
    let meter = testMeter()
    let latencies = [10, 20, 30, 40, 50, 60, 70]
    for (index, latency) in latencies.enumerated() {
        let input = UInt64(index) * 1000
        meter.noteInputCompletion(input)
        meter.noteOutputPull(input + UInt64(latency) * 1000)
    }

    #expect(meter.medianHopLatencyMs == 40)
}

@Test
func latencyMeterKeepsOnlyTheLastFiftyHops() {
    let meter = testMeter()
    for index in 1...60 {
        let input = UInt64(index) * 1000
        meter.noteInputCompletion(input)
        meter.noteOutputPull(input + UInt64(index) * 1000)
    }

    // The window holds 11 through 60 milliseconds, whose middle pair is 35 and 36.
    #expect(meter.medianHopLatencyMs == 35.5)
}

@Test
func latencyMeterAddsTheDeviceDelayToTheReadout() {
    let meter = testMeter(deviceLatencyMs: 4.25)
    meter.noteInputCompletion(0)
    meter.noteOutputPull(40_000)

    #expect(meter.medianHopLatencyMs == 40)
    #expect(meter.addedLatencyMs == 44.25)
}

@Test
func latencyMeterIgnoresAPullWithNoMatchingInput() {
    let meter = testMeter()
    meter.noteOutputPull(10_000)

    #expect(meter.medianHopLatencyMs == nil)
}
