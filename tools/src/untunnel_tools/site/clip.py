"""Build the spoken line the project page sets as type, from audio through the shipped engine.

By default the line is the pinned LibriVox recording the parity goldens use, put through the
mSBC headset simulation and restored by `untunnel enhance --bwe 48000`. Pass `--headset` with a
recording of a real call (and `--words` with its timings) to replace it; nothing else changes.

Outputs, all in `site/clip/`: the two takes as FLAC (lossless, so the page does not lose the
band it is about), and `clip.json` with the word timings, the restored take's spectrum and the
numbers the page quotes. `docs/clip.md` repeats those numbers for the claims check.
"""

import argparse
import base64
import hashlib
import json
import subprocess
import sys
import tempfile
import urllib.request
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import soundfile

from untunnel_tools.eval import simulate_hfp as hfp
from untunnel_tools.goldens import HOP_MILLISECONDS, WINDOW_MILLISECONDS
from untunnel_tools.measure import FloatArray, read_mono
from untunnel_tools.paths import repo_root

# The recording `tools/reference/realtime_goldens.py` pins as SPEECH; that module needs torch.
SPEECH_URL = (
    "https://archive.org/download/short_poetry_001_librivox/"
    "because_I_could_not_stop_for_death_dickinson_64kb.mp3"
)
SPEECH_SHA256 = "641ad9e73d10e7bd928f590381e41ba79e6f3200621792aa0bf4e559ca1b43e8"
SPEECH_START_SECONDS = 11.0
SPEECH_SECONDS = 8.0

OUTPUT_RATE = 48_000
CONDITION = hfp.CONDITIONS[0]
BIN_HZ = 100
WELCH_LENGTH = 2048
DROP_DB = 40.0
FLOOR_DB = -90.0
LOW_PERCENTILE = 5.0
HIGH_PERCENTILE = 99.5
SMOOTH_COLUMNS = 31
VOICED_COLUMNS = 40
TILT = 0.8
FRAME_WEIGHT = 0.5
FADE_SECONDS = 0.02
MILLISECONDS = 1000

CLIP_DIRECTORY = Path("site") / "clip"
EVIDENCE = Path("docs") / "clip.md"
WORDS = Path("tools") / "reference" / "clip-words.json"


@dataclass(frozen=True)
class Word:
    """One spoken word and the span of the line it fills, in seconds from the window start."""

    text: str
    start: float
    end: float


def spans(onsets: list[tuple[str, float]], window: tuple[float, float]) -> list[Word]:
    """Turn word onsets into spans that run end to end across the window."""
    start, end = window
    if not onsets:
        message = "the timing file lists no words"
        raise ValueError(message)
    times = [onset for _, onset in onsets]
    if times != sorted(times) or times[0] < start or times[-1] >= end:
        message = f"word onsets must rise inside the window {start} to {end} s"
        raise ValueError(message)
    bounds = [*times, end]
    return [
        Word(text, round(bounds[index] - start, 3), round(bounds[index + 1] - start, 3))
        for index, (text, _) in enumerate(onsets)
    ]


VOWEL_LETTERS = frozenset("AEIOUY")
FRICATIVE_LETTERS = frozenset("SFZX")
STOP_LETTERS = frozenset("PTKBDGCQ")
TYPICAL_FRAMES = {"vowel": 4, "sonorant": 2, "fricative": 3, "stop": 2}
LENGTH_WEIGHT = 0.15


def letter_classes(word: str) -> list[str]:
    """Guess each letter's sound class from spelling: enough to share a word's time among them."""
    letters = [letter for letter in word.upper() if letter.isalpha()]
    classes: list[str] = []
    for index, letter in enumerate(letters):
        pairs = ("".join(letters[index : index + 2]), "".join(letters[index - 1 : index + 1]))
        in_th = "TH" in pairs
        if in_th or letter in FRICATIVE_LETTERS:
            classes.append("fricative")
        elif letter in VOWEL_LETTERS:
            classes.append("vowel")
        elif letter in STOP_LETTERS:
            classes.append("stop")
        else:
            classes.append("sonorant")
    return classes


