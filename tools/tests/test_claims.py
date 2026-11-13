from pathlib import Path

import pytest

from untunnel_tools import claims

AUTO_ROUTE_ROW = "| 2026-01-01T00:00:00+00:00 | Auto-route: PASS | PASS | engaged |\n"


def write(root: Path, name: str, text: str) -> None:
    """Create a file in the fixture checkout, with its folders."""
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def messages(root: Path) -> list[str]:
    """Return the findings as text, for substring checks."""
    return [str(finding) for finding in claims.check(root)]


def test_empty_checkout_passes(tmp_path: Path) -> None:
    """A checkout with no copy has nothing to contradict."""
    assert claims.check(tmp_path) == []


def test_number_missing_from_every_results_file_fails(tmp_path: Path) -> None:
    """A figure in the README must be backed by a measurement."""
    write(tmp_path, "README.md", "Adds 12 ms of delay.\n")
    write(tmp_path, "docs/results.md", "Latency was 11 ms.\n")
    write(tmp_path, "docs/bench.md", "Nothing here.\n")
    assert messages(tmp_path) == ["README.md:1: 12 ms does not appear in any results document"]


@pytest.mark.parametrize(
    "document",
    ["results.md", "bench.md", "evaluation.md", "listening-test.md", "alternatives.md"],
)
def test_number_found_in_any_results_file_passes(tmp_path: Path, document: str) -> None:
    """Any of the five documents can back a figure."""
    write(tmp_path, "README.md", "Adds 12 ms of delay.\n")
    write(
        tmp_path,
        f"docs/{document}",
        "Measured 12 milliseconds, https://example.org checked 2026-01-01.\n",
    )
    assert claims.check(tmp_path) == []


@pytest.mark.parametrize(
    ("claim", "evidence"),
    [
        ("Saves 40%.", "40 percent saved"),
        ("About 1,500 Hz.", "1500 Hz"),
        ("A 0.50 s gap.", "0.5 seconds"),
        ("Takes 5-10 minutes.", "5 minutes and 10 min"),
        ("It costs $12.", "$12.00 a month, https://example.org 2026-01-01"),
        ("A 24-hour trial.", "24 hours"),
    ],
)
def test_same_quantity_in_another_form_matches(tmp_path: Path, claim: str, evidence: str) -> None:
    """Spelling, separators and trailing zeros do not make a different figure."""
    write(tmp_path, "README.md", claim + "\n")
    write(tmp_path, "docs/results.md", evidence + "\n")
    assert claims.check(tmp_path) == []


def test_unit_must_match_not_just_the_number(tmp_path: Path) -> None:
    """Twelve seconds is not backed by twelve milliseconds."""
    write(tmp_path, "README.md", "Adds 12 s.\n")
    write(tmp_path, "docs/results.md", "12 ms\n")
    assert len(claims.check(tmp_path)) == 1


def test_urls_and_unitless_numbers_are_ignored(tmp_path: Path) -> None:
    """Versions, ordinals and link targets are not figures."""
    write(tmp_path, "README.md", "macOS 15, Swift 6.2: see https://example.org/v1.2s/9ms.\n")
    assert claims.check(tmp_path) == []


def test_site_pages_are_linted_as_text(tmp_path: Path) -> None:
    """Markup, scripts and styles do not hide or fake a claim."""
    write(
        tmp_path,
        "site/index.html",
        "<style>a{margin:3px; transition:90ms}</style><script>var n = '7 s';</script>"
        "<p>Cuts <b>35</b>%&nbsp;of the hiss.</p><p>Replies in 8 ms.</p>",
    )
    write(tmp_path, "docs/results.md", "8 ms\n")
    found = messages(tmp_path)
    assert len(found) == 1
    assert found[0].startswith("site/index.html: 35 % does not appear")


@pytest.mark.parametrize(
    "phrase",
    ["nothing to configure", "Nothing to set up", "Zero setup", "no setup"],
)
def test_setup_phrases_fail_even_with_the_pass_row(tmp_path: Path, phrase: str) -> None:
    """Setup asks for a password and a microphone permission, whatever the check says."""
    write(tmp_path, "README.md", f"There is {phrase} here.\n")
    write(tmp_path, "docs/results.md", AUTO_ROUTE_ROW)
    found = messages(tmp_path)
    assert len(found) == 1
    assert phrase.lower() in found[0]


