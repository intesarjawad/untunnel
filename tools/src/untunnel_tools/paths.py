import argparse
import sys
from pathlib import Path


def repo_root(source: Path) -> Path:
    """Find the nearest enclosing package without requiring a Git checkout."""
    resolved = source.resolve()
    for parent in resolved.parents:
        if (parent / "Package.swift").is_file():
            return parent
    message = f"No Package.swift found above {resolved}; run a tool from a source checkout."
    raise FileNotFoundError(message)


def main() -> None:
    """Expose the path diagnostic used by every tool entry point."""
    parser = argparse.ArgumentParser(description="Locate the source checkout.")
    parser.add_argument("--print-root", action="store_true", required=True)
    parser.parse_args()
    root = repo_root(Path(__file__))
    sys.stdout.write(f"{root}\n")


if __name__ == "__main__":
    main()
