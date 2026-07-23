#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Shared population reader for `lib/test/`'s `git ls-files` lints (issue #724).

Five independent `lib/test/` lints enumerate a file population from `git ls-files`
(`pin-corpus-lint.py`, `coverage_map_guard.py`, `lint-tree-enumeration.py`,
`lint-gh-api-repo-path.py`, `lint-issue-body-refetch.py`). The last three
additionally read each file and expose a `--root` / `--files-from` command-line
preamble, and carried near-verbatim copies of that machinery, and the copies had
already drifted (issue #711 was itself an instance: one reader used a working-tree
enumeration where an index read was required, invisible until a worktree-carrying
checkout ate a red suite CI could not reproduce). This module owns the one shape for
those three so a new reader inherits a *decision*, not a copied accident;
`pin-corpus-lint.py` and `coverage_map_guard.py` keep their own differently-shaped
readers and are outside this consolidation by construction.

Only the two axes that legitimately differ between callers are parameters; every
other line is shared:

* **The `git ls-files` argv** (`enumerate_population(..., ls_files_argv=…)`). An
  index-reading caller passes `LS_FILES_INDEX` and a working-tree-reading caller
  passes `LS_FILES_WORKING_TREE`, each stating its choice at the call site where a
  reviewer sees it. The index read is worktree-immune on a bare clone; the
  working-tree read (`--others`) sweeps sibling worktrees and needs its own
  `.claude/worktrees/` handling — the #711 lesson made explicit rather than default.
* **The NUL-byte policy** (`read_source(..., skip_nul=…)`). A caller whose
  population can contain binaries/UTF-16 passes `skip_nul=True` to report such a
  file as a skip (no `gh api` token can match its replacement-decoded text anyway);
  a caller whose population is source-only, and whose governing criterion demands a
  lossy decode that raises on no tracked file, passes `skip_nul=False` so a planted
  non-UTF-8 fixture is scanned to completion rather than skipped.

Everything else — the `EnumerationError` fail-closed contract, the "strip only the
line terminator" path splitting, the unopenable-path skip reason, the `--root` /
`--files-from` argument definitions, and the git-toplevel root resolution — is
owned here and shared verbatim. The per-tool breadcrumb text carries the caller's
own name via the `tool` argument, so a diagnostic still says which lint spoke.

Each lint imports this module with the same `importlib.util.spec_from_file_location`
idiom the directory already uses for `extract-command-heads.py`.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

#: The two sanctioned `git ls-files` argvs. A caller names one at its call site.
#: `LS_FILES_INDEX` reads the index only (no `--others`) and is worktree-immune on a
#: bare clone; `LS_FILES_WORKING_TREE` additionally lists untracked-but-unignored
#: files (`--others`), which sweeps sibling worktrees and is chosen only when a
#: caller must see files not yet in the index.
LS_FILES_INDEX = ("git", "ls-files")
LS_FILES_WORKING_TREE = ("git", "ls-files", "--cached", "--others", "--exclude-standard")


class EnumerationError(Exception):
    """The audited population could not be established. Always fails closed."""


def enumerate_population(
    root: Path,
    files_from: Path | None,
    *,
    ls_files_argv: tuple[str, ...],
) -> list[str]:
    """Return the repo-relative paths to consider, before any caller exclusions.

    The population comes from `--files-from` when given, else from running
    `ls_files_argv` in `root`. Raises `EnumerationError` when the source cannot be
    read or yields nothing — the two arms that must never be mistaken for a clean
    audit. The argv is the caller's explicit index-vs-working-tree choice; this
    function never picks one for it.
    """
    if files_from is not None:
        try:
            raw = files_from.read_text(encoding="utf-8")
        except OSError as exc:
            raise EnumerationError(
                f"--files-from list could not be read ({files_from}): {exc}"
            ) from exc
    else:
        try:
            proc = subprocess.run(
                list(ls_files_argv),
                cwd=str(root),
                capture_output=True,
                text=True,
                check=False,
            )
        except OSError as exc:
            raise EnumerationError(f"git ls-files could not be run: {exc}") from exc
        if proc.returncode != 0:
            raise EnumerationError(
                "git ls-files exited "
                f"{proc.returncode}: {proc.stderr.strip() or '(no stderr)'}"
            )
        raw = proc.stdout

    # Strip ONLY the line terminator: a path with leading/trailing spaces is legal in
    # git, and trimming it would yield a path that cannot open — silently dropping a
    # real file from the audit through a caller's skip arm.
    paths = [line.rstrip("\r\n") for line in raw.split("\n") if line.rstrip("\r\n")]
    if not paths:
        raise EnumerationError(
            "the enumeration yielded zero paths before any exclusion was applied"
        )
    return paths


def read_source(path: Path, *, skip_nul: bool) -> tuple[str | None, str | None]:
    """Return `(text, skip_reason)` — exactly one of the two is None.

    Decoding is always lossy (`errors="replace"`), so a stray non-UTF-8 byte never
    drops a file from the audit. An unopenable path is always a reported skip, never
    an absorbed one — "audited nothing" must never read as "audited everything,
    found nothing".

    `skip_nul` is the caller's one policy choice. When True, a NUL-carrying decode
    (binary, UTF-16, or similar) is reported as a skip: no source-language token can
    match its replacement-decoded text, so scanning it would only invite a false
    clean. When False, NUL bytes are kept and the file is scanned to completion —
    the shape a source-only population needs when its governing criterion requires a
    lossy decode that raises on no tracked file (a planted non-UTF-8 fixture must be
    audited, not skipped).
    """
    try:
        data = path.read_bytes()
    except OSError as exc:
        return None, f"unreadable ({exc.__class__.__name__}: {exc})"
    text = data.decode("utf-8", errors="replace").replace("\r\n", "\n")
    if skip_nul and "\x00" in text:
        return None, "not a UTF-8-superset text file (NUL bytes — binary, UTF-16, or similar)"
    return text, None


def add_population_arguments(parser: argparse.ArgumentParser) -> None:
    """Add the shared `--root` / `--files-from` arguments to `parser`.

    Both help strings are owned here so every lint's preamble reads identically; a
    caller adds its own tool-specific arguments alongside.
    """
    parser.add_argument(
        "--root",
        default=None,
        help="repository root to enumerate and resolve paths against (default: the git toplevel, else the cwd)",
    )
    parser.add_argument(
        "--files-from",
        default=None,
        help="read the population from this newline-separated path list instead of git ls-files",
    )


def resolve_root(root_arg: str | None, *, tool: str) -> Path:
    """Resolve the population root from `--root`, else the git toplevel, else the cwd.

    Never a silent default (the #295 repo-root contract): a wrong root feeds
    straight into the read loop, and with `--files-from` it would otherwise produce
    a green run over files that do not exist. When the git toplevel cannot be
    resolved, the cwd fallback is announced on stderr under the caller's `tool` name.
    """
    if root_arg is not None:
        return Path(root_arg)
    proc = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode == 0 and proc.stdout.strip():
        return Path(proc.stdout.strip())
    root = Path.cwd()
    print(
        f"{tool}: no git toplevel "
        f"({proc.stderr.strip() or 'git rev-parse failed'}); "
        f"resolving paths against the cwd {root}",
        file=sys.stderr,
    )
    return root
