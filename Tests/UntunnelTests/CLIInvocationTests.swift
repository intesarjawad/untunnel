import Darwin
import Foundation
import Testing

@testable import Untunnel

@Test
func noArgumentsOpensTheApp() {
    #expect(UntunnelMain.invocation(for: []) == .app)
}

@Test
func setupLaunchFlagOpensTheApp() {
    #expect(UntunnelMain.invocation(for: ["--hear-yourself"]) == .app)
    #expect(HearYourselfLaunch.requested(arguments: ["untunnel", "--hear-yourself"]))
}

@Test
func knownSubcommandsKeepTheirArguments() {
    #expect(UntunnelMain.invocation(for: ["bench", "--all"]) == .bench(["--all"]))
    #expect(
        UntunnelMain.invocation(for: ["doctor", "--devices", "--json"])
            == .doctor(["--devices", "--json"])
    )
    #expect(
        UntunnelMain.invocation(for: ["download", "--offline-model"])
            == .download(["--offline-model"])
    )
    #expect(
        UntunnelMain.invocation(for: ["enhance", "in.wav", "out.wav", "--model", "offline"])
            == .enhance(["in.wav", "out.wav", "--model", "offline"])
    )
    #expect(
        UntunnelMain.invocation(for: ["snapshot", "--window", "hear", "--state", "idle"])
            == .snapshot(["--window", "hear", "--state", "idle"])
    )
    #expect(
        UntunnelMain.invocation(for: ["setup", "--yes", "--driver"])
            == .setup(["--yes", "--driver"])
    )
    #expect(
        UntunnelMain.invocation(for: ["uninstall", "--dry-run"])
            == .uninstall(["--dry-run"])
    )
    #expect(UntunnelMain.invocation(for: ["quit"]) == .quit(force: false))
    #expect(UntunnelMain.invocation(for: ["quit", "--force"]) == .quit(force: true))
}

@Test
func unknownCommandsAskForUsage() {
    #expect(
        UntunnelMain.invocation(for: ["restore"]) == .usage(reason: "unknown command 'restore'")
    )
    #expect(
        UntunnelMain.invocation(for: ["quit", "now"]) == .usage(reason: "quit takes only --force"))
}

private final class FakeQuitSystem: QuitSystem {
    var pids: [pid_t] = []
    var clients: [String] = []
    var stopsOnTerminate = true
    private(set) var terminated: [pid_t] = []

    func runningPIDs() -> [pid_t] {
        pids
    }

    func inputClientNames() -> [String] {
        clients
    }

    func terminate(_ pid: pid_t) {
        terminated.append(pid)
    }

    func isRunning(_ pid: pid_t) -> Bool {
        !(stopsOnTerminate && terminated.contains(pid))
    }

    func sleep(seconds: TimeInterval) {}
}

@Test
func quitReportsAnAppThatIsNotRunning() {
    let result = Quit.perform(force: false, system: FakeQuitSystem())

    #expect(result.status == 0)
    #expect(result.output.text == "Untunnel is not running.\n")
}

@Test
func quitStopsTheAppWhenNobodyUsesTheMicrophone() {
    let system = FakeQuitSystem()
    system.pids = [4_001]

    let result = Quit.perform(force: false, system: system)

    #expect(result.status == 0)
    #expect(system.terminated == [4_001])
}

@Test
func quitRefusesWhileAnApplicationRecordsFromTheMicrophone() {
    let system = FakeQuitSystem()
    system.pids = [4_001]
    system.clients = ["zoom.us"]

    let result = Quit.perform(force: false, system: system)

    #expect(result.status == 1)
    #expect(system.terminated.isEmpty)
    #expect(
        result.output.errorText
            == "Untunnel Microphone is in use by zoom.us.\n"
            + "Fix: stop recording in that app, or run `untunnel quit --force`.\n"
    )
}

@Test
func forcedQuitStopsTheAppDespiteARecordingClient() {
    let system = FakeQuitSystem()
    system.pids = [4_001, 4_002]
    system.clients = ["zoom.us"]

    let result = Quit.perform(force: true, system: system)

    #expect(result.status == 0)
    #expect(system.terminated == [4_001, 4_002])
}

@Test
func quitReportsAProcessThatDidNotStop() {
    let system = FakeQuitSystem()
    system.pids = [4_001]
    system.stopsOnTerminate = false

    let result = Quit.perform(force: false, system: system, timeout: 0)

    #expect(result.status == 1)
    #expect(
        result.output.errorText == "Untunnel did not stop (pids 4001); retry with --force\n"
    )
}

@Test func helpIsNotAnUnknownCommand() {
    #expect(UntunnelMain.invocation(for: ["--help"]) == .help)
}
