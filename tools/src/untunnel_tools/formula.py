"""Writes the Homebrew formula for one release, for the tap repository.

The release workflow runs this with the pushed tag and the release's `.sha256` file and
commits the output to the tap as `Formula/untunnel.rb`.
"""

import argparse
import re
import sys
from pathlib import Path

from untunnel_tools.paths import repo_root

REPOSITORY = "intesarjawad/untunnel"
ASSET = "Untunnel-arm64.zip"
TAG = re.compile(r"v(\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?)")
DIGEST = re.compile(r"[0-9a-f]{64}")

TEMPLATE = """\
class Untunnel < Formula
  desc "Restores the voice band a Bluetooth headset microphone loses on calls"
  homepage "https://github.com/{repository}"
  url "https://github.com/{repository}/releases/download/{tag}/{asset}"
  version "{version}"
  sha256 "{digest}"
  license "MIT"

  depends_on arch: :arm64
  depends_on macos: :sequoia

  def install
    # Homebrew unpacks into the zip's only directory, the app bundle itself.
    (prefix/"Untunnel.app").install buildpath.children
    bin.install_symlink prefix/"Untunnel.app/Contents/MacOS/Untunnel" => "untunnel"
  end

  def caveats
    <<~EOS
      Finish the install, which adds the audio plug-in and the login item:
        untunnel setup
      Run `untunnel uninstall` before `brew uninstall untunnel`.
    EOS
  end

  test do
    system bin/"untunnel", "doctor", "--json", "--offline"
  end
end
"""


def render(tag: str, digest: str) -> str:
    """Return the formula for the release with this tag and archive digest."""
    match = TAG.fullmatch(tag)
    if match is None:
        message = f"{tag!r} is not a release tag such as v0.1.0 or v0.1.0-rc1"
        raise ValueError(message)
    if DIGEST.fullmatch(digest) is None:
        message = f"{digest!r} is not a lower-case SHA-256 digest"
        raise ValueError(message)
    return TEMPLATE.format(
        repository=REPOSITORY,
        tag=tag,
        asset=ASSET,
        version=match.group(1),
        digest=digest,
    )


def main() -> None:
    """Print the formula for a tag and the release's checksum file."""
    root = repo_root(Path(__file__))
    if "--print-root" in sys.argv[1:]:
        sys.stdout.write(f"{root}\n")
        return
    parser = argparse.ArgumentParser(description="Print the Homebrew formula for a release.")
    parser.add_argument("--tag", required=True, help="the release tag, such as v0.1.0")
    parser.add_argument(
        "--checksum",
        type=Path,
        required=True,
        help=f"the release's {ASSET}.sha256 file",
    )
    args = parser.parse_args(sys.argv[1:])
    fields = args.checksum.read_text(encoding="utf-8").split()
    try:
        sys.stdout.write(render(args.tag, fields[0] if fields else ""))
    except ValueError as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
