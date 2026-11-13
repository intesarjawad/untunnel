# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = [
#     "einops==0.8.2",
#     "huggingface-hub==2.4.0",
#     "numpy==2.5.4",
#     "safetensors==0.8.0",
#     "soundfile==0.14.0",
#     "soxr==1.1.0",
#     "torch==2.15.0",
# ]
# ///
"""Write the real-time model's reference outputs from the publisher's own inference code.

Run from the repository root, after `untunnel download`:

    uv run tools/reference/realtime_goldens.py

The publisher's model and streaming code are fetched at the pinned revision, checked against
the hashes below and executed unchanged; none of it is stored in this repository. Their code
needs the CUDA build of `mamba_ssm`, which does not exist for macOS, so `Mamba` below supplies
the same block in plain PyTorch. `--validate` measures that substitution against the enhanced
recording the publisher ships next to the model.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
import types
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
import soundfile
import soxr
import torch
import torch.nn.functional as F  # noqa: N812
from safetensors.numpy import save_file
from safetensors.torch import load_file
from torch import nn

REPOSITORY = "nvidia/Real-time_RE-USE"
REVISION = "4c0c186272ca853cd18d832fc5c28777b62f32d1"
CHECKPOINT_SHA256 = "6eac4e8cc721f99a22cde7eac3c9f8e2826ced5dc8a4234fd1977de1ec0d3ade"
UPSTREAM_SHA256 = {
    "config.json": "7c46c3279c4edbb3ae9b190905f90683f8db6ec38dea45da007e87b7d8b5621d",
    "models/stfts.py": "7bd63bb6f4a055fbd7c75e712e47c3c3923c15c969fb1ae6f3c2f2b6c15911a0",
    "models/streaming_codec_module_time_d1_input_ahead_sep_conv.py": (
        "96b23a9efcb43de06a2b7f08d536e2f12ada940402f1b61a0505347e911470f2"
    ),
    "models/streaming_generator_SEMamba_time_d1_random_layer_ahead_sep_conv.py": (
        "838f8d50ebeedd97d1ad5dc3e43f53591a06d76c78b8e6552cf49f5b17a9405a"
    ),
    "models/streaming_mamba_block2_SEMamba.py": (
        "86026a8b987b33749c3ea3e71bfb83fe81c658ec51eb9392fb5fa814da7b08eb"
    ),
    "online_inference.py": "49dc7f57798c0f89f19c6f70ac4835b9e9efd43d02de499f02ed01450c7a6d4f",
    "noisy_audio/mic_test.wav": "dd54fe1decefe2e5c11c489f3d3d5b0e567bdd840f71bf4007cbe6349194f794",
    "enhanced_audio/online_enhanced_mic_test.flac": (
        "fe038f9f531b60bf3e15f2660cf4bfc287a0d889e0e99f2ccca6a54203abb08f"
    ),
}
# The publisher's script wraps its streaming classes in these two comment lines; only the code
# between them runs here, because the rest of that file requires CUDA at import.
STREAMING_SECTION = ("modification start", "modification end")
SHIPPED_PAIR = {"exit_layer": 8, "look_ahead": 0}

# A LibriVox reading, dedicated to the public domain; the model suppresses anything that is
# not speech, so a synthetic signal would compare near-silent outputs.
SPEECH = {
    "url": (
        "https://archive.org/download/short_poetry_001_librivox/"
        "because_I_could_not_stop_for_death_dickinson_64kb.mp3"
    ),
    "sha256": "641ad9e73d10e7bd928f590381e41ba79e6f3200621792aa0bf4e559ca1b43e8",
    "licence": "http://creativecommons.org/licenses/publicdomain/",
    "start_seconds": 11.0,
}

# Phase jumps at +-pi and is arbitrary in an empty bin, so the model's input, and with it the
# output, follows the last bit of the transform's arithmetic. A seeded noise floor under every
# golden input keeps each bin defined, and `perturbed_rerun` in the manifest measures how far
# the publisher's own output still moves when the input changes by `PERTURBATION`.
NOISE_FLOOR = 3e-3
PERTURBATION = 1e-6
INTERMEDIATE_FRAMES = 8
INTERMEDIATE_CASE = {"sample_rate": 8_000, "exit_layer": 12, "look_ahead": 0, "seconds": 0.2}
OUTPUT_STEM = "fixtures/model/realtime-goldens"
# The repository's hooks refuse files above 1 MiB, so the arrays are spread over several.
PART_BYTES = 1_000_000


@dataclass(frozen=True)
class Case:
    """One input and the model configuration it is restored with."""

    name: str
    sample_rate: int
    seconds: float
    exit_layer: int
    look_ahead: int


CASES = (
    Case("speech-16k-exit4", 16_000, 1.0, 4, 0),
    Case("speech-48k-exit6-ahead1", 48_000, 0.8, 6, 1),
    Case("speech-16k-exit8", 16_000, 3.0, 8, 0),
    Case("speech-24k-exit12-ahead2", 24_000, 2.0, 12, 2),
    Case("speech-8k-exit3", 8_000, 2.0, 3, 0),
)


class Mamba(nn.Module):
    """The Mamba block of `mamba_ssm` 1.x in plain PyTorch, with the same parameter names.

    Written from the recurrence the Mamba paper and that project's reference scan define:
    `h = exp(dt * A) * h + dt * B * x`, `y = h . C + D * x`, gated by `silu(z)`.
    """

    def __init__(self, d_model: int, d_state: int = 16, d_conv: int = 4, expand: int = 2) -> None:
        super().__init__()
        self.d_inner = expand * d_model
        self.d_state = d_state
        self.d_conv = d_conv
        self.dt_rank = math.ceil(d_model / 16)
        self.in_proj = nn.Linear(d_model, 2 * self.d_inner, bias=False)
        self.conv1d = nn.Conv1d(
            self.d_inner, self.d_inner, d_conv, groups=self.d_inner, padding=d_conv - 1
        )
        self.x_proj = nn.Linear(self.d_inner, self.dt_rank + 2 * d_state, bias=False)
        self.dt_proj = nn.Linear(self.dt_rank, self.d_inner)
        self.A_log = nn.Parameter(torch.zeros(self.d_inner, d_state))
        self.D = nn.Parameter(torch.zeros(self.d_inner))
        self.out_proj = nn.Linear(self.d_inner, d_model, bias=False)

    def allocate_inference_cache(
        self, batch_size: int, max_seqlen: int
    ) -> tuple[torch.Tensor, torch.Tensor]:
        """Return a zero convolution history and a zero recurrence state."""
        del max_seqlen
        return (
            torch.zeros(batch_size, self.d_inner, self.d_conv),
            torch.zeros(batch_size, self.d_inner, self.d_state),
        )

    def _advance(
        self, convolved: torch.Tensor, gate: torch.Tensor, state: torch.Tensor
    ) -> tuple[torch.Tensor, torch.Tensor]:
        signal = F.silu(convolved)
        step, drive, readout = torch.split(
            self.x_proj(signal), [self.dt_rank, self.d_state, self.d_state], dim=-1
        )
        step = F.softplus(self.dt_proj(step))
        decay = torch.exp(step.unsqueeze(-1) * -torch.exp(self.A_log))
        state = state * decay + (step * signal).unsqueeze(-1) * drive.unsqueeze(1)
        output = (state * readout.unsqueeze(1)).sum(-1) + self.D * signal
        return self.out_proj(output * F.silu(gate)), state

    def forward(self, hidden: torch.Tensor) -> torch.Tensor:
        """Run a whole `[batch, length, d_model]` sequence from a zero state."""
        batch, length, _ = hidden.shape
        signal, gate = self.in_proj(hidden).chunk(2, dim=-1)
        convolved = self.conv1d(signal.transpose(1, 2))[..., :length].transpose(1, 2)
        state = hidden.new_zeros(batch, self.d_inner, self.d_state)
        outputs: list[torch.Tensor] = []
        for index in range(length):
            output, state = self._advance(convolved[:, index], gate[:, index], state)
            outputs.append(output)
        return torch.stack(outputs, dim=1)

    def step(
        self, hidden: torch.Tensor, conv_state: torch.Tensor, ssm_state: torch.Tensor
    ) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        """Advance every `[batch, 1, d_model]` row by one position."""
        signal, gate = self.in_proj(hidden.squeeze(1)).chunk(2, dim=-1)
        conv_state = torch.cat([conv_state[:, :, 1:], signal.unsqueeze(-1)], dim=-1)
        convolved = (conv_state * self.conv1d.weight.squeeze(1)).sum(-1) + self.conv1d.bias
        output, ssm_state = self._advance(convolved, gate, ssm_state)
        return output.unsqueeze(1), conv_state, ssm_state


def sha256(path: Path) -> str:
    """Return the hex digest of a file."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fetch(url: str, path: Path, expected: str) -> Path:
    """Download a pinned file once and verify its hash."""
    if not path.is_file():
        path.parent.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(url) as response:  # noqa: S310
            path.write_bytes(response.read())
    actual = sha256(path)
    if actual != expected:
        message = f"{path} has SHA-256 {actual}, expected {expected}; delete it and rerun"
        raise SystemExit(message)
    return path


