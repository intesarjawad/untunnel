# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = [
#     "einops==0.8.2",
#     "huggingface-hub==2.4.0",
#     "numpy==2.5.4",
#     "pyyaml==6.0.3",
#     "safetensors==0.8.0",
#     "soundfile==0.14.0",
#     "soxr==1.1.0",
#     "torch==2.15.0",
# ]
# ///
"""Write the offline model's reference outputs from the publisher's own model code.

Run from the repository root, after `untunnel download --offline-model`:

    uv run tools/reference/offline_goldens.py

The publisher's model code is fetched at the pinned revision, checked against the hashes below
and executed unchanged; none of it is stored in this repository. Its `inference.py` only runs
on CUDA, so `restore` repeats that script's per-file steps on the CPU, calling the publisher's
transform, model and length helper. The Mamba block is the plain PyTorch one the real-time
generator defines and validates against a recording the publisher ships; this checkpoint ships
no enhanced recording to repeat that check with.
"""

from __future__ import annotations

import argparse
import json
import sys
import types
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
import torch
from realtime_goldens import (
    NOISE_FLOOR,
    PART_BYTES,
    PERTURBATION,
    SPEECH,
    Mamba,
    difference_snr_db,
    fetch,
    frame_major,
    pack,
    sha256,
    speech_signal,
    transform_sizes,
)
from safetensors.numpy import save_file
from safetensors.torch import load_file

REPOSITORY = "nvidia/NVIDIA-NemotronLabs-RE-USE"
REVISION = "31f82f2efad1095034492f236e8dac9239ba713b"
CHECKPOINT_SHA256 = "06badaf4029b297f97f7fe48d62990b48d5482608210df577354e0d4e0ed70e1"
UPSTREAM_SHA256 = {
    "config.json": "e69986483774f01893d2727503addc49ef201d19e6e1a266b8d4e971e28c478d",
    "inference.py": "71ccef1b231bd30c85b1cddd85266ef9cdc3216dc85db65e38f89a670ae28236",
    "models/codec_module_time_d4.py": (
        "02bd1d478f36a9b38dce7d44368805298f42798ea239304580f1ccffafe766a0"
    ),
    "models/generator_SEMamba_time_d4.py": (
        "beebaf2d9ab7b83c101f46246ae7a7a8a2d2f57b6683025d3712c64c1b7d6817"
    ),
    "models/mamba_block2_SEMamba.py": (
        "97397af2d7e0f5e6530aa8c4a45b4f0f0030b4b56d8c9922a9b0bc25f8b5962e"
    ),
    "models/stfts.py": "b82383c1ec7d7e9fe9bca1f93b3c0afe9609e191c38efc16f705e7145198d835",
    "utils/util.py": "85960c6eb94033f37f9f77676a0cf2e7285ce12b11c24ba77577fc354766d0bf",
}
# `inference.py` clears every frame whose decompressed magnitude is zero in more than this
# share of its bins, and pads a short output with this value.
EMPTY_FRAME_SHARE = 0.5
LENGTH_PAD_VALUE = 1e-8
# The blocks whose outputs are stored: each tested block's input is the one before it.
TAPPED_BLOCKS = (0, 1, 14, 15, 28, 29)
INTERMEDIATE_CASE = {"sample_rate": 8_000, "seconds": 0.1}
OUTPUT_STEM = "fixtures/model/offline-goldens"


@dataclass(frozen=True)
class Case:
    """One input restored as a whole file."""

    name: str
    sample_rate: int
    seconds: float


# 1.503 s at 16 kHz is not a whole number of hops, so the publisher's length padding is covered.
CASES = (
    Case("speech-8k", 8_000, 2.0),
    Case("speech-16k", 16_000, 1.503),
    Case("speech-24k", 24_000, 1.0),
    Case("speech-48k", 48_000, 0.5),
)


@dataclass(frozen=True)
class Bundle:
    """The publisher's model and the helpers its inference script calls."""

    model: Any
    config: dict[str, Any]
    stfts: Any
    pad_or_trim_to_match: Any


@dataclass
class Restored:
    """What one whole-file pass produced."""

    waveform: np.ndarray
    magnitudes: torch.Tensor
    phases: torch.Tensor
    taps: dict[str, torch.Tensor]


