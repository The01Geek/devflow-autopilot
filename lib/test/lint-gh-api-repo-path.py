#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Fail the suite when a `gh api` REST path is addressed through the
`$GITHUB_REPOSITORY` environment variable on a surface that can run outside
GitHub Actions.

Why this exists (issue #664): the variable is produced by the Actions runner and
has no producer on the local/interactive tier, so an interpolated path collapses
to `repos//issues/…`. `gh` then writes the HTTP error body to **stdout**, which a
best-effort `VAR=$(gh api … 2>/dev/null || true)` capture happily stores — so a
downstream `[ -n "$VAR" ]` guard is satisfied by a 404 blob rather than an id.
The correct idiom is the `{owner}/{repo}` placeholder pair, which `gh` fills from
the git remote on both tiers.

Scope boundaries, all deliberate and asserted by the suite:

* The audited population excludes `lib/test/`, `docs/`, `.github/workflows/`,
  `.github/actions/`, `.devflow/logs/`, `.devflow/learnings/`, `.changeset/`,
  and `CHANGELOG.md`. The first three groups carry the rule's own statement text
  and the `#466` pin literal; the `.devflow/` corpora are machine-appended
  records that quote reviewed commands verbatim; `.changeset/` is `CHANGELOG.md`'s
  producer and describes before-states. `.github/workflows/` and
  `.github/actions/` are excluded on the merits: both run only inside Actions,
  and a checkout-less workflow job has no remote for the placeholders to resolve
  from, so environment addressing is the *correct* form there.
* The recognized head set is closed: `gh`, `gh.exe`, and a `$VAR` / `${VAR}`
  expansion whose variable name ends in `GH` (the repo's `DEVFLOW_GH` resolver
  contract). A `gh` reached through a wrapper script, or through a variable whose
  name does not end in `GH`, is outside this guard and is not covered elsewhere.
* The recognized path token set is closed at the literal variable name. A repo
  string reached through one assignment hop (`repos/$REPO/…`) is invisible here
  even when that variable was populated from the environment. Both residuals are
  accepted, not closed.

The statement model — continuation folding aside — is **shared, not re-derived**:
this scanner imports `extract-command-heads.py`'s splitter, substitution walker,
tokenizer, and normalizer exactly as `extract-command-shapes.py` does, so the
#363 / #401 / #664 guards can never disagree about what a `gh api` invocation is.
What is bespoke here is only the *line selector*: unlike the #363 extractor, this
scanner does **not** skip heredoc bodies and does not require a fence's info
string to be exactly `bash` — a recipe emitted from a heredoc runs as written, and
an unterminated fence's remainder is treated as fence interior so a violation
after it is still reached.

Usage:
    lint-gh-api-repo-path.py [--root DIR] [--files-from PATH]

Exit status is 0 when the audited population is clean, and non-zero both when a
violation is found and when the enumeration is unusable — callers distinguish the
two by reading the report, never the exit code.
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import re
import subprocess
import sys
from pathlib import Path

# Reuse the issue-#363 extractor's quote/substitution/tokenization machinery — the same
# import `extract-command-shapes.py` uses, and for the same reason: three independent
# notions of "a statement" in lib/test/ would drift, and this guard would then disagree
# with the #363/#401 guards about which text is a `gh api` invocation.
_HEADS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "extract-command-heads.py")
_spec = importlib.util.spec_from_file_location("extract_command_heads", _HEADS_PATH)
_heads = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_heads)

#: Path prefixes whose files are never read. See the module docstring for why
#: each one is here.
EXCLUDED_PREFIXES = (
    "lib/test/",
    "docs/",
    ".github/workflows/",
    ".github/actions/",
    ".devflow/logs/",
    ".devflow/learnings/",
    ".changeset/",
)

#: Exact paths (not prefixes) that are never read.
EXCLUDED_PATHS = ("CHANGELOG.md",)

#: Suffixes dispatched to the Markdown reader. `.md.example` is listed because
#: the repository tracks prompt-extension examples with that suffix, whose prose
#: would otherwise be scanned as if it were shell.
MARKDOWN_SUFFIXES = (".md", ".md.example")

#: A head token naming the gh binary directly, or through a resolver variable.
_GH_VAR_HEAD = re.compile(r"^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$")

#: The two spellings of the prohibited variable inside a path argument.
_FORBIDDEN = ("$GITHUB_REPOSITORY", "${GITHUB_REPOSITORY}")


class EnumerationError(Exception):
    """The audited population could not be established. Always fails closed."""


