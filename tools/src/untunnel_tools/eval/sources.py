import argparse
import hashlib
import json
import re
import shlex
import sys
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit

import numpy as np
import soundfile

from untunnel_tools.measure import FloatArray, read_mono
from untunnel_tools.paths import repo_root

type JSONValue = dict[str, JSONValue] | list[JSONValue] | str | int | float | bool | None

FRAME_MILLISECONDS = 20
PAUSE_MILLISECONDS = 300
PAUSE_THRESHOLD_DB = -40.0
MIN_SEGMENT_SECONDS = 3.0
MAX_SEGMENT_SECONDS = 10.0
DRAW_SEED = 0
DAPS_UTTERANCES_PER_SPEAKER = 10
DAPS_SPEAKER_COUNT = 20
VCTK_UTTERANCES_PER_SPEAKER = 25
VCTK_TEST_SPEAKERS = ("p360", "p361", "p362", "p363", "p364", "p374", "p376", "s5")
VCTK_AUDIO_DIRECTORY = "wav48_silence_trimmed"
VCTK_TEXT_DIRECTORY = "txt"
LIST_HEADER = (
    "# corpus<TAB>speaker<TAB>file<TAB>start_sample<TAB>end_sample, sample positions at the "
    "corpus's native rate; vctk lines use the whole file and write - for both positions."
)

REQUIRED_SOURCES = frozenset(
    {
        "daps",
        "vctk",
        "ap_bwe_code",
        "ap_bwe_checkpoint",
        "ap_bwe_config",
        "webmushra",
        "dnsmos",
        "deep_filter",
        "whisper",
        "reuse_rs",
        "reusemic",
        "hush_ai",
    }
)


@dataclass(frozen=True)
class Source:
    """A versioned evaluation artifact whose bytes must match before use."""

    identifier: str
    filename: str
    url: str
    version: str
    sha256: str
    size_bytes: int
    license: str
    license_url: str


def _text(record: Mapping[str, object], field: str) -> str:
    value = record.get(field)
    if not isinstance(value, str) or not value.strip():
        message = f"sources: {field} must be a non-empty string."
        raise ValueError(message)
    return value


def _https_url(record: Mapping[str, object], field: str) -> str:
    value = _text(record, field)
    parsed = urlsplit(value)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        message = f"sources: {field} must be an HTTPS URL without credentials."
        raise ValueError(message)
    return value


def _source(record: Mapping[str, object]) -> Source:
    filename = _text(record, "filename")
    if Path(filename).name != filename or filename in {".", ".."} or "\\" in filename:
        message = "sources: filename must be a single cache filename."
        raise ValueError(message)
    sha256 = _text(record, "sha256")
    if re.fullmatch(r"[0-9a-f]{64}", sha256) is None:
        message = "sources: sha256 must be 64 lowercase hexadecimal characters."
        raise ValueError(message)
    version = _text(record, "version")
    if re.fullmatch(r"[0-9a-f]{40}|v?\d+(?:\.\d+)+(?:[-+][\w.-]+)?", version) is None:
        message = "sources: version must be an exact release version or full commit revision."
        raise ValueError(message)
    size_bytes = record.get("size_bytes")
    if type(size_bytes) is not int or size_bytes <= 0:
        message = "sources: size_bytes must be a positive integer."
        raise ValueError(message)
    return Source(
        identifier=_text(record, "id"),
        filename=filename,
        url=_https_url(record, "url"),
        version=version,
        sha256=sha256,
        size_bytes=size_bytes,
        license=_text(record, "license"),
        license_url=_https_url(record, "license_url"),
    )


def load_sources(path: Path) -> tuple[Source, ...]:
    """Validate manifest fields before using any paths or artifact identities."""
    manifest: JSONValue = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict):
        message = "sources: manifest must be a JSON object."
        raise TypeError(message)
    records = manifest.get("sources")
    if not isinstance(records, list) or not records:
        message = "sources: manifest must contain a non-empty sources array."
        raise ValueError(message)
    sources: list[Source] = []
    identifiers: set[str] = set()
    filenames: set[str] = set()
    for record in records:
        if not isinstance(record, dict):
            message = "sources: every entry must be a JSON object."
            raise TypeError(message)
        source = _source(record)
        if source.identifier in identifiers or source.filename in filenames:
            message = f"Duplicate sources identity or filename: {source.identifier}."
            raise ValueError(message)
        identifiers.add(source.identifier)
        filenames.add(source.filename)
        sources.append(source)
    return tuple(sources)


