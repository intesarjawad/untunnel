"""Degradations a hands-free headset link applies to speech, all scripted and seeded.

The mSBC and G.711 stages run the pinned ffmpeg encoders on real frames. Packet loss is
applied to the decoded signal: a lost 7.5 ms frame becomes silence, the worst case, because a
real stack conceals lost frames and a decoder keeps state across them.
"""

import shutil
import subprocess
import tempfile
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import soundfile
import soxr
from numpy.typing import NDArray

from untunnel_tools import paths
from untunnel_tools.measure import FloatArray

REFERENCE_RATE = 48_000
MSBC_RATE = 16_000
MSBC_FRAME_SAMPLES = 120
MULAW_RATE = 8_000
MEAN_BURST_FRAMES = 2.0
LOSS_LEVELS = (0.02, 0.05)
LOSS_SEED = 0

type BoolArray = NDArray[np.bool_]


@dataclass(frozen=True)
class Condition:
    """One degradation of the clean reference."""

    key: str
    label: str
    sample_rate: int
    bandwidth_hz: int
    average_loss: float = 0.0

    @property
    def worst_case(self) -> bool:
        """Whether lost frames are zero-filled rather than concealed."""
        return self.average_loss > 0


CONDITIONS = (
    Condition("msbc", "mSBC", MSBC_RATE, 8_000),
    Condition(
        "msbc-loss2",
        "mSBC with 2 % packet loss (worst case: lost frames zero-filled)",
        MSBC_RATE,
        8_000,
        LOSS_LEVELS[0],
    ),
    Condition(
        "msbc-loss5",
        "mSBC with 5 % packet loss (worst case: lost frames zero-filled)",
        MSBC_RATE,
        8_000,
        LOSS_LEVELS[1],
    ),
    Condition("mulaw", "Narrowband phone, G.711 mu-law at 8 kHz", MULAW_RATE, 4_000),
)


def resample(samples: FloatArray, from_rate: int, to_rate: int) -> FloatArray:
    """Convert a mono signal between sample rates."""
    if from_rate == to_rate:
        return samples
    return np.asarray(soxr.resample(samples, from_rate, to_rate, quality="VHQ"), dtype=np.float64)


def gilbert_elliott_loss(
    frame_count: int, average_loss: float, rng: np.random.Generator
) -> BoolArray:
    """Mark lost frames with a two-state burst model whose bursts average two frames.

    The bad state drops every frame. Leaving it with probability 1/2 gives the mean burst
    length, and entering it with L / (2 (1 - L)) makes the long-run loss equal `average_loss`.
    """
    if not 0 <= average_loss < 1:
        message = f"simulate_hfp: average loss {average_loss} must be in [0, 1)."
        raise ValueError(message)
    leave_bad = 1 / MEAN_BURST_FRAMES
    enter_bad = average_loss * leave_bad / (1 - average_loss)
    draws = rng.random(frame_count + 1)
    bad = bool(draws[0] < average_loss)
    lost = np.zeros(frame_count, dtype=np.bool_)
    for index in range(frame_count):
        bad = bool(draws[index + 1] >= leave_bad) if bad else bool(draws[index + 1] < enter_bad)
        lost[index] = bad
    return lost


def _ffmpeg(arguments: Sequence[str]) -> None:
    executable = shutil.which("ffmpeg")
    if executable is None:
        message = "simulate_hfp: ffmpeg is not on PATH; install the version pinned in sources.json."
        raise FileNotFoundError(message)
    # The executable is resolved from PATH and every argument is a fixed flag or a path this
    # module created in a private temporary directory.
    result = subprocess.run(  # noqa: S603
        [executable, "-v", "error", "-nostdin", "-y", *arguments],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        message = f"simulate_hfp: ffmpeg failed: {result.stderr.strip()}"
        raise RuntimeError(message)


def _read(path: Path) -> FloatArray:
    samples, _ = soundfile.read(str(path), dtype="float64")
    return np.asarray(samples, dtype=np.float64)


def msbc_roundtrip(samples: FloatArray, lost_frames: BoolArray | None = None) -> FloatArray:
    """Encode a 16 kHz signal as mSBC, decode it and silence the frames marked lost."""
    with tempfile.TemporaryDirectory() as folder:
        source = Path(folder) / "source.wav"
        stream = Path(folder) / "stream.sbc"
        decoded = Path(folder) / "decoded.wav"
        soundfile.write(str(source), samples, MSBC_RATE, subtype="PCM_16")
        _ffmpeg(["-i", str(source), "-c:a", "sbc", "-msbc", "1", "-f", "sbc", str(stream)])
        _ffmpeg(["-f", "sbc", "-i", str(stream), "-c:a", "pcm_s16le", str(decoded)])
        output = _read(decoded)
    if lost_frames is not None:
        for index in np.flatnonzero(lost_frames):
            start = int(index) * MSBC_FRAME_SAMPLES
            output[start : start + MSBC_FRAME_SAMPLES] = 0.0
    return output


def mulaw_roundtrip(samples: FloatArray) -> FloatArray:
    """Encode an 8 kHz signal as G.711 mu-law and decode it again."""
    with tempfile.TemporaryDirectory() as folder:
        source = Path(folder) / "source.wav"
        encoded = Path(folder) / "encoded.wav"
        decoded = Path(folder) / "decoded.wav"
        soundfile.write(str(source), samples, MULAW_RATE, subtype="PCM_16")
        _ffmpeg(["-i", str(source), "-c:a", "pcm_mulaw", str(encoded)])
        _ffmpeg(["-i", str(encoded), "-c:a", "pcm_s16le", str(decoded)])
        return _read(decoded)


def degrade(reference: FloatArray, condition: Condition, rng: np.random.Generator) -> FloatArray:
    """Apply a condition to a 48 kHz clean reference, returning audio at the condition's rate."""
    narrow = resample(reference, REFERENCE_RATE, condition.sample_rate)
    if condition.sample_rate == MULAW_RATE:
        return mulaw_roundtrip(narrow)
    lost = None
    if condition.average_loss > 0:
        frame_count = -(-len(narrow) // MSBC_FRAME_SAMPLES)
        lost = gilbert_elliott_loss(frame_count, condition.average_loss, rng)
    return msbc_roundtrip(narrow, lost)


# Shared with the other tool modules so `--print-root` works from each of them.
main = paths.main
repo_root = paths.repo_root

if __name__ == "__main__":
    main()
