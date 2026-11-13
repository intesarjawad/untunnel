"""Estimates the added latency from a recording of the demo click train.

The train repeats at a known period, so the tool measures the phase of the detected clicks
against the recording's own start rather than trying to align a second clock. A delay longer
than one period is therefore ambiguous; the demo period is chosen longer than any acceptable
readout.
"""

import argparse
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from untunnel_tools.measure import FloatArray, read_mono
from untunnel_tools.paths import repo_root

DEMO_PERIOD_MS = 500.0
DEFAULT_THRESHOLD_DBFS = -30.0
DEFAULT_TOLERANCE_MS = 5.0
MILLISECONDS_PER_SECOND = 1000.0
MINIMUM_CLICK_SEPARATION_MS = 20.0
MINIMUM_CLICKS = 2
RELATIVE_RECORDING = Path("recordings") / "latency-train.wav"


@dataclass(frozen=True)
class MeasurementOptions:
    """The click train and the readout the measurement is compared with."""

    period_ms: float
    readout_ms: float | None = None
    tolerance_ms: float = DEFAULT_TOLERANCE_MS
    threshold_dbfs: float = DEFAULT_THRESHOLD_DBFS


@dataclass(frozen=True)
class LatencyResult:
    """One measured delay and its comparison with the app's readout."""

    measured_ms: float
    readout_ms: float | None
    clicks: int
    tolerance_ms: float

    @property
    def difference_ms(self) -> float | None:
        """The gap between the measurement and the readout, when a readout was given."""
        if self.readout_ms is None:
            return None
        return self.measured_ms - self.readout_ms

    @property
    def within_tolerance(self) -> bool:
        """Whether the readout agrees with the recording."""
        difference = self.difference_ms
        return difference is None or abs(difference) <= self.tolerance_ms


def click_onsets(
    samples: FloatArray,
    sample_rate: int,
    threshold_dbfs: float = DEFAULT_THRESHOLD_DBFS,
    minimum_separation_ms: float = MINIMUM_CLICK_SEPARATION_MS,
) -> list[int]:
    """Return the first sample of each click that rises above the threshold."""
    threshold = 10 ** (threshold_dbfs / 20)
    above = np.abs(samples) > threshold
    padded = np.concatenate((np.zeros(1, dtype=bool), above))
    starts = np.flatnonzero(~padded[:-1] & padded[1:])
    separation = max(1, round(minimum_separation_ms * sample_rate / MILLISECONDS_PER_SECOND))
    onsets: list[int] = []
    for start in starts:
        index = int(start)
        if not onsets or index - onsets[-1] >= separation:
            onsets.append(index)
    return onsets


def phase_latency_ms(onsets: list[int], sample_rate: int, period_ms: float) -> float:
    """Return the delay modulo one period, in milliseconds."""
    period = period_ms * sample_rate / MILLISECONDS_PER_SECOND
    phases = np.asarray([onset % period for onset in onsets], dtype=np.float64)
    centre = float(np.median(phases))
    # A click whose phase lands on the other side of the period boundary is the same delay;
    # folding each value towards the median removes that wrap without moving the cluster.
    wrapped = phases + period * np.round((centre - phases) / period)
    return float(np.median(wrapped)) / sample_rate * MILLISECONDS_PER_SECOND


def measure(
    samples: FloatArray,
    sample_rate: int,
    options: MeasurementOptions,
) -> LatencyResult:
    """Detect the click train and compare its phase with the readout."""
    onsets = click_onsets(samples, sample_rate, options.threshold_dbfs)
    if len(onsets) < MINIMUM_CLICKS:
        message = f"found {len(onsets)} clicks; at least {MINIMUM_CLICKS} are needed"
        raise ValueError(message)
    return LatencyResult(
        measured_ms=phase_latency_ms(onsets, sample_rate, options.period_ms),
        readout_ms=options.readout_ms,
        clicks=len(onsets),
        tolerance_ms=options.tolerance_ms,
    )


def run(arguments: list[str]) -> int:
    """Run the latency check and return a process status."""
    parser = _parser()
    args = parser.parse_args(arguments)
    root = repo_root(Path(__file__))
    recording = Path(args.recording) if args.recording else root / RELATIVE_RECORDING
    if args.source == "file" and args.period_ms is None:
        parser.error("--source file needs --period-ms")
    period_ms = DEMO_PERIOD_MS if args.period_ms is None else args.period_ms
    if period_ms <= MINIMUM_CLICK_SEPARATION_MS:
        parser.error("--period-ms must exceed the minimum click separation")
    try:
        samples, sample_rate = read_mono(_resolve(root, recording))
        result = measure(
            samples,
            sample_rate,
            MeasurementOptions(
                period_ms=period_ms,
                readout_ms=args.readout_ms,
                tolerance_ms=args.tolerance_ms,
                threshold_dbfs=args.threshold_dbfs,
            ),
        )
    except (OSError, RuntimeError, ValueError) as error:
        sys.stderr.write(f"latency: {error}\n")
        return 2

    sys.stdout.write(
        f"Measured added latency: {result.measured_ms:.2f} ms from {result.clicks} clicks\n"
    )
    if result.difference_ms is not None:
        sys.stdout.write(
            f"App readout: {result.readout_ms:.2f} ms "
            f"(difference {result.difference_ms:+.2f} ms, "
            f"tolerance {result.tolerance_ms:.2f} ms)\n"
        )
    if not result.within_tolerance:
        sys.stderr.write("latency: the readout does not agree with the recording\n")
        return 1
    return 0


def _resolve(root: Path, path: Path) -> Path:
    return path if path.is_absolute() else root / path


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Measure the added latency from a demo click-train recording.",
        epilog=(
            "The capture step needs an audio device; record the virtual microphone to a WAV "
            "and pass it with --recording."
        ),
    )
    parser.add_argument("--recording", help="WAV file of the recorded click train")
    parser.add_argument(
        "--source",
        choices=("demo", "file"),
        default="demo",
        help="the demo train uses its fixed period; file needs --period-ms",
    )
    parser.add_argument("--period-ms", type=float, help="delay between clicks in milliseconds")
    parser.add_argument("--readout-ms", type=float, help="added latency the app reported")
    parser.add_argument(
        "--tolerance-ms",
        type=float,
        default=DEFAULT_TOLERANCE_MS,
        help="largest acceptable difference from the readout",
    )
    parser.add_argument(
        "--threshold-dbfs",
        type=float,
        default=DEFAULT_THRESHOLD_DBFS,
        help="level a click must exceed to count",
    )
    return parser


def main() -> None:
    """Run the latency check from the command line."""
    root = repo_root(Path(__file__))
    if "--print-root" in sys.argv[1:]:
        sys.stdout.write(f"{root}\n")
        return
    raise SystemExit(run(sys.argv[1:]))


if __name__ == "__main__":
    main()
