"""Times a first install from the published install line to the first restored clip.

Run on a fresh macOS user account. The tester answers the password prompt and the microphone
prompt, presses Record in Hear Yourself and chooses After; the clock stops at the app's
`first_ab_played` log event. Setup's own step timings are printed so a slow run names its
slowest step.
"""

import argparse
import json
import shlex
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path

from untunnel_tools.measure.autoroute import WaitPlan, append_result
from untunnel_tools.measure.cpu import CommandRunner, run_command
from untunnel_tools.measure.reconnect import CATEGORY, LOG, SUBSYSTEM, parse_timestamp
from untunnel_tools.paths import repo_root

INSTALL_URL = "https://untunnel.intesarjawad.com/install.sh"
FORMULA = "intesarjawad/tap/untunnel"
FIRST_SOUND = "first_ab_played"
TIMINGS_SCHEMA_VERSION = 1
# Install line to the first restored clip on a fresh account, prompts answered by a person.
BUDGET_SECONDS = 120.0
DEFAULT_TIMEOUT_SECONDS = 600.0
POLL_SECONDS = 1.0
LOG_WINDOW = "15m"
RESULTS = Path("docs") / "results.md"
INSTALL_PATHS = ("curl", "brew")

type JSONValue = dict[str, JSONValue] | list[JSONValue] | str | int | float | bool | None


@dataclass(frozen=True)
class StepTiming:
    """One setup step as `setup --timings-json` recorded it."""

    step: int
    name: str
    seconds: float


@dataclass(frozen=True)
class ColdStartReport:
    """Setup's steps and the time from the install line to the first restored clip."""

    path: str
    steps: tuple[StepTiming, ...]
    total_seconds: float | None
    budget_seconds: float = BUDGET_SECONDS

    @property
    def passed(self) -> bool:
        """Whether setup timed its steps and the clip played within the budget."""
        return (
            bool(self.steps)
            and self.total_seconds is not None
            and self.total_seconds <= self.budget_seconds
        )


def install_commands(path: str, timings: Path) -> tuple[list[str], ...]:
    """Return the published install commands, with setup writing its step timings."""
    flags = ["--yes", "--timings-json", str(timings)]
    if path == "curl":
        line = f"curl -fsSL {INSTALL_URL} | sh -s -- {shlex.join(flags)}"
        return (["/bin/sh", "-c", line],)
    if path == "brew":
        return (["brew", "install", FORMULA], ["untunnel", "setup", *flags])
    message = f"unknown install path {path!r}; expected one of {', '.join(INSTALL_PATHS)}"
    raise ValueError(message)


def read_timings(text: str) -> tuple[StepTiming, ...]:
    """Parse setup's timings document, in step order."""
    document: JSONValue = json.loads(text)
    if not isinstance(document, dict):
        message = "the timings document is not a JSON object"
        raise TypeError(message)
    version = document.get("schema_version")
    if version != TIMINGS_SCHEMA_VERSION:
        message = f"the timings document has schema version {version}, not 1"
        raise ValueError(message)
    entries = document.get("steps")
    if not isinstance(entries, list) or not entries:
        message = "the timings document has no steps"
        raise ValueError(message)
    steps: list[StepTiming] = []
    for entry in entries:
        if not isinstance(entry, dict):
            message = "a timings entry is not an object"
            raise TypeError(message)
        step, name, seconds = entry.get("step"), entry.get("name"), entry.get("seconds")
        if (
            type(step) is not int
            or not isinstance(name, str)
            or not isinstance(seconds, int | float)
            or isinstance(seconds, bool)
        ):
            message = f"a timings entry is incomplete: {entry}"
            raise TypeError(message)
        steps.append(StepTiming(step=step, name=name, seconds=float(seconds)))
    return tuple(sorted(steps, key=lambda timing: timing.step))


def parse_first_sound(output: str) -> tuple[float, ...]:
    """Return the epoch times of every first-clip event in `log show --style json` output."""
    entries: JSONValue = json.loads(output)
    if not isinstance(entries, list):
        message = "the log output is not a JSON list"
        raise TypeError(message)
    stamps: list[float] = []
    for entry in entries:
        if not isinstance(entry, dict):
            message = "a log entry is not an object"
            raise TypeError(message)
        if entry.get("eventMessage") != FIRST_SOUND:
            continue
        timestamp = entry.get("timestamp")
        if not isinstance(timestamp, str):
            message = f"a {FIRST_SOUND} entry has no timestamp"
            raise TypeError(message)
        stamps.append(parse_timestamp(timestamp))
    return tuple(sorted(stamps))


