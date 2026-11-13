import hashlib
import json
from pathlib import Path

import numpy as np
import pytest
import soundfile

from untunnel_tools.eval.sources import (
    REQUIRED_SOURCES,
    Segment,
    Source,
    Utterance,
    daps_candidates,
    draw_utterances,
    format_utterances,
    load_sources,
    parse_utterances,
    read_utterance,
    segment_speech,
    vctk_candidates,
    verify_file,
    verify_sources,
)
from untunnel_tools.measure import FloatArray

SPEECH_RATE = 16_000


@pytest.fixture
def source() -> Source:
    """Exercise integrity checks with a small artifact without network access."""
    return Source(
        identifier="example",
        filename="example.bin",
        url="https://example.org/releases/v1/example.bin",
        version="v1.0",
        sha256=hashlib.sha256(b"audio").hexdigest(),
        size_bytes=5,
        license="MIT",
        license_url="https://example.org/releases/v1/LICENSE",
    )


def test_verified_bytes_are_accepted(tmp_path: Path, source: Source) -> None:
    """Verification checks both the recorded size and digest."""
    artifact = tmp_path / source.filename
    artifact.write_bytes(b"audio")
    verify_file(source, artifact)


@pytest.mark.parametrize("content", [b"audip", b"audi", b"audio!"])
def test_changed_or_truncated_artifact_fails(
    tmp_path: Path, source: Source, content: bytes
) -> None:
    """A corrupt artifact names the source and leaves the bytes for inspection."""
    artifact = tmp_path / source.filename
    artifact.write_bytes(content)
    with pytest.raises(ValueError, match=r"example.*(SHA-256|size)"):
        verify_file(source, artifact)
    assert artifact.read_bytes() == content


def test_missing_artifact_names_fetch_url(tmp_path: Path, source: Source) -> None:
    """An empty cache fails with instructions instead of claiming verification."""
    with pytest.raises(FileNotFoundError, match=r"https://example\.org"):
        verify_file(source, tmp_path / source.filename)


def manifest_record() -> dict[str, object]:
    """Use a complete record when testing individual trust boundary failures."""
    return {
        "id": "example",
        "filename": "example.bin",
        "url": "https://example.org/releases/v1/example.bin",
        "version": "v1.0",
        "sha256": "a" * 64,
        "size_bytes": 5,
        "license": "MIT",
        "license_url": "https://example.org/releases/v1/LICENSE",
    }


def write_manifest(tmp_path: Path, records: object) -> Path:
    """Serialize manifests including malformed shapes at the input boundary."""
    path = tmp_path / "sources.json"
    path.write_text(json.dumps({"sources": records}), encoding="utf-8")
    return path


def test_manifest_reads_pins(tmp_path: Path) -> None:
    """Every accepted record exposes its pinned identity and licence."""
    sources = load_sources(write_manifest(tmp_path, [manifest_record()]))
    assert len(sources) == 1
    assert sources[0].version == "v1.0"
    assert sources[0].license == "MIT"


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("sha256", "unknown"),
        ("sha256", "a" * 63),
        ("license", ""),
        ("version", ""),
        ("version", "main"),
        ("version", "latest"),
        ("url", "http://example.org/file"),
        ("license_url", "file:///tmp/license"),
        ("filename", "../escape"),
        ("filename", "/absolute/escape"),
        ("size_bytes", 0),
        ("size_bytes", True),
    ],
)
def test_invalid_pin_fails(tmp_path: Path, field: str, value: object) -> None:
    """Incomplete pins and cache path traversal are rejected before I/O."""
    record = manifest_record()
    record[field] = value
    with pytest.raises(ValueError, match=field):
        load_sources(write_manifest(tmp_path, [record]))


def test_duplicate_identity_fails(tmp_path: Path) -> None:
    """Two records cannot overwrite the same artifact or source identity."""
    record = manifest_record()
    with pytest.raises(ValueError, match="Duplicate"):
        load_sources(write_manifest(tmp_path, [record, record]))


@pytest.mark.parametrize("records", [[], {}, [None], ["example"]])
def test_malformed_manifest_fails(tmp_path: Path, records: object) -> None:
    """Wrong JSON shapes fail with a manifest error."""
    with pytest.raises((ValueError, TypeError), match="sources"):
        load_sources(write_manifest(tmp_path, records))


