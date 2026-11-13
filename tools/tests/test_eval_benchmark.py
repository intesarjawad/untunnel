import json
from collections.abc import Mapping
from pathlib import Path

import numpy as np
import pytest
import soundfile

from untunnel_tools.eval import benchmark
from untunnel_tools.eval.baselines import System, folding_system, input_system, upsample_input
from untunnel_tools.eval.benchmark import (
    COMPARABILITY_SET,
    PRIMARY_SET,
    RESULTS_END,
    RESULTS_START,
    Corpora,
    SetScores,
    draw_clip_indices,
    export_clips,
    match_loudness,
    render_results,
    run_set,
    select_subset,
    write_results,
)
from untunnel_tools.eval.metrics import (
    METRICS,
    Backends,
    SampleArray,
    log_spectral_distance,
)
from untunnel_tools.eval.simulate_hfp import CONDITIONS, REFERENCE_RATE, Condition
from untunnel_tools.eval.sources import Utterance
from untunnel_tools.measure import FloatArray

NATIVE_RATES = {"daps": REFERENCE_RATE, "vctk": REFERENCE_RATE}


def noise(seconds: float, seed: int, amplitude: float = 0.05) -> FloatArray:
    """Return seeded noise at the reference rate."""
    rng = np.random.default_rng(seed)
    return np.asarray(
        amplitude * rng.standard_normal(round(seconds * REFERENCE_RATE)), dtype=np.float64
    )


def half_level(samples: FloatArray, condition: Condition) -> FloatArray:
    """Stand in for a restorer that returns the upsampled input at half level."""
    return 0.5 * upsample_input(samples, condition)


def auto_system() -> System:
    """Build a fake Untunnel auto-tier system that needs no program."""
    return System("untunnel-auto", "Untunnel, tier auto", half_level)


def test_subset_spans_the_list_evenly() -> None:
    """Ten of two hundred are every twentieth item, so ten speakers appear."""
    items = [Utterance("daps", f"s{index // 10}", f"f{index}.wav", 0, 1) for index in range(200)]
    chosen = select_subset(items, 10)
    assert [item.file for item in chosen] == [f"f{index}.wav" for index in range(0, 200, 20)]
    assert len({item.speaker for item in chosen}) == 10
    assert select_subset(items, None) == items
    assert select_subset(items, 500) == items


def test_loudness_matching_levels_the_three_clips() -> None:
    """The degraded and restored clips take the clean clip's RMS."""
    clean = noise(1.0, 0)
    matched = match_loudness(clean, 0.3 * noise(1.0, 1), 2.0 * noise(1.0, 2))
    target = float(np.sqrt(np.mean(clean**2)))
    for clip in matched:
        assert abs(float(np.sqrt(np.mean(clip**2))) / target - 1) < 1e-9


def test_loudness_matching_lowers_all_clips_together_below_clipping() -> None:
    """A loud restored clip brings every clip down by one common gain."""
    clean = np.array([0.5, -0.5, 0.5, -0.5])
    restored = np.array([4.0, -4.0, 4.0, -4.0])
    matched = match_loudness(clean, clean.copy(), restored)
    assert max(float(np.max(np.abs(clip))) for clip in matched) <= 0.99 + 1e-12
    assert np.allclose(matched[0], matched[1])
    assert np.allclose(matched[0], matched[2])


def test_clip_indices_are_four_and_two_distinct_and_repeatable() -> None:
    """Seed 0 picks four primary and two comparability positions in range."""
    daps, vctk = draw_clip_indices(200, 200)
    assert len(set(daps)) == 4
    assert len(set(vctk)) == 2
    assert all(0 <= index < 200 for index in daps + vctk)
    assert (daps, vctk) == draw_clip_indices(200, 200)


