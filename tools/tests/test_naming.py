import shutil
import subprocess
from pathlib import Path

import pytest

from untunnel_tools.paths import repo_root

# Built from parts so this file does not match its own search.
RETIRED_NAMES = ("hifi" + "mic",)


def git(checkout: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    """Run git in a checkout without raising, so callers can read its exit status."""
    executable = shutil.which("git")
    if executable is None:
        pytest.fail("git is not on PATH")
    return subprocess.run(  # noqa: S603
        [executable, "-C", str(checkout), *arguments],
        capture_output=True,
        text=True,
        check=False,
    )


def tracked_mentions(checkout: Path) -> list[str]:
    """Return tracked paths whose name or contents mention a retired name, in any case."""
    patterns = [argument for name in RETIRED_NAMES for argument in ("-e", name)]
    grep = git(checkout, "grep", "-z", "-l", "-i", *patterns)
    # git grep exits 1 when nothing matches; anything above that is a failure.
    if grep.returncode > 1:
        pytest.fail(f"git grep failed in {checkout}: {grep.stderr.strip()}")
    listing = git(checkout, "ls-files", "-z")
    if listing.returncode != 0:
        pytest.fail(f"git ls-files failed in {checkout}: {listing.stderr.strip()}")
    named = {
        path
        for path in listing.stdout.split("\0")
        if any(name in path.lower() for name in RETIRED_NAMES)
    }
    return sorted(set(filter(None, grep.stdout.split("\0"))) | named)


def make_checkout(root: Path, files: dict[str, str]) -> Path:
    """Create a git repository tracking the given files."""
    git(root, "init", "--quiet")
    for name, text in files.items():
        (root / name).write_text(text)
    added = git(root, "add", "--", *files)
    assert added.returncode == 0, added.stderr
    return root


def test_repository_uses_only_the_current_name() -> None:
    """No tracked file name or contents carry the retired product name or bundle id."""
    assert tracked_mentions(repo_root(Path(__file__))) == []


@pytest.mark.parametrize(
    ("files", "expected"),
    [
        ({"clean.txt": "Untunnel"}, []),
        ({"notes.txt": "Built by " + "HiFi" + "Mic"}, ["notes.txt"]),
        ({"Info.plist": "com.example." + "HIFI" + "MIC"}, ["Info.plist"]),
        ({"driver/" + "HiFi" + "Mic.c": "int main(void);"}, ["driver/" + "HiFi" + "Mic.c"]),
    ],
    ids=["clean", "mixed-case-contents", "upper-case-bundle-id", "file-name-only"],
)
def test_tracked_mentions_finds_names_in_contents_and_paths(
    tmp_path: Path,
    files: dict[str, str],
    expected: list[str],
) -> None:
    """Both contents and file names count, whatever their case."""
    (tmp_path / "driver").mkdir()
    assert tracked_mentions(make_checkout(tmp_path, files)) == expected


def test_untracked_files_are_ignored(tmp_path: Path) -> None:
    """Build output and scratch files outside git do not fail the check."""
    checkout = make_checkout(tmp_path, {"clean.txt": "Untunnel"})
    (checkout / "scratch.txt").write_text("hifi" + "mic")
    assert tracked_mentions(checkout) == []


def test_outside_a_repository_fails_loudly(tmp_path: Path) -> None:
    """A missing checkout is an error, never an empty result."""
    with pytest.raises(pytest.fail.Exception, match="git grep failed"):
        tracked_mentions(tmp_path)
