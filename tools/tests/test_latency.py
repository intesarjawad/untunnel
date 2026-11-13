from pathlib import Path

import numpy as np
import pytest
import soundfile

from untunnel_tools.measure import FloatArray, latency


def click_train(
    sample_rate: int = 48_000,
    period_ms: float = 100.0,
    delay_ms: float = 30.0,
    clicks: int = 6,
    amplitude: float = 0.8,
) -> FloatArray:
    """Build a click train whose first click is at `delay_ms` into the recording."""
    samples = np.zeros(sample_rate, dtype=np.float64)
    impulse_length = round(0.00025 * sample_rate)
    for index in range(clicks):
        start = round((delay_ms + index * period_ms) * sample_rate / 1000)
        samples[start : start + impulse_length] = amplitude
    return samples


def write_recording(path: Path, samples: FloatArray, sample_rate: int) -> None:
    """Write float samples as a WAV a recording tool would produce."""
    soundfile.write(str(path), samples, sample_rate, subtype="FLOAT")


def test_click_phase_is_the_measured_latency() -> None:
    """Every click's phase against the train period is the added delay."""
    samples = click_train()
    result = latency.measure(samples, 48_000, latency.MeasurementOptions(period_ms=100))

    assert result.clicks == 6
    assert result.measured_ms == pytest.approx(30, abs=0.1)
    assert result.difference_ms is None
    assert result.within_tolerance


def test_a_missing_first_click_keeps_the_same_phase() -> None:
    """The measurement does not rely on the first click being recorded."""
    samples = click_train(delay_ms=130)
    result = latency.measure(samples, 48_000, latency.MeasurementOptions(period_ms=100))

    assert result.measured_ms == pytest.approx(30, abs=0.1)


def test_detection_jitter_across_the_period_boundary_folds_into_one_cluster() -> None:
    """Clicks a sample either side of the boundary describe the same delay."""
    sample_rate = 48_000
    onsets = [
        round(0.0995 * sample_rate),
        round(0.1005 * sample_rate),
        round(0.2005 * sample_rate),
    ]

    measured = latency.phase_latency_ms(onsets, sample_rate, period_ms=100)

    assert measured == pytest.approx(0.5, abs=0.1)


def test_too_few_clicks_are_an_error() -> None:
    """A silent recording cannot produce a phase measurement."""
    samples = click_train(clicks=1)
    with pytest.raises(ValueError, match="clicks"):
        latency.measure(samples, 48_000, latency.MeasurementOptions(period_ms=100))


def test_run_accepts_a_readout_inside_the_tolerance(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """The command compares the recording with the value the app reported."""
    recording = tmp_path / "latency.wav"
    write_recording(recording, click_train(), 48_000)

    status = latency.run(
        ["--recording", str(recording), "--period-ms", "100", "--readout-ms", "32"]
    )

    assert status == 0
    captured = capsys.readouterr()
    assert "Measured added latency: 30.00 ms" in captured.out
    assert "difference -2.00 ms" in captured.out


def test_run_rejects_a_readout_outside_the_tolerance(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """A readout more than five milliseconds away fails the check."""
    recording = tmp_path / "latency.wav"
    write_recording(recording, click_train(), 48_000)

    status = latency.run(
        ["--recording", str(recording), "--period-ms", "100", "--readout-ms", "50"]
    )

    assert status == 1
    assert "does not agree" in capsys.readouterr().err


def test_run_reports_a_missing_recording(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """A missing file fails with the path in the message instead of a traceback."""
    status = latency.run(["--recording", str(tmp_path / "missing.wav")])

    assert status == 2
    assert "latency:" in capsys.readouterr().err
