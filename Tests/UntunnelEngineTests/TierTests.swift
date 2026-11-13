import Testing
import UntunnelEngine

@Test
func tierPreservesConfiguration() {
    let tier = Tier(sampleRate: 32_000, exitLayer: 7, lookAhead: 1)

    #expect(tier.sampleRate == 32_000)
    #expect(tier.exitLayer == 7)
    #expect(tier.lookAhead == 1)
    #expect(tier.hopMilliseconds == 20)
}

@Test
func tierIdentityIncludesEveryParameter() {
    let tier = Tier(sampleRate: 32_000, exitLayer: 7, lookAhead: 1)
    let configurations: Set = [
        tier,
        Tier(sampleRate: 32_000, exitLayer: 7, lookAhead: 1),
        Tier(sampleRate: 24_000, exitLayer: 7, lookAhead: 1),
        Tier(sampleRate: 32_000, exitLayer: 6, lookAhead: 1),
        Tier(sampleRate: 32_000, exitLayer: 7, lookAhead: 0),
        Tier(sampleRate: 32_000, exitLayer: 7, lookAhead: 1, hopMilliseconds: 5),
    ]

    #expect(configurations.count == 5)
}
