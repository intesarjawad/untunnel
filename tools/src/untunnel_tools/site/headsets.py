"""Validate headset reports from issues and build the community tables of the headset pages.

A report is the one fenced JSON block `untunnel doctor --headset-report` prints. Validation is
written out by hand to match `docs/headset-report.schema.json`, so an issue can be checked with
no package beyond the standard library. Collection reads the issues labelled as valid and writes
one HTML fragment per headset, which a headset page includes, and an index page with every
headset's table; both say the numbers are the reporters' own, not a maintainer measurement.
"""

import argparse
import json
import re
import statistics
import subprocess
import sys
from collections import defaultdict
from dataclasses import dataclass
from html import escape
from pathlib import Path
from typing import cast

from untunnel_tools.paths import repo_root

SCHEMA_VERSION = 1
VALID_LABEL = "headset-report:valid"
EXCLUDED_LABEL = "test"
CAPTION = (
    "Reported by users with <code>untunnel doctor --headset-report</code>; "
    "not re-measured by the maintainer."
)
FRAGMENT_NAME = "community-reports.inc"
INDEX_NAME = "index.html"
GH = "gh"
ISSUE_LIMIT = "1000"

RATE_RANGE = (8_000, 96_000)
ROLLOFF_FLOOR_HZ = 125
LATENCY_CEILING_MS = 1_000
MAX_TEXT = 128

_FENCE = re.compile(r"```json[ \t]*\r?\n(.*?)\r?\n[ \t]*```", re.DOTALL | re.IGNORECASE)
_ID = re.compile(r"0x[0-9A-F]{4}")
_BUILD = re.compile(r"[0-9]{2}[A-Z][0-9]{1,5}[a-z]?")

_TOP_KEYS = frozenset(
    {"schema_version", "headset", "call_mode", "tier", "added_latency_ms", "macos_build"}
    | {"rolloff_40db_hz"}
)


@dataclass(frozen=True)
class Report:
    """One validated report and the issue it came from."""

    number: int
    url: str
    name: str
    vendor_id: str
    product_id: str
    firmware: str | None
    macos_build: str
    raw_rolloff_hz: int
    untunnel_rolloff_hz: int
    added_latency_ms: float
    canonical: str


