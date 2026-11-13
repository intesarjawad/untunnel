# ADR-0007: Evaluate on simulated headset links with a clean reference

Status: Accepted for the simulated benchmark. Real-headset recordings and a listening test are
not built (see Open).

## Context

The restored band is predicted, so the only fair score compares it with what the speaker really
said above the cut-off. A recording made through a real headset has no such reference: the
headset never captured the upper band. Most standard speech metrics also resample to 16 kHz or
lower and cannot see the band the restoration adds.

## Decision

The first evaluation set degrades clean speech the way a hands-free link does, so every output
has a full-band reference. `docs/evaluation.md` is the protocol and
`tools/src/untunnel_tools/eval` the code:

1. **Conditions**: mSBC through the pinned ffmpeg encoder, mSBC with scripted, seeded packet
   loss, and a narrowband G.711 phone link (`simulate_hfp.py`).
2. **Speech**: a primary set from a corpus not listed in the model's training data, and a
   comparability set that is, labelled as such in every table. Both lists are drawn with a fixed
   seed and never used for tuning.
3. **Systems**: the degraded input, spectral folding as the floor, every Untunnel tier the tier
   rule accepts, the offline model, and other open restorers run as commands
   (`baselines.py`), each replaceable from the command line.
4. **Metrics**: log-spectral distance over the full band and above the narrow band, which see
   the restored region, next to metrics that do not (PESQ-WB, ESTOI, speaker similarity, WER,
   DNSMOS), reported as repair rather than extension.
5. **Statistics**: one primary endpoint fixed in `docs/evaluation.md` before the first full run;
   intervals from a bootstrap that resamples speakers before utterances; Holm-corrected
   secondary tests (`stats.py`).

The benchmark writes its results between markers in `docs/evaluation.md`, and public copy may
quote only numbers found there or in the other results files (`untunnel_tools.claims`).

## Consequences

Scores measure how close the prediction is to the real upper band, and the comparisons are
paired against a fixed floor, so a system that only adds energy above the cut-off does not
score well by default. A simulated link is not a real headset: it leaves out the headset's own
microphone, its processing and real radio conditions.

## Open

- A set of real headset recordings with a simultaneous wideband reference microphone is not
  built.
- A listening test with human ratings is not built.

Until both exist, results speak only for simulated links.
