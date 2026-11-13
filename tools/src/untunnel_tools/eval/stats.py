"""Paired statistics for the benchmark: clustered bootstrap, Wilcoxon and Holm.

Utterances from one speaker are not independent, so intervals resample speakers first and
utterances within each chosen speaker second, and tests run on per-speaker means.
"""

import importlib
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Protocol, cast

import numpy as np

from untunnel_tools import paths
from untunnel_tools.measure import FloatArray

BOOTSTRAP_RESAMPLES = 10_000
BOOTSTRAP_SEED = 0
CONFIDENCE = 0.95
BOOTSTRAP_BLOCK = 1_000


class _WilcoxonResult(Protocol):
    pvalue: float


class _Stats(Protocol):
    """The scipy.stats call used here, typed because scipy ships partial annotations."""

    def wilcoxon(self, x: FloatArray) -> _WilcoxonResult: ...


@dataclass(frozen=True)
class PairedComparison:
    """Median paired difference with its interval and per-speaker Wilcoxon p-value."""

    median: float
    ci_low: float
    ci_high: float
    p_value: float


def _interval(medians: FloatArray) -> tuple[float, float]:
    tail = 100 * (1 - CONFIDENCE) / 2
    low, high = np.percentile(medians, [tail, 100 - tail])
    return float(low), float(high)


def clustered_bootstrap_ci(
    values: Sequence[float],
    speakers: Sequence[str],
    resamples: int = BOOTSTRAP_RESAMPLES,
    seed: int = BOOTSTRAP_SEED,
) -> tuple[float, float]:
    """Interval for the median from resampling speakers, then utterances within each."""
    groups = [
        np.asarray([value for value, owner in zip(values, speakers, strict=True) if owner == name])
        for name in sorted(set(speakers))
    ]
    counts = np.asarray([len(group) for group in groups])
    padded = np.full((len(groups), int(counts.max())), np.nan)
    for row, group in enumerate(groups):
        padded[row, : len(group)] = group
    rng = np.random.default_rng(seed)
    medians: list[FloatArray] = []
    for block in range(0, resamples, BOOTSTRAP_BLOCK):
        size = min(BOOTSTRAP_BLOCK, resamples - block)
        chosen = rng.integers(0, len(groups), size=(size, len(groups)))
        picks = np.floor(
            rng.random((size, len(groups), padded.shape[1])) * counts[chosen][:, :, np.newaxis]
        ).astype(np.int64)
        drawn = padded[chosen[:, :, np.newaxis], picks]
        drawn[np.arange(padded.shape[1]) >= counts[chosen][:, :, np.newaxis]] = np.nan
        medians.append(np.nanmedian(drawn.reshape(size, -1), axis=1))
    return _interval(np.concatenate(medians))


def naive_bootstrap_ci(
    values: Sequence[float],
    resamples: int = BOOTSTRAP_RESAMPLES,
    seed: int = BOOTSTRAP_SEED,
) -> tuple[float, float]:
    """Interval that treats every utterance as independent; shown only to size the error."""
    data = np.asarray(values, dtype=np.float64)
    rng = np.random.default_rng(seed)
    medians = np.median(data[rng.integers(0, len(data), size=(resamples, len(data)))], axis=1)
    return _interval(medians)


def speaker_means(values: Sequence[float], speakers: Sequence[str]) -> FloatArray:
    """Average each speaker's differences, in sorted speaker order."""
    return np.asarray(
        [
            np.mean([value for value, owner in zip(values, speakers, strict=True) if owner == name])
            for name in sorted(set(speakers))
        ],
        dtype=np.float64,
    )


def wilcoxon_p(differences: FloatArray) -> float:
    """Two-sided signed-rank p-value; no difference at all is p = 1."""
    if not np.any(differences):
        return 1.0
    module = cast("_Stats", importlib.import_module("scipy.stats"))
    return float(module.wilcoxon(differences).pvalue)


def holm_adjust(p_values: Sequence[float]) -> list[float]:
    """Holm step-down adjusted p-values, returned in the input order."""
    order = np.argsort(p_values)
    adjusted = [0.0] * len(p_values)
    running = 0.0
    for rank, index in enumerate(order):
        running = max(running, min(1.0, (len(p_values) - rank) * p_values[int(index)]))
        adjusted[int(index)] = running
    return adjusted


def compare_paired(
    differences: Sequence[float],
    speakers: Sequence[str],
    resamples: int = BOOTSTRAP_RESAMPLES,
    seed: int = BOOTSTRAP_SEED,
) -> PairedComparison:
    """Summarise per-utterance paired differences, grouped by speaker."""
    low, high = clustered_bootstrap_ci(differences, speakers, resamples, seed)
    return PairedComparison(
        median=float(np.median(differences)),
        ci_low=low,
        ci_high=high,
        p_value=wilcoxon_p(speaker_means(differences, speakers)),
    )


# Shared with the other tool modules so `--print-root` works from each of them.
main = paths.main
repo_root = paths.repo_root

if __name__ == "__main__":
    main()