def fetch_upstream(cache: Path) -> Path:
    """Download the pinned upstream files and return the directory that holds them."""
    root = cache / REVISION
    for name, expected in UPSTREAM_SHA256.items():
        fetch(
            f"https://huggingface.co/{REPOSITORY}/resolve/{REVISION}/{name}", root / name, expected
        )
    return root


def load_models(upstream: Path, checkpoint: Path) -> tuple[Any, Any, dict[str, Any], Any]:
    """Build the publisher's model and streaming wrapper around the pinned weights."""
    actual = sha256(checkpoint)
    if actual != CHECKPOINT_SHA256:
        message = f"{checkpoint} has SHA-256 {actual}, expected {CHECKPOINT_SHA256}"
        raise SystemExit(message)

    substitute = types.ModuleType("mamba_ssm")
    substitute.Mamba = Mamba  # type: ignore[attr-defined]
    sys.modules["mamba_ssm"] = substitute
    sys.path.insert(0, str(upstream))
    from models import stfts  # noqa: PLC0415
    from models.streaming_generator_SEMamba_time_d1_random_layer_ahead_sep_conv import (  # noqa: PLC0415
        SEMamba_decoder_list,
    )

    config = json.loads((upstream / "config.json").read_text(encoding="utf-8"))
    model = SEMamba_decoder_list(config)
    model.load_state_dict(load_file(checkpoint), strict=True)
    model.eval()

    source = (upstream / "online_inference.py").read_text(encoding="utf-8")
    section = source.split(STREAMING_SECTION[0], 1)[1].split(STREAMING_SECTION[1], 1)[0]
    namespace: dict[str, Any] = {"torch": torch, "nn": nn, "F": F}
    exec(compile(section, "online_inference.py", "exec"), namespace)  # noqa: S102
    streaming = namespace["StreamingSEMamba"](model).eval()
    return model, streaming, config, stfts


