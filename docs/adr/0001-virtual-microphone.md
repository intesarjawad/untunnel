# ADR-0001: Own virtual microphone, BlackHole 2ch as the fallback

Status: Accepted. Whether macOS loads the ad-hoc signed plug-in is not yet recorded; see Open.

## Context

Call apps read a microphone device. The restored audio therefore has to appear as an input
device that any app can pick, fed by the app from outside coreaudiod's sandbox. Two ways exist
without a paid developer account: ship an audio server plug-in of our own, or write into an
existing loopback driver such as BlackHole 2ch, which the user installs separately.

An own plug-in can carry the failsafe ([ADR-0008](0008-auto-route.md)): it can remove its
microphone when the app stops, which a third-party loopback cannot do. Reports conflict on
whether a plug-in signed ad hoc still loads on current macOS, so the fallback has to stay.

## Decision

**The plug-in.** `driver/Untunnel.c`, with its testable logic in `Sources/UntunnelDriverCore`,
publishes two devices on one clock and one ring:

- "Untunnel Feed", a hidden output the app writes with an ordinary IOProc;
- "Untunnel Microphone", the visible input call apps read, in mono or stereo.

Both index the ring by the clock's sample time, so a frame written for time T is the frame a
reader gets at time T, and anything not written in time reads as silence. No memory is shared
with the app. The plug-in exposes `'vers'`, its version, and `'hbt '`, the heartbeat.

**Liveness.** By default the microphone is unlisted once no write has reached the feed device,
by IO or by the heartbeat property, for the timeout in `kLivenessTimeoutNanoseconds`.
`make -C driver LIVENESS=clients` builds the alternative: the microphone goes when the last
client leaves the feed device. Until the app has written once, the microphone stays listed, so
an installed plug-in shows its device before the app first runs.

**Installing.** `bundle.sh` signs the plug-in ad hoc and places it in
`Untunnel.app/Contents/Resources/Untunnel.driver`. `untunnel setup` copies it to
`/Library/Audio/Plug-Ins/HAL` with sudo and restarts coreaudiod, waiting first for any app that
is recording from the virtual microphone. When the bundle has no plug-in or the copy does not
appear, setup installs BlackHole 2ch with `brew install --cask blackhole-2ch` instead;
`untunnel setup --driver` chooses BlackHole directly.

**Choosing at run time.** `AudioDevicePolicy.virtualMic` uses the own feed and microphone when
both are listed, otherwise BlackHole 2ch when it is listed. `untunnel doctor` reports which as
`virtual_mic.kind` (`own`, `blackhole` or `none`) and whether the device is listed as
`virtual_mic.present`.

## Consequences

With the own plug-in, call apps see "Untunnel Microphone" and the plug-in can run the failsafe.
On the BlackHole path the user picks BlackHole 2ch in each call app, there is no heartbeat, and
auto-route stays off, because its prerequisites require `virtual_mic.kind == own`.

Installing or upgrading the plug-in restarts coreaudiod, which interrupts every app's audio for
a moment; setup therefore waits until no app is recording from the virtual microphone.

## Open

- No load test is recorded. Setup's check is that the bundle exists in the HAL folder after the
  copy, not that coreaudiod loaded it, so a plug-in macOS refuses to load is not caught there.
  `untunnel doctor` shows that case as `virtual_mic.kind` `own` with `present` false, because
  the bundle is on disk but no device is listed.
- Whether the device removal makes macOS fall back to another default input, and whether the
  plug-in's mere presence holds the idle-sleep assertion, have not been measured
  (`measure.failsafe` and `measure.sleep` are the hand-run checks). The heartbeat stays off
  until those checks pass.
