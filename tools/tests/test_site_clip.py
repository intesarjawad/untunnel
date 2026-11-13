import base64
import json
from pathlib import Path
from typing import Any

import numpy as np
import pytest

from untunnel_tools.paths import repo_root
from untunnel_tools.site import clip, stop

RATE = 48_000


def test_spans_run_end_to_end_from_the_window_start() -> None:
    """Each word fills the line up to the next onset; the last runs to the window end."""
    words = clip.spans([("Because", 3.47), ("I", 3.80), ("could", 3.88)], (3.44, 4.19))
    assert [(word.text, word.start, word.end) for word in words] == [
        ("Because", 0.03, 0.36),
        ("I", 0.36, 0.44),
        ("could", 0.44, 0.75),
    ]


@pytest.mark.parametrize(
    "onsets",
    [[], [("a", 1.0), ("b", 0.5)], [("a", 0.1)], [("a", 2.0)]],
)
def test_spans_reject_onsets_outside_or_out_of_order(onsets: list[tuple[str, float]]) -> None:
    """An empty, unordered or out-of-window timing file is an error, not a squashed line."""
    with pytest.raises(ValueError, match=r"words|onsets"):
        clip.spans(onsets, (0.5, 2.0))


def test_rolloff_finds_a_low_pass_edge() -> None:
    """White noise low-passed at 8 kHz rolls off within a few hundred hertz of 8 kHz."""
    rng = np.random.default_rng(0)
    noise = rng.standard_normal(RATE * 2)
    band = np.fft.rfft(noise)
    band[np.fft.rfftfreq(len(noise), 1 / RATE) > 8_000] = 0
    narrow = np.fft.irfft(band, len(noise))
    assert abs(clip.rolloff_hz(narrow, RATE) - 8_000) < 400


def test_spectrum_has_one_row_per_hop_and_one_column_per_100_hz() -> None:
    """Two seconds at 48 kHz give 101 frames of 240 columns up to 24 kHz."""
    tone = np.sin(2 * np.pi * 1_000 * np.arange(RATE * 2) / RATE)
    decibels = clip.spectrum(tone, RATE)
    assert decibels.shape == (101, 240)
    assert int(np.argmax(decibels[50])) == 10


def test_texture_burns_hiss_over_a_quiet_mouth_and_keeps_vowels_faint() -> None:
    """A hiss quieter up top than a vowel's harmonics still outshines them: tops read as sound."""
    vowel = np.concatenate([np.zeros(80), np.full(160, -40.0)])
    hiss = np.concatenate([np.full(80, -40.0), np.full(160, -45.0)])
    silence = np.full(240, -90.0)
    pixels = np.frombuffer(clip.texture(np.stack([vowel, hiss, silence]), 80), dtype=np.uint8)
    top = pixels.reshape(3, 240)[:, 80:].mean(axis=1)
    assert top[1] == 255
    assert top[0] == 0


def test_letter_classes_read_th_as_one_fricative() -> None:
    """Spelling gives each letter a class; the th of Death is a fricative, both letters."""
    assert clip.letter_classes("Death,") == ["stop", "vowel", "vowel", "fricative", "fricative"]


def test_align_holds_vowels_and_clips_stops_when_the_audio_is_neutral() -> None:
    """With no evidence either way, a stop gets two frames and a vowel four."""
    costs = {name: np.zeros(8) for name in clip.TYPICAL_FRAMES}
    assert clip.align(["stop", "vowel", "stop"], costs) == [0, 2, 6, 8]


def _letter_brightness(data: dict[str, Any], word: str, letter: str) -> float:
    pixels = np.frombuffer(base64.b64decode(data["spectrum"]), dtype=np.uint8)
    rows = pixels.reshape(int(data["frames"]), int(data["bins"]))
    cut = int(data["cut_hz"]) // int(data["bin_hz"])
    hop = int(data["hop_ms"]) / 1000
    entry: dict[str, Any] = next(item for item in data["words"] if item["text"] == word)
    spans: list[tuple[str, float, float]] = [tuple(item) for item in entry["letters"]]
    start, end = next((start, end) for name, start, end in spans if name == letter)
    first = round(start / hop)
    return float(rows[first : max(first + 1, round(end / hop)), cut:].mean())


def test_committed_clip_burns_the_s_of_stop_brighter_than_the_vowel_of_not() -> None:
    """On the real line the sibilant flares and the vowel stays faint, as the page claims."""
    root = repo_root(Path(__file__))
    data = json.loads((root / clip.CLIP_DIRECTORY / "clip.json").read_text(encoding="utf-8"))
    assert _letter_brightness(data, "stop", "S") > 2 * _letter_brightness(data, "not", "O")


def test_committed_clip_matches_its_timing_file() -> None:
    """The page's words come from the committed timing file, and its numbers reach the evidence."""
    root = repo_root(Path(__file__))
    data = json.loads((root / clip.CLIP_DIRECTORY / "clip.json").read_text(encoding="utf-8"))
    timing = json.loads((root / clip.WORDS).read_text(encoding="utf-8"))
    assert [word["text"] for word in data["words"]] == [text for text, _ in timing["words"]]
    assert len(base64.b64decode(data["spectrum"])) == data["frames"] * data["bins"]
    evidence = (root / clip.EVIDENCE).read_text(encoding="utf-8")
    for hertz in data["rolloff_hz"].values():
        assert f"({hertz} Hz)" in evidence


def test_microphone_check_carries_the_committed_clips_stop() -> None:
    """The check's copy of STOP is the clip's, word for word and frame for frame."""
    root = repo_root(Path(__file__))
    data = json.loads((root / clip.CLIP_DIRECTORY / "clip.json").read_text(encoding="utf-8"))
    assert (root / stop.OUTPUT).read_text(encoding="utf-8") == stop.script(data)
    copy = json.loads(stop.script(data).split("Object.freeze(", 1)[1].rsplit(");", 1)[0])
    assert copy["frames"] * copy["bins"] == len(base64.b64decode(copy["spectrum"]))
    assert copy["first_frame"] * data["hop_ms"] / 1000 <= copy["start"]
