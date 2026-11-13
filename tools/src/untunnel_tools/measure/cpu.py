"""Reports the app's CPU over a run and, optionally, that it opened no sockets.

`ps -o %cpu=` reports the whole process, so the value covers every thread. The socket check
samples `lsof` once a second and treats any connection line as a failure.
"""

import argparse
import math
import subprocess
import sys
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from untunnel_tools.paths import repo_root

DEFAULT_SECONDS = 60
DEFAULT_INTERVAL_SECONDS = 1.0
DEFAULT_CPU_BUDGET_PERCENT_PER_PATH = 25.0
DEFAULT_PROCESS_NAME = "untunnel"
PS = "/bin/ps"
LSOF = "/usr/sbin/lsof"
PGREP = "/usr/bin/pgrep"

type CommandRunner = Callable[[list[str]], subprocess.CompletedProcess[str]]


def run_command(arguments: list[str]) -> subprocess.CompletedProcess[str]:
    """Run a diagnostic command and capture its text output."""
    # The process, lsof and pgrep paths are constants and every argument is an int or a
    # fixed flag, so no shell or caller-supplied command reaches this call.
    return subprocess.run(  # noqa: S603
        arguments, check=False, capture_output=True, text=True
    )


@dataclass(frozen=True)
class SamplePlan:
    """How long to sample and what the run must stay under."""

    seconds: int = DEFAULT_SECONDS
    interval: float = DEFAULT_INTERVAL_SECONDS
    paths: int = 1
    budget_percent_per_path: float = DEFAULT_CPU_BUDGET_PERCENT_PER_PATH
    no_network: bool = False


@dataclass(frozen=True)
class CpuReport:
    """One run's CPU samples and socket findings."""

    average_percent: float
    maximum_percent: float
    samples: int
    seconds: float
    paths: int
    budget_percent_per_path: float
    sockets: tuple[str, ...]

    @property
    def budget_percent(self) -> float:
        """The whole-process budget for the number of active paths."""
        return self.budget_percent_per_path * self.paths

    @property
    def within_budget(self) -> bool:
        """Whether the average CPU and the socket sample both passed."""
        return self.average_percent <= self.budget_percent and not self.sockets


def parse_cpu(output: str) -> float:
    """Read the process CPU percentage from `ps` output."""
    for line in output.splitlines():
        text = line.strip()
        if text:
            return float(text.split()[0])
    message = "ps reported no CPU value"
    raise ValueError(message)


def parse_sockets(output: str) -> tuple[str, ...]:
    """Return the connection lines `lsof` printed, excluding its header."""
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    return tuple(line for line in lines if not line.startswith("COMMAND"))


def resolve_pid(name: str, runner: CommandRunner) -> int:
    """Find a running process by its exact name."""
    result = runner([PGREP, "-x", name])
    for line in result.stdout.splitlines():
        text = line.strip()
        if text.isdigit():
            return int(text)
    message = f"no running process named {name}; pass --pid"
    raise LookupError(message)


def measure(
    pid: int,
    plan: SamplePlan | None = None,
    runner: CommandRunner | None = None,
    sleep: Callable[[float], None] | None = None,
) -> CpuReport:
    """Sample the process once per interval and check the budget and sockets."""
    plan = SamplePlan() if plan is None else plan
    run = run_command if runner is None else runner
    wait = time.sleep if sleep is None else sleep
    sample_count = max(1, math.ceil(plan.seconds / plan.interval))
    cpu_values: list[float] = []
    sockets: list[str] = []

    for index in range(sample_count):
        cpu_values.append(parse_cpu(run([PS, "-o", "%cpu=", "-p", str(pid)]).stdout))
        if plan.no_network:
            result = run([LSOF, "-i", "-n", "-P", "-p", str(pid)])
            sockets.extend(parse_sockets(result.stdout))
        if index + 1 < sample_count:
            wait(plan.interval)

    return CpuReport(
        average_percent=sum(cpu_values) / len(cpu_values),
        maximum_percent=max(cpu_values),
        samples=len(cpu_values),
        seconds=plan.seconds,
        paths=plan.paths,
        budget_percent_per_path=plan.budget_percent_per_path,
        sockets=tuple(sockets),
    )


def run(arguments: list[str]) -> int:
    """Run the CPU check and return a process status."""
    parser = _parser()
    args = parser.parse_args(arguments)
    if args.seconds <= 0 or args.interval <= 0:
        parser.error("--seconds and --interval must be positive")
    if args.paths <= 0 or args.budget_percent_per_path <= 0:
        parser.error("--paths and --budget-percent-per-path must be positive")

    try:
        pid = args.pid if args.pid is not None else resolve_pid(args.process_name, run_command)
        plan = SamplePlan(
            seconds=args.seconds,
            interval=args.interval,
            paths=args.paths,
            budget_percent_per_path=args.budget_percent_per_path,
            no_network=args.no_network,
        )
        report = measure(pid, plan)
    except (OSError, ValueError, LookupError) as error:
        sys.stderr.write(f"cpu: {error}\n")
        return 2

    sys.stdout.write(f"CPU samples: {report.samples} over {report.seconds:.1f} s\n")
    sys.stdout.write(
        f"Average CPU: {report.average_percent:.2f} % "
        f"(budget {report.budget_percent:.2f} % for {report.paths} path(s))\n"
    )
    sys.stdout.write(f"Maximum CPU: {report.maximum_percent:.2f} %\n")
    if args.no_network:
        if report.sockets:
            sys.stdout.write(f"Network: {len(report.sockets)} socket line(s)\n")
        else:
            sys.stdout.write("Network: no sockets\n")
    if not report.within_budget:
        if report.average_percent > report.budget_percent:
            sys.stderr.write("cpu: average CPU is over the budget\n")
        if report.sockets:
            sys.stderr.write("cpu: the process opened a socket\n")
        return 1
    return 0


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Measure the app's CPU and check that it opened no sockets.",
    )
    parser.add_argument("--seconds", type=int, default=DEFAULT_SECONDS)
    parser.add_argument("--interval", type=float, default=DEFAULT_INTERVAL_SECONDS)
    parser.add_argument("--pid", type=int, help="process to sample instead of looking it up")
    parser.add_argument("--process-name", default=DEFAULT_PROCESS_NAME)
    parser.add_argument(
        "--paths",
        type=int,
        default=1,
        help="number of active capture and restoration paths",
    )
    parser.add_argument(
        "--budget-percent-per-path",
        type=float,
        default=DEFAULT_CPU_BUDGET_PERCENT_PER_PATH,
        help="average CPU one path may use",
    )
    parser.add_argument(
        "--no-network",
        action="store_true",
        help="sample lsof each second and fail when a socket appears",
    )
    return parser


def main() -> None:
    """Run the CPU check from the command line."""
    root = repo_root(Path(__file__))
    if "--print-root" in sys.argv[1:]:
        sys.stdout.write(f"{root}\n")
        return
    raise SystemExit(run(sys.argv[1:]))


if __name__ == "__main__":
    main()
