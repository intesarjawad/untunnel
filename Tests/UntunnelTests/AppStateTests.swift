import Testing
import UntunnelEngine

@testable import Untunnel

private let fineTier = Tier(sampleRate: 48_000, exitLayer: 7, lookAhead: 1)

@Test
func statusTextCoversEveryEngineStatus() {
    #expect(
        AppState.statusText(engine: .loading, incoming: .off)
            == "Starting the restore engine"
    )
    #expect(
        AppState.statusText(engine: .ready(fineTier), incoming: .off)
            == "Restore engine ready at 48 kHz"
    )
    #expect(
        AppState.statusText(engine: .failed("weights missing"), incoming: .off)
            == "Restore engine failed: weights missing"
    )
}

@Test
func statusTextLeadsWithTheIncomingPath() {
    #expect(
        AppState.statusText(
            engine: .ready(fineTier),
            incoming: .restoring(pid: 42, name: "QuickTime Player")
        ) == "Restoring incoming audio for QuickTime Player (process 42)"
    )
    #expect(
        AppState.statusText(engine: .loading, incoming: .blockedSpeakers)
            == "Microphone blocked while the speakers are in use"
    )
    #expect(
        AppState.statusText(engine: .loading, incoming: .permissionDenied)
            == "Microphone permission denied"
    )
}

@Test
func micPathTextCoversEveryMicPath() {
    #expect(AppState.micPathText(.off) == "Microphone off")
    #expect(AppState.micPathText(.standby) == "Microphone on standby")
    #expect(
        AppState.micPathText(.restoring(Tier(sampleRate: 24_000, exitLayer: 5, lookAhead: 1)))
            == "Restoring at 24 kHz"
    )
    #expect(AppState.micPathText(.waiting(deviceName: "AirPods Pro")) == "Waiting for AirPods Pro")
    #expect(AppState.micPathText(.bypass) == "Microphone bypassed")
}

@Test
func micPathTextKeepsARateWithoutAWholeKilohertzInHertz() {
    #expect(
        AppState.micPathText(.restoring(Tier(sampleRate: 22_050, exitLayer: 5, lookAhead: 1)))
            == "Restoring at 22050 Hz"
    )
}

@Test
func sixteenKilohertzStatusDisclosesItsLimitedBand() {
    let text = AppState.statusText(engine: .ready(BenchTiers.all[0]), incoming: .off)
    #expect(text.contains("below 8 kHz"))
}
