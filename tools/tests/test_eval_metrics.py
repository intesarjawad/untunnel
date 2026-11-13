from collections.abc import Mapping

import numpy as np

from untunnel_tools.eval.baselines import FOLD_GAIN_DB, spectral_folding
from untunnel_tools.eval.metrics import (
    HIGH_BAND_HZ,
    METRICS,
    SampleArray,
    align,
    cosine_similarity,
    dnsmos_scores,
    ecapa_similarity,
    log_spectral_distance,
    to_reference_time,
)
from untunnel_tools.measure import FloatArray

SAMPLE_RATE = 48_000


def noise(seconds: float = 1.0, seed: int = 0) -> FloatArray:
    """Return broadband noise, so every bin of a spectrogram carries energy."""
    rng = np.random.default_rng(seed)
    return np.asarray(0.1 * rng.standard_normal(round(seconds * SAMPLE_RATE)), dtype=np.float64)


def lowpass(samples: FloatArray, cutoff_hz: float) -> FloatArray:
    """Remove every frequency above the cutoff with a brick-wall filter."""
    spectrum = np.fft.rfft(samples)
    frequencies = np.fft.rfftfreq(len(samples), 1 / SAMPLE_RATE)
    spectrum[frequencies > cutoff_hz] = 0
    return np.asarray(np.fft.irfft(spectrum, len(samples)), dtype=np.float64)


def band_power(samples: FloatArray, low_hz: float, high_hz: float) -> float:
    """Sum the power between two frequencies."""
    power = np.abs(np.fft.rfft(samples)) ** 2
    frequencies = np.fft.rfftfreq(len(samples), 1 / SAMPLE_RATE)
    return float(np.sum(power[(frequencies >= low_hz) & (frequencies <= high_hz)]))


def test_identical_signals_have_zero_distance() -> None:
    """A signal is at distance zero from itself in both bands."""
    samples = noise()
    assert log_spectral_distance(samples, samples, SAMPLE_RATE) == 0.0
    assert log_spectral_distance(samples, samples, SAMPLE_RATE, HIGH_BAND_HZ) == 0.0


def test_lowpass_raises_high_band_distance() -> None:
    """Removing everything above 4 kHz makes the high band far from the reference."""
    reference = noise()
    limited = lowpass(reference, 4_000)
    high = log_spectral_distance(reference, limited, SAMPLE_RATE, HIGH_BAND_HZ)
    full = log_spectral_distance(reference, limited, SAMPLE_RATE)
    assert high > 10.0
    assert full < high


def test_folding_puts_energy_between_8_and_16_khz() -> None:
    """The mirrored octave arrives near the fixed gain and nothing lands above 16 kHz."""
    reference = noise()
    limited = lowpass(reference, 8_000)
    folded = spectral_folding(limited, 8_000)
    below = band_power(limited, 500, 7_500)
    assert band_power(limited, 8_500, 15_500) < 1e-9 * below
    ratio = band_power(folded, 8_500, 15_500) / below
    expected = 10 ** (FOLD_GAIN_DB / 10)
    assert 0.95 * expected < ratio < 1.05 * expected
    assert band_power(folded, 16_500, 23_500) < 1e-6 * below


def test_folding_lowers_high_band_distance_to_the_reference() -> None:
    """Against a full-band reference, folded energy beats an empty high band."""
    reference = noise()
    limited = lowpass(reference, 8_000)
    folded = spectral_folding(limited, 8_000)
    distance_folded = log_spectral_distance(reference, folded, SAMPLE_RATE, HIGH_BAND_HZ)
    distance_limited = log_spectral_distance(reference, limited, SAMPLE_RATE, HIGH_BAND_HZ)
    assert distance_folded < distance_limited


def test_folding_keeps_the_input_below_its_bandwidth() -> None:
    """The band the input already had is left as it was."""
    limited = lowpass(noise(), 8_000)
    folded = spectral_folding(limited, 8_000)
    assert len(folded) == len(limited)
    assert np.allclose(np.fft.rfft(folded)[:7_000], np.fft.rfft(limited)[:7_000], rtol=0, atol=1e-9)


