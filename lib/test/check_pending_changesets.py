#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Validate the repository's own pending changesets against the consolidator's parser (issue #1373).

A ``.changeset/*.md`` file whose frontmatter uses the npm ``@changesets`` form
(``"prflow": patch``) instead of the required ``bump: patch`` parses cleanly to a human
eye and passes every PR-side check, then **aborts** ``version-consolidate`` at merge time on
``main`` — after review and after CI, on the default branch, producing no version bump, no
CHANGELOG entry, no tag, and leaving the malformed file pending so every subsequent merge
fails identically until a human diagnoses it.

This check parses every tracked ``.changeset/*.md`` with the **same** ``_parse_changeset`` the
consolidator uses (imported, never re-implemented, so the check cannot drift from the parser it
protects) and fails RED naming any file that would raise ``ChangesetError``. It reuses the
consolidator's own ``_is_consumable`` predicate so the audited population is the tracked subset
of the set the consolidator would consume (``README.md`` exempt; the npm ``config.json``
excluded by the ``.md`` filter). It is the *tracked* subset because the enumeration reads the git
index (below); at merge time on ``main`` there are no untracked changesets, so the gap is inert
where it matters.

**Parse only — never consolidate.** The consolidator mutates the tree (it deletes consumed
changesets and rewrites tracked files, with no dry-run mode), so this check calls only the pure
parser and leaves the working tree byte-identical.

**Enumeration reads the git index**, not a repository-root recursive walk, so sibling worktrees
under ``.claude/worktrees/`` cannot contribute files and make the result vary between runs on the
same commit.

Usage:
  check_pending_changesets.py [--root DIR]        # enumerate tracked .changeset/*.md from the index
  check_pending_changesets.py FILE [FILE ...]     # validate the given files (fixture mode)

Exit 0 = every audited changeset parses. Exit 1 = at least one would raise ChangesetError
(each offending file named with the parser's own error text on stderr), or the enumeration
could not be established (fail-closed).
"""
from __future__ import annotations

import argparse
import importlib.util
import os
import subprocess
import sys
from pathlib import Path

_TEST_DIR = Path(__file__).resolve().parent
_SCRIPTS_DIR = _TEST_DIR.parent.parent / "scripts"


def _load_by_path(name: str, path: Path):
    """Import a sibling script by path (a hyphen in the filename forbids a plain import)."""
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# The consolidator whose parser this check protects, and the shared git-ls-files population
# reader (issue #724) — reused for its git-toplevel root resolution (#295) and the index-read
# argv (LS_FILES_INDEX carries `-c core.quotePath=false`, #1217, and states the worktree-immune
# index choice at the call site) rather than re-deriving that machinery here.
_consolidator = _load_by_path("_consolidate_changesets", _SCRIPTS_DIR / "consolidate-changesets.py")
_population = _load_by_path("_lint_population", _TEST_DIR / "lint_population.py")


def _enumerate_from_index(root: Path) -> list[str]:
    """Tracked ``.changeset/*.md`` paths, read from the git index (never a recursive walk).

    Zero pending changesets is a clean empty population, not an error (mirroring the
    consolidator's own zero-pending no-op), so this keeps a targeted pathspec and its own
    empty handling rather than ``enumerate_population``, whose fail-closed contract raises on
    an empty result.
    """
    argv = [*_population.LS_FILES_INDEX, "-z", "--", ".changeset/*.md"]
    result = subprocess.run(argv, cwd=str(root), capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise _population.EnumerationError(
            f"git ls-files could not enumerate .changeset/*.md under {root}: "
            f"{result.stderr.strip() or '(no stderr)'}"
        )
    names = [p for p in result.stdout.split("\0") if p]
    return [os.path.join(root, p) for p in names]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        default=None,
        help="repo root whose git index is enumerated (default: git toplevel, else cwd; "
        "ignored when FILE args are given)",
    )
    parser.add_argument("files", nargs="*", help="explicit changeset files (fixture mode)")
    args = parser.parse_args(argv)

    parse_changeset = _consolidator._parse_changeset
    is_consumable = _consolidator._is_consumable
    ChangesetError = _consolidator.ChangesetError

    if args.files:
        candidates = list(args.files)
    else:
        root = _population.resolve_root(args.root, tool="check-pending-changesets")
        try:
            candidates = _enumerate_from_index(root)
        except _population.EnumerationError as exc:
            print(f"check-pending-changesets: {exc}", file=sys.stderr)
            return 1

    # Reuse the consolidator's own consumption predicate so this audit's population cannot
    # drift from the set the consolidator would actually parse (README.md exempt).
    to_check = [p for p in candidates if is_consumable(os.path.basename(p))]

    errors: list[str] = []
    for path in to_check:
        try:
            parse_changeset(path)
        except ChangesetError as exc:
            errors.append(str(exc))

    if errors:
        print(
            f"check-pending-changesets: {len(errors)} malformed changeset(s) — "
            "version-consolidate would abort at merge time on main:",
            file=sys.stderr,
        )
        for msg in errors:
            print(f"  {msg}", file=sys.stderr)
        return 1

    print(f"check-pending-changesets: {len(to_check)} pending changeset(s) parse cleanly")
    return 0


if __name__ == "__main__":
    sys.exit(main())
