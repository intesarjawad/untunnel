from pathlib import Path

import numpy as np
import pytest
import soundfile

from untunnel_tools.measure import FloatArray, bypass_click


def program_pair(sample_rate: int = 48_000) -> tuple[FloatArray, FloatArray]:
    """Return the direct and restored 200 Hz programs used by both fixtures."""
    time = np.arange(sample_rate, dtype=np.float64) / sample_rate
    direct = 0.5 * np.sin(2 * np.pi * 200 * time)
    restored = 0.5 * np.sin(2 * np.pi * 200 * time + np.pi / 3)
    return direct, restored


def clean_switch(direct: FloatArray, restored: FloatArray) -> FloatArray:
    """Switch programs over five milliseconds with an equal-power crossfade."""
    output = direct.copy()
    middle = len(output) // 2
    fade = round(0.005 * 48_000)
    start = middle - fade // 2
    for index in range(fade):
        angle = (index + 1) / fade * np.pi / 2
        output[start + index] = direct[start + index] * np.cos(angle) + restored[
            start + index
        ] * np.sin(angle)
    output[start + fade :] = restored[start + fade :]
    return output


def click_switch(direct: FloatArray, restored: FloatArray) -> FloatArray:
    """Switch programs at one sample, the failure the check is looking for."""
    middle = len(direct) // 2
    return np.concatenate((direct[:middle], restored[middle:]))


def write_recording(path: Path, samples: FloatArray) -> None:
    """Write a fixture as the float WAV a recording tool would produce."""
    soundfile.write(str(path), samples, 48_000, subtype="FLOAT")


def test_a_crossfaded_switch_stays_below_the_transient_limit() -> None:
    """A five millisecond equal-power fade has no sample-scale jump."""
    direct, restored = program_pair()
    result = bypass_click.measure(clean_switch(direct, restored), 48_000)

    assert result.passes
    assert result.relative_db <= bypass_click.MAXIMUM_TRANSIENT_DBFS


def test_a_hard_switch_exceeds_the_transient_limit() -> None:
    """Switching at one sample is the click the acceptance rule rejects."""
    direct, restored = program_pair()
    result = bypass_click.measure(click_switch(direct, restored), 48_000)

    assert not result.passes
    assert result.relative_db > bypass_click.MAXIMUM_TRANSIENT_DBFS


def test_a_recording_shorter_than_one_window_is_an_error() -> None:
    """There must be at least one window to measure."""
    with pytest.raises(ValueError, match="too short"):
        bypass_click.measure(np.zeros(2, dtype=np.float64), 48_000)


def test_run_reports_a_clean_recording(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    """The command exits zero when no transient stands out."""
    direct, restored = program_pair()
    recording = tmp_path / "bypass.wav"
    write_recording(recording, clean_switch(direct, restored))

    status = bypass_click.run(["--recording", str(recording)])

    assert status == 0
    captured = capsys.readouterr()
    assert "Largest transient:" in captured.out
    assert "Relative to program:" in captured.out


def test_run_fails_on_a_click(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    """The command exits one when the switch adds a transient."""
    direct, restored = program_pair()
    recording = tmp_path / "bypass.wav"
    write_recording(recording, click_switch(direct, restored))

    status = bypass_click.run(["--recording", str(recording)])

    assert status == 1
    assert "added a transient" in capsys.readouterr().err
