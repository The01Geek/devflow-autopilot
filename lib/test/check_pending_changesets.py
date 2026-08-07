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
consolidator's own ``_is_consumable`` predicate so the audited population is exactly the set the
consolidator would consume (``README.md`` exempt; the npm ``config.json`` excluded by the
``.md`` filter).

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

_SCRIPTS_DIR = Path(__file__).resolve().parent.parent.parent / "scripts"


def _load_consolidator():
    """Import scripts/consolidate-changesets.py by path (its hyphen forbids a plain import)."""
    path = _SCRIPTS_DIR / "consolidate-changesets.py"
    spec = importlib.util.spec_from_file_location("_consolidate_changesets", path)
    if spec is None or spec.loader is None:  # pragma: no cover - defensive
        raise RuntimeError(f"cannot load the consolidator module from {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _enumerate_from_index(root: str) -> list[str]:
    """Tracked ``.changeset/*.md`` paths, read from the git index (never a recursive walk)."""
    result = subprocess.run(
        ["git", "-C", root, "ls-files", "-z", "--", ".changeset/*.md"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"git ls-files could not enumerate .changeset/*.md under {root}: "
            f"{result.stderr.strip()}"
        )
    names = [p for p in result.stdout.split("\0") if p]
    return [os.path.join(root, p) for p in names]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        default=".",
        help="repo root whose git index is enumerated (ignored when FILE args are given)",
    )
    parser.add_argument("files", nargs="*", help="explicit changeset files (fixture mode)")
    args = parser.parse_args(argv)

    consolidator = _load_consolidator()
    parse_changeset = consolidator._parse_changeset
    is_consumable = consolidator._is_consumable
    ChangesetError = consolidator.ChangesetError

    if args.files:
        candidates = list(args.files)
    else:
        try:
            candidates = _enumerate_from_index(args.root)
        except RuntimeError as exc:
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
