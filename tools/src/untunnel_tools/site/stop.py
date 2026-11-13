"""Write the microphone check's copy of the word STOP from the page's clip: `site/test/stop.js`.

The check's content policy allows no connections, so it cannot fetch `clip.json`. The word it
sets, with its letter timings and the restored take's spectrum under it, ships as a script:

    uv run --project tools --locked python -m untunnel_tools.site.stop
"""

import base64
import json
import math
import sys
from pathlib import Path
from typing import Any

from untunnel_tools.paths import repo_root
from untunnel_tools.site import clip

OUTPUT = Path("site/test/stop.js")
WORD = "stop"
# The page blends each frame with two on either side, so the copy keeps two more each way.
BLEND_FRAMES = 2


def script(data: dict[str, Any]) -> str:
    """Return a script defining `STOP`: the word's timings and its restored spectrum."""
    word = next(item for item in data["words"] if item["text"] == WORD)
    hop = data["hop_ms"] / 1000
    bins = data["bins"]
    first = max(0, math.floor(word["start"] / hop) - BLEND_FRAMES)
    last = min(data["frames"], math.ceil(word["end"] / hop) + BLEND_FRAMES)
    rows = base64.b64decode(data["spectrum"])[first * bins : last * bins]
    copy = {
        "start": word["start"],
        "end": word["end"],
        "letters": word["letters"],
        "hop_ms": data["hop_ms"],
        "cut_hz": data["cut_hz"],
        "top_hz": data["top_hz"],
        "bins": bins,
        "first_frame": first,
        "frames": last - first,
        "spectrum": base64.b64encode(rows).decode("ascii"),
    }
    body = json.dumps(copy, separators=(",", ":"))
    return (
        f"// Written by untunnel_tools.site.stop from site/clip/clip.json.\n"
        f'"use strict";\n\nconst STOP = Object.freeze({body});\n'
    )


def main() -> None:
    """Rewrite the copy from the committed clip."""
    root = repo_root(Path(__file__))
    if "--print-root" in sys.argv[1:]:
        sys.stdout.write(f"{root}\n")
        return
    data = json.loads((root / clip.CLIP_DIRECTORY / "clip.json").read_text(encoding="utf-8"))
    (root / OUTPUT).write_text(script(data), encoding="utf-8")
    sys.stdout.write(f"{root / OUTPUT}\n")


if __name__ == "__main__":
    main()
