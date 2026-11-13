"""Checks the microphone path after the app dies, hangs or loses its permission.

Each case watches the system default input after one tester action: a forced quit, a stopped
process, or Deny on the microphone prompt. The tool signals only the process id it is given or
finds by exact name, and it never matches command lines.
"""

import argparse
import os
import signal
import sys
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from untunnel_tools.measure.autoroute import (
    WaitPlan,
    append_result,
    is_virtual_mic,
    read_default_input,
)
from untunnel_tools.measure.cpu import CommandRunner, resolve_pid, run_command
from untunnel_tools.paths import repo_root

TCCUTIL = "/usr/bin/tccutil"
OPEN = "/usr/bin/open"
BUNDLE_ID = "com.intesarjawad.untunnel"
DEFAULT_PROCESS_NAME = "Untunnel"
DEFAULT_APP = Path("~/Applications/Untunnel.app")
PROMPT_LIMIT_SECONDS = 5.0
PROCESS_TIMEOUT_SECONDS = 15.0
HANG_SECONDS = 5.0
HANG_SETUP = {
    "standby": "Leave Untunnel on Standby with no application reading the microphone.",
    "waiting": "Put the headset in its case so Untunnel is waiting for it.",
}
POLL_SECONDS = 0.5
RESULTS = Path("docs") / "results.md"
CASES = ("kill9", "hang-standby", "hang-waiting", "no-permission")


@dataclass(frozen=True)
class Observation:
    """What the case watched after the tester acted."""

    relaunched: bool
    default_input: str | None
    prompt_seconds: float | None = None
    permission_line: bool = False


@dataclass(frozen=True)
class CaseReport:
    """One case's observation and whether it met its acceptance rule."""

    case: str
    observation: Observation

    @property
    def passed(self) -> bool:
        """Whether the default stayed usable and, for permission, the prompt was in time."""
        name = self.observation.default_input
        usable = name is not None and not is_virtual_mic(name)
        if self.case == "no-permission":
            return (
                usable
                and self.observation.permission_line
                and self.observation.prompt_seconds is not None
                and self.observation.prompt_seconds <= PROMPT_LIMIT_SECONDS
            )
        return self.observation.relaunched and usable


def verify(case: str, observation: Observation) -> CaseReport:
    """Turn one observation into the acceptance report."""
    if case not in CASES:
        message = f"unknown failsafe case {case!r}"
        raise ValueError(message)
    return CaseReport(case=case, observation=observation)


def process_running(name: str, runner: CommandRunner = run_command) -> bool:
    """Whether a process with this exact name exists."""
    try:
        resolve_pid(name, runner)
    except LookupError:
        return False
    return True


def force_kill(pid: int) -> None:
    """Send `SIGKILL` to one process id the case names."""
    os.kill(pid, signal.SIGKILL)


def pause_process(pid: int) -> None:
    """Stop one process id so the pipeline stops publishing hops."""
    os.kill(pid, signal.SIGSTOP)


def resume_process(pid: int) -> None:
    """Let a stopped process run again."""
    os.kill(pid, signal.SIGCONT)


def reset_permission(runner: CommandRunner = run_command) -> None:
    """Clear the app's microphone grant so the next launch asks again."""
    result = runner([TCCUTIL, "reset", "Microphone", BUNDLE_ID])
    if result.returncode != 0:
        message = f"tccutil exited with status {result.returncode}"
        raise RuntimeError(message)


def launch_app(app: Path, runner: CommandRunner = run_command) -> None:
    """Start a fresh copy of the installed app."""
    result = runner([OPEN, "-n", str(app)])
    if result.returncode != 0:
        message = f"open exited with status {result.returncode}"
        raise RuntimeError(message)


def confirm(message: str) -> None:
    """Wait for the tester to confirm that a visible step happened."""
    input(message)


def ask_yes_no(question: str) -> bool:
    """Ask the tester one yes or no question about the screen."""
    answer = input(f"{question} [y/N] ").strip().lower()
    return answer in {"y", "yes"}


def wait_for_process(
    name: str,
    plan: WaitPlan | None = None,
    runner: CommandRunner = run_command,
) -> bool:
    """Poll until a process with this name exists or the tester's time runs out."""
    plan = WaitPlan(timeout_seconds=PROCESS_TIMEOUT_SECONDS) if plan is None else plan
    started = plan.clock()
    while True:
        if process_running(name, runner):
            return True
        elapsed = plan.clock() - started
        if elapsed >= plan.timeout_seconds:
            return False
        plan.sleep(min(plan.poll_seconds, plan.timeout_seconds - elapsed))


