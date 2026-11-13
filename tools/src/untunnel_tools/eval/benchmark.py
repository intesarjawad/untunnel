"""Runs the simulated-headset benchmark and writes its results into docs/evaluation.md.

Every system hears the same degraded signal per utterance and condition, and is scored
against the clean reference after alignment. Only the region between the results markers in
the report is rewritten, so the protocol text above it stays as written.
"""

import argparse
import json
import shlex
import sys
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import soundfile

from untunnel_tools.eval.baselines import (
    AUTO_TIER,
    FOLDING_KEY,
    INPUT_KEY,
    System,
    default_systems,
    tier_key,
)
from untunnel_tools.eval.metrics import (
    METRICS,
    WIDEBAND_RATE,
    Backends,
    MetricInfo,
    align,
    load_dnsmos_session,
    load_embedder,
    load_transcriber,
    score_output,
    to_reference_time,
)
from untunnel_tools.eval.simulate_hfp import (
    CONDITIONS,
    REFERENCE_RATE,
    Condition,
    degrade,
    resample,
)
from untunnel_tools.eval.sources import (
    DRAW_SEED,
    Utterance,
    draw_e1_lists,
    format_utterances,
    parse_utterances,
    read_utterance,
    vctk_transcript_path,
)
from untunnel_tools.eval.stats import PairedComparison, compare_paired, holm_adjust
from untunnel_tools.measure import FloatArray
from untunnel_tools.paths import repo_root

RESULTS_START = "<!-- e1-results:start -->"
RESULTS_END = "<!-- e1-results:end -->"
PRIMARY_SET = "primary"
COMPARABILITY_SET = "comparability"
PRIMARY_CONDITION = "msbc"
PRIMARY_METRIC = "lsd_high"
PRIMARY_SYSTEM = tier_key(AUTO_TIER)
SET_LABELS = {
    PRIMARY_SET: "Primary set: DAPS clean speech, not in the listed training data",
    COMPARABILITY_SET: "Comparability set: VCTK test speakers, in RE-USE's training data",
}
CLIP_DAPS_COUNT = 4
CLIP_VCTK_COUNT = 2
CLIP_PEAK_LIMIT = 0.99
CLIP_SOURCES = {
    "daps": (
        "DAPS dataset, Zenodo record 4660670",
        "CC BY-NC 4.0",
        "https://creativecommons.org/licenses/by-nc/4.0/",
        "Mysore, G. J., Device and Produced Speech (DAPS) dataset, 2015, CC BY-NC 4.0.",
    ),
    "vctk": (
        "CSTR VCTK Corpus 0.92, University of Edinburgh",
        "CC BY 4.0",
        "https://creativecommons.org/licenses/by/4.0/",
        (
            "Yamagishi, J., Veaux, C., MacDonald, K., CSTR VCTK Corpus, University of Edinburgh, "
            "2019, CC BY 4.0."
        ),
    ),
}

type Scores = dict[tuple[str, str], dict[str, list[float]]]


@dataclass(frozen=True)
class SetScores:
    """Per-utterance scores of one utterance list, keyed by condition and system."""

    key: str
    speakers: tuple[str, ...]
    scores: Mapping[tuple[str, str], Mapping[str, FloatArray]]


@dataclass(frozen=True)
class Corpora:
    """Where the extracted corpora live and the rate each was recorded at."""

    daps: Path
    vctk: Path
    native_rates: Mapping[str, int]

    def root(self, utterance: Utterance) -> Path:
        """Return the extracted folder holding an utterance's corpus."""
        return self.daps if utterance.corpus == "daps" else self.vctk


@dataclass(frozen=True)
class Secondary:
    """One secondary comparison against spectral folding, awaiting Holm adjustment."""

    set_key: str
    condition: Condition
    metric: MetricInfo
    system: System
    comparison: PairedComparison


def read_native_rates(sources_path: Path) -> dict[str, int]:
    """Read each corpus's native sample rate from the pinned source manifest."""
    manifest = json.loads(sources_path.read_text(encoding="utf-8"))
    return {
        record["id"]: int(record["native_sample_rate_hz"])
        for record in manifest["sources"]
        if record["id"] in {"daps", "vctk"}
    }