def test_incomplete_catalog_cannot_pass_verification(tmp_path: Path) -> None:
    """Removing required artifacts from the manifest cannot yield a green check."""
    manifest_dir = tmp_path / "fixtures" / "eval"
    manifest_dir.mkdir(parents=True)
    write_manifest(manifest_dir, [manifest_record()])
    with pytest.raises(ValueError, match=r"missing.*daps"):
        verify_sources(tmp_path)


def test_complete_catalog_checks_every_file(tmp_path: Path) -> None:
    """A corrupt artifact at the end of the catalog still fails verification."""
    manifest_dir = tmp_path / "fixtures" / "eval"
    manifest_dir.mkdir(parents=True)
    cache = tmp_path / ".cache" / "eval"
    cache.mkdir(parents=True)
    records: list[dict[str, object]] = []
    for identifier in sorted(REQUIRED_SOURCES):
        record = manifest_record()
        record.update(
            id=identifier,
            filename=f"{identifier}.bin",
            sha256=hashlib.sha256(b"audio").hexdigest(),
        )
        records.append(record)
        (cache / f"{identifier}.bin").write_bytes(b"audio")
    write_manifest(manifest_dir, records)
    assert verify_sources(tmp_path) == len(REQUIRED_SOURCES)
    (cache / "whisper.bin").write_bytes(b"audip")
    with pytest.raises(ValueError, match="whisper: SHA-256"):
        verify_sources(tmp_path)


def burst(seconds: float) -> FloatArray:
    """Return a loud tone, standing in for speech."""
    time_seconds = np.arange(round(seconds * SPEECH_RATE)) / SPEECH_RATE
    return np.asarray(0.5 * np.sin(2 * np.pi * 220 * time_seconds), dtype=np.float64)


def quiet(seconds: float, rng: np.random.Generator) -> FloatArray:
    """Return noise about 57 dB below the tone, which is well under the -40 dB threshold."""
    return np.asarray(0.0005 * rng.standard_normal(round(seconds * SPEECH_RATE)), dtype=np.float64)


def synthetic_recording() -> FloatArray:
    """Lay out speech and silences whose boundaries are known in seconds.

    Speech 0 to 2, pause to 2.5, speech to 4.5, pause to 5.0, speech to 10.0, pause to 10.4,
    speech to 17.6 holding a 0.2 s gap that is too short to be a pause, pause to 18.1,
    speech to 19.1.
    """
    rng = np.random.default_rng(0)
    return np.concatenate(
        [
            burst(2.0),
            quiet(0.5, rng),
            burst(2.0),
            quiet(0.5, rng),
            burst(5.0),
            quiet(0.4, rng),
            burst(4.0),
            quiet(0.2, rng),
            burst(3.0),
            quiet(0.5, rng),
            burst(1.0),
        ]
    )


def test_segments_merge_up_to_three_seconds_and_drop_the_rest() -> None:
    """Short neighbours merge, long chunks stand alone and a lone short tail is dropped."""
    segments = segment_speech(synthetic_recording(), SPEECH_RATE)
    expected = [(0.0, 4.5), (5.0, 10.0), (10.4, 17.6)]
    assert segments == tuple(
        Segment(round(start * SPEECH_RATE), round(end * SPEECH_RATE)) for start, end in expected
    )


def test_short_gap_does_not_split_speech() -> None:
    """A 0.2 s gap inside the last long segment stays inside it."""
    segments = segment_speech(synthetic_recording(), SPEECH_RATE)
    assert segments[-1].end - segments[-1].start == round(7.2 * SPEECH_RATE)


def test_every_segment_is_between_three_and_ten_seconds() -> None:
    """The length bounds hold for every segment kept."""
    for segment in segment_speech(synthetic_recording(), SPEECH_RATE):
        assert 3 * SPEECH_RATE <= segment.end - segment.start <= 10 * SPEECH_RATE


def test_silence_has_no_segments() -> None:
    """A recording with no frame above the others yields nothing, not a crash."""
    assert segment_speech(np.zeros(SPEECH_RATE), SPEECH_RATE) == ()
    assert segment_speech(np.zeros(10), SPEECH_RATE) == ()


def test_chunk_over_ten_seconds_is_dropped() -> None:
    """A single stretch of speech longer than ten seconds cannot be cut without a pause."""
    rng = np.random.default_rng(0)
    samples = np.concatenate([burst(11.0), quiet(0.5, rng), burst(4.0)])
    assert segment_speech(samples, SPEECH_RATE) == (
        Segment(round(11.5 * SPEECH_RATE), round(15.5 * SPEECH_RATE)),
    )


