from datetime import UTC, datetime
from pathlib import Path

import pytest

from untunnel_tools.measure import autoroute

AUDIO_REPORT = """
{
  "SPAudioDataType": [
    {
      "_name": "coreaudio_device",
      "_items": [
        {
          "_name": "MacBook Pro Microphone",
          "coreaudio_device_input": 1,
          "coreaudio_device_srate": 48000,
          "coreaudio_device_transport": "coreaudio_device_type_builtin",
          "coreaudio_default_audio_input_device": "spaudio_yes"
        },
        {
          "_name": "AirPods Pro",
          "coreaudio_device_input": 1,
          "coreaudio_device_srate": 16000,
          "coreaudio_device_transport": "coreaudio_device_type_bluetooth"
        }
      ]
    }
  ]
}
"""


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


def test_parse_default_input_names_the_flagged_device() -> None:
    """Only the item macOS flags as the default input counts, not the headset."""
    assert autoroute.parse_default_input(AUDIO_REPORT) == "MacBook Pro Microphone"


def test_parse_default_input_returns_none_when_nothing_is_flagged() -> None:
    """A report without a default input is not a tool failure."""
    output = '{"SPAudioDataType": [{"_name": "section", "_items": []}]}'

    assert autoroute.parse_default_input(output) is None


def test_parse_default_input_rejects_a_missing_section() -> None:
    """Wrong JSON shapes fail at the report boundary."""
    with pytest.raises(ValueError, match="no devices"):
        autoroute.parse_default_input('{"SPAudioDataType": []}')


def test_only_the_app_names_count_as_the_virtual_microphone() -> None:
    """Both product names count; a real microphone does not."""
    assert autoroute.is_virtual_mic("Untunnel Microphone")
    assert autoroute.is_virtual_mic("Untunnel Microphone")
    assert not autoroute.is_virtual_mic("MacBook Pro Microphone")


def test_wait_for_virtual_reports_the_switch_time() -> None:
    """The second reading is the app's microphone, half a second after the first."""
    clock = FakeClock()
    readings = iter(["MacBook Pro Microphone", "Untunnel Microphone"])

    found = autoroute.wait_for_virtual(
        lambda: next(readings),
        autoroute.WaitPlan(clock=clock.read, sleep=clock.sleep),
    )

    assert found == ("Untunnel Microphone", pytest.approx(0.5))


def test_wait_for_virtual_gives_up_at_the_limit() -> None:
    """An app that never engages ends at the timeout instead of hanging."""
    clock = FakeClock()

    found = autoroute.wait_for_virtual(
        lambda: "MacBook Pro Microphone",
        autoroute.WaitPlan(timeout_seconds=2.0, clock=clock.read, sleep=clock.sleep),
    )

    assert found is None
    assert clock.now == pytest.approx(2.0)


def test_verify_passes_an_automatic_switch_and_a_restore() -> None:
    """The engaged default is the app's microphone and the old device returns."""
    report = autoroute.verify(
        "MacBook Pro Microphone",
        ("Untunnel Microphone", 1.5),
        ("MacBook Pro Microphone", 4.0),
    )

    assert report.passed
    assert report.engaged_seconds == pytest.approx(1.5)


def test_verify_fails_when_the_default_never_returns() -> None:
    """Staying on the virtual microphone after quit is a failure."""
    report = autoroute.verify(
        "MacBook Pro Microphone",
        ("Untunnel Microphone", 1.5),
        None,
    )

    assert not report.passed


def test_append_result_adds_one_row(tmp_path: Path) -> None:
    """The measurement log receives a stamped row for each check."""
    path = tmp_path / "docs" / "results.md"
    stamp = datetime(2026, 11, 6, 18, 30, tzinfo=UTC)

    autoroute.append_result(path, "auto-route", passed=True, detail="engaged", stamp=stamp)

    assert path.read_text(encoding="utf-8").endswith(
        "| 2026-11-06T18:30:00+00:00 | auto-route | PASS | engaged |\n"
    )


def test_run_prints_pass_after_the_switch_and_the_restore(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The command follows the tester through the connect and the quit."""
    readings = iter(
        [
            "MacBook Pro Microphone",
            "MacBook Pro Microphone",
            "Untunnel Microphone",
            "Untunnel Microphone",
            "MacBook Pro Microphone",
        ]
    )
    appended: list[bool] = []

    def append(
        _path: Path,
        _check: str,
        *,
        passed: bool,
        detail: str,
        stamp: datetime | None = None,
    ) -> None:
        _ = stamp, detail
        appended.append(passed)

    held: list[float] = []

    monkeypatch.setattr(autoroute, "read_default_input", lambda: next(readings))
    monkeypatch.setattr(autoroute, "append_result", append)
    monkeypatch.setattr(autoroute, "open_default_reader", held.append)

    status = autoroute.run(["--timeout", "5"])

    assert status == 0
    assert appended == [True]
    assert held == [3.0]
    assert "PASS" in capsys.readouterr().out


def test_run_refuses_to_start_while_the_virtual_microphone_is_the_default(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A check that starts already engaged cannot observe the switch."""
    monkeypatch.setattr(autoroute, "read_default_input", lambda: "Untunnel Microphone")

    status = autoroute.run([])

    assert status == 2
    assert "quit Untunnel first" in capsys.readouterr().err


def _discard_result(
    _path: Path,
    _check: str,
    *,
    passed: bool,
    detail: str,
    stamp: datetime | None = None,
) -> None:
    _ = passed, detail, stamp


def test_run_skips_the_reader_when_the_app_never_engages(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A reader on the wrong default would prove nothing about the app."""
    held: list[float] = []

    monkeypatch.setattr(autoroute, "read_default_input", lambda: "MacBook Pro Microphone")
    monkeypatch.setattr(autoroute, "append_result", _discard_result)
    monkeypatch.setattr(autoroute, "open_default_reader", held.append)

    status = autoroute.run(["--timeout", "0.01"])

    assert status == 1
    assert held == []


def test_run_reports_a_reader_that_cannot_open(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A missing sounddevice install is a setup error, not a failed check."""
    readings = iter(["MacBook Pro Microphone", "MacBook Pro Microphone", "Untunnel Microphone"])

    def refuse(_seconds: float) -> None:
        message = "sounddevice is not installed"
        raise RuntimeError(message)

    monkeypatch.setattr(autoroute, "read_default_input", lambda: next(readings))
    monkeypatch.setattr(autoroute, "open_default_reader", refuse)

    status = autoroute.run(["--timeout", "5"])

    assert status == 2
    assert "sounddevice is not installed" in capsys.readouterr().err
