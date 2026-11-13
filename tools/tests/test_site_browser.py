import base64
import json
from collections.abc import Generator
from contextlib import contextmanager
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread
from typing import Protocol

import pytest

from untunnel_tools.paths import repo_root


class _QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, format: str, *args: object) -> None:  # noqa: A002
        """Keep the test output to assertions."""


class _AbortRoute(Protocol):
    def abort(self) -> None: ...


def _abort(route: _AbortRoute) -> None:
    route.abort()


class _RequestLog:
    def __init__(self) -> None:
        self.urls: list[str] = []

    def __call__(self, request: object) -> None:
        url: object = getattr(request, "url", None)
        if isinstance(url, str):
            self.urls.append(url)


@contextmanager
def _serve(directory: Path) -> Generator[str, None, None]:
    """Serve the site on a loopback URL, which browsers treat as a secure context."""
    handler = partial(_QuietHandler, directory=str(directory))
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def test_mic_test_page_measures_the_fixture_and_renders_every_state() -> None:
    """The no-install page must reproduce the committed rolloff and reach every state."""
    playwright_api = pytest.importorskip("playwright.sync_api")
    sync_playwright = playwright_api.sync_playwright
    root = repo_root(Path(__file__))
    fixture = json.loads(
        (root / "fixtures" / "narrowband" / "sample.rolloff.json").read_text(encoding="utf-8")
    )
    expected = int(fixture["rolloff_40db_hz"])
    sample = root / "fixtures" / "narrowband" / "sample.wav"

    with _serve(root / "site") as base_url, sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            headless=True,
            args=[
                "--use-fake-ui-for-media-stream",
                "--use-fake-device-for-media-stream",
                f"--use-file-for-fake-audio-capture={sample.resolve()}",
            ],
        )
        try:
            context = browser.new_context()
            context.grant_permissions(["microphone"], origin=base_url)
            page = context.new_page()
            requests = _RequestLog()
            page.on("request", requests)
            page.goto(f"{base_url}/test/index.html", wait_until="domcontentloaded", timeout=180_000)
            playwright_api.expect(page.locator("#start")).to_be_visible(timeout=10_000)
            page.wait_for_load_state("networkidle", timeout=5_000)
            requests.urls.clear()

            page.click("#start")
            page.wait_for_selector('#main[data-state="ready"]', timeout=90_000)
            page.click("#take")
            page.wait_for_selector('#main[data-state="result"]', timeout=90_000)

            measured = page.evaluate("window.MIC_TEST.lastRolloffHz")
            assert isinstance(measured, int)
            assert abs(measured - expected) <= 200

            ended = page.evaluate("window.MIC_TEST.takeEndedAt")
            shown = page.evaluate("window.MIC_TEST.resultShownAt")
            assert isinstance(ended, (int, float))
            assert isinstance(shown, (int, float))
            assert shown - ended <= 1000
            assert requests.urls == []

            states = page.evaluate("window.MIC_TEST.states.join(',')")
            assert isinstance(states, str)
            for state in states.split(","):
                page.goto(
                    f"{base_url}/test/index.html#state={state}",
                    wait_until="domcontentloaded",
                    timeout=180_000,
                )
                playwright_api.expect(page.locator("#main")).to_have_attribute(
                    "data-state", state, timeout=5_000
                )
                assert page.get_attribute("#main", "data-state") == state
                assert page.locator("#panel").inner_text().strip()
        finally:
            browser.close()


# Reads which columns of a PNG carry ink (black or red) between two rows, skipping the rows of
# the dashed cut line, decoded by the browser itself. The rows start under the 24 kHz hairline.
_INK_COLUMNS = """async ({ png, top, bottom, cut }) => {
    const image = new Image();
    image.src = `data:image/png;base64,${png}`;
    await image.decode();
    const canvas = document.createElement("canvas");
    canvas.width = image.width;
    canvas.height = image.height;
    const context = canvas.getContext("2d");
    context.drawImage(image, 0, 0);
    const pixels = context.getImageData(0, top, image.width, bottom - top).data;
    return Array.from({ length: image.width }, (_, x) => {
        for (let y = 0; y < bottom - top; y += 1) {
            if (Math.abs(top + y - cut) <= 2) {
                continue;
            }
            const at = (y * image.width + x) * 4;
            if (pixels[at] + pixels[at + 1] + pixels[at + 2] < 600) {
                return true;
            }
        }
        return false;
    });
}"""

_REGISTER_PX = 3