def enumerate_population(root: Path, files_from: Path | None) -> list[str]:
    """Return the repo-relative paths to consider, before exclusions.

    Raises `EnumerationError` when the source cannot be read or yields nothing —
    the two arms that must never be mistaken for a clean audit.
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
                ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
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

    paths = [line.strip() for line in raw.split("\n") if line.strip()]
    if not paths:
        raise EnumerationError(
            "the enumeration yielded zero paths before any exclusion was applied"
        )
    return paths


def is_audited(path: str) -> bool:
    """True when `path` survives the population exclusions."""
    normalized = path.replace("\\", "/")
    if normalized in EXCLUDED_PATHS:
        return False
    return not any(normalized.startswith(p) for p in EXCLUDED_PREFIXES)


def _read(path: Path) -> str | None:
    """Decode a file with replacement, or return None when it cannot be opened.

    A stray non-UTF-8 byte never drops a file from the audit; an unopenable path
    (a deleted-but-still-listed entry, a directory) is skipped silently, because
    the enumeration is a snapshot the filesystem may have moved past.
    """
    try:
        data = path.read_bytes()
    except OSError:
        return None
    return data.decode("utf-8", errors="replace").replace("\r\n", "\n")


def considered_lines(text: str, markdown: bool) -> list[tuple[int, str]]:
    """Return the 1-based (line number, text) pairs the scan may read.

    In Markdown only fence interiors are considered — an unterminated fence runs
    to end of file. In source every line whose first non-whitespace character is
    not `#` is considered.
    """
    kept: list[tuple[int, str]] = []
    inside = False
    for number, line in enumerate(text.split("\n"), start=1):
        stripped = line.lstrip()
        if markdown:
            if stripped.startswith("```"):
                inside = not inside
                continue
            if inside:
                kept.append((number, line))
            continue
        if stripped.startswith("#"):
            continue
        kept.append((number, line))
    return kept


def fold_continuations(lines: list[tuple[int, str]]) -> list[tuple[int, str]]:
    """Fold `\\`-continued lines onto the line number of the statement's head."""
    folded: list[tuple[int, str]] = []
    pending_number: int | None = None
    pending_text = ""
    for number, line in lines:
        if pending_number is None:
            pending_number, pending_text = number, line
        else:
            pending_text += line
        if pending_text.endswith("\\"):
            pending_text = pending_text[:-1]
            continue
        folded.append((pending_number, pending_text))
        pending_number, pending_text = None, ""
    if pending_number is not None:
        folded.append((pending_number, pending_text))
    return folded


def statements_in(text: str) -> list[str]:
    """Return every statement in one logical line, descending into `$(…)` bodies.

    Composed from the shared machinery rather than re-derived: `_split_statements`
    keeps a substitution's body intact as part of its enclosing statement, and
    `_substitutions` hands back those bodies to be split in their own right — which
    is how `VAR=$(gh api …)` is reached without the assignment prefix hiding the head.
    The descent repeats until no further substitution appears, so a nested
    `$( … $(gh api …) … )` is reached too.
    """
    found: list[str] = []
    pending = [text]
    while pending:
        current = pending.pop()
        for statement in _heads._split_statements(current):
            found.append(statement)
            pending.extend(_heads._substitutions(statement))
    return found


def _is_gh_head(token: str) -> bool:
    if token in ("gh", "gh.exe"):
        return True
    match = _GH_VAR_HEAD.match(token)
    return bool(match) and match.group(1).endswith("GH")


def violations_in_statement(statement: str) -> list[str]:
    """Return the offending path arguments of one statement (usually none)."""
    tokens = [_heads._normalize(t) for t in _heads._tokenize(statement)]
    if len(tokens) < 3 or not _is_gh_head(tokens[0]) or tokens[1] != "api":
        return []
    return [
        token
        for token in tokens[2:]
        if token.startswith("repos/") and any(f in token for f in _FORBIDDEN)
    ]


def scan_text(text: str, markdown: bool) -> list[tuple[int, str]]:
    """Return the (line number, offending argument) pairs found in `text`."""
    found: list[tuple[int, str]] = []
    for number, line in fold_continuations(considered_lines(text, markdown)):
        for statement in statements_in(line):
            found.extend((number, argument) for argument in violations_in_statement(statement))
    return found


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Fail when a gh api REST path interpolates $GITHUB_REPOSITORY on a "
            "surface that can run outside GitHub Actions."
        )
    )
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
    args = parser.parse_args(argv)

    if args.root is not None:
        root = Path(args.root)
    else:
        proc = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=False,
        )
        root = Path(proc.stdout.strip()) if proc.returncode == 0 and proc.stdout.strip() else Path.cwd()

    try:
        population = enumerate_population(root, Path(args.files_from) if args.files_from else None)
    except EnumerationError as exc:
        print(f"lint-gh-api-repo-path: enumeration unusable: {exc}", file=sys.stderr)
        return 1

    audited = [path for path in population if is_audited(path)]

    findings: list[str] = []
    for relative in audited:
        text = _read(root / relative)
        if text is None:
            continue
        markdown = any(relative.endswith(suffix) for suffix in MARKDOWN_SUFFIXES)
        for number, argument in scan_text(text, markdown):
            findings.append(
                f"{relative}:{number}: gh api REST path addresses the repo through "
                f"$GITHUB_REPOSITORY ({argument}) — use the {{owner}}/{{repo}} placeholders"
            )

    for finding in findings:
        print(finding)
    print(f"lint-gh-api-repo-path: audited {len(audited)} files")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
