import subprocess
from datetime import datetime
from pathlib import Path

import pytest

from untunnel_tools.measure import uninstall
from untunnel_tools.measure.autoroute import WaitPlan

DRY_RUN = """Untunnel uninstall (dry run)

Would remove:
  /Users/example/Applications/Untunnel.app
  /Users/example/Library/LaunchAgents/com.intesarjawad.untunnel.plist
  /Users/example/Library/Application Support/Untunnel
  /Library/Audio/Plug-Ins/HAL/Untunnel.driver

Would run:
  launchctl bootout gui/501/com.intesarjawad.untunnel
  sudo rm -rf /Library/Audio/Plug-Ins/HAL/Untunnel.driver
  sudo killall coreaudiod

Nothing was changed.
"""


class FakeClock:
    """Advance only when the code under test sleeps."""

    def __init__(self) -> None:
        self.now = 0.0

    def read(self) -> float:
        """Return the current fake time."""
        return self.now

    def sleep(self, seconds: float) -> None:
        """Advance the fake time by the requested pause."""
        self.now += seconds


def plan(clock: FakeClock, timeout_seconds: float = 5.0) -> WaitPlan:
    """Return a wait plan on the fake clock."""
    return WaitPlan(
        timeout_seconds=timeout_seconds,
        poll_seconds=1.0,
        clock=clock.read,
        sleep=clock.sleep,
    )


def test_parse_dry_run_lists_every_path_the_app_removes() -> None:
    """The paths come from the app's own list, including one with a space."""
    assert uninstall.parse_dry_run(DRY_RUN) == (
        Path("/Users/example/Applications/Untunnel.app"),
        Path("/Users/example/Library/LaunchAgents/com.intesarjawad.untunnel.plist"),
        Path("/Users/example/Library/Application Support/Untunnel"),
        Path("/Library/Audio/Plug-Ins/HAL/Untunnel.driver"),
    )


@pytest.mark.parametrize(
    "output",
    ["Untunnel uninstall (dry run)\n\nNothing was changed.\n", "Would remove:\n\nWould run:\n"],
    ids=["no-section", "empty-section"],
)
def test_parse_dry_run_rejects_output_without_paths(output: str) -> None:
    """An empty list would pass the check vacuously, so it is an error."""
    with pytest.raises(ValueError, match="no paths"):
        uninstall.parse_dry_run(output)


def test_read_installed_paths_reports_a_failing_dry_run() -> None:
    """A dry run that fails is a tool error, not an empty list."""

    def runner(arguments: list[str]) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(arguments, 2, stdout="", stderr="usage")

    with pytest.raises(RuntimeError, match="status 2"):
        uninstall.read_installed_paths(Path("/Applications/Untunnel"), runner)


def test_read_installed_paths_asks_the_executable_for_a_dry_run() -> None:
    """The check never builds its own list of paths."""
    calls: list[list[str]] = []

    def runner(arguments: list[str]) -> subprocess.CompletedProcess[str]:
        calls.append(arguments)
        return subprocess.CompletedProcess(arguments, 0, stdout=DRY_RUN, stderr="")

    paths = uninstall.read_installed_paths(Path("/x/Untunnel"), runner)

    assert calls == [["/x/Untunnel", "uninstall", "--dry-run"]]
    assert len(paths) == 4


def test_wait_for_removal_returns_nothing_once_every_path_is_gone() -> None:
    """Paths may disappear one at a time; the wait ends when the last one goes."""
    clock = FakeClock()
    present = {Path("/a"), Path("/b")}

    def exists(path: Path) -> bool:
        if clock.now >= 1.0:
            present.discard(Path("/a"))
        if clock.now >= 2.0:
            present.discard(Path("/b"))
        return path in present

    assert uninstall.wait_for_removal((Path("/a"), Path("/b")), exists, plan(clock)) == ()
    assert clock.now == 2.0


def test_wait_for_removal_names_what_is_left_at_the_timeout() -> None:
    """A path that stays is reported by name."""
    clock = FakeClock()

    remaining = uninstall.wait_for_removal(
        (Path("/a"), Path("/b")),
        lambda path: path == Path("/b"),
        plan(clock, timeout_seconds=2.0),
    )

    assert remaining == (Path("/b"),)
    assert clock.now == 2.0


