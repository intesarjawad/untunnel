import json
import subprocess
from pathlib import Path

import pytest

from untunnel_tools.measure import teardown
from untunnel_tools.measure.teardown import ListedDevice


def profiler_output(*items: dict[str, object]) -> str:
    """Build the `system_profiler SPAudioDataType -json` shape around some items."""
    return json.dumps({"SPAudioDataType": [{"_items": list(items), "_name": "coreaudio_device"}]})


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


def ignore_result(
    _path: Path,
    _check: str,
    *,
    passed: bool,
    detail: str,
    stamp: object = None,
) -> None:
    """Stand in for the results log so a test never writes to it."""
    _ = passed, detail, stamp


def say_nothing(_message: str) -> None:
    """Stand in for a prompt the tester would answer."""


def answer_yes(_question: str) -> bool:
    """Stand in for a tester who confirms the tapped app is audible."""
    return True


def kill_nothing(_pid: int) -> None:
    """Stand in for the signal so a test never stops a process."""


def launch_nothing(_app: Path, _runner: teardown.CommandRunner = teardown.run_command) -> None:
    """Stand in for `open` so a test never starts an app."""


def process_is_back(
    _name: str,
    _plan: teardown.WaitPlan | None = None,
    _runner: teardown.CommandRunner = teardown.run_command,
) -> bool:
    """Stand in for the wait for the relaunched process."""
    return True


def tap_stays_listed(_read: object, _plan: object) -> tuple[str, ...]:
    """Stand in for a device list that never loses the tap."""
    return ("Untunnel Tap",)


def test_parse_listing_keeps_names_and_transports_even_without_a_sample_rate() -> None:
    """A leftover aggregate may report no rate and must still be seen."""
    devices = teardown.parse_listing(
        profiler_output(
            {"_name": "MacBook Pro Speakers", "coreaudio_device_transport": "built_in"},
            {"_name": "Untunnel Tap"},
        )
    )

    assert devices == (
        ListedDevice("MacBook Pro Speakers", "built_in"),
        ListedDevice("Untunnel Tap", ""),
    )


def test_parse_listing_rejects_a_report_without_devices() -> None:
    """An empty report fails instead of reading as a clean device list."""
    with pytest.raises(ValueError, match="no devices"):
        teardown.parse_listing(json.dumps({"SPAudioDataType": []}))


def test_find_strays_flags_the_tap_by_name_whatever_its_transport() -> None:
    """The tap's name alone is enough, as the doctor reports it."""
    strays = teardown.find_strays(
        [
            ListedDevice("Untunnel Tap", ""),
            ListedDevice("Untunnel Tap", "coreaudio_device_type_usb"),
        ]
    )

    assert strays == ("Untunnel Tap", "Untunnel Tap")


def test_find_strays_flags_an_untunnel_aggregate_but_not_the_microphone() -> None:
    """The virtual microphone is a device the app owns on purpose."""
    strays = teardown.find_strays(
        [
            ListedDevice("Untunnel Microphone", "coreaudio_device_type_virtual"),
            ListedDevice("Untunnel Aggregate", "coreaudio_device_type_aggregate"),
            ListedDevice("Studio Aggregate", "coreaudio_device_type_aggregate"),
        ]
    )

    assert strays == ("Untunnel Aggregate",)


def test_wait_for_clean_returns_once_the_tap_is_gone() -> None:
    """A device that disappears during the wait passes."""
    clock = FakeClock()
    plan = teardown.WaitPlan(timeout_seconds=5.0, clock=clock.read, sleep=clock.sleep)
    reads = iter([[ListedDevice("Untunnel Tap", "")], []])

    strays = teardown.wait_for_clean(lambda: next(reads), plan)

    assert strays == ()
    assert clock.now == pytest.approx(teardown.POLL_SECONDS)


def test_wait_for_clean_reports_what_is_still_listed_at_the_limit() -> None:
    """A device that never goes away ends the wait at the timeout."""
    clock = FakeClock()
    plan = teardown.WaitPlan(timeout_seconds=2.0, clock=clock.read, sleep=clock.sleep)

    strays = teardown.wait_for_clean(lambda: [ListedDevice("Untunnel Tap", "")], plan)

    assert strays == ("Untunnel Tap",)
    assert clock.now == pytest.approx(2.0)


def test_report_needs_all_three_conditions() -> None:
    """The relaunch, the empty list and the audible app each fail the check alone."""
    assert teardown.TeardownReport(relaunched=True, strays=(), plays_again=True).passed
    assert not teardown.TeardownReport(relaunched=False, strays=(), plays_again=True).passed
    assert not teardown.TeardownReport(
        relaunched=True, strays=("Untunnel Tap",), plays_again=True
    ).passed
    assert not teardown.TeardownReport(relaunched=True, strays=(), plays_again=False).passed


def test_read_listing_fails_when_the_profiler_does() -> None:
    """A failed profiler run is an error, not an empty list."""

    def failing(_arguments: list[str]) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(args=[], returncode=1, stdout="", stderr="")

    with pytest.raises(RuntimeError, match="system_profiler"):
        teardown.read_listing(failing)


def test_run_kills_the_named_process_and_reports_pass(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The process id is signalled, the app returns and the device list is clean."""
    killed: list[int] = []
    launched: list[Path] = []
    appended: list[bool] = []

    def append(
        _path: Path,
        _check: str,
        *,
        passed: bool,
        detail: str,
        stamp: object = None,
    ) -> None:
        _ = detail, stamp
        appended.append(passed)

    def launch(app: Path, _runner: teardown.CommandRunner = teardown.run_command) -> None:
        launched.append(app)

    def clean_listing() -> tuple[ListedDevice, ...]:
        return (ListedDevice("MacBook Pro Speakers", ""),)

    monkeypatch.setattr(teardown, "confirm", say_nothing)
    monkeypatch.setattr(teardown, "force_kill", killed.append)
    monkeypatch.setattr(teardown, "launch_app", launch)
    monkeypatch.setattr(teardown, "wait_for_process", process_is_back)
    monkeypatch.setattr(teardown, "read_listing", clean_listing)
    monkeypatch.setattr(teardown, "ask_yes_no", answer_yes)
    monkeypatch.setattr(teardown, "append_result", append)

    status = teardown.run(["--pid", "4321", "--app", "/Applications/Fixture.app"])

    assert status == 0
    assert killed == [4321]
    assert launched == [Path("/Applications/Fixture.app")]
    assert appended == [True]
    assert "PASS" in capsys.readouterr().out


def test_run_fails_while_the_tap_is_still_listed(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A tap left in the device list fails the check and is named in the message."""
    monkeypatch.setattr(teardown, "confirm", say_nothing)
    monkeypatch.setattr(teardown, "force_kill", kill_nothing)
    monkeypatch.setattr(teardown, "launch_app", launch_nothing)
    monkeypatch.setattr(teardown, "wait_for_process", process_is_back)
    monkeypatch.setattr(teardown, "wait_for_clean", tap_stays_listed)
    monkeypatch.setattr(teardown, "ask_yes_no", answer_yes)
    monkeypatch.setattr(teardown, "append_result", ignore_result)

    status = teardown.run(["--pid", "4321"])

    assert status == 1
    assert "Untunnel Tap" in capsys.readouterr().err
