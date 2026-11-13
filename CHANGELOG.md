# Changelog

This file follows Keep a Changelog. Versions follow semantic versioning.

## [0.1.0] - Unreleased

### Fixed

- The streaming engine now implements the published Real-time RE-USE model and loads its
  checkpoint; the first engine followed an inferred layer graph and rejected the real file.
  Parity with the publisher's implementation is tested per module and on whole waveforms
  (ADR-0010).
- The parity suites run in CI against the publisher's checkpoint, downloaded at the pinned
  revision and checked by its SHA-256. The difference between restoring from samples and
  from the publisher's frames is traced to the phase signs of the first frame, whose
  spectrum is real; the engine's own transform is now held to the parity limits apart from
  those signs (ADR-0010).
- The offline engine now implements the published RE-USE file-mode model and loads its
  checkpoint; it had followed the same inferred graph, with 10 ms frames. Parity with the
  publisher's implementation is tested per module and on whole files, and CI downloads that
  checkpoint too (ADR-0013).

### Changed

- The streaming engine runs its recurrences in C kernels and shares each frame between the
  calling thread and a pool of worker threads; `untunnel bench` now states which tiers fit
  the latency budget (ADR-0011).
- The frame path no longer calls Accelerate's matrix product, which allocated on every
  call; its own product runs on the matrix unit where the processor has one. Matrix
  products run on the calling thread, sweeps are shared by channel, and the workers stay
  awake for the length of a frame (ADR-0012).
- `untunnel bench` measures as a stream runs: one frame per hop on a time-constraint thread.
  Its numbers are not comparable with earlier reports.
- The streaming hop is 20 ms and the frame 40 ms, as the model was trained, so the microphone
  path processes 20 ms at a time.

### Added

- Swift package targets for the engine, DSP, audio layer and executable.
- Locked development tools, formatting rules and repo-root path checks.
- `untunnel enhance IN.wav OUT.wav`, which restores a WAV file with the offline model
  (`--model offline`, with `--bwe RATE` to extend the band) or with the streaming model, and
  the offline restorer behind it: bidirectional time blocks, a 5 ms hop and chunked
  inference with crossfaded joins.