def test_a_dangling_link_counts_as_left_behind(tmp_path: Path) -> None:
    """A link to a removed bundle is still a file uninstall should have taken."""
    link = tmp_path / "Untunnel.app"
    link.symlink_to(tmp_path / "gone")

    assert uninstall.present(link)
    assert not uninstall.present(tmp_path / "never")


@pytest.mark.parametrize(
    ("remaining", "restored", "passed"),
    [
        ((), "MacBook Pro Microphone", True),
        ((Path("/a"),), "MacBook Pro Microphone", False),
        ((), "Untunnel Microphone", False),
        ((), None, False),
    ],
    ids=["clean", "path-left", "virtual-still-default", "no-default"],
)
def test_report_needs_every_path_gone_and_the_input_back(
    remaining: tuple[Path, ...],
    restored: str | None,
    passed: bool,  # noqa: FBT001
) -> None:
    """Both halves of the check must hold."""
    report = uninstall.UninstallReport(
        previous="MacBook Pro Microphone",
        restored=restored,
        remaining=remaining,
    )

    assert report.passed is passed


def _patch_machine(
    monkeypatch: pytest.MonkeyPatch,
    defaults: list[str],
    *,
    left: frozenset[Path] = frozenset(),
) -> list[list[str]]:
    """Stand in for the installed app, the default input and the filesystem."""
    ran: list[list[str]] = []
    readings = iter(defaults)

    def run_visible(command: list[str]) -> int:
        ran.append(command)
        return 0

    def record(
        _path: Path,
        _check: str,
        *,
        passed: bool,
        detail: str,
        stamp: datetime | None = None,
    ) -> None:
        _ = passed, detail, stamp

    def installed_paths(_executable: Path) -> tuple[Path, ...]:
        return uninstall.parse_dry_run(DRY_RUN)

    def present(path: Path) -> bool:
        return path in left

    monkeypatch.setattr(uninstall, "read_installed_paths", installed_paths)
    monkeypatch.setattr(uninstall, "read_default_input", lambda: next(readings))
    monkeypatch.setattr(uninstall, "run_visible", run_visible)
    monkeypatch.setattr(uninstall, "present", present)
    monkeypatch.setattr(uninstall, "append_result", record)
    return ran


def test_run_uninstalls_with_the_app_and_prints_pass(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The app's own uninstall runs once, then both checks pass."""
    ran = _patch_machine(monkeypatch, ["MacBook Pro Microphone", "MacBook Pro Microphone"])

    status = uninstall.run(["--executable", "/x/Untunnel", "--timeout", "0.01"])

    assert status == 0
    assert ran == [["/x/Untunnel", "uninstall", "--yes"]]
    assert capsys.readouterr().out.rstrip().endswith("PASS")


def test_run_needs_the_previous_input_while_the_app_is_the_default(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """With the app's microphone as the default, the device to return to must be named."""
    ran = _patch_machine(monkeypatch, ["Untunnel Microphone"])

    status = uninstall.run(["--executable", "/x/Untunnel"])

    assert status == 2
    assert "--previous" in capsys.readouterr().err
    assert ran == []


def test_run_accepts_the_named_previous_input(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Uninstall while engaged passes when the named device becomes the default again."""
    _patch_machine(monkeypatch, ["Untunnel Microphone", "AirPods Pro"])

    status = uninstall.run(
        ["--executable", "/x/Untunnel", "--previous", "AirPods Pro", "--timeout", "0.01"]
    )

    assert status == 0


def test_run_fails_and_names_a_path_left_behind(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A surviving login item fails the check by name."""
    agent = Path("/Users/example/Library/LaunchAgents/com.intesarjawad.untunnel.plist")
    _patch_machine(
        monkeypatch,
        ["MacBook Pro Microphone", "MacBook Pro Microphone"],
        left=frozenset({agent}),
    )

    status = uninstall.run(["--executable", "/x/Untunnel", "--timeout", "0.01"])

    assert status == 1
    assert str(agent) in capsys.readouterr().err
