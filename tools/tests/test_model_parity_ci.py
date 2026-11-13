import os
import re
import subprocess
import textwrap
from pathlib import Path

import pytest

from untunnel_tools.paths import repo_root


@pytest.mark.parametrize("downloaded", [0, 1, 2])
def test_ci_checkpoint_gate_rejects_a_missing_download(tmp_path: Path, downloaded: int) -> None:
    """Exercise the workflow's actual shell gate, including a partially restored cache."""
    root = repo_root(Path(__file__))
    workflow = (root / ".github/workflows/ci.yml").read_text()
    gate = re.search(
        r"- name: Fail instead of skipping parity[^\n]*\n\s+run: \|\n"
        r"(?P<script>(?: {10,}[^\n]*\n)+)",
        workflow,
    )
    assert gate is not None, "CI must fail before running parity without its checkpoints"
    script = textwrap.dedent(gate["script"])
    # Use the same manifests and pinned destinations as the workflow, without real weights.
    manifests = ("realtime-goldens.json", "offline-goldens.json")
    import json  # noqa: PLC0415

    for filename in manifests[:downloaded]:
        manifest = json.loads((root / "fixtures/model" / filename).read_text())
        pinned = f"{manifest['repository']}@{manifest['revision']}"
        destination = tmp_path / "Library/Application Support/Untunnel/models" / pinned
        destination.mkdir(parents=True)
        (destination / "model.safetensors").touch()
    result = subprocess.run(  # noqa: S603
        ["/bin/bash", "-eu", "-c", script],
        cwd=root,
        env={**os.environ, "HOME": str(tmp_path)},
        capture_output=True,
        check=False,
    )
    assert (result.returncode == 0) == (downloaded == len(manifests))