def fetch_upstream(cache: Path) -> Path:
    """Download the pinned upstream files and return the directory that holds them."""
    root = cache / REVISION
    for name, expected in UPSTREAM_SHA256.items():
        fetch(
            f"https://huggingface.co/{REPOSITORY}/resolve/{REVISION}/{name}", root / name, expected
        )
    return root


def load_bundle(upstream: Path, checkpoint: Path) -> Bundle:
    """Build the publisher's model around the pinned weights."""
    actual = sha256(checkpoint)
    if actual != CHECKPOINT_SHA256:
        message = f"{checkpoint} has SHA-256 {actual}, expected {CHECKPOINT_SHA256}"
        raise SystemExit(message)

    substitute = types.ModuleType("mamba_ssm")
    substitute.Mamba = Mamba  # type: ignore[attr-defined]
    sys.modules["mamba_ssm"] = substitute
    sys.path.insert(0, str(upstream))
    from models import stfts  # noqa: PLC0415
    from models.generator_SEMamba_time_d4 import SEMamba  # noqa: PLC0415
    from utils.util import pad_or_trim_to_match  # noqa: PLC0415

    config = json.loads((upstream / "config.json").read_text(encoding="utf-8"))
    model = SEMamba(config)
    model.load_state_dict(load_file(checkpoint), strict=True)
    model.eval()
    return Bundle(model, config, stfts, pad_or_trim_to_match)


def restore(
    bundle: Bundle, waveform: np.ndarray, sample_rate: int, *, tap: bool = False
) -> Restored:
    """Follow the per-file steps of the publisher's `inference.py`."""
    n_fft, hop, window = transform_sizes(bundle.config, sample_rate)
    compress = bundle.config["model_cfg"]["compress_factor"]
    noisy = torch.from_numpy(waveform).unsqueeze(0)
    magnitudes, phases, _ = bundle.stfts.mag_phase_stft(
        noisy, n_fft, hop, window, compress, center=True, addeps=False
    )

    taps: dict[str, torch.Tensor] = {}
    hooks = []
    if tap:
        model = bundle.model
        modules = {"encoder": model.dense_encoder}
        modules |= {f"block{index}": model.TSMamba[index] for index in TAPPED_BLOCKS}
        modules |= {"magnitude": model.mask_decoder, "phase": model.phase_decoder}
        for name, module in modules.items():
            hooks.append(
                module.register_forward_hook(
                    lambda _module, _inputs, output, name=name: taps.__setitem__(
                        name, output.detach()
                    )
                )
            )
    amplitude, phase, _ = bundle.model(magnitudes, phases)
    for hook in hooks:
        hook.remove()

    decompressed = torch.expm1(torch.relu(amplitude))
    empty = torch.sum(decompressed == 0, 1) / decompressed.shape[1] > EMPTY_FRAME_SHARE
    amplitude[:, :, empty[0]] = 0
    restored = bundle.stfts.mag_phase_istft(amplitude, phase, n_fft, hop, window, compress)
    restored = bundle.pad_or_trim_to_match(noisy, restored, pad_value=LENGTH_PAD_VALUE)
    return Restored(
        waveform=restored[0].numpy().astype(np.float32),
        magnitudes=magnitudes,
        phases=phases,
        taps=taps,
    )


def time_major(feature_map: torch.Tensor) -> np.ndarray:
    """Turn a `[1, channels, frames, bins]` map into `[frames, bins, channels]`."""
    return feature_map[0].permute(1, 2, 0).contiguous().numpy().astype(np.float32)


def noisy_speech(cache: Path, sample_rate: int, seconds: float, seed: int) -> np.ndarray:
    """Return the speech excerpt over a seeded noise floor, as the real-time goldens use."""
    speech = speech_signal(cache, sample_rate, seconds)
    noise = np.random.default_rng(seed)
    return (speech + NOISE_FLOOR * noise.standard_normal(len(speech))).astype(np.float32)


