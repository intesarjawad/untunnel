"""Checks that a connecting headset moves the default input to the app and back.

The tester takes the headset out of its case, so macOS performs the switch itself; this check
only reads the system default input before, during and after. It passes when the app's
microphone became the default without a device being chosen and the previous device returned
after the app quit.
"""

import argparse
import json
import sys
import time
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Protocol, cast

from untunnel_tools.measure.cpu import CommandRunner, run_command
from untunnel_tools.measure.engage import InputStream, load_sounddevice
from untunnel_tools.paths import repo_root

SYSTEM_PROFILER = "/usr/sbin/system_profiler"
VIRTUAL_MIC_MARKERS = ("Untunnel",)
DEFAULT_INPUT_KEYS = (
    "coreaudio_default_audio_input_device",
    "coreaudio_default_audio_system_device",
)
ENGAGE_TIMEOUT_SECONDS = 30.0
RETURN_TIMEOUT_SECONDS = 30.0
READER_SECONDS = 3.0
POLL_SECONDS = 0.5
RESULTS = Path("docs") / "results.md"

type JSONValue = dict[str, JSONValue] | list[JSONValue] | str | int | float | bool | None


class DefaultInputModule(Protocol):
    """The call this check makes on the lazily imported sounddevice module."""

    def InputStream(self, *, channels: int) -> InputStream:  # noqa: N802
        """Open a readable stream on the system default input."""
        ...


@dataclass(frozen=True)
class WaitPlan:
    """How long the tester has for each step and how often to re-read the report."""

    timeout_seconds: float = ENGAGE_TIMEOUT_SECONDS
    poll_seconds: float = POLL_SECONDS
    clock: Callable[[], float] = time.monotonic
    sleep: Callable[[float], None] = time.sleep


@dataclass(frozen=True)
class RouteReport:
    """The default input before, during and after the automatic switch."""

    previous: str | None
    engaged: str | None
    restored: str | None
    engaged_seconds: float | None
    restored_seconds: float | None

    @property
    def passed(self) -> bool:
        """Whether the app engaged by itself and the previous device came back."""
        return (
            self.previous is not None
            and self.engaged is not None
            and is_virtual_mic(self.engaged)
            and self.restored == self.previous
        )


def parse_default_input(output: str) -> str | None:
    """Read the system default input's name from `system_profiler` output."""
    report: JSONValue = json.loads(output)
    if not isinstance(report, dict):
        message = "the audio report is not a JSON object"
        raise TypeError(message)
    sections = report.get("SPAudioDataType")
    if not isinstance(sections, list) or not sections:
        message = "the audio report lists no devices"
        raise ValueError(message)

    for section in sections:
        if not isinstance(section, dict):
            message = "an audio report section is not an object"
            raise TypeError(message)
        items = section.get("_items")
        if not isinstance(items, list):
            message = "an audio report section has no items"
            raise TypeError(message)
        for item in items:
            if not isinstance(item, dict):
                message = "an audio report item is not an object"
                raise TypeError(message)
            name = item.get("_name")
            if not isinstance(name, str) or not name:
                continue
            if any(item.get(key) == "spaudio_yes" for key in DEFAULT_INPUT_KEYS):
                return name
    return None


def is_virtual_mic(name: str) -> bool:
    """Whether a device name belongs to the app's microphone or its fallback."""
    return any(marker in name for marker in VIRTUAL_MIC_MARKERS)


def read_default_input(runner: CommandRunner = run_command) -> str | None:
    """Read the live system default input without opening a device."""
    result = runner([SYSTEM_PROFILER, "SPAudioDataType", "-json"])
    if result.returncode != 0:
        message = f"system_profiler exited with status {result.returncode}"
        raise RuntimeError(message)
    return parse_default_input(result.stdout)


def open_default_reader(hold_seconds: float) -> None:
    """Read the system default input for a moment, the way a calling application would.

    The module is imported after the switch, because PortAudio reads the default device once
    when it loads.
    """
    module = cast("DefaultInputModule", load_sounddevice())
    stream = module.InputStream(channels=1)
    stream.start()
    try:
        time.sleep(hold_seconds)
    finally:
        stream.stop()
        stream.close()


def wait_for_virtual(
    read: Callable[[], str | None],
    plan: WaitPlan | None = None,
) -> tuple[str, float] | None:
    """Poll until the app's microphone becomes the default input."""
    return _wait_for(read, is_virtual_mic, plan)