def test_cosine_similarity_of_known_vectors() -> None:
    """Parallel vectors score one and perpendicular vectors zero."""
    assert cosine_similarity(np.array([1.0, 2.0, 3.0]), np.array([2.0, 4.0, 6.0])) == 1.0
    assert cosine_similarity(np.array([1.0, 0.0]), np.array([0.0, 1.0])) == 0.0


def band_embedding(samples: FloatArray) -> FloatArray:
    """Describe a signal by its power in four bands, standing in for a speaker encoder."""
    power = np.abs(np.fft.rfft(samples)) ** 2
    return np.asarray([float(band.sum()) for band in np.array_split(power, 4)])


def test_identical_signals_have_unit_speaker_similarity() -> None:
    """The same audio embeds to the same vector, so its cosine is one."""
    samples = noise()
    assert abs(ecapa_similarity(samples, samples, SAMPLE_RATE, band_embedding) - 1.0) < 1e-12


def test_changed_signal_lowers_speaker_similarity() -> None:
    """A signal with a different spectrum embeds away from the reference."""
    reference = noise()
    similarity = ecapa_similarity(reference, lowpass(reference, 1_000), SAMPLE_RATE, band_embedding)
    assert similarity < 0.9


def test_alignment_removes_a_delay() -> None:
    """An output delayed by 37 samples lines up with its reference exactly."""
    reference = noise(0.5)
    delayed = np.concatenate([np.zeros(37), reference])
    aligned_reference, aligned_output = align(reference, delayed, SAMPLE_RATE)
    assert np.array_equal(aligned_reference, reference)
    assert np.array_equal(aligned_output, reference)


def test_alignment_removes_an_advance() -> None:
    """An output that starts 50 samples late in the reference trims the reference instead."""
    reference = noise(0.5)
    advanced = reference[50:]
    aligned_reference, aligned_output = align(reference, advanced, SAMPLE_RATE)
    assert np.array_equal(aligned_reference, advanced)
    assert np.array_equal(aligned_output, advanced)


def test_shift_onto_the_reference_timeline_keeps_the_length() -> None:
    """A delayed output moves back in time and is padded to the reference length."""
    reference = noise(0.5)
    delayed = np.concatenate([np.zeros(37), reference])
    shifted = to_reference_time(reference, delayed, SAMPLE_RATE)
    assert np.array_equal(shifted, reference)


class RecordingSession:
    """An inference session that returns fixed raw scores and counts its calls."""

    def __init__(self) -> None:
        """Start with no calls recorded."""
        self.calls = 0

    def run(self, output_names: None, input_feed: Mapping[str, SampleArray]) -> list[FloatArray]:
        """Return signal 1, background 2 and overall 3 whatever the input."""
        assert output_names is None
        assert input_feed["input_1"].shape == (1, 144_160)
        self.calls += 1
        return [np.array([[1.0, 2.0, 3.0]])]


def test_dnsmos_maps_raw_scores_through_the_published_fit() -> None:
    """Eleven seconds hold two 9.01 s windows, and each raw score goes through its own fit."""
    session = RecordingSession()
    scores = dnsmos_scores(noise(11.0), SAMPLE_RATE, session)
    assert session.calls == 2
    assert abs(scores["dnsmos_sig"] - 1.14211065) < 1e-6
    assert abs(scores["dnsmos_bak"] - 2.2955893) < 1e-6
    assert abs(scores["dnsmos_ovrl"] - 2.78345392) < 1e-6


def test_only_lsd_sees_above_8_khz() -> None:
    """Every other metric works on a resampled copy that stops at or below 8 kHz."""
    seeing = {metric.key for metric in METRICS if metric.sees_above_8khz}
    assert seeing == {"lsd_full", "lsd_high"}
