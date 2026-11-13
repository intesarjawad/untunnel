"""Checks that the microphone path recovers when its input device leaves and comes back.

The check reads the app's own log events for the loss and the return, and samples the audio
device list once a second with `system_profiler` while the tester moves the headset in and out
of its case. The virtual microphone has to stay listed for the whole outage, and the headset
has to be usable again within three seconds of the return.
"""

import argparse
import json
import sys
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from untunnel_tools.measure.cpu import CommandRunner, run_command
from untunnel_tools.measure.engage import (
    VIRTUAL_MIC_MARKERS,
    AudioDeviceReport,
    find_headset,
    read_audio_devices,
)
from untunnel_tools.paths import repo_root

LOG = "/usr/bin/log"
SUBSYSTEM = "com.intesarjawad.untunnel"
CATEGORY = "audio"
LOST_MESSAGE = "input_device_lost"
RESTORED_MESSAGE = "input_device_restored"
LOG_WINDOW = "5m"
POLL_SECONDS = 0.5
SAMPLE_SECONDS = 1.0
RESUME_TIMEOUT_SECONDS = 3.0
EVENT_TIMEOUT_SECONDS = 120.0
TIMESTAMP_FORMATS = ("%Y-%m-%d %H:%M:%S.%f%z", "%Y-%m-%d %H:%M:%S%z")

type JSONValue = dict[str, JSONValue] | list[JSONValue] | str | int | float | bool | None


@dataclass(frozen=True)
class RecoveryEvent:
    """One log line the app wrote when the input device changed."""

    message: str
    timestamp: float


@dataclass(frozen=True)
class WaitPlan:
    """How often to poll and how long the tester has for each step."""

    poll_seconds: float = POLL_SECONDS
    sample_seconds: float = SAMPLE_SECONDS
    event_timeout_seconds: float = EVENT_TIMEOUT_SECONDS
    resume_timeout_seconds: float = RESUME_TIMEOUT_SECONDS
    clock: Callable[[], float] = time.monotonic
    sleep: Callable[[float], None] = time.sleep


@dataclass(frozen=True)
class RecoveryReport:
    """What the log, the device samples and the resumption showed."""

    lost: int
    restored: int
    ordered: bool
    resumed_seconds: float | None
    samples: int
    missing_samples: tuple[int, ...]
    resume_timeout_seconds: float = RESUME_TIMEOUT_SECONDS

    @property
    def resumed_in_time(self) -> bool:
        """Whether audio came back inside the limit."""
        return (
            self.resumed_seconds is not None and self.resumed_seconds <= self.resume_timeout_seconds
        )

    @property
    def passed(self) -> bool:
        """Whether the log shows one recovery and the microphone stayed listed."""
        return (
            self.lost == 1
            and self.restored == 1
            and self.ordered
            and self.resumed_in_time
            and not self.missing_samples
        )


def parse_timestamp(text: str) -> float:
    """Convert one `log show` timestamp to seconds since the epoch."""
    for pattern in TIMESTAMP_FORMATS:
        try:
            return datetime.strptime(text, pattern).timestamp()  # noqa: DTZ007 - both carry %z
        except ValueError:
            continue
    message = f"unrecognized log timestamp {text!r}"
    raise ValueError(message)


def parse_log_entries(output: str) -> tuple[RecoveryEvent, ...]:
    """Read the recovery events from `log show --style json` output."""
    entries: JSONValue = json.loads(output)
    if not isinstance(entries, list):
        message = "the log output is not a JSON list"
        raise TypeError(message)
    events: list[RecoveryEvent] = []
    for entry in entries:
        if not isinstance(entry, dict):
            message = "a log entry is not an object"
            raise TypeError(message)
        text = entry.get("eventMessage")
        if text not in (LOST_MESSAGE, RESTORED_MESSAGE):
            continue
        timestamp = entry.get("timestamp")
        if not isinstance(timestamp, str):
            message = "a recovery log entry has no timestamp"
            raise TypeError(message)
        events.append(RecoveryEvent(message=text, timestamp=parse_timestamp(timestamp)))
    events.sort(key=lambda event: (event.timestamp, event.message))
    return tuple(events)


def has_virtual_mic(devices: Sequence[AudioDeviceReport]) -> bool:
    """Whether the app's virtual microphone is listed in an audio report."""
    return any(any(marker in device.name for marker in VIRTUAL_MIC_MARKERS) for device in devices)


def headset_input_present(devices: Sequence[AudioDeviceReport], name: str) -> bool:
    """Whether the headset offers its input again."""
    return any(device.name == name and device.has_input for device in devices)


def read_recovery_events(
    since: float,
    runner: CommandRunner = run_command,
) -> tuple[RecoveryEvent, ...]:
    """Read the app's recovery events from the log, keeping those at or after `since`."""
    predicate = f'subsystem == "{SUBSYSTEM}" AND category == "{CATEGORY}"'
    result = runner(
        [LOG, "show", "--last", LOG_WINDOW, "--style", "json", "--predicate", predicate]
    )
    if result.returncode != 0:
        message = f"log show exited with status {result.returncode}"
        raise RuntimeError(message)
    return tuple(event for event in parse_log_entries(result.stdout) if event.timestamp >= since)


def wait_for_event(
    read: Callable[[], Sequence[RecoveryEvent]],
    message: str,
    since: float,
    plan: WaitPlan | None = None,
) -> RecoveryEvent | None:
    """Poll the log until the named event appears or the tester's time runs out."""
    plan = WaitPlan() if plan is None else plan
    started = plan.clock()
    while True:
        matches = [
            event for event in read() if event.message == message and event.timestamp >= since
        ]
        if matches:
            return matches[0]
        elapsed = plan.clock() - started
        if elapsed >= plan.event_timeout_seconds:
            return None
        plan.sleep(min(plan.poll_seconds, plan.event_timeout_seconds - elapsed))