def run(arguments: list[str]) -> int:
    """Run one failsafe case and return a process status."""
    parser = _parser()
    args = parser.parse_args(arguments)
    plan = WaitPlan(
        timeout_seconds=args.timeout,
        poll_seconds=POLL_SECONDS,
    )
    case = "no-permission" if args.no_permission else "kill9"
    if args.hang is not None:
        case = f"hang-{args.hang}"
    try:
        if case == "kill9":
            report = kill_case(args.pid, args.process_name, plan)
        elif case.startswith("hang-"):
            report = hang_case(args.pid, args.process_name, case)
        else:
            report = permission_case(args.app)
    except (OSError, RuntimeError, ValueError) as error:
        sys.stderr.write(f"failsafe: {error}\n")
        return 2

    append_result(
        repo_root(Path(__file__)) / RESULTS,
        f"failsafe-{report.case}",
        passed=report.passed,
        detail=f"default {report.observation.default_input}; "
        f"prompt {report.observation.prompt_seconds}",
    )
    _write_report(report)
    return 0 if report.passed else 1


def kill_case(pid: int | None, process_name: str, plan: WaitPlan) -> CaseReport:
    """Force-quit the app and watch for its restart."""
    target = pid if pid is not None else resolve_pid(process_name, run_command)
    sys.stdout.write(f"Force-quitting process {target}.\n")
    force_kill(target)
    relaunched = wait_for_process(process_name, plan)
    return verify(
        "kill9",
        Observation(relaunched=relaunched, default_input=read_default_input()),
    )


def hang_case(pid: int | None, process_name: str, case: str) -> CaseReport:
    """Stop the app in the microphone state the case names, then let it run again."""
    confirm(f"{HANG_SETUP[case.removeprefix('hang-')]} Press Return when it is set: ")
    target = pid if pid is not None else resolve_pid(process_name, run_command)
    sys.stdout.write(f"Stopping process {target} for {HANG_SECONDS:.0f} s.\n")
    pause_process(target)
    try:
        time.sleep(HANG_SECONDS)
        running = process_running(process_name)
        default = read_default_input()
    finally:
        resume_process(target)
    return verify(case, Observation(relaunched=running, default_input=default))


def permission_case(app: Path, clock: Callable[[], float] = time.monotonic) -> CaseReport:
    """Reset the grant, relaunch and time how long the prompt takes to show."""
    reset_permission()
    launch_app(app)
    started = clock()
    confirm("Press Return the moment the microphone prompt appears: ")
    seconds = clock() - started
    confirm("Click Don't Allow, then press Return: ")
    default = read_default_input()
    line = ask_yes_no("Does the menu show the microphone permission line?")
    return verify(
        "no-permission",
        Observation(
            relaunched=process_running(DEFAULT_PROCESS_NAME),
            default_input=default,
            prompt_seconds=seconds,
            permission_line=line,
        ),
    )


def _write_report(report: CaseReport) -> None:
    if report.passed:
        sys.stdout.write(f"PASS: {report.case} left a real microphone as the default\n")
        return
    if report.observation.default_input is None:
        sys.stderr.write("failsafe: no default input could be read\n")
    elif is_virtual_mic(report.observation.default_input):
        sys.stderr.write("failsafe: the app's microphone stayed the default input\n")
    if report.case == "no-permission":
        prompt = report.observation.prompt_seconds
        if prompt is None or prompt > PROMPT_LIMIT_SECONDS:
            sys.stderr.write("failsafe: the permission prompt did not appear within 5 s\n")
        if not report.observation.permission_line:
            sys.stderr.write("failsafe: the menu did not show the permission line\n")
    elif not report.observation.relaunched:
        sys.stderr.write("failsafe: the app did not come back\n")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Check the microphone path after the app dies, hangs or loses permission.",
    )
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--kill", action="store_true", help="force quit the app (the default)")
    group.add_argument(
        "--hang",
        choices=("standby", "waiting"),
        help="stop the app in this microphone state",
    )
    group.add_argument(
        "--no-permission",
        action="store_true",
        help="reset the grant, relaunch and observe Deny",
    )
    parser.add_argument("--pid", type=int, help="process id to signal instead of looking it up")
    parser.add_argument("--process-name", default=DEFAULT_PROCESS_NAME)
    parser.add_argument("--app", type=Path, default=DEFAULT_APP)
    parser.add_argument(
        "--timeout",
        type=float,
        default=PROCESS_TIMEOUT_SECONDS,
        help="seconds to wait for the app to come back",
    )
    return parser


def main() -> None:
    """Run one failsafe case from the command line."""
    root = repo_root(Path(__file__))
    if "--print-root" in sys.argv[1:]:
        sys.stdout.write(f"{root}\n")
        return
    raise SystemExit(run(sys.argv[1:]))


if __name__ == "__main__":
    main()