def verify_file(source: Source, path: Path) -> None:
    """Reject missing, truncated or altered cached artifacts without modifying them."""
    if not path.is_file():
        command = shlex.join(
            [
                "curl",
                "--fail",
                "--location",
                "--proto",
                "=https",
                "--proto-redir",
                "=https",
                "--output",
                str(path),
                source.url,
            ]
        )
        message = (
            f"{source.identifier}: missing {path}. Create its parent directory, then run {command}"
        )
        raise FileNotFoundError(message)
    actual_size = path.stat().st_size
    if actual_size != source.size_bytes:
        message = (
            f"{source.identifier}: size {actual_size} does not match "
            f"{source.size_bytes} bytes: {path}"
        )
        raise ValueError(message)
    with path.open("rb") as artifact:
        digest = hashlib.file_digest(artifact, "sha256").hexdigest()
    if digest != source.sha256:
        message = f"{source.identifier}: SHA-256 {digest} does not match {source.sha256}: {path}"
        raise ValueError(message)


def verify_sources(root: Path) -> int:
    """Require the complete task catalog and hash every artifact in the local cache."""
    sources = load_sources(root / "fixtures" / "eval" / "sources.json")
    identifiers = frozenset(source.identifier for source in sources)
    if identifiers != REQUIRED_SOURCES:
        message = (
            f"sources: missing {sorted(REQUIRED_SOURCES - identifiers)}, "
            f"unexpected {sorted(identifiers - REQUIRED_SOURCES)}."
        )
        raise ValueError(message)
    cache = root / ".cache" / "eval"
    for source in sources:
        verify_file(source, cache / source.filename)
        sys.stdout.write(f"{source.identifier}: SHA-256 OK ({source.size_bytes} bytes)\n")
    return len(sources)


@dataclass(frozen=True)
class Segment:
    """A region of speech as sample positions, end exclusive."""

    start: int
    end: int


@dataclass(frozen=True)
class Utterance:
    """One test item: a corpus file, or a segment of it at the corpus's native rate."""

    corpus: str
    speaker: str
    file: str
    start: int | None
    end: int | None


def segment_speech(samples: FloatArray, sample_rate: int) -> tuple[Segment, ...]:
    """Cut a recording at its pauses into 3 to 10 second segments of speech.

    A pause is a run of 20 ms frames at least 300 ms long whose RMS stays below -40 dB
    relative to the loudest frame. Neighbouring speech chunks merge until the segment reaches
    3 s; a segment that cannot land between 3 and 10 s is dropped rather than cut inside speech.
    """
    frame_length = sample_rate * FRAME_MILLISECONDS // 1000
    frame_count = len(samples) // frame_length
    if frame_count == 0:
        return ()
    frames = samples[: frame_count * frame_length].reshape(frame_count, frame_length)
    rms = np.sqrt(np.mean(np.square(frames), axis=1))
    loud = np.flatnonzero(rms >= rms.max() * 10 ** (PAUSE_THRESHOLD_DB / 20))
    if len(loud) == 0:
        return ()
    pause_frames = PAUSE_MILLISECONDS // FRAME_MILLISECONDS
    splits = np.flatnonzero(np.diff(loud) - 1 >= pause_frames) + 1
    chunks = [
        (int(run[0]) * frame_length, (int(run[-1]) + 1) * frame_length)
        for run in np.split(loud, splits)
    ]

    minimum = round(MIN_SEGMENT_SECONDS * sample_rate)
    maximum = round(MAX_SEGMENT_SECONDS * sample_rate)
    segments: list[Segment] = []
    index = 0
    while index < len(chunks):
        start, end = chunks[index]
        index += 1
        while end - start < minimum and index < len(chunks) and chunks[index][1] - start <= maximum:
            end = chunks[index][1]
            index += 1
        if minimum <= end - start <= maximum:
            segments.append(Segment(start, end))
    return tuple(segments)


def format_utterances(utterances: Sequence[Utterance]) -> str:
    """Serialise a list as the tab-separated file committed under fixtures/eval."""
    lines = [LIST_HEADER]
    for item in utterances:
        start = "-" if item.start is None else str(item.start)
        end = "-" if item.end is None else str(item.end)
        lines.append(f"{item.corpus}\t{item.speaker}\t{item.file}\t{start}\t{end}")
    return "\n".join(lines) + "\n"


def _position(field: str, line_number: int) -> int | None:
    if field == "-":
        return None
    if not field.isdecimal():
        message = f"utterances: line {line_number}: {field!r} is not a sample position."
        raise ValueError(message)
    return int(field)


def parse_utterances(text: str) -> tuple[Utterance, ...]:
    """Read a list written by `format_utterances`, rejecting any malformed line."""
    utterances: list[Utterance] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 5 or fields[0] not in {"daps", "vctk"}:  # noqa: PLR2004
            message = f"utterances: line {line_number} must be corpus, speaker, file, start, end."
            raise ValueError(message)
        start = _position(fields[3], line_number)
        end = _position(fields[4], line_number)
        if (start is None) != (end is None) or (
            start is not None and end is not None and end <= start
        ):
            message = f"utterances: line {line_number} needs a start before its end, or both -."
            raise ValueError(message)
        utterances.append(Utterance(fields[0], fields[1], fields[2], start, end))
    return tuple(utterances)


