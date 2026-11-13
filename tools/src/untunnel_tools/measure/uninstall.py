"""Checks that uninstall removes every installed file and gives the default input back.

The list of paths comes from the installed app's own `uninstall --dry-run`, the same list the
real uninstall walks, so this check cannot drift from it. The app's uninstall does the
removal; the tester types the password for the audio plug-in.
"""

import argparse
import os
import subprocess
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path

from untunnel_tools.measure.autoroute import (
    RETURN_TIMEOUT_SECONDS,
    WaitPlan,
    append_result,
    is_virtual_mic,
    read_default_input,
    wait_for_previous,
)
from untunnel_tools.measure.cpu import CommandRunner, run_command
from untunnel_tools.paths import repo_root

EXECUTABLE = Path.home() / "Applications" / "Untunnel.app" / "Contents" / "MacOS" / "Untunnel"
REMOVE_HEADING = "Would remove:"
POLL_SECONDS = 0.5
RESULTS = Path("docs") / "results.md"


@dataclass(frozen=True)
class UninstallReport:
    """What was left on disk and which input macOS returned to."""

    previous: str
    restored: str | None
    remaining: tuple[Path, ...]

    @property
    def passed(self) -> bool:
        """Whether every path is gone and the previous default input is back."""
        return not self.remaining and self.restored == self.previous


def parse_dry_run(output: str) -> tuple[Path, ...]:
    """Read the indented paths under "Would remove:" in `uninstall --dry-run` output."""
    lines = output.splitlines()
    paths: list[Path] = []
    if REMOVE_HEADING in lines:
        for line in lines[lines.index(REMOVE_HEADING) + 1 :]:
            if not line.startswith("  "):
                break
            paths.append(Path(line.strip()))
    if not paths:
        message = "uninstall --dry-run listed no paths"
        raise ValueError(message)
    return tuple(paths)


def read_installed_paths(
    executable: Path,
    runner: CommandRunner = run_command,
) -> tuple[Path, ...]:
    """Ask the installed app which paths its uninstall removes."""
    result = runner([str(executable), "uninstall", "--dry-run"])
    if result.returncode != 0:
        message = f"uninstall --dry-run exited with status {result.returncode}"
        raise RuntimeError(message)
    return parse_dry_run(result.stdout)


def present(path: Path) -> bool:
    """Whether anything, a dangling link included, is still at a path."""
    return os.path.lexists(path)


def wait_for_removal(
    paths: Sequence[Path],
    exists: Callable[[Path], bool],
    plan: WaitPlan,
) -> tuple[Path, ...]:
    """Poll until every path is gone; return those still present at the timeout."""
    started = plan.clock()
    while True:
        remaining = tuple(path for path in paths if exists(path))
        elapsed = plan.clock() - started
        if not remaining or elapsed >= plan.timeout_seconds:
            return remaining
        plan.sleep(min(plan.poll_seconds, plan.timeout_seconds - elapsed))


def run_visible(command: list[str]) -> int:
    """Run the app's uninstall on the tester's terminal, so sudo can ask for the password."""
    # The command is the installed executable and fixed arguments, never caller input.
    return subprocess.run(command, check=False).returncode  # noqa: S603


def run(arguments: list[str]) -> int:
    """Run the uninstall check and return a process status."""
    parser = _parser()
    args = parser.parse_args(arguments)
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    plan = WaitPlan(timeout_seconds=args.timeout, poll_seconds=POLL_SECONDS)
    try:
        previous = _previous_input(read_default_input(), args.previous)
        paths = read_installed_paths(args.executable)
        status = run_visible([str(args.executable), "uninstall", "--yes"])
        if status != 0:
            sys.stderr.write(f"uninstall: the app's uninstall exited with status {status}\n")
            return 2
        remaining = wait_for_removal(paths, present, plan)
        restored = wait_for_previous(read_default_input, previous, plan)
    except (OSError, RuntimeError, TypeError, ValueError) as error:
        sys.stderr.write(f"uninstall: {error}\n")
        return 2

    report = UninstallReport(
        previous=previous,
        restored=None if restored is None else restored[0],
        remaining=remaining,
    )
    append_result(
        repo_root(Path(__file__)) / RESULTS,
        "uninstall",
        passed=report.passed,
        detail=f"previous {report.previous}; restored {report.restored}; "
        f"left {', '.join(map(str, report.remaining)) or 'nothing'}",
    )
    _write_report(report)
    return 0 if report.passed else 1


def _previous_input(current: str | None, named: str | None) -> str:
    if named is not None:
        return named
    if current is None:
        message = "the audio report names no default input"
        raise ValueError(message)
    if is_virtual_mic(current):
        message = (
            f"{current} is the default input; pass --previous with the device "
            "the default should return to"
        )
        raise ValueError(message)
    return current


def _write_report(report: UninstallReport) -> None:
    sys.stdout.write(f"Default input before: {report.previous}\n")
    sys.stdout.write(f"Default input after: {report.restored}\n")
    for path in report.remaining:
        sys.stderr.write(f"uninstall: still present: {path}\n")
    if report.restored != report.previous:
        sys.stderr.write("uninstall: the previous default input did not return\n")
    if report.passed:
        sys.stdout.write("PASS\n")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Check that uninstall removes every path and restores the default input.",
    )
    parser.add_argument(
        "--executable",
        type=Path,
        default=EXECUTABLE,
        help="the installed app's executable",
    )
    parser.add_argument(
        "--previous",
        help="the default input to expect afterwards, when the app's microphone is the default",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=RETURN_TIMEOUT_SECONDS,
        help="seconds to wait for the files to go and the input to return",
    )
    return parser


def main() -> None:
    """Run the uninstall check from the command line."""
    root = repo_root(Path(__file__))
    if "--print-root" in sys.argv[1:]:
        sys.stdout.write(f"{root}\n")
        return
    raise SystemExit(run(sys.argv[1:]))


if __name__ == "__main__":
    main()