def select_subset(utterances: Sequence[Utterance], limit: int | None) -> list[Utterance]:
    """Take `limit` evenly spaced utterances so a smoke run still spans several speakers."""
    if limit is None or limit >= len(utterances):
        return list(utterances)
    return [utterances[index * len(utterances) // limit] for index in range(limit)]


def load_reference(corpora: Corpora, utterance: Utterance) -> FloatArray:
    """Read an utterance and resample it to the 48 kHz reference rate."""
    samples, rate = read_utterance(corpora.root(utterance), utterance)
    expected = corpora.native_rates[utterance.corpus]
    if rate != expected:
        message = (
            f"benchmark: {utterance.file} is {rate} Hz, "
            f"the pinned {utterance.corpus} rate is {expected} Hz."
        )
        raise ValueError(message)
    return resample(samples, rate, REFERENCE_RATE)


def reference_text(
    corpora: Corpora, utterance: Utterance, reference: FloatArray, backends: Backends
) -> str:
    """Give VCTK's own transcript, or Whisper's reading of the clean DAPS segment."""
    if utterance.corpus == "vctk":
        path = vctk_transcript_path(corpora.vctk, utterance.speaker, Path(utterance.file).name)
        return path.read_text(encoding="utf-8").strip()
    return backends.transcribe(resample(reference, REFERENCE_RATE, WIDEBAND_RATE))


def run_set(
    key: str,
    utterances: Sequence[Utterance],
    corpora: Corpora,
    systems: Sequence[System],
    backends: Backends,
) -> SetScores:
    """Score every system under every condition for each utterance of one list."""
    collected: Scores = {}
    for index, utterance in enumerate(utterances):
        sys.stderr.write(f"{key}: utterance {index + 1} of {len(utterances)}\n")
        reference = load_reference(corpora, utterance)
        text = reference_text(corpora, utterance, reference, backends)
        for condition in CONDITIONS:
            rng = np.random.default_rng([DRAW_SEED, index])
            degraded = degrade(reference, condition, rng)
            for system in systems:
                restored = system.process(degraded, condition)
                aligned_reference, aligned = align(reference, restored, REFERENCE_RATE)
                scores = score_output(aligned_reference, aligned, REFERENCE_RATE, text, backends)
                row = collected.setdefault((condition.key, system.key), {})
                for metric, value in scores.items():
                    row.setdefault(metric, []).append(value)
    return SetScores(
        key,
        tuple(item.speaker for item in utterances),
        {
            cell: {metric: np.asarray(values) for metric, values in row.items()}
            for cell, row in collected.items()
        },
    )


def metric_label(info: MetricInfo, set_key: str) -> str:
    """Name a metric row, marking WER against Whisper's transcript as a pseudo-reference."""
    if info.key == "wer" and set_key == PRIMARY_SET:
        return "WER (pseudo-reference)"
    return info.label


def _table(header: Sequence[str], rows: Sequence[Sequence[str]]) -> list[str]:
    lines = ["| " + " | ".join(header) + " |", "|" + "|".join(["---"] * len(header)) + "|"]
    lines.extend("| " + " | ".join(row) + " |" for row in rows)
    return [*lines, ""]


def _yes_no(*, flag: bool) -> str:
    return "yes" if flag else "no"


def _differences(
    result: SetScores, condition: str, system: str, baseline: str, metric: str
) -> list[float]:
    system_scores = result.scores[(condition, system)][metric]
    return list(system_scores - result.scores[(condition, baseline)][metric])


def _interval(comparison: PairedComparison) -> str:
    return f"{comparison.median:+.3f} [{comparison.ci_low:+.3f}, {comparison.ci_high:+.3f}]"


def _secondary(sets: Sequence[SetScores], systems: Sequence[System]) -> list[Secondary]:
    candidates = [system for system in systems if system.key not in {FOLDING_KEY, INPUT_KEY}]
    found: list[Secondary] = []
    for result in sets:
        for condition in CONDITIONS:
            for system in candidates:
                for metric in METRICS:
                    is_primary = (
                        result.key == PRIMARY_SET
                        and condition.key == PRIMARY_CONDITION
                        and system.key == PRIMARY_SYSTEM
                        and metric.key == PRIMARY_METRIC
                    )
                    if is_primary:
                        continue
                    differences = _differences(
                        result, condition.key, system.key, FOLDING_KEY, metric.key
                    )
                    comparison = compare_paired(differences, result.speakers)
                    found.append(Secondary(result.key, condition, metric, system, comparison))
    return found


def _primary_section(result: SetScores) -> list[str]:
    differences = _differences(
        result, PRIMARY_CONDITION, PRIMARY_SYSTEM, FOLDING_KEY, PRIMARY_METRIC
    )
    comparison = compare_paired(differences, result.speakers)
    lines = [
        "### Primary endpoint",
        "",
        (
            "Median paired difference in high-band LSD, auto tier minus spectral folding, mSBC, "
            "primary set."
        ),
        "",
        f"- Median difference (dB) with 95 % CI: {_interval(comparison)}",
        f"- Wilcoxon signed-rank p on per-speaker means: {comparison.p_value:.4f}",
        "",
    ]
    if INPUT_KEY in {key[1] for key in result.scores}:
        against_input = compare_paired(
            _differences(result, PRIMARY_CONDITION, PRIMARY_SYSTEM, INPUT_KEY, PRIMARY_METRIC),
            result.speakers,
        )
        lines += [
            (
                "Against the degraded input, the same difference is "
                f"{_interval(against_input)} dB. This is reported but proves nothing: any added "
                "energy above 8 kHz lowers the distance to a full-band reference."
            ),
            "",
        ]
    return lines


def _secondary_section(found: Sequence[Secondary]) -> list[str]:
    if not found:
        return []
    adjusted = holm_adjust([item.comparison.p_value for item in found])
    rows = [
        [
            item.set_key,
            item.condition.label,
            metric_label(item.metric, item.set_key),
            _yes_no(flag=item.metric.sees_above_8khz),
            item.system.label,
            _interval(item.comparison),
            f"{item.comparison.p_value:.4f}",
            f"{holm:.4f}",
        ]
        for item, holm in zip(found, adjusted, strict=True)
    ]
    header = [
        "Set",
        "Condition",
        "Metric",
        "Sees above 8 kHz",
        "System",
        "Median difference [95 % CI]",
        "p",
        "p (Holm)",
    ]
    return [
        "### Secondary comparisons",
        "",
        (
            "Wilcoxon signed-rank tests on per-speaker mean differences, Holm-corrected across all "
            f"{len(found)} comparisons below."
        ),
        "",
        *_table(header, rows),
    ]


def _median_table(result: SetScores, condition: Condition, systems: Sequence[System]) -> list[str]:
    header = ["Metric", "Sees above 8 kHz", *(system.label for system in systems)]
    rows = [
        [
            metric_label(metric, result.key),
            _yes_no(flag=metric.sees_above_8khz),
            *(
                f"{float(np.median(result.scores[(condition.key, system.key)][metric.key])):.3f}"
                for system in systems
            ),
        ]
        for metric in METRICS
    ]
    return _table(header, rows)


def render_results(sets: Sequence[SetScores], systems: Sequence[System]) -> str:
    """Render the primary endpoint, per-condition medians and the secondary comparisons."""
    lines = [
        (
            "Differences are system minus spectral folding. A negative difference is better for "
            "LSD and WER, a positive one for the other metrics. Intervals are 95 % two-stage "
            "speaker-clustered bootstrap intervals for the median (10,000 resamples, seed 0)."
        ),
        "",
    ]
    primary = next((result for result in sets if result.key == PRIMARY_SET), None)
    if primary is not None and (PRIMARY_CONDITION, PRIMARY_SYSTEM) in primary.scores:
        lines += _primary_section(primary)
    for result in sets:
        lines += [f"### {SET_LABELS[result.key]}", ""]
        for condition in CONDITIONS:
            lines += [f"#### {condition.label}", ""]
            lines += [f"Median over {len(result.speakers)} utterances.", ""]
            lines += _median_table(result, condition, systems)
    if FOLDING_KEY in {system.key for system in systems}:
        lines += _secondary_section(_secondary(sets, systems))
    return "\n".join(lines).rstrip() + "\n"


def write_results(path: Path, body: str) -> None:
    """Replace the results region of a report, appending it when the markers are absent."""
    region = f"{RESULTS_START}\n{body}{RESULTS_END}"
    text = path.read_text(encoding="utf-8") if path.is_file() else ""
    if RESULTS_START in text and RESULTS_END in text:
        before, rest = text.split(RESULTS_START, 1)
        after = rest.split(RESULTS_END, 1)[1]
        text = before + region + after
    else:
        text = text.rstrip() + ("\n\n" if text else "") + region + "\n"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def _rms(samples: FloatArray) -> float:
    return float(np.sqrt(np.mean(np.square(samples))))


def match_loudness(
    clean: FloatArray, degraded: FloatArray, restored: FloatArray
) -> tuple[FloatArray, FloatArray, FloatArray]:
    """Scale the degraded and restored clips to the clean clip's RMS.

    When any peak would then exceed the limit, one common gain lowers all three, so the
    clips stay level with each other.
    """
    target = _rms(clean)
    matched = (clean, degraded * target / _rms(degraded), restored * target / _rms(restored))
    peak = max(float(np.max(np.abs(clip))) for clip in matched)
    scale = min(1.0, CLIP_PEAK_LIMIT / peak)
    return matched[0] * scale, matched[1] * scale, matched[2] * scale


def draw_clip_indices(daps_count: int, vctk_count: int) -> tuple[list[int], list[int]]:
    """Pick the listening-page clips with seed 0: four from the primary list, two from VCTK."""
    rng = np.random.default_rng(DRAW_SEED)
    daps = sorted(int(i) for i in rng.choice(daps_count, size=CLIP_DAPS_COUNT, replace=False))
    vctk = sorted(int(i) for i in rng.choice(vctk_count, size=CLIP_VCTK_COUNT, replace=False))
    return daps, vctk


def clip_name(utterance: Utterance) -> str:
    """Name a clip after its corpus, file and segment start."""
    stem = Path(utterance.file).stem
    suffix = "" if utterance.start is None else f"-{utterance.start}"
    return f"{utterance.corpus}-{stem}{suffix}"


def export_clips(
    folder: Path,
    lists: tuple[Sequence[Utterance], Sequence[Utterance]],
    corpora: Corpora,
    systems: tuple[System, System],
) -> None:
    """Write loudness-matched mSBC input, auto tier and clean clips with their licences."""
    primary, comparability = lists
    degraded_system, restoring_system = systems
    condition = next(item for item in CONDITIONS if item.key == PRIMARY_CONDITION)
    daps_indices, vctk_indices = draw_clip_indices(len(primary), len(comparability))
    chosen = [primary[i] for i in daps_indices] + [comparability[i] for i in vctk_indices]
    folder.mkdir(parents=True, exist_ok=True)
    licences: list[dict[str, str]] = []
    for utterance in chosen:
        reference = load_reference(corpora, utterance)
        degraded = degrade(reference, condition, np.random.default_rng(DRAW_SEED))
        clips = match_loudness(
            reference,
            to_reference_time(
                reference, degraded_system.process(degraded, condition), REFERENCE_RATE
            ),
            to_reference_time(
                reference, restoring_system.process(degraded, condition), REFERENCE_RATE
            ),
        )
        source, licence, licence_url, attribution = CLIP_SOURCES[utterance.corpus]
        for kind, clip in zip(("clean", "input", "untunnel"), clips, strict=True):
            name = f"{clip_name(utterance)}-{kind}.wav"
            soundfile.write(str(folder / name), clip, REFERENCE_RATE, subtype="PCM_16")
            licences.append(
                {
                    "file": name,
                    "kind": kind,
                    "source": f"{source}: {utterance.file}",
                    "licence": licence,
                    "licence_url": licence_url,
                    "attribution": attribution,
                }
            )
    (folder / "licences.json").write_text(json.dumps(licences, indent=2) + "\n", encoding="utf-8")


def _command_overrides(entries: Sequence[str]) -> dict[str, tuple[str, ...]]:
    overrides: dict[str, tuple[str, ...]] = {}
    for entry in entries:
        name, separator, template = entry.partition("=")
        if not separator or not template.strip():
            message = f"benchmark: --system-command wants NAME=COMMAND, got {entry!r}."
            raise ValueError(message)
        overrides[name] = tuple(shlex.split(template))
    return overrides


def build_parser() -> argparse.ArgumentParser:
    """Describe the command line."""
    parser = argparse.ArgumentParser(description="Run the simulated-headset benchmark.")
    parser.add_argument("--print-root", action="store_true", help="print the checkout and exit")
    parser.add_argument("--set", dest="benchmark_set", choices=["e1"])
    parser.add_argument("--out", type=Path, help="report to update, such as docs/evaluation.md")
    parser.add_argument("--limit", type=int, help="score only this many utterances per list")
    parser.add_argument("--systems", help="comma-separated system keys; default is all")
    parser.add_argument("--tier", action="append", default=[], help="extra RATE:EXIT:LOOKAHEAD")
    parser.add_argument("--auto-tier", help="measured auto selection as RATE:EXIT:LOOKAHEAD")
    parser.add_argument("--system-command", action="append", default=[], metavar="NAME=COMMAND")
    parser.add_argument("--export-clips", type=Path, metavar="DIR")
    parser.add_argument("--draw-lists", action="store_true", help="draw and write the e1 lists")
    parser.add_argument("--daps-root", type=Path)
    parser.add_argument("--vctk-root", type=Path)
    parser.add_argument("--whisper-dir", type=Path)
    parser.add_argument("--ecapa-dir", type=Path)
    parser.add_argument("--dnsmos-model", type=Path)
    return parser


def _split_lists(utterances: Sequence[Utterance]) -> tuple[list[Utterance], list[Utterance]]:
    primary = [item for item in utterances if item.corpus == "daps"]
    comparability = [item for item in utterances if item.corpus == "vctk"]
    if not primary or not comparability:
        message = "benchmark: the utterance list needs both daps and vctk lines."
        raise ValueError(message)
    return primary, comparability


def run(args: argparse.Namespace, root: Path) -> None:
    """Draw lists, export clips, or run the benchmark."""
    if args.print_root:
        sys.stdout.write(f"{root}\n")
        return
    cache = root / ".cache" / "eval"
    list_path = root / "fixtures" / "eval" / "e1_utterances.txt"
    corpora = Corpora(
        args.daps_root or cache / "daps",
        args.vctk_root or cache / "vctk",
        read_native_rates(root / "fixtures" / "eval" / "sources.json"),
    )
    if args.draw_lists:
        lists = draw_e1_lists(corpora.daps, corpora.vctk)
        list_path.write_text(format_utterances(lists), encoding="utf-8")
        return
    if args.benchmark_set is None and args.export_clips is None:
        message = "benchmark: choose --set e1, --export-clips or --draw-lists."
        raise ValueError(message)
    if args.benchmark_set is not None and args.out is None:
        message = "benchmark: --set needs --out."
        raise ValueError(message)
    if not list_path.is_file():
        message = f"benchmark: {list_path} is missing; create it with --draw-lists."
        raise FileNotFoundError(message)
    primary, comparability = _split_lists(parse_utterances(list_path.read_text(encoding="utf-8")))
    if args.auto_tier is None:
        message = "benchmark: supply the measured auto tier with --auto-tier RATE:EXIT:LOOKAHEAD."
        raise ValueError(message)
    systems = default_systems(
        tuple(args.tier), _command_overrides(args.system_command), args.auto_tier
    )
    if args.export_clips is not None:
        by_key = {system.key: system for system in systems}
        pair = (by_key[INPUT_KEY], by_key[PRIMARY_SYSTEM])
        export_clips(args.export_clips, (primary, comparability), corpora, pair)
    if args.benchmark_set is None:
        return
    if args.systems:
        wanted = set(args.systems.split(","))
        systems = tuple(system for system in systems if system.key in wanted)
    backends = Backends(
        load_embedder(args.ecapa_dir or cache / "ecapa"),
        load_transcriber(args.whisper_dir or cache / "whisper-large-v3-turbo"),
        load_dnsmos_session(args.dnsmos_model or cache / "sig_bak_ovr.onnx"),
    )
    results = [
        run_set(key, select_subset(items, args.limit), corpora, systems, backends)
        for key, items in ((PRIMARY_SET, primary), (COMPARABILITY_SET, comparability))
    ]
    write_results(args.out, render_results(results, systems))


def main() -> None:
    """Run the benchmark from any working directory."""
    parser = build_parser()
    args = parser.parse_args()
    try:
        run(args, repo_root(Path(__file__)))
    except (OSError, ValueError, RuntimeError, KeyError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
