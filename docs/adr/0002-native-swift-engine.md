# ADR-0002: Native Swift engine with development-only Python

Status: Accepted.

## Context

The application needs in-process audio restoration without a Python runtime in the user
installation. Use Swift 6 with Accelerate, with Core Audio isolated from the
engine. An in-process engine avoids a subprocess protocol and its serialisation overhead.

## Decision

Export `UntunnelEngine` as a library and `untunnel` as the executable product. Use Swift tools
version 6.2, Swift 6 language mode, and a macOS 15 deployment target. Keep DSP, audio I/O
and the app in distinct targets. Enforce warnings as errors through build commands,
without unsafe manifest flags that would prevent use as a package dependency.

Use Python 3.12 through uv for development only. Pin base dependencies and the `eval`,
`site` and `dev` groups exactly and retain a universal uv lockfile. Do not depend on
`deepfilternet`: its NumPy constraint conflicts with the planned numeric stack.

## Consequences

Native implementation and numerical parity tests remain required. The static site can
install its dependency group without torch or other evaluation
dependencies. Hardware-dependent microphone and routing decisions remain pending.

## Pin confirmation: 2026-11-05

The PyPI JSON endpoint `https://pypi.org/pypi/<package>/json` returned these latest stable
versions. Every Python pin remains unchanged. `uv_build` is the
build backend and is pinned to the current 0.13.7 release.

| Package | Version |
| --- | --- |
| numpy | 2.5.4 |
| scipy | 1.18.1 |
| soundfile | 0.14.0 |
| soxr | 1.1.0 |
| sounddevice | 0.5.6 |
| onnxruntime | 1.31.1 |
| mlx-whisper | 0.4.3 |
| jiwer | 4.0.0 |
| pesq | 0.0.4 |
| pystoi | 0.4.1 |
| speechbrain | 1.1.2 |
| torch | 2.15.0 |
| torchaudio | 2.11.1 |
| pytest | 9.2.0 |
| pytest-playwright | 0.10.0 |
| playwright | 1.64.1 |
| axe-playwright-python | 0.1.8 |
| ruff | 0.17.3 |
| pyright | 1.1.414 |
| hypothesis | 6.170.14 |
| pre-commit | 4.7.0 |
| uv_build | 0.13.7 |

`brew info --json=v2 uv ffmpeg swift-format gitleaks lychee rust blackhole-2ch`
confirmed these current Homebrew versions:

| Tool | Version |
| --- | --- |
| uv | 0.13.7 |
| ffmpeg | 9.0.2 |
| swift-format formula | 604.0.0 |
| gitleaks | 8.30.1 |
| lychee | 0.24.2 |
| rust | 1.99.1 |
| blackhole-2ch | 0.7.1 |

`swift --version` returned Swift 6.4.2 targeting arm64 macOS 27.2. `xcrun swift-format
--version` returned 6.4.4; the toolchain formatter is used instead of the Homebrew formula.
The uv interpreter is CPython 3.12.15.

GitHub release lookups and the `macos-26` CI build remain pending.
The action major versions, pre-commit-hooks v6.0.0, libASPL v3.1.2, deep-filter
0.5.6 and reuse-rs 0.4.0 are carried forward without a new GitHub release lookup.
webMUSHRA and evaluation asset revisions and hashes are not yet recorded. No model or corpus
was downloaded.
