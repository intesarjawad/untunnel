"""Checks that switching the microphone path does not add a click.

The recording holds a steady program while the path toggles. A click is a jump that the
program's own smoothness cannot produce, so the tool measures the largest sample-scale
prediction residual. That residual must stay 40 dB below the program's peak level, which a
crossfaded switch does and a one-sample switch does not.
"""

import argparse
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from untunnel_tools.measure import FloatArray, dbfs, read_mono
from untunnel_tools.paths import repo_root

DEFAULT_TOGGLES = 50
MAXIMUM_TRANSIENT_DBFS = -40.0
DEFAULT_WINDOW_MS = 1.0
MINIMUM_RESIDUAL_SAMPLES = 3
MILLISECONDS_PER_SECOND = 1000.0
RELATIVE_RECORDING = Path("recordings") / "bypass-click.wav"


@dataclass(frozen=True)
class BypassResult:
    """The loudest transient and the program level it is compared with."""

    transient_dbfs: float
    program_dbfs: float
    toggles: int

    @property
    def relative_db(self) -> float:
        """The transient level relative to the program, in decibels."""
        if self.transient_dbfs == float("-inf"):
            return float("-inf")
        if self.program_dbfs == float("-inf"):
            return float("inf")
        return self.transient_dbfs - self.program_dbfs

    @property
    def passes(self) -> bool:
        """Whether the transient stayed below the limit."""
        return self.relative_db <= MAXIMUM_TRANSIENT_DBFS


def prediction_residual(samples: FloatArray) -> FloatArray:
    """Return how far each sample sits from the average of its neighbours.

    A smooth program predicts well at this scale; a click is exactly the sample that does not.
    """
    if len(samples) < MINIMUM_RESIDUAL_SAMPLES:
        return np.zeros(0, dtype=np.float64)
    return np.asarray(
        samples[1:-1] - 0.5 * (samples[:-2] + samples[2:]),
        dtype=np.float64,
    )


def measure(
    samples: FloatArray,
    sample_rate: int,
    toggles: int = DEFAULT_TOGGLES,
    window_ms: float = DEFAULT_WINDOW_MS,
) -> BypassResult:
    """Measure the loudest transient in the recording and compare it with the program."""
    if len(samples) == 0:
        message = "recording is empty"
        raise ValueError(message)
    residual = prediction_residual(samples)
    size = max(1, round(window_ms * sample_rate / MILLISECONDS_PER_SECOND))
    window_count = len(residual) // size
    if window_count == 0:
        message = "recording is too short to measure a transient"
        raise ValueError(message)
    peaks = np.max(
        np.abs(residual[: window_count * size].reshape(window_count, size)),
        axis=1,
    )
    return BypassResult(
        transient_dbfs=dbfs(float(np.max(peaks))),
        program_dbfs=dbfs(float(np.max(np.abs(samples)))),
        toggles=toggles,
    )


def run(arguments: list[str]) -> int:
    """Run the bypass check and return a process status."""
    parser = _parser()
    args = parser.parse_args(arguments)
    root = repo_root(Path(__file__))
    recording = Path(args.recording) if args.recording else root / RELATIVE_RECORDING
    try:
        samples, sample_rate = read_mono(_resolve(root, recording))
        result = measure(samples, sample_rate, args.toggles, args.window_ms)
    except (OSError, RuntimeError, ValueError) as error:
        sys.stderr.write(f"bypass-click: {error}\n")
        return 2

    sys.stdout.write(
        f"Program level: {result.program_dbfs:.1f} dBFS over {result.toggles} toggles\n"
    )
    sys.stdout.write(f"Largest transient: {result.transient_dbfs:.1f} dBFS\n")
    sys.stdout.write(
        f"Relative to program: {result.relative_db:.1f} dB "
        f"(limit {MAXIMUM_TRANSIENT_DBFS:.0f} dB)\n"
    )
    if not result.passes:
        sys.stderr.write("bypass-click: the path switch added a transient\n")
        return 1
    return 0


def _resolve(root: Path, path: Path) -> Path:
    return path if path.is_absolute() else root / path


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Check a recording of the microphone path toggling for a click.",
        epilog=(
            "The capture step needs an audio device; record the virtual microphone to a WAV "
            "and pass it with --recording."
        ),
    )
    parser.add_argument("--recording", help="WAV file of the toggled program")
    parser.add_argument(
        "--toggles",
        type=int,
        default=DEFAULT_TOGGLES,
        help="number of path switches the recording contains",
    )
    parser.add_argument(
        "--window-ms",
        type=float,
        default=DEFAULT_WINDOW_MS,
        help="length of the window whose peak counts as a transient",
    )
    return parser


def main() -> None:
    """Run the bypass check from the command line."""
    root = repo_root(Path(__file__))
    if "--print-root" in sys.argv[1:]:
        sys.stdout.write(f"{root}\n")
        return
    raise SystemExit(run(sys.argv[1:]))


if __name__ == "__main__":
    main()
