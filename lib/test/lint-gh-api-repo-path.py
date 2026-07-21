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

Unlike `extract-command-heads.py`, this scanner does **not** skip heredoc bodies
and does not require a fence's info string to be exactly `bash`: a recipe emitted
from a heredoc runs as written, and an unterminated fence's remainder is treated
as fence interior so a violation after it is still reached.

Usage:
    lint-gh-api-repo-path.py [--root DIR] [--files-from PATH]

Exit status is 0 when the audited population is clean, and non-zero both when a
violation is found and when the enumeration is unusable — callers distinguish the
two by reading the report, never the exit code.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

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

#: Statement separators, matched outside quotes and outside `$(…)`.
_SEPARATORS = ("&&", "||", ";", "|", "&", "\n")

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


def _substitution_spans(text: str) -> list[tuple[int, int]]:
    """Return the (start, end) offsets of each top-level `$(…)` body."""
    spans: list[tuple[int, int]] = []
    quote: str | None = None
    depth = 0
    start = 0
    index = 0
    while index < len(text):
        char = text[index]
        if quote:
            if char == quote:
                quote = None
        elif depth == 0 and char in ("'", '"'):
            quote = char
        elif text.startswith("$(", index):
            if depth == 0:
                start = index + 2
            depth += 1
            index += 2
            continue
        elif char == "(" and depth:
            depth += 1
        elif char == ")" and depth:
            depth -= 1
            if depth == 0:
                spans.append((start, index))
        index += 1
    return spans


def split_statements(text: str) -> list[str]:
    """Split on the shell separator set, outside quotes, descending into `$(…)`.

    A substitution's body becomes its own statement list and is removed from the
    enclosing text, so `VAR=$(gh api …)` is reached without the assignment prefix
    hiding the head.
    """
    statements: list[str] = []
    spans = _substitution_spans(text)
    if spans:
        remainder: list[str] = []
        previous = 0
        for start, end in spans:
            remainder.append(text[previous : start - 2])
            statements.extend(split_statements(text[start:end]))
            previous = end + 1
        remainder.append(text[previous:])
        text = "".join(remainder)

    current: list[str] = []
    quote: str | None = None
    index = 0
    while index < len(text):
        char = text[index]
        if quote:
            current.append(char)
            if char == quote:
                quote = None
            index += 1
            continue
        if char in ("'", '"'):
            quote = char
            current.append(char)
            index += 1
            continue
        separator = next((s for s in _SEPARATORS if text.startswith(s, index)), None)
        if separator is not None:
            statements.append("".join(current))
            current = []
            index += len(separator)
            continue
        current.append(char)
        index += 1
    statements.append("".join(current))
    return statements


def tokenize(statement: str) -> list[str]:
    """Split a statement into whitespace-separated tokens, stripping quotes."""
    tokens: list[str] = []
    current: list[str] = []
    quote: str | None = None
    for char in statement:
        if quote:
            if char == quote:
                quote = None
            else:
                current.append(char)
            continue
        if char in ("'", '"'):
            quote = char
            continue
        if char.isspace():
            if current:
                tokens.append("".join(current))
                current = []
            continue
        current.append(char)
    if current:
        tokens.append("".join(current))
    return tokens


def _is_gh_head(token: str) -> bool:
    if token in ("gh", "gh.exe"):
        return True
    match = _GH_VAR_HEAD.match(token)
    return bool(match) and match.group(1).endswith("GH")


def violations_in_statement(statement: str) -> list[str]:
    """Return the offending path arguments of one statement (usually none)."""
    tokens = tokenize(statement)
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
        for statement in split_statements(line):
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
