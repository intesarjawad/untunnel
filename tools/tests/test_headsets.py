import copy
import json
from pathlib import Path
from typing import cast

import pytest

from untunnel_tools.paths import repo_root
from untunnel_tools.site import headsets

BASE: dict[str, object] = {
    "schema_version": 1,
    "headset": {
        "name": "Example Buds",
        "vendor_id": "0x054C",
        "product_id": "0x0F8A",
        "firmware": "3.1.5",
    },
    "call_mode": {"input_rate_hz": 16000, "output_rate_hz": 16000},
    "tier": {"sample_rate": 24000, "exit_layer": 5, "look_ahead": 1},
    "added_latency_ms": 40.0,
    "macos_build": "26A1234",
    "rolloff_40db_hz": {"raw": 7000, "untunnel": 11000},
}


def report(**changes: object) -> dict[str, object]:
    """Copy the valid report and replace top-level keys; a dotted key reaches into a section."""
    document = copy.deepcopy(BASE)
    for key, value in changes.items():
        section, _, field = key.partition("__")
        if field:
            inner = document[section]
            assert isinstance(inner, dict)
            inner[field] = value
        else:
            document[key] = value
    return document


def body(document: object) -> str:
    """Wrap a document the way the command prints it, inside an issue form's text."""
    return f"### Report\n\n```json\n{json.dumps(document, indent=2)}\n```\n"


def issue(number: int, document: object, *labels: str, url: str | None = None) -> dict[str, object]:
    """Build the object `gh issue list --json` returns for one issue."""
    return {
        "number": number,
        "body": body(document),
        "url": url or f"https://github.com/example/untunnel/issues/{number}",
        "labels": [{"name": name} for name in ("headset-report:valid", *labels)],
    }


def errors_of(text: str) -> list[str]:
    """Return the validation errors of an issue body."""
    return headsets.check(text)[1]


def test_valid_report_passes() -> None:
    """The documented object has no errors, with or without the optional firmware."""
    assert errors_of(body(BASE)) == []
    without_firmware = report()
    headset = without_firmware["headset"]
    assert isinstance(headset, dict)
    del headset["firmware"]
    assert errors_of(body(without_firmware)) == []


def test_bare_json_without_a_fence_is_refused() -> None:
    """The issue form asks for the fenced block the command prints."""
    assert errors_of(json.dumps(BASE)) == [
        "the issue holds no fenced json block; paste the one block the command printed"
    ]


def test_two_blocks_are_refused() -> None:
    """One report per issue."""
    assert errors_of(body(BASE) + body(BASE)) == [
        "the issue holds 2 fenced json blocks; paste the one block the command printed"
    ]


def test_invalid_json_reports_the_parser_message() -> None:
    """The reporter sees where the text broke."""
    (message,) = errors_of('```json\n{"schema_version": 1,}\n```')
    assert message.startswith("the block is not valid JSON: ")


@pytest.mark.parametrize(
    ("document", "expected"),
    [
        ([], "must be an object"),
        ({}, "headset is missing"),
        (report(schema_version=2), "schema_version must be 1"),
        (report(schema_version=True), "schema_version must be 1"),
        (report(extra=1), "extra is not a known field"),
        (report(headset__vendor_id="054C"), "headset.vendor_id is '054C'"),
        (report(headset__product_id="0x0f8a"), "headset.product_id is '0x0f8a'"),
        (report(headset__name=""), "headset.name must be non-empty text"),
        (report(headset__firmware=3), "headset.firmware must be non-empty text"),
        (
            report(call_mode__input_rate_hz="16000"),
            "call_mode.input_rate_hz must be a whole number",
        ),
        (report(call_mode__output_rate_hz=True), "call_mode.output_rate_hz must be a whole number"),
        (report(tier__look_ahead=1.5), "tier.look_ahead must be a whole number"),
        (report(added_latency_ms="40"), "added_latency_ms must be a number"),
        (report(macos_build="Sequoia"), "macos_build is 'Sequoia'"),
        (report(rolloff_40db_hz=7000), "rolloff_40db_hz must be an object"),
    ],
)
def test_malformed_reports_are_refused(document: object, expected: str) -> None:
    """A wrong shape or type names the field."""
    assert any(expected in error for error in errors_of(body(document)))


def test_missing_nested_field_is_named() -> None:
    """Dotted paths say where the gap is."""
    document = report()
    tier = document["tier"]
    assert isinstance(tier, dict)
    del tier["exit_layer"]
    assert errors_of(body(document)) == ["tier.exit_layer is missing"]


