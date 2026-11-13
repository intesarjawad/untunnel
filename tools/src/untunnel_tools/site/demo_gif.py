"""Record the project page playing its restored line into the README GIF."""

import importlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from untunnel_tools.paths import repo_root
from untunnel_tools.site.stills import serve

BRAVE = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"


def main() -> None:
    """Capture the live page and convert its recording with a GIF palette."""
    root = repo_root(Path(__file__))
    if "--print-root" in sys.argv[1:]:
        sys.stdout.write(f"{root}\n")
        return
    sync_playwright = importlib.import_module("playwright.sync_api").sync_playwright
    with tempfile.TemporaryDirectory() as temporary, serve(root / "site") as base:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(
                executable_path=BRAVE,
                args=["--autoplay-policy=no-user-gesture-required"],
            )
            context = browser.new_context(
                viewport={"width": 1280, "height": 900},
                record_video_dir=temporary,
                record_video_size={"width": 1280, "height": 900},
            )
            page = context.new_page()
            page.goto(f"{base}/index.html", wait_until="load")
            page.locator("html[data-ready=true]").wait_for(timeout=60000)
            page.locator('#score[data-state="live"]').wait_for(timeout=60000)
            page.get_by_role("button", name="Play the line").click()
            page.wait_for_timeout(5500)
            video = page.video
            context.close()
            browser.close()
            if video is None:
                message = "Playwright did not record a video"
                raise RuntimeError(message)
            recording = video.path()
        ffmpeg = shutil.which("ffmpeg")
        if ffmpeg is None:
            message = "Install ffmpeg to render the demo GIF"
            raise FileNotFoundError(message)
        subprocess.run(  # noqa: S603
            [
                ffmpeg,
                "-y",
                "-loglevel",
                "error",
                "-sseof",
                "-5.5",
                "-i",
                recording,
                "-filter_complex",
                "fps=10,scale=720:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle",
                str(root / "docs" / "demo.gif"),
            ],
            check=True,
        )


if __name__ == "__main__":
    main()
