import importlib
import os
import subprocess
import sys
from pathlib import Path

import pytest

from untunnel_tools.paths import repo_root


def test_nearest_package_manifest_wins(tmp_path: Path) -> None:
    """Nested checkouts resolve to their own manifest."""
    (tmp_path / "Package.swift").touch()
    nested = tmp_path / "nested"
    nested.mkdir()
    (nested / "Package.swift").touch()
    source = nested / "tools" / "probe.py"
    source.parent.mkdir()
    source.touch()
    assert repo_root(source) == nested


def test_missing_manifest_fails_at_filesystem_root(tmp_path: Path) -> None:
    """A detached tool reports the missing checkout marker."""
    with pytest.raises(FileNotFoundError, match=r"Package\.swift"):
        repo_root(tmp_path / "probe.py")


def test_symlink_uses_source_checkout(tmp_path: Path) -> None:
    """A linked tool resolves its physical checkout."""
    checkout = tmp_path / "checkout"
    checkout.mkdir()
    (checkout / "Package.swift").touch()
    source = checkout / "probe.py"
    source.touch()
    linked = tmp_path / "linked.py"
    linked.symlink_to(source)
    assert repo_root(linked) == checkout


def test_every_module_and_script_resolves_from_other_directories(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Tool entry points work without the checkout as the working directory."""
    root = repo_root(Path(__file__))
    package = root / "tools" / "src" / "untunnel_tools"
    modules = sorted(path for path in package.rglob("*.py") if path.name != "__init__.py")
    scripts = sorted(package.rglob("*.sh"))
    assert modules
    for working_directory in (Path("/", "tmp"), root / "tools"):
        monkeypatch.chdir(working_directory)
        for path in modules:
            name = ".".join(path.relative_to(package.parent).with_suffix("").parts)
            module = importlib.import_module(name)
            assert module.repo_root(path) == root
            monkeypatch.setattr(sys, "argv", [name, "--print-root"])
            module.main()
            assert capsys.readouterr().out.strip() == str(root)
        for script in scripts:
            result = subprocess.run(
                ["/bin/sh", "-c", 'exec "$UNTUNNEL_PATH_SCRIPT" --print-root'],
                env={**os.environ, "UNTUNNEL_PATH_SCRIPT": str(script)},
                cwd=working_directory,
                capture_output=True,
                text=True,
                check=True,
            )
            assert result.stdout.strip() == str(root)
