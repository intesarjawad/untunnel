import hashlib
import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

import pytest

from untunnel_tools.paths import repo_root

INSTALL_SH = repo_root(Path(__file__)) / "site" / "install.sh"
ASSET = "Untunnel-arm64.zip"
SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"

# Records what setup received. Reading stdin to the end is the point: under `curl ... | sh`
# anything left in the pipe is the rest of the install script.
SETUP_STUB = """#!/bin/sh
printf '%s\\n' "$*" > "$HOME/setup-arguments"
cat > "$HOME/setup-stdin"
"""


@dataclass(frozen=True)
class Install:
    """One run of the install script and the home directory it ran against."""

    home: Path
    result: subprocess.CompletedProcess[str]

    @property
    def app(self) -> Path:
        """The bundle the script installs."""
        return self.home / "Applications" / "Untunnel.app"


def make_artifact(directory: Path, version: str) -> Path:
    """Build a release zip whose app is the setup stub, with its checksum beside it."""
    ditto = shutil.which("ditto")
    if ditto is None:
        pytest.fail("ditto is not on PATH; the install script needs macOS")
    source = directory / f"source-{version}"
    executable = source / "Untunnel.app" / "Contents" / "MacOS" / "Untunnel"
    executable.parent.mkdir(parents=True)
    executable.write_text(SETUP_STUB, encoding="utf-8")
    executable.chmod(0o755)
    (source / "Untunnel.app" / "Contents" / "version").write_text(version, encoding="utf-8")
    archive = directory / f"release-{version}" / ASSET
    archive.parent.mkdir()
    subprocess.run(  # noqa: S603
        [ditto, "-c", "-k", "--keepParent", str(source / "Untunnel.app"), str(archive)],
        check=True,
    )
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (archive.parent / f"{ASSET}.sha256").write_text(f"{digest}  {ASSET}\n", encoding="utf-8")
    return archive


def run_install(
    home: Path,
    artifact: Path,
    *,
    piped: bool = True,
    fake_bin: Path | None = None,
) -> Install:
    """Run the script as the README line does, through a pipe, with no terminal attached."""
    command = 'cat "$INSTALL_SH" | /bin/sh -s -- --yes' if piped else '/bin/sh "$INSTALL_SH" --yes'
    path = SYSTEM_PATH if fake_bin is None else f"{fake_bin}:{SYSTEM_PATH}"
    # The command is one of the two fixed lines above; the paths travel in the environment.
    result = subprocess.run(  # noqa: S603
        ["/bin/sh", "-c", command],
        env={
            "HOME": str(home),
            "PATH": path,
            "TMPDIR": str(home.parent / "tmp"),
            "INSTALL_SH": str(INSTALL_SH),
            "UNTUNNEL_ARTIFACT": str(artifact),
        },
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        check=False,
        # A new session has no controlling terminal, so /dev/tty cannot be opened, as in CI.
        start_new_session=True,
        timeout=60,
    )
    return Install(home=home, result=result)


def snapshot(home: Path) -> list[tuple[str, str]]:
    """Every entry under a home directory, with link targets and file contents."""
    entries: list[tuple[str, str]] = []
    for directory, names, files in os.walk(home):
        for name in sorted(names + files):
            path = Path(directory) / name
            relative = str(path.relative_to(home))
            if path.is_symlink():
                entries.append((relative, f"link {path.readlink()}"))
            elif path.is_file():
                entries.append((relative, path.read_text(encoding="utf-8")))
            else:
                entries.append((relative, "directory"))
    return sorted(entries)


@pytest.fixture
def home(tmp_path: Path) -> Path:
    """Return an empty home directory with its own temporary directory beside it."""
    (tmp_path / "tmp").mkdir()
    directory = tmp_path / "home"
    directory.mkdir()
    return directory


def fake_tools(directory: Path, answers: dict[str, str]) -> Path:
    """Put commands that print fixed answers first on PATH."""
    directory.mkdir()
    for name, output in answers.items():
        tool = directory / name
        tool.write_text(f"#!/bin/sh\nprintf '%s\\n' '{output}'\n", encoding="utf-8")
        tool.chmod(0o755)
    return directory


def test_piped_install_never_hands_the_script_to_setup(home: Path, tmp_path: Path) -> None:
    """Setup gets the arguments after `--` and an empty stdin, never the script's text."""
    install = run_install(home, make_artifact(tmp_path, "1"))

    assert install.result.returncode == 0, install.result.stderr
    assert (install.home / "setup-arguments").read_text(encoding="utf-8") == "setup --yes\n"
    assert (install.home / "setup-stdin").read_text(encoding="utf-8") == ""
    assert (install.app / "Contents" / "version").read_text(encoding="utf-8") == "1"


def test_running_from_a_file_installs_too(home: Path, tmp_path: Path) -> None:
    """The script works when saved and run with sh, for readers who check it first."""
    install = run_install(home, make_artifact(tmp_path, "1"), piped=False)

    assert install.result.returncode == 0, install.result.stderr
    assert install.app.is_dir()
    assert not install.app.is_symlink()


