"""Lint the public copy against the measurements and policies the project can back up.

README.md and the site may only quote a number with a unit (or a percent)
that also appears in a results document, and a few phrases promise more than the app delivers.
Missing results files count as empty, so a claim made before any measurement fails instead of
passing by default. Everything is plain text; nothing here needs a browser or a network.
"""

import html
import re
import sys
from dataclasses import dataclass
from decimal import Decimal
from pathlib import Path

from untunnel_tools.paths import repo_root

CLAIM_FILES = (Path("README.md"),)
SITE_DIRECTORY = Path("site")
SITE_SUFFIXES = frozenset({".html", ".htm", ".md", ".txt"})
RESULTS = Path("docs") / "results.md"
ALTERNATIVES = Path("docs") / "alternatives.md"
EVIDENCE_FILES = (
    RESULTS,
    Path("docs") / "bench.md",
    Path("docs") / "evaluation.md",
    Path("docs") / "listening-test.md",
    ALTERNATIVES,
    Path("docs") / "clip.md",
)

AUTO_ROUTE_MARKER = "Auto-route: PASS"

NEVER_PHRASES = ("nothing to configure", "nothing to set up", "zero setup", "no setup")
AUTO_ROUTE_PHRASES = ("nothing to pick", "put your airpods in and join")
COMMERCIAL_TERMS = ("free", "for keeps", "no subscription", "at work")
NON_COMMERCIAL = "non-commercial"

_NUMBER = r"\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?"
_UNIT = (
    r"%|percent|(?:milli)?seconds?|ms|secs?|s|minutes?|mins?|hours?|hrs?|h|days?"
    r"|[kMG]Hz|Hz|dBFS|dB|[KMG]i?B|[x\u00d7]"
)
_UNIT_QUANTITY = re.compile(
    rf"(?<![\w.])(?:(?P<low>{_NUMBER})\s*(?:[\u2013-]|to)\s*)?(?P<high>{_NUMBER})"
    rf"[ \u00a0-]?(?P<unit>{_UNIT})(?![A-Za-z0-9])",
    re.IGNORECASE,
)
_CURRENCY_QUANTITY = re.compile(rf"(?P<unit>[$\u20ac\u00a3])\s?(?P<high>{_NUMBER})")
_UNIT_ALIASES = {
    "percent": "%",
    "second": "s",
    "seconds": "s",
    "sec": "s",
    "secs": "s",
    "millisecond": "ms",
    "milliseconds": "ms",
    "minute": "min",
    "minutes": "min",
    "mins": "min",
    "hour": "h",
    "hours": "h",
    "hr": "h",
    "hrs": "h",
    "day": "d",
    "days": "d",
    "\u00d7": "x",
}
_URL = re.compile(r"https?://[^\s<>]*[^\s<>.,;:!?)\]]")
_ISO_DATE = re.compile(r"\b\d{4}-\d{2}-\d{2}\b")
_SCRIPT_OR_STYLE = re.compile(r"<(script|style)\b.*?</\1\s*>|<!--.*?-->", re.DOTALL | re.IGNORECASE)
_BLOCK_TAG = re.compile(
    r"</?(?:p|div|section|article|header|footer|main|nav|ul|ol|li|tr|table|h[1-6]|br|blockquote"
    r"|figure|figcaption|dd|dt|dl|details|summary)\b[^>]*>",
    re.IGNORECASE,
)
_TAG = re.compile(r"<[^>]*>")

type Quantity = tuple[str, str]


@dataclass(frozen=True)
class Finding:
    """One broken rule, located in a file."""

    path: Path
    line: int | None
    message: str

    def __str__(self) -> str:
        """Format as `path:line: message`, leaving out the line when the text was reflowed."""
        place = str(self.path) if self.line is None else f"{self.path}:{self.line}"
        return f"{place}: {self.message}"


@dataclass(frozen=True)
class Paragraph:
    """A run of non-blank lines and the line it starts on."""

    line: int
    text: str


def paragraphs(text: str) -> list[Paragraph]:
    """Split text on blank lines."""
    result: list[Paragraph] = []
    current: list[str] = []
    start = 1
    for number, line in enumerate(text.splitlines(), start=1):
        if line.strip():
            if not current:
                start = number
            current.append(line)
        elif current:
            result.append(Paragraph(start, "\n".join(current)))
            current = []
    if current:
        result.append(Paragraph(start, "\n".join(current)))
    return result


def html_to_text(source: str) -> str:
    """Reduce a page to its visible text with a blank line wherever a block ends."""
    visible = _SCRIPT_OR_STYLE.sub(" ", source)
    visible = _BLOCK_TAG.sub("\n\n", visible)
    return html.unescape(_TAG.sub("", visible))


