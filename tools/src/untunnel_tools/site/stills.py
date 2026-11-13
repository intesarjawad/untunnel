"""Render the project page's still frames: its no-WebGL fallback, README hero and social card.

Every image is a screenshot of `site/index.html` itself, drawn by its own shader, so a change to
the clip (`untunnel_tools.site.clip`) or the page reaches all of them in one run:

    uv run --project tools --group site python -m untunnel_tools.site.stills
"""

import importlib
import sys
from collections.abc import Generator
from contextlib import contextmanager
from dataclasses import dataclass
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread

from untunnel_tools.paths import repo_root


@dataclass(frozen=True)
class Still:
    """One frame: where it goes, the page's frame query, the viewport and what to capture."""

    output: Path
    query: str
    width: int
    height: int
    scale: float
    selector: str | None = None


STILLS = (
    Still(Path("site/clip/still-wide.png"), "frame=still", 1440, 900, 1, "#score"),
    Still(Path("site/clip/still-narrow.png"), "frame=still", 390, 844, 2, "#score"),
    Still(Path("docs/hero.png"), "frame=hero&at=0.83", 1280, 640, 1.5),
    Still(Path("site/social-card.png"), "frame=card", 1280, 640, 1),
)


class _QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, format: str, *args: object) -> None:  # noqa: A002
        """Keep the output to the files written."""


@contextmanager
def serve(directory: Path) -> Generator[str, None, None]:
    """Serve a directory on loopback while rendering its pages."""
    server = ThreadingHTTPServer(("127.0.0.1", 0), partial(_QuietHandler, directory=str(directory)))
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def render(root: Path) -> list[Path]:
    """Write every still under `root` and return their paths."""
    # Playwright lives in the optional `site` group, so the default type check runs without it.
    sync_playwright = importlib.import_module("playwright.sync_api").sync_playwright

    written: list[Path] = []
    with serve(root / "site") as base, sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            args=["--use-angle=swiftshader", "--enable-unsafe-swiftshader"]
        )
        try:
            for still in STILLS:
                page = browser.new_page(
                    viewport={"width": still.width, "height": still.height},
                    device_scale_factor=still.scale,
                )
                page.goto(f"{base}/index.html?{still.query}", wait_until="networkidle")
                page.wait_for_function("document.documentElement.dataset.ready === 'true'")
                page.wait_for_selector('#score[data-state="live"]')
                target = root / still.output
                if still.selector is None:
                    page.screenshot(path=str(target))
                else:
                    page.locator(still.selector).screenshot(path=str(target), omit_background=True)
                page.close()
                written.append(target)
        finally:
            browser.close()
    return written


def main() -> None:
    """Render the stills from the command line."""
    root = repo_root(Path(__file__))
    if "--print-root" in sys.argv[1:]:
        sys.stdout.write(f"{root}\n")
        return
    for path in render(root):
        print(path)  # noqa: T201


if __name__ == "__main__":
    main()
