#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Fail the suite when a shipped prompt surface references a path the vendor slice
prunes (issue #1072).

Why this exists: `.github/actions/vendor-plugin/vendor-slice.sh`'s
`devflow_copy_slice()` deletes subtrees from the vendored plugin before it lands in
a consumer (`lib/test`, `docs/site`, `.claude-plugin/marketplace.json`). A shipped
prompt sentence that names one of those paths as an instruction to *run* — or even
merely mentions it — resolves against a consumer's own tree, where the path does not
exist. The guards that predated this lint were hand-written per-file negatives over
a closed literal blacklist covering two files out of the shipped prompt surface's
sixty-three. This lint replaces that with a derivation: it parses the prune set out
of the slice itself and audits every `skills/**` / `agents/**` file for a reference
to one of those paths that does not carry an explicit declaration marker.

The forbidden path set is **derived, never transcribed** — a guard whose comparand is
a hardcoded copy of another file's content fails open the moment that file changes,
which is the exact defect this lint exists to prevent recurring one level up. A
qualifying prune target is an argument of an `rm` (any flag set — `rm -f` qualifies
alongside `rm -rf`) inside `devflow_copy_slice()`, written as the staging-directory
variable followed by a non-empty path suffix. The staging variable is itself
**identified from the function** — the target of the single assignment whose
right-hand side composes the function's destination argument (`$2`) — and never
carried as the literal name `stage`, so a rename in the slice is tracked rather than
silently missed. When the prune set cannot be established (the function, the
destination parameter, the composing assignment, or any qualifying target is
missing) the lint **refuses non-zero naming the slice source**, auditing nothing: an
empty or unparseable prune set is never a clean run.

Deliberate divergence from the closest structural sibling
(`lib/test/lint-superseded-config-keys.py`, issue #1084): #1084 exempts sites via an
in-checker path list. This lint rejects that in favour of an in-file declaration
marker on the referencing line, because its exceptions are per-*line* prose
judgements a reader must see at the site. The marker joins the existing family
(`# structural-pin-ok:`, `# raw-guard-ok:`, `# tree-walk-ok:`, `# argjson-ok:`),
adapted to markdown as an HTML comment. It has two fence-conditional spellings:
`<!-- pruned-path-ok: <reason> -->` for ordinary prose, and `# pruned-path-ok:
<reason>` for a line inside a fenced block the engine emits verbatim into a
consumer's shell (where an HTML comment would be emitted as shell text). The reason
must be non-empty. Fence tracking mirrors `scripts/load-prompt-extension.sh`'s
header — the in-repo rule of record: both CommonMark fence characters, a fence
closes only on its own kind, an unclosed fence runs to end of file, and an indented
fence is not recognized.

Population is enumerated from the git index over `skills/**` and `agents/**`
(`lib/test/lint_population.py`'s `enumerate_population` with the index-reading argv —
no `--others`, no repository-root-anchored recursive walk, per issue #711).

Usage:
    lint-shipped-pruned-path.py [--root DIR] [--files-from PATH]
                                [--slice-source PATH] [--print-prune-set]

Exit status is 0 only when the prune set was established, every selected file was
read, and none referenced a prune target without a marker. It is non-zero when a
reference is found, when the prune set cannot be established, when the enumeration is
unusable, and when any selected path could not be read.
"""

from __future__ import annotations

import argparse
import importlib.util
import re
import shlex
import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parents[2]

# The population enumeration, the file reader, the `EnumerationError` fail-closed
# contract, and the `--root` / `--files-from` preamble are shared with the other
# `git ls-files` lints (issue #724), loaded by path exactly as the sibling lints do.
_POP_PATH = _REPO_ROOT / "lib" / "test" / "lint_population.py"
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
        f"lint-shipped-pruned-path: {_POP_PATH} no longer provides "
        f"{', '.join(_pop_missing)}; refusing to audit"
    )

EnumerationError = _pop.EnumerationError

#: The audited population is markdown source; a NUL-carrying decode is reported as a
#: skip (never scanned) and fails the run closed, mirroring the sibling gh-api lint.
_SKIP_NUL = True

#: Path prefixes whose files make up the audited population.
AUDITED_PREFIXES = ("skills/", "agents/")

#: The default slice source, relative to the resolved root.
DEFAULT_SLICE_REL = ".github/actions/vendor-plugin/vendor-slice.sh"


class PruneParseError(Exception):
    """The prune set could not be established from the slice source. Fails closed."""


def _function_body(slice_text: str) -> str:
    """Return the body lines of `devflow_copy_slice()`, or raise.

    The function's closing brace is a bare `}` at column 0 (the bash style this repo
    uses), so the body runs from the line after the definition to the next such line.
    Braces inside `${…}` / `$(…)` never start a line, so this is robust where a raw
    character-level brace count is not.
    """
    lines = slice_text.split("\n")
    start = None
    for i, line in enumerate(lines):
        if re.match(r"\s*devflow_copy_slice\s*\(\s*\)", line):
            start = i
            break
    if start is None:
        raise PruneParseError("devflow_copy_slice() not found")
    body: list[str] = []
    for line in lines[start + 1:]:
        if re.match(r"}\s*$", line):
            return "\n".join(body)
        body.append(line)
    raise PruneParseError("devflow_copy_slice() closing brace not found")


def _fold_continuations(body: str) -> list[str]:
    """Join `\\`-continued lines so a target wrapped across a continuation is one line."""
    folded: list[str] = []
    pending = ""
    for line in body.split("\n"):
        if pending:
            pending += " " + line.lstrip()
        else:
            pending = line
        if pending.rstrip().endswith("\\"):
            pending = pending.rstrip()[:-1]
            continue
        folded.append(pending)
        pending = ""
    if pending:
        folded.append(pending)
    return folded


def _destination_param(lines: list[str]) -> str | None:
    """The function's destination parameter — the local var assigned exactly `$2`."""
    for line in lines:
        m = re.search(r'\b([A-Za-z_][A-Za-z0-9_]*)="?\$\{?2\}?"?', line)
        if m:
            return m.group(1)
    return None


def _staging_variable(lines: list[str], dest: str) -> str | None:
    """The staging variable — target of the single assignment composing `$dest`."""
    ref = re.compile(r"\$\{?" + re.escape(dest) + r"\}?\b")
    for line in lines:
        m = re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$', line)
        if not m:
            continue
        # An assignment whose target is the destination itself is not the staging var.
        if m.group(1) == dest:
            continue
        if ref.search(m.group(2)):
            return m.group(1)
    return None


def parse_prune_targets(slice_text: str) -> list[str]:
    """Return the sorted, de-duplicated prune-target suffixes derived from the slice.

    Raises `PruneParseError` on every shape that cannot yield a real target set: no
    function, no destination parameter, no composing assignment, or no qualifying
    removal. A bare staging-directory argument, a removal keyed on any other variable,
    and a `find … -exec` `{}` placeholder are all rejected — the first must never
    normalize to an empty suffix that would match every line of every audited file.
    """
    body = _function_body(slice_text)
    lines = _fold_continuations(body)
    dest = _destination_param(lines)
    if dest is None:
        raise PruneParseError("could not identify the destination parameter ($2)")
    stage = _staging_variable(lines, dest)
    if stage is None:
        raise PruneParseError(
            "could not identify the staging variable "
            "(no assignment composes the destination argument)"
        )
    stage_re = re.compile(r"^\$\{?" + re.escape(stage) + r"\}?/(.+)$")
    bare_re = re.compile(r"^\$\{?" + re.escape(stage) + r"\}?/?$")
    targets: list[str] = []
    for line in lines:
        try:
            tokens = shlex.split(line, posix=True)
        except ValueError:
            tokens = line.split()
        if "rm" not in tokens:
            continue
        for token in tokens:
            if bare_re.match(token):
                # Bare staging directory — never a target (would be an empty suffix).
                continue
            m = stage_re.match(token)
            if m and m.group(1):
                suffix = m.group(1).rstrip("/")
                if suffix and suffix not in targets:
                    targets.append(suffix)
    if not targets:
        raise PruneParseError("no qualifying rm target found in devflow_copy_slice()")
    return sorted(targets)


#: A recognized declaration marker, by fence context. Each requires a non-empty reason.
_MARKER_HTML = re.compile(r"<!--\s*pruned-path-ok:\s*(\S.*?)\s*-->")
_MARKER_SHELL = re.compile(r"#\s*pruned-path-ok:\s*(\S.*?)\s*$")

#: A line at column 0 opening/closing a fenced block (indented fences are not fences).
_FENCE = re.compile(r"^(`{3,}|~{3,})")


def _fence_states(lines: list[str]) -> list[bool]:
    """Return, per line, whether that content line is inside a fenced block.

    A fence delimiter line itself yields False (it is the boundary, not the interior).
    Mirrors scripts/load-prompt-extension.sh: both fence characters tracked, a fence
    closes only on its own kind, an unclosed fence runs to end of file, an indented
    fence is not recognized.
    """
    states: list[bool] = []
    fence_char: str | None = None
    for line in lines:
        m = _FENCE.match(line)
        if m:
            char = line[0]
            if fence_char is None:
                fence_char = char
                states.append(False)  # opening delimiter
                continue
            if fence_char == char:
                fence_char = None
                states.append(False)  # closing delimiter
                continue
            # A fence delimiter of the other kind is interior content of this fence.
            states.append(True)
            continue
        states.append(fence_char is not None)
    return states


def scan_text(text: str, targets: list[str]) -> list[tuple[int, str]]:
    """Return (1-based line number, matched target) for each unmarked reference.

    The matched target is returned alongside the line so the caller never re-splits the
    file or re-scans the targets to recover which path it matched.
    """
    lines = text.split("\n")
    states = _fence_states(lines)
    found: list[tuple[int, str]] = []
    for idx, line in enumerate(lines):
        hit = next((t for t in targets if t in line), None)
        if hit is None:
            continue
        marker = _MARKER_SHELL if states[idx] else _MARKER_HTML
        if marker.search(line):
            continue
        found.append((idx + 1, hit))
    return found


def is_audited(path: str) -> bool:
    normalized = path.replace("\\", "/")
    return any(normalized.startswith(p) for p in AUDITED_PREFIXES)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Fail when a shipped prompt surface (skills/**, agents/**) references a "
            "path the vendor slice prunes without a declaration marker."
        )
    )
    _pop.add_population_arguments(parser)
    parser.add_argument(
        "--slice-source",
        default=None,
        help=(
            "the vendor-slice.sh to derive the prune set from "
            "(default: <root>/" + DEFAULT_SLICE_REL + ")"
        ),
    )
    parser.add_argument(
        "--print-prune-set",
        action="store_true",
        help="print the derived prune set (one per line) and exit, auditing nothing",
    )
    args = parser.parse_args(argv)

    root = _pop.resolve_root(args.root, tool="lint-shipped-pruned-path")
    slice_source = Path(args.slice_source) if args.slice_source else root / DEFAULT_SLICE_REL

    try:
        slice_text = slice_source.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        print(
            f"lint-shipped-pruned-path: could not read slice source {slice_source}: "
            f"{exc}",
            file=sys.stderr,
        )
        return 1
    try:
        targets = parse_prune_targets(slice_text)
    except PruneParseError as exc:
        print(
            f"lint-shipped-pruned-path: could not establish a prune set from "
            f"{slice_source}: {exc}; auditing nothing",
            file=sys.stderr,
        )
        return 1

    if args.print_prune_set:
        for target in targets:
            print(target)
        return 0

    try:
        population = _pop.enumerate_population(
            root,
            Path(args.files_from) if args.files_from else None,
            ls_files_argv=_pop.LS_FILES_INDEX,
        )
    except EnumerationError as exc:
        print(f"lint-shipped-pruned-path: enumeration unusable: {exc}", file=sys.stderr)
        return 1

    audited = [path for path in population if is_audited(path)]

    findings: list[str] = []
    skipped: list[tuple[str, str]] = []
    read_ok = 0
    for relative in audited:
        text, skip_reason = _pop.read_source(root / relative, skip_nul=_SKIP_NUL)
        if text is None:
            skipped.append((relative, skip_reason or "unknown"))
            continue
        read_ok += 1
        for number, hit in scan_text(text, targets):
            findings.append(
                f"{relative}:{number}: references pruned path '{hit}' with no "
                "pruned-path-ok marker"
            )

    for finding in findings:
        print(finding)
    for relative, reason in skipped:
        print(f"lint-shipped-pruned-path: SKIPPED {relative}: {reason}", file=sys.stderr)
    print(
        f"lint-shipped-pruned-path: audited {read_ok} of {len(audited)} files"
        + (f" ({len(skipped)} skipped)" if skipped else "")
        + f"; prune set: {' '.join(targets)}"
    )
    if skipped:
        print(
            f"lint-shipped-pruned-path: {len(skipped)} selected path(s) could not be "
            "audited — refusing to report clean; see the SKIPPED lines above",
            file=sys.stderr,
        )
        return 1
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
