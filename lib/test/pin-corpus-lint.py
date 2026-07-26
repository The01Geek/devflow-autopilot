#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Static self-scan of `lib/test/run.sh`'s own pin corpus (issue #375).

Three mechanical guards over the suite's pin-helper call sites, so a defect the
parents (#370, #371) had to rediscover in a later shadow instead fails RED at
authoring time:

* ``lint`` — the **pin-in-comment lint.** A pin literal that also appears inside
  a *comment* of its own target file inflates the occurrence count the pin reads
  (issue #370's evidence: a ``pin_count`` expecting 2 read 3 because the phase
  file's own comment quoted the literal, so collapsing a real call site brought
  the count *down* to the expected 2 — the pin passed on the regression it
  guards). This scan enumerates every statically-resolvable ``(literal, target)``
  pair from the four pin helpers and FAILs when the literal sits in a ``#``
  comment (``.sh``/``.py``/``.jq``/``.yml``) or an ``<!-- … -->`` region
  (``.md``) of its target.

* ``wrapped`` — the **wrapped-literal meta-guard.** A contract phrase assembled
  from wrapped adjacent string literals (``'… OLD does '`` then ``'not) …'`` in
  an argparse ``help=``) lives on *no single line*, so a line-based ``grep`` /
  ``pin_count`` finds nothing even though the rendered ``--help`` text contains
  it (issue #371's evidence). This scan flags any source-grep pin whose phrase
  occurs on no single line of its target, distinguishing *absent* from *present
  only in the whitespace-normalized rendering* (``tr -s '[:space:]' ' '``), and
  additionally FAILs any pin into a multi-literal argparse ``help=`` string,
  requiring the pin to target the rendered surface (captured ``--help`` output,
  real stderr) instead.

  **Relocation diagnosis (issue #661, opt-in via ``--reloc``).** A bare
  ``ABSENT`` reads identically for a pin literal that was *relocated* into a
  different file and one that was genuinely *deleted*. When ``--reloc`` is
  passed and a pin literal is ABSENT from its named target (whitespace-normalized
  and rendered-surface, so a wrapped literal still counts), the guard searches a
  scoped tracked-file set — from ``--reloc-search-set`` when supplied (the
  git-free path the self-tests use) else ``git ls-files`` — **minus** the
  pin-source file(s) that declare the literal (auto-excluded plus any
  ``--reloc-exclude`` substring token) and the non-source trees ``.devflow/vendor/`` /
  ``.devflow/tmp/``, and reports every other file where the literal resolves as
  ``RELOCATED … relocated to <file>; update the pin target``. Only when the set
  was enumerated successfully **and** the literal resolves nowhere in it does it
  read ``deleted (not found anywhere)`` — a failed/empty enumeration is reported
  ``relocation diagnosis unavailable`` on stderr and is **never** collapsed to
  ``deleted`` (fail-closed). Without ``--reloc`` the ABSENT emit is unchanged.

* ``mutation-routing-worktree`` — the required **wording-only pin authoring gate**
  (issues #666 and #810). It establishes a path-aware worktree diff, validates its
  audited source population against the module registry, and applies one policy to
  helper-based and direct raw source-presence pins. A permitted structural boundary
  declares ``# structural-pin-ok: <category> -- <non-empty rationale>`` with a category
  from the closed set; a move is exempt one-to-one only when classification is
  preserved. Base, diff, enumeration, source-read, registry, and scratch failures exit
  2, policy findings exit 3, and a clean established scan exits 0. The lower-level
  ``mutation-routing`` synthetic-fixture command remains for legacy self-tests.

**Fail-closed:** a call site the scanner cannot resolve statically (the literal
interpolates a variable it cannot resolve, or the target file is a variable with
no ``--var`` binding and no ``$LIB``-relative assignment) is COUNTED and reported
on stderr, never silently skipped.

The three legacy pin-source commands preserve their existing output contracts:
without ``--strict``, ``lint`` and ``wrapped`` exit 0 even on findings, and the
synthetic-fixture ``mutation-routing`` command always exits 0. Findings go to
stdout (one per line, tab-separated); unresolvable counts and per-site details go
to stderr. The required ``mutation-routing-worktree`` command instead carries its
0/2/3 clean/infrastructure/finding contract directly.

**``--strict`` exit-code mode (issue #687, opt-in, applies to ``lint`` and
``wrapped``; ``mutation-routing`` keeps its own always-exit-0 contract).** With
``--strict`` a run that writes at least one line to stdout exits **3**, and a run
that writes none exits 0; the stdout and stderr bytes are byte-for-byte what they
are without the flag — ``--strict`` changes only the exit code. The rule is
defined over **whether any line was written to stdout**, not over a list of
finding tokens, so a finding arm added later is covered the day it lands. Every
stdout write on a covered path routes through the single ``_emit`` helper (defined
just above ``run_lint``); ``lib/test/run.sh``'s issue-#687 emit-helper guard,
anchored from ``run_lint`` to the end of ``_emit_wrapped_or_absent``, goes RED if
a raw stdout write is introduced inside that range — so a future arm printing
*informational* output on a covered path must route it to ``sys.stderr`` instead.
**What ``--strict`` rc 0 does and does not assert:** it asserts only that no line
was written to stdout; it does **not** assert that any pin was resolved. The
fail-closed accounting (``UNRESOLVED-COUNT`` / ``RESOLVED-COUNT``) is a stderr
channel that never moves the exit code, so a corpus in which every pin failed to
resolve prints nothing and exits 0 under ``--strict`` — a caller keying on the
exit code still owes the separate ``RESOLVED-COUNT`` floor.

CLI::

    pin-corpus-lint.py lint            PIN_SOURCE [--strict] [--lib DIR] [--var NAME=PATH ...]
    pin-corpus-lint.py wrapped         PIN_SOURCE [--strict] [--lib DIR] [--var NAME=PATH ...]
                                       [--reloc] [--reloc-search-set FILE]
                                       [--reloc-exclude SUBSTR ...]
    pin-corpus-lint.py mutation-routing PIN_SOURCE --diff-file FILE
                                       [--lib DIR] [--var NAME=PATH ...]
    pin-corpus-lint.py mutation-routing-worktree REPO_ROOT

``PIN_SOURCE`` is the shell file whose pin call sites are scanned (``run.sh``
itself for the real corpus, a synthetic fixture for the self-tests). ``--var``
supplies the runtime value of a target-file variable the helper cannot resolve
statically (e.g. ``DEF_SKILL``, the mktemp'd implement-skill bundle); ``--lib``
binds ``$LIB`` so ``VAR="$LIB/../skills/…"`` assignments resolve on their own.
``--reloc`` enables the issue-#661 relocation diagnosis on the ``wrapped``
guard's ABSENT branch; ``--reloc-search-set FILE`` supplies the search set as a
newline-delimited file (git-free, for the self-tests) instead of ``git
ls-files``; ``--reloc-exclude SUBSTR`` (repeatable) drops any tracked path
containing SUBSTR anywhere in it -- a substring test, not an anchored prefix --
from the search set (the pin-source file(s) that declare the literal); a token
that resolves to the same file as a candidate (abspath-equal) is dropped too.
``--diff-file FILE`` (``mutation-routing`` only, required) supplies the unified
diff whose added/deleted lines scope the declaration gate.

Known limitation: the search set is read as UTF-8, so a non-UTF-8 tracked file
(an image, a binary fixture) is an UNREADABLE candidate. That direction is safe
-- it downgrades a would-be ``deleted`` verdict to ``diagnosis INCOMPLETE`` and
never claims a false deletion -- but it does mean a genuine deletion in a corpus
containing binary tracked files reports INCOMPLETE rather than ``deleted``.
"""

from __future__ import annotations

import ast
import difflib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import NamedTuple

# Non-source trees always excluded from the relocation search set (issue #661): a
# committed vendored plugin copy and the run's own draft/derivation artifacts both
# quote pin literals and would otherwise be reported as spurious destinations.
RELOC_DEFAULT_EXCLUDES = (".devflow/vendor/", ".devflow/tmp/")

# (literal_arg_index, file_arg_index, default_file_var).  Indices are 0-based
# over the call's arguments AFTER the helper name.  A file index past the actual
# arg list means the optional file arg was omitted -> use default_file_var.
HELPERS = {
    "assert_pin_unique": (1, 2, None),
    "pin_count": (0, 1, None),
    "assert_pin_red_on_removal": (1, 2, "MAXI_SKILL"),
    "assert_pin_red_under": (1, 3, "MAXI_SKILL"),
    # NOTE (#666): `assert_count_red_under` is deliberately NOT registered here. Its
    # first slot is `pattern` — an ERE counted with `grep -cE` over a `sed -n` line-range
    # slice — whereas HELPERS' first slot is the fixed-string LITERAL that `lint` and
    # `wrapped` treat as such. Registering it would make its first call site draw a
    # `wrapped` finding for an anchor pattern that legitimately matches no literal line
    # and a `lint` finding false by construction. It needs no registration to be handled
    # correctly by `mutation-routing`: it is mutation-taking (see MUTATION_TAKING_HELPERS),
    # which never draws a finding.
    # Namespaced module pin API (module-harness.sh, issue #577) so the meta-lints
    # cover pins that extraction moves out of run.sh into lib/test/modules/*.sh
    # (issue #591). Module pins always pass the target file explicitly — no default.
    "devflow_module_pin_count": (0, 1, None),
    "devflow_module_pin_unique": (1, 2, None),
    "devflow_module_pin_present": (1, 2, None),
    "devflow_module_pin_red_under": (1, 3, None),
}

COMMENT_HASH_EXTS = {".sh", ".py", ".jq", ".yml", ".yaml"}
COMMENT_MD_EXTS = {".md"}


# ── shell tokenizing ────────────────────────────────────────────────────────
def join_logical_lines(text):
    """Yield (start_lineno, logical_line) joining backslash-continued lines."""
    physical = text.split("\n")
    i = 0
    while i < len(physical):
        start = i + 1
        line = physical[i]
        while line.endswith("\\") and not line.endswith("\\\\") and i + 1 < len(physical):
            line = line[:-1] + "\n" + physical[i + 1]
            i += 1
        yield start, line
        i += 1


def tokenize(s):
    """Split a shell fragment into argument tokens, quote-aware.

    Returns a list of tokens, each a list of (kind, value) segments where kind
    is 'sq' (single-quoted, literal), 'dq' (double-quoted), or 'bare'. Adjacent
    segments with no separating whitespace belong to one token (shell
    concatenation, e.g. `'a'"$B"`).
    """
    tokens = []
    cur = []  # list of (kind, value) segments for the current token
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c in " \t\n":
            if cur:
                tokens.append(cur)
                cur = []
            i += 1
            continue
        if c == "#" and not cur:
            # A '#' starting a token begins a comment (only outside a token, so
            # `foo#bar` bare words are unaffected — none occur in pin calls).
            break
        if c == "'":
            j = s.index("'", i + 1) if "'" in s[i + 1 :] else n
            cur.append(("sq", s[i + 1 : j]))
            i = j + 1
            continue
        if c == '"':
            j = i + 1
            buf = []
            while j < n and s[j] != '"':
                if s[j] == "\\" and j + 1 < n:
                    buf.append(s[j : j + 2])
                    j += 1
                else:
                    buf.append(s[j])
                j += 1
            cur.append(("dq", "".join(buf)))
            i = j + 1
            continue
        # bare run up to next whitespace/quote
        j = i
        buf = []
        while j < n and s[j] not in " \t\n'\"":
            if s[j] == "\\" and j + 1 < n:
                buf.append(s[j + 1])
                j += 1
            else:
                buf.append(s[j])
            j += 1
        cur.append(("bare", "".join(buf)))
        i = j
    if cur:
        tokens.append(cur)
    return tokens


# ── variable resolution ─────────────────────────────────────────────────────
_VARREF = re.compile(r"^\$\{?(\w+)\}?$")
_ASSIGNMENT_RE = re.compile(r"^\s*(?:local\s+)?([A-Za-z_]\w*)=(.*)$")


def build_var_maps(text, lib, overrides):
    """Return (path_vars, literal_vars).

    path_vars: NAME -> resolved filesystem path (from `--var` overrides and from
    `VAR="$LIB/..."` / `VAR=$OTHER` assignments).
    literal_vars: NAME -> literal string value (from `VAR='single-quoted'`).

    This intentionally models only sequential top-level assignments. Each
    right-hand side is resolved against the values available at that point; it
    does not attempt to evaluate conditional shell control flow.
    """
    path_vars = dict(overrides)
    literal_vars = {}
    for _, line in join_logical_lines(text):
        m = _ASSIGNMENT_RE.match(line)
        if not m:
            continue
        name, rhs = m.group(1), m.group(2).strip()
        _apply_assignment(
            name, rhs, path_vars, literal_vars, lib, protected=set(overrides)
        )
    return path_vars, literal_vars


def _apply_assignment(name, rhs, path_vars, literal_vars, lib, protected=()):
    """Apply one supported assignment using the values visible before it."""
    if name in protected:
        return
    path_vars.pop(name, None)
    literal_vars.pop(name, None)
    if (
        len(rhs) >= 2
        and rhs[0] == "'"
        and rhs.endswith("'")
        and "'" not in rhs[1:-1]
    ):
        literal_vars[name] = rhs[1:-1]
        return
    value = _resolve_path_rhs(rhs, lib, path_vars)
    if value is not None:
        path_vars[name] = value


def variable_maps_by_line(text, lib, overrides):
    """Return sequential assignment maps before each logical line."""
    maps = {}
    path_vars = dict(overrides)
    literal_vars = {}
    for lineno, line in join_logical_lines(text):
        maps[lineno] = (dict(path_vars), dict(literal_vars))
        match = _ASSIGNMENT_RE.match(line)
        if match is None:
            continue
        _apply_assignment(
            match.group(1),
            match.group(2).strip(),
            path_vars,
            literal_vars,
            lib,
            protected=set(overrides),
        )
    return maps


def _resolve_path_rhs(rhs, lib, path_vars):
    # Strip surrounding quotes if the whole RHS is quoted.
    r = rhs
    if len(r) >= 2 and r[0] == '"' and r.endswith('"'):
        r = r[1:-1]
    elif len(r) >= 2 and r[0] == "'" and r.endswith("'"):
        return None  # single-quoted -> a literal var, not a path
    # `$OTHER` alone
    m = _VARREF.match(r)
    if m:
        return path_vars.get(m.group(1))
    # `$LIB/rel` / `${LIB}/rel` / `$OTHER/rel` — the shared inline var-prefixed
    # path grammar, so this and resolve_arg's inline target resolution stay one
    # owner (issue #757).
    inline = _resolve_inline_var_path(r, lib, path_vars)
    if inline is not None:
        return inline
    # A bare literal path (no `$`).
    if "$" not in r and "(" not in r and r:
        # Only treat as a path if it looks like one (has a slash or extension).
        if "/" in r or "." in r:
            return r if os.path.isabs(r) else os.path.normpath(os.path.join(lib or ".", r))
    return None


_INLINE_LIB = re.compile(r"^\$\{?LIB\}?/(.*)$")
_INLINE_VAR = re.compile(r"^\$\{?(\w+)\}?/(.*)$")


def _resolve_inline_var_path(s, lib, path_vars):
    """Resolve an inline var-prefixed path reference — ``$LIB/rel`` / ``${LIB}/rel``,
    or ``$OTHER/rel`` / ``${OTHER}/rel`` where OTHER is a known path var — to a
    filesystem path, or None when it is neither shape (or the referenced var is
    unknown).

    This is the inline counterpart of the whole-``$VAR`` resolution ``resolve_arg``
    already performs. A pin's target file argument is frequently written inline —
    ``devflow_module_pin_unique "…" '…' "$LIB/../CLAUDE.md"`` — rather than as a
    pre-assigned whole-``$VAR`` token, and without this an inline target stays
    unresolved: surfaced on stderr but never asserted, i.e. silently exempt from the
    wrapped / pin-in-comment meta-guards while the guards still read rc 0 (issue
    #757). Applied only for ``want_path`` targets, never for pinned literals, so
    literal resolution is unchanged."""
    m = _INLINE_LIB.match(s)
    if m and lib is not None:
        return os.path.normpath(os.path.join(lib, m.group(1)))
    m = _INLINE_VAR.match(s)
    if m and m.group(1) in path_vars:
        return os.path.normpath(os.path.join(path_vars[m.group(1)], m.group(2)))
    return None


def resolve_arg(segments, literal_vars, path_vars, want_path, lib=None):
    """Resolve one argument's segments to a string, or None if unresolvable.

    want_path=True resolves against path_vars (target file); otherwise against
    literal_vars (the pinned literal). ``lib`` enables inline ``$LIB/rel`` /
    ``$VAR/rel`` path resolution for ``want_path`` targets (issue #757).
    """
    out = []
    for kind, val in segments:
        if kind == "sq":
            out.append(val)
        elif kind == "dq":
            # Neutralize backslash-escaped metacharacters first: `\$`, `` \` ``, `\"`,
            # `\\` are literal, not interpolation. Only an UNescaped `$`/backtick that
            # remains is real interpolation (a whole `$VAR`, or — for a path target —
            # an inline `$VAR/rel` prefix).
            NUL, TCK = "\x00d", "\x00t"
            neutral = (
                val.replace("\\\\", "\x00b")
                .replace("\\$", NUL)
                .replace("\\`", TCK)
                .replace('\\"', '"')
            )
            if "$" in neutral or "`" in neutral:
                m = _VARREF.match(neutral)
                if m:
                    repl = (path_vars if want_path else literal_vars).get(m.group(1))
                    if repl is None:
                        return None
                    out.append(repl)
                    continue
                inline = _resolve_inline_var_path(neutral, lib, path_vars) if want_path else None
                if inline is None:
                    return None
                out.append(inline)
            else:
                out.append(neutral.replace(NUL, "$").replace(TCK, "`").replace("\x00b", "\\"))
        else:  # bare
            m = _VARREF.match(val)
            if m:
                repl = (path_vars if want_path else literal_vars).get(m.group(1))
                if repl is None:
                    return None
                out.append(repl)
            elif "$" in val:
                inline = _resolve_inline_var_path(val, lib, path_vars) if want_path else None
                if inline is None:
                    return None
                out.append(inline)
            else:
                out.append(val)
    return "".join(out)


# ── call-site extraction ────────────────────────────────────────────────────
def extract_pins(text, lib, overrides):
    """Yield dicts for each pin call site: resolved (literal, file) or unresolved."""
    maps_by_line = variable_maps_by_line(text, lib, overrides)
    for lineno, line in join_logical_lines(text):
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        first = stripped.split(None, 1)
        if not first or first[0] not in HELPERS:
            continue
        toks = tokenize(stripped)
        if not toks or "".join(v for _, v in toks[0]) != first[0]:
            continue
        path_vars, literal_vars = maps_by_line[lineno]
        args = toks[1:]
        lit_idx, file_idx, default_file = HELPERS[first[0]]
        if lit_idx >= len(args):
            # A pin call with too few args to carry its literal — malformed, but still
            # surfaced as unresolved (literal=None) rather than silently dropped, honoring
            # the "never silently skipped" contract.
            yield {"lineno": lineno, "helper": first[0], "literal": None, "file": None}
            continue
        literal = resolve_arg(args[lit_idx], literal_vars, path_vars, want_path=False, lib=lib)
        if file_idx < len(args):
            fpath = resolve_arg(args[file_idx], literal_vars, path_vars, want_path=True, lib=lib)
        elif default_file is not None:
            fpath = path_vars.get(default_file)
        else:
            fpath = None
        yield {
            "lineno": lineno,
            "helper": first[0],
            "literal": literal,
            "file": fpath,
        }


# ── comment / rendering analysis of a target file ───────────────────────────
def hash_comment_regions(lines):
    """Return list of (lineno, comment_text) for #-comment regions, quote-aware."""
    out = []
    for i, line in enumerate(lines, 1):
        insq = indq = False
        start = None
        j = 0
        while j < len(line):
            c = line[j]
            if c == "\\" and (insq or indq):
                j += 2
                continue
            if c == "'" and not indq:
                insq = not insq
            elif c == '"' and not insq:
                indq = not indq
            elif (
                c == "#"
                and not insq
                and not indq
                and (j == 0 or line[j - 1] in " \t")
            ):
                # A `#` starts a shell/py comment only at a word boundary (line start
                # or after whitespace) — mirroring tokenize()'s `not cur` rule. Keying
                # on any unquoted `#` misclassified a mid-word `#` (e.g. `url#anchor`)
                # as a comment start, moving operative text into the "comment" region
                # and making a real collision go UNFLAGGED (a fail-open in the guard
                # direction).
                start = j
                break
            j += 1
        if start is not None:
            out.append((i, line[start:]))
    return out


def md_comment_text(text):
    return "\n".join(re.findall(r"<!--(.*?)-->", text, flags=re.DOTALL))


def md_fenced_hash_comment_spans(text):
    """Return {lineno: comment_text} for #-comment regions inside fenced code
    blocks (``` / ~~~, language-tagged or indented) of a markdown target.

    The #375 .md arm scanned only HTML ``<!-- … -->`` regions; a pin literal
    quoted in a ``#`` comment inside a ```` ```bash ```` fence of a skill bundle
    was folded into the operative "outside" text, so a #370-class count-inflation
    collision there went unflagged (issue #394). Extracting these fenced ``#``
    comments lets the .md arm subtract them from "outside" symmetrically with the
    .sh/.py arm, so such a collision is flagged while a literal living ONLY in a
    fenced comment (the ``lit in outside`` conjunct) still is not.

    Fence tracking mirrors CommonMark's opener/closer rules enough for this use:
    an opening fence is a line whose first non-space run is >=3 backticks or
    tildes (a backtick opener's info string may not itself contain a backtick);
    the matching closer is the same marker char, at least as long, with only
    whitespace after it. Language-tagged fences and fences indented up to 3
    spaces are handled; a run indented >=4 spaces is CommonMark *indented code*,
    NOT a fence, so it is deliberately not treated as a fence marker — otherwise
    a deeply-indented ``` in prose would spuriously open a never-closed fence and
    fold every following operative ``#``-line into the comment region, a
    fail-open that could hide a real #370-class collision (issue #394 review).
    The fence markers themselves are never treated as content.

    An UNTERMINATED fence fails closed (issue #394 review): a fence opener that
    never meets a matching closer before EOF is suspect (a stray/unbalanced ```
    in a malformed target), so its content lines are discarded rather than folded
    into the comment region — otherwise every following operative ``#``-line (an
    ATX heading, say) would be stripped out of "outside", masking a real
    #370-class collision. Only lines inside a PROPERLY CLOSED fence are trusted.
    """
    lines = text.split("\n")
    fence = None  # (char, length) while inside a fence, else None
    inside = []  # (lineno, line) content lines strictly inside fences
    committed = 0  # inside[:committed] are lines from PROPERLY CLOSED fences
    for i, line in enumerate(lines, 1):
        # 0-3 leading spaces only (>=4 is indented code, not a fence marker).
        m = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line)
        if fence is None:
            # A backtick opener's info string must not contain a backtick.
            if m and not (m.group(1)[0] == "`" and "`" in m.group(2)):
                fence = (m.group(1)[0], len(m.group(1)))
            continue
        if (
            m
            and m.group(1)[0] == fence[0]
            and len(m.group(1)) >= fence[1]
            and m.group(2).strip() == ""
        ):
            fence = None
            committed = len(inside)  # this fence closed cleanly — trust its lines
            continue
        inside.append((i, line))
    # Fail closed on an UNTERMINATED trailing fence (issue #394 review): a stray or
    # unbalanced opener that never meets a closer is suspect, so drop its content
    # rather than fold every following operative `#`-line out of "outside" and mask a
    # real #370-class collision. Only PROPERLY CLOSED fences' lines are trusted.
    if fence is not None:
        inside = inside[:committed]
    spans = {}
    for idx, ctext in hash_comment_regions([ln for _, ln in inside]):
        spans[inside[idx - 1][0]] = ctext
    return spans


def normalize_ws(s):
    return " ".join(s.split())


def multiliteral_help_renderings(text):
    """Yield the concatenated rendering of each multi-literal argparse help=.

    Detects `help=` followed by two or more adjacent string literals (Python's
    implicit string concatenation, optionally parenthesized / across lines).
    """
    out = []
    for m in re.finditer(r"help\s*=\s*\(?", text):
        i = m.end()
        lits = []
        while True:
            # skip whitespace and line continuations
            while i < len(text) and text[i] in " \t\r\n\\":
                i += 1
            if i >= len(text) or text[i] not in "'\"":
                break
            q = text[i]
            # handle triple quotes
            if text[i : i + 3] == q * 3:
                end = text.find(q * 3, i + 3)
                if end == -1:
                    break
                lits.append(text[i + 3 : end])
                i = end + 3
            else:
                j = i + 1
                buf = []
                while j < len(text) and text[j] != q:
                    if text[j] == "\\" and j + 1 < len(text):
                        buf.append(text[j + 1])
                        j += 1
                    else:
                        buf.append(text[j])
                    j += 1
                lits.append("".join(buf))
                i = j + 1
        if len(lits) >= 2:
            out.append("".join(lits))
    return out


# ── the two guards ──────────────────────────────────────────────────────────
def _target_ext(path, md_targets):
    """Extension used to pick the comment syntax; a `--md`-flagged target (e.g. the
    extensionless mktemp'd skill bundle, which is markdown) is treated as `.md`."""
    if path in md_targets:
        return ".md"
    return os.path.splitext(path)[1]


def _strip_line_spans(lines, spans):
    """Remove each line-keyed comment suffix from `lines`, returning the joined
    "outside-comments" text. Shared by the hash arm and the .md fenced-#-comment
    arm (issue #394) so the two subtractions stay in lockstep rather than being
    two hand-maintained copies of the same off-by-one-prone slice."""
    return "\n".join(
        (line[: len(line) - len(spans[i])] if i in spans else line)
        for i, line in enumerate(lines, 1)
    )


def _lint_view(path, ext, cache):
    """Memoized per-target-file comment analysis (read + comment regions + the
    outside-comments text). Many pins share a target, so this is derived once per
    file rather than once per pin."""
    v = cache.get(path)
    if v is not None:
        return v
    ftext, err = _read_target(path)
    if err is not None:
        v = ("unreadable", err, None)
        cache[path] = v
        return v
    if ext in COMMENT_HASH_EXTS:
        lines = ftext.split("\n")
        comment_spans = {cln: ctext for cln, ctext in hash_comment_regions(lines)}
        outside = _strip_line_spans(lines, comment_spans)
        v = ("hash", comment_spans, outside)
    elif ext in COMMENT_MD_EXTS:
        # Comment regions of a .md target are BOTH its HTML <!-- … --> spans AND
        # the #-comments inside its fenced code blocks (issue #394). Union them
        # into `comments`, and subtract both from `outside` symmetrically so a
        # literal living only in a fenced # comment is removed from "outside"
        # (preserving the `lit in outside` conjunct) exactly as the .sh/.py arm.
        fenced_spans = md_fenced_hash_comment_spans(ftext)
        comment_text = md_comment_text(ftext)
        if fenced_spans:
            comment_text = comment_text + "\n" + "\n".join(fenced_spans.values())
        without_fenced = _strip_line_spans(ftext.split("\n"), fenced_spans)
        outside = re.sub(r"<!--.*?-->", "", without_fenced, flags=re.DOTALL)
        v = ("md", comment_text, outside)
    else:
        v = ("none", None, None)
    cache[path] = v
    return v


def _wrapped_view(path, cache):
    """Memoized per-target-file wrapped-literal analysis (lines + whitespace-normalized
    whole file + normalized multi-literal help= renderings). Derived once per file."""
    v = cache.get(path)
    if v is not None:
        return v
    ftext, err = _read_target(path)
    if err is not None:
        v = ("unreadable", err, None)
        cache[path] = v
        return v
    helps = [normalize_ws(r) for r in multiliteral_help_renderings(ftext)] if path.endswith(".py") else []
    v = (ftext.split("\n"), normalize_ws(ftext), helps)
    cache[path] = v
    return v


def _emit(sink, line):
    """The single stdout chokepoint for every finding line on a ``--strict``-covered
    path (issue #687). Appends to ``sink`` — so ``--strict`` can key rc 3 on
    "at least one line was written to stdout" — and prints the line unchanged, so
    the stdout/stderr bytes are byte-identical with and without ``--strict``.

    Defined OUTSIDE the ``run_lint`` … end-of-``_emit_wrapped_or_absent`` guard
    range that ``lib/test/run.sh``'s issue-#687 emit-helper guard anchors over, so
    the guard's ``grep -cE`` count of raw stdout-writing forms inside that range
    stays 0. A future finding arm on a covered path MUST route through this helper
    (never a bare ``print(`` / ``sys.stdout.write`` / ``os.write(1``) or the guard
    goes RED; informational output on a covered path must go to ``sys.stderr``."""
    sink.append(line)
    print(line)


def run_lint(pin_source, lib, overrides, md_targets, strict=False):
    text = _read(pin_source)
    unresolved = 0
    resolved = 0
    collisions = []
    view_cache = {}
    sink = []
    for pin in extract_pins(text, lib, overrides):
        if pin["literal"] is None or pin["file"] is None:
            unresolved += 1
            sys.stderr.write(
                f"UNRESOLVED\t{pin_source}:{pin['lineno']}\t{pin['helper']}\t"
                f"literal={'?' if pin['literal'] is None else 'ok'}\t"
                f"file={'?' if pin['file'] is None else pin['file']}\n"
            )
            continue
        if not os.path.isfile(pin["file"]):
            unresolved += 1
            sys.stderr.write(
                f"UNRESOLVED\t{pin_source}:{pin['lineno']}\t{pin['helper']}\t"
                f"target-missing={pin['file']}\n"
            )
            continue
        ext = _target_ext(pin["file"], md_targets)
        kind, comments, outside = _lint_view(pin["file"], ext, view_cache)
        if kind == "unreadable":
            unresolved += 1
            sys.stderr.write(
                f"UNRESOLVED\t{pin_source}:{pin['lineno']}\t{pin['helper']}\t"
                f"target-unreadable={pin['file']} ({comments})\n"
            )
            continue
        resolved += 1
        lit = pin["literal"]
        # The defect (#370): a comment occurrence that COEXISTS with an operative
        # occurrence — it inflates the count / can mask a refactored-away operative
        # site. A literal that lives ONLY in a comment (an SPDX-header pin, a
        # deliberately comment-targeted contract) is the pin's intended home, not the
        # count-inflation defect, so it is NOT flagged. Hence: flag only when the
        # literal appears in a comment AND ALSO outside every comment region.
        if kind == "hash":
            in_comment_line = next((cln for cln, ctext in comments.items() if lit in ctext), None)
            if in_comment_line is not None and lit in outside:
                collisions.append((pin, in_comment_line))
        elif kind == "md":
            if lit in comments and lit in outside:
                collisions.append((pin, None))
    for pin, cln in collisions:
        loc = f":{cln}" if cln else ""
        _emit(sink, f"COLLISION\t{pin['file']}{loc}\t{pin['helper']}@{pin_source}:{pin['lineno']}\t{pin['literal']}")
    sys.stderr.write(f"UNRESOLVED-COUNT\t{unresolved}\n")
    sys.stderr.write(f"RESOLVED-COUNT\t{resolved}\n")
    return 3 if strict and sink else 0


# ── #661 relocation diagnosis ───────────────────────────────────────────────
def _git_ls_files():
    """Enumerate tracked files with the granted ``git ls-files``. Returns
    (paths, None) on success or (None, reason) fail-closed on any error / empty
    output — the caller must NOT collapse a failed enumeration to "deleted"."""
    try:
        res = subprocess.run(
            ["git", "ls-files", "-z"], capture_output=True, text=True, check=False
        )
    except (OSError, UnicodeDecodeError) as exc:
        # UnicodeDecodeError (a ValueError, NOT an OSError) can surface from text=True
        # eager decoding of a non-UTF-8 tracked filename; catch it too so the docstring's
        # "fail-closed on any error" holds rather than crashing the scan.
        return None, f"git-ls-files-error:{type(exc).__name__}"
    if res.returncode != 0:
        return None, f"git-ls-files-rc:{res.returncode}"
    paths = [p for p in res.stdout.split("\0") if p]
    if not paths:
        return None, "git-ls-files-empty"
    return paths, None


def resolve_reloc_search_set(explicit_file):
    """Resolve the relocation search set. An explicit ``--reloc-search-set`` file
    (the git-free self-test path) wins; otherwise ``git ls-files``. A file that is
    unreadable, or a raw enumeration that fails or is empty, returns (None, reason)
    so the ABSENT branch fails closed rather than reporting a false deletion."""
    if explicit_file is not None:
        # Read through _read_target, which catches (OSError, UnicodeDecodeError):
        # a non-UTF-8 --reloc-search-set file raises UnicodeDecodeError (a ValueError,
        # NOT an OSError), and a bare `except OSError` would let it escape and crash
        # the scan instead of taking this docstring's fail-closed (None, reason) arm.
        raw, reason = _read_target(explicit_file)
        if reason is not None:
            return None, f"search-set-unreadable:{reason}"
        paths = [ln.strip() for ln in raw.splitlines() if ln.strip()]
        if not paths:
            return None, "search-set-empty"
        return paths, None
    return _git_ls_files()


def _reloc_excluded(path, exclude_tokens):
    """A search-set path is excluded when any exclude token is a substring of it
    (the distinctive ``.devflow/vendor/`` / ``.devflow/tmp/`` trees, or a
    pin-source path/prefix) OR resolves to the same file (abspath-equal). Substring
    matches a temp-dir stand-in like ``/tmp/xxx/.devflow/vendor/copy.md`` against the
    same token a repo-relative ``.devflow/vendor/…`` path does; the abspath-equality
    arm is load-bearing for the pin-source auto-exclude, because ``git ls-files``
    emits **repo-relative** paths (``lib/test/run.sh``) while the pin-source token is
    the **absolute** ``$LIB/test/run.sh`` — a substring test alone never matches those
    two spellings, so without abspath-equality the auto-exclude would silently no-op
    and a deleted pin's literal would self-match its own declaration in run.sh."""
    apath = os.path.abspath(path)
    for tok in exclude_tokens:
        if not tok:
            continue
        if tok in path or apath == os.path.abspath(tok):
            return True
    return False


def _literal_resolves_in(lit, nlit, path, cache):
    """Tri-state: ``True`` when the pin literal resolves in a candidate file (on a
    single line, in the whitespace-normalized rendering — a wrapped-adjacent-literal
    destination, #375 — or in a multi-literal argparse help= rendering), ``False``
    when the file was read but does not contain it, and ``None`` when the candidate
    is UNREADABLE. The None arm is load-bearing: a swallowed read error on the very
    file a literal moved into would otherwise let ``diagnose_relocation`` report a
    false ``deleted`` — the AC5 masquerade at per-candidate granularity — so the
    caller must surface unreadable candidates rather than treat them as 'not here'."""
    view = _wrapped_view(path, cache)
    if view[0] == "unreadable":
        return None
    lines, nfile, helps = view
    if any(lit in ln for ln in lines):
        return True
    if nlit and nlit in nfile:
        return True
    return bool(nlit and any(nlit in h for h in helps))


def diagnose_relocation(lit, nlit, target, search_paths, exclude_tokens, cache):
    """Given the resolved (non-None) search set, return
    ``(sorted_dests, unreadable_paths)``: the files (excluding the
    pin-source/vendor/tmp set and the target itself) where the literal resolves, and
    the candidates that could not be read. An empty ``dests`` with an empty
    ``unreadable`` means a genuine deletion; an empty ``dests`` with a non-empty
    ``unreadable`` means the diagnosis is INCOMPLETE — the caller must not claim a
    clean deletion over swallowed read errors (fail-closed, AC5 spirit)."""
    dests = []
    unreadable = []
    for path in search_paths:
        if path == target or _reloc_excluded(path, exclude_tokens):
            continue
        resolved = _literal_resolves_in(lit, nlit, path, cache)
        if resolved is None:
            unreadable.append(path)
        elif resolved:
            dests.append(path)
    return sorted(set(dests)), sorted(set(unreadable))


def run_wrapped(pin_source, lib, overrides, md_targets,
                reloc=False, reloc_search_file=None, reloc_exclude=None,
                strict=False):
    text = _read(pin_source)
    unresolved = 0
    resolved = 0
    view_cache = {}
    sink = []
    # Resolve the relocation search set ONCE (issue #661) — only when --reloc is on.
    # A resolution failure is carried as (None, reason): the ABSENT branch then reports
    # "relocation diagnosis unavailable" and never a false "deleted". The pin-source file
    # is auto-excluded (a pin literal is present in its own declaration by construction),
    # alongside the always-on vendor/tmp trees and any --reloc-exclude substring token.
    reloc_paths, reloc_err = (None, None)
    reloc_excludes = ()
    if reloc:
        reloc_paths, reloc_err = resolve_reloc_search_set(reloc_search_file)
        reloc_excludes = (
            (pin_source,) + tuple(RELOC_DEFAULT_EXCLUDES) + tuple(reloc_exclude or ())
        )
    for pin in extract_pins(text, lib, overrides):
        if pin["literal"] is None or pin["file"] is None:
            unresolved += 1
            sys.stderr.write(
                f"UNRESOLVED\t{pin_source}:{pin['lineno']}\t{pin['helper']}\t"
                f"literal={'?' if pin['literal'] is None else 'ok'}\t"
                f"file={'?' if pin['file'] is None else pin['file']}\n"
            )
            continue
        if not os.path.isfile(pin["file"]):
            unresolved += 1
            sys.stderr.write(
                f"UNRESOLVED\t{pin_source}:{pin['lineno']}\t{pin['helper']}\t"
                f"target-missing={pin['file']}\n"
            )
            continue
        lines, nfile, helps = _wrapped_view(pin["file"], view_cache)
        if lines == "unreadable":
            unresolved += 1
            sys.stderr.write(
                f"UNRESOLVED\t{pin_source}:{pin['lineno']}\t{pin['helper']}\t"
                f"target-unreadable={pin['file']} ({nfile})\n"
            )
            continue
        resolved += 1
        lit = pin["literal"]
        if any(lit in ln for ln in lines):
            # The phrase IS on a line; nothing to flag.
            continue
        # occurs on no single line: distinguish a multi-literal help= (needs the
        # rendered surface), a whitespace-wrapped phrase, and a genuinely-absent one.
        nlit = normalize_ws(lit)
        if nlit and any(nlit in h for h in helps):
            _emit(
                sink,
                f"HELP\t{pin['file']}\t{pin['helper']}@{pin_source}:{pin['lineno']}\t"
                f"pin targets a multi-literal argparse help= string; pin the RENDERED "
                f"surface (captured --help output / real stderr), not the source\t{lit}"
            )
            continue
        _emit_wrapped_or_absent(
            pin, pin_source, nlit, nfile, lit,
            reloc=reloc, reloc_paths=reloc_paths, reloc_err=reloc_err,
            reloc_excludes=reloc_excludes, cache=view_cache, sink=sink,
        )
    sys.stderr.write(f"UNRESOLVED-COUNT\t{unresolved}\n")
    sys.stderr.write(f"RESOLVED-COUNT\t{resolved}\n")
    return 3 if strict and sink else 0


def _emit_wrapped_or_absent(pin, pin_source, nlit, nfile, lit, sink,
                            reloc=False, reloc_paths=None, reloc_err=None,
                            reloc_excludes=(), cache=None):
    site = f"{pin['helper']}@{pin_source}:{pin['lineno']}"
    if nlit and nlit in nfile:
        _emit(
            sink,
            f"WRAPPED\t{pin['file']}\t{site}\t"
            f"phrase occurs on NO single line but IS present in the whitespace-normalized "
            f"rendering — a wrapped-literal blind spot; pin the rendered surface\t{lit}"
        )
        return
    if not reloc:
        # Relocation diagnosis off — the pre-#661 ABSENT emit, byte-identical.
        _emit(
            sink,
            f"ABSENT\t{pin['file']}\t{site}\t"
            f"phrase absent from the target entirely (not merely wrapped)\t{lit}"
        )
        return
    if reloc_paths is None:
        # The search set could not be enumerated (git ls-files failed/empty, or an
        # unreadable --reloc-search-set). Fail closed: report unavailability on stderr
        # and NEVER collapse to "deleted" — a failed enumeration is not evidence of
        # deletion. stdout still carries an ABSENT line so a real absent pin stays RED.
        sys.stderr.write(
            f"RELOC-UNAVAILABLE\t{pin['file']}\t{site}\t{reloc_err}\n"
        )
        _emit(
            sink,
            f"ABSENT\t{pin['file']}\t{site}\t"
            f"phrase absent from the target entirely; relocation diagnosis unavailable "
            f"({reloc_err})\t{lit}"
        )
        return
    dests, unreadable = diagnose_relocation(
        lit, nlit, pin["file"], reloc_paths, reloc_excludes, cache or {}
    )
    if dests:
        _emit(
            sink,
            f"RELOCATED\t{pin['file']}\t{site}\t"
            f"relocated to {', '.join(dests)}; update the pin target\t{lit}"
        )
    elif unreadable:
        # Fail closed: candidates could not be read, so the literal may have moved into
        # one of them — do NOT claim a clean deletion. Surface each unreadable candidate
        # on stderr and say the diagnosis is incomplete (AC5 masquerade guard).
        for path in unreadable:
            sys.stderr.write(f"RELOC-CANDIDATE-UNREADABLE\t{pin['file']}\t{site}\t{path}\n")
        _emit(
            sink,
            f"ABSENT\t{pin['file']}\t{site}\t"
            f"phrase absent from the target; relocation diagnosis INCOMPLETE "
            f"({len(unreadable)} candidate(s) unreadable — not a confirmed deletion)\t{lit}"
        )
    else:
        _emit(
            sink,
            f"ABSENT\t{pin['file']}\t{site}\t"
            f"phrase absent from the target AND from the scoped tracked-file set — "
            f"deleted (not found anywhere)\t{lit}"
        )


# ── #666 mutation-routing: the behavioral-fix-pin declaration gate ────────────
# The mutation-taking helpers prove a pin is non-vacuous; NOTHING proved a pin
# reached them. A behavioral-fix pin authored as a plain `assert_pin_unique` is
# byte-indistinguishable from a legitimate structural pin, so a framing-only guard
# ships silently. This diff-scoped, fail-closed gate makes the author STATE the
# classification: a pin call site the change ADDS whose helper is not
# mutation-taking must either route through a mutation-taking helper or carry an
# explicit typed structural declaration. Sites the change does not touch are
# out of scope by construction — no backfill of the ~1372 existing pins.

# Helpers that MUST declare (non-mutation-taking pins) — complete by construction.
REQUIRED_DECLARATION_HELPERS = frozenset(
    {
        "assert_pin_unique",
        "assert_pin_red_on_removal",
        "devflow_module_pin_unique",
        "devflow_module_pin_present",
    }
)
# Mutation-taking helpers — never draw a finding (they already prove non-vacuity).
# assert_count_red_under is deliberately NOT in HELPERS (see the note beside HELPERS);
# it is mutation-taking, so even if it were extracted it would land in this set.
MUTATION_TAKING_HELPERS = frozenset(
    {"assert_pin_red_under", "devflow_module_pin_red_under", "assert_count_red_under"}
)
# Count-based guards — exempt by helper, grounded in the phase-2 §2.3 scope limiter
# ("does not apply to count-based guards"). They draw no finding.
COUNT_HELPERS = frozenset({"pin_count", "devflow_module_pin_count"})

# The declaration marker is recognized only in a real comment region; a quoted
# substring never exempts the site.
STRUCTURAL_PIN_OK_MARKER = "# structural-pin-ok:"

STRUCTURAL_PIN_CATEGORIES = frozenset(
    {
        "helper-contract",
        "schema-config-vocabulary",
        "security-credential-boundary",
        "machine-sentinel-provenance",
        "routing-dispatch-contract",
        "lifecycle-state-transition",
        "generated-artifact-identity",
        "cross-file-phase-contract",
    }
)

# This population is intentionally committed and independent of the registry. The
# production gate compares the two sets exactly, so registering a new focused module
# without adding it here fails closed instead of silently leaving its pins unscanned.
AUDITED_PIN_SOURCES = frozenset(
    {
        "lib/test/run.sh",
        "lib/test/modules/workflow-flight-recorder.sh",
        "lib/test/modules/review-and-fix-contract.sh",
        "lib/test/modules/create-issue-contract.sh",
        "lib/test/modules/capability-profiles.sh",
        "lib/test/modules/regenerate-artifacts.sh",
        "lib/test/modules/installer-wiring.sh",
        "lib/test/modules/harness-python-guards.sh",
        "lib/test/modules/prompt-extension-reader.sh",
        "lib/test/modules/review-trigger-helpers.sh",
        "lib/test/modules/review-stall-backstop.sh",
        "lib/test/modules/experiment-records.sh",
    }
)

_DEF_LINE_RE = re.compile(r"^\w+\s*\(\)")


class StructuralDeclaration(NamedTuple):
    category: str
    rationale: str


class GuardSite(NamedTuple):
    source_path: str
    line_start: int
    line_end: int
    family: str
    helper: str | None
    literal: str | None
    target_path: str | None
    declaration: StructuralDeclaration | None
    declaration_error: str | None


class FilePatch(NamedTuple):
    old_path: str | None
    new_path: str | None
    added_lines: frozenset[int]
    deleted_lines: frozenset[int]


class InfrastructureError(RuntimeError):
    """The blocking gate could not establish the population or comparison."""


_FUNCTION_START_RE = re.compile(r"(?m)^([A-Za-z_]\w*)\s*\(\)\s*\{")
_POSITIONAL_RE = re.compile(r"^\$\{?([1-9][0-9]*)\}?$")
_ALL_POSITIONAL_RE = re.compile(r"^\$\{?@\}?$")


def _function_definitions(text):
    """Return quote-, comment-, escape-, and parameter-aware function spans."""
    definitions = {}
    for match in _FUNCTION_START_RE.finditer(text):
        depth = 1
        parameter_depth = 0
        quote = None
        escaped = False
        index = match.end()
        body_start = index
        while index < len(text):
            char = text[index]
            if escaped:
                escaped = False
                index += 1
                continue
            if char == "\\" and quote != "'":
                escaped = True
                index += 1
                continue
            if quote:
                if char == quote:
                    quote = None
                index += 1
                continue
            if char in ("'", '"'):
                quote = char
                index += 1
                continue
            if char == "#" and (
                index == body_start or text[index - 1].isspace()
            ):
                newline = text.find("\n", index)
                index = len(text) if newline < 0 else newline + 1
                continue
            if char == "$" and index + 1 < len(text) and text[index + 1] == "{":
                parameter_depth += 1
                index += 2
                continue
            if char == "}" and parameter_depth:
                parameter_depth -= 1
                index += 1
                continue
            if char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    definitions[match.group(1)] = (
                        text[body_start:index],
                        text.count("\n", 0, match.start()) + 1,
                        text.count("\n", 0, index) + 1,
                    )
                    break
            index += 1
    return definitions


def _function_bodies(text):
    return {
        name: definition[0]
        for name, definition in _function_definitions(text).items()
    }


def _token_value(token):
    return "".join(value for _, value in token)


def _helper_call(tokens, helper_specs):
    """Return (token-index, helper-name) for the first executable helper token.

    Shell control prefixes such as ``if`` and ``!`` remain separate bare
    tokens, so scanning the token stream covers guarded calls without treating
    a helper name inside an assertion label as executable.
    """
    command_prefixes = {
        "if", "then", "elif", "while", "until", "do", "!", "&&", "||", ";", "{"
    }
    assignment = re.compile(r"^[A-Za-z_]\w*=.*$")
    for index, token in enumerate(tokens):
        if not token or any(kind != "bare" for kind, _ in token):
            continue
        value = _token_value(token)
        if value not in helper_specs:
            continue
        before = [_token_value(item) for item in tokens[:index]]
        executable = (
            not before
            or before[-1] in command_prefixes
            or before[-1].endswith(";")
            or all(assignment.match(item) for item in before)
        )
        if executable:
            return index, value
    return None, None


def helper_specs_for_source(
    text, include_families=False, include_origins=False
):
    """Return built-in plus source-local wrapper helper specifications.

    A focused module may wrap the shared pin API. Enumerating function
    definitions independently of call spellings keeps those wrappers in the
    audited population. Wrappers are inferred from the supported positional or
    ``$@`` forwarding forms to an already-known helper; conventional
    ``*_pin_*`` wrappers provide the small fallback needed for wrappers
    implemented via lower-level counters (for example ``_raf_pin_unique``).
    """
    specs = dict(HELPERS)
    families = {name: _helper_family(name) for name in HELPERS}
    origins = {}
    bodies = _function_bodies(text)

    for _ in range(len(bodies) + 1):
        changed = False
        for name, body in bodies.items():
            if name in specs:
                continue
            for body_lineno, logical_line in join_logical_lines(body):
                tokens = tokenize(logical_line.strip())
                index, callee = _helper_call(tokens, specs)
                if callee is None:
                    continue
                args = tokens[index + 1 :]
                if len(args) == 1 and _ALL_POSITIONAL_RE.match(
                    _token_value(args[0]).rstrip(";")
                ):
                    specs[name] = specs[callee]
                    families[name] = families[callee]
                    origins[name] = body_lineno
                    changed = True
                    break
                splat_indexes = [
                    arg_index
                    for arg_index, arg in enumerate(args)
                    if _ALL_POSITIONAL_RE.match(
                        _token_value(arg).rstrip(";")
                    )
                ]
                lit_selector, file_index, default_file = specs[callee]
                if len(splat_indexes) > 1:
                    continue
                splat_index = splat_indexes[0] if splat_indexes else None
                if isinstance(lit_selector, int):
                    if splat_index is not None and lit_selector >= splat_index:
                        wrapper_lit_selector = lit_selector - splat_index
                    elif lit_selector >= len(args):
                        continue
                    else:
                        lit_token = args[lit_selector]
                        lit_ref = _POSITIONAL_RE.match(
                            _token_value(lit_token).rstrip(";")
                        )
                        if lit_ref is not None:
                            wrapper_lit_selector = int(lit_ref.group(1)) - 1
                        else:
                            fixed_literal = resolve_arg(
                                lit_token,
                                literal_vars={},
                                path_vars={},
                                want_path=False,
                            )
                            if fixed_literal is None:
                                continue
                            wrapper_lit_selector = fixed_literal
                else:
                    wrapper_lit_selector = lit_selector
                wrapper_file_index = 10**6
                wrapper_default = default_file
                if splat_index is not None and file_index >= splat_index:
                    wrapper_file_index = file_index - splat_index
                    wrapper_default = None
                elif file_index < len(args):
                    file_value = _token_value(args[file_index]).rstrip(";")
                    file_ref = _POSITIONAL_RE.match(file_value)
                    if file_ref is not None:
                        wrapper_file_index = int(file_ref.group(1)) - 1
                        wrapper_default = None
                    else:
                        var_ref = _VARREF.match(file_value)
                        if var_ref is not None:
                            wrapper_default = var_ref.group(1)
                specs[name] = (
                    wrapper_lit_selector,
                    wrapper_file_index,
                    wrapper_default,
                )
                families[name] = families[callee]
                origins[name] = body_lineno
                changed = True
                break
        if not changed:
            break
    # A name-only fallback may identify static presence wrappers implemented
    # through lower-level counters, but it must never grant mutation/count
    # exemption without body-derived evidence.
    for name in bodies:
        if name not in specs and name.endswith(("_pin_unique", "_pin_present")):
            specs[name] = (1, 2, None)
            families[name] = "static-helper"
    if include_families and include_origins:
        return specs, families, origins
    if include_families:
        return specs, families
    return specs


def parse_structural_declaration(physical_lines):
    """Parse one real-comment declaration using the closed issue-810 grammar."""
    declarations = []
    for _, comment in hash_comment_regions(physical_lines):
        if STRUCTURAL_PIN_OK_MARKER not in comment:
            continue
        tail = comment.split(STRUCTURAL_PIN_OK_MARKER, 1)[1].strip()
        category, sep, rationale = tail.partition("--")
        category = category.strip()
        rationale = rationale.strip()
        if not sep or not category:
            return None, "missing structural category"
        if category not in STRUCTURAL_PIN_CATEGORIES:
            return None, f"unknown structural category: {category}"
        if not rationale:
            return None, "empty structural rationale"
        declarations.append(StructuralDeclaration(category, rationale))
    if not declarations:
        return None, "missing structural declaration"
    if len(declarations) != 1:
        return None, "multiple structural declarations"
    return declarations[0], None


def parse_diff(difftext):
    """Parse a unified diff into (added_set, deleted_lines).

    added_set: the set of added-line CONTENT strings (`+` lines, minus the `+++`
    file header), CR-stripped so a CRLF target still matches. run.sh appends every
    line of each untracked lib/test/ file as a synthetic `+` line, so the untracked
    corpus rides this same channel.
    deleted_lines: the ordered content of `-` lines (minus `---`), reconstructed
    into text and re-parsed for pin sites so a MOVED pin's deleted side is known.

    The diff is an external structured format this repo does not author, so its
    boundary shapes are handled explicitly: `+++`/`---` headers are never content;
    `@@` hunk headers, context lines (leading space), rename/binary stanzas and
    blank lines are ignored; a bare `+`/`-` adds/removes an empty line.
    """
    added = set()
    deleted = []
    for raw in difftext.split("\n"):
        if raw.startswith("+++") or raw.startswith("---"):
            continue
        if raw.startswith("+"):
            added.add(raw[1:].rstrip("\r"))
        elif raw.startswith("-"):
            deleted.append(raw[1:])
    return added, deleted


def _deleted_pin_literals(deleted_lines, lib, overrides):
    """Multiset (dict literal->count) of pin literals from DELETED pin sites whose
    helper is a pin helper that is NOT mutation-taking and whose literal resolved —
    the only deletions that can exempt an added site by move."""
    counts = {}
    text = "\n".join(deleted_lines)
    for pin in extract_pins(text, lib, overrides):
        lit = pin["literal"]
        if lit is None:
            continue
        if pin["helper"] in MUTATION_TAKING_HELPERS:
            # A deletion of a mutation-taking site never exempts (an added
            # non-mutation-taking site paired with it is the silent DOWNGRADE the
            # gate exists to catch).
            continue
        counts[lit] = counts.get(lit, 0) + 1
    return counts


def site_physical_lines(all_lines, start_lineno, logical_line):
    """The ORIGINAL physical lines of a call site (with trailing backslashes intact),
    so they match the diff's added-line content. `logical_line` carries one embedded
    newline per continuation join, so its newline count is (end - start)."""
    span = logical_line.count("\n")
    return all_lines[start_lineno - 1 : start_lineno + span]


def _has_structural_pin_ok(physical_lines):
    """True only for one valid typed declaration in a real comment region."""
    declaration, error = parse_structural_declaration(physical_lines)
    return declaration is not None and error is None


def run_mutation_routing(pin_source, lib, overrides, md_targets, diff_file):
    if diff_file is None:
        sys.stderr.write("MUTATION-ROUTING\tno --diff-file supplied; no findings emitted\n")
        return 0
    difftext, err = _read_target(diff_file)
    if err is not None:
        # An absent/unreadable diff file is reported, never silently suppressed —
        # but the run still exits 0 with no findings (run.sh owns the skip decision).
        sys.stderr.write(f"MUTATION-ROUTING\tdiff-file unreadable ({diff_file}: {err}); no findings emitted\n")
        return 0
    added, deleted_lines = parse_diff(difftext)
    del_literals = _deleted_pin_literals(deleted_lines, lib, overrides)

    text = _read(pin_source)
    all_lines = text.split("\n")
    path_vars, literal_vars = build_var_maps(text, lib, overrides)
    scanned = findings = exempted = 0
    for lineno, line in join_logical_lines(text):
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        first = stripped.split(None, 1)
        if not first or first[0] not in HELPERS:
            continue
        # A helper's own `name() {` definition line is not a call site (extract_pins
        # already skips it because `name()` != `name`, but assert it explicitly so a
        # future call-shape change cannot make the gate demand a marker on a def line).
        if _DEF_LINE_RE.match(stripped):
            continue
        helper = first[0]
        if helper not in REQUIRED_DECLARATION_HELPERS:
            # Mutation-taking and count-based helpers never draw a finding.
            continue
        toks = tokenize(stripped)
        if not toks or "".join(v for _, v in toks[0]) != helper:
            continue
        phys = site_physical_lines(all_lines, lineno, line)
        # In scope only when EVERY physical line of the site is in the added set.
        if not phys or any(pl.rstrip("\r") not in added for pl in phys):
            continue
        scanned += 1
        if _has_structural_pin_ok(phys):
            continue
        # Resolve the literal for move-exemption (a None literal is never exempt).
        args = toks[1:]
        lit_idx, _, _ = HELPERS[helper]
        literal = resolve_arg(args[lit_idx], literal_vars, path_vars, want_path=False) if lit_idx < len(args) else None
        if literal is not None and del_literals.get(literal, 0) > 0:
            del_literals[literal] -= 1  # one-to-one: consume this deletion
            exempted += 1
            continue
        findings += 1
        print(
            f"MUTATION-ROUTING\t{pin_source}:{lineno}\t{helper}\t"
            f"{literal if literal is not None else '<unresolved-literal>'}\t"
            f"added non-mutation pin site needs a mutation-taking helper or a "
            f"'# structural-pin-ok: <category> -- <non-empty rationale>' declaration"
        )
    sys.stderr.write(f"MUTATION-ROUTING-SCANNED\t{scanned}\n")
    sys.stderr.write(f"MUTATION-ROUTING-EXEMPTED-BY-MOVE\t{exempted}\n")
    sys.stderr.write(f"MUTATION-ROUTING-FINDINGS\t{findings}\n")
    return 0


def parse_unified_diff(difftext):
    """Return file- and hunk-coordinate-aware patches from a unified diff."""
    patches = []
    old_path = new_path = None
    added = set()
    deleted = set()
    old_lineno = new_lineno = None
    in_file = False
    old_header_seen = new_header_seen = False
    hunk_expected = None
    hunk_consumed = None
    saw_hunk = False
    metadata = set()
    last_hunk_line_was_content = False
    no_newline_marker_seen = False

    def finish_hunk():
        nonlocal hunk_expected, hunk_consumed, old_lineno, new_lineno
        nonlocal last_hunk_line_was_content, no_newline_marker_seen
        if hunk_expected is not None and hunk_consumed != hunk_expected:
            raise InfrastructureError(
                "malformed unified diff: truncated hunk "
                f"(expected {hunk_expected}, consumed {hunk_consumed})"
            )
        hunk_expected = hunk_consumed = None
        old_lineno = new_lineno = None
        last_hunk_line_was_content = False
        no_newline_marker_seen = False

    def finish():
        nonlocal old_path, new_path, added, deleted, in_file
        nonlocal old_header_seen, new_header_seen
        nonlocal saw_hunk, metadata
        finish_hunk()
        if in_file and (old_header_seen != new_header_seen):
            raise InfrastructureError(
                "malformed unified diff: file patch is missing ---/+++ header pair"
            )
        if in_file and old_header_seen and not saw_hunk:
            raise InfrastructureError(
                "malformed unified diff: ---/+++ headers have no hunk"
            )
        if in_file and old_header_seen and old_path is None and new_path is None:
            raise InfrastructureError(
                "malformed unified diff: both file paths are /dev/null"
            )
        if in_file and old_header_seen and new_header_seen:
            patches.append(
                FilePatch(old_path, new_path, frozenset(added), frozenset(deleted))
            )
        if in_file and not old_header_seen:
            complete_metadata_change = (
                {"old mode", "new mode"} <= metadata
                or {"rename from", "rename to"} <= metadata
                or {"copy from", "copy to"} <= metadata
                or "new file mode" in metadata
                or "deleted file mode" in metadata
            )
            if not complete_metadata_change:
                raise InfrastructureError(
                    "malformed unified diff: file stanza has no complete change record"
                )
        old_path = new_path = None
        added = set()
        deleted = set()
        in_file = False
        old_header_seen = new_header_seen = False
        saw_hunk = False
        metadata = set()

    def diff_path(value, prefix):
        value = value.split("\t", 1)[0]
        if value.startswith('"') != value.endswith('"'):
            raise InfrastructureError(
                "malformed unified diff: unterminated quoted path"
            )
        if value.startswith('"'):
            try:
                value = ast.literal_eval(value)
                if not isinstance(value, str):
                    raise ValueError("quoted path did not decode to a string")
                # Git C-quotes non-ASCII UTF-8 bytes as octal escapes. Python's
                # literal parser maps each escape to a Latin-1 code point, so
                # reconstruct the original byte sequence before path matching.
                value = value.encode("latin-1").decode("utf-8")
            except (SyntaxError, ValueError) as exc:
                raise InfrastructureError(
                    f"malformed unified diff: invalid quoted path ({exc})"
                ) from exc
            except (UnicodeEncodeError, UnicodeDecodeError):
                pass
        return re.sub(rf"^{prefix}/", "", value)

    for raw in difftext.splitlines():
        if raw.startswith("diff --git "):
            finish()
            in_file = True
            continue
        if not in_file:
            if raw.strip():
                raise InfrastructureError(
                    "malformed unified diff: content precedes diff --git header"
                )
            continue
        if hunk_expected is not None and hunk_consumed == hunk_expected:
            finish_hunk()
        if hunk_expected is not None:
            if raw == r"\ No newline at end of file":
                if not last_hunk_line_was_content or no_newline_marker_seen:
                    raise InfrastructureError(
                        "malformed unified diff: misplaced no-newline marker"
                    )
                no_newline_marker_seen = True
                last_hunk_line_was_content = False
                continue
            if raw.startswith("+"):
                added.add(new_lineno)
                new_lineno += 1
                hunk_consumed = (
                    hunk_consumed[0], hunk_consumed[1] + 1
                )
            elif raw.startswith("-"):
                deleted.add(old_lineno)
                old_lineno += 1
                hunk_consumed = (
                    hunk_consumed[0] + 1, hunk_consumed[1]
                )
            elif raw.startswith(" "):
                old_lineno += 1
                new_lineno += 1
                hunk_consumed = (
                    hunk_consumed[0] + 1, hunk_consumed[1] + 1
                )
            elif raw.startswith("@@ "):
                finish_hunk()
            else:
                raise InfrastructureError(
                    f"malformed unified diff: unexpected hunk line {raw!r}"
                )
            if hunk_expected is not None:
                last_hunk_line_was_content = True
                no_newline_marker_seen = False
                if (
                    hunk_consumed[0] > hunk_expected[0]
                    or hunk_consumed[1] > hunk_expected[1]
                ):
                    raise InfrastructureError(
                        "malformed unified diff: hunk exceeds declared size"
                    )
                continue
        if raw.startswith("--- "):
            if old_header_seen:
                raise InfrastructureError(
                    "malformed unified diff: duplicate --- header"
                )
            value = raw[4:].split("\t", 1)[0]
            old_path = None if value == "/dev/null" else diff_path(value, "a")
            old_header_seen = True
            continue
        if raw.startswith("+++ "):
            if not old_header_seen or new_header_seen:
                raise InfrastructureError(
                    "malformed unified diff: invalid +++ header ordering"
                )
            value = raw[4:].split("\t", 1)[0]
            new_path = None if value == "/dev/null" else diff_path(value, "b")
            new_header_seen = True
            continue
        if raw.startswith("@@ "):
            match = re.match(
                r"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@",
                raw,
            )
            if match is None or not old_header_seen or not new_header_seen:
                raise InfrastructureError(
                    f"malformed unified diff: invalid hunk header {raw!r}"
                )
            old_lineno = int(match.group(1))
            new_lineno = int(match.group(3))
            hunk_expected = (
                int(match.group(2) or 1),
                int(match.group(4) or 1),
            )
            hunk_consumed = (0, 0)
            saw_hunk = True
            continue
        if not raw and saw_hunk:
            continue
        if old_header_seen or new_header_seen:
            raise InfrastructureError(
                f"malformed unified diff: unexpected post-header line {raw!r}"
            )
        metadata_patterns = (
            ("index", r"index [0-9a-fA-F]+\.\.[0-9a-fA-F]+(?: [0-7]{6})?"),
            ("new file mode", r"new file mode [0-7]{6}"),
            ("deleted file mode", r"deleted file mode [0-7]{6}"),
            ("old mode", r"old mode [0-7]{6}"),
            ("new mode", r"new mode [0-7]{6}"),
            ("similarity index", r"similarity index (?:100|[0-9]?[0-9])%"),
            ("dissimilarity index", r"dissimilarity index (?:100|[0-9]?[0-9])%"),
            ("rename from", r"rename from .+"),
            ("rename to", r"rename to .+"),
            ("copy from", r"copy from .+"),
            ("copy to", r"copy to .+"),
        )
        matched_metadata = next(
            (
                name
                for name, pattern in metadata_patterns
                if re.fullmatch(pattern, raw)
            ),
            None,
        )
        if raw and matched_metadata is None:
            raise InfrastructureError(
                f"malformed unified diff: unexpected metadata line {raw!r}"
            )
        if matched_metadata is not None:
            if matched_metadata in metadata and matched_metadata != "index":
                raise InfrastructureError(
                    f"malformed unified diff: duplicate metadata line {raw!r}"
                )
            metadata.add(matched_metadata)
    finish()
    return tuple(patches)


def _helper_family(helper):
    if helper in MUTATION_TAKING_HELPERS:
        return "mutation-helper"
    if helper in COUNT_HELPERS:
        return "count-helper"
    return "static-helper"


_RAW_PRESENCE_RE = re.compile(
    r"""(?P<prefix>\$\(|\bif\s+|\bthen\s+|(?:^|;|&&)\s*)
        grep\s+
        (?P<options>(?:(?:-[A-Za-z]+|--[a-z-]+)\s+)+)
        (?:--\s+)?
        (?P<literal_token>'[^']*'|"[^"]*"|[^\s]+)\s+
        (?P<target>
            "(?:\$\{?[A-Za-z_]\w*\}?(?:/[^\s";]+)?|/?[A-Za-z0-9_.-]+(?:/[^\s";]+)*)"
            |
            '(?:/?[A-Za-z0-9_.-]+(?:/[^\s';]+)*)'
            |
            (?:\$\{?[A-Za-z_]\w*\}?(?:/[^\s";]+)?|/?[A-Za-z0-9_.-]+(?:/[^\s";]+)*)
        )
        (?P<tail>\s*(?:;|\)|&&|\|\||$))""",
    re.VERBOSE | re.DOTALL,
)


def _line_end(start, logical_line):
    return start + logical_line.count("\n")


def _raw_options_are_fixed_quiet(options):
    fixed = quiet = False
    for option in options.split():
        if option == "--fixed-strings":
            fixed = True
        elif option == "--quiet":
            quiet = True
        elif option.startswith("-") and not option.startswith("--"):
            fixed = fixed or "F" in option[1:]
            quiet = quiet or "q" in option[1:]
    return fixed and quiet


def _resolve_guard_target(args, spec, literal_vars, path_vars, lib):
    _, file_index, default_file = spec
    if file_index < len(args):
        target = resolve_arg(
            args[file_index], literal_vars, path_vars, want_path=True, lib=lib
        )
        return target.rstrip(";") if target is not None else None
    if default_file is not None:
        return path_vars.get(default_file)
    return None


def _markdown_prose_text(text):
    """Return Markdown text outside closed fences and HTML comments.

    A properly closed fenced block is machine-facing content for this boundary.
    An unterminated fence fails closed: its content remains prose-eligible
    rather than allowing a stray opener to exempt the rest of a document.
    """
    lines = text.splitlines(keepends=True)
    excluded = set()
    fence = None
    fence_start = None
    for index, line in enumerate(lines):
        match = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line.rstrip("\r\n"))
        if fence is None:
            if match and not (
                match.group(1)[0] == "`" and "`" in match.group(2)
            ):
                fence = (match.group(1)[0], len(match.group(1)))
                fence_start = index
            continue
        if (
            match
            and match.group(1)[0] == fence[0]
            and len(match.group(1)) >= fence[1]
            and match.group(2).strip() == ""
        ):
            excluded.update(range(fence_start, index + 1))
            fence = None
            fence_start = None

    visible = "".join(
        line for index, line in enumerate(lines) if index not in excluded
    )
    return re.sub(r"<!--.*?-->", "", visible, flags=re.DOTALL)


def _markdown_literal_is_prose(text, literal):
    """Detect visible Markdown headings and whitespace-bearing prose phrases."""
    visible = _markdown_prose_text(text)
    for line in visible.splitlines():
        if literal not in line:
            continue
        if re.match(r"^ {0,3}#{1,6}(?:\s+|$)", line):
            return True
        if re.search(r"\s", literal):
            return True
    return False


def _typed_pin_protects_prose(site, repo_root):
    """Return True when a declaration matches the conservative prose boundary.

    The issue-810 boundary is semantic: a category marker does not turn an
    advisory phrase into an executable contract. For statically resolved
    targets, the conservative classifier rejects headings, whitespace-bearing
    visible Markdown phrases, and hash-comment text. A standalone non-heading
    token is treated as a sentinel; fenced Markdown machine content and
    operative source text retain the typed structural path.
    """
    if (
        site.declaration is None
        or site.literal is None
        or site.target_path is None
    ):
        return False
    target = Path(site.target_path)
    if not target.is_absolute():
        target = Path(repo_root) / target
    ext = target.suffix.lower()
    try:
        text = target.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        # Defensive fallback for direct callers. The production scanner rejects
        # unreadable typed targets in _typed_pin_inspection_error first.
        return ext in COMMENT_MD_EXTS and bool(re.search(r"\s", site.literal))
    if site.literal not in text:
        return False
    if ext in COMMENT_MD_EXTS:
        return _markdown_literal_is_prose(text, site.literal)
    if ext in COMMENT_HASH_EXTS:
        return any(
            site.literal in comment
            for _, comment in hash_comment_regions(text.splitlines())
        )
    return False


def _typed_pin_inspection_error(site, repo_root):
    """Return why a typed declaration's target boundary cannot be inspected."""
    if site.declaration is None or site.declaration_error is not None:
        return None
    if not site.literal:
        return "typed structural declaration literal cannot be inspected"
    if site.target_path is None:
        return "typed structural declaration target cannot be inspected"
    target = Path(site.target_path)
    if not target.is_absolute():
        target = Path(repo_root) / target
    try:
        if os.path.commonpath((Path(repo_root).resolve(), target.resolve())) != str(
            Path(repo_root).resolve()
        ):
            return (
                "typed structural declaration target cannot be inspected "
                "(outside repository)"
            )
    except (OSError, ValueError):
        return "typed structural declaration target cannot be inspected"
    try:
        target_text = target.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        return (
            "typed structural declaration target cannot be inspected "
            f"({type(exc).__name__})"
        )
    if site.literal not in target_text:
        return (
            "typed structural declaration literal cannot be inspected "
            "(absent from target)"
        )
    return None


def _python_read_target(node, repo_root):
    """Return (contains file-text read, statically resolved target or None)."""
    for child in ast.walk(node):
        if not (
            isinstance(child, ast.Call)
            and isinstance(child.func, ast.Attribute)
            and child.func.attr in {"read", "read_text"}
        ):
            continue
        receiver = child.func.value
        path_arg = None
        if (
            child.func.attr == "read_text"
            and isinstance(receiver, ast.Call)
            and isinstance(receiver.func, ast.Name)
            and receiver.func.id == "Path"
            and receiver.args
        ):
            path_arg = receiver.args[0]
        elif (
            child.func.attr == "read"
            and isinstance(receiver, ast.Call)
            and isinstance(receiver.func, ast.Name)
            and receiver.func.id == "open"
            and receiver.args
        ):
            path_arg = receiver.args[0]
        target = None
        if isinstance(path_arg, ast.Constant) and isinstance(path_arg.value, str):
            target = Path(path_arg.value)
            if not target.is_absolute():
                target = Path(repo_root) / target
            target = str(target)
        return True, target
    return False, None


def extract_python_guard_sites(text, source_path, repo_root):
    """Extract direct Python assertions over file text."""
    try:
        tree = ast.parse(text)
    except SyntaxError as exc:
        raise InfrastructureError(
            f"Python pin source cannot be parsed: {source_path}: {exc}"
        ) from exc
    physical = text.splitlines()
    assigned_reads = {}
    for assignment in ast.walk(tree):
        if (
            isinstance(assignment, ast.Assign)
            and len(assignment.targets) == 1
            and isinstance(assignment.targets[0], ast.Name)
        ):
            is_read, target = _python_read_target(assignment.value, repo_root)
            if is_read:
                assigned_reads[assignment.targets[0].id] = target
    sites = []
    for node in ast.walk(tree):
        literal = haystack = helper = None
        if (
            isinstance(node, ast.Call)
            and isinstance(node.func, ast.Attribute)
            and node.func.attr == "assertIn"
            and len(node.args) >= 2
        ):
            literal, haystack = node.args[:2]
            helper = f"python-{node.func.attr}"
        elif (
            isinstance(node, ast.Call)
            and isinstance(node.func, ast.Attribute)
            and node.func.attr == "assertRegex"
            and len(node.args) >= 2
        ):
            haystack, literal = node.args[:2]
            helper = "python-assertRegex"
        elif isinstance(node, ast.Assert) and isinstance(node.test, ast.Compare):
            comparison = node.test
            if (
                len(comparison.ops) == 1
                and isinstance(comparison.ops[0], ast.In)
                and len(comparison.comparators) == 1
            ):
                literal = comparison.left
                haystack = comparison.comparators[0]
                helper = "python-assert-in"
        direct_read, target_path = (
            _python_read_target(haystack, repo_root)
            if haystack is not None
            else (False, None)
        )
        assigned_read = (
            isinstance(haystack, ast.Name) and haystack.id in assigned_reads
        )
        if (
            not isinstance(literal, ast.Constant)
            or not isinstance(literal.value, str)
            or haystack is None
            or not (direct_read or assigned_read)
        ):
            continue
        if assigned_read:
            target_path = assigned_reads[haystack.id]
        line_end = getattr(node, "end_lineno", node.lineno)
        declaration, error = parse_structural_declaration(
            physical[node.lineno - 1 : line_end]
        )
        sites.append(
            GuardSite(
                source_path,
                node.lineno,
                line_end,
                "raw-presence",
                helper,
                literal.value,
                target_path,
                declaration,
                error,
            )
        )
    return sites


def extract_guard_sites(text, source_path, repo_root):
    """Extract complete helper and narrow raw repository-presence guard sites."""
    if source_path.endswith(".py"):
        return extract_python_guard_sites(text, source_path, repo_root)
    repo_root = os.path.abspath(repo_root)
    lib = os.path.join(repo_root, "lib")
    helper_specs, helper_families, wrapper_origins = helper_specs_for_source(
        text, include_families=True, include_origins=True
    )
    definitions = _function_definitions(text)
    function_by_line = {
        line: name
        for name, (_, start, end) in definitions.items()
        for line in range(start, end + 1)
    }
    invoked_wrappers = set()
    for invocation_line, invocation_text in join_logical_lines(text):
        invocation_tokens = tokenize(invocation_text.lstrip())
        _, invocation_helper = _helper_call(invocation_tokens, helper_specs)
        if (
            invocation_helper in definitions
            and function_by_line.get(invocation_line) != invocation_helper
        ):
            invoked_wrappers.add(invocation_helper)
    represented_body_lines = {
        definitions[name][1] + wrapper_origins[name] - 1
        for name in invoked_wrappers
        if name in wrapper_origins
    }
    maps_by_line = variable_maps_by_line(text, lib, {})
    physical = text.splitlines()
    sites = []
    for lineno, logical_line in join_logical_lines(text):
        stripped = logical_line.lstrip()
        if not stripped or stripped.startswith("#"):
            continue
        path_vars, literal_vars = maps_by_line[lineno]
        lines = physical[lineno - 1 : _line_end(lineno, logical_line)]
        toks = tokenize(stripped)
        helper_index, helper = _helper_call(toks, helper_specs)
        if helper is not None:
            args = toks[helper_index + 1 :]
            literal = None
            spec = helper_specs[helper]
            lit_selector = spec[0]
            if isinstance(lit_selector, int) and lit_selector < len(args):
                literal = resolve_arg(
                    args[lit_selector],
                    literal_vars,
                    path_vars,
                    want_path=False,
                    lib=lib,
                )
            elif isinstance(lit_selector, str):
                literal = lit_selector
            if lineno in represented_body_lines:
                # An invoked wrapper's body is not a second runtime pin site;
                # its body-derived spec classifies the invocation instead.
                continue
            target = _resolve_guard_target(
                args, spec, literal_vars, path_vars, lib
            )
            declaration, error = parse_structural_declaration(lines)
            sites.append(
                GuardSite(
                    source_path,
                    lineno,
                    _line_end(lineno, logical_line),
                    helper_families[helper],
                    helper,
                    literal,
                    target,
                    declaration,
                    error,
                )
            )
            continue
        match = _RAW_PRESENCE_RE.search(logical_line)
        if not match or not _raw_options_are_fixed_quiet(match.group("options")):
            continue
        # Negative assertions are absence guards, not presence pins. Canonical
        # yes/no and 1/0 renderings are recognized; an `if grep ...` branch is
        # positive unless explicitly negated.
        before_grep = logical_line[: match.start()]
        expected = re.search(
            r"""assert_eq\s+(?:"[^"]*"|'[^']*')\s+(?P<q>['"])(?P<value>yes|no|1|0)(?P=q)""",
            before_grep,
        )
        if re.search(r"!\s*$", before_grep):
            continue
        echo_pair = re.search(
            r"&&\s+echo\s+(?P<on_match>yes|no|1|0)"
            r"\s+\|\|\s+echo\s+(?P<on_miss>yes|no|1|0)",
            logical_line[match.start() :],
        )
        if expected:
            if echo_pair:
                if expected.group("value") != echo_pair.group("on_match"):
                    continue
            elif expected.group("value") in {"no", "0"}:
                continue
        target_token = match.group("target")
        if (
            len(target_token) >= 2
            and target_token[0] == target_token[-1]
            and target_token[0] in {"'", '"'}
        ):
            target_token = target_token[1:-1]
        var_match = _VARREF.match(target_token)
        var_name = var_match.group(1) if var_match else ""
        target = path_vars.get(var_name) if var_name else None
        if target is None:
            target = _resolve_inline_var_path(target_token, lib, path_vars)
        if target is None and "$" not in target_token:
            target = (
                target_token
                if os.path.isabs(target_token)
                else os.path.join(repo_root, target_token)
            )
        if (
            target is None
            and var_name
            and re.match(r"^(?:TMP|TEMP)(?:_|$)", var_name)
        ):
            continue
        target_abs = os.path.abspath(target) if target is not None else None
        if target_abs is not None:
            try:
                inside_repo = os.path.commonpath((repo_root, target_abs)) == repo_root
            except ValueError:
                inside_repo = False
            if not inside_repo:
                continue
        declaration, error = parse_structural_declaration(lines)
        literal_tokens = tokenize(match.group("literal_token"))
        raw_literal = None
        if literal_tokens:
            raw_literal = resolve_arg(
                literal_tokens[0],
                literal_vars,
                path_vars,
                want_path=False,
                lib=lib,
            )
        sites.append(
            GuardSite(
                source_path,
                lineno,
                _line_end(lineno, logical_line),
                "raw-presence",
                None,
                raw_literal,
                target_abs,
                declaration,
                error,
            )
        )
    return sites


def _site_changed(site, changed_lines):
    return any(site.line_start <= line <= site.line_end for line in changed_lines)


def _move_class(site):
    if site.family == "mutation-helper":
        return ("mutation-helper", None)
    if site.declaration is not None:
        return (site.family, site.declaration.category)
    return (site.family, "legacy")


def _move_compatible(old, new):
    if old.target_path != new.target_path:
        return False
    old_class = _move_class(old)
    new_class = _move_class(new)
    if old_class[0] != new_class[0]:
        return False
    if old_class[1] == "legacy":
        return new_class[1] == "legacy" or new.declaration is not None
    return old_class == new_class


def scan_changed_sources(current_sources, base_sources, difftext, repo_root):
    """Classify changed complete sites and return blocking finding strings."""
    patches = parse_unified_diff(difftext)
    old_candidates = []
    new_candidates = []
    for patch in patches:
        old_sites = []
        new_sites = []
        if patch.old_path in base_sources:
            old_sites = extract_guard_sites(
                base_sources[patch.old_path], patch.old_path, repo_root
            )
            old_candidates.extend(
                site for site in old_sites if _site_changed(site, patch.deleted_lines)
            )
        if patch.new_path in current_sources:
            new_sites = extract_guard_sites(
                current_sources[patch.new_path], patch.new_path, repo_root
            )
            new_candidates.extend(
                site for site in new_sites if _site_changed(site, patch.added_lines)
            )
        # A changed assignment can alter an unchanged call's effective literal
        # or target. Compare sites connected by the unchanged-line mapping so
        # semantic changes enter the same policy path even when the call line is
        # diff context.
        if (
            patch.old_path == patch.new_path
            and patch.old_path in base_sources
            and patch.new_path in current_sources
            and (patch.added_lines or patch.deleted_lines)
        ):
            old_lines = base_sources[patch.old_path].splitlines()
            new_lines = current_sources[patch.new_path].splitlines()
            line_map = {}
            for block in difflib.SequenceMatcher(
                None, old_lines, new_lines, autojunk=False
            ).get_matching_blocks():
                for offset in range(block.size):
                    line_map[block.a + offset + 1] = block.b + offset + 1
            new_by_line = {site.line_start: site for site in new_sites}
            for old_site in old_sites:
                new_site = new_by_line.get(line_map.get(old_site.line_start))
                if new_site is None:
                    continue
                old_effective = (
                    old_site.family,
                    old_site.helper,
                    old_site.literal,
                    old_site.target_path,
                    old_site.declaration,
                    old_site.declaration_error,
                )
                new_effective = (
                    new_site.family,
                    new_site.helper,
                    new_site.literal,
                    new_site.target_path,
                    new_site.declaration,
                    new_site.declaration_error,
                )
                if old_effective == new_effective:
                    continue
                if old_site not in old_candidates:
                    old_candidates.append(old_site)
                if new_site not in new_candidates:
                    new_candidates.append(new_site)

    unused_old = list(old_candidates)
    findings = []
    for site in new_candidates:
        if site.family in ("mutation-helper", "count-helper"):
            continue
        inspection_error = _typed_pin_inspection_error(site, repo_root)
        if inspection_error is not None:
            findings.append(
                f"MUTATION-ROUTING\t{site.source_path}:{site.line_start}\t"
                f"{site.helper or site.family}\t{site.literal or '<unresolved-literal>'}\t"
                f"{inspection_error}"
            )
            continue
        if (
            site.declaration is not None
            and site.declaration_error is None
            and not _typed_pin_protects_prose(site, repo_root)
        ):
            continue
        if _typed_pin_protects_prose(site, repo_root):
            findings.append(
                f"MUTATION-ROUTING\t{site.source_path}:{site.line_start}\t"
                f"{site.helper or site.family}\t{site.literal or '<unresolved-literal>'}\t"
                "typed structural declaration cannot exempt prose presence"
            )
            continue
        if site.declaration_error != "missing structural declaration":
            detail = site.declaration_error
            findings.append(
                f"MUTATION-ROUTING\t{site.source_path}:{site.line_start}\t"
                f"{site.helper or site.family}\t{site.literal or '<unresolved-literal>'}\t{detail}"
            )
            continue
        move_index = next(
            (
                index
                for index, old in enumerate(unused_old)
                if site.literal is not None
                and old.literal == site.literal
                and _move_compatible(old, site)
            ),
            None,
        )
        if move_index is not None:
            unused_old.pop(move_index)
            continue
        detail = site.declaration_error or "wording-only presence pin"
        findings.append(
            f"MUTATION-ROUTING\t{site.source_path}:{site.line_start}\t"
            f"{site.helper or site.family}\t{site.literal or '<unresolved-literal>'}\t{detail}"
        )
    return findings


def validate_audited_population(registry, audited_sources, enumerated_sources):
    """Return registry/audit mismatches and audited paths absent from Git."""
    if not isinstance(registry, dict):
        raise InfrastructureError("registry schema: root must be an object")
    if type(registry.get("schema_version")) is not int or registry["schema_version"] != 1:
        raise InfrastructureError(
            "registry schema: schema_version must be integer 1"
        )
    modules = registry.get("test_modules")
    if not isinstance(modules, dict) or not modules:
        raise InfrastructureError(
            "registry schema: test_modules must be a non-empty object"
        )
    registered = {"lib/test/run.sh"}
    for name, row in modules.items():
        if (
            not isinstance(name, str)
            or re.fullmatch(r"[a-z0-9][a-z0-9._-]*", name) is None
            or not isinstance(row, dict)
            or not isinstance(row.get("path"), str)
            or re.fullmatch(
                r"lib/test/modules/[A-Za-z0-9][A-Za-z0-9._-]*[.]sh",
                row["path"],
            )
            is None
            or type(row.get("minimum_assertions")) is not int
            or not 1 <= row["minimum_assertions"] <= 1_000_000
        ):
            raise InfrastructureError(
                f"registry schema: invalid test_modules row: {name!r}"
            )
        registered.add(row["path"])
    audited = set(audited_sources)
    enumerated = set(enumerated_sources)
    findings = []
    for path in sorted(registered - audited):
        findings.append(f"registered pin source absent from audited population: {path}")
    for path in sorted(audited - registered):
        findings.append(f"stale audited pin source absent from registry: {path}")
    for path in sorted(audited - enumerated):
        findings.append(f"audited pin source absent from Git enumeration: {path}")
    return findings


def _unique_json_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate registry key {key!r}")
        result[key] = value
    return result


def load_registry(path):
    """Load the module registry with the selector's duplicate-key contract."""
    try:
        return json.loads(
            Path(path).read_text(encoding="utf-8"),
            object_pairs_hook=_unique_json_object,
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        raise InfrastructureError(f"registry read failed: {exc}") from exc


def _run_git(git_runner, repo_root, *args):
    result = git_runner(
        ["git", "-C", str(repo_root), *args],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise InfrastructureError(
            f"git {' '.join(args)} failed (exit {result.returncode}): {result.stderr.strip()}"
        )
    return result.stdout


def scan_worktree(
    repo_root,
    base_ref="origin/main",
    *,
    git_runner=subprocess.run,
    scratch_factory=None,
):
    """Run the required, fail-closed mutation-routing gate over the worktree."""
    repo_root = Path(repo_root)
    scratch_factory = scratch_factory or (
        lambda: tempfile.NamedTemporaryFile(mode="w+", encoding="utf-8")
    )
    try:
        scratch = scratch_factory()
    except OSError as exc:
        raise InfrastructureError(f"scratch allocation failed: {exc}") from exc
    try:
        _run_git(git_runner, repo_root, "rev-parse", "--verify", base_ref)
        # A missing local main is the normal Actions checkout shape. Other ancestry
        # failures remain infrastructure failures rather than green skips.
        local_main = git_runner(
            [
                "git",
                "-C",
                str(repo_root),
                "show-ref",
                "--verify",
                "--quiet",
                "refs/heads/main",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if local_main.returncode == 0:
            _run_git(
                git_runner,
                repo_root,
                "merge-base",
                "--is-ancestor",
                "refs/heads/main",
                base_ref,
            )
        elif local_main.returncode != 1:
            raise InfrastructureError(
                "local main resolution failed "
                f"(exit {local_main.returncode}): {local_main.stderr.strip()}"
            )
        merge_base = _run_git(
            git_runner, repo_root, "merge-base", base_ref, "HEAD"
        ).strip()
        if not merge_base:
            raise InfrastructureError("comparison merge base resolved to empty output")
        python_tracked = set(
            filter(
                None,
                _run_git(
                    git_runner,
                    repo_root,
                    "ls-files",
                    "--cached",
                    "--",
                    "lib/test/test_*.py",
                ).splitlines(),
            )
        )
        python_untracked = set(
            filter(
                None,
                _run_git(
                    git_runner,
                    repo_root,
                    "ls-files",
                    "--others",
                    "--exclude-standard",
                    "--",
                    "lib/test/test_*.py",
                ).splitlines(),
            )
        )
        scan_sources = set(AUDITED_PIN_SOURCES) | python_tracked | python_untracked
        difftext = _run_git(
            git_runner,
            repo_root,
            "diff",
            "--no-color",
            "--no-ext-diff",
            "--unified=0",
            merge_base,
            "--",
            *sorted(scan_sources),
        )
        untracked = set(
            filter(
                None,
                _run_git(
                    git_runner,
                    repo_root,
                    "ls-files",
                    "--others",
                    "--exclude-standard",
                    "--",
                    *sorted(AUDITED_PIN_SOURCES),
                ).splitlines(),
            )
        )
        tracked = set(
            filter(
                None,
                _run_git(
                    git_runner,
                    repo_root,
                    "ls-files",
                    "--cached",
                    "--",
                    *sorted(AUDITED_PIN_SOURCES),
                ).splitlines(),
            )
        )
        base_paths = set(
            filter(
                None,
                _run_git(
                    git_runner,
                    repo_root,
                    "ls-tree",
                    "-r",
                    "--name-only",
                    merge_base,
                    "--",
                    *sorted(scan_sources),
                ).splitlines(),
            )
        )
        registry = load_registry(
            repo_root / "scripts/workflow-flight-recorder-registry.json"
        )
        population_findings = validate_audited_population(
            registry, AUDITED_PIN_SOURCES, tracked | untracked
        )
        if population_findings:
            raise InfrastructureError("; ".join(population_findings))

        current_sources = {}
        base_sources = {}
        for path in sorted(scan_sources):
            try:
                current_sources[path] = (repo_root / path).read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError) as exc:
                raise InfrastructureError(f"pin source unreadable: {path}: {exc}") from exc
            if path in base_paths:
                base_sources[path] = _run_git(
                    git_runner, repo_root, "show", f"{merge_base}:{path}"
                )
            else:
                base_sources[path] = ""
                lines = current_sources[path].splitlines()
                difftext += (
                    f"\ndiff --git a/{path} b/{path}\n"
                    "--- /dev/null\n"
                    f"+++ b/{path}\n"
                    f"@@ -0,0 +1,{len(lines)} @@\n"
                    + "\n".join(f"+{line}" for line in lines)
                    + "\n"
                )
        try:
            scratch.write(difftext)
        except OSError as exc:
            raise InfrastructureError(f"scratch write failed: {exc}") from exc
        try:
            scratch.flush()
        except OSError as exc:
            raise InfrastructureError(f"scratch flush failed: {exc}") from exc
        return scan_changed_sources(
            current_sources, base_sources, difftext, str(repo_root)
        )
    finally:
        try:
            scratch.close()
        except OSError as exc:
            raise InfrastructureError(f"scratch close failed: {exc}") from exc


def _read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def _read_target(path):
    """Read a resolved target file, returning (text, None) on success or
    (None, reason) when the file passed os.path.isfile yet cannot be read or
    decoded (permission, non-UTF-8, a directory racing in). Its callers turn a
    non-None reason into an UNRESOLVED count + stderr breadcrumb — so a
    resolved-but-unreadable target fails CLOSED (counted, matching the module's
    fail-closed contract) instead of raising an uncaught exception that would
    empty stdout and pass the real-corpus assertion vacuously (issue #375 review)."""
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read(), None
    except (OSError, UnicodeDecodeError) as exc:
        return None, type(exc).__name__


def main(argv):
    if len(argv) < 3 or argv[1] not in (
        "lint",
        "wrapped",
        "mutation-routing",
        "mutation-routing-worktree",
    ):
        sys.stderr.write(__doc__ or "")
        return 2
    cmd, pin_source = argv[1], argv[2]
    if cmd == "mutation-routing-worktree":
        if len(argv) != 3:
            sys.stderr.write("mutation-routing-worktree accepts only REPO_ROOT\n")
            return 2
        try:
            findings = scan_worktree(pin_source)
        except InfrastructureError as exc:
            sys.stderr.write(f"MUTATION-ROUTING-INFRASTRUCTURE\t{exc}\n")
            return 2
        for finding in findings:
            print(finding)
        return 3 if findings else 0
    lib = None
    overrides = {}
    md_targets = set()
    reloc = False
    reloc_search_file = None
    reloc_exclude = []
    diff_file = None
    strict = False
    i = 3
    while i < len(argv):
        if argv[i] == "--diff-file" and i + 1 < len(argv):
            diff_file = argv[i + 1]
            i += 2
        elif argv[i] == "--strict":
            # Opt-in exit-code mode (issue #687): make the exit code carry the
            # finding signal so a caller can key on it. Takes no value, so it
            # mirrors --reloc's single-token arm. Off by default → byte-for-byte
            # today's behaviour, which is why every existing call site is
            # unaffected and the #661 rc-0-on-findings self-test still passes.
            strict = True
            i += 1
        elif argv[i] == "--lib" and i + 1 < len(argv):
            lib = argv[i + 1]
            i += 2
        elif argv[i] == "--var" and i + 1 < len(argv):
            name, _, val = argv[i + 1].partition("=")
            overrides[name] = val
            i += 2
        elif argv[i] == "--md" and i + 1 < len(argv):
            md_targets.add(argv[i + 1])
            i += 2
        elif argv[i] == "--reloc":
            reloc = True
            i += 1
        elif argv[i] == "--reloc-search-set" and i + 1 < len(argv):
            reloc_search_file = argv[i + 1]
            i += 2
        elif argv[i] == "--reloc-exclude" and i + 1 < len(argv):
            reloc_exclude.append(argv[i + 1])
            i += 2
        else:
            sys.stderr.write(f"unknown arg: {argv[i]}\n")
            return 2
    if lib is None:
        lib = os.path.dirname(os.path.dirname(os.path.abspath(pin_source)))
    if cmd == "lint":
        return run_lint(pin_source, lib, overrides, md_targets, strict=strict)
    if cmd == "mutation-routing":
        return run_mutation_routing(pin_source, lib, overrides, md_targets, diff_file)
    return run_wrapped(
        pin_source, lib, overrides, md_targets,
        reloc=reloc, reloc_search_file=reloc_search_file, reloc_exclude=reloc_exclude,
        strict=strict,
    )


if __name__ == "__main__":
    sys.exit(main(sys.argv))
