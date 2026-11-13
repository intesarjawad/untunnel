import Foundation
import UntunnelEngine

/// Main-thread policy over cumulative pipeline counters; no clock or audio IO is hidden here.
struct TierRecovery {
    private let preferred: Tier
    private let tiers: [Tier]
    private(set) var current: Tier
    private var windowStart: TimeInterval
    private var windowHops: UInt64 = 0
    private var windowLate: UInt64 = 0
    private var lastHops: UInt64 = 0
    private var lastLate: UInt64 = 0
    private var cleanSince: TimeInterval
    private var cleanHops: UInt64 = 0

    init(preferred: Tier, tiers: [Tier], at time: TimeInterval) {
        self.preferred = preferred
        current = preferred
        self.tiers = (Set(tiers + [preferred])).filter {
            $0.sampleRate <= preferred.sampleRate && $0.lookAhead == preferred.lookAhead
        }.sorted {
            $0.sampleRate == $1.sampleRate
                ? $0.exitLayer < $1.exitLayer : $0.sampleRate < $1.sampleRate
        }
        windowStart = time
        cleanSince = time
    }

    var isReduced: Bool { current != preferred }

    mutating func restarted(at time: TimeInterval, hops: UInt64 = 0, late: UInt64 = 0) {
        cleanSince = time
        cleanHops = 0
        windowStart = time
        windowHops = hops
        windowLate = late
        lastHops = hops
        lastLate = late
    }

    mutating func update(hops: UInt64, late: UInt64, at time: TimeInterval, isRunning: Bool = true)
        -> Tier?
    {
        guard isRunning else {
            restarted(at: time, hops: hops, late: late)
            return nil
        }
        if hops < lastHops || late < lastLate { restarted(at: time) }
        guard hops > lastHops else { return nil }
        if late > lastLate {
            cleanSince = time
            cleanHops = 0
        } else {
            cleanHops += hops - lastHops
        }
        lastHops = hops
        lastLate = late
        if isReduced && time - cleanSince >= 60
            && Double(cleanHops) * Double(Tier.streamingHopMilliseconds) >= 60_000
        {
            current = preferred
            restarted(at: time)
            return current
        }
        guard time - windowStart >= 10 else { return nil }
        let count = hops - windowHops
        let misses = late - windowLate
        windowStart = time
        windowHops = hops
        windowLate = late
        guard count > 0, Double(misses) / Double(count) > 0.02,
            let lower = tiers.last(where: {
                $0.sampleRate < current.sampleRate && $0.exitLayer <= current.exitLayer
            })
        else { return nil }
        current = lower
        return current
    }
}
