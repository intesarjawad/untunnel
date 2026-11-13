# ADR-0003: Engage the microphone path only while another application listens

Status: Accepted.

## Context

A Bluetooth headset switches to a low-rate call profile as soon as anything opens its input,
and returns to its high-rate output profile only after the input is closed. Keeping the
headset input open all the time would hold the headset in the call profile and defeat the
restoration. The path therefore has to open when an application starts listening to the virtual
microphone and close when the last one stops.

Core Audio publishes this as process objects. Each audio process reports whether it is running
input and which devices it uses for input, and the system publishes the list of those
processes.

## Decision

`ClientWatcher` decides from the process list alone:

1. It listens to the process object list and, for every process in it,
   `kAudioProcessPropertyIsRunningInput` and `kAudioProcessPropertyDevices` in the input scope.
   A process object disappears with its client, so the per-process listeners are registered
   again whenever the list changes.
2. A process is a client when it is running input and the virtual microphone is among its input
   devices. Input on any other device is not a client.
3. The app is never its own client. A process is excluded when its pid is the app's, or when its
   bundle identifier is one of the app's, because the audio process can belong to a helper with
   another pid.
4. The path engages as soon as any client exists: the headset input is opened and the pipeline
   started. When several clients exist, the first by name then pid is the one the menu names.
5. The path is released two seconds after the last client stops. A client that reappears
   inside that window cancels the release, so an application that closes and reopens its stream
   does not make the headset change profile each time. When the delay ends the live process
   list is read again, so a client that came back without a notification still keeps the path
   open.
6. The menu shows "Standby" while no client exists and "Restoring for <client>" while one does.

The decision is separated from Core Audio by a process-source protocol and from the clock by a
scheduler protocol. The tests drive both with a fake process list and a manual scheduler, and
cover engage, release, debounce, several clients, and exclusion of the app itself.

`uv run --project tools python -m untunnel_tools.measure.engage [--device NAME]` is the hand-run hardware
check. It opens a reader on the virtual microphone, or on the named device, holds it, closes it,
and then reads the headset's rates from `system_profiler SPAudioDataType -json` until the
headset is back at the output rate it had before, for at most five seconds. It does not use
PortAudio's device rates because PortAudio caches them. It prints PASS only when the idle rate
returns inside that time.

## Consequences

The headset stays at its high-rate profile whenever nobody is listening, and the call profile
is held only while a client needs it. The two-second delay is a fixed value; it trades a short
period of holding the call profile after a call ends against profile flapping between rapid
stream reopenings.

A client that reads the virtual microphone through an aggregate or another virtual device is
not seen, because the match is on the virtual microphone's own identifier. No hardware result
is recorded here: the engage check needs a paired headset and is run by hand, and its
output belongs in the run log, not in this record.
