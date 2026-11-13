"""Offline analysis for the live audio measurements.

Recording itself needs an audio device, which a development machine cannot assume, so each
command reads the WAV a recording produced. That keeps the arithmetic and the thresholds
testable and lets one recording be re-measured without hardware.
"""

from pathlib import Path

import numpy as np
import soundfile
from numpy.typing import NDArray

type FloatArray = NDArray[np.float64]


def read_mono(path: Path) -> tuple[FloatArray, int]:
    """Read a recording, mix its channels to mono and keep its sample rate."""
    samples, sample_rate = soundfile.read(str(path), dtype="float64", always_2d=True)
    mono = np.asarray(samples.mean(axis=1), dtype=np.float64)
    return mono, int(sample_rate)


def dbfs(amplitude: float) -> float:
    """Return an amplitude in dBFS, with silence at negative infinity."""
    if amplitude <= 0:
        return float("-inf")
    return 20 * float(np.log10(amplitude))