@pytest.mark.parametrize(
    ("changes", "expected"),
    [
        ({"call_mode__input_rate_hz": 0}, "call_mode.input_rate_hz is 0, outside 8000 to 96000"),
        ({"tier__sample_rate": 200000}, "tier.sample_rate is 200000, outside 8000 to 96000"),
        ({"tier__exit_layer": 0}, "tier.exit_layer is 0, outside 1 to 64"),
        ({"added_latency_ms": -1}, "added_latency_ms is -1, outside 0 to 1000"),
        ({"added_latency_ms": 5000}, "added_latency_ms is 5000, outside 0 to 1000"),
        ({"rolloff_40db_hz__raw": 50}, "rolloff_40db_hz.raw is 50, outside 125 to 96000"),
    ],
)
def test_out_of_range_values_are_refused_with_the_exact_message(
    changes: dict[str, object], expected: str
) -> None:
    """A number outside its range says which and what the range is."""
    assert errors_of(body(report(**changes))) == [expected]


def test_raw_rolloff_above_half_the_input_rate_is_refused() -> None:
    """Sixteen kilohertz audio cannot carry anything above eight."""
    assert errors_of(body(report(rolloff_40db_hz__raw=8000))) == []
    assert errors_of(body(report(rolloff_40db_hz__raw=9000))) == [
        "rolloff_40db_hz.raw is 9000 Hz, above half the input rate (8000 Hz)"
    ]


def test_restored_rolloff_may_reach_half_the_tier_rate() -> None:
    """The restored side is limited by the larger of the two rates."""
    assert errors_of(body(report(rolloff_40db_hz__untunnel=12000))) == []
    message = (
        "rolloff_40db_hz.untunnel is 12001 Hz, above half the highest of the input and tier "
        "rates (12000 Hz)"
    )
    assert errors_of(body(report(rolloff_40db_hz__untunnel=12001))) == [message]


def test_every_problem_is_listed() -> None:
    """The reporter fixes everything in one edit."""
    document = report(macos_build="x", added_latency_ms=-3)
    assert len(errors_of(body(document))) == 2


def test_duplicate_reports_count_once() -> None:
    """A pasted copy in a later issue is left out; the first issue keeps the entry."""
    groups = headsets.collect([issue(10, BASE), issue(2, BASE)])
    (reports,) = groups.values()
    assert [item.number for item in reports] == [2]


def test_reports_group_by_vendor_and_product_id() -> None:
    """The name does not group, the pair of IDs does."""
    renamed = report(headset__name="Example Buds (renamed)", added_latency_ms=41.0)
    other = report(headset__product_id="0x0001")
    groups = headsets.collect([issue(1, BASE), issue(2, renamed), issue(3, other)])
    assert sorted(groups) == [("0x054C", "0x0001"), ("0x054C", "0x0F8A")]
    assert [item.number for item in groups["0x054C", "0x0F8A"]] == [1, 2]


def test_test_labelled_and_invalid_issues_are_left_out() -> None:
    """The maintainer's test issue and a broken body never reach a page."""
    broken = {**issue(3, BASE), "body": "no block here"}
    groups = headsets.collect(
        [issue(1, BASE, "test"), issue(2, report(tier__look_ahead=99)), broken]
    )
    assert groups == {}


def test_table_shows_each_issue_the_median_and_n() -> None:
    """Three reports: medians are the middle values, and every issue is linked."""
    reports = [
        issue(3, report(rolloff_40db_hz__raw=7000, rolloff_40db_hz__untunnel=11000)),
        issue(
            5,
            report(
                rolloff_40db_hz__raw=7500,
                rolloff_40db_hz__untunnel=11500,
                added_latency_ms=42.5,
                macos_build="26B7",
            ),
        ),
        issue(
            8,
            report(
                rolloff_40db_hz__raw=6500,
                rolloff_40db_hz__untunnel=12000,
                added_latency_ms=38.0,
                headset__firmware="3.2.0",
            ),
        ),
    ]
    ((_, grouped),) = headsets.collect(reports).items()

    page = headsets.render(grouped)

    assert "Community reports" in page
    assert "untunnel doctor --headset-report</code>; not re-measured by the maintainer." in page
    for number in (3, 5, 8):
        assert f'href="https://github.com/example/untunnel/issues/{number}"' in page
    assert "Median of 3 reports (n = 3)" in page
    assert "<td>7,000</td><td>11,500</td><td>40.0</td>" in page.split("Median of")[1]


def test_median_of_two_reports_is_their_mean() -> None:
    """An even count averages the middle pair."""
    first = report(rolloff_40db_hz__raw=6000, added_latency_ms=40.0)
    second = report(rolloff_40db_hz__raw=7000, added_latency_ms=45.0)
    ((_, grouped),) = headsets.collect([issue(1, first), issue(2, second)]).items()
    median = headsets.render(grouped).split("Median of")[1]
    assert "Median of 2 reports" in "Median of" + median
    assert "<td>6,500</td>" in median
    assert "<td>42.5</td>" in median


def test_single_report_uses_the_singular() -> None:
    """One report reads as one."""
    ((_, grouped),) = headsets.collect([issue(1, BASE)]).items()
    assert "Median of 1 report (n = 1)" in headsets.render(grouped)


