# ADR-0008: Auto-route and the heartbeat

Status: Accepted.

## Context

Untunnel's microphone only helps when applications read it. A person who takes their headset out
of its case expects calls to use the restored microphone without opening a settings pane. macOS
already switches the default input to a Bluetooth headset when it connects, so the app can follow
that switch instead of racing it.

Moving the system default is intrusive: a person who picks another device by hand must never be
overridden, and an app that dies while it is the default must not leave the Mac with a dead
microphone.

## Decision

**Routing.** `AutoRoute` is a pure state machine. Its input is a list of events with
timestamps: launch, device appeared, default input changed, headset disconnected, toggle, quit,
wake and permission changed. Its output is the default input to set, if any, plus what the menu
shows. A shell applies the answer with `AudioObjectSetPropertyData` on
`kAudioHardwarePropertyDefaultInputDevice`.

1. A default-input change to a Bluetooth device within 3 s of that device appearing in the
   device list is macOS switching on connect. It starts auto-route: the app records the headset
   and the default it replaced, and sets its own microphone.
2. Any other default change is the person's. It ends auto-route until the next connect, so a
   device chosen by hand while connected is never overridden.
3. A disconnect of the recorded headset ends auto-route. Turning the item off ends it too.
4. Quit restores the recorded previous default and marks the exit as clean.

**Relaunch after a crash.** The shell stores the previous default's UID, the headset's UID and a
clean-exit flag in `UserDefaults`. Quit and the update relaunch set the flag. On a launch without
it, the app sets its own microphone again only when the stored headset is connected and the
current default is that headset or the stored previous default. Otherwise it leaves the default
alone.

**Permission.** While microphone permission is not granted there is no heartbeat and
auto-route is off. At launch and on wake, an undecided permission calls
`AVCaptureDevice.requestAccess(for: .audio)` so the prompt appears at once. A denied or
restricted permission shows the permission line in the menu.

**Driver version.** At launch the app reads the plug-in's `'vers'` property and compares it with
its bundled driver. A mismatch shows the "driver outdated" message with the fix
`untunnel setup`, which installs the matching plug-in and asks for one password. The `'hbt '`
property keeps its meaning across versions, so an outdated plug-in still runs the failsafe.

**Heartbeat.** A 1 Hz timer on the main run loop sets `'hbt '` on the feed device. It fires only
when every condition holds:

- the doctor reports `virtual_mic.kind == own`;
- the fallback, liveness and sleep checks have passed;
- microphone permission is granted;
- the pipeline's hop counter moved since the last tick, with a status of waiting, running or
  bypassed.

Silence hops advance the counter, so a pipeline in `waiting` keeps beating, and a stalled
pipeline there stops the heartbeat. When a condition is false the menu shows auto-route off with
the reason.

## Consequences

The driver, not the app, decides when the microphone has gone silent: the app only has to stop
beating for the failsafe to take the default away from a hung or killed process. A heartbeat is
therefore a promise that the pipeline is moving, never a signal that audio is present.

The 3 s window is a heuristic. If macOS switches later than that on some headset, auto-route
treats the switch as the person's and stays off; the person can still choose the Untunnel
microphone by hand. The window is changed only from a measurement, and the measurement tools
append to `docs/results.md`.

Auto-route is off by default on machines where a prerequisite check has not passed, and the menu
says which one.