def draw_utterances(
    candidates: Sequence[Utterance], per_speaker: int, rng: np.random.Generator
) -> list[Utterance]:
    """Draw the same number of items from every speaker, without replacement."""
    by_speaker: dict[str, list[Utterance]] = {}
    for item in sorted(candidates, key=lambda item: (item.speaker, item.file, item.start or 0)):
        by_speaker.setdefault(item.speaker, []).append(item)
    drawn: list[Utterance] = []
    for speaker in sorted(by_speaker):
        pool = by_speaker[speaker]
        if len(pool) < per_speaker:
            message = f"utterances: {speaker} has {len(pool)} candidates, needs {per_speaker}."
            raise ValueError(message)
        chosen = sorted(rng.choice(len(pool), size=per_speaker, replace=False))
        drawn.extend(pool[int(index)] for index in chosen)
    return drawn


def daps_candidates(root: Path) -> list[Utterance]:
    """Segment every clean DAPS recording under an extracted archive."""
    candidates: list[Utterance] = []
    for path in sorted((root / "clean").glob("*.wav")):
        if path.name.startswith("."):
            continue
        samples, sample_rate = read_mono(path)
        speaker = path.name.split("_")[0]
        candidates.extend(
            Utterance("daps", speaker, f"clean/{path.name}", segment.start, segment.end)
            for segment in segment_speech(samples, sample_rate)
        )
    return candidates


def vctk_candidates(root: Path) -> list[Utterance]:
    """List the standard test speakers' microphone-1 recordings that have a transcript."""
    candidates: list[Utterance] = []
    for speaker in VCTK_TEST_SPEAKERS:
        folder = root / VCTK_AUDIO_DIRECTORY / speaker
        candidates.extend(
            Utterance("vctk", speaker, f"{VCTK_AUDIO_DIRECTORY}/{speaker}/{path.name}", None, None)
            for path in sorted(folder.glob("*_mic1.flac"))
            if vctk_transcript_path(root, speaker, path.name).is_file()
        )
    return candidates


def vctk_transcript_path(root: Path, speaker: str, audio_name: str) -> Path:
    """Locate the transcript of a VCTK recording such as p360_001_mic1.flac."""
    stem = audio_name.removesuffix("_mic1.flac")
    return root / VCTK_TEXT_DIRECTORY / speaker / f"{stem}.txt"


def draw_e1_lists(daps_root: Path, vctk_root: Path) -> list[Utterance]:
    """Draw the primary and comparability lists with the fixed seed, DAPS first."""
    rng = np.random.default_rng(DRAW_SEED)
    daps = draw_utterances(daps_candidates(daps_root), DAPS_UTTERANCES_PER_SPEAKER, rng)
    if len({item.speaker for item in daps}) != DAPS_SPEAKER_COUNT:
        message = f"utterances: expected {DAPS_SPEAKER_COUNT} DAPS speakers under {daps_root}."
        raise ValueError(message)
    vctk = draw_utterances(vctk_candidates(vctk_root), VCTK_UTTERANCES_PER_SPEAKER, rng)
    if len({item.speaker for item in vctk}) != len(VCTK_TEST_SPEAKERS):
        message = f"utterances: expected the {len(VCTK_TEST_SPEAKERS)} VCTK test speakers."
        raise ValueError(message)
    return daps + vctk


def read_utterance(root: Path, utterance: Utterance) -> tuple[FloatArray, int]:
    """Read an utterance's samples at the corpus's native rate."""
    start = utterance.start or 0
    stop = utterance.end
    samples, sample_rate = soundfile.read(
        str(root / utterance.file), start=start, stop=stop, dtype="float64", always_2d=True
    )
    mono = np.asarray(samples.mean(axis=1), dtype=np.float64)
    return mono, int(sample_rate)


def main() -> None:
    """Verify pinned evaluation artifacts from any working directory, without uploads."""
    parser = argparse.ArgumentParser(description="Verify the pinned evaluation source cache.")
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--print-root", action="store_true")
    action.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    root = repo_root(Path(__file__))
    if args.print_root:
        sys.stdout.write(f"{root}\n")
        return
    try:
        count = verify_sources(root)
    except (OSError, TypeError, ValueError) as error:
        parser.exit(1, f"{error}\n")
    sys.stdout.write(f"Verified {count} pinned evaluation sources.\n")


if __name__ == "__main__":
    main()
