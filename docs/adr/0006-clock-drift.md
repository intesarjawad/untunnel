# ADR-0006: A PI-steered drift resampler in front of the virtual microphone

Status: Accepted.

## Context

The headset input and the virtual microphone run on independent clocks. Two clocks nominally at
the same rate differ by a small, steady amount, so a ring between them that is read one frame
per frame written slowly fills or empties. Within a long call that ends in a dropout or in
growing delay. The pipeline cannot slow either device down; it can only read the ring a little
faster or slower than one frame per frame.

## Decision

`DriftResampler` (`Sources/UntunnelDSP/DriftResampler.swift`) reads the ring through a
fractional position that advances by a ratio close to 1:

1. Once per hop it measures how full the ring is, in hops, and steers that fill towards a
   target of one and a half hops with a proportional-plus-integral controller. Its gains come
   from a second-order loop with the natural frequency and damping ratio named in the file.
2. The ratio is clamped to ±0.5 % of 1, and the integral term is clamped to the same range, so a
   ring that runs dry or a stalled producer cannot wind the controller up.
3. Samples between two frames are linearly interpolated. The ratio moves slowly, and the
   `PolyphaseResampler` stage does the actual rate conversion, so this stage only has to absorb
   the drift.
4. A hop the ring cannot fill is returned short; `VirtualMicOutput` sends the missing part as
   silence and counts it in `PipelineSnapshot`, so drops are reported instead of hidden.

The resampler is pure: it reads a `RingBuffer` and writes a buffer, with no clock or device.
`DriftResamplerTests` runs a producer 500 parts per million fast against a 48 kHz consumer for
one simulated hour and requires no underflow after warm-up and a fill that stays between half a
hop and two and a half hops.

## Consequences

The virtual microphone keeps a steady delay through a long call, at the cost of the extra hop
and a half held in the ring, which counts towards the added latency
([how it works](../how-it-works.md#the-latency-budget)). Drift beyond ±0.5 % is not absorbed;
the counter of short hops then rises and shows it.

Only the virtual microphone output uses the resampler today. `HeadsetOutput` plays a whole
recorded take, resampled once before playback, so it has no long-running ring to steer.
