# Model licences

The code is MIT. The weights are not included and keep their own licences ([NOTICE](NOTICE)):

| Model | Licence | What it allows |
|---|---|---|
| Streaming, `nvidia/Real-time_RE-USE` | NVIDIA One-Way Noncommercial License (NSCLv1) | Non-commercial research and educational use. The model card says "This model is for research and development only." |
| Offline, `nvidia/NVIDIA-NemotronLabs-RE-USE` | OpenMDW-1.1 | The model card says "This model is ready for commercial use." Read the licence text before you rely on that. |

Both cards were read on 2026-11-10. The streaming weights are the live path, so a build that
restores a call with them is for non-commercial use whatever licence the Swift code has.
[ADR-0010](docs/adr/0010-real-time-model-architecture.md) records the licence reading and
leaves open whether a clean reimplementation is a derivative work. To use another checkpoint with
the streaming architecture, run
`untunnel download --model <owner>/<name>@<revision> --sha256 <hex>`, and check its licence first.
