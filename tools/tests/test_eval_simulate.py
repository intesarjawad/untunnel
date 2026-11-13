import numpy as np
import pytest
from numpy.typing import NDArray

from untunnel_tools.eval.metrics import align
from untunnel_tools.eval.simulate_hfp import (
    CONDITIONS,
    MSBC_FRAME_SAMPLES,
    MSBC_RATE,
    MULAW_RATE,
    REFERENCE_RATE,
    BoolArray,
    degrade,
    gilbert_elliott_loss,
    msbc_roundtrip,
    mulaw_roundtrip,
)
from untunnel_tools.measure import FloatArray

FRAME_COUNT = 100_000
LOSS_TOLERANCE = 0.002


def burst_lengths(lost: BoolArray) -> NDArray[np.intp]:
    """Return the length of every run of consecutive lost frames."""
    edges = np.diff(np.concatenate([[0], lost.astype(int), [0]]))
    return np.flatnonzero(edges == -1) - np.flatnonzero(edges == 1)


@pytest.mark.parametrize("average_loss", [0.02, 0.05])
def test_realised_loss_matches_the_target(average_loss: float) -> None:
    """Over 100,000 frames the dropped share stays within 0.2 percentage points."""
    lost = gilbert_elliott_loss(FRAME_COUNT, average_loss, np.random.default_rng(0))
    assert abs(float(lost.mean()) - average_loss) < LOSS_TOLERANCE


@pytest.mark.parametrize("average_loss", [0.02, 0.05])
def test_bursts_average_two_frames(average_loss: float) -> None:
    """A bad-to-good probability of one half gives a mean burst of two frames."""
    lost = gilbert_elliott_loss(FRAME_COUNT, average_loss, np.random.default_rng(0))
    assert abs(float(burst_lengths(lost).mean()) - 2.0) < 0.15


def test_loss_pattern_repeats_for_a_seed() -> None:
    """The same generator state gives the same lost frames."""
    first = gilbert_elliott_loss(1_000, 0.05, np.random.default_rng(0))
    second = gilbert_elliott_loss(1_000, 0.05, np.random.default_rng(0))
    other = gilbert_elliott_loss(1_000, 0.05, np.random.default_rng(1))
    assert np.array_equal(first, second)
    assert not np.array_equal(first, other)


@pytest.mark.parametrize("average_loss", [-0.1, 1.0])
def test_loss_outside_the_unit_interval_fails(average_loss: float) -> None:
    """Loss must be at least zero and below one."""
    with pytest.raises(ValueError, match="average loss"):
        gilbert_elliott_loss(10, average_loss, np.random.default_rng(0))


def tones(sample_rate: int, seconds: float = 1.0) -> FloatArray:
    """Return a low and a mid-band tone that the codecs both pass."""
    time_seconds = np.arange(round(seconds * sample_rate)) / sample_rate
    return np.asarray(
        0.2 * np.sin(2 * np.pi * 440 * time_seconds)
        + 0.1 * np.sin(2 * np.pi * 3_000 * time_seconds),
        dtype=np.float64,
    )


def test_msbc_keeps_the_signal_level() -> None:
    """After removing the codec delay the decoded tones carry the input's energy."""
    samples = tones(MSBC_RATE)
    decoded = msbc_roundtrip(samples)
    assert abs(len(decoded) - len(samples)) < 2 * MSBC_FRAME_SAMPLES
    aligned_reference, aligned = align(samples, decoded, MSBC_RATE)
    reference_rms = float(np.sqrt(np.mean(aligned_reference**2)))
    decoded_rms = float(np.sqrt(np.mean(aligned**2)))
    assert abs(decoded_rms / reference_rms - 1) < 0.05


def test_lost_frames_are_silent_and_the_rest_untouched() -> None:
    """A marked 7.5 ms frame becomes zeros while its neighbours still carry audio."""
    samples = tones(MSBC_RATE)
    intact = msbc_roundtrip(samples)
    lost = np.zeros(len(samples) // MSBC_FRAME_SAMPLES, dtype=np.bool_)
    lost[[5, 40]] = True
    damaged = msbc_roundtrip(samples, lost)
    for index in (5, 40):
        start = index * MSBC_FRAME_SAMPLES
        assert not np.any(damaged[start : start + MSBC_FRAME_SAMPLES])
        assert np.any(intact[start : start + MSBC_FRAME_SAMPLES])
    kept = np.ones(len(damaged), dtype=np.bool_)
    for index in (5, 40):
        kept[index * MSBC_FRAME_SAMPLES : (index + 1) * MSBC_FRAME_SAMPLES] = False
    assert np.array_equal(damaged[kept], intact[kept])


def test_mulaw_error_stays_within_its_largest_step() -> None:
    """G.711 mu-law quantises a 0.5 amplitude tone to within about 0.016 of full scale."""
    samples = 0.5 * np.sin(2 * np.pi * 1_000 * np.arange(MULAW_RATE) / MULAW_RATE)
    decoded = mulaw_roundtrip(samples)
    assert len(decoded) == len(samples)
    assert float(np.max(np.abs(decoded - samples))) < 0.02


def test_every_condition_returns_audio_at_its_own_rate() -> None:
    """Degradations run from the 48 kHz reference and land at 16 kHz or 8 kHz."""
    reference = tones(REFERENCE_RATE)
    for condition in CONDITIONS:
        degraded = degrade(reference, condition, np.random.default_rng(0))
        assert abs(len(degraded) - condition.sample_rate) < 2 * MSBC_FRAME_SAMPLES


def test_packet_loss_conditions_are_labelled_worst_case() -> None:
    """Zero-filled loss is called out in the label of both loss conditions."""
    lossy = [condition for condition in CONDITIONS if condition.worst_case]
    assert len(lossy) == 2
    assert all("worst case" in condition.label for condition in lossy)
    assert [condition.average_loss for condition in lossy] == [0.02, 0.05]


def test_loss_conditions_silence_frames_and_clean_ones_do_not() -> None:
    """Only the loss conditions contain fully silent codec frames in a steady tone."""
    reference = tones(REFERENCE_RATE, 2.0)
    results = {
        condition.key: degrade(reference, condition, np.random.default_rng(0))
        for condition in CONDITIONS
    }

    def silent_frames(samples: FloatArray) -> int:
        frames = samples[: len(samples) // MSBC_FRAME_SAMPLES * MSBC_FRAME_SAMPLES]
        return int(np.sum(~np.any(frames.reshape(-1, MSBC_FRAME_SAMPLES), axis=1)))

    assert silent_frames(results["msbc"]) == 0
    assert silent_frames(results["msbc-loss5"]) > 0
