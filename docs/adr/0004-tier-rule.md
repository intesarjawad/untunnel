# ADR-0004: Measured tier rule and head-to-head benchmark

Status: Accepted.

## Context

The engine runs at several processing rates, each with its own exit layer and look-ahead. A
higher rate and a deeper exit sound better and cost more per frame. Audio frames arrive every
20 ms and a frame that takes longer than that is a missed deadline, so the choice cannot be
made from the model size alone: it depends on the machine, its power source and what else is
running, such as a video call app.

Another open-source restorer, reuse-rs, runs on the same hardware. Whether either engine is
faster is a measurement, not an assumption.

## Decision

`untunnel bench` measures every tier on a real-time thread after 100 warm-up frames, one
frame per hop as a stream delivers them, idle and under `--load N` busy default-priority
threads, and records median, p95, p99, p99.9, maximum,
deadline misses per 10,000 frames, peak resident memory and the parameter count. Every report
names the machine, macOS version, power source and date, because numbers do not transfer
between them.

`TierRule` reads that report and picks the tier the app runs:

1. A tier qualifies when its loaded p99 is at most 12 ms. A report without a loaded pass uses
   the idle pass.
2. Among qualifying tiers it takes the highest rate, then the deeper exit, then the larger
   look-ahead, since each buys quality.
3. When nothing qualifies it takes the cheapest tier, so a slow machine starts with the most
   affordable configuration instead of failing.

The microphone path and the incoming path run at the same time. `bench --concurrent` runs the
chosen tier and a candidate for the other path together, one real-time thread each, and the
pair is accepted only when every path stays inside the same 12 ms budget. The result is stored
in the `concurrent` part of the JSON report, next to the sequential passes of the same machine.

`bench_reuse_rs.sh` builds reuse-rs at a pinned commit with its default features and times the
same tiers on the same input. The default features use Accelerate on macOS; the `metal`
feature is not used because its own README reports worse tail latency. A tier the reuse-rs
example cannot run is marked "not supported" rather than left out. Both tools write to
`docs/bench.md`, and each keeps the other's rows when it rewrites the file.

## Consequences

The tier is chosen by measurement on the user's machine, and the 12 ms budget leaves headroom
below the 20 ms deadline for scheduler jitter. If no tier at 24 kHz or above fits the budget
on the reference machine, the engine is optimised and the benchmark rerun; the budget is not
loosened.

If reuse-rs is faster on a tier, that is profiled with Instruments and the changes made in
response are recorded in `docs/bench.md`. If it is still faster afterwards, `docs/bench.md`
says so plainly and no public copy claims that Untunnel is faster. Performance statements come
from the benchmark output, never from prose.