def make_even(value: float) -> int:
    """Round to the nearest even integer, as the publisher scales its transform."""
    rounded = round(value)
    return rounded if rounded % 2 == 0 else rounded + 1


def transform_sizes(config: dict[str, Any], sample_rate: int) -> tuple[int, int, int]:
    """Return the FFT, hop and window lengths the publisher uses at this rate."""
    stft = config["stft_cfg"]
    base = stft["sampling_rate"]
    return (
        make_even(stft["n_fft"] * sample_rate // base),
        make_even(stft["hop_size"] * sample_rate // base),
        make_even(stft["win_size"] * sample_rate // base),
    )


@dataclass
class Restored:
    """What one streamed pass produced."""

    waveform: np.ndarray
    offline_difference: float
    taps: dict[str, list[torch.Tensor]]
    magnitudes: torch.Tensor
    phases: torch.Tensor


def restore(  # noqa: PLR0913
    bundle: tuple[Any, Any, dict[str, Any], Any],
    waveform: np.ndarray,
    sample_rate: int,
    exit_layer: int,
    look_ahead: int,
    *,
    tap: bool = False,
) -> Restored:
    """Follow the publisher's online loop: one frame in, one frame out."""
    model, streaming, config, stfts = bundle
    n_fft, hop, window = transform_sizes(config, sample_rate)
    compress = config["model_cfg"]["compress_factor"]
    noisy = torch.from_numpy(waveform).unsqueeze(0)
    magnitudes, phases, _ = stfts.mag_phase_stft(noisy, n_fft, hop, window, compress)

    offline_magnitude, offline_phase, _ = model(magnitudes, phases, exit_layer, look_ahead)
    empty = (torch.expm1(torch.relu(offline_magnitude)) == 0).float().mean(1) > 0.5  # noqa: PLR2004
    offline_magnitude[:, :, empty[0]] = 0
    offline = stfts.mag_phase_istft(offline_magnitude, offline_phase, n_fft, hop, window, compress)

    taps: dict[str, list[torch.Tensor]] = {}
    hooks = []
    if tap:
        modules = {"encoder": streaming.encoder}
        modules |= {f"block{index}": streaming.mamba[index] for index in range(exit_layer)}
        modules["magnitude"] = streaming.mag_decoder_list[exit_layer - 1]
        modules["phase"] = streaming.pha_decoder_list[exit_layer - 1]
        for name, module in modules.items():
            store = taps.setdefault(name, [])
            hooks.append(
                module.register_forward_hook(
                    lambda _module, _inputs, output, store=store: store.append(output.detach())
                )
            )

    streaming.reset(magnitudes.shape[1] // 2 + 1)
    padding = torch.zeros(1, magnitudes.shape[1], look_ahead)
    padded_magnitudes = torch.cat([magnitudes, padding], dim=-1)
    padded_phases = torch.cat([phases, padding], dim=-1)
    first = look_ahead + 1
    magnitude, phase = streaming(
        padded_magnitudes[:, :, :first], padded_phases[:, :, :first], exit_layer, look_ahead
    )
    out_magnitudes, out_phases = [magnitude], [phase]
    for frame in range(first, padded_magnitudes.shape[-1]):
        magnitude, phase = streaming(
            padded_magnitudes[:, :, frame : frame + 1],
            padded_phases[:, :, frame : frame + 1],
            exit_layer,
            look_ahead,
        )
        if (torch.expm1(torch.relu(magnitude)) == 0).float().mean().item() > 0.5:  # noqa: PLR2004
            magnitude = 0 * magnitude
        out_magnitudes.append(magnitude)
        out_phases.append(phase)
    for hook in hooks:
        hook.remove()

    online = stfts.mag_phase_istft(
        torch.stack(out_magnitudes, dim=-1),
        torch.stack(out_phases, dim=-1),
        n_fft,
        hop,
        window,
        compress,
    )
    length = min(online.shape[-1], offline.shape[-1])
    return Restored(
        waveform=online[0].numpy().astype(np.float32),
        offline_difference=float((online[0, :length] - offline[0, :length]).abs().max()),
        taps=taps,
        magnitudes=magnitudes,
        phases=phases,
    )


def speech_signal(cache: Path, sample_rate: int, seconds: float) -> np.ndarray:
    """Return an excerpt of the pinned recording, mixed to mono, at the requested rate."""
    url = str(SPEECH["url"])
    path = fetch(url, cache / "speech" / url.rsplit("/", 1)[1], str(SPEECH["sha256"]))
    samples, native_rate = soundfile.read(path, dtype="float32", always_2d=True)
    start = round(float(SPEECH["start_seconds"]) * native_rate)
    excerpt = samples[start : start + round(seconds * native_rate)].mean(axis=1)
    if native_rate != sample_rate:
        excerpt = soxr.resample(excerpt, native_rate, sample_rate, quality="VHQ")
    return np.ascontiguousarray(excerpt[: round(sample_rate * seconds)], dtype=np.float32)


def difference_snr_db(reference: np.ndarray, candidate: np.ndarray) -> float:
    """Return the reference power over the power of the difference, in decibels."""
    noise = float(np.sum((reference - candidate) ** 2))
    return 10 * math.log10(float(np.sum(reference**2)) / noise)


def validate(bundle: tuple[Any, Any, dict[str, Any], Any], upstream: Path) -> dict[str, Any]:
    """Reproduce the enhanced recording the publisher ships and measure the difference."""
    noisy, sample_rate = soundfile.read(upstream / "noisy_audio/mic_test.wav", dtype="float32")
    shipped, _ = soundfile.read(
        upstream / "enhanced_audio/online_enhanced_mic_test.flac", dtype="float32"
    )
    restored = restore(bundle, noisy, sample_rate, **SHIPPED_PAIR)
    length = min(len(shipped), len(restored.waveform))
    return {
        "input": "noisy_audio/mic_test.wav",
        "reference": "enhanced_audio/online_enhanced_mic_test.flac",
        "reference_bit_depth": 16,
        "sample_rate": sample_rate,
        **SHIPPED_PAIR,
        "difference_snr_db": round(
            difference_snr_db(shipped[:length], restored.waveform[:length]), 2
        ),
        "maximum_difference": float(np.abs(shipped[:length] - restored.waveform[:length]).max()),
        "online_offline_maximum_difference": restored.offline_difference,
    }


def frame_major(spectrum: torch.Tensor) -> np.ndarray:
    """Turn a `[1, bins, frames]` spectrum into `[frames, bins]`."""
    return spectrum[0].transpose(0, 1).contiguous().numpy()


def bin_major(feature_map: torch.Tensor) -> np.ndarray:
    """Turn one `[1, channels, 1, bins]` frame into `[bins, channels]`."""
    return feature_map[0, :, 0, :].transpose(0, 1).contiguous().numpy().astype(np.float32)


def intermediates(
    bundle: tuple[Any, Any, dict[str, Any], Any], cache: Path
) -> tuple[dict[str, Any], dict[str, np.ndarray]]:
    """Dump every block boundary for the first frames of a speech stream."""
    case = INTERMEDIATE_CASE
    signal = speech_signal(cache, case["sample_rate"], case["seconds"])
    restored = restore(
        bundle, signal, case["sample_rate"], case["exit_layer"], case["look_ahead"], tap=True
    )
    frames = range(INTERMEDIATE_FRAMES)
    tensors = {
        "intermediates.input.magnitude": frame_major(restored.magnitudes)[:INTERMEDIATE_FRAMES],
        "intermediates.input.phase": frame_major(restored.phases)[:INTERMEDIATE_FRAMES],
    }
    for name, outputs in restored.taps.items():
        tensors[f"intermediates.{name}"] = np.stack([bin_major(outputs[index]) for index in frames])
    manifest = {
        "sample_rate": case["sample_rate"],
        "exit_layer": case["exit_layer"],
        "look_ahead": case["look_ahead"],
        "frames": INTERMEDIATE_FRAMES,
        "layout": "input: [frame, bin]; every other tensor: [frame, bin, channel]",
        "tensors": sorted(tensors),
    }
    return manifest, tensors


def pack(tensors: dict[str, np.ndarray]) -> list[dict[str, np.ndarray]]:
    """Group the arrays, in name order, into files that stay under `PART_BYTES`."""
    parts: list[dict[str, np.ndarray]] = [{}]
    used = 0
    for name in sorted(tensors):
        size = tensors[name].nbytes
        if parts[-1] and used + size > PART_BYTES:
            parts.append({})
            used = 0
        parts[-1][name] = tensors[name]
        used += size
    return parts


def main() -> None:
    """Generate the fixtures, or only validate the substitution with `--validate`."""
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--checkpoint",
        type=Path,
        default=Path.home()
        / "Library/Application Support/Untunnel/models"
        / f"{REPOSITORY}@{REVISION}"
        / "model.safetensors",
        help="the pinned model.safetensors, as `untunnel download` stores it",
    )
    parser.add_argument("--cache", type=Path, default=root / ".cache" / "reference")
    parser.add_argument(
        "--validate",
        action="store_true",
        help="only compare against the publisher's shipped recording; write nothing",
    )
    args = parser.parse_args()

    torch.manual_seed(0)
    torch.set_grad_enabled(False)
    upstream = fetch_upstream(args.cache)
    bundle = load_models(upstream, args.checkpoint)

    validation = validate(bundle, upstream)
    sys.stdout.write(f"shipped pair: {json.dumps(validation)}\n")
    if args.validate:
        return

    intermediate_manifest, tensors = intermediates(bundle, args.cache)
    goldens: list[dict[str, Any]] = []
    for case in CASES:
        noise = np.random.default_rng(case.sample_rate + case.exit_layer)
        speech = speech_signal(args.cache, case.sample_rate, case.seconds)
        signal = (speech + NOISE_FLOOR * noise.standard_normal(len(speech))).astype(np.float32)
        restored = restore(bundle, signal, case.sample_rate, case.exit_layer, case.look_ahead)
        nudged = (signal + PERTURBATION * noise.standard_normal(len(signal))).astype(np.float32)
        rerun = restore(bundle, nudged, case.sample_rate, case.exit_layer, case.look_ahead)
        tensors[f"goldens.{case.name}.input"] = signal
        tensors[f"goldens.{case.name}.output"] = restored.waveform
        tensors[f"goldens.{case.name}.magnitude"] = frame_major(restored.magnitudes)
        tensors[f"goldens.{case.name}.phase"] = frame_major(restored.phases)
        goldens.append(
            {
                "name": case.name,
                "sample_rate": case.sample_rate,
                "exit_layer": case.exit_layer,
                "look_ahead": case.look_ahead,
                "online_offline_maximum_difference": restored.offline_difference,
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
        "generator": "tools/reference/realtime_goldens.py",
        "torch": torch.__version__,
        "device": "cpu",
        "mamba": "plain PyTorch substitute for mamba_ssm.Mamba, defined in the generator",
        "shipped_pair": validation,
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
    sys.stdout.write(f"Wrote {OUTPUT_STEM}.json and {len(parts)} array files\n")


if __name__ == "__main__":
    main()
