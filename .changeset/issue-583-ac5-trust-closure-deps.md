---
bump: patch
---

### Added

- Cloud-writer trust-closure dependency classification (AC5 of #583, PR #598): `lib/test/cloud_writer_deps.py` classifies static source/exec/import edges out of every AC1-closure helper entry point — repository-owned edges must resolve beneath the vendored tree, external runtime edges must name a preflight guarantee or explicit profile grant, and an include the source scan cannot resolve is emitted as an `unresolved-source` edge the guard rejects (fail closed). `lib/preflight.sh` gains the machine-readable `_DEVFLOW_PREFLIGHT_GUARANTEES` declaration the classifier parses, machine-pinned against the file's own probes.