def test_second_run_upgrades_and_keeps_the_model_and_preferences(
    home: Path,
    tmp_path: Path,
) -> None:
    """Running the line again replaces only the bundle and leaves one app."""
    assert run_install(home, make_artifact(tmp_path, "1")).result.returncode == 0
    support = home / "Library" / "Application Support" / "Untunnel"
    (support / "models" / "v1").mkdir(parents=True)
    (support / "models" / "v1" / "model.safetensors").write_text("weights", encoding="utf-8")
    (support / "preferences.json").write_text('{"tier": "auto"}', encoding="utf-8")

    install = run_install(home, make_artifact(tmp_path, "2"))

    assert install.result.returncode == 0, install.result.stderr
    assert (install.app / "Contents" / "version").read_text(encoding="utf-8") == "2"
    assert sorted(path.name for path in (home / "Applications").iterdir()) == ["Untunnel.app"]
    assert (support / "models" / "v1" / "model.safetensors").read_text(
        encoding="utf-8"
    ) == "weights"
    assert (support / "preferences.json").read_text(encoding="utf-8") == '{"tier": "auto"}'


def test_a_homebrew_install_is_refused_and_nothing_changes(home: Path, tmp_path: Path) -> None:
    """A working link means Homebrew owns the app; the script names both ways forward."""
    cellar = home / "homebrew" / "Untunnel.app"
    cellar.mkdir(parents=True)
    (home / "Applications").mkdir()
    (home / "Applications" / "Untunnel.app").symlink_to(cellar)
    before = snapshot(home)

    install = run_install(home, make_artifact(tmp_path, "1"))

    assert install.result.returncode != 0
    fix = (
        "Fix: run `brew upgrade untunnel`; to switch, run `brew uninstall untunnel`, "
        "then this install line again."
    )
    assert install.result.stderr.splitlines() == ["Untunnel is installed with Homebrew.", fix]
    assert snapshot(home) == before


def test_a_dangling_link_is_removed_and_the_install_completes(
    home: Path,
    tmp_path: Path,
) -> None:
    """`brew uninstall` without `untunnel uninstall` leaves a link to nothing."""
    (home / "Applications").mkdir()
    (home / "Applications" / "Untunnel.app").symlink_to(home / "removed" / "Untunnel.app")

    install = run_install(home, make_artifact(tmp_path, "1"))

    assert install.result.returncode == 0, install.result.stderr
    assert not install.app.is_symlink()
    assert (install.app / "Contents" / "version").read_text(encoding="utf-8") == "1"


def test_a_checksum_mismatch_installs_nothing(home: Path, tmp_path: Path) -> None:
    """A corrupt download stops before anything in the home directory changes."""
    artifact = make_artifact(tmp_path, "1")
    (artifact.parent / f"{ASSET}.sha256").write_text(f"{'0' * 64}  {ASSET}\n", encoding="utf-8")

    install = run_install(home, artifact)

    assert install.result.returncode != 0
    assert "The download does not match its checksum." in install.result.stderr
    assert not (home / "Applications").exists()
    assert not (home / "setup-arguments").exists()


def test_a_missing_artifact_is_named(home: Path, tmp_path: Path) -> None:
    """A wrong UNTUNNEL_ARTIFACT path fails with the path, not a curl error."""
    install = run_install(home, tmp_path / "absent" / ASSET)

    assert install.result.returncode != 0
    assert f"{tmp_path / 'absent' / ASSET} does not exist." in install.result.stderr
    assert not (home / "Applications").exists()


def test_a_shell_under_rosetta_still_installs(home: Path, tmp_path: Path) -> None:
    """Under Rosetta uname says x86_64, but the chip is Apple silicon."""
    fake_bin = fake_tools(tmp_path / "bin", {"uname": "x86_64", "sysctl": "1"})

    install = run_install(home, make_artifact(tmp_path, "1"), fake_bin=fake_bin)

    assert install.result.returncode == 0, install.result.stderr
    assert install.app.is_dir()


@pytest.mark.parametrize(
    ("answers", "message"),
    [
        ({"uname": "x86_64", "sysctl": "0"}, "Untunnel needs an Apple silicon Mac."),
        ({"uname": "arm64", "sw_vers": "14.7.1"}, "Untunnel needs macOS 15 or later."),
    ],
    ids=["intel", "macos-14"],
)
def test_an_unsupported_mac_is_refused_before_downloading(
    home: Path,
    tmp_path: Path,
    answers: dict[str, str],
    message: str,
) -> None:
    """Intel Macs and macOS before 15 get the same message setup prints."""
    fake_bin = fake_tools(tmp_path / "bin", answers)

    install = run_install(home, make_artifact(tmp_path, "1"), fake_bin=fake_bin)

    assert install.result.returncode != 0
    assert install.result.stderr.splitlines()[0] == message
    assert install.result.stderr.splitlines()[1].startswith("Fix: ")
    assert not (home / "Applications").exists()
