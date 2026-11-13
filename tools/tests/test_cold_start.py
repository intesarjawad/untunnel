import json
import shlex
import subprocess
from datetime import datetime
from pathlib import Path

import pytest

from untunnel_tools.measure import cold_start
from untunnel_tools.measure.autoroute import WaitPlan

TIMINGS = json.dumps(
    {
        "schema_version": 1,
        "steps": [
            {"step": 2, "name": "Install the audio plug-in", "seconds": 9.5},
            {"step": 1, "name": "Check this Mac", "seconds": 0.25},
        ],
    }
)

LOG_OUTPUT = json.dumps(
    [
        {"eventMessage": "input_device_lost", "timestamp": "2026-11-09 10:00:01.000000+0000"},
        {"eventMessage": "first_ab_played", "timestamp": "2026-11-09 10:00:30.500000+0000"},
        {"eventMessage": "first_ab_played", "timestamp": "2026-11-09 10:00:20.000000+0000"},
    ]
)


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


def plan(clock: FakeClock, timeout_seconds: float = 10.0) -> WaitPlan:
    """Return a wait plan on the fake clock."""
    return WaitPlan(
        timeout_seconds=timeout_seconds,
        poll_seconds=1.0,
        clock=clock.read,
        sleep=clock.sleep,
    )


def test_curl_path_runs_the_readme_line_with_a_timings_file() -> None:
    """The measured line is the published one; only the timings flag is added."""
    commands = cold_start.install_commands("curl", Path("/work dir/timings.json"))

    line = (
        f"curl -fsSL {cold_start.INSTALL_URL} | sh -s -- --yes "
        "--timings-json '/work dir/timings.json'"
    )
    assert commands == (["/bin/sh", "-c", line],)


def test_brew_path_installs_the_formula_then_runs_setup() -> None:
    """The formula never runs setup itself, so the measurement runs it as the caveat says."""
    commands = cold_start.install_commands("brew", Path("/work/timings.json"))

    assert commands == (
        ["brew", "install", "intesarjawad/tap/untunnel"],
        ["untunnel", "setup", "--yes", "--timings-json", "/work/timings.json"],
    )


def test_an_unknown_path_is_rejected() -> None:
    """Only the two published install lines are measured."""
    with pytest.raises(ValueError, match="unknown install path"):
        cold_start.install_commands("pkg", Path("/work/timings.json"))


def test_read_timings_orders_the_steps() -> None:
    """Steps come back in setup's order, whatever the file order."""
    steps = cold_start.read_timings(TIMINGS)

    assert [step.step for step in steps] == [1, 2]
    assert steps[1] == cold_start.StepTiming(2, "Install the audio plug-in", 9.5)


@pytest.mark.parametrize(
    ("document", "message"),
    [
        ("[]", "not a JSON object"),
        ('{"schema_version": 2, "steps": []}', "schema version 2"),
        ('{"schema_version": 1, "steps": []}', "no steps"),
        ('{"schema_version": 1, "steps": [{"step": 1, "name": "x"}]}', "incomplete"),
        (
            '{"schema_version": 1, "steps": [{"step": true, "name": "x", "seconds": 1}]}',
            "incomplete",
        ),
    ],
    ids=["not-an-object", "newer-schema", "no-steps", "missing-seconds", "boolean-step"],
)
def test_read_timings_rejects_malformed_documents(document: str, message: str) -> None:
    """A timings file setup did not write fails at the boundary, with the reason."""
    with pytest.raises((TypeError, ValueError), match=message):
        cold_start.read_timings(document)


def test_parse_first_sound_keeps_only_that_event_oldest_first() -> None:
    """Other app events in the same subsystem are ignored."""
    stamps = cold_start.parse_first_sound(LOG_OUTPUT)

    first = datetime.fromisoformat("2026-11-09T10:00:20+00:00").timestamp()
    assert stamps == (first, first + 10.5)


def test_parse_first_sound_rejects_an_entry_without_a_timestamp() -> None:
    """A malformed log entry is a tool failure, not a missing event."""
    with pytest.raises(TypeError, match="no timestamp"):
        cold_start.parse_first_sound('[{"eventMessage": "first_ab_played"}]')


def test_read_first_sound_drops_events_before_the_install_started() -> None:
    """An event from an earlier run in the log window does not count."""
    first = datetime.fromisoformat("2026-11-09T10:00:20+00:00").timestamp()

    def runner(arguments: list[str]) -> subprocess.CompletedProcess[str]:
        assert "eventMessage" not in arguments[-1]
        assert 'subsystem == "com.intesarjawad.untunnel"' in arguments[-1]
        return subprocess.CompletedProcess(arguments, 0, stdout=LOG_OUTPUT, stderr="")

    assert cold_start.read_first_sound(first + 1, runner) == (first + 10.5,)


