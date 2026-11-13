"""The systems the benchmark compares: two references and four external restorers.

The degraded input and spectral folding run in process. Untunnel, the offline model, AP-BWE
and DeepFilterNet3 are programs that read one WAV file and write another, so each is a command
template; `{input}`, `{output}`, `{output_directory}` and `{tier}` are filled in per call.
"""

import subprocess
import tempfile
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import soundfile

from untunnel_tools import paths
from untunnel_tools.eval.simulate_hfp import REFERENCE_RATE, Condition, resample
from untunnel_tools.measure import FloatArray

# Fixed before any benchmark run; no utterance in either list was used to choose it.
FOLD_GAIN_DB = -12.0
INPUT_KEY = "input"
FOLDING_KEY = "folding"
AUTO_TIER = "auto"
AP_BWE_RATE = 16_000
FULL_BAND_RATE = 48_000

type Process = Callable[[FloatArray, Condition], FloatArray]

UNTUNNEL_COMMAND = (
    "untunnel",
    "enhance",
    "{input}",
    "{output}",
    "--model",
    "streaming",
    "--tier",
    "{tier}",
)
OFFLINE_COMMAND = (
    "untunnel",
    "enhance",
    "{input}",
    "{output}",
    "--model",
    "offline",
    "--bwe",
    str(FULL_BAND_RATE),
)
AP_BWE_COMMAND = (
    "env",
    "PYTHONPATH=.cache/eval/ap-bwe",
    "python",
    ".cache/eval/ap-bwe/inference/inference_16k.py",
    "--input_wavs_dir",
    "{input_directory}",
    "--output_dir",
    "{output_directory}",
    "--checkpoint_file",
    ".cache/eval/ap-bwe-g_16kto48k",
)
DEEP_FILTER_COMMAND = ("deep-filter", "-D", "-o", "{output_directory}", "{input}")


@dataclass(frozen=True)
class System:
    """A named way to restore degraded speech into a 48 kHz signal."""

    key: str
    label: str
    process: Process


def upsample_input(samples: FloatArray, condition: Condition) -> FloatArray:
    """Return the degraded signal at 48 kHz with nothing added."""
    return resample(samples, condition.sample_rate, REFERENCE_RATE)


def spectral_folding(samples: FloatArray, bandwidth_hz: int) -> FloatArray:
    """Mirror the band below `bandwidth_hz` into the octave above it at a fixed gain.

    Multiplying by a carrier at twice the bandwidth turns each frequency f into 2B - f, which
    lands the input's band mirrored between B and 2B. This is the floor any learned bandwidth
    extension has to beat: it adds energy above the input's bandwidth without knowing
    anything about speech.
    """
    time_index = np.arange(len(samples))
    carrier = 2 * np.cos(2 * np.pi * (2 * bandwidth_hz) * time_index / REFERENCE_RATE)
    spectrum = np.fft.rfft(samples * carrier)
    frequencies = np.fft.rfftfreq(len(samples), 1 / REFERENCE_RATE)
    spectrum[(frequencies <= bandwidth_hz) | (frequencies > 2 * bandwidth_hz)] = 0
    mirrored = np.asarray(np.fft.irfft(spectrum, len(samples)), dtype=np.float64)
    return samples + 10 ** (FOLD_GAIN_DB / 20) * mirrored


def run_command_system(
    template: tuple[str, ...], samples: FloatArray, input_rate: int, tier: str | None = None
) -> FloatArray:
    """Run a file-to-file restorer and return its output at 48 kHz."""
    with tempfile.TemporaryDirectory() as folder:
        root = Path(folder)
        input_directory = root / "input"
        output_directory = root / "output"
        input_directory.mkdir()
        output_directory.mkdir()
        source = input_directory / "utterance.wav"
        result = output_directory / "utterance.wav"
        soundfile.write(str(source), samples, input_rate, subtype="PCM_16")
        values = {
            "{input}": str(source),
            "{input_directory}": str(input_directory),
            "{output}": str(result),
            "{output_directory}": str(output_directory),
            "{tier}": tier or "",
        }
        arguments = [_fill(argument, values) for argument in template]
        # The template comes from this module or the operator's own command line, and
        # no shell interprets it.
        completed = subprocess.run(  # noqa: S603
            arguments, check=False, capture_output=True, text=True
        )
        if completed.returncode != 0:
            message = (
                f"baselines: {arguments[0]} exited {completed.returncode}: "
                f"{completed.stderr.strip()}"
            )
            raise RuntimeError(message)
        if not result.is_file():
            message = f"baselines: {arguments[0]} wrote no {result.name} in its output directory."
            raise FileNotFoundError(message)
        restored, rate = soundfile.read(str(result), dtype="float64", always_2d=True)
    return resample(np.asarray(restored.mean(axis=1), dtype=np.float64), int(rate), REFERENCE_RATE)


def _fill(argument: str, values: dict[str, str]) -> str:
    for placeholder, value in values.items():
        argument = argument.replace(placeholder, value)
    return argument


def command_system(
    key: str,
    label: str,
    template: tuple[str, ...],
    input_rate: int | None,
    tier: str | None = None,
) -> System:
    """Wrap a command template; `input_rate` None passes the condition's own rate through."""

    def process(samples: FloatArray, condition: Condition) -> FloatArray:
        rate = input_rate or condition.sample_rate
        return run_command_system(
            template, resample(samples, condition.sample_rate, rate), rate, tier
        )

    return System(key, label, process)


def folding_system() -> System:
    """Build the spectral folding floor, folded at each condition's bandwidth."""

    def process(samples: FloatArray, condition: Condition) -> FloatArray:
        return spectral_folding(upsample_input(samples, condition), condition.bandwidth_hz)

    return System(FOLDING_KEY, "Spectral folding", process)


def input_system() -> System:
    """Build the degraded input system: upsampled and nothing else."""
    return System(INPUT_KEY, "Degraded input", upsample_input)


def tier_key(tier: str) -> str:
    """Name an Untunnel system after its tier, such as untunnel-48000-8-2."""
    return "untunnel-" + tier.replace(":", "-")


def default_systems(
    tiers: tuple[str, ...], overrides: dict[str, tuple[str, ...]], auto_tier: str
) -> tuple[System, ...]:
    """Build every system: the auto tier, each listed tier, then the other baselines."""
    commands = {
        "untunnel": UNTUNNEL_COMMAND,
        "offline": OFFLINE_COMMAND,
        "ap-bwe": AP_BWE_COMMAND,
        "deepfilternet3": DEEP_FILTER_COMMAND,
    } | overrides
    untunnel = tuple(
        command_system(
            tier_key(tier),
            f"Untunnel, tier {tier}",
            commands["untunnel"],
            FULL_BAND_RATE,
            auto_tier if tier == AUTO_TIER else tier,
        )
        for tier in (AUTO_TIER, *tiers)
    )
    return (
        input_system(),
        folding_system(),
        *untunnel,
        command_system("offline", "Offline OpenMDW model", commands["offline"], FULL_BAND_RATE),
        command_system("ap-bwe", "AP-BWE", commands["ap-bwe"], AP_BWE_RATE),
        command_system(
            "deepfilternet3", "DeepFilterNet3", commands["deepfilternet3"], FULL_BAND_RATE
        ),
    )


# Shared with the other tool modules so `--print-root` works from each of them.
main = paths.main
repo_root = paths.repo_root

if __name__ == "__main__":
    main()
