"""Checks that the tapped call reaches the headphones exactly once.

The operator plays a narrowband fixture with `afplay`, turns on "Also restore the other person"
while a call is playing, and records the headphone output to a WAV. The recording is compared
with the fixture: one cross-correlation peak means the call was heard once, so the tapped app
no longer plays its own copy out loud. A second peak is the double the tap must prevent.

The recording itself needs a headphone device and a loopback, so the command reads the WAV a
recording produced. Its arguments are the only inputs, and a fake player and runner cover the
steps a test cannot perform.
"""

import argparse
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import soundfile

from untunnel_tools.measure import FloatArray, dbfs, read_mono
from untunnel_tools.measure.autoroute import append_result
from untunnel_tools.paths import repo_root

AFPLAY = "/usr/bin/afplay"
FIXTURE_SECONDS = 3.0
FIXTURE_RATE = 48_000
NARROWBAND_LOW_HZ = 300.0
NARROWBAND_HIGH_HZ = 1_200.0
FIXTURE_PEAK = 0.5
RANDOM_SEED = 7
AUDIBLE_DB = -12.0
SEPARATION_SECONDS = 0.05
RELATIVE_FIXTURE = Path("recordings") / "no-double-fixture.wav"
RESULTS = Path("docs") / "results.md"


@dataclass(frozen=True)
class Copy:
    """One place the fixture was heard in the recording."""

    lag_seconds: float
    relative_db: float


@dataclass(frozen=True)
class NoDoubleReport:
    """Every audible copy of the fixture the recording holds."""

    copies: tuple[Copy, ...]

    @property
    def passes(self) -> bool:
        """Whether the call was heard exactly once."""
        return len(self.copies) == 1


def narrowband_program(
    sample_rate: int = FIXTURE_RATE,
    seconds: float = FIXTURE_SECONDS,
) -> FloatArray:
    """Return band-limited noise with one sharp correlation peak.

    A tone would correlate with itself at every period, so the fixture is noise kept inside
    the band a call keeps; the fixed seed makes every run measure the same signal.
    """
    count = round(sample_rate * seconds)
    noise = np.random.default_rng(RANDOM_SEED).standard_normal(count)
    spectrum = np.fft.rfft(noise)
    frequencies = np.fft.rfftfreq(count, 1 / sample_rate)
    spectrum[(frequencies < NARROWBAND_LOW_HZ) | (frequencies > NARROWBAND_HIGH_HZ)] = 0
    band = np.asarray(np.fft.irfft(spectrum, count), dtype=np.float64)
    peak = float(np.max(np.abs(band)))
    return band * (FIXTURE_PEAK / peak)


def write_fixture(path: Path) -> None:
    """Write the fixture as the WAV `afplay` plays."""
    path.parent.mkdir(parents=True, exist_ok=True)
    soundfile.write(str(path), narrowband_program(), FIXTURE_RATE, subtype="FLOAT")


def find_copies(
    reference: FloatArray,
    recording: FloatArray,
    sample_rate: int,
    audible_db: float = AUDIBLE_DB,
) -> NoDoubleReport:
    """Return the audible copies of the fixture in the recording, loudest first.

    Each copy is the fixture played once, so a tap that leaves the app's own playback on adds
    a second peak. Peaks closer than fifty milliseconds are one copy, because the correlation
    of noise wobbles around its maximum.
    """
    if sample_rate != FIXTURE_RATE:
        message = (
            f"the recording is {sample_rate} Hz; record the headphone output at {FIXTURE_RATE} Hz"
        )
        raise ValueError(message)
    if len(reference) == 0 or len(recording) < len(reference):
        return NoDoubleReport(copies=())
    gain = cross_correlation(reference, recording) / float(np.dot(reference, reference))
    separation = max(1, round(SEPARATION_SECONDS * sample_rate))
    picked: list[Copy] = []
    for index in np.argsort(np.abs(gain))[::-1]:
        if dbfs(float(abs(gain[index]))) < audible_db:
            break
        if any(
            abs(int(index) - round(copy.lag_seconds * sample_rate)) < separation for copy in picked
        ):
            continue
        picked.append(
            Copy(lag_seconds=int(index) / sample_rate, relative_db=dbfs(float(abs(gain[index]))))
        )
    return NoDoubleReport(copies=tuple(picked))


def cross_correlation(reference: FloatArray, recording: FloatArray) -> FloatArray:
    """Return the correlation of the recording with the fixture at every offset it fits.

    The transform is padded past both lengths, so the circular result holds no wrap-around and
    the slice is the same as a direct correlation at each whole-sample offset.
    """
    count = len(recording) - len(reference) + 1
    size = 1 << (len(recording) + len(reference) - 1).bit_length()
    spectrum = np.fft.rfft(recording, size) * np.conj(np.fft.rfft(reference, size))
    full = np.fft.irfft(spectrum, size)
    return np.ascontiguousarray(full[:count])


def play_fixture(fixture: Path) -> int:
    """Start `afplay` on the fixture and return the process id the app must tap."""
    # The fixture path comes from the repository root and no shell reads it.
    player = subprocess.Popen(  # noqa: S603
        [AFPLAY, str(fixture)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return player.pid


def run(arguments: list[str]) -> int:
    """Run the double-playback check and return a process status."""
    parser = _parser()
    args = parser.parse_args(arguments)
    root = repo_root(Path(__file__))
    if args.play:
        return _play(root)
    if args.recording is None:
        parser.error("pass --play to play the fixture or --recording to analyse a recording")
    try:
        reference = narrowband_program()
        samples, sample_rate = read_mono(_resolve(root, Path(args.recording)))
        report = find_copies(reference, samples, sample_rate)
    except (OSError, RuntimeError, ValueError) as error:
        sys.stderr.write(f"no-double: {error}\n")
        return 2

    append_result(
        root / RESULTS,
        "no-double",
        passed=report.passes,
        detail="copies "
        + ", ".join(
            f"{copy.lag_seconds:.3f} s at {copy.relative_db:.1f} dB" for copy in report.copies
        ),
    )
    for copy in report.copies:
        sys.stdout.write(f"Copy at {copy.lag_seconds:.3f} s: {copy.relative_db:.1f} dB\n")
    if report.passes:
        sys.stdout.write("PASS: the call was heard once and nothing played it twice\n")
        return 0
    if not report.copies:
        sys.stderr.write("no-double: the recording holds no audible copy of the fixture\n")
    else:
        sys.stderr.write(f"no-double: the fixture was heard {len(report.copies)} times\n")
    return 1


def _play(root: Path) -> int:
    fixture = root / RELATIVE_FIXTURE
    write_fixture(fixture)
    pid = play_fixture(fixture)
    sys.stdout.write(f"Playing {fixture} as process {pid}\n")
    sys.stdout.write("Turn on 'Also restore the other person', then record the headphone output\n")
    return 0


def _resolve(root: Path, path: Path) -> Path:
    return path if path.is_absolute() else root / path


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Check that a tapped call reaches the headphones once.",
        epilog=(
            "The capture step needs headphones and a loopback; record the headphone output "
            "to a WAV and pass it with --recording."
        ),
    )
    parser.add_argument("--play", action="store_true", help="play the fixture with afplay")
    parser.add_argument("--recording", help="WAV file of the headphone output")
    return parser


def main() -> None:
    """Run the double-playback check from the command line."""
    root = repo_root(Path(__file__))
    if "--print-root" in sys.argv[1:]:
        sys.stdout.write(f"{root}\n")
        return
    raise SystemExit(run(sys.argv[1:]))


if __name__ == "__main__":
    main()