def _normalised(values: FloatArray) -> FloatArray:
    low, high = np.percentile(values, [LOW_PERCENTILE, 100 - LOW_PERCENTILE])
    return np.clip((values - low) / max(float(high - low), 1e-9), 0, 1)


def landmarks(samples: FloatArray, sample_rate: int) -> str:
    """Return one line per 20 ms frame: voiced level and hiss, to place word onsets by eye."""
    power = 10 ** (spectrum(samples, sample_rate) / 10)
    low = 10 * np.log10(power[:, 1:10].sum(axis=1) + 1e-12)
    high = 10 * np.log10(power[:, 30:].sum(axis=1) + 1e-12)
    hop = HOP_MILLISECONDS / MILLISECONDS
    hiss = high - low
    return "".join(
        f"{index * hop:5.2f} s  voiced {low[index]:6.1f} dB  hiss {hiss[index]:6.1f} dB\n"
        for index in range(len(power))
    )


def frame_costs(samples: FloatArray, sample_rate: int) -> dict[str, FloatArray]:
    """Return, per 20 ms frame, how badly each sound class fits what the headset carried."""
    power = 10 ** (spectrum(samples, sample_rate) / 10)
    low = 10 * np.log10(power[:, 1:10].sum(axis=1) + 1e-12)
    high = 10 * np.log10(power[:, 30:].sum(axis=1) + 1e-12)
    voiced = _normalised(low)
    hiss = _normalised(high - low)
    loud = _normalised(10 * np.log10(power.sum(axis=1) + 1e-12))
    return {
        "vowel": (1 - voiced) + 0.5 * hiss,
        "sonorant": 0.6 * (1 - voiced) + 0.4 * hiss,
        "fricative": 1 - hiss,
        "stop": 0.3 + 0.7 * loud,
    }


def align(classes: list[str], costs: dict[str, FloatArray]) -> list[int]:
    """Split a run of frames among letters, in order, at least one frame each, at least cost.

    Each letter also pays for straying from its class's typical length, so the cheapest
    class cannot swallow the word: vowels hold, stops stay short. Returns the frame boundaries,
    first 0 and last the frame count. With fewer frames than
    letters every letter gets an equal share instead.
    """
    letters = len(classes)
    frames = len(next(iter(costs.values())))
    if frames < letters:
        return [round(index * frames / letters) for index in range(letters + 1)]
    sums = {name: np.concatenate([[0.0], np.cumsum(values)]) for name, values in costs.items()}
    best = np.full((letters + 1, frames + 1), np.inf)
    back = np.zeros((letters + 1, frames + 1), dtype=int)
    best[0, 0] = 0.0
    for letter in range(1, letters + 1):
        total = sums[classes[letter - 1]]
        for end in range(letter, frames - (letters - letter) + 1):
            starts = np.arange(letter - 1, end)
            typical = TYPICAL_FRAMES[classes[letter - 1]]
            stray = LENGTH_WEIGHT * (end - starts - typical) ** 2 / typical
            options = best[letter - 1, starts] + total[end] - total[starts] + stray
            pick = int(np.argmin(options))
            best[letter, end] = options[pick]
            back[letter, end] = starts[pick]
    bounds = [frames]
    for letter in range(letters, 0, -1):
        bounds.append(int(back[letter, bounds[-1]]))
    return bounds[::-1]


def letter_spans(word: Word, costs: dict[str, FloatArray], hop: float) -> list[list[object]]:
    """Return each letter of a word with the stretch of its span the audio gives it."""
    first = int(np.ceil(word.start / hop))
    last = max(first + 1, int(np.ceil(word.end / hop)))
    bounds = align(letter_classes(word.text), {k: v[first:last] for k, v in costs.items()})
    count = last - first
    width = word.end - word.start
    letters = [letter for letter in word.text.upper() if letter.isalpha()]
    return [
        [
            letter,
            round(word.start + width * bounds[index] / count, 3),
            round(word.start + width * bounds[index + 1] / count, 3),
        ]
        for index, letter in enumerate(letters)
    ]