def write_corpora(root: Path) -> tuple[Corpora, list[Utterance], list[Utterance]]:
    """Create small DAPS and VCTK trees of seeded noise and the lists that point into them."""
    (root / "daps" / "clean").mkdir(parents=True)
    (root / "vctk" / "wav48_silence_trimmed" / "p360").mkdir(parents=True)
    (root / "vctk" / "txt" / "p360").mkdir(parents=True)
    soundfile.write(str(root / "daps" / "clean" / "f1_script1_clean.wav"), noise(8.0, 0), 48_000)
    daps = [
        Utterance("daps", "f1", "clean/f1_script1_clean.wav", start * 48_000, (start + 1) * 48_000)
        for start in range(1, 6)
    ]
    vctk: list[Utterance] = []
    for number in range(3):
        stem = f"p360_{number:03d}"
        file = f"wav48_silence_trimmed/p360/{stem}_mic1.flac"
        soundfile.write(str(root / "vctk" / file), noise(1.0, 10 + number), 48_000)
        (root / "vctk" / "txt" / "p360" / f"{stem}.txt").write_text(f"Words {number}.\n")
        vctk.append(Utterance("vctk", "p360", file, None, None))
    return Corpora(root / "daps", root / "vctk", NATIVE_RATES), daps, vctk


def test_clips_are_matched_pairs_with_licences_for_every_file(tmp_path: Path) -> None:
    """Four primary and two comparability utterances give 18 WAVs, each in licences.json."""
    corpora, daps, vctk = write_corpora(tmp_path)
    folder = tmp_path / "clips"
    export_clips(folder, (daps, vctk), corpora, (input_system(), auto_system()))
    wavs = sorted(path.name for path in folder.glob("*.wav"))
    licences = json.loads((folder / "licences.json").read_text(encoding="utf-8"))
    assert len(wavs) == 18
    assert sorted(entry["file"] for entry in licences) == wavs
    by_corpus = {"daps": 0, "vctk": 0}
    for entry in licences:
        corpus = entry["file"].split("-")[0]
        by_corpus[corpus] += 1
        assert entry["licence"] == {"daps": "CC BY-NC 4.0", "vctk": "CC BY 4.0"}[corpus]
        assert entry["source"]
        assert entry["attribution"]
    assert by_corpus == {"daps": 12, "vctk": 6}
    for prefix in {name.rsplit("-", 1)[0] for name in wavs}:
        clips = {
            kind: soundfile.read(str(folder / f"{prefix}-{kind}.wav"))
            for kind in ("clean", "input", "untunnel")
        }
        assert {rate for _, rate in clips.values()} == {REFERENCE_RATE}
        assert len({len(audio) for audio, _ in clips.values()}) == 1
        level = float(np.sqrt(np.mean(clips["clean"][0] ** 2)))
        for audio, _ in clips.values():
            assert abs(float(np.sqrt(np.mean(audio**2))) / level - 1) < 0.02


def fake_backends() -> Backends:
    """Return model stand-ins that give fixed answers."""

    class Session:
        def run(
            self, output_names: None, input_feed: Mapping[str, SampleArray]
        ) -> list[FloatArray]:
            del output_names, input_feed
            return [np.zeros((1, 3))]

    return Backends(lambda samples: samples[:4], lambda _: "transcript", Session())


def fake_score(
    reference: FloatArray, output: FloatArray, sample_rate: int, text: str, backends: Backends
) -> dict[str, float]:
    """Score only LSD for real, so a run does not need the optional metric packages."""
    del text, backends
    scores = {metric.key: 0.0 for metric in METRICS}
    scores["lsd_full"] = log_spectral_distance(reference, output, sample_rate)
    scores["lsd_high"] = log_spectral_distance(reference, output, sample_rate, 8_000)
    return scores