def _normal_quantity(number: str, unit: str) -> Quantity:
    value = format(Decimal(number.replace(",", "")).normalize(), "f")
    lowered = unit.lower()
    if lowered in {"khz", "mhz", "ghz"}:
        factor = {"khz": 1000, "mhz": 1_000_000, "ghz": 1_000_000_000}[lowered]
        return format(Decimal(value) * factor, "f"), "hz"
    return value, _UNIT_ALIASES.get(lowered, lowered)


def quantities(text: str) -> list[tuple[int, Quantity]]:
    """Find every number with a unit or percent, with the line it is on."""
    bare = _URL.sub(" ", text)
    found: list[tuple[int, Quantity]] = []
    for pattern in (_UNIT_QUANTITY, _CURRENCY_QUANTITY):
        for match in pattern.finditer(bare):
            line = bare.count("\n", 0, match.start()) + 1
            unit = match.group("unit")
            numbers = [match.group("high")]
            if pattern is _UNIT_QUANTITY and match.group("low"):
                numbers.append(match.group("low"))
            found.extend((line, _normal_quantity(number, unit)) for number in numbers)
    return found


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.is_file() else ""


def claim_files(root: Path) -> list[Path]:
    """List the copy to lint, relative to the checkout, in a stable order."""
    paths = [path for path in CLAIM_FILES if (root / path).is_file()]
    site = root / SITE_DIRECTORY
    if site.is_dir():
        paths.extend(
            sorted(
                path.relative_to(root)
                for path in site.rglob("*")
                if path.is_file() and path.suffix.lower() in SITE_SUFFIXES
            )
        )
    return paths


def _contains_word(text: str, phrase: str) -> bool:
    return re.search(rf"\b{re.escape(phrase)}\b", text, re.IGNORECASE) is not None


def _phrase_findings(
    path: Path, text: str, *, auto_route_passes: bool, reflowed: bool
) -> list[Finding]:
    findings: list[Finding] = []
    for paragraph in paragraphs(text):
        line = None if reflowed else paragraph.line
        findings.extend(
            Finding(
                path,
                line,
                f'"{phrase}" is not true: setup asks for a password and a microphone permission',
            )
            for phrase in NEVER_PHRASES
            if _contains_word(paragraph.text, phrase)
        )
        if not auto_route_passes:
            findings.extend(
                Finding(path, line, f'"{phrase}" needs "{AUTO_ROUTE_MARKER}" in {RESULTS}')
                for phrase in AUTO_ROUTE_PHRASES
                if _contains_word(paragraph.text, phrase)
            )
        if NON_COMMERCIAL not in paragraph.text.lower():
            findings.extend(
                Finding(path, line, f'"{term}" needs "{NON_COMMERCIAL}" in the same paragraph')
                for term in COMMERCIAL_TERMS
                if _contains_word(paragraph.text, term)
            )
    return findings


def _number_findings(
    path: Path, text: str, allowed: set[Quantity], *, reflowed: bool
) -> list[Finding]:
    return [
        Finding(
            path,
            None if reflowed else line,
            f"{value} {unit} does not appear in any results document",
        )
        for line, (value, unit) in quantities(text)
        if (value, unit) not in allowed
    ]


def _sourcing_findings(root: Path) -> list[Finding]:
    findings: list[Finding] = []
    for paragraph in paragraphs(_read(root / ALTERNATIVES)):
        if not quantities(paragraph.text):
            continue
        if not _URL.search(paragraph.text):
            findings.append(Finding(ALTERNATIVES, paragraph.line, "figure has no source URL"))
        if not _ISO_DATE.search(paragraph.text):
            findings.append(
                Finding(ALTERNATIVES, paragraph.line, "figure has no check date (YYYY-MM-DD)")
            )
    return findings


def check(root: Path) -> list[Finding]:
    """Lint the checkout at `root` and return every broken rule."""
    results = _read(root / RESULTS)
    evidence = "\n".join(_read(root / path) for path in EVIDENCE_FILES)
    allowed = {quantity for _, quantity in quantities(evidence)}
    auto_route_passes = AUTO_ROUTE_MARKER in results
    findings: list[Finding] = []
    for path in claim_files(root):
        text = _read(root / path)
        reflowed = path.suffix.lower() in {".html", ".htm"}
        if reflowed:
            text = html_to_text(text)
        findings.extend(_number_findings(path, text, allowed, reflowed=reflowed))
        findings.extend(
            _phrase_findings(path, text, auto_route_passes=auto_route_passes, reflowed=reflowed)
        )
    findings.extend(_sourcing_findings(root))
    return findings


def main() -> None:
    """Lint the checkout from the command line."""
    root = repo_root(Path(__file__))
    if "--print-root" in sys.argv[1:]:
        sys.stdout.write(f"{root}\n")
        return
    findings = check(root)
    for finding in findings:
        sys.stderr.write(f"claims: {finding}\n")
    raise SystemExit(1 if findings else 0)


if __name__ == "__main__":
    main()
