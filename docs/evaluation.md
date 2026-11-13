# Evaluation: simulated headset benchmark

This benchmark degrades clean speech the way a Bluetooth hands-free link does and compares
Untunnel against reference points and other restorers. No results are recorded yet. The command
below rewrites only the region between the results markers at the end of this file.

## Primary endpoint

Fixed here before the first full run:

> Median paired difference in high-band LSD (log-spectral distance above 8 kHz), auto tier
> minus spectral folding, mSBC condition, primary set.

Each utterance contributes one difference. The median is reported with a 95 % interval from a
two-stage speaker-clustered bootstrap, and a Wilcoxon signed-rank test on per-speaker mean
differences. Against the degraded input, any added energy above 8 kHz lowers the distance to a
full-band reference, so that comparison is reported but proves nothing.

## Utterances

Both lists are drawn with seed 0 and saved in `fixtures/eval/e1_utterances.txt`. The lists
have not yet been generated in this checkout: under this rule the pinned DAPS recordings yield
no eligible segments for m1 and only two for m5, below the required ten per speaker. No
utterance from either list is used for any tuning, including the auto rule.

- **Primary: DAPS clean speech, 200 utterances.** Ten from each of the 20 speakers. DAPS is not
  among the corpora listed on RE-USE's model card, which is the only evidence available, so the
  copy says "not in the listed training data". Recordings are cut at pauses of at least 300 ms
  below -40 dB relative to the file's peak 20 ms frame RMS, and neighbouring segments are merged
  until each lasts 3 to 10 s. DAPS has one text per script rather than per segment, so its WER
  reference is Whisper's transcript of the clean segment, labelled "pseudo-reference".
- **Comparability: VCTK, 200 utterances.** Twenty-five from each of the eight standard test
  speakers (p360, p361, p362, p363, p364, p374, p376, s5), microphone 1. Every table marks this
  set "in RE-USE's training data". WER uses VCTK's own transcripts.

Extract the pinned archives, then draw or re-draw the lists:

```sh
tar -xzf .cache/eval/daps.tar.gz -C .cache/eval
unzip -q .cache/eval/VCTK-Corpus-0.92.zip -d .cache/eval/vctk
uv run --project tools python -m untunnel_tools.eval.benchmark --draw-lists
```

## Degradations

Each is scripted, seeded and applied to the clean reference at 48 kHz.

| Condition | Steps |
|---|---|
| mSBC | Resample to 16 kHz, encode with `ffmpeg -c:a sbc -msbc 1`, decode. |
| mSBC with packet loss, 2 % and 5 % | As above, then drop 7.5 ms frames with a two-state Gilbert-Elliott model, seed 0. Bursts average 2 frames: the bad state is left with probability 0.5 and entered with probability L / (2 (1 - L)) for average loss L. Lost frames are zero-filled, the worst case; real stacks conceal them. Labelled "worst case" in every table. |
| Narrowband phone | Resample to 8 kHz, G.711 mu-law (`pcm_mulaw`), decode. |

## Systems

| System | Input it receives | Notes |
|---|---|---|
| Degraded input | The degraded signal | Upsampled to 48 kHz only. |
| Spectral folding | The degraded signal | Mirrors the band below the condition's bandwidth (8 kHz, or 4 kHz for the phone) into the octave above it, at a fixed gain of -12 dB. The floor. |
| Untunnel, auto tier and each listed tier | 48 kHz | Every tier the tier rule accepts ([ADR-0004](adr/0004-tier-rule.md)), passed with `--tier RATE:EXIT:LOOKAHEAD`. |
| Offline OpenMDW model | 48 kHz | `untunnel enhance --model offline --bwe 48000`. |
| AP-BWE | 16 kHz | Offline bandwidth extension. For the phone condition the 8 kHz input is upsampled to 16 kHz first. |
| DeepFilterNet3 | 48 kHz | `deep-filter -D`, which compensates its own delay. |

