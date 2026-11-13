from pathlib import Path

import pytest

from untunnel_tools.measure import sleep

PMSET_OUTPUT = """
Assertion status system-wide:
   BackgroundTask                 0
   ApplePushServiceTask           0
   UserIsActive                   1
   PreventUserIdleDisplaySleep    0
   PreventSystemSleep             0
   ExternalMedia                  0
   PreventUserIdleSystemSleep     1
   NetworkClientActive            0
Listed by owning process:
   pid 100(powerd): [0x0000000100000001] 00:00:00 PreventUserIdleSystemSleep named: "com.example"
"""


def test_parse_reads_the_system_wide_count_not_a_process_line() -> None:
    """The summary line is the value both readings compare."""
    assert sleep.parse_prevent_idle_count(PMSET_OUTPUT) == 1


def test_parse_rejects_output_without_the_assertion() -> None:
    """A missing line fails instead of comparing two unrelated numbers."""
    with pytest.raises(ValueError, match="PreventUserIdleSystemSleep"):
        sleep.parse_prevent_idle_count("Assertion status system-wide:\n")


def test_verify_passes_when_the_count_does_not_change() -> None:
    """The app added no idle-sleep assertion in either mode."""
    assert sleep.verify("standby", 1, 1).passed
    assert sleep.verify("quit", 0, 0).passed


def test_verify_fails_when_the_count_changes() -> None:
    """One extra assertion is exactly what the check looks for."""
    report = sleep.verify("standby", 1, 2)

    assert not report.passed
    assert report.baseline == 1
    assert report.after == 2


def test_verify_rejects_an_unknown_mode() -> None:
    """The two acceptance states are the only ones the instructions cover."""
    with pytest.raises(ValueError, match="sleep mode"):
        sleep.verify("awake", 1, 1)


def test_run_prints_pass_for_an_unchanged_count(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Both readings are one, so the standby state added nothing."""
    counts = iter([1, 1])
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

    def no_wait(_seconds: float) -> None:
        return None

    monkeypatch.setattr(sleep, "read_prevent_idle_count", lambda: next(counts))
    monkeypatch.setattr(sleep, "wait", no_wait)
    monkeypatch.setattr(sleep, "append_result", append)

    status = sleep.run(["--mode", "standby"])

    assert status == 0
    assert appended == [True]
    assert "PASS" in capsys.readouterr().out


def test_run_fails_a_changed_count(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A second assertion after opening the app fails the standby comparison."""
    counts = iter([1, 2])

    def no_wait(_seconds: float) -> None:
        return None

    def ignore(
        _path: Path,
        _check: str,
        *,
        passed: bool,
        detail: str,
        stamp: object = None,
    ) -> None:
        _ = passed, detail, stamp

    monkeypatch.setattr(sleep, "read_prevent_idle_count", lambda: next(counts))
    monkeypatch.setattr(sleep, "wait", no_wait)
    monkeypatch.setattr(sleep, "append_result", ignore)

    status = sleep.run(["--mode", "standby"])

    assert status == 1
    assert "SLEEP_HELD" in capsys.readouterr().err