def intermediates(bundle: Bundle, cache: Path) -> tuple[dict[str, Any], dict[str, np.ndarray]]:
    """Dump the encoder, the tapped blocks and both decoders for one short file."""
    case = INTERMEDIATE_CASE
    signal = noisy_speech(cache, case["sample_rate"], case["seconds"], seed=case["sample_rate"])
    restored = restore(bundle, signal, case["sample_rate"], tap=True)
    tensors = {
        "intermediates.input.magnitude": frame_major(restored.magnitudes),
        "intermediates.input.phase": frame_major(restored.phases),
    }
    for name, output in restored.taps.items():
        if output.shape[1] == 1:
            tensors[f"intermediates.{name}"] = output[0, 0].numpy().astype(np.float32)
        else:
            tensors[f"intermediates.{name}"] = time_major(output)
    manifest = {
        "sample_rate": case["sample_rate"],
        "blocks": list(TAPPED_BLOCKS),
        "layout": (
            "input: [frame, bin]; encoder and blocks: [frame, bin, channel]; "
            "magnitude and phase: [frame, bin] before cropping"
        ),
        "tensors": sorted(tensors),
    }
    return manifest, tensors


def main() -> None:
    """Generate the fixtures."""
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--checkpoint",
        type=Path,
        default=Path.home()
        / "Library/Application Support/Untunnel/models"
        / f"{REPOSITORY}@{REVISION}"
        / "model.safetensors",
        help="the pinned model.safetensors, as `untunnel download --offline-model` stores it",
    )
    parser.add_argument("--cache", type=Path, default=root / ".cache" / "reference")
    args = parser.parse_args()

    torch.manual_seed(0)
    torch.set_grad_enabled(False)
    bundle = load_bundle(fetch_upstream(args.cache), args.checkpoint)

    intermediate_manifest, tensors = intermediates(bundle, args.cache)
    goldens: list[dict[str, Any]] = []
    for case in CASES:
        signal = noisy_speech(args.cache, case.sample_rate, case.seconds, seed=case.sample_rate)
        restored = restore(bundle, signal, case.sample_rate)
        nudge = np.random.default_rng(case.sample_rate + 1)
        nudged = (signal + PERTURBATION * nudge.standard_normal(len(signal))).astype(np.float32)
        rerun = restore(bundle, nudged, case.sample_rate)
        tensors[f"goldens.{case.name}.input"] = signal
        tensors[f"goldens.{case.name}.output"] = restored.waveform
        tensors[f"goldens.{case.name}.magnitude"] = frame_major(restored.magnitudes)
        tensors[f"goldens.{case.name}.phase"] = frame_major(restored.phases)
        goldens.append(
            {
                "name": case.name,
                "sample_rate": case.sample_rate,
                "perturbed_rerun": {
                    "difference_snr_db": round(
                        difference_snr_db(restored.waveform, rerun.waveform), 2
                    ),
                    "maximum_difference": float(np.abs(restored.waveform - rerun.waveform).max()),
                },
            }
        )
        sys.stdout.write(f"{case.name}: {len(signal)} samples\n")

    manifest = {
        "repository": REPOSITORY,
        "revision": REVISION,
        "checkpoint_sha256": CHECKPOINT_SHA256,
        "upstream_sha256": UPSTREAM_SHA256,
        "generator": "tools/reference/offline_goldens.py",
        "torch": torch.__version__,
        "device": "cpu",
        "mamba": "plain PyTorch substitute for mamba_ssm.Mamba, from realtime_goldens.py",
        "speech": SPEECH,
        "noise_floor": NOISE_FLOOR,
        "perturbation": PERTURBATION,
        "intermediates": intermediate_manifest,
        "goldens": goldens,
    }
    stem = root / OUTPUT_STEM
    stem.parent.mkdir(parents=True, exist_ok=True)
    for stale in stem.parent.glob(f"{stem.name}.*"):
        stale.unlink()
    parts = pack({name: np.ascontiguousarray(v, dtype=np.float32) for name, v in tensors.items()})
    manifest["files"] = [f"{stem.name}.{index}.safetensors" for index in range(len(parts))]
    for name, part in zip(manifest["files"], parts, strict=True):
        save_file(part, stem.parent / name)
    stem.with_suffix(".json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    sys.stdout.write(f"Wrote {OUTPUT_STEM}.json and {len(parts)} array files (<{PART_BYTES} B)\n")


if __name__ == "__main__":
    main()
