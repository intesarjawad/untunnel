# Limits

- The missing band is predicted from what survived, not recovered.
- The live path has not run on a real call yet (see Status), and the added delay is not measured.
  The streaming model alone adds 40 ms plus 20 ms per look-ahead frame.
  <!-- number: 40 ms window plus 20 ms per look-ahead frame, docs/adr/0010-real-time-model-architecture.md "Consequences" -->
- Speech only. The model suppresses what is not speech.
- The streaming weights are non-commercial. The commercial-use offline model works on files only.
- Long files are cut into chunks and joined with normalized Hann overlap-add, matching the
  publisher's chunk weighting. Model parity covers single chunks
  ([ADR-0013](docs/adr/0013-offline-model-architecture.md)).
- Offline memory grows with chunk length, particularly in the encoder's dense block
  ([ADR-0013](docs/adr/0013-offline-model-architecture.md)).
- Incoming restoration (the other person) is allowed only on headphones, because on speakers
  it would reach the call as echo ([ADR-0005](docs/adr/0005-process-tap-headphones-only.md)).
- Apple silicon and macOS 15 or later only. Timings exist for no other machine.
- The app and driver are signed ad hoc and not notarised ([ADR-0009](docs/adr/0009-prebuilt-release.md)). Whether macOS asks for permissions again after an upgrade has not been recorded.