def test_read_first_sound_reports_a_failing_log_command() -> None:
    """`log show` failing is not the same as the event not happening yet."""

    def runner(arguments: list[str]) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(arguments, 1, stdout="", stderr="denied")

    with pytest.raises(RuntimeError, match="status 1"):
        cold_start.read_first_sound(0.0, runner)


def test_wait_for_first_sound_measures_from_the_install_start() -> None:
    """The total runs from the install line to the logged event, not to when it was read."""
    clock = FakeClock()
    readings = iter([(), (), (1_000.0 + 95.0,)])

    total = cold_start.wait_for_first_sound(lambda: next(readings), 1_000.0, plan(clock))

    assert total == 95.0
    assert clock.now == 2.0


def test_wait_for_first_sound_gives_up_at_the_timeout() -> None:
    """A clip that never plays ends the wait instead of hanging the tester."""
    clock = FakeClock()

    total = cold_start.wait_for_first_sound(lambda: (), 0.0, plan(clock, timeout_seconds=3.0))

    assert total is None
    assert clock.now == 3.0


@pytest.mark.parametrize(
    ("total", "passed"),
    [(120.0, True), (120.1, False), (None, False)],
    ids=["at-budget", "over-budget", "never-played"],
)
def test_the_budget_is_inclusive(total: float | None, passed: bool) -> None:  # noqa: FBT001
    """Exactly the budget passes; over it, or no clip at all, fails."""
    steps = cold_start.read_timings(TIMINGS)

    assert cold_start.ColdStartReport("curl", steps, total).passed is passed


def test_a_report_without_steps_fails() -> None:
    """Without setup's timings the slow step cannot be found, so the run does not count."""
    assert not cold_start.ColdStartReport("curl", (), 30.0).passed


def write_timings(command: list[str]) -> int:
    """Stand in for an install command: setup writes the timings file it was pointed at."""
    words = [word for part in command for word in shlex.split(part)]
    if "--timings-json" in words:
        Path(words[words.index("--timings-json") + 1]).write_text(TIMINGS, encoding="utf-8")
    return 0


def _discard_result(
    _path: Path,
    _check: str,
    *,
    passed: bool,
    detail: str,
    stamp: datetime | None = None,
) -> None:
    _ = passed, detail, stamp


def test_run_prints_each_step_and_pass(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A run within budget prints the steps, the total and PASS, and records one row."""
    rows: list[tuple[str, bool]] = []

    def record(
        _path: Path,
        check: str,
        *,
        passed: bool,
        detail: str,
        stamp: datetime | None = None,
    ) -> None:
        _ = detail, stamp
        rows.append((check, passed))

    def first_sound(since: float) -> tuple[float, ...]:
        return (since + 41.0,)

    monkeypatch.setattr(cold_start, "run_visible", write_timings)
    monkeypatch.setattr(cold_start, "read_first_sound", first_sound)
    monkeypatch.setattr(cold_start, "append_result", record)

    status = cold_start.run(["--path", "curl"])

    output = capsys.readouterr().out
    assert status == 0
    assert "[1] Check this Mac: 0.25 s" in output
    assert "[2] Install the audio plug-in: 9.50 s" in output
    assert "total: 41.0 s (budget 120 s)" in output
    assert output.rstrip().endswith("PASS")
    assert rows == [("cold start (curl)", True)]


def test_run_stops_when_the_install_line_fails(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A failed install is reported with its status and records nothing."""
    rows: list[bool] = []

    def record(
        _path: Path,
        _check: str,
        *,
        passed: bool,
        detail: str,
        stamp: datetime | None = None,
    ) -> None:
        _ = detail, stamp
        rows.append(passed)

    def failing_install(_command: list[str]) -> int:
        return 7

    monkeypatch.setattr(cold_start, "run_visible", failing_install)
    monkeypatch.setattr(cold_start, "append_result", record)

    status = cold_start.run(["--path", "brew"])

    assert status == 2
    assert "exited with status 7" in capsys.readouterr().err
    assert rows == []


def test_run_fails_when_no_clip_plays(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Setup finishing is not enough; the first restored clip must play."""

    def no_sound(_since: float) -> tuple[float, ...]:
        return ()

    monkeypatch.setattr(cold_start, "run_visible", write_timings)
    monkeypatch.setattr(cold_start, "read_first_sound", no_sound)
    monkeypatch.setattr(cold_start, "append_result", _discard_result)

    status = cold_start.run(["--path", "brew", "--timeout", "0.01"])

    assert status == 1
    assert "never logged first_ab_played" in capsys.readouterr().err