def wait_for_previous(
    read: Callable[[], str | None],
    previous: str,
    plan: WaitPlan | None = None,
) -> tuple[str, float] | None:
    """Poll until the previous device is the default input again."""
    return _wait_for(read, lambda name: name == previous, plan)


def verify(
    previous: str | None,
    engaged: tuple[str, float] | None,
    restored: tuple[str, float] | None,
) -> RouteReport:
    """Turn the three readings into the acceptance report."""
    return RouteReport(
        previous=previous,
        engaged=None if engaged is None else engaged[0],
        restored=None if restored is None else restored[0],
        engaged_seconds=None if engaged is None else engaged[1],
        restored_seconds=None if restored is None else restored[1],
    )


def append_result(
    path: Path,
    check: str,
    *,
    passed: bool,
    detail: str,
    stamp: datetime | None = None,
) -> None:
    """Append one result row to the measurement log."""
    path.parent.mkdir(parents=True, exist_ok=True)
    when = datetime.now(tz=UTC).astimezone() if stamp is None else stamp
    status = "PASS" if passed else "FAIL"
    with path.open("a", encoding="utf-8") as handle:
        handle.write(f"| {when.isoformat(timespec='seconds')} | {check} | {status} | {detail} |\n")


def run(arguments: list[str]) -> int:
    """Run the auto-route check and return a process status."""
    parser = _parser()
    args = parser.parse_args(arguments)
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    plan = WaitPlan(timeout_seconds=args.timeout)
    try:
        previous = _starting_default(read_default_input())
        sys.stdout.write(f"Default input before: {previous}\n")
        sys.stdout.write("Take the headset out of its case and wait for the switch.\n")
        engaged = wait_for_virtual(read_default_input, plan)
        restored = None
        if engaged is not None:
            sys.stdout.write(
                f"Untunnel engaged; reading the default input for {READER_SECONDS:.0f} s.\n"
            )
            open_default_reader(READER_SECONDS)
            sys.stdout.write("Quit Untunnel now.\n")
            restored = wait_for_previous(read_default_input, previous, plan)
        report = verify(previous, engaged, restored)
    except (OSError, RuntimeError, ValueError) as error:
        sys.stderr.write(f"autoroute: {error}\n")
        return 2

    append_result(
        repo_root(Path(__file__)) / RESULTS,
        "auto-route",
        passed=report.passed,
        detail=f"previous {report.previous}; engaged {report.engaged}; restored {report.restored}",
    )
    _write_report(report)
    return 0 if report.passed else 1


def _starting_default(name: str | None) -> str:
    if name is None:
        message = "the audio report names no default input"
        raise ValueError(message)
    if is_virtual_mic(name):
        message = "the app's microphone is already the default; quit Untunnel first"
        raise ValueError(message)
    return name


def _write_report(report: RouteReport) -> None:
    if report.passed:
        sys.stdout.write("PASS: the app engaged without a device being chosen and quit restored\n")
        return
    if report.engaged is None:
        sys.stderr.write("autoroute: the app's microphone never became the default\n")
    elif not is_virtual_mic(report.engaged):
        sys.stderr.write(
            "autoroute: the default moved to a device other than the app's microphone\n"
        )
    if report.restored != report.previous:
        sys.stderr.write("autoroute: the previous default did not return after quit\n")


def _wait_for(
    read: Callable[[], str | None],
    accept: Callable[[str], bool],
    plan: WaitPlan | None,
) -> tuple[str, float] | None:
    plan = WaitPlan() if plan is None else plan
    started = plan.clock()
    while True:
        name = read()
        if name is not None and accept(name):
            return name, plan.clock() - started
        elapsed = plan.clock() - started
        if elapsed >= plan.timeout_seconds:
            return None
        plan.sleep(min(plan.poll_seconds, plan.timeout_seconds - elapsed))


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Check that a connecting headset engages auto-route and quit restores.",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=ENGAGE_TIMEOUT_SECONDS,
        help="seconds the tester has for each step",
    )
    return parser


def main() -> None:
    """Run the auto-route check from the command line."""
    root = repo_root(Path(__file__))
    if "--print-root" in sys.argv[1:]:
        sys.stdout.write(f"{root}\n")
        return
    raise SystemExit(run(sys.argv[1:]))


if __name__ == "__main__":
    main()
