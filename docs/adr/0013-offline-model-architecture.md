# ADR-0013: The offline model as published, and how parity with it is proven

Status: Accepted.

## Context

ADR-0010 found that the streaming engine followed an inferred layer graph and rebuilt it to the
published one. The file-mode path had the same defect: `OfflineRestorer` read tensors named
`encoder.conv0` and `tfmamba.n.time.mamba`, hopped every 5 ms over 10 ms frames, and had no
parity test, so it could not load the published checkpoint.

Everything below was read on 2026-11-10 from
`https://huggingface.co/nvidia/NVIDIA-NemotronLabs-RE-USE` at revision
`31f82f2efad1095034492f236e8dac9239ba713b`: `config.json`, the header of `model.safetensors`
(SHA-256 `06badaf4…70e1`), `models/generator_SEMamba_time_d4.py`,
`models/codec_module_time_d4.py`, `models/mamba_block2_SEMamba.py`, `models/stfts.py`,
`utils/util.py`, `inference.py` and `inference_chunk.py`.

## The published model

**Checkpoint.** 1,416 tensors, all `F32`, 9,607,747 values: `dense_encoder`, `TSMamba.0` to
`TSMamba.29`, `mask_decoder` and `phase_decoder`. `config.json` sets 30 blocks, 64 channels,
Mamba state 16, convolution 4, expansion 4 and normalisation epsilon 1e-5.

**Transform.** 40 ms frames every 5 ms at every rate: 320 and 40 samples at the 8 kHz base,
scaled by the rate and rounded up to even. Centred, reflection padded, periodic Hann window,
`log1p` magnitude and phase, the same as the streaming model apart from the lengths.

**Encoder.** Two zero bins and two zero frames are appended. A 1x1 convolution widens
magnitude and phase to 64 channels, a dense block of four 3x3 layers with time dilations 1,
2, 4 and 8 follows, padded by the dilation on both sides of time, and a 1x3 convolution that
steps four frames and two bins without padding reduces the map. Every layer is followed by
instance normalisation over the whole map, the appended frames and bins included, and a
PReLU.

**Blocks.** Each of the 30 blocks runs a time branch, one sequence per bin, then a frequency
branch, one sequence per frame; each branch is `x + norm(linear([fw(x) + x, bw(x) + x]))`
with separately trained forward and backward Mambas starting from a zero state.

**Decoders.** A dense block, a 1x3 convolution to 128 channels that become two neighbouring
bins (channel `64j + c` to bin `2w + j`), a convolution of three taps along time to 256
channels that become four consecutive frames, each with instance normalisation and a PReLU,
then 1x1 readouts: one for the magnitude and two whose `atan2` is the phase. The maps are
cut back to the spectrum's frames and bins.

**Inference.** `inference.py` clears every frame in which more than half of the bins'
magnitudes are not positive, inverts the transform with `torch.istft` and pads the output to
the input's length with 1e-8.

## Decision

Rebuild the offline path under `Sources/UntunnelEngine/Offline` to that graph, read the
checkpoint by its published names (`OfflineModelLayout` lists every tensor), and reuse the
streaming engine's convolution, recurrence and branch head. Instance normalisation and the
bidirectional sweeps need the whole chunk, so the offline layers work on whole maps rather
than frame by frame.

**Reference outputs.** `tools/reference/offline_goldens.py` downloads the publisher's code at
the pinned revision, checks each file's SHA-256, and follows `inference.py`'s per-file steps
on the CPU with the plain PyTorch Mamba of `realtime_goldens.py`. It writes
`fixtures/model/offline-goldens.*`: four inputs at 8, 16, 24 and 48 kHz with the publisher's
analysed frames and waveform, the encoder, blocks 0, 1, 14, 15, 28 and 29 and both decoder
outputs for a 0.1 s input at 8 kHz, and for every golden the publisher's own sensitivity to a
perturbation of one part in a million. No weights are stored.

**Tests.** `OfflineIntermediateParity` checks that the layout names every tensor of the
published checkpoint, and drives the encoder, blocks 0, 1, 15 and 29 and both decoders with
the reference input of each and compares to 1e-4. `OfflineGoldenParity` restores each golden
whole from the publisher's frames, from this engine's transform with the first frame's
branch-cut signs taken from the reference (ADR-0010, "Phase"), and from samples; it holds
the first two to 1e-3 at every sample and more than 50 dB, checks the third for alignment,
and records all three in `docs/bench.md`. Both suites read the checkpoint from where
`untunnel download --offline-model` stores it, or from `UNTUNNEL_OFFLINE_CHECKPOINT`, and are
skipped without it.

## Licences

- **Weights and the publisher's code**: the model card and the repository's `LICENSE` name
  OpenMDW-1.1, and the card says the model is ready for commercial use. This record does not
  interpret those terms.
- **This repository** stores none of the publisher's files and none of the weights; the
  Swift engine is written from the architecture and copies no source text.

## Consequences

- Each layer of a chunk normalises over the whole chunk, so memory grows with its length.
  The encoder's dense block alone holds `(frames + 18) x (bins + 4) x 256` floats, about
  216 MB per second of audio at 48 kHz, so the chunk length is a memory budget as well as a
  quality choice.
- `ChunkedInference` weights each chunk with a Hann window and divides by the summed weights,
  matching the publisher's overlap-add method. Model parity covers single chunks.
- CI downloads this checkpoint beside the streaming one and caches both under the hash of
  the two fixture manifests.
