import numpy as np

from untunnel_tools.eval.stats import (
    clustered_bootstrap_ci,
    compare_paired,
    holm_adjust,
    naive_bootstrap_ci,
    speaker_means,
    wilcoxon_p,
)


def dominated_set() -> tuple[list[float], list[str]]:
    """One speaker with 80 utterances near 1.0 and four with 5 each near 0.0."""
    rng = np.random.default_rng(0)
    values: list[float] = []
    speakers: list[str] = []
    for name, count, centre in [
        ("a", 80, 1.0),
        ("b", 5, 0.0),
        ("c", 5, 0.0),
        ("d", 5, 0.0),
        ("e", 5, 0.0),
    ]:
        values.extend(float(value) for value in centre + 0.1 * rng.standard_normal(count))
        speakers.extend([name] * count)
    return values, speakers


def test_clustered_interval_is_wider_when_one_speaker_dominates() -> None:
    """Resampling speakers can drop the dominant one, which a per-utterance bootstrap misses."""
    values, speakers = dominated_set()
    naive_low, naive_high = naive_bootstrap_ci(values)
    low, high = clustered_bootstrap_ci(values, speakers)
    assert naive_high - naive_low < 0.2
    assert high - low > 0.5
    assert high - low > naive_high - naive_low


def test_identical_values_give_a_degenerate_interval() -> None:
    """With no spread anywhere, every resample has the same median."""
    values = [0.25] * 12
    speakers = ["a"] * 4 + ["b"] * 4 + ["c"] * 4
    assert clustered_bootstrap_ci(values, speakers, resamples=500) == (0.25, 0.25)


def test_interval_is_repeatable_for_a_seed() -> None:
    """The fixed seed makes the report reproducible."""
    values, speakers = dominated_set()
    first = clustered_bootstrap_ci(values, speakers, resamples=500, seed=0)
    assert first == clustered_bootstrap_ci(values, speakers, resamples=500, seed=0)


def test_interval_handles_unequal_speaker_sizes() -> None:
    """Speakers with different counts still resample without padding leaking in."""
    values = [1.0, 1.0, 1.0, 1.0, 1.0, 3.0]
    speakers = ["a"] * 5 + ["b"]
    low, high = clustered_bootstrap_ci(values, speakers, resamples=500)
    assert 1.0 <= low <= high <= 3.0


def test_speaker_means_follow_sorted_speaker_order() -> None:
    """Each speaker contributes one average, whatever order the utterances arrive in."""
    means = speaker_means([1.0, 10.0, 3.0, 20.0], ["a", "b", "a", "b"])
    assert means.tolist() == [2.0, 15.0]


def test_wilcoxon_matches_the_exact_two_sided_value() -> None:
    """Eight positive differences are the most extreme outcome: p = 2 / 2**8."""
    assert abs(wilcoxon_p(np.arange(1.0, 9.0)) - 2 / 2**8) < 1e-12


def test_wilcoxon_of_no_difference_is_one() -> None:
    """All-zero differences carry no evidence against equality."""
    assert wilcoxon_p(np.zeros(5)) == 1.0


def test_holm_adjusts_in_input_order_and_stays_monotone() -> None:
    """Sorted p-values 0.005, 0.01, 0.03, 0.04 scale by 4, 3, 2, 1 and never decrease."""
    adjusted = holm_adjust([0.01, 0.04, 0.03, 0.005])
    assert np.allclose(adjusted, [0.03, 0.06, 0.06, 0.02])


def test_holm_caps_at_one() -> None:
    """A large p-value is never reported above one."""
    assert holm_adjust([0.9, 0.8]) == [1.0, 1.0]


def test_comparison_reports_median_interval_and_p() -> None:
    """Twenty speakers who all improve by about 2 give a significant, tight comparison."""
    differences = [-2.0 - 0.1 * (index % 5) for index in range(40)]
    speakers = [f"s{index // 2}" for index in range(40)]
    result = compare_paired(differences, speakers, resamples=500)
    assert abs(result.median + 2.2) < 1e-9
    assert result.ci_low <= result.median <= result.ci_high
    assert result.p_value < 0.001
