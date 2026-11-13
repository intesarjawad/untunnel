# Benchmark report

Machine: Mac17,2
macOS: Version 27.3 (Build 26C5035r)
Power source: AC power
Date: 2026-11-10T10:14:00Z

Run the benchmark again on the machine you are deciding for; these numbers are not
portable between machines or power sources.

## untunnel

The timing workload uses zero-filled model weights and a repeated sine input, not a trained
checkpoint or a real call. No trained-versus-zero timing comparison has been recorded.

| Tier | Pass | Median ms | p95 ms | p99 ms | p99.9 ms | Max ms | Misses / 10,000 | Peak RSS MB | Parameters |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 16000:4:0 | idle | 2.48 | 2.64 | 2.71 | 2.84 | 2.91 | 0.00 | 402 | 2032067 |
| 16000:4:0 | loaded | 2.48 | 2.61 | 2.71 | 2.82 | 2.86 | 0.00 | 416 | 2032067 |
| 24000:5:1 | idle | 4.10 | 4.33 | 4.44 | 4.56 | 4.57 | 0.00 | 416 | 2240579 |
| 24000:5:1 | loaded | 4.08 | 4.21 | 4.35 | 4.44 | 4.54 | 0.00 | 416 | 2240579 |
| 32000:6:1 | idle | 6.06 | 6.43 | 6.70 | 6.89 | 7.12 | 0.00 | 416 | 2449091 |
| 32000:6:1 | loaded | 6.01 | 6.21 | 6.39 | 6.52 | 6.74 | 0.00 | 416 | 2449091 |
| 48000:7:1 | idle | 9.81 | 10.16 | 10.39 | 10.59 | 10.81 | 0.00 | 416 | 2657603 |
| 48000:7:1 | loaded | 9.75 | 10.02 | 10.16 | 10.51 | 10.62 | 0.00 | 416 | 2657603 |

These measurements describe this run only. The app selects a tier from its own benchmark results; real call performance remains unverified.

## reuse-rs

<!-- reuse-rs:start -->
Run `tools/src/untunnel_tools/measure/bench_reuse_rs.sh` to fill this section.
<!-- reuse-rs:end -->

## Notes

The golden parity suites require waveform SNR above 50 dB; this is an acceptance threshold,
not a measured result (see `Tests/UntunnelEngineTests/GoldenParityTests.swift` and
`OfflineGoldenParityTests.swift`).

Record each optimisation made after profiling, with the before and after rows, below this line.

### 2026-11-10: products on the matrix unit, staged recurrences, workers awake for a frame

ADR-0012 records the changes. The benchmark changed with them: it now starts one frame per
hop on a time-constraint thread, where the "before" rows were taken back to back on a
thread of ordinary priority, so they are the earlier report and not a like-for-like
baseline. Loaded passes on the machine and power source above:

| Tier | Report | Median ms | p99 ms | Max ms | Misses / 10,000 |
| --- | --- | --- | --- | --- | --- |
| 16000:4:0 | before | 3.93 | 8.14 | 19.53 | 0.00 |
| 16000:4:0 | after | 2.48 | 2.71 | 2.86 | 0.00 |
| 24000:5:1 | before | 6.58 | 12.14 | 30.10 | 10.00 |
| 24000:5:1 | after | 4.08 | 4.35 | 4.54 | 0.00 |
| 32000:6:1 | before | 9.94 | 16.27 | 51.44 | 26.67 |
| 32000:6:1 | after | 6.01 | 6.39 | 6.74 | 0.00 |
| 48000:7:1 | before | 16.25 | 25.28 | 51.71 | 760.00 |
| 48000:7:1 | after | 9.75 | 10.16 | 10.62 | 0.00 |

## Golden parity

<!-- golden-parity:start -->
Difference between this engine's stream and the publisher's implementation, per golden:
restored from the publisher's analysed frames; from this engine's transform with the
signs of the first frame's phases at ±π taken from the publisher's frames; and from the
input samples. The model path uses float32 Hann window construction and multiplication.
The analysed-frame paths isolate model arithmetic from preprocessing differences.

| Golden | Rate Hz | Exit | Look-ahead | Max abs difference | SNR dB | Own transform: SNR dB | From samples: max abs difference | From samples: SNR dB |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| speech-16k-exit4 | 16000 | 4 | 0 | 4.17e-07 | 120.44 | 120.45 | 2.66e-04 | 62.13 |
| speech-48k-exit6-ahead1 | 48000 | 6 | 1 | 3.12e-07 | 119.71 | 118.60 | 5.32e-04 | 56.88 |
| speech-16k-exit8 | 16000 | 8 | 0 | 2.68e-07 | 121.97 | 121.96 | 7.98e-04 | 57.89 |
| speech-24k-exit12-ahead2 | 24000 | 12 | 2 | 4.17e-07 | 121.75 | 121.85 | 1.94e-04 | 63.98 |
| speech-8k-exit3 | 8000 | 3 | 0 | 2.98e-07 | 121.18 | 120.99 | 2.79e-04 | 63.26 |
<!-- golden-parity:end -->

## Offline golden parity

<!-- offline-golden-parity:start -->
Difference between this engine's offline restorer and the publisher's file inference,
per golden, over the whole file: restored from the publisher's analysed frames; from
this engine's transform with the signs of the first frame's phases at ±π taken from
the publisher's frames; and from the input samples.

| Golden | Rate Hz | Max abs difference | SNR dB | Own transform: SNR dB | From samples: max abs difference | From samples: SNR dB |
| --- | --- | --- | --- | --- | --- | --- |
| speech-8k | 8000 | 2.12e-06 | 104.17 | 104.15 | 5.32e-05 | 73.24 |
| speech-16k | 16000 | 8.14e-06 | 92.21 | 92.22 | 3.62e-05 | 74.38 |
| speech-24k | 24000 | 6.11e-06 | 94.71 | 94.73 | 7.95e-05 | 70.22 |
| speech-48k | 48000 | 7.15e-06 | 93.61 | 93.53 | 3.99e-05 | 78.52 |
<!-- offline-golden-parity:end -->

The analysed-frame SNR ranges are 119.71 to 121.97 dB for streaming and 92.21 to
104.17 dB for offline. From streaming input samples, the SNR ranges from 56.88 to
63.98 dB. The example file `fixtures/narrowband/sample.wav` is 16000 Hz.