def test_setup_phrase_must_be_a_whole_phrase(tmp_path: Path) -> None:
    """A longer word that merely contains the text is not a promise."""
    write(tmp_path, "README.md", "Read the no setups appendix.\n")
    assert claims.check(tmp_path) == []


def test_nothing_to_pick_fails_without_the_pass_row(tmp_path: Path) -> None:
    """The zero-setup promise needs the auto-route check to have passed."""
    write(tmp_path, "README.md", "There is nothing to pick in Zoom.\n")
    assert len(claims.check(tmp_path)) == 1
    write(tmp_path, "docs/results.md", "Auto-route: FAIL\n")
    assert len(claims.check(tmp_path)) == 1


def test_nothing_to_pick_passes_with_the_pass_row(tmp_path: Path) -> None:
    """The recorded pass lets the claim stand."""
    write(tmp_path, "README.md", "There is nothing to pick in Zoom.\n")
    write(tmp_path, "docs/results.md", "Auto-route: PASS\n")
    assert claims.check(tmp_path) == []


def test_put_your_airpods_in_phrase_is_case_insensitive(tmp_path: Path) -> None:
    """Capitalisation does not hide the claim."""
    write(tmp_path, "README.md", "PUT YOUR AIRPODS IN AND JOIN.\n")
    assert len(claims.check(tmp_path)) == 1
    write(tmp_path, "docs/results.md", "Auto-route: PASS\n")
    assert claims.check(tmp_path) == []


@pytest.mark.parametrize("term", ["free", "Free", "for keeps", "no subscription", "at work"])
def test_commercial_terms_fail_without_non_commercial(tmp_path: Path, term: str) -> None:
    """Free use at work is not what the licence allows."""
    write(tmp_path, "README.md", f"Use it {term} today.\n")
    assert len(claims.check(tmp_path)) == 1


def test_commercial_term_passes_with_non_commercial_in_the_paragraph(tmp_path: Path) -> None:
    """The qualifier has to be in the same paragraph, on any line of it."""
    write(tmp_path, "README.md", "It is free for\nnon-commercial use.\n")
    assert claims.check(tmp_path) == []
    write(tmp_path, "README.md", "Non-commercial use only.\n\nIt is free.\n")
    found = claims.check(tmp_path)
    assert [finding.line for finding in found] == [3]


def test_free_inside_another_word_is_fine(tmp_path: Path) -> None:
    """Only the word itself is a promise."""
    write(tmp_path, "README.md", "Freedom to freeze the settings.\n")
    assert claims.check(tmp_path) == []


def test_alternative_figures_need_a_source_and_a_date(tmp_path: Path) -> None:
    """Competitor prices must say where and when they were read."""
    write(tmp_path, "docs/alternatives.md", "Rival costs $9 a month.\n")
    found = messages(tmp_path)
    assert len(found) == 2
    assert any("source URL" in message for message in found)
    assert any("check date" in message for message in found)
    write(
        tmp_path,
        "docs/alternatives.md",
        "Rival costs $9 a month (https://example.org/pricing, checked 2026-01-01).\n",
    )
    assert claims.check(tmp_path) == []


def test_main_exit_status(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """The command fails with the findings on stderr and succeeds when clean."""
    root = tmp_path / "checkout"
    write(root, "Package.swift", "")
    write(root, "tools/src/untunnel_tools/claims.py", "")
    monkeypatch.setattr(claims, "__file__", str(root / "tools/src/untunnel_tools/claims.py"))
    monkeypatch.setattr("sys.argv", ["claims"])
    write(root, "README.md", "It is free.\n")
    with pytest.raises(SystemExit) as failed:
        claims.main()
    assert failed.value.code == 1
    write(root, "README.md", "Hello.\n")
    with pytest.raises(SystemExit) as passed:
        claims.main()
    assert passed.value.code == 0


def test_frequency_units_match_equivalent_evidence(tmp_path: Path) -> None:
    """A rate in Hz is supported by the same rate expressed in kHz."""
    write(tmp_path, "README.md", "The output is 48000 Hz.\n")
    write(tmp_path, "docs/clip.md", "Output: 48 kHz.\n")
    assert claims.check(tmp_path) == []
    write(tmp_path, "README.md", "The output is 49000 Hz.\n")
    assert len(claims.check(tmp_path)) == 1
