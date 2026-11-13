import subprocess

import pytest

from untunnel_tools.measure import cpu


class FakeRunner:
    """Stand in for `ps` and `lsof` with fixed text output."""

    def __init__(self, cpu_lines: list[str] | None = None, sockets: str = "") -> None:
        self.cpu_lines = cpu_lines or ["10.0"]
        self.sockets = sockets
        self.calls: list[list[str]] = []

    def __call__(self, arguments: list[str]) -> subprocess.CompletedProcess[str]:
        """Answer ps with the next line and lsof with the configured sockets."""
        self.calls.append(arguments)
        if arguments[0] == cpu.PS:
            output = self.cpu_lines.pop(0) if len(self.cpu_lines) > 1 else self.cpu_lines[0]
            return subprocess.CompletedProcess(arguments, 0, stdout=output, stderr="")
        return subprocess.CompletedProcess(arguments, 0, stdout=self.sockets, stderr="")


def test_parse_cpu_reads_the_process_percentage() -> None:
    """The percentage ps prints is padded and may include a second column."""
    assert cpu.parse_cpu("  12.5\n") == 12.5
    assert cpu.parse_cpu("3.25 extra\n") == 3.25


def test_parse_cpu_rejects_empty_output() -> None:
    """A missing process is reported rather than treated as zero load."""
    with pytest.raises(ValueError, match="ps"):
        cpu.parse_cpu("\n")


def test_parse_sockets_ignores_the_lsof_header() -> None:
    """Header lines are not connections; every other line is."""
    output = (
        "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n"
        "untunnel 42 user 3u IPv4 0x1 0t0 TCP 127.0.0.1:5000\n"
    )
    assert cpu.parse_sockets(output) == ("untunnel 42 user 3u IPv4 0x1 0t0 TCP 127.0.0.1:5000",)
    assert cpu.parse_sockets("COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n") == ()


def test_measure_averages_every_sample_and_skips_lsof_by_default() -> None:
    """Three one-second samples average their whole-process CPU values."""
    runner = FakeRunner(cpu_lines=["10.0", "20.0", "30.0"])
    waits: list[float] = []

    plan = cpu.SamplePlan(seconds=3, interval=1)
    report = cpu.measure(42, plan, runner=runner, sleep=waits.append)

    assert report.samples == 3
    assert report.average_percent == pytest.approx(20)
    assert report.maximum_percent == pytest.approx(30)
    assert report.within_budget
    assert waits == [1, 1]
    assert all(call[0] == cpu.PS for call in runner.calls)


def test_measure_accepts_a_budget_for_two_paths() -> None:
    """The budget grows with the number of active paths."""
    runner = FakeRunner(cpu_lines=["40.0"])

    one_path = cpu.measure(
        42, cpu.SamplePlan(seconds=1, paths=1), runner=runner, sleep=lambda _: None
    )
    two_paths = cpu.measure(
        42, cpu.SamplePlan(seconds=1, paths=2), runner=runner, sleep=lambda _: None
    )

    assert not one_path.within_budget
    assert two_paths.within_budget


def test_measure_fails_when_a_socket_appears() -> None:
    """Any connection line sampled by lsof fails the run even with low CPU."""
    runner = FakeRunner(
        cpu_lines=["1.0"],
        sockets="untunnel 42 user 3u IPv4 0x1 0t0 TCP 127.0.0.1:5000\n",
    )

    report = cpu.measure(42, cpu.SamplePlan(seconds=1, no_network=True), runner=runner)

    assert not report.within_budget
    assert len(report.sockets) == 1
    assert runner.calls[-1][0] == cpu.LSOF


def test_resolve_pid_reads_pgrep() -> None:
    """The process lookup takes the first numeric pid."""

    def runner(arguments: list[str]) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(arguments, 0, stdout="42\n43\n", stderr="")

    assert cpu.resolve_pid("untunnel", runner) == 42


def test_run_prints_the_average(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """A single fast sample reports the values and passes."""
    runner = FakeRunner(cpu_lines=["9.5"])
    monkeypatch.setattr(cpu, "run_command", runner)

    status = cpu.run(["--pid", "42", "--seconds", "1", "--interval", "1", "--no-network"])

    assert status == 0
    captured = capsys.readouterr()
    assert "Average CPU: 9.50 %" in captured.out
    assert "Network: no sockets" in captured.out
