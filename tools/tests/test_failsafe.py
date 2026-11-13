import subprocess
from pathlib import Path

import pytest

from untunnel_tools.measure import failsafe


def report_output(status: int = 0) -> subprocess.CompletedProcess[str]:
    """Build the result shape a command runner returns."""
    return subprocess.CompletedProcess(args=[], returncode=status, stdout="", stderr="")


class FakeClock:
    """Advance only when the code under test sleeps."""

    def __init__(self) -> None:
        self.now = 0.0

    def read(self) -> float:
        """Return the current fake time."""
        return self.now

    def sleep(self, seconds: float) -> None:
        """Advance the fake time by the requested pause."""
        self.now += seconds


def test_kill_case_passes_with_a_real_microphone_after_the_restart() -> None:
    """The app came back and no longer owns the default input."""
    report = failsafe.verify(
        "kill9",
        failsafe.Observation(relaunched=True, default_input="MacBook Pro Microphone"),
    )

    assert report.passed


def test_kill_case_fails_while_the_virtual_microphone_stays_default() -> None:
    """A dead app must not leave its device as the system default."""
    report = failsafe.verify(
        "kill9",
        failsafe.Observation(relaunched=True, default_input="Untunnel Microphone"),
    )

    assert not report.passed


def test_hang_case_needs_the_app_to_still_be_running() -> None:
    """The stopped process is still present while its watchdog falls back."""
    assert failsafe.verify(
        "hang-waiting",
        failsafe.Observation(relaunched=True, default_input="MacBook Pro Microphone"),
    ).passed
    assert not failsafe.verify(
        "hang-standby",
        failsafe.Observation(relaunched=False, default_input="MacBook Pro Microphone"),
    ).passed


def test_permission_case_passes_inside_five_seconds_with_the_line() -> None:
    """The prompt, Deny, a real default and the menu line all count."""
    report = failsafe.verify(
        "no-permission",
        failsafe.Observation(
            relaunched=True,
            default_input="MacBook Pro Microphone",
            prompt_seconds=4.9,
            permission_line=True,
        ),
    )

    assert report.passed


def test_permission_case_fails_a_late_prompt_or_a_missing_line() -> None:
    """Either half of the permission acceptance fails the case."""
    late = failsafe.verify(
        "no-permission",
        failsafe.Observation(
            relaunched=True,
            default_input="MacBook Pro Microphone",
            prompt_seconds=5.1,
            permission_line=True,
        ),
    )
    silent = failsafe.verify(
        "no-permission",
        failsafe.Observation(
            relaunched=True,
            default_input="MacBook Pro Microphone",
            prompt_seconds=1.0,
            permission_line=False,
        ),
    )

    assert not late.passed
    assert not silent.passed


def test_verify_rejects_an_unknown_case() -> None:
    """Only the four documented cases have an acceptance rule."""
    with pytest.raises(ValueError, match="failsafe case"):
        failsafe.verify("sleep", failsafe.Observation(relaunched=True, default_input="mic"))


def test_process_running_uses_the_exact_name() -> None:
    """A pid line means the process exists; an empty answer means it does not."""
    assert failsafe.process_running(
        "Untunnel",
        lambda _arguments: subprocess.CompletedProcess(
            args=[], returncode=0, stdout="123\n", stderr=""
        ),
    )
    assert not failsafe.process_running(
        "Untunnel",
        lambda _arguments: report_output(1),
    )


def test_wait_for_process_gives_up_at_the_limit() -> None:
    """A relaunch that never happens ends at the timeout."""
    clock = FakeClock()
    plan = failsafe.WaitPlan(
        timeout_seconds=2.0,
        clock=clock.read,
        sleep=clock.sleep,
    )

    found = failsafe.wait_for_process(
        "Untunnel",
        plan,
        lambda _arguments: report_output(1),
    )

    assert not found
    assert clock.now == pytest.approx(2.0)


