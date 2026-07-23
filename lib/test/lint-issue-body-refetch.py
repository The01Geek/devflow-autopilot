#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Fail the suite when a cut-over site re-fetches the GitHub issue body.

Why this exists (issue #693): a single `/devflow:implement` run now fetches the
issue body ONCE, at Phase 1 §1.1, into an in-tree cache
(`.devflow/tmp/issue-body/issue-<n>.md`), and the Phase 1–2 consumers read it by
explicit hand-off — shell helpers through their `--body-file` arms, subagents
through an `Issue body path:` line. This scanner keeps a cut-over site from
silently regressing to a fresh fetch.

The audited population is defined POSITIVELY: the tracked-and-unignored files
under `skills/implement/`. Its complement is out of the audited set on the
merits, each for a stated reason:

  * `skills/review/**` — §0.4's `issue_context` feeds the merge-gating reviewer's
    issue-compliance check; a named freshness exemption (it stays live).
  * `skills/pr-description/**` — renders the acceptance criteria into the PR body
    and its Post-Merge Verification checklist; a named freshness exemption.
  * `skills/receiving-code-review/**` — its per-iteration live re-read is a named
    freshness exemption.
  * `.devflow/prompt-extensions/**` and `docs/**` — documentation / consumer
    prose, not cut-over sites.

The audited UNIT is the site, not the file: `skills/implement/phases/
phase-1-setup.md` is audited, yet §1.1 in that same file must KEEP its fetch —
that fetch is the cache producer. So the scanner carries two named in-file
allowances, recognized by a literal in the offending logical line:

  * the §1.1 producer fetch — it redirects into the cache path, so its statement
    carries the `issue-body/issue-` cache-path literal; and
  * §4.1's Documentation-Needed gate fences — they redirect to
    `/tmp/devflow-docgate-body-<n>.txt`, carrying the `devflow-docgate-body`
    literal.

A detected form anywhere ELSE in an audited file is a failure.

Worktree immunity (issue #711/#725) — the ASSERTION form, not an in-helper
exclusion. The default enumeration is `git ls-files --cached --others
--exclude-standard`, whose `--others` leg sweeps every sibling git worktree the
harness parks under `.claude/worktrees/`, on any clone whose machine-local
`.git/info/exclude` lacks the harness line. A worktree-nested path such as
`.claude/worktrees/<w>/skills/implement/phases/phase-1-setup.md` is never
reported all the same, because `is_audited` requires the `skills/implement/`
prefix and that path fails it. That immunity is a PREFIX CONSEQUENCE, so — unlike
`lint-gh-api-repo-path.py`, whose audited population is defined by exclusion and
which therefore carries its own `.claude/worktrees/` line — this scanner does NOT
duplicate that exclusion: widening `AUDITED_PREFIX` is a deliberate act, and the
immunity is pinned by an assertion in `lib/test/run.sh` (the `#725` block) that
plants a worktree-shaped decoy carrying a real re-fetch violation, drives it
through `--files-from` (so no `.git/info/exclude` line has any say), proves the
real helper does not report it, and proves the same decoy — with the helper's
`AUDITED_PREFIX` widened in-process (importlib, so the shipped file's own sibling
imports still resolve) — DOES report it, so the pin guards the prefix property,
not a merely-deselected path.

Detected re-fetch forms (at minimum these five):
  1. `gh issue view` requesting `body` in its `--json` field list.
  2. `gh issue view` with no `--json` at all (its default human output prints
     the body).
  3. `gh api` reading an issue's `body` (an `issues/…` path plus a `.body` / a
     `--json body` extraction).
  4. a `parse-acs.py` invocation carrying `--issue`.
  5. a `preflight.py` invocation carrying `--issue`.

What the detected set does NOT cover, and which path handles it instead:
  * a `gh api graphql` body read — GraphQL is not the REST `gh api` shape this
    scanner tokenizes; out of reach.
  * a subagent-side `WebFetch` of the issue URL — a subagent tool call, not a
    shell statement; out of reach.
  * a re-pasted issue body in a dispatch prompt — plain prose, not a command;
    out of reach. The re-paste regression (the one the headline saving depends
    on) is guarded instead by `assert_pin_red_under` prose pins on each of the
    three dispatch sites in `lib/test/run.sh`, whose mutation restores the
    pasted body and is observed turning the pin RED.

The statement model is SHARED with the #363/#401/#664 guards — this scanner
imports `extract-command-heads.py`'s splitter, substitution walker, tokenizer,
and normalizer — so the guards agree on what a command invocation is. The line
selector (Markdown fence interiors; non-comment source lines) mirrors
`lint-gh-api-repo-path.py`.

Usage:
    lint-issue-body-refetch.py [--root DIR] [--files-from PATH]

Exit status is 0 only when every audited file was read and none violated the
rule. It is non-zero on a violation, on an unusable enumeration, and on any
audited path that could not be read — callers distinguish the three by reading
the report, never the exit code.
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import re
import subprocess
import sys
from pathlib import Path

# Reuse the issue-#363 extractor's quote/substitution/tokenization machinery — the
# same import `extract-command-shapes.py` and `lint-gh-api-repo-path.py` use, so
# this guard agrees with them about what a command invocation is.
_HEADS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "extract-command-heads.py")
_spec = importlib.util.spec_from_file_location("extract_command_heads", _HEADS_PATH)
_heads = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_heads)