def test_ruler_words_sit_under_their_glyphs() -> None:
    """On a wide screen each word's button is centred under the glyphs the shader drew."""
    playwright_api = pytest.importorskip("playwright.sync_api")
    root = repo_root(Path(__file__))
    with _serve(root / "site") as base_url, playwright_api.sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            headless=True, args=["--use-angle=swiftshader", "--enable-unsafe-swiftshader"]
        )
        try:
            page = browser.new_page(
                viewport={"width": 1440, "height": 900}, reduced_motion="reduce"
            )
            page.goto(f"{base_url}/index.html", wait_until="domcontentloaded", timeout=180_000)
            playwright_api.expect(page.locator("#score")).to_have_attribute(
                "data-state", "live", timeout=180_000
            )
            band = page.evaluate(
                """() => {
                    const row = document.querySelector('.stave--restored');
                    const cut = row.offsetTop + row.querySelector('.stave__cut').offsetTop;
                    const bottom = row.offsetTop + row.offsetHeight;
                    const top = row.offsetTop + 3;
                    return { top, bottom: Math.floor(bottom - 2), cut, left: row.offsetLeft };
                }"""
            )
            png = base64.b64encode(page.locator("#score").screenshot()).decode("ascii")
            ink: list[bool] = page.evaluate(
                _INK_COLUMNS,
                {"png": png, "top": band["top"], "bottom": band["bottom"], "cut": band["cut"]},
            )
            spans: list[list[float]] = page.evaluate(
                """() => {
                    const left = document.querySelector('#score').getBoundingClientRect().left;
                    return [...document.querySelectorAll('.ruler__word')].map((button) => {
                        const box = button.getBoundingClientRect();
                        return [box.left - left, box.right - left];
                    });
                }"""
            )
        finally:
            browser.close()

    # Each word owns the columns from halfway into the gap before its button to halfway into the
    # gap after it, and the first starts where the stave does, clear of the scale; the ink in that
    # window must centre on the button.
    bounds = [float(band["left"])]
    bounds += [(spans[i][1] + spans[i + 1][0]) / 2 for i in range(len(spans) - 1)]
    bounds.append(float(len(ink)))
    for index, (left, right) in enumerate(spans):
        window = range(round(bounds[index]), round(bounds[index + 1]))
        inked = [x for x in window if ink[x]]
        assert inked, f"no ink under word {index}"
        assert abs((inked[0] + inked[-1]) / 2 - (left + right) / 2) <= _REGISTER_PX


def test_clip_load_failure_leaves_visible_recovery() -> None:
    """A failed metadata request leaves disabled controls and a visible retry instruction."""
    playwright_api = pytest.importorskip("playwright.sync_api")
    root = repo_root(Path(__file__))
    with _serve(root / "site") as base_url, playwright_api.sync_playwright() as playwright:
        browser = playwright.chromium.launch(headless=True)
        try:
            page = browser.new_page()
            page.route("**/clip/clip.json", _abort)
            page.goto(f"{base_url}/index.html", wait_until="domcontentloaded", timeout=180_000)
            playwright_api.expect(page.locator("html")).to_have_attribute(
                "data-ready", "error", timeout=180_000
            )
            playwright_api.expect(page.locator(".listen__status")).to_be_visible()
            playwright_api.expect(page.locator(".listen__status")).to_contain_text("Reload")
            playwright_api.expect(page.get_by_role("button", name="Play the line")).to_be_disabled()
        finally:
            browser.close()


def test_playback_failure_restores_the_play_control() -> None:
    """A rejected play operation shows a retry message and restores the button."""
    playwright_api = pytest.importorskip("playwright.sync_api")
    root = repo_root(Path(__file__))
    with _serve(root / "site") as base_url, playwright_api.sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            headless=True, args=["--use-angle=swiftshader", "--enable-unsafe-swiftshader"]
        )
        try:
            page = browser.new_page()
            page.add_init_script(
                "HTMLMediaElement.prototype.play = () => Promise.reject(new Error('failed'))"
            )
            page.goto(f"{base_url}/index.html", wait_until="domcontentloaded", timeout=180_000)
            button = page.get_by_role("button", name="Play the line")
            playwright_api.expect(button).to_be_enabled(timeout=180_000)
            button.click()
            playwright_api.expect(page.locator(".listen__status")).to_contain_text(
                "retry", timeout=90_000
            )
            playwright_api.expect(button).to_have_text("Play the line")
        finally:
            browser.close()


def test_comparison_uses_the_builtin_device_and_shows_recording_progress() -> None:
    """Default aliases must not be mistaken for a built-in comparison microphone."""
    playwright_api = pytest.importorskip("playwright.sync_api")
    root = repo_root(Path(__file__))
    with _serve(root / "site") as base_url, playwright_api.sync_playwright() as playwright:
        browser = playwright.chromium.launch(headless=True)
        try:
            page = browser.new_page()
            page.add_init_script("""(() => {
                window.recordedDevices = [];
                navigator.mediaDevices.enumerateDevices = async () => [
                    ['default', 'MacBook Pro Microphone'], ['headset', 'AirPods Pro'],
                    ['builtin', 'MacBook Pro Microphone']
                ].map(([deviceId, label]) => ({kind: 'audioinput', deviceId, label}));
                navigator.mediaDevices.getUserMedia = async (options) => {
                    window.recordedDevices.push(options.audio.deviceId?.exact || 'probe');
                    const context = new AudioContext();
                    await context.resume();
                    const destination = context.createMediaStreamDestination();
                    const oscillator = context.createOscillator();
                    oscillator.connect(destination);
                    oscillator.start();
                    return destination.stream;
                };
            })()""")
            page.goto(f"{base_url}/test/", wait_until="domcontentloaded", timeout=180_000)
            page.locator("#start").click()
            page.locator("#device").select_option("headset")
            page.locator("#take").click()
            playwright_api.expect(page.locator("progress")).to_be_visible(timeout=5_000)
            playwright_api.expect(page.locator("progress")).not_to_have_js_property(
                "value", 0, timeout=10_000
            )
            playwright_api.expect(page.locator("#result")).to_be_visible(timeout=90_000)
            assert "this take" in page.locator("#result").inner_text()
            page.locator("#compare").click()
            playwright_api.expect(page.locator(".comparison")).to_be_visible(timeout=90_000)
            assert page.evaluate("window.recordedDevices")[-1] == "builtin"
        finally:
            browser.close()
