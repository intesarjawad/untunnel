# ADR-0010: The real-time model as published, and how parity with it is proven

Status: Accepted.

## Context

The first engine was written before the checkpoint could be loaded. Once
`untunnel download` fetched the pinned file, `untunnel enhance --model streaming` stopped with
"the checkpoint has no tensor 'encoder.conv0.weight'": the engine's layer graph and tensor
names had been inferred, and the inference was wrong. The parity suites did not catch it
because they only ran when a reference dump was present, and none had been generated.

Everything below was read on 2026-11-09 from
`https://huggingface.co/nvidia/Real-time_RE-USE` at revision
`4c0c186272ca853cd18d832fc5c28777b62f32d1`: `config.json`, the header of `model.safetensors`
(SHA-256 `6eac4e8c…3ade`), the four files under `models/`, and `online_inference.py`.

## The published model

**Checkpoint.** 1,318 tensors, all `F32`, 13,475,815 values. Top-level groups:
`dense_encoder`, `TSMamba.0` to `TSMamba.11`, `mask_decoder_list.0` to `.11`,
`phase_decoder_list.0` to `.11`, and one `mask_decoder` and `phase_decoder` that the forward
pass never calls. Every hidden width is 64.

**Transform.** Periodic Hann window of 40 ms, hop of 20 ms, FFT size equal to the window, at
every sample rate (320 / 160 at 8 kHz, scaled by `rate / 8000` and rounded up to even).
Frames are centred with reflection padding. The model reads `log1p(|X|)` and the phase, and
writes a compressed magnitude and a phase; the inverse uses `expm1(relu(magnitude))`.
The same rate goes in and comes out.

**Encoder** (`dense_encoder`). The magnitude and phase columns get two zero bins appended, so
a frame of `F` bins is `F + 2` wide inside the encoder.

1. A 3x3 convolution from 2 to 64 channels, one of three (`dense_conv_1_1`, `_1_2`, `_1_3`)
   chosen by the look-ahead of 0, 1 or 2 frames: with look-ahead `a` it reads frames
   `t - 2 + a` to `t + a`. Then a layer normalisation over the 64 channels and a per-channel
   PReLU, as after every convolution below.
2. A dense block of four 3x3 convolutions with time dilations 1, 2, 4 and 8. Layer `i` reads
   the outputs of all earlier layers and the block input (`64 * (i + 1)` channels, newest
   first) and writes 64. Time padding is causal; frequency padding is one bin each side.
3. A 1x3 convolution with frequency stride 2 and no padding, which leaves
   `W = (F - 1) / 2 + 1` bins: 161 at 16 kHz, 481 at 48 kHz.

**Blocks** (`TSMamba.n`), on `W` bins of 64 channels. With `x` the block input:

- time: `u = x + norm(linear(mamba(x) + x))`, one causal Mamba recurrence per bin whose
  convolution history and state persist across frames;
- frequency: `y = u + norm(linear([f(u) + u, b(u) + u]))`, where `f` scans the bins upwards
  and `b` downwards with a second, separately trained Mamba, each from a zero state on every
  frame, and the linear layer maps 128 to 64.

Each Mamba is `d_model 64, d_state 16, d_conv 4, expand 4`: `in_proj` 64 to 512 without bias,
a depthwise causal convolution of 4 taps, SiLU, `x_proj` 256 to 36 split 4 / 16 / 16 into the
step, the input and the readout vectors, `dt_proj` 4 to 256 with softplus,
`h = exp(dt * -exp(A_log)) * h + dt * B * x`, `y = h . C + D * x`, a `silu(z)` gate, and
`out_proj` 256 to 64 without bias.