def spectrum(samples: FloatArray, sample_rate: int) -> FloatArray:
    """Return magnitudes in dB, one row per 20 ms hop and one column per 100 Hz to Nyquist."""
    window = sample_rate * WINDOW_MILLISECONDS // MILLISECONDS
    hop = sample_rate * HOP_MILLISECONDS // MILLISECONDS
    padded = np.pad(samples, (window // 2, window // 2))
    frames = np.lib.stride_tricks.sliding_window_view(padded, window)[::hop] * np.hanning(window)
    bins_per_column = round(BIN_HZ * window / sample_rate)
    columns = (window // 2) // bins_per_column
    magnitude = np.abs(np.fft.rfft(frames, axis=1))[:, : columns * bins_per_column]
    grouped = magnitude.reshape(len(frames), columns, bins_per_column).mean(axis=2)
    return 20 * np.log10(grouped + 1e-12)


def rolloff_hz(samples: FloatArray, sample_rate: int) -> int:
    """Return the upper edge of the last bin within 40 dB of the loudest, as the mic test does."""
    frames = np.lib.stride_tricks.sliding_window_view(samples, WELCH_LENGTH)[:: WELCH_LENGTH // 2]
    power = (np.abs(np.fft.rfft(frames * np.hanning(WELCH_LENGTH), axis=1)) ** 2).mean(axis=0)
    loud = np.flatnonzero(power >= power.max() / 10 ** (DROP_DB / 10))
    return round(min((int(loud[-1]) + 1) * sample_rate / WELCH_LENGTH, sample_rate / 2))


def texture(decibels: FloatArray, cut_column: int) -> bytes:
    """Scale the spectrum to bytes, the band that survives and the predicted band each on its own.

    The predicted band is smoothed across frequency, so its grain runs along time in 20 ms
    columns with sharp onsets. Each frame is then measured against its own voiced band (up to
    4 kHz), so hiss over a quiet mouth, the s, t and f, burns while a vowel's upper harmonics
    stay faint. Each 100 Hz row is normalised across the line on the dB scale, then half of
    every cell is its frame's mean, so the picture reads along time, not in streaks along rows.
    """
    scaled = np.empty_like(decibels)
    surviving = decibels[:, :cut_column]
    low, high = np.percentile(surviving, [LOW_PERCENTILE, HIGH_PERCENTILE])
    scaled[:, :cut_column] = (surviving - low) / max(high - low, 1e-9)
    kernel = np.ones(SMOOTH_COLUMNS) / SMOOTH_COLUMNS
    predicted = np.apply_along_axis(
        lambda row: np.convolve(np.pad(row, SMOOTH_COLUMNS // 2, mode="edge"), kernel, "valid"),
        1,
        decibels[:, cut_column:],
    )
    power = 10 ** (decibels[:, 1:VOICED_COLUMNS] / 10)
    voiced = 10 * np.log10(power.sum(axis=1) + 1e-12)
    predicted -= TILT * voiced[:, None]
    floor, peak = np.percentile(predicted, [LOW_PERCENTILE, HIGH_PERCENTILE], axis=0)
    rows = np.clip((predicted - floor) / np.maximum(peak - floor, 1e-9), 0, 1)
    frame_means = rows.mean(axis=1, keepdims=True)
    scaled[:, cut_column:] = FRAME_WEIGHT * frame_means + (1 - FRAME_WEIGHT) * rows
    return (np.clip(scaled, 0, 1) * 255).round().astype(np.uint8).tobytes()


def faded(samples: FloatArray, sample_rate: int) -> FloatArray:
    """Ramp both ends so the cut window does not click."""
    ramp = np.linspace(0, 1, round(FADE_SECONDS * sample_rate))
    out = samples.copy()
    out[: len(ramp)] *= ramp
    out[len(out) - len(ramp) :] *= ramp[::-1]
    return out


def _fetch_speech(cache: Path) -> Path:
    path = cache / SPEECH_URL.rsplit("/", 1)[1]
    if not path.is_file():
        path.parent.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(SPEECH_URL) as response:
            path.write_bytes(response.read())
    if hashlib.sha256(path.read_bytes()).hexdigest() != SPEECH_SHA256:
        message = f"{path} does not match the pinned SHA-256; delete it and rerun"
        raise SystemExit(message)
    return path


def _simulated_headset(cache: Path) -> tuple[FloatArray, FloatArray]:
    """Return the clean excerpt at 48 kHz and its mSBC round trip at 16 kHz."""
    samples, rate = soundfile.read(str(_fetch_speech(cache)), dtype="float64", always_2d=True)
    start = round(SPEECH_START_SECONDS * rate)
    excerpt = np.asarray(samples[start : start + round(SPEECH_SECONDS * rate)].mean(axis=1))
    clean = hfp.resample(excerpt, int(rate), OUTPUT_RATE)
    return clean, hfp.degrade(clean, CONDITION, np.random.default_rng(0))


def _restore(untunnel: Path, headset: FloatArray, rate: int) -> FloatArray:
    with tempfile.TemporaryDirectory() as folder:
        source, restored = Path(folder) / "headset.wav", Path(folder) / "restored.wav"
        soundfile.write(str(source), headset, rate, subtype="FLOAT")
        # Every argument is a path this function created or the engine the caller named.
        subprocess.run(  # noqa: S603
            [
                str(untunnel),
                "enhance",
                str(source),
                str(restored),
                "--model",
                "streaming",
                "--bwe",
                str(OUTPUT_RATE),
            ],
            check=True,
            capture_output=True,
        )
        samples, restored_rate = read_mono(restored)
    if restored_rate != OUTPUT_RATE:
        message = f"the engine wrote {restored_rate} Hz, expected {OUTPUT_RATE} Hz"
        raise RuntimeError(message)
    return samples


def _window(samples: FloatArray, rate: int, window: tuple[float, float]) -> FloatArray:
    return faded(samples[round(window[0] * rate) : round(window[1] * rate)], rate)


def _khz(hertz: int) -> str:
    return f"{hertz / 1000:.1f}".removesuffix(".0")


def build(
    root: Path, untunnel: Path, headset_path: Path | None, words_path: Path
) -> dict[str, object]:
    """Write the clip files under `root` and return the page's data."""
    timing = json.loads(words_path.read_text(encoding="utf-8"))
    window = (float(timing["window_seconds"][0]), float(timing["window_seconds"][1]))
    words = spans([(str(text), float(onset)) for text, onset in timing["words"]], window)
    cache = root / ".cache" / "site-clip"
    clean: FloatArray | None = None
    if headset_path is None:
        clean, headset = _simulated_headset(cache)
        headset_rate = CONDITION.sample_rate
    else:
        headset, headset_rate = read_mono(headset_path)
    restored = _restore(untunnel, headset, headset_rate)

    headset_line = _window(headset, headset_rate, window)
    restored_line = _window(restored, OUTPUT_RATE, window)
    out = root / CLIP_DIRECTORY
    out.mkdir(parents=True, exist_ok=True)
    soundfile.write(str(out / "headset.flac"), headset_line, headset_rate, subtype="PCM_16")
    soundfile.write(str(out / "untunnel.flac"), restored_line, OUTPUT_RATE, subtype="PCM_16")

    cut_hz = headset_rate // 2 if headset_path is not None else CONDITION.bandwidth_hz
    costs = frame_costs(headset_line, headset_rate)
    decibels = np.maximum(spectrum(restored_line, OUTPUT_RATE), FLOOR_DB)
    rolloff = {
        "headset": rolloff_hz(headset_line, headset_rate),
        "untunnel": rolloff_hz(restored_line, OUTPUT_RATE),
    }
    if clean is not None:
        rolloff["original"] = rolloff_hz(_window(clean, OUTPUT_RATE, window), OUTPUT_RATE)
    data: dict[str, object] = {
        "recording": timing["recording"],
        "timing": timing["timing"],
        "simulated": headset_path is None,
        "seconds": round(window[1] - window[0], 3),
        "hop_ms": HOP_MILLISECONDS,
        "window_ms": WINDOW_MILLISECONDS,
        "bin_hz": BIN_HZ,
        "cut_hz": cut_hz,
        "top_hz": OUTPUT_RATE // 2,
        "rolloff_hz": rolloff,
        "words": [
            {
                "text": word.text,
                "start": word.start,
                "end": word.end,
                "letters": letter_spans(word, costs, HOP_MILLISECONDS / MILLISECONDS),
            }
            for word in words
        ],
        "frames": int(decibels.shape[0]),
        "bins": int(decibels.shape[1]),
        "spectrum": base64.b64encode(texture(decibels, cut_hz // BIN_HZ)).decode("ascii"),
    }
    (out / "clip.json").write_text(json.dumps(data, separators=(",", ":")) + "\n", encoding="utf-8")
    (root / EVIDENCE).write_text(
        evidence(
            str(timing["recording"]), len(decibels), cut_hz, rolloff, simulated=headset_path is None
        ),
        encoding="utf-8",
    )
    return data


def evidence(
    recording: str, frames: int, cut_hz: int, rolloff: dict[str, int], *, simulated: bool
) -> str:
    """Render the numbers the page quotes as the results document the claims check reads."""
    headset = "the mSBC simulation in `simulate_hfp.py`" if simulated else "a real call"
    lines = [
        "# The line on the project page",
        "",
        "Written by `uv run --project tools python -m untunnel_tools.site.clip`; do not edit.",
        "",
        f"- Recording: {recording}.",
        f"- Headset: {headset}, which carries {_khz(cut_hz)} kHz.",
        (
            f"- Restored by `untunnel enhance --model streaming --bwe {OUTPUT_RATE}`, which writes "
            f"{_khz(OUTPUT_RATE)} kHz audio and so predicts up to {_khz(OUTPUT_RATE // 2)} kHz."
        ),
        (
            f"- Spectrum: {WINDOW_MILLISECONDS} ms Hann window, {HOP_MILLISECONDS} ms hop, "
            f"{BIN_HZ} Hz columns; {frames} frames."
        ),
        (
            "- Rolloff, the upper edge of the last FFT bin within 40 dB of the loudest "
            "(2048-point Hann, half overlap):"
        ),
    ]
    lines += [f"  - {name}: {_khz(hertz)} kHz ({hertz} Hz)" for name, hertz in rolloff.items()]
    return "\n".join(lines) + "\n"


def main() -> None:
    """Regenerate the page's clip from the command line."""
    root = repo_root(Path(__file__))
    if "--print-root" in sys.argv[1:]:
        sys.stdout.write(f"{root}\n")
        return
    parser = argparse.ArgumentParser(description="Regenerate the line on the project page.")
    parser.add_argument("--untunnel", type=Path, default=root / ".build" / "release" / "untunnel")
    parser.add_argument("--headset", type=Path, help="a mono recording of a real call")
    parser.add_argument("--words", type=Path, default=root / WORDS, help="word onsets, same format")
    parser.add_argument(
        "--frames", action="store_true", help="print the committed headset take's landmarks"
    )
    arguments = parser.parse_args()
    if arguments.frames:
        headset, rate = read_mono(root / CLIP_DIRECTORY / "headset.flac")
        sys.stdout.write(landmarks(headset, rate))
        return
    data = build(root, arguments.untunnel, arguments.headset, arguments.words)
    print(json.dumps(data["rolloff_hz"]))  # noqa: T201


if __name__ == "__main__":
    main()
