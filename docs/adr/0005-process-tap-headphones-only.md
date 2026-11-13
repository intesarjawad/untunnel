# ADR-0005: Tap the other person's audio, muted while tapped, on headphones only

Status: Accepted. The tap, its guard and the playback of the restored audio are built.

## Context

The other person's voice reaches the Mac as the call app's output, so restoring it means
capturing that app's audio before it is played, restoring it, and playing the result instead.
Core Audio process taps capture one process's output without a loopback driver, and a tap can
mute the original while it is read.

Muting the original changes what the call app's echo canceller sees. On speakers, the room
would hear the restored, delayed copy while the canceller compares the microphone against the
muted original, so the far end would hear its own voice back. On headphones nothing reaches the
microphone and the problem does not arise.

## Decision

`IncomingTap` in `Sources/UntunnelAudio/ProcessTap.swift`:

1. Follows the microphone path. It targets the app `ClientWatcher` reports as reading the
   virtual microphone and stops when that path is released.
2. Finds that app's processes that are running output and groups them by bundle identifier, so
   a browser call taps the helper that plays it. A helper one browser engine shares for every
   tab mutes the whole browser while tapped, and the menu says so.
3. Creates a `CATapDescription` stereo mixdown of those processes with
   `muteBehavior = .mutedWhenTapped` and `isPrivate = true`; on macOS 26 and later it also sets
   the bundle identifiers and process restore, so a call app that restarts comes back on the same
   tap. A private aggregate device named "Untunnel Tap" carries the tap, with drift
   compensation on.
4. Allows the tap only when `HeadphoneGuard` accepts the current output: a Bluetooth device, the
   built-in output with its headphone data source, or a device the person marked as headphones
   (stored by UID). The guard runs again on every default-output change; a refusal tears the tap
   down, which unmutes the app, and the menu shows the path as paused on speakers.
5. Maps a permission error from tap creation to a permission-denied state the menu explains.
6. Starts off. "Also restore the other person" is a menu toggle stored in user defaults.

At launch, `StrayTapSweep` destroys any "Untunnel Tap" aggregate a killed run left behind.

## Consequences

Incoming restoration never plays on speakers, at the cost of doing nothing for people who take
calls on them. A browser call mutes all audio from that browser while tapped. A measurement
override allows one named loopback device as the output; the app logs a warning whenever it is
set.

## Playback

`IncomingPlayback` in `Sources/Untunnel/App/IncomingPath.swift` wraps the tap: it reads the
aggregate device into a second `Pipeline` with its own model instance and plays the result on
the current output. Creating the tap mutes the app, so a playback that cannot start destroys the
tap again before reporting the failure; the app is never left muted with nothing in its place.

## Open

No real call has run through it, and the system-audio permission prompt has not been observed.
