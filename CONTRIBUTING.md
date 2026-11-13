# Contributing

Follow the [engineering standards](docs/engineering-standards.md).
Use the locked versions in `tools/pyproject.toml` and `tools/uv.lock`.
Run `make setup` once and `make check` before submitting a change.

The tracked `.pre-commit-config.yaml` defines formatting, lint, type and build checks.
Do not replace an externally managed `core.hooksPath`. Run hooks manually with
`uv run --project tools pre-commit run --all-files` when hooks are managed externally.

Keep `UntunnelEngine` free of filesystem, clock, network, Core Audio and UI dependencies.
Public APIs need concise documentation and follow semantic versioning from 0.1.0.
Do not add unsafe Swift compiler flags to the package manifest; dependent packages must
be able to consume the engine product.

Python entry points import `repo_root` from `untunnel_tools.paths` and call it with
`Path(__file__)` before accessing repo data. They support `--print-root` without accessing
hardware or the network. Shell scripts locate the nearest enclosing `Package.swift`
from their own directory and support the same diagnostic. Never use `git rev-parse`
for data paths. `tools/tests/test_paths.py` discovers modules and shell scripts to check
this contract from `/tmp` and `tools/`.

Hardware checks require access to the hardware and consent. Keep recordings, model
weights and third-party corpora out of commits. Never upload user audio or add paid services.