def sample_utterances() -> list[Utterance]:
    """Return one segmented and one whole-file utterance."""
    return [
        Utterance("daps", "f1", "clean/f1_script1_clean.wav", 100, 5_000),
        Utterance("vctk", "p360", "wav48_silence_trimmed/p360/p360_001_mic1.flac", None, None),
    ]


def test_utterance_list_round_trips() -> None:
    """Writing and reading a list gives the same items."""
    text = format_utterances(sample_utterances())
    assert text.splitlines()[1] == "daps\tf1\tclean/f1_script1_clean.wav\t100\t5000"
    assert text.splitlines()[2].endswith("p360_001_mic1.flac\t-\t-")
    assert parse_utterances(text) == tuple(sample_utterances())


@pytest.mark.parametrize(
    "line",
    [
        "daps\tf1\tfile.wav\t1",
        "other\tf1\tfile.wav\t1\t2",
        "daps\tf1\tfile.wav\tx\t2",
        "daps\tf1\tfile.wav\t5\t5",
        "daps\tf1\tfile.wav\t5\t-",
    ],
)
def test_malformed_utterance_line_fails(line: str) -> None:
    """Each bad line is rejected with its line number."""
    with pytest.raises(ValueError, match="line 1"):
        parse_utterances(line + "\n")


def candidates() -> list[Utterance]:
    """Return five candidates for each of two speakers."""
    return [
        Utterance("vctk", speaker, f"{speaker}_{index}.flac", None, None)
        for speaker in ("p1", "p2")
        for index in range(5)
    ]


def test_draw_takes_the_same_count_from_every_speaker() -> None:
    """Two per speaker, distinct, and the same for the same seed."""
    drawn = draw_utterances(candidates(), 2, np.random.default_rng(0))
    assert len(drawn) == len(set(drawn)) == 4
    assert [item.speaker for item in drawn].count("p1") == 2
    assert drawn == draw_utterances(candidates(), 2, np.random.default_rng(0))
    assert drawn != draw_utterances(candidates(), 2, np.random.default_rng(1))


def test_draw_from_a_small_pool_fails() -> None:
    """Asking for more than a speaker has is an error, not a short list."""
    with pytest.raises(ValueError, match="p1 has 5 candidates, needs 6"):
        draw_utterances(candidates(), 6, np.random.default_rng(0))


def test_daps_candidates_skip_hidden_metadata_files(tmp_path: Path) -> None:
    """Hidden archive members that end in .wav are not read as recordings."""
    clean = tmp_path / "clean"
    clean.mkdir()
    soundfile.write(str(clean / "f1_script1_clean.wav"), synthetic_recording(), SPEECH_RATE)
    (clean / "._f1_script1_clean.wav").write_bytes(b"not audio")
    found = daps_candidates(tmp_path)
    assert [(item.speaker, item.file) for item in found] == [
        ("f1", "clean/f1_script1_clean.wav")
    ] * 3
    assert [item.start for item in found] == [0, 80_000, 166_400]


def test_vctk_candidates_need_a_transcript_and_a_test_speaker(tmp_path: Path) -> None:
    """Only microphone-1 recordings of the listed speakers with a text file qualify."""
    for speaker in ("p360", "p999"):
        (tmp_path / "wav48_silence_trimmed" / speaker).mkdir(parents=True)
        (tmp_path / "txt" / speaker).mkdir(parents=True)
        for name in ("001", "002"):
            (tmp_path / "wav48_silence_trimmed" / speaker / f"{speaker}_{name}_mic1.flac").touch()
            (tmp_path / "wav48_silence_trimmed" / speaker / f"{speaker}_{name}_mic2.flac").touch()
        (tmp_path / "txt" / speaker / f"{speaker}_001.txt").write_text("Hello.")
    found = vctk_candidates(tmp_path)
    assert [item.file for item in found] == ["wav48_silence_trimmed/p360/p360_001_mic1.flac"]


def test_read_utterance_returns_the_segment(tmp_path: Path) -> None:
    """A segment reads only its own samples; a whole-file item reads everything."""
    ramp = np.arange(1_000, dtype=np.float64) / 1_000
    soundfile.write(str(tmp_path / "ramp.wav"), ramp, SPEECH_RATE, subtype="DOUBLE")
    part, rate = read_utterance(tmp_path, Utterance("daps", "f1", "ramp.wav", 100, 200))
    assert rate == SPEECH_RATE
    assert np.array_equal(part, ramp[100:200])
    whole, _ = read_utterance(tmp_path, Utterance("vctk", "p360", "ramp.wav", None, None))
    assert np.array_equal(whole, ramp)