def wait_for_resume(
    headset_name: str,
    read: Callable[[], Sequence[AudioDeviceReport]],
    plan: WaitPlan | None = None,
) -> float | None:
    """Poll the device list until the headset input is back and report how long it took."""
    plan = WaitPlan() if plan is None else plan
    started = plan.clock()
    while True:
        if headset_input_present(read(), headset_name):
            return plan.clock() - started
        elapsed = plan.clock() - started
        if elapsed >= plan.resume_timeout_seconds:
            return None
        plan.sleep(min(plan.sample_seconds, plan.resume_timeout_seconds - elapsed))


class VirtualMicSamples:
    """The virtual microphone's presence at each one-second sample during the check."""

    def __init__(
        self,
        read: Callable[[], Sequence[AudioDeviceReport]],
        plan: WaitPlan,
    ) -> None:
        self._read = read
        self._plan = plan
        self._next = plan.clock()
        self._present: list[bool] = []

    @property
    def present(self) -> tuple[bool, ...]:
        """One entry per sample, in order."""
        return tuple(self._present)

    def sample_if_due(self) -> None:
        """Read the device list when the sample interval has elapsed."""
        now = self._plan.clock()
        if now < self._next:
            return
        self._present.append(has_virtual_mic(self._read()))
        self._next = now + self._plan.sample_seconds


def verify(
    events: Sequence[RecoveryEvent],
    samples: Sequence[bool],
    resumed_seconds: float | None,
    plan: WaitPlan | None = None,
) -> RecoveryReport:
    """Check the log, the samples and the resumption against the acceptance limits."""
    plan = WaitPlan() if plan is None else plan
    unique = {(event.message, event.timestamp): event for event in events}
    ordered_events = sorted(unique.values(), key=lambda event: event.timestamp)
    lost = [event for event in ordered_events if event.message == LOST_MESSAGE]
    restored = [event for event in ordered_events if event.message == RESTORED_MESSAGE]
    ordered = bool(lost and restored and restored[0].timestamp > lost[0].timestamp)
    return RecoveryReport(
        lost=len(lost),
        restored=len(restored),
        ordered=ordered,
        resumed_seconds=resumed_seconds,
        samples=len(samples),
        missing_samples=tuple(index for index, present in enumerate(samples) if not present),
        resume_timeout_seconds=plan.resume_timeout_seconds,
    )


def run(arguments: list[str]) -> int:
    """Run the reconnect check and return a process status."""
    parser = _parser()
    args = parser.parse_args(arguments)
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    plan = WaitPlan(event_timeout_seconds=args.timeout)
    try:
        headset = find_headset(read_audio_devices())
        sampler = VirtualMicSamples(read_audio_devices, plan)
        sampler.sample_if_due()
        since = time.time() - 1

        def read_events() -> tuple[RecoveryEvent, ...]:
            sampler.sample_if_due()
            return read_recovery_events(since)

        sys.stdout.write(f"Headset: {headset.name}\n")
        sys.stdout.write("Put the headset in its case; waiting for its input device to go away.\n")
        lost = wait_for_event(read_events, LOST_MESSAGE, since, plan)
        if lost is None:
            sys.stderr.write(f"reconnect: no {LOST_MESSAGE} event appeared\n")
            return 2

        sys.stdout.write("Take the headset out of its case; waiting for it to come back.\n")
        restored = wait_for_event(read_events, RESTORED_MESSAGE, lost.timestamp, plan)
        if restored is None:
            sys.stderr.write(f"reconnect: no {RESTORED_MESSAGE} event appeared\n")
            return 2

        def read_devices() -> tuple[AudioDeviceReport, ...]:
            sampler.sample_if_due()
            return read_audio_devices()

        resumed = wait_for_resume(headset.name, read_devices, plan)
        sampler.sample_if_due()
        report = verify(read_recovery_events(since), sampler.present, resumed, plan)
    except (OSError, RuntimeError, ValueError) as error:
        sys.stderr.write(f"reconnect: {error}\n")
        return 2

    _write_report(report)
    return 0 if report.passed else 1


def _write_report(report: RecoveryReport) -> None:
    resumed = (
        "no resumption inside the limit"
        if report.resumed_seconds is None
        else f"{report.resumed_seconds:.2f} s"
    )
    sys.stdout.write(f"Lost events: {report.lost}, restored events: {report.restored}\n")
    sys.stdout.write(f"Resumed audio: {resumed}\n")
    sys.stdout.write(
        f"Device samples: {report.samples}, without the virtual microphone: "
        f"{len(report.missing_samples)}\n"
    )
    if report.passed:
        sys.stdout.write("PASS: the path recovered across one device reconnect\n")
        return
    if report.lost != 1 or report.restored != 1:
        sys.stderr.write("reconnect: the log does not hold exactly one loss and one return\n")
    if not report.ordered:
        sys.stderr.write("reconnect: the return event is not after the loss\n")
    if not report.resumed_in_time:
        sys.stderr.write("reconnect: audio did not resume within the limit\n")
    if report.missing_samples:
        sys.stderr.write("reconnect: the virtual microphone was missing from a device sample\n")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Check that the microphone path recovers when its input device returns.",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=EVENT_TIMEOUT_SECONDS,
        help="seconds the tester has for each step",
    )
    return parser


def main() -> None:
    """Run the reconnect check from the command line."""
    root = repo_root(Path(__file__))
    if "--print-root" in sys.argv[1:]:
        sys.stdout.write(f"{root}\n")
        return
    raise SystemExit(run(sys.argv[1:]))


if __name__ == "__main__":
    main()