**Decoders.** Exit depth `n` (3 to 12) runs blocks 0 to `n - 1` and then
`mask_decoder_list[n - 1]` and `phase_decoder_list[n - 1]`. Each is a dense block as in the
encoder at width `W`; a 1x3 convolution from 64 to 128 channels with one bin of padding whose
output is interleaved to 64 channels at `2W` bins (output bin `2w + j` of channel `c` is
convolution channel `64j + c`); a convolution of three taps along time and one bin wide with
causal padding; and a 1x1 convolution to one channel for the magnitude, or two 1x1
convolutions combined with `atan2(imaginary, real)` for the phase. The first `F` bins are kept.

**Streaming.** The publisher's online loop feeds one frame per call. Every time-dilated
convolution keeps `(taps - 1) * dilation` past frames, initially zero. A frame whose
decompressed magnitude is zero in more than half of its bins has its magnitude cleared.
Algorithmic latency is one window plus one hop per look-ahead frame.

## What the first engine had wrong

| | First engine | Published model |
| --- | --- | --- |
| Hop and window | 10 ms, 20 ms | 20 ms, 40 ms |
| Encoder | four convolutions, widths 16, 32, 48, 64, stride 2 first | 2 to 64, a four-layer dense block at full width, stride 2 last |
| Normalisation | none after convolutions | layer normalisation over channels after each |
| Time branch | `x + norm(linear(mamba(x)) + x)` | `x + norm(linear(mamba(x) + x))` |
| Frequency branch | one Mamba for both directions, reading the block input | two Mambas, reading the time branch's output |
| Decoder | 1x3 projection, sub-pixel, 1x1 | dense block, sub-pixel, time convolution, 1x1 |
| Sub-pixel order | channel `2c + j` | channel `64j + c` |
| Tensor names | `encoder.conv0`, `tfmamba.n.time.mamba`, `decoder.magnitude.n` | `dense_encoder…`, `TSMamba.n.time_mamba.forward_blocks…`, `mask_decoder_list.n…` |

The file-mode model (`nvidia/NVIDIA-NemotronLabs-RE-USE`) has the same class of defect: its
header, read the same day, names `dense_encoder.dense_block.dense_block.0.0.weight` and
`TSMamba.0.time_mamba.backward_blocks…`, which `OfflineRestorer` did not read. That path is
unchanged by this decision; ADR-0013 rebuilds it against its own reference code.

## Decision

Rebuild the streaming engine to the graph above under `Sources/UntunnelEngine/Realtime`, read
the checkpoint by its published names, and prove it against the publisher's implementation.

**Reference outputs.** `tools/reference/realtime_goldens.py` downloads the publisher's model
and streaming code at the pinned revision, checks each file's SHA-256, and runs it unchanged
on the CPU in a development-only environment that `uv` builds from the pins in the script's
header. The publisher's code imports the CUDA build of `mamba_ssm`, which cannot be installed
on macOS, so the script supplies the Mamba block in plain PyTorch with the same parameter
names; the checkpoint loads into it with `strict=True`. The script measures that substitution
by reproducing the enhanced recording the publisher ships beside the model
(`enhanced_audio/online_enhanced_mic_test.flac`, 16-bit, exit depth 8, no look-ahead) and
stores the measured difference in the fixture manifest under `shipped_pair`.

**Fixtures.** `fixtures/model/realtime-goldens.*.safetensors` hold, for five inputs across
8, 16, 24 and 48 kHz, exit depths 3 to 12 and every look-ahead, the input, the publisher's
analysed frames and its streamed waveform; and for an 8 kHz stream at exit depth 12, the
encoder output, every block output and both decoder outputs for frames 0 to 7. The inputs are excerpts of a LibriVox
reading in the public domain, because the model suppresses anything that is not speech and a
synthetic signal comes back near-silent. `realtime-goldens.json` names the upstream revision,
every upstream hash, the recording and the configuration of each case. No weights are stored.

