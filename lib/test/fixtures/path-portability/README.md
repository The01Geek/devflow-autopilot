<!-- SPDX-FileCopyrightText: 2026 Daniel Radman -->
<!-- SPDX-License-Identifier: MIT -->
# path-portability fixture corpus (issue #702, AC6)

Proves the **local portable helper-anchor form** — the
`${CLAUDE_SKILL_DIR:-<base>}/../../scripts/…` anchor resolved through
`lib/normalize-path.sh` — for each of the four supported host-path families.
These four families are **complete by construction** for the existing
POSIX-shell contract: a helper anchor arrives either already in POSIX form
(Linux, macOS) or in Windows drive-letter form that the running shell maps to
its own mount scheme (WSL → `/mnt/<drive>/…`, Git Bash / MSYS2 → `/<drive>/…`).
UNC paths are the documented out-of-scope residual (a skill anchor is never
UNC — see `lib/normalize-path.sh`).

`families.tsv` is the corpus. Columns (tab-separated; `#` comment / blank lines
ignored):

1. `family`      — one of the four family ids (the driver asserts the set is
                   exactly these four, so a dropped or added family goes RED).
2. `host_signal` — the environment the driver simulates: `posix` (no
                   wslpath/cygpath, no WSL/MSYS signal), `wsl` (stub `uname -r`
                   reporting a microsoft kernel), or `msys2` (`MSYSTEM` set,
                   non-microsoft `uname`).
3. `input_base`  — the runner-reported skill base directory as it arrives on
                   that host (a Windows-form base for the winform families).
4. `expected_base` — the POSIX base the anchor must resolve to before the
                   `/../../scripts/…` join.

The driver is `lib/test/path-portability-test.sh`, invoked from
`lib/test/run.sh`. It mirrors the existing `#247` T4* stub methodology
(restricted-PATH sandbox + stubbed `uname`/`MSYSTEM`) so the corpus rows and
the live `devflow_normalize_path` behavior stay in lockstep.
