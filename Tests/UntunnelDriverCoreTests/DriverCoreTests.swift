import Testing
import UntunnelDriverCore

private let second: UInt64 = 1_000_000_000

/// A ring over owned storage, freed when the test's value goes away.
private final class Ring {
    private let storage: UnsafeMutablePointer<Float>
    var ring = untunnel_ring()

    init(capacity: Int64) {
        storage = .allocate(capacity: Int(capacity) * Int(UNTUNNEL_RING_CHANNELS))
        untunnel_ring_init(&ring, storage, capacity)
    }

    deinit {
        storage.deallocate()
    }

    func write(at time: Int64, _ samples: [Float], channels: UInt32) {
        samples.withUnsafeBufferPointer {
            untunnel_ring_write(
                &ring,
                time,
                $0.baseAddress,
                UInt32(samples.count) / channels,
                channels
            )
        }
    }

    func read(at time: Int64, frames: Int, channels: UInt32) -> [Float] {
        var result = [Float](repeating: -1, count: frames * Int(channels))
        result.withUnsafeMutableBufferPointer {
            untunnel_ring_read(&ring, time, $0.baseAddress, UInt32(frames), channels)
        }
        return result
    }

    func clear() {
        untunnel_ring_clear(&ring)
    }
}

@Test
func anUnwrittenRingReadsSilence() {
    let ring = Ring(capacity: 8)
    #expect(ring.read(at: 5, frames: 3, channels: 2) == [0, 0, 0, 0, 0, 0])
}

@Test
func aMonoWriteFillsBothChannelsAtItsSampleTime() {
    let ring = Ring(capacity: 8)
    ring.write(at: 10, [1, 2, 3], channels: 1)
    #expect(ring.read(at: 9, frames: 5, channels: 2) == [0, 0, 1, 1, 2, 2, 3, 3, 0, 0])
}

@Test
func aMonoReaderHearsTheAverageOfAStereoWrite() {
    let ring = Ring(capacity: 8)
    ring.write(at: 0, [1, 3, 5, 7], channels: 2)
    #expect(ring.read(at: 0, frames: 2, channels: 1) == [2, 6])
}

@Test
func framesOlderThanTheCapacityReadAsSilence() {
    let ring = Ring(capacity: 4)
    ring.write(at: 2, [1, 2, 3, 4, 5, 6], channels: 1)
    #expect(ring.read(at: 2, frames: 6, channels: 1) == [0, 0, 3, 4, 5, 6])
}

@Test
func aSkippedSpanReadsAsSilenceRatherThanStaleFrames() {
    let ring = Ring(capacity: 8)
    ring.write(at: 0, [9, 9, 9, 9], channels: 1)
    ring.clear()
    ring.write(at: 0, [1, 1], channels: 1)
    ring.write(at: 4, [2], channels: 1)
    #expect(ring.read(at: 0, frames: 5, channels: 1) == [1, 1, 0, 0, 2])
}

@Test
func aClearedRingReadsSilenceUntilTheNextWrite() {
    let ring = Ring(capacity: 8)
    ring.write(at: 0, [1, 2], channels: 1)
    ring.clear()
    #expect(ring.read(at: 0, frames: 2, channels: 1) == [0, 0])
    ring.write(at: 6, [3], channels: 1)
    #expect(ring.read(at: 6, frames: 1, channels: 1) == [3])
}

@Test
func theClockReportsTheLatestPeriodBoundary() {
    var clock = untunnel_clock()
    untunnel_clock_init(&clock, 2, 4)
    untunnel_clock_start(&clock, 1000)

    func stamp(_ now: UInt64) -> (Double, UInt64) {
        var sampleTime = -1.0
        var hostTime: UInt64 = 0
        untunnel_clock_zero_time_stamp(&clock, now, &sampleTime, &hostTime)
        return (sampleTime, hostTime)
    }

    #expect(stamp(900) == (0, 1000))
    #expect(stamp(1000) == (0, 1000))
    #expect(stamp(1007) == (0, 1000))
    #expect(stamp(1008) == (4, 1008))
    #expect(stamp(1030) == (12, 1024))
}

@Test
func theMicrophoneStaysListedUntilTheFirstWrite() {
    var liveness = untunnel_liveness()
    untunnel_liveness_init(&liveness, UNTUNNEL_LIVENESS_WRITES, 2 * second)
    #expect(!untunnel_liveness_update(&liveness, 10 * second))
    #expect(liveness.visible)
}

@Test
func twoSecondsWithoutAWriteRemoveTheMicrophoneAndTheNextWriteRestoresIt() {
    var liveness = untunnel_liveness()
    untunnel_liveness_init(&liveness, UNTUNNEL_LIVENESS_WRITES, 2 * second)
    untunnel_liveness_note_write(&liveness, 1 * second)

    #expect(!untunnel_liveness_update(&liveness, 2_500_000_000))
    #expect(liveness.visible)
    #expect(untunnel_liveness_update(&liveness, 3 * second))
    #expect(!liveness.visible)
    #expect(!untunnel_liveness_update(&liveness, 4 * second))

    untunnel_liveness_note_write(&liveness, 4_500_000_000)
    #expect(untunnel_liveness_update(&liveness, 4_600_000_000))
    #expect(liveness.visible)
}

@Test
func inClientModeTheLastFeedClientLeavingRemovesTheMicrophone() {
    var liveness = untunnel_liveness()
    untunnel_liveness_init(&liveness, UNTUNNEL_LIVENESS_CLIENTS, 2 * second)
    untunnel_liveness_note_write(&liveness, 1 * second)
    #expect(!untunnel_liveness_update(&liveness, 60 * second))
    #expect(liveness.visible)

    untunnel_liveness_client_added(&liveness)
    untunnel_liveness_client_added(&liveness)
    #expect(!untunnel_liveness_update(&liveness, 61 * second))
    untunnel_liveness_client_removed(&liveness)
    #expect(!untunnel_liveness_update(&liveness, 62 * second))
    #expect(liveness.visible)

    untunnel_liveness_client_removed(&liveness)
    #expect(untunnel_liveness_update(&liveness, 63 * second))
    #expect(!liveness.visible)

    untunnel_liveness_client_added(&liveness)
    #expect(untunnel_liveness_update(&liveness, 64 * second))
    #expect(liveness.visible)
}
