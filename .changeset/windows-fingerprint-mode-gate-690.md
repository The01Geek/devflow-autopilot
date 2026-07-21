---
bump: patch
---

### Fixed

- `scripts/install-gh-wrapper.sh`'s output 5/7 fingerprint-mode gate is now platform-aware, so a writer-tier run on a self-hosted Windows / Git-Bash runner with a GitHub App configured no longer aborts before the agent starts (issue #690). A native-Windows `python3` synthesizes `os.stat().st_mode`'s permission bits from the `FILE_ATTRIBUTE_READONLY` bit alone, making the required `600` unreachable and failing every run. The platform token and the mode value now come from a single `python3` invocation reading a single `os.stat` result: on a `posix` token the strict comparison is unchanged, and on an `nt` token with a well-formed octal mode the installer continues and writes an `install-gh-wrapper:` stderr line recording that the owner-only guarantee could not be established. No `chmod` is introduced — `umask 077` remains the sole producer of the file's mode.

### Changed

- `docs/cloud-setup.md`, `docs/install.md`, `docs/DEVFLOW_SYSTEM_OVERVIEW.md`, and the comments in `scripts/install-gh-wrapper.sh` and `scripts/refresh-app-credentials.sh` now state that POSIX mode bits constrain neither the `gh`-wrapper fingerprint file nor the sibling credential token file on Windows, replacing the previous unconditional mode-0600 claims.
