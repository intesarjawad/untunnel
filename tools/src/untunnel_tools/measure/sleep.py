"""Checks that the app holds no idle-sleep assertion in the two states that matter.

`pmset -g assertions` reports one system-wide `PreventUserIdleSystemSleep` count. The check
reads it in a baseline state, gives the tester 120 seconds to reach the comparison state, and
reads it again. A pass means the count did not change.
"""

import argparse
import re
import sys
import time
from dataclasses import dataclass
from pathlib import Path

from untunnel_tools.measure.autoroute import append_result
from untunnel_tools.measure.cpu import CommandRunner, run_command
from untunnel_tools.paths import repo_root

PMSET = "/usr/bin/pmset"
ASSERTION = "PreventUserIdleSystemSleep"
DWELL_SECONDS = 120.0
RESULTS = Path("docs") / "results.md"

MODES = ("standby", "quit")
INSTRUCTIONS = {
    "standby": (
        "Quit Untunnel and keep the headset connected; that is the baseline.",
        "Open Untunnel and leave it on Standby; the headset stays connected.",
    ),
    "quit": (
        "Quit Untunnel and keep the plug-in installed; that is the baseline.",
        "Run `make -C driver uninstall` now; the comparison is the plug-in removed.",
    ),
}


@dataclass(frozen=True)
class SleepReport:
    """The assertion count before and after the tester changed the state."""

    mode: str
    baseline: int
    after: int

    @property
    def passed(self) -> bool:
        """Whether the app held no additional sleep assertion."""
        return self.baseline == self.after


def parse_prevent_idle_count(output: str) -> int:
    """Read the system-wide assertion count from `pmset -g assertions`."""
    pattern = re.compile(rf"^\s*{ASSERTION}\s+(\d+)\s*$", re.MULTILINE)
    match = pattern.search(output)
    if match is None:
        message = f"pmset reported no {ASSERTION} count"
        raise ValueError(message)
    return int(match.group(1))


def read_prevent_idle_count(runner: CommandRunner = run_command) -> int:
    """Read the live system-wide assertion count."""
    result = runner([PMSET, "-g", "assertions"])
    if result.returncode != 0:
        message = f"pmset exited with status {result.returncode}"
        raise RuntimeError(message)
    return parse_prevent_idle_count(result.stdout)


def verify(mode: str, baseline: int, after: int) -> SleepReport:
    """Turn the two counts into the acceptance report."""
    if mode not in MODES:
        message = f"unknown sleep mode {mode!r}"
        raise ValueError(message)
    return SleepReport(mode=mode, baseline=baseline, after=after)


def wait(seconds: float) -> None:
    """Give the tester the dwell time to change the state under test."""
    time.sleep(seconds)


def run(arguments: list[str]) -> int:
    """Run the sleep check and return a process status."""
    parser = _parser()
    args = parser.parse_args(arguments)
    baseline_text, after_text = INSTRUCTIONS[args.mode]
    try:
        baseline = read_prevent_idle_count()
        sys.stdout.write(f"Baseline {ASSERTION}: {baseline}\n")
        sys.stdout.write(f"{baseline_text}\n")
        sys.stdout.write(f"{after_text}\n")
        sys.stdout.write(f"Waiting {DWELL_SECONDS:.0f} s for the state to change.\n")
        wait(DWELL_SECONDS)
        after = read_prevent_idle_count()
        report = verify(args.mode, baseline, after)
    except (OSError, RuntimeError, ValueError) as error:
        sys.stderr.write(f"sleep: {error}\n")
        return 2

    append_result(
        repo_root(Path(__file__)) / RESULTS,
        f"sleep-{report.mode}",
        passed=report.passed,
        detail=f"baseline {report.baseline}; after {report.after}",
    )
    sys.stdout.write(f"After {ASSERTION}: {report.after}\n")
    if report.passed:
        sys.stdout.write(f"PASS: the {report.mode} state added no idle-sleep assertion\n")
        return 0
    sys.stderr.write(f"sleep: the count changed from {report.baseline} to {report.after}\n")
    if report.mode == "standby":
        sys.stderr.write(
            "sleep: the standby result is recorded; with SLEEP_HELD it is expected to fail "
            "and the quit check must pass\n"
        )
    return 1


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Compare the idle-sleep assertion count in two app states.",
    )
    parser.add_argument("--mode", choices=MODES, required=True)
    return parser


def main() -> None:
    """Run the sleep check from the command line."""
    root = repo_root(Path(__file__))
    if "--print-root" in sys.argv[1:]:
        sys.stdout.write(f"{root}\n")
        return
    raise SystemExit(run(sys.argv[1:]))


if __name__ == "__main__":
    main()