def read_first_sound(since: float, runner: CommandRunner = run_command) -> tuple[float, ...]:
    """Read the app's first-clip events from the log, keeping those at or after `since`."""
    predicate = f'subsystem == "{SUBSYSTEM}" AND category == "{CATEGORY}"'
    result = runner(
        [LOG, "show", "--last", LOG_WINDOW, "--style", "json", "--predicate", predicate]
    )
    if result.returncode != 0:
        message = f"log show exited with status {result.returncode}"
        raise RuntimeError(message)
    return tuple(stamp for stamp in parse_first_sound(result.stdout) if stamp >= since)


def wait_for_first_sound(
    read: Callable[[], Sequence[float]],
    started: float,
    plan: WaitPlan,
) -> float | None:
    """Poll the log until the first clip plays; return seconds since `started`, an epoch time."""
    waited_from = plan.clock()
    while True:
        stamps = read()
        if stamps:
            return min(stamps) - started
        elapsed = plan.clock() - waited_from
        if elapsed >= plan.timeout_seconds:
            return None
        plan.sleep(min(plan.poll_seconds, plan.timeout_seconds - elapsed))


def run_visible(command: list[str]) -> int:
    """Run one install command on the tester's terminal, so its prompts can be answered."""
    # The commands are the fixed install lines above, never caller input.
    return subprocess.run(command, check=False).returncode  # noqa: S603


def run(arguments: list[str]) -> int:
    """Run the cold-start measurement and return a process status."""
    parser = _parser()
    args = parser.parse_args(arguments)
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    plan = WaitPlan(timeout_seconds=args.timeout, poll_seconds=POLL_SECONDS)
    started = time.time()
    try:
        with tempfile.TemporaryDirectory(prefix="untunnel-cold-start-") as work:
            timings = Path(work) / "timings.json"
            for command in install_commands(args.path, timings):
                status = run_visible(command)
                if status != 0:
                    sys.stderr.write(f"cold-start: {command[0]} exited with status {status}\n")
                    return 2
            steps = read_timings(timings.read_text(encoding="utf-8"))
        sys.stdout.write("Press Record in Hear Yourself, then choose After.\n")
        total = wait_for_first_sound(lambda: read_first_sound(started), started, plan)
    except (OSError, RuntimeError, TypeError, ValueError) as error:
        sys.stderr.write(f"cold-start: {error}\n")
        return 2

    report = ColdStartReport(path=args.path, steps=steps, total_seconds=total)
    append_result(
        repo_root(Path(__file__)) / RESULTS,
        f"cold start ({report.path})",
        passed=report.passed,
        detail=_detail(report),
    )
    _write_report(report)
    return 0 if report.passed else 1


def _detail(report: ColdStartReport) -> str:
    steps = ", ".join(f"{timing.name} {timing.seconds:.1f} s" for timing in report.steps)
    total = "no clip played" if report.total_seconds is None else f"{report.total_seconds:.1f} s"
    return f"total {total}; {steps}"


def _write_report(report: ColdStartReport) -> None:
    for timing in report.steps:
        sys.stdout.write(f"[{timing.step}] {timing.name}: {timing.seconds:.2f} s\n")
    if report.total_seconds is None:
        sys.stderr.write(f"cold-start: the app never logged {FIRST_SOUND}\n")
        return
    sys.stdout.write(
        f"total: {report.total_seconds:.1f} s (budget {report.budget_seconds:.0f} s)\n"
    )
    if report.passed:
        sys.stdout.write("PASS\n")
    else:
        sys.stderr.write("cold-start: the first clip played after the budget\n")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Time a first install from the install line to the first restored clip.",
    )
    parser.add_argument(
        "--path",
        choices=INSTALL_PATHS,
        required=True,
        help="which published install line to run",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=DEFAULT_TIMEOUT_SECONDS,
        help="seconds to wait for the first clip after setup finishes",
    )
    return parser


def main() -> None:
    """Run the cold-start measurement from the command line."""
    root = repo_root(Path(__file__))
    if "--print-root" in sys.argv[1:]:
        sys.stdout.write(f"{root}\n")
        return
    raise SystemExit(run(sys.argv[1:]))


if __name__ == "__main__":
    main()