Untunnel, the offline model, AP-BWE and DeepFilterNet3 run as commands that read one WAV and
write another. The defaults live in `tools/src/untunnel_tools/eval/baselines.py`; replace any
with `--system-command NAME=COMMAND`, where `{input}`, `{input_directory}`, `{output}`,
`{output_directory}` and `{tier}` are filled in per call. `untunnel enhance IN.wav OUT.wav`
runs the Untunnel default with `--model streaming --tier` and the offline default with
`--model offline --bwe 48000`. The offline model needs a chunk length and overlap: it reads
`chunk_seconds` and `overlap_seconds` from the `config.json` next to its checkpoint, and
`--chunk-seconds` and `--overlap-seconds` override them. The AP-BWE default names a script and
checkpoint path under `.cache/eval` that are unchecked.

## Metrics

Every score is against the clean reference resampled to 48 kHz (DAPS is recorded at 44.1 kHz,
VCTK at 48 kHz, as pinned in `fixtures/eval/sources.json`), after removing each system's delay.

| Metric | Sees above 8 kHz | Notes |
|---|---|---|
| LSD, full band and above 8 kHz | yes | 1024-sample Hann windows, 75 % overlap, power floor 1e-10. |
| PESQ-WB (P.862.2) | no | Resampled to 16 kHz. Measures repair, not extension. |
| ESTOI | no | Computed at 10 kHz. |
| ECAPA cosine similarity | no | Speaker embeddings at 16 kHz. |
| WER | no | Whisper large-v3-turbo at the pinned revision, 16 kHz, jiwer normalisation. |
| DNSMOS P.835 OVRL, SIG, BAK | no | 16 kHz, local model only. |

ViSQOL v3 is not used: its speech mode runs at 16 kHz and is blind above 8 kHz like the other
metrics, and its 48 kHz audio mode is designed for music.

## Statistics

Utterances from one speaker are not independent, so intervals resample speakers first and
utterances within each chosen speaker second (10,000 resamples, seed 0). Tests run on
per-speaker mean differences. Every comparison is system minus spectral folding. Wilcoxon
p-values for every secondary comparison in the report are Holm-corrected together; the primary
endpoint is the single pre-specified test and is not part of that family.

## Run it

The optional `eval` dependency group provides PESQ, ESTOI, jiwer, SpeechBrain and the Whisper
runtime. The ECAPA checkpoint prepared for the intended run is
`speechbrain/spkrec-ecapa-voxceleb` at revision `0f99f2d0ebe89ac095bcc5903c4dd8f72b367286`.
The ECAPA model directory, the Whisper revision and the DNSMOS model are read from
`.cache/eval` by default; override with `--ecapa-dir`, `--whisper-dir` and `--dnsmos-model`.

The tier arguments below reflect the qualifying rows and selected tier in this machine's
[benchmark report](bench.md). Measure and substitute your machine's selection and qualifying
tiers before reproducing the evaluation. The CLI accepts a numeric tier, not `auto`.

```sh
uv sync --project tools --locked --group eval
uv run --project tools python -m untunnel_tools.eval.benchmark --set e1 --out docs/evaluation.md \
  --auto-tier 48000:7:1 --tier 16000:4:0 --tier 24000:5:1 \
  --tier 32000:6:1 --tier 48000:7:1
```

A smoke run scores evenly spaced utterances from each list and should write elsewhere:

```sh
uv run --project tools python -m untunnel_tools.eval.benchmark --set e1 --limit 10 \
  --auto-tier 48000:7:1 --out .cache/e1-smoke.md
```

## Listening clips

```sh
uv run --project tools python -m untunnel_tools.eval.benchmark --export-clips recordings/e1-clips \
  --auto-tier 48000:7:1
```

Writes six items drawn with seed 0, four from the primary list and two from the comparability
list. Each has the mSBC input, the Untunnel auto tier output and the clean reference, matched to
the clean clip's RMS level (one common gain lowers all three if a peak would clip). The folder's
`licences.json` names every file's source, licence (DAPS CC BY-NC 4.0, VCTK CC BY 4.0) and
attribution line, which the site prints under each figure.

## Results

<!-- e1-results:start -->
No full run is recorded yet.
<!-- e1-results:end -->
