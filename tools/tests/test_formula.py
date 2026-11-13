import shutil
import subprocess
import sys
from pathlib import Path

import pytest

from untunnel_tools import formula

DIGEST = "3f" * 32


def test_formula_points_at_the_tagged_asset_and_its_digest() -> None:
    """Each release's formula pins that release's zip, not the moving latest link."""
    text = formula.render("v0.1.0-rc2", DIGEST)

    assert (
        'url "https://github.com/intesarjawad/untunnel/releases/download/'
        'v0.1.0-rc2/Untunnel-arm64.zip"'
    ) in text
    assert f'sha256 "{DIGEST}"' in text
    assert 'version "0.1.0-rc2"' in text


def test_formula_installs_the_bundle_and_links_the_command() -> None:
    """The app keeps its bundle, so permissions attach to it; the command is a link into it."""
    text = formula.render("v0.1.0", DIGEST)

    assert "depends_on arch: :arm64" in text
    assert "depends_on macos: :sequoia" in text
    assert '(prefix/"Untunnel.app").install buildpath.children' in text
    assert 'bin.install_symlink prefix/"Untunnel.app/Contents/MacOS/Untunnel" => "untunnel"' in text
    assert "untunnel setup" in text
    assert "Run `untunnel uninstall` before `brew uninstall untunnel`." in text
    assert 'system bin/"untunnel", "doctor", "--json", "--offline"' in text


def test_formula_is_valid_ruby() -> None:
    """The generated text parses, so a typo cannot reach the tap."""
    ruby = shutil.which("ruby")
    if ruby is None:
        pytest.fail("ruby is not on PATH; macOS and the CI runners ship it")
    result = subprocess.run(  # noqa: S603
        [ruby, "-c"],
        input=formula.render("v0.1.0", DIGEST),
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr


@pytest.mark.parametrize(
    ("tag", "digest", "message"),
    [
        ("0.1.0", DIGEST, "tag"),
        ("v0.1", DIGEST, "tag"),
        ("v0.1.0;rm", DIGEST, "tag"),
        ("v0.1.0", "3f" * 31, "SHA-256"),
        ("v0.1.0", "3F" * 32, "SHA-256"),
    ],
    ids=["no-v", "two-parts", "shell-text", "short-digest", "upper-case-digest"],
)
def test_render_rejects_values_that_are_not_a_release(tag: str, digest: str, message: str) -> None:
    """Both values come from the workflow, so they are checked before they reach Ruby."""
    with pytest.raises(ValueError, match=message):
        formula.render(tag, digest)


def test_main_reads_the_digest_from_the_checksum_file(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The release's .sha256 file is passed as is, name and all."""
    checksum = tmp_path / "Untunnel-arm64.zip.sha256"
    checksum.write_text(f"{DIGEST}  Untunnel-arm64.zip\n", encoding="utf-8")
    monkeypatch.setattr(sys, "argv", ["formula", "--tag", "v0.1.0", "--checksum", str(checksum)])

    formula.main()

    assert f'sha256 "{DIGEST}"' in capsys.readouterr().out