def test_run_scores_every_system_under_every_condition(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A small run fills one score per utterance for each condition, system and metric."""
    monkeypatch.setattr(benchmark, "score_output", fake_score)
    corpora, daps, vctk = write_corpora(tmp_path)
    systems = (input_system(), folding_system())
    primary = run_set(PRIMARY_SET, daps[:4], corpora, systems, fake_backends())
    comparability = run_set(COMPARABILITY_SET, vctk, corpora, systems, fake_backends())
    assert primary.speakers == ("f1",) * 4
    assert set(primary.scores) == {
        (condition.key, system.key) for condition in CONDITIONS for system in systems
    }
    row = primary.scores[("msbc", "folding")]
    assert set(row) == {metric.key for metric in METRICS}
    assert all(len(values) == 4 for values in row.values())
    assert np.all(row["lsd_high"] < primary.scores[("msbc", "input")]["lsd_high"])
    report = render_results([primary, comparability], systems)
    assert "WER (pseudo-reference)" in report.split("### Comparability")[0]
    assert "pseudo-reference" not in report.split("### Comparability")[1]


def test_mismatched_native_rate_is_rejected(tmp_path: Path) -> None:
    """A corpus file at another rate than the pinned one stops the run."""
    corpora, daps, _ = write_corpora(tmp_path)
    wrong = Corpora(corpora.daps, corpora.vctk, {"daps": 44_100, "vctk": 48_000})
    with pytest.raises(ValueError, match="44100"):
        benchmark.load_reference(wrong, daps[0])


def constant_set(key: str, speaker_count: int = 10) -> SetScores:
    """Build scores where auto beats folding by 1 dB at high band and ties elsewhere."""
    speakers = tuple(f"s{index // 2}" for index in range(2 * speaker_count))
    scores: dict[tuple[str, str], Mapping[str, FloatArray]] = {}
    for condition in CONDITIONS:
        for system, high in (("input", 9.0), ("folding", 5.0), ("untunnel-auto", 4.0)):
            row = {metric.key: np.full(len(speakers), 0.5) for metric in METRICS}
            row["lsd_high"] = np.full(len(speakers), high)
            scores[(condition.key, system)] = row
    return SetScores(key, speakers, scores)


def test_report_states_the_primary_endpoint_and_labels_every_table() -> None:
    """The endpoint reads -1 dB with p = 2 / 2**10, and each table carries its labels."""
    systems = (input_system(), folding_system(), auto_system())
    report = render_results([constant_set(PRIMARY_SET), constant_set(COMPARABILITY_SET)], systems)
    assert "Median difference (dB) with 95 % CI: -1.000 [-1.000, -1.000]" in report
    assert "per-speaker means: 0.0020" in report
    assert "the same difference is -5.000 [-5.000, -5.000] dB" in report
    assert "not in the listed training data" in report
    assert "in RE-USE's training data" in report
    tables = [line for line in report.splitlines() if line.startswith("| Metric")]
    assert len(tables) == 8
    assert all("Sees above 8 kHz" in line for line in tables)


def test_only_lsd_rows_see_above_8_khz() -> None:
    """The column reads yes for the two LSD rows and no for every other metric."""
    systems = (input_system(), folding_system(), auto_system())
    report = render_results([constant_set(PRIMARY_SET)], systems)
    metric_rows = [
        line.split(" | ")[:2]
        for line in report.splitlines()
        if line.startswith("| ") and "Sees above" not in line and line.count("|") == 6
    ]
    answers = {row[0][2:]: row[1] for row in metric_rows}
    assert answers["LSD, full band (dB)"] == "yes"
    assert answers["LSD above 8 kHz (dB)"] == "yes"
    assert {value for name, value in answers.items() if "LSD" not in name} == {"no"}


def test_secondary_comparisons_exclude_the_primary_and_count_for_holm() -> None:
    """Two sets, four conditions and nine metrics for one system, less the endpoint."""
    systems = (input_system(), folding_system(), auto_system())
    report = render_results([constant_set(PRIMARY_SET), constant_set(COMPARABILITY_SET)], systems)
    assert "Holm-corrected across all 71 comparisons" in report
    rows = [line for line in report.splitlines() if line.startswith("| primary |")]
    assert len(rows) == 35
    assert not any(
        "mSBC |" in row and "LSD above 8 kHz" in row and "Untunnel" in row for row in rows
    )
    assert any("1.0000 | 1.0000" in row for row in rows)


def test_results_region_is_replaced_and_the_rest_kept(tmp_path: Path) -> None:
    """Rewriting swaps only the text between the markers."""
    path = tmp_path / "evaluation.md"
    path.write_text(
        f"Protocol.\n\n{RESULTS_START}\nold\n{RESULTS_END}\n\nNotes.\n", encoding="utf-8"
    )
    write_results(path, "new\n")
    assert path.read_text(encoding="utf-8") == (
        f"Protocol.\n\n{RESULTS_START}\nnew\n{RESULTS_END}\n\nNotes.\n"
    )


def test_results_region_is_appended_when_markers_are_missing(tmp_path: Path) -> None:
    """A report without markers keeps its text and gains the region at the end."""
    path = tmp_path / "evaluation.md"
    path.write_text("Protocol.\n", encoding="utf-8")
    write_results(path, "new\n")
    assert path.read_text(encoding="utf-8") == f"Protocol.\n\n{RESULTS_START}\nnew\n{RESULTS_END}\n"
