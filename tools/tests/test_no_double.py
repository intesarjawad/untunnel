from datetime import datetime
from pathlib import Path

import numpy as np
import pytest
import soundfile

from untunnel_tools.measure import FloatArray, no_double


def fixture() -> FloatArray:
    """Return the narrowband program the tester plays."""
    return no_double.narrowband_program()


def recording_with(*copies: tuple[float, float]) -> FloatArray:
    """Build a recording holding the fixture at each offset in seconds and gain."""
    program = fixture()
    length = round(no_double.FIXTURE_RATE * no_double.FIXTURE_SECONDS) + max(
        (round(offset * no_double.FIXTURE_RATE) for offset, _ in copies), default=0
    )
    recording = np.zeros(length, dtype=np.float64)
    for offset, gain in copies:
        start = round(offset * no_double.FIXTURE_RATE)
        recording[start : start + len(program)] += gain * program
    return recording


def write_recording(path: Path, samples: FloatArray) -> None:
    """Write a fixture as the float WAV a recording tool would produce."""
    soundfile.write(str(path), samples, no_double.FIXTURE_RATE, subtype="FLOAT")


def test_the_fixture_is_narrowband_and_fits_the_sample_range() -> None:
    """The program keeps the band a call keeps and never clips."""
    program = fixture()

    assert len(program) == 48_000 * 3
    assert np.max(np.abs(program)) == pytest.approx(0.5)
    spectrum = np.abs(np.fft.rfft(program))
    frequencies = np.fft.rfftfreq(len(program), 1 / no_double.FIXTURE_RATE)
    above = float(np.sum(spectrum[frequencies > no_double.NARROWBAND_HIGH_HZ]))
    assert above < 1e-6 * float(np.sum(spectrum))


def test_one_copy_is_one_peak() -> None:
    """A call heard through the tap alone leaves a single copy."""
    report = no_double.find_copies(fixture(), recording_with((0.5, 1.0)), no_double.FIXTURE_RATE)

    assert report.passes
    assert len(report.copies) == 1
    assert report.copies[0].lag_seconds == pytest.approx(0.5, abs=1 / no_double.FIXTURE_RATE)
    assert report.copies[0].relative_db == pytest.approx(0.0, abs=0.1)


def test_two_copies_fail() -> None:
    """The app playing its own copy is the double the check rejects."""
    recording = recording_with((0.0, 1.0), (1.0, 1.0))

    report = no_double.find_copies(fixture(), recording, no_double.FIXTURE_RATE)

    assert not report.passes
    assert len(report.copies) == 2
    assert report.copies[0].relative_db >= report.copies[1].relative_db


def test_a_copy_below_the_audible_level_is_ignored() -> None:
    """A leak 30 dB down is not a second playback a person hears."""
    recording = recording_with((0.0, 1.0), (1.0, 0.031))

    report = no_double.find_copies(fixture(), recording, no_double.FIXTURE_RATE)

    assert report.passes
    assert len(report.copies) == 1


def test_silence_holds_no_copy() -> None:
    """A muted tap is a failed measurement, not a pass."""
    recording = np.zeros(no_double.FIXTURE_RATE * 2, dtype=np.float64)

    report = no_double.find_copies(fixture(), recording, no_double.FIXTURE_RATE)

    assert not report.passes
    assert report.copies == ()


def test_a_recording_at_another_rate_is_an_error() -> None:
    """The fixture is only comparable at the rate it was played at."""
    recording = recording_with((0.0, 1.0))

    with pytest.raises(ValueError, match="44100 Hz"):
        no_double.find_copies(fixture(), recording, 44_100)


def test_run_passes_a_single_playback(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The command exits zero when the recording holds one copy."""
    recording = tmp_path / "headphones.wav"
    write_recording(recording, recording_with((0.25, 1.0)))
    written: list[tuple[str, bool]] = []

    def append(
        _path: Path,
        check: str,
        *,
        passed: bool,
        detail: str,
        stamp: datetime | None = None,
    ) -> None:
        _ = detail, stamp
        written.append((check, passed))

    monkeypatch.setattr(no_double, "append_result", append)

    status = no_double.run(["--recording", str(recording)])

    assert status == 0
    assert written == [("no-double", True)]
    assert "PASS" in capsys.readouterr().out


def test_run_fails_a_double_playback(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Two copies exit one and name the count."""
    recording = tmp_path / "headphones.wav"
    write_recording(recording, recording_with((0.0, 1.0), (1.0, 1.0)))

    def append(
        _path: Path,
        _check: str,
        *,
        passed: bool,
        detail: str,
        stamp: datetime | None = None,
    ) -> None:
        _ = passed, detail, stamp

    monkeypatch.setattr(no_double, "append_result", append)

    status = no_double.run(["--recording", str(recording)])

    assert status == 1
    assert "heard 2 times" in capsys.readouterr().err


def test_play_spawns_afplay_on_the_written_fixture(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The play step writes the fixture and reports the process the app taps."""
    played: list[Path] = []

    def play(fixture_path: Path) -> int:
        played.append(fixture_path)
        return 4_242

    def root(_source: Path) -> Path:
        return tmp_path

    monkeypatch.setattr(no_double, "play_fixture", play)
    monkeypatch.setattr(no_double, "repo_root", root)

    status = no_double.run(["--play"])

    assert status == 0
    assert played == [tmp_path / no_double.RELATIVE_FIXTURE]
    assert played[0].is_file()
    assert "process 4242" in capsys.readouterr().out


def test_neither_play_nor_recording_is_a_usage_error() -> None:
    """The command needs one of its two jobs named."""
    with pytest.raises(SystemExit) as exit_info:
        no_double.run([])

    assert exit_info.value.code == 2