#: The positive audited set: tracked files under this prefix.
AUDITED_PREFIX = "skills/implement/"

#: Suffixes dispatched to the Markdown fence reader.
MARKDOWN_SUFFIXES = (".md", ".md.example")

#: A logical line carrying one of these literals is a named in-file allowance —
#: the §1.1 producer fetch (which writes the cache) or §4.1's Documentation-Needed
#: gate fences (which redirect to the docgate scratch file). Findings on such a
#: line are suppressed. See the module docstring.
ALLOW_SITE_LITERALS = ("issue-body/issue-", "devflow-docgate-body")

#: A head token naming the gh binary directly, or through a resolver variable
#: whose name ends in `GH` (the repo's resolver contract, mirrored from
#: lint-gh-api-repo-path.py).
_GH_VAR_HEAD = re.compile(r"^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$")

#: A `gh api` path token that addresses an ISSUE resource directly —
#: `…/issues/<n>` as the final path segment. A sub-resource such as
#: `…/issues/<n>/comments` (the workpad/reaction listing, whose jq filters
#: comment `.body` fields) is deliberately NOT matched: that is a comment-body
#: read, not an issue-body read, and must stay. The query string is stripped
#: before the test so `…/issues/<n>?…` still matches.
_ISSUE_RESOURCE = re.compile(r"(^|/)issues/[^/]+/?$")


class EnumerationError(Exception):
    """The audited population could not be established. Always fails closed."""