**Phase.** The model reads the phase of every bin, and phase is not a continuous function
of the signal: it jumps between π and -π, and in a bin that holds no signal it is whatever the
rounding of the transform leaves. Two correct forward transforms therefore hand the model
different inputs, and the output follows. The publisher's own code, run twice on inputs that
differ by one part in a million, disagrees with itself by more than the waveform tolerance
on some inputs; the generator measures that for every golden and stores it under
`perturbed_rerun`. The model after the transform is well conditioned. So each golden also
stores the publisher's analysed frames, which is where the comparison with the tolerance
starts, and each input carries a seeded noise floor at about -50 dBFS, as a microphone signal
does, so that no bin is empty.

The noise floor cannot reach the first frame. It is centred on sample zero and padded by
reflection, and the periodic window is symmetric about its centre, so the windowed frame is
even and its spectrum real: every bin's phase is 0 or ±π, and the sign of π is the sign of
an imaginary part that rounding alone makes nonzero. This engine's transform and the
publisher's disagree on that sign in about a quarter of the first frame's bins at every
rate, and on no bin of any later frame. The model reads π and -π as inputs 2π apart and
carries the difference forward in its recurrent state. That one frame is the whole gap
between the stream restored from samples and the reference: with the first frame's signs
taken from the publisher's frames, this engine's transform restores every golden as closely
as the publisher's frames do. The size of the gap varies by golden, and the 48 kHz one has
the widest; `docs/bench.md` lists all three measurements per golden. Neither transform's sign is the
right one, so the gap is a property of the model's input, not a defect to fix in either.

**Tests.** `IntermediateParity` drives each Swift module with the reference input of that
module and compares its output to 1e-4. `GoldenParity` restores each golden from the
publisher's analysed frames through the encoder, the blocks, the decoders and the inverse
transform, and requires the waveform to match within 1e-3 at every sample and by more than
50 dB; it holds this engine's own transform to the same limits once the first frame's signs
at ±π are taken from the reference; and it streams the input samples through
`RealtimeRestorer`, requires the result to be aligned, and records all three differences in
`docs/bench.md`. The forward
transform has its own fixture in `fixtures/stft`. Both suites need the pinned checkpoint,
which they read from where `untunnel download` stores it (or from
`UNTUNNEL_REALTIME_CHECKPOINT`), and are skipped when it is absent.

## Licences

- **Weights and the publisher's code**: NVIDIA One-Way Noncommercial License (NSCLv1), linked
  from the model card and read at `https://github.com/NVlabs/HMAR/blob/main/LICENSE` on
  2026-11-09. It grants use, reproduction and derivative works, limits the work and its
  derivative works to non-commercial research and educational use (section 3.3), and
  requires redistribution of the work itself under the same licence (3.1). The card adds
  "This model is for research and development only." The Python files carry an
  all-rights-reserved header that defers to an express licence, which the card supplies.
- **This repository** stores none of those files and none of the weights. The Swift engine
  is written from the architecture, which the papers (arXiv 2603.02641, 2606.25621) and the
  checkpoint header also describe, and copies no source text. Whether a clean
  reimplementation counts as a derivative work under 3.2 is a legal question this record does
  not settle; if it does, section 3.3's non-commercial limit would reach the engine as well
  as the weights. The weights carry that limit either way, so a build that restores audio
  with this checkpoint is for non-commercial use regardless of the engine's MIT licence.
- **Mamba** (`state-spaces/mamba`): Apache-2.0. The recurrence is implemented from its
  published equations; no source is copied.
- **Swap path**: `untunnel download --model <repo>@<revision> --sha256 <hex>` loads any
  checkpoint with the same tensor layout, which is how differently licensed weights replace
  these.

## Consequences

- `Tier.streamingHopMilliseconds` is 20, so every caller that sizes a buffer by the hop
  processes 20 ms at a time and the algorithmic latency is 40 ms plus 20 ms per look-ahead
  frame.
- Parity runs only where the checkpoint has been downloaded. CI downloads it from the
  publisher with `untunnel download`, which checks its SHA-256, caches it under the hash of
  the fixture manifest, and fails rather than skips when it is not where the suites look.
- The published model is heavier than the inferred one: timings come from `untunnel bench`
  and decide the tier, not the tables written for the first engine.
