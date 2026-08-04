#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Fail the suite when a fenced shell block under `skills/` expands an unquoted
filename pattern that has neither a zsh `nomatch` guard nor a declaration marker.

Why this exists (issue #1211). A fenced shell block in a skill file is prose an
agent runs verbatim, in whatever shell the agent's harness gives it — commonly
**zsh**, not bash. zsh's default `nomatch` makes an unmatched glob a hard refusal
of *that one command*: it prints `zsh: no matches found: <pattern>` to stderr and
skips the command, then carries on with the rest of the block (it aborts the whole
block only under `set -e`, which no skill fence sets). The harm is therefore not a
dead block — it is a **silently empty enumeration**: the step that was supposed to
list something produces no output at all, and the surrounding prose cannot tell
"there is nothing here" from "the shell declined to look". A skill that works in
this repository can answer the wrong question in a consumer's repository purely
because a directory that exists here does not exist there.

The standard remedy, already used in this repository, is one line placed next to
the glob inside the same block:

    [ -n "${ZSH_VERSION:-}" ] && setopt nonomatch || :

It turns the behaviour off under native zsh and is an exact no-op everywhere else
(`$ZSH_VERSION` is unset, so `&&` short-circuits and `|| :` holds the exit status
at zero).

**This guard is deliberately narrow, and claims nothing more.** Telling a real
shell glob apart from prose that merely looks like one is the parsing problem
issue #644 had to solve for the documentation-path extractor, and a check that
tries to catch every case produces false alarms and gets switched off. So the
candidate shape is closed by enumeration below, and everything outside it is an
accepted, disclosed miss — never a claim of completeness.

Audited population, closed by enumeration:

* the tracked `*.md` files under `skills/`, sourced from an index-reading
  `git ls-files` with no `--others` (issue #711: a repository-root-anchored
  recursive walk descends into every sibling worktree under `.claude/worktrees/`
  and reports a number that varies between runs on the same commit).

Candidate shape, closed by enumeration — ALL of these must hold:

* the line sits inside a fenced block whose info string's first word is one of
  `bash`, `sh`, `shell`, `zsh` (an untagged or differently-tagged fence is not
  audited);
* the line is not wholly a comment, and is not a `case` branch (a line carrying
  `;;`, or the `case … in` header itself) — `*)` and `''|*[!0-9]*)` are branch
  patterns, not globs;
* the line contains a whitespace-delimited token, appearing **outside** any single
  or double quotes, that carries an unquoted `*` **and** a `/`. Requiring the `/`
  is what keeps `--include=*.py`, `Bash(gh:*)` and bare `*)` out of the candidate
  set; requiring the token to be unquoted is what keeps `find . -name "*.sql"` out,
  since a quoted pattern is never expanded by the shell;
* the token contains no `(`, `)` or `$` — a permission-grant literal written in
  prose (`Bash(lib/test/run.sh:*)`) and a parameter expansion are not filename
  patterns the shell will glob at this site;
* the token contains no `**` — markdown emphasis written inside a fence
  (`**Relevant Classes/Files**`) is not a pattern any skill fence's shell expands,
  since POSIX shells have no `**` operator and bash gives it recursive meaning only
  under `shopt -s globstar`, which no skill fence sets.

Accepted residuals, stated rather than papered over: a glob assembled through a
variable, a glob inside an untagged fence, a glob in a `for … in` list spanning
lines, and a glob written with `?` or `[…]` and no `*` are all outside the shape
and are not detected. The written convention in `CLAUDE.md` is the primary control;
this check is the narrow mechanical backstop for the commonest shape.

Violation condition: a candidate token whose line carries no `# glob-ok: <reason>`
marker and whose fence carries no `setopt nonomatch` guard on an earlier line. The
guard never judges what a marker's reason claims — what it buys is a reviewable,
greppable declaration at the desk, exactly like the sibling markers
`# structural-pin-ok:`, `# tree-walk-ok:`, `# pruned-path-ok:` and `# argjson-ok:`.

Usage:
    lint-skills-glob-guard.py [--root DIR] [--files-from FILE]

Exit 0 when the audited population is clean, 1 on a violation or a refusal to
audit (fail closed — an unusable population is never reported as clean).
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import sys
from pathlib import Path

TOOL = "lint-skills-glob-guard"

# The population enumeration, the file reader, the `EnumerationError` fail-closed
# contract, and the `--root` / `--files-from` preamble are shared with the other
# `git ls-files` lints (issue #724), imported by path with the idiom those files use.
# Assert the names this file uses at LOAD time so a rename fails here naming the
# dependency, not mid-scan.
_POP_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lint_population.py")
_pop_spec = importlib.util.spec_from_file_location("lint_population", _POP_PATH)
_pop = importlib.util.module_from_spec(_pop_spec)
_pop_spec.loader.exec_module(_pop)
_REQUIRED_POP_ATTRS = (
    "EnumerationError", "enumerate_population", "read_source",
    "add_population_arguments", "resolve_root", "LS_FILES_INDEX",
)
_pop_missing = [name for name in _REQUIRED_POP_ATTRS if not hasattr(_pop, name)]
if _pop_missing:
    raise SystemExit(
        f"{TOOL}: {_POP_PATH} no longer provides "
        f"{', '.join(_pop_missing)}; refusing to audit"
    )

MARKER = "# glob-ok:"
ZSH_GUARD = "setopt nonomatch"
SHELL_INFO_WORDS = {"bash", "sh", "shell", "zsh"}


def is_audited(relative: str) -> bool:
    """The audited population: tracked markdown under `skills/`."""
    return relative.startswith("skills/") and relative.endswith(".md")


def _unquoted_tokens(line: str) -> list[str]:
    """Split a line into whitespace-delimited tokens, dropping every token that
    carries a quote character.

    A token is dropped rather than unquoted: a partially-quoted token
    (`--name="*.sql"`) still has its pattern protected from the shell, and a
    token that opens a quote is not a bare filename pattern. This is a textual
    approximation of shell word-splitting, which is all the narrow candidate
    shape needs — it never has to reconstruct what the shell would actually run.
    """
    return [t for t in line.split() if "'" not in t and '"' not in t]


def _is_case_branch(line: str) -> bool:
    stripped = line.strip()
    if ";;" in stripped:
        return True
    if stripped.startswith("case ") or stripped.endswith(" in"):
        return True
    # A bare branch label on its own line: `*)` / `''|*[!0-9]*)` / `claude/issue-*|issue-*)`
    return stripped.endswith(")") and "(" not in stripped


def _candidate_tokens(line: str) -> list[str]:
    found = []
    for token in _unquoted_tokens(line):
        if "*" not in token or "/" not in token:
            continue
        if any(ch in token for ch in "()$"):
            continue
        if "**" in token:
            # Markdown emphasis inside a fence (`**Relevant Classes/Files**`), not a
            # pattern the shell expands: POSIX shells have no `**` operator, and bash
            # gives it recursive meaning only under `shopt -s globstar`, which no skill
            # fence sets. This is the named false-alarm class the narrow shape excludes.
            continue
        found.append(token)
    return found


def scan_file(text: str, path: str) -> list[str]:
    """Return one violation string per offending line."""
    violations: list[str] = []
    in_fence = False
    fence_is_shell = False
    fence_marker = ""
    fence_guarded = False
    for lineno, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if in_fence:
            if stripped.startswith(fence_marker) and stripped.strip("`~") == "":
                in_fence = False
                fence_is_shell = False
                fence_guarded = False
                continue
        elif stripped.startswith("```") or stripped.startswith("~~~"):
            fence_marker = stripped[0] * 3
            info = stripped.lstrip("`~").strip()
            first_word = info.split()[0].lower() if info.split() else ""
            in_fence = True
            fence_is_shell = first_word in SHELL_INFO_WORDS
            fence_guarded = False
            continue
        else:
            continue

        if not fence_is_shell:
            continue
        if ZSH_GUARD in line:
            fence_guarded = True
            continue
        if stripped.startswith("#") or not stripped:
            continue
        if _is_case_branch(line):
            continue
        tokens = _candidate_tokens(line)
        if not tokens:
            continue
        if fence_guarded or MARKER in line:
            continue
        violations.append(
            f"{path}:{lineno}: unguarded filename pattern {tokens[0]!r} in a "
            f"shell fence — add the `[ -n \"${{ZSH_VERSION:-}}\" ] && setopt "
            f"nonomatch || :` guard beside it, or declare it with "
            f"`{MARKER} <reason>`"
        )
    return violations


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Fail when a skills/ shell fence expands an unguarded filename pattern (issue #1211)."
    )
    _pop.add_population_arguments(parser)
    args = parser.parse_args(argv)

    root = _pop.resolve_root(args.root, tool=TOOL)

    try:
        population = _pop.enumerate_population(
            root,
            Path(args.files_from) if args.files_from else None,
            ls_files_argv=_pop.LS_FILES_INDEX,
        )
    except _pop.EnumerationError as exc:
        print(f"{TOOL}: enumeration unusable: {exc}", file=sys.stderr)
        return 1

    audited = [path for path in population if is_audited(path)]

    violations: list[str] = []
    skipped: list[tuple[str, str]] = []
    read_ok = 0
    for relative in audited:
        text, skip_reason = _pop.read_source(root / relative, skip_nul=False)
        if text is None:
            skipped.append((relative, skip_reason or "unknown"))
            continue
        read_ok += 1
        violations.extend(scan_file(text, relative))

    for violation in violations:
        print(f"{TOOL}: {violation}", file=sys.stderr)
    for relative, reason in skipped:
        print(f"{TOOL}: SKIPPED {relative}: {reason}", file=sys.stderr)
    print(f"{TOOL}: audited {read_ok} of {len(audited)} files")
    if skipped:
        # A path that could not be read is an UNESTABLISHED measurement, never a
        # clean one — fail closed rather than report coverage the scan never had.
        print(
            f"{TOOL}: {len(skipped)} selected path(s) could not be audited — "
            "refusing to report clean",
            file=sys.stderr,
        )
        return 1
    if violations:
        print(
            f"{TOOL}: {len(violations)} unguarded pattern(s) in {read_ok} file(s)",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
