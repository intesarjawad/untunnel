"""Checks that a forced quit with a tap running leaves no tap device behind.

The tester starts a call in the tapped app with "Also restore the other person" on. The check
force-quits the app, relaunches it and reads `system_profiler SPAudioDataType -json`: no device
may still carry the tap's name or be an Untunnel aggregate, and the tester confirms the tapped app
plays out loud again. The tap's own aggregate is private and never listed while it runs, so the
device list only shows what a crash left behind.
"""

import argparse
import json
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path

from untunnel_tools.measure.autoroute import WaitPlan, append_result
from untunnel_tools.measure.cpu import CommandRunner, resolve_pid, run_command
from untunnel_tools.measure.engage import SYSTEM_PROFILER, VIRTUAL_MIC_MARKERS
from untunnel_tools.measure.failsafe import (
    DEFAULT_APP,
    DEFAULT_PROCESS_NAME,
    PROCESS_TIMEOUT_SECONDS,
    ask_yes_no,
    confirm,
    force_kill,
    launch_app,
    wait_for_process,
)
from untunnel_tools.paths import repo_root

TAP_NAME = "Untunnel Tap"
AGGREGATE_MARKER = "aggregate"
POLL_SECONDS = 0.5
RESULTS = Path("docs") / "results.md"

type JSONValue = dict[str, JSONValue] | list[JSONValue] | str | int | float | bool | None


@dataclass(frozen=True)
class ListedDevice:
    """One device name and transport from the system audio report."""

    name: str
    transport: str


@dataclass(frozen=True)
class TeardownReport:
    """What the relaunch, the device list and the tester showed after the forced quit."""

    relaunched: bool
    strays: tuple[str, ...]
    plays_again: bool

    @property
    def passed(self) -> bool:
        """Whether the app came back, left no tap device and the tapped app is audible."""
        return self.relaunched and not self.strays and self.plays_again


def parse_listing(output: str) -> tuple[ListedDevice, ...]:
    """Read every named device from `system_profiler SPAudioDataType -json` output."""
    report: JSONValue = json.loads(output)
    if not isinstance(report, dict):
        message = "the audio report is not a JSON object"
        raise TypeError(message)
    sections = report.get("SPAudioDataType")
    if not isinstance(sections, list) or not sections:
        message = "the audio report lists no devices"
        raise ValueError(message)
    devices: list[ListedDevice] = []
    for section in sections:
        items = section.get("_items") if isinstance(section, dict) else None
        if not isinstance(items, list):
            message = "an audio report section has no items"
            raise TypeError(message)
        for item in items:
            if not isinstance(item, dict):
                message = "an audio report item is not an object"
                raise TypeError(message)
            name = item.get("_name")
            transport = item.get("coreaudio_device_transport")
            if isinstance(name, str) and name:
                devices.append(ListedDevice(name, transport if isinstance(transport, str) else ""))
    return tuple(devices)


def find_strays(devices: Sequence[ListedDevice]) -> tuple[str, ...]:
    """Name every device that is the tap itself or an aggregate under the app's name."""
    return tuple(
        device.name
        for device in devices
        if device.name == TAP_NAME
        or (
            AGGREGATE_MARKER in device.transport.lower()
            and any(marker.lower() in device.name.lower() for marker in VIRTUAL_MIC_MARKERS)
        )
    )


def read_listing(runner: CommandRunner = run_command) -> tuple[ListedDevice, ...]:
    """Read the live device list from the system report."""
    result = runner([SYSTEM_PROFILER, "SPAudioDataType", "-json"])
    if result.returncode != 0:
        message = f"system_profiler exited with status {result.returncode}"
        raise RuntimeError(message)
    return parse_listing(result.stdout)


def wait_for_clean(
    read: Callable[[], Sequence[ListedDevice]],
    plan: WaitPlan,
) -> tuple[str, ...]:
    """Poll until no stray device is listed, and return those still listed at the limit."""
    started = plan.clock()
    while True:
        strays = find_strays(read())
        if not strays:
            return ()
        elapsed = plan.clock() - started
        if elapsed >= plan.timeout_seconds:
            return strays
        plan.sleep(min(plan.poll_seconds, plan.timeout_seconds - elapsed))


def run(arguments: list[str]) -> int:
    """Run the teardown check and return a process status."""
    parser = _parser()
    args = parser.parse_args(arguments)
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    plan = WaitPlan(timeout_seconds=args.timeout, poll_seconds=POLL_SECONDS)
    try:
        report = teardown_case(args.pid, args.process_name, args.app, plan)
    except (LookupError, OSError, RuntimeError, TypeError, ValueError) as error:
        sys.stderr.write(f"teardown: {error}\n")
        return 2

    append_result(
        repo_root(Path(__file__)) / RESULTS,
        "teardown",
        passed=report.passed,
        detail=f"relaunched {report.relaunched}; strays {', '.join(report.strays) or 'none'}; "
        f"tapped app audible {report.plays_again}",
    )
    _write_report(report)
    return 0 if report.passed else 1


def teardown_case(
    pid: int | None,
    process_name: str,
    app: Path,
    plan: WaitPlan,
) -> TeardownReport:
    """Force-quit the app with a tap active, relaunch it and look for what was left behind."""
    confirm(
        "Turn on 'Also restore the other person' and start a call in the app to tap. "
        "Press Return once that app is silent in the room: "
    )
    target = pid if pid is not None else resolve_pid(process_name, run_command)
    sys.stdout.write(f"Force-quitting process {target}.\n")
    force_kill(target)
    launch_app(app)
    relaunched = wait_for_process(process_name, plan)
    strays = wait_for_clean(read_listing, plan)
    plays_again = ask_yes_no("Does the tapped app play out loud again?")
    return TeardownReport(relaunched=relaunched, strays=strays, plays_again=plays_again)


def _write_report(report: TeardownReport) -> None:
    if report.passed:
        sys.stdout.write("PASS: the forced quit left no tap device and the app plays again\n")
        return
    if not report.relaunched:
        sys.stderr.write("teardown: the app did not come back\n")
    if report.strays:
        sys.stderr.write(f"teardown: still listed after the relaunch: {', '.join(report.strays)}\n")
    if not report.plays_again:
        sys.stderr.write("teardown: the tapped app did not play out loud again\n")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Check that a forced quit with a tap running leaves no tap device behind.",
    )
    parser.add_argument("--pid", type=int, help="process id to signal instead of looking it up")
    parser.add_argument("--process-name", default=DEFAULT_PROCESS_NAME)
    parser.add_argument("--app", type=Path, default=DEFAULT_APP)
    parser.add_argument(
        "--timeout",
        type=float,
        default=PROCESS_TIMEOUT_SECONDS,
        help="seconds to wait for the relaunch and for the tap device to be gone",
    )
    return parser


def main() -> None:
    """Run the teardown check from the command line."""
    root = repo_root(Path(__file__))
    if "--print-root" in sys.argv[1:]:
        sys.stdout.write(f"{root}\n")
        return
    raise SystemExit(run(sys.argv[1:]))


if __name__ == "__main__":
    main()