def _is_integer(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _as_dict(value: object) -> dict[str, object] | None:
    """View a decoded JSON object with text keys, or None for any other value."""
    return cast("dict[str, object]", value) if isinstance(value, dict) else None


def _dig(document: object, *keys: str) -> object:
    """Follow `keys` through nested objects; None where the path breaks."""
    for key in keys:
        found = _as_dict(document)
        document = found.get(key) if found is not None else None
    return document


class _Checker:
    """Collect every problem in one report instead of stopping at the first."""

    def __init__(self) -> None:
        self.errors: list[str] = []

    def mapping(
        self, value: object, path: str, required: frozenset[str], optional: frozenset[str]
    ) -> dict[str, object]:
        """Return the object, or an empty one after recording why it is not usable."""
        found = _as_dict(value)
        if found is None:
            self.errors.append(f"{path} must be an object")
            return {}
        prefix = f"{path}." if path else ""
        self.errors.extend(f"{prefix}{key} is missing" for key in sorted(required - found.keys()))
        self.errors.extend(
            f"{prefix}{key} is not a known field"
            for key in sorted(found.keys() - required - optional)
        )
        return found

    def integer(self, value: object, path: str, low: int, high: int) -> int:
        """Return an integer in `low..high`, or `low` after recording the problem."""
        if value is None:
            return low
        if not isinstance(value, int) or isinstance(value, bool):
            self.errors.append(f"{path} must be a whole number")
            return low
        if not low <= value <= high:
            self.errors.append(f"{path} is {value}, outside {low} to {high}")
            return low
        return value

    def number(self, value: object, path: str, low: float, high: float) -> float:
        """Return a number in `low..high`, or `low` after recording the problem."""
        if value is None:
            return low
        if isinstance(value, bool) or not isinstance(value, int | float):
            self.errors.append(f"{path} must be a number")
            return low
        if not low <= value <= high:
            self.errors.append(f"{path} is {value}, outside {low} to {high}")
            return low
        return float(value)

    def text(self, value: object, path: str, pattern: re.Pattern[str] | None = None) -> str:
        """Return non-empty text, matching `pattern` when given."""
        if value is None:
            return ""
        if not isinstance(value, str) or not value.strip():
            self.errors.append(f"{path} must be non-empty text")
            return ""
        if len(value) > MAX_TEXT:
            self.errors.append(f"{path} is longer than {MAX_TEXT} characters")
        elif pattern is not None and not pattern.fullmatch(value):
            self.errors.append(f"{path} is '{value}', which is not in the expected form")
        return value


def extract_block(body: str) -> str | None:
    """Return the JSON inside the single fenced block of an issue body, or None."""
    blocks = _FENCE.findall(body)
    return blocks[0] if len(blocks) == 1 else None


def check(body: str) -> tuple[dict[str, object] | None, list[str]]:
    """Validate an issue body; return the report object and no errors, or None and the errors."""
    fences = len(_FENCE.findall(body))
    if fences != 1:
        found = "no fenced json block" if fences == 0 else f"{fences} fenced json blocks"
        return None, [f"the issue holds {found}; paste the one block the command printed"]
    try:
        document: object = json.loads(extract_block(body) or "")
    except json.JSONDecodeError as error:
        return None, [f"the block is not valid JSON: {error}"]

    checker = _Checker()
    top = checker.mapping(document, "", _TOP_KEYS, frozenset())
    if top.get("schema_version") != SCHEMA_VERSION or not _is_integer(top.get("schema_version")):
        checker.errors.append(f"schema_version must be {SCHEMA_VERSION}")
    headset = checker.mapping(
        top.get("headset"),
        "headset",
        frozenset({"name", "vendor_id", "product_id"}),
        frozenset({"firmware"}),
    )
    checker.text(headset.get("name"), "headset.name")
    checker.text(headset.get("vendor_id"), "headset.vendor_id", _ID)
    checker.text(headset.get("product_id"), "headset.product_id", _ID)
    if "firmware" in headset:
        checker.text(headset["firmware"], "headset.firmware")

    call_mode = checker.mapping(
        top.get("call_mode"),
        "call_mode",
        frozenset({"input_rate_hz", "output_rate_hz"}),
        frozenset(),
    )
    input_rate = checker.integer(
        call_mode.get("input_rate_hz"), "call_mode.input_rate_hz", *RATE_RANGE
    )
    checker.integer(call_mode.get("output_rate_hz"), "call_mode.output_rate_hz", *RATE_RANGE)

    tier = checker.mapping(
        top.get("tier"),
        "tier",
        frozenset({"sample_rate", "exit_layer", "look_ahead"}),
        frozenset(),
    )
    tier_rate = checker.integer(tier.get("sample_rate"), "tier.sample_rate", *RATE_RANGE)
    checker.integer(tier.get("exit_layer"), "tier.exit_layer", 1, 64)
    checker.integer(tier.get("look_ahead"), "tier.look_ahead", 0, 16)

    checker.number(top.get("added_latency_ms"), "added_latency_ms", 0, LATENCY_CEILING_MS)
    checker.text(top.get("macos_build"), "macos_build", _BUILD)

    rolloff = checker.mapping(
        top.get("rolloff_40db_hz"), "rolloff_40db_hz", frozenset({"raw", "untunnel"}), frozenset()
    )
    raw = checker.integer(
        rolloff.get("raw"), "rolloff_40db_hz.raw", ROLLOFF_FLOOR_HZ, RATE_RANGE[1]
    )
    restored = checker.integer(
        rolloff.get("untunnel"), "rolloff_40db_hz.untunnel", ROLLOFF_FLOOR_HZ, RATE_RANGE[1]
    )
    if not checker.errors:
        if raw > input_rate / 2:
            checker.errors.append(
                f"rolloff_40db_hz.raw is {raw} Hz, "
                f"above half the input rate ({input_rate / 2:g} Hz)"
            )
        limit = max(input_rate, tier_rate) / 2
        if restored > limit:
            checker.errors.append(
                f"rolloff_40db_hz.untunnel is {restored} Hz, above half the highest of the input "
                f"and tier rates ({limit:g} Hz)"
            )
    if checker.errors:
        return None, checker.errors
    return top, []


def _report(number: int, url: str, document: dict[str, object]) -> Report:
    firmware = _dig(document, "headset", "firmware")
    return Report(
        number=number,
        url=url,
        name=str(_dig(document, "headset", "name")),
        vendor_id=str(_dig(document, "headset", "vendor_id")),
        product_id=str(_dig(document, "headset", "product_id")),
        firmware=firmware if isinstance(firmware, str) else None,
        macos_build=str(_dig(document, "macos_build")),
        raw_rolloff_hz=int(str(_dig(document, "rolloff_40db_hz", "raw"))),
        untunnel_rolloff_hz=int(str(_dig(document, "rolloff_40db_hz", "untunnel"))),
        added_latency_ms=float(str(_dig(document, "added_latency_ms"))),
        canonical=json.dumps(document, sort_keys=True),
    )


def _labels(issue: dict[str, object]) -> set[str]:
    labels = issue.get("labels")
    if not isinstance(labels, list):
        return set()
    entries = (_as_dict(label) for label in cast("list[object]", labels))
    return {str(entry["name"]) for entry in entries if entry is not None and "name" in entry}


def collect(issues: list[dict[str, object]]) -> dict[tuple[str, str], list[Report]]:
    """Group the valid reports by vendor and product ID.

    An issue labelled `test`, an invalid body, or a report identical to one from a lower issue
    number is left out, so a pasted copy does not count twice.
    """
    groups: defaultdict[tuple[str, str], list[Report]] = defaultdict(list)
    seen: set[str] = set()
    for issue in sorted(
        issues, key=lambda item: int(str(item["number"])) if _is_integer(item.get("number")) else -1
    ):
        number, body, url = issue.get("number"), issue.get("body"), issue.get("url")
        if (
            not _is_integer(number)
            or not isinstance(body, str)
            or not isinstance(url, str)
            or EXCLUDED_LABEL in _labels(issue)
        ):
            continue
        document, errors = check(body)
        if document is None or errors:
            continue
        report = _report(int(str(number)), url, document)
        if report.canonical in seen:
            continue
        seen.add(report.canonical)
        groups[report.vendor_id, report.product_id].append(report)
    for reports in groups.values():
        reports.sort(key=lambda item: item.number)
    return dict(groups)


def _median(values: list[float], digits: int) -> str:
    return f"{statistics.median(values):,.{digits}f}"


def _table(reports: list[Report], caption: str) -> str:
    """Build the table of one headset's reports with a median row."""
    header = (
        "<tr>"
        '<th scope="col">Report</th>'
        '<th scope="col">Firmware</th>'
        '<th scope="col">macOS build</th>'
        '<th scope="col">Rolloff, raw (Hz)</th>'
        '<th scope="col">Rolloff, Untunnel (Hz)</th>'
        '<th scope="col">Added latency (ms)</th>'
        "</tr>"
    )
    rows = [
        "<tr>"
        f'<th scope="row"><a href="{escape(report.url)}">Issue #{report.number}</a></th>'
        f"<td>{escape(report.firmware or 'not reported')}</td>"
        f"<td>{escape(report.macos_build)}</td>"
        f"<td>{report.raw_rolloff_hz:,}</td>"
        f"<td>{report.untunnel_rolloff_hz:,}</td>"
        f"<td>{report.added_latency_ms:,.1f}</td>"
        "</tr>"
        for report in reports
    ]
    rows.append(
        "<tr>"
        f'<th scope="row">Median of {len(reports)} '
        f"{'report' if len(reports) == 1 else 'reports'} (n = {len(reports)})</th>"
        "<td></td><td></td>"
        f"<td>{_median([float(r.raw_rolloff_hz) for r in reports], 0)}</td>"
        f"<td>{_median([float(r.untunnel_rolloff_hz) for r in reports], 0)}</td>"
        f"<td>{_median([r.added_latency_ms for r in reports], 1)}</td>"
        "</tr>"
    )
    return (
        '<div class="table-scroll" role="region" tabindex="0" '
        'aria-label="Scrollable headset reports">\n<table>\n'
        f"<caption>{escape(caption)}</caption>\n"
        f"<thead>{header}</thead>\n"
        f"<tbody>\n{chr(10).join(rows)}\n</tbody>\n"
        "</table>\n</div>\n"
    )


def render(reports: list[Report]) -> str:
    """Build the Community reports section for one headset."""
    return (
        '<section aria-labelledby="community-reports">\n'
        '<h2 id="community-reports">Community reports</h2>\n'
        f"<p>{CAPTION}</p>\n"
        "<p>Scroll the table horizontally to see all columns.</p>\n"
        f"{_table(reports, 'Community reports for this headset')}"
        "</section>\n"
    )


def render_index(groups: dict[tuple[str, str], list[Report]]) -> str:
    """Build the page that lists every headset with its reports, served at `headsets/`."""
    sections: list[str] = []
    for (vendor_id, product_id), reports in sorted(groups.items()):
        anchor = fragment_directory(vendor_id, product_id)
        name = escape(reports[0].name)
        sections.append(
            f'<section aria-labelledby="{anchor}">\n'
            f'<h2 id="{anchor}">{name}</h2>\n'
            f"<p>Vendor ID {escape(vendor_id)}, product ID {escape(product_id)}</p>\n"
            "<p>Scroll the table horizontally to see all columns.</p>\n"
            f"{_table(reports, f'Reports for {reports[0].name}')}"
            "</section>\n"
        )
    listing = "".join(sections) or "<p>No reports yet.</p>\n"
    return (
        "<!doctype html>\n"
        '<html lang="en">\n'
        "<head>\n"
        '<meta charset="utf-8" />\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1" />\n'
        '<meta name="color-scheme" content="light dark" />\n'
        '<meta name="description" content="Call microphone measurements reported by users, '
        'by headset." />\n'
        '<link rel="icon" href="data:," />\n'
        '<link rel="stylesheet" href="../tokens.css" />\n'
        "<title>Headset reports · Untunnel</title>\n"
        "</head>\n"
        "<body>\n"
        '<a class="skip-link" href="#main">Skip to content</a>\n'
        '<nav aria-label="Site"><a href="../">Home</a> · '
        '<a href="https://github.com/intesarjawad/untunnel/issues/new/choose">'
        "Submit a report</a></nav>\n"
        '<main id="main" class="page">\n'
        "<h1>Headset reports</h1>\n"
        f'<p class="lede">{CAPTION}</p>\n'
        "<p>To add yours, run <code>untunnel doctor --headset-report</code> and paste the block "
        "it prints into a new headset report issue.</p>\n"
        f"{listing}"
        "</main>\n"
        "</body>\n"
        "</html>\n"
    )


def fragment_directory(vendor_id: str, product_id: str) -> str:
    """Name the folder of one headset's page, such as `054c-0f8a`."""
    return f"{vendor_id[2:].lower()}-{product_id[2:].lower()}"


def write_fragments(groups: dict[tuple[str, str], list[Report]], out: Path) -> list[Path]:
    """Write one fragment per headset and the index page under `out`; return the files."""
    written: list[Path] = []
    for (vendor_id, product_id), reports in sorted(groups.items()):
        path = out / fragment_directory(vendor_id, product_id) / FRAGMENT_NAME
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(render(reports), encoding="utf-8")
        written.append(path)
    index = out / INDEX_NAME
    index.parent.mkdir(parents=True, exist_ok=True)
    index.write_text(render_index(groups), encoding="utf-8")
    written.append(index)
    return written


def list_valid_issues() -> list[dict[str, object]]:
    """Read every issue carrying the valid label, open or closed, through the GitHub CLI."""
    # The command and every argument are constants; nothing from an issue reaches it.
    completed = subprocess.run(  # noqa: S603
        [
            GH,
            "issue",
            "list",
            "--label",
            VALID_LABEL,
            "--state",
            "all",
            "--limit",
            ISSUE_LIMIT,
            "--json",
            "number,body,url,labels",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return _issue_objects(json.loads(completed.stdout))


def _issue_objects(loaded: object) -> list[dict[str, object]]:
    if not isinstance(loaded, list):
        message = "the issues are not a JSON list"
        raise TypeError(message)
    objects = (_as_dict(item) for item in cast("list[object]", loaded))
    return [item for item in objects if item is not None]


def main(argv: list[str] | None = None) -> None:
    """Validate one issue body, or collect the reports into page fragments."""
    arguments = sys.argv[1:] if argv is None else argv
    if "--print-root" in arguments:
        sys.stdout.write(f"{repo_root(Path(__file__))}\n")
        return
    parser = argparse.ArgumentParser(description="Headset reports from issues.")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--validate", action="store_true", help="check an issue body")
    mode.add_argument("--collect", action="store_true", help="write the community tables")
    parser.add_argument("--body", type=Path, help="issue body file for --validate; default stdin")
    parser.add_argument("--issues", type=Path, help="issues JSON for --collect; default gh")
    parser.add_argument("--out", type=Path, help="directory for --collect")
    args = parser.parse_args(arguments)

    if args.validate:
        body = args.body.read_text(encoding="utf-8") if args.body else sys.stdin.read()
        _, errors = check(body)
        for error in errors:
            sys.stderr.write(f"{error}\n")
        raise SystemExit(1 if errors else 0)

    if args.out is None:
        parser.error("--collect needs --out")
    if args.issues:
        issues = _issue_objects(json.loads(args.issues.read_text(encoding="utf-8")))
    else:
        issues = list_valid_issues()
    for path in write_fragments(collect(issues), args.out):  # pyright: ignore[reportUnknownArgumentType]
        sys.stdout.write(f"{path}\n")


if __name__ == "__main__":
    main()