def test_reset_permission_names_the_app_bundle() -> None:
    """The reset touches only the app's own grant."""
    seen: list[list[str]] = []

    def runner(arguments: list[str]) -> subprocess.CompletedProcess[str]:
        seen.append(arguments)
        return report_output()

    failsafe.reset_permission(runner)

    assert seen == [[failsafe.TCCUTIL, "reset", "Microphone", failsafe.BUNDLE_ID]]


def test_run_kill_case_reports_pass(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A process id is signalled, the restart is observed and the default is real."""
    killed: list[int] = []
    appended: list[bool] = []

    def append(
        _path: Path,
        _check: str,
        *,
        passed: bool,
        detail: str,
        stamp: object = None,
    ) -> None:
        _ = stamp, detail
        appended.append(passed)

    def relaunched(
        _name: str,
        _plan: failsafe.WaitPlan | None = None,
        _runner: failsafe.CommandRunner | None = None,
    ) -> bool:
        return True

    monkeypatch.setattr(failsafe, "force_kill", killed.append)
    monkeypatch.setattr(failsafe, "wait_for_process", relaunched)
    monkeypatch.setattr(failsafe, "read_default_input", lambda: "MacBook Pro Microphone")
    monkeypatch.setattr(failsafe, "append_result", append)

    status = failsafe.run(["--kill", "--pid", "4321"])

    assert status == 0
    assert killed == [4321]
    assert appended == [True]
    assert "PASS" in capsys.readouterr().out


def test_permission_case_times_the_prompt_apart_from_the_owner_clicking(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Only the wait until the prompt shows counts against the five seconds."""
    clock = FakeClock()
    asked: list[str] = []
    waits = iter([3.2, 40.0])

    def confirm(message: str) -> None:
        asked.append(message)
        clock.now += next(waits)

    def launch(_app: Path, _runner: failsafe.CommandRunner = failsafe.run_command) -> None:
        return None

    def reset(_runner: failsafe.CommandRunner = failsafe.run_command) -> None:
        return None

    def answer(_question: str) -> bool:
        return True

    def running(_name: str, _runner: failsafe.CommandRunner = failsafe.run_command) -> bool:
        return True

    monkeypatch.setattr(failsafe, "reset_permission", reset)
    monkeypatch.setattr(failsafe, "launch_app", launch)
    monkeypatch.setattr(failsafe, "confirm", confirm)
    monkeypatch.setattr(failsafe, "read_default_input", lambda: "MacBook Pro Microphone")
    monkeypatch.setattr(failsafe, "ask_yes_no", answer)
    monkeypatch.setattr(failsafe, "process_running", running)

    report = failsafe.permission_case(Path("Untunnel.app"), clock.read)

    assert report.observation.prompt_seconds == pytest.approx(3.2)
    assert report.passed
    assert asked[0].startswith("Press Return the moment")
    assert asked[1].startswith("Click Don't Allow")


def test_hang_case_tells_the_owner_how_to_set_up_waiting(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The waiting case needs the headset in its case before the process stops."""
    events: list[str] = []

    def confirm(message: str) -> None:
        events.append(message)

    def pause(pid: int) -> None:
        events.append(f"stop {pid}")

    def resume(pid: int) -> None:
        events.append(f"resume {pid}")

    def running(_name: str, _runner: failsafe.CommandRunner = failsafe.run_command) -> bool:
        return True

    monkeypatch.setattr(failsafe, "HANG_SECONDS", 0.0)
    monkeypatch.setattr(failsafe, "confirm", confirm)
    monkeypatch.setattr(failsafe, "pause_process", pause)
    monkeypatch.setattr(failsafe, "resume_process", resume)
    monkeypatch.setattr(failsafe, "process_running", running)
    monkeypatch.setattr(failsafe, "read_default_input", lambda: "MacBook Pro Microphone")

    report = failsafe.hang_case(77, "Untunnel", "hang-waiting")

    assert report.passed
    assert "in its case" in events[0]
    assert events[1:] == ["stop 77", "resume 77"]