def enumerate_population(root: Path, files_from: Path | None) -> list[str]:
    """Return the repo-relative paths to consider, before the prefix filter.

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

    paths = [line.rstrip("\r\n") for line in raw.split("\n") if line.rstrip("\r\n")]
    if not paths:
        raise EnumerationError(
            "the enumeration yielded zero paths before any filter was applied"
        )
    return paths


def is_audited(path: str) -> bool:
    """True when `path` is inside the positive audited prefix."""
    return path.replace("\\", "/").startswith(AUDITED_PREFIX)


def _read(path: Path) -> tuple[str | None, str | None]:
    """Return `(text, skip_reason)` — exactly one of the two is None."""
    try:
        data = path.read_bytes()
    except OSError as exc:
        return None, f"unreadable ({exc.__class__.__name__}: {exc})"
    text = data.decode("utf-8", errors="replace").replace("\r\n", "\n")
    if "\x00" in text:
        return None, "not a UTF-8-superset text file (NUL bytes — binary, UTF-16, or similar)"
    return text, None


def considered_lines(text: str, markdown: bool) -> list[tuple[int, str]]:
    """Return the 1-based (line number, text) pairs the scan may read.

    In Markdown only fence interiors are considered (an unterminated fence runs to
    end of file). In source every line whose first non-whitespace character is not
    `#` is considered.
    """
    kept: list[tuple[int, str]] = []
    inside = False
    for number, line in enumerate(text.split("\n"), start=1):
        stripped = line.lstrip()
        if markdown:
            if stripped.startswith("```") or stripped.startswith("~~~"):
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
    r"""Fold `\`-continued lines onto the line number of the statement's head.

    A form spelled across a line wrap is matched because the folded logical line
    carries the whole statement — a line-based scan would miss it.
    """
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
    """Every statement in one logical line, descending into `$(…)` bodies."""
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


def _json_value(tokens: list[str]) -> str | None:
    """The `--json` field-list value if present, else None.

    Handles `--json body`, `--json=body`, and a bare `--json` with the value in
    the following token. Returns None when no `--json` flag appears at all.
    """
    for index, token in enumerate(tokens):
        if token == "--json":
            return tokens[index + 1] if index + 1 < len(tokens) else ""
        if token.startswith("--json="):
            return token[len("--json="):]
    return None


def _json_has_body(json_value: str) -> bool:
    return any(field.strip() == "body" for field in json_value.split(","))


def _reads_body(tokens: list[str]) -> bool:
    """True when a `gh api` statement extracts an issue's body.

    A `.body` jq/-q extraction, or a `--json` field list naming `body`. The dot in
    `.body` is required, so a WRITE field like `-F body=@-` (a comment/body PATCH)
    is not mistaken for a body READ.
    """
    json_value = _json_value(tokens)
    if json_value is not None and _json_has_body(json_value):
        return True
    return any(".body" in token for token in tokens)


def _addresses_issue_resource(tokens: list[str]) -> bool:
    """True when some token is a REST path ending at `…/issues/<n>` itself."""
    for token in tokens:
        path = token.split("?", 1)[0]
        if _ISSUE_RESOURCE.search(path):
            return True
    return False


def _helper_invoked(tokens: list[str], basename: str) -> bool:
    """True when some token is (or ends in `/`) the named helper script."""
    return any(token == basename or token.endswith("/" + basename) for token in tokens)


def detect_forms(statement: str) -> list[str]:
    """Return the detected re-fetch form slugs in one statement (usually none)."""
    tokens = [_heads._normalize(t) for t in _heads._tokenize(statement)]
    if not tokens:
        return []
    head = tokens[0]
    forms: list[str] = []

    gh = _is_gh_head(head)
    rest = tokens[1:]
    if gh and "issue" in rest and "view" in rest:
        json_value = _json_value(tokens)
        if json_value is None:
            forms.append("gh-issue-view-no-json")
        elif _json_has_body(json_value):
            forms.append("gh-issue-view-body")
    if gh and "api" in rest:
        if _addresses_issue_resource(tokens) and _reads_body(tokens):
            forms.append("gh-api-issue-body")
    if _helper_invoked(tokens, "parse-acs.py") and "--issue" in tokens:
        forms.append("parse-acs-issue")
    if _helper_invoked(tokens, "preflight.py") and "--issue" in tokens:
        forms.append("preflight-issue")
    return forms


def _allowed(logical_line: str) -> bool:
    return any(literal in logical_line for literal in ALLOW_SITE_LITERALS)


def scan_text(text: str, markdown: bool) -> list[tuple[int, str]]:
    """Return the (line number, detected form) pairs found in `text`.

    A finding on a logical line carrying a named in-file allowance literal is
    suppressed — that is the §1.1 producer fetch and §4.1's gate fences.
    """
    found: list[tuple[int, str]] = []
    seen: set[tuple[int, str]] = set()
    for number, logical_line in fold_continuations(considered_lines(text, markdown)):
        if _allowed(logical_line):
            continue
        for statement in statements_in(logical_line):
            for form in detect_forms(statement):
                if (number, form) not in seen:
                    seen.add((number, form))
                    found.append((number, form))
    return found


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Fail when a cut-over site re-fetches the GitHub issue body (issue #693)."
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
        if proc.returncode == 0 and proc.stdout.strip():
            root = Path(proc.stdout.strip())
        else:
            root = Path.cwd()
            print(
                "lint-issue-body-refetch: no git toplevel "
                f"({proc.stderr.strip() or 'git rev-parse failed'}); "
                f"resolving paths against the cwd {root}",
                file=sys.stderr,
            )

    try:
        population = enumerate_population(root, Path(args.files_from) if args.files_from else None)
    except EnumerationError as exc:
        print(f"lint-issue-body-refetch: enumeration unusable: {exc}", file=sys.stderr)
        return 1

    audited = [path for path in population if is_audited(path)]

    findings: list[str] = []
    skipped: list[tuple[str, str]] = []
    read_ok = 0
    for relative in audited:
        text, skip_reason = _read(root / relative)
        if text is None:
            skipped.append((relative, skip_reason or "unknown"))
            continue
        read_ok += 1
        markdown = any(relative.endswith(suffix) for suffix in MARKDOWN_SUFFIXES)
        for number, form in scan_text(text, markdown):
            findings.append(
                f"{relative}:{number}: re-fetch of the issue body ({form}) at a "
                f"cut-over site — read the Phase-1 cache by hand-off instead"
            )

    for finding in findings:
        print(finding)
    for relative, reason in skipped:
        print(f"lint-issue-body-refetch: SKIPPED {relative}: {reason}", file=sys.stderr)
    print(
        f"lint-issue-body-refetch: audited {read_ok} of {len(audited)} files"
        + (f" ({len(skipped)} skipped)" if skipped else "")
    )
    if skipped:
        print(
            f"lint-issue-body-refetch: {len(skipped)} selected path(s) could not be audited — "
            "refusing to report clean; see the SKIPPED lines above",
            file=sys.stderr,
        )
        return 1
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
