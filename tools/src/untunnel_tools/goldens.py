import argparse
import json
import sys
from pathlib import Path

import numpy as np
from numpy.typing import NDArray

from untunnel_tools.paths import repo_root

SAMPLE_RATES = (16_000, 24_000, 32_000, 48_000)
WINDOW_MILLISECONDS = 40
HOP_MILLISECONDS = 20
MILLISECONDS_PER_SECOND = 1000
FRAME_HOPS = 3
DECIMALS = 7
NOISE_AMPLITUDE = 0.25
IMPULSE_AMPLITUDE = 4.0
# Irregular positions keep every frame broadband without comb nulls.
IMPULSE_POSITIONS_HOPS = (0.3, 1.15, 2.35)

FloatArray = NDArray[np.float64]


def window_length(sample_rate: int) -> int:
    """Return the frame length the model uses at this rate."""
    return sample_rate * WINDOW_MILLISECONDS // MILLISECONDS_PER_SECOND


def hop_length(sample_rate: int) -> int:
    """Return the frame advance the model uses at this rate."""
    return sample_rate * HOP_MILLISECONDS // MILLISECONDS_PER_SECOND


def periodic_hann(size: int) -> FloatArray:
    """Return a periodic Hann window, matching torch.hann_window(periodic=True)."""
    index = np.arange(size, dtype=np.float64)
    return np.asarray(0.5 - 0.5 * np.cos(2 * np.pi * index / size), dtype=np.float64)


def source_signal(sample_rate: int) -> FloatArray:
    """Return a deterministic broadband signal with a stable phase in every bin."""
    hop = hop_length(sample_rate)
    length = FRAME_HOPS * hop
    generator = np.random.default_rng(sample_rate)
    signal = NOISE_AMPLITUDE * np.asarray(generator.standard_normal(length), dtype=np.float64)
    for position_hops in IMPULSE_POSITIONS_HOPS:
        signal[int(position_hops * hop)] += IMPULSE_AMPLITUDE
    return signal


def stft_columns(
    signal: FloatArray, window: FloatArray, hop: int
) -> tuple[list[list[float]], list[list[float]]]:
    """Return log1p magnitudes and atan2 phases for a centred, reflect-padded STFT."""
    padding = len(window) // 2
    padded = np.asarray(np.pad(signal, padding, mode="reflect"), dtype=np.float64)
    frame_count = 1 + (len(padded) - len(window)) // hop

    magnitudes: list[list[float]] = []
    phases: list[list[float]] = []
    for frame_index in range(frame_count):
        start = frame_index * hop
        frame = padded[start : start + len(window)] * window
        spectrum = np.fft.rfft(frame)
        magnitude = np.log1p(np.abs(spectrum))
        phase = np.arctan2(spectrum.imag, spectrum.real)
        magnitudes.append([round(float(value), DECIMALS) for value in magnitude])
        phases.append([round(float(value), DECIMALS) for value in phase])
    return magnitudes, phases


def reference_case(sample_rate: int) -> dict[str, object]:
    """Build the stored signal and columns for one sample rate."""
    # The engine reads single-precision samples, so derive the columns from the values the
    # fixture will deliver after that conversion rather than from the wider source signal.
    signal = np.asarray(np.asarray(source_signal(sample_rate), dtype=np.float32), dtype=np.float64)
    window = periodic_hann(window_length(sample_rate))
    magnitudes, phases = stft_columns(signal, window, hop_length(sample_rate))
    frames = [
        {"magnitudes": frame_magnitudes, "phases": frame_phases}
        for frame_magnitudes, frame_phases in zip(magnitudes, phases, strict=True)
    ]
    return {
        "sample_rate": sample_rate,
        "window_length": len(window),
        "hop_length": hop_length(sample_rate),
        "signal": [float(format(value, ".9g")) for value in signal],
        "frames": frames,
    }


def write_reference(root: Path) -> Path:
    """Write every reference case as one compact JSON document."""
    document: dict[str, object] = {
        "backend": "numpy",
        "definition": "periodic Hann, centre reflection padding, log1p magnitude, atan2 phase",
        "window_milliseconds": WINDOW_MILLISECONDS,
        "hop_milliseconds": HOP_MILLISECONDS,
        "cases": [reference_case(rate) for rate in SAMPLE_RATES],
    }
    path = root / "fixtures" / "stft" / "reference.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(document, separators=(",", ":"), sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return path


def main() -> None:
    """Generate the STFT reference columns."""
    parser = argparse.ArgumentParser(description="Generate the streaming transform references.")
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--print-root", action="store_true")
    action.add_argument(
        "--stft-fixtures",
        action="store_true",
        help="write fixtures/stft/reference.json from the numpy definition",
    )
    args = parser.parse_args()
    root = repo_root(Path(__file__))
    if args.print_root:
        sys.stdout.write(f"{root}\n")
        return
    path = write_reference(root)
    sys.stdout.write(f"Wrote {path.relative_to(root)} with the numpy STFT definition.\n")


if __name__ == "__main__":
    main()