def test_link_and_text_are_escaped() -> None:
    """Nothing an issue holds becomes markup."""
    risky = report(headset__firmware="<b>1</b>")
    ((_, grouped),) = headsets.collect(
        [issue(1, risky, url='https://github.com/example/untunnel/issues/1"onmouseover="x')]
    ).items()
    page = headsets.render(grouped)
    assert "<b>1</b>" not in page
    assert "&lt;b&gt;1&lt;/b&gt;" in page
    assert 'issues/1"onmouseover' not in page


def test_fragments_are_written_per_headset(tmp_path: Path) -> None:
    """One include file per vendor and product, named from the IDs, then the index page."""
    groups = headsets.collect([issue(1, BASE), issue(2, report(headset__product_id="0x0001"))])
    written = headsets.write_fragments(groups, tmp_path)
    assert [path.relative_to(tmp_path).as_posix() for path in written] == [
        "054c-0001/community-reports.inc",
        "054c-0f8a/community-reports.inc",
        "index.html",
    ]
    assert "issues/1" in written[1].read_text(encoding="utf-8")


def test_index_lists_every_headset_with_its_issue_links() -> None:
    """The page served at headsets/ links each report, so a reporter finds their issue there."""
    groups = headsets.collect(
        [issue(1, BASE), issue(2, report(headset__product_id="0x0001", headset__name="Other"))]
    )
    page = headsets.render_index(groups)
    assert page.startswith("<!doctype html>")
    assert '<h2 id="054c-0001">Other</h2>' in page
    assert '<h2 id="054c-0f8a">Example Buds</h2>' in page
    assert page.index("054c-0001") < page.index("054c-0f8a")
    for number in (1, 2):
        assert f'href="https://github.com/example/untunnel/issues/{number}"' in page
    assert "not re-measured by the maintainer." in page
    assert "No reports yet" not in page


def test_index_without_reports_says_so() -> None:
    """The weekly build publishes a page even before the first report."""
    page = headsets.render_index({})
    assert "<p>No reports yet.</p>" in page
    assert "<table>" not in page


def test_index_escapes_the_headset_name() -> None:
    """A name from an issue never becomes markup in the heading or the caption."""
    groups = headsets.collect([issue(1, report(headset__name="<i>Buds</i>"))])
    page = headsets.render_index(groups)
    assert "<i>Buds</i>" not in page
    assert "&lt;i&gt;Buds&lt;/i&gt;" in page


def test_validate_exit_status_and_message(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """The workflow comments with exactly what stderr holds."""
    good = tmp_path / "good.md"
    good.write_text(body(BASE), encoding="utf-8")
    bad = tmp_path / "bad.md"
    bad.write_text(body(report(rolloff_40db_hz__raw=9000)), encoding="utf-8")

    with pytest.raises(SystemExit) as passed:
        headsets.main(["--validate", "--body", str(good)])
    assert passed.value.code == 0
    with pytest.raises(SystemExit) as failed:
        headsets.main(["--validate", "--body", str(bad)])
    assert failed.value.code == 1
    assert capsys.readouterr().err == (
        "rolloff_40db_hz.raw is 9000 Hz, above half the input rate (8000 Hz)\n"
    )


def test_collect_reads_an_issues_file(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    """The same code path as gh, fed from a file."""
    issues = tmp_path / "issues.json"
    issues.write_text(json.dumps([issue(1, BASE), issue(2, BASE, "test")]), encoding="utf-8")
    out = tmp_path / "out"

    headsets.main(["--collect", "--issues", str(issues), "--out", str(out)])

    fragment = out / "054c-0f8a" / "community-reports.inc"
    assert capsys.readouterr().out == f"{fragment}\n{out / 'index.html'}\n"
    assert "issues/1" in fragment.read_text(encoding="utf-8")


def test_collect_needs_an_output_directory(capsys: pytest.CaptureFixture[str]) -> None:
    """A missing --out is a usage error, not a traceback."""
    with pytest.raises(SystemExit) as failed:
        headsets.main(["--collect"])
    assert failed.value.code == 2
    assert "--collect needs --out" in capsys.readouterr().err


def test_schema_file_names_the_same_fields_as_the_validator() -> None:
    """The documented schema and the hand-written checks cannot drift apart unnoticed."""
    schema = json.loads(
        (repo_root(Path(__file__)) / "docs" / "headset-report.schema.json").read_text("utf-8")
    )
    assert set(schema["required"]) == set(BASE)
    assert set(schema["properties"]) == set(BASE)
    for section in ("headset", "call_mode", "tier", "rolloff_40db_hz"):
        value = cast("dict[str, object]", BASE[section])
        assert set(schema["properties"][section]["properties"]) == set(value)
        assert schema["properties"][section]["additionalProperties"] is False
