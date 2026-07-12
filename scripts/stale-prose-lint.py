#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Deterministic stale counted-prose lint (issue #423).

Detects the top defect class escaping DevFlow's in-run review-and-fix loop to the
standalone review: **diff-added prose asserting counts, ranges, sums, or absolutes
that the same PR's later commits outgrow or falsify**. Modeled on
``lib/test/pin-corpus-lint.py`` (deterministic scanner + fail-closed accounting).

The four deterministic rule classes, each evaluated over **diff-added comment / prose lines**
and resolved against the **post-diff file state**:

**Scoping (issue #434).** A claim is prose. A line of *code* that merely contains claim-shaped
text — a shell fixture string, an assertion name — is data, not an assertion about the file,
so it is not examined; ``prose_mask`` decides this per file type (markdown-family prose outside
fenced blocks; ``#`` comments; ``//`` comments and ``/* … */`` interiors; Python ``#`` comments
plus real docstrings, resolved with ``ast``). The same predicate scopes R4's *permit referent*,
so a code line can neither raise a claim nor contradict one. **An unrecognised file type fails
OPEN — every added line is examined, exactly as before — with a stderr breadcrumb.** Never the
reverse: a closed allowlist would silently reduce a consumer repo in an unlisted language to a
permanent no-op (empty output, exit 0, forever) while this header still advertised the check.
Deliberately NOT examined (accepted, not accidental): ``.sh`` heredoc prose, YAML block-scalar
prose, trailing comments after code, and ``#`` comments inside ```` ```bash ```` fences in
markdown. None of the four historical escape shapes lived on those surfaces.

* **R1 range-outgrowth.** A ``Cases A-B`` header whose forward region (the lines
  after it in the post-diff file) contains a ``Case N`` with ``N > B`` — the header
  was frozen while the block it introduces grew past it (the PR #328 shape).
* **R2 legend-sum.** An ``Expected total = N`` claim whose adjacent enumeration
  block does not contain exactly ``N`` items (the PR #320 shape).
* **R3 / R3b count-locked.** An exact-count claim (``N assertions``) or a two-item
  ``a X and a Y … both`` claim resolved against the adjacent assertion block; a
  mismatch is STALE, a match a VERIFIED ``count-locked`` row (the PR #336 shape).
  ``R3b`` names the two-item *shape* only; both sub-cases are emitted under the
  ``rule`` TSV token ``R3`` — there is no ``R3b`` output token.
* **R4 modality-conflict (operator-token restricted).** A deny-absolute
  (``never``/``no``/``not``/``any``/``forbidden`` …) about a **backticked operator
  token** — one of ``> >> < << | || && & |& 2> 2>> &>`` — that the SAME post-diff
  file also asserts is *permitted* elsewhere (the PR #397 shape). The
  **operator-token restriction is the only shipped operating point**: a backticked
  token that is not an operator (an arbitrary named identifier) is never examined,
  which is the false-positive boundary a named-token scope mismatch stays clear of.

**R3 recognition-only tier (issue #439).** Layered cleanly over the R3 count-locked rule
above without touching it, and **evaluated last — after every gating rule (R1/R2/R3/R3b/R4),
each of which ``continue``s on a match — so it is reached only on a line no gating rule
claimed** (an earlier placement let a line matching both the widened count shape and a gating
R4 deny-absolute be consumed here before R4 could run, suppressing a real STALE). A diff-added
prose/comment line that matches a *widened* claim shape but that no gating rule (including the
gating ``_COUNT_RE``) claims emits a single ``UNRESOLVABLE`` ``R3`` row whose detail begins
``count-locked: recognition-only (<n> <noun>) — pin or drift-proof this claim``.
The widened shape is: a spelled-out numeral word (``two`` … ``twelve``, case-insensitive ASCII)
or a digit run; up to two intervening modifier words (each optionally wrapped in ``**…**`` /
``*…*`` / backticks); and a noun from the *widened* set — the seven ``_COUNT_RE`` nouns plus
the plural-only additions ``tags`` / ``members`` / ``fields`` / ``rows`` / ``columns`` /
``arms`` / ``files`` / ``rules`` / ``sites``. This tier is **non-gating by construction**: it
runs **no** referent resolution (no adjacency walk, no table parsing), never emits STALE, and
never affects the exit code (``UNRESOLVABLE`` never gates). Its only job is to surface the
``count-locked`` literal the pin-or-don't-write policy keys on, so an unpinned counted claim
announces itself in the fix loop's Step 3 pre-check and the Phase 0.6 note.

**Recognition-tier noise guards** (noise-limiting only — the tier cannot gate, so these need not
be correctness-critical): the numeral must not be directly preceded by ``#`` / ``§`` / a digit /
``.`` / ``-`` (so ``#402``-style references and ``§2.3`` section numbers are never read as
numerals); and an intervening modifier token that is numeral-shaped, or one of ``of`` / ``per`` /
``and`` / ``or`` (killing partitives like "two of these tags"), disqualifies the recognition. A
token carrying sentence punctuation cannot even form a modifier — the modifier pattern is a bare
word — so such a token structurally breaks the match rather than being separately rejected.

**Recognition-tier out of scope (by design, decided in issue #439).** Verification / gating of the
widened surface, markdown-table referent counting, and adjacency-walk relaxation are deliberately
**not** built — the #423 build methodology routes such n=1 verification shapes to the review-agent
LLM carve-out, which remains the gate for this class. Numeral words are English-only (a documented
accepted boundary for non-English consumer repos). Hyphenated numeral compounds (``twenty-one``)
and the word ``one`` (idiom-heavy) are excluded.

**Out of scope (by design).** The *behavioral-absolute* subclass — a deny-absolute
with no countable referent (the PR #383 "grep errors either way" shape) — is
deterministically out of reach and stays routed to ``comment-analyzer`` via the
fix loop's existing Step 3 item 3a machinery. This helper adds NO LLM fallback.

**Caller-supplied-diff contract (shallow-clone safe).** The helper reads the
unified diff from **stdin** and resolves post-diff file state via an explicit
``--rev`` argument (``git show <rev>:<path>``). It never derives the diff range
itself (no base..head range computation) and never calls the range-deriving git
plumbing — the caller passes the diff it already computed (the review engine's
cached ``diff.patch``; the fix loop's branch diff). This is what makes the PR #328
shape detectable on every invocation: a claim line added by an *earlier* commit of
the branch whose referent a *later* commit outgrew is still in the supplied diff's
added set, and the post-diff file (``--rev``) shows the grown referent — no fix
commit ever has to touch the frozen header for the staleness to surface.

Output: one TSV row per examined claim on stdout —
``verdict<TAB>rule<TAB>file<TAB>line<TAB>detail`` — with ``verdict`` one of
``VERIFIED`` / ``STALE`` / ``UNRESOLVABLE``.

Exit codes:
  0  no STALE row (all VERIFIED / UNRESOLVABLE, or no claims at all)
  1  at least one STALE row
  2  internal error — an unreadable ``--rev``, an unreadable or non-UTF-8 stdin diff,
     or any other unexpected failure (e.g. ``git`` unavailable); all fail-closed
UNRESOLVABLE rows never affect the exit code.

Usage:
    stale-prose-lint.py --rev REV  < unified.diff
"""

from __future__ import annotations

import argparse
import ast
import re
import subprocess
import sys
from typing import NamedTuple

# Operator tokens R4 is restricted to. A backticked token outside this set is an
# arbitrary named identifier and is deliberately never examined (the false-positive
# boundary): the operator-token restriction is the only shipped R4 operating point.
OP_TOKENS = frozenset({">", ">>", "<", "<<", "|", "||", "&&", "&", "|&", "2>", "2>>", "&>"})

# A deny-absolute marker on the claim line (case-insensitive, word-ish boundaries).
_DENY_RE = re.compile(
    r"(?i)\b(never|no|not|none|any|forbid|forbidden|forbids|banned|bans|"
    r"deny|denies|denied|disallow|disallowed|must\s+not|cannot|can't|don't|do\s+not)\b"
)
# A permit marker anywhere else in the post-diff file (case-insensitive).
_PERMIT_RE = re.compile(
    r"(?i)\b(permit|permits|permitted|permissible|allow|allows|allowed|"
    r"sanction|sanctions|sanctioned|grant|grants|granted)\b"
)

_RANGE_RE = re.compile(r"\bCases?\s+(\d+)\s*[-–—]\s*(\d+)\b")
_CASE_ITEM_RE = re.compile(r"\bCase\s+(\d+)\b")
_TOTAL_RE = re.compile(r"\bExpected\s+total\s*[=:]\s*(\d+)\b", re.IGNORECASE)
_LIST_ITEM_RE = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s+\S")
# A leading line-comment marker, stripped from a REFERENT line before it is tested for
# enumeration-item shape. Load-bearing: the claims these rules resolve live in comment blocks,
# so their enumerations do too — PR #320's legend bullets are `#   - inline_missing: …`, and
# `_LIST_ITEM_RE` is anchored, so without this strip `_adjacent_list_count` returns 0 on the
# very defect R2 exists to catch (a non-gating UNRESOLVABLE, exit 0 — a silent false negative;
# only a *bare*-bullet legend, which the historical defect never was, ever resolved).
# Deliberately only `#` and `//`: `*` is EXCLUDED because it is itself a markdown bullet
# marker, so stripping it would turn a real `* item` enumeration into a non-item and break the
# count in the opposite direction.
_COMMENT_PREFIX_RE = re.compile(r"^\s*(?:#+|//+)\s?")


def _uncomment(line):
    """A referent line with its leading line-comment marker removed (if any)."""
    return _COMMENT_PREFIX_RE.sub("", line, count=1)
_ASSERT_LINE_RE = re.compile(r"(?i)\bassert\w*\b")
# The gating R3 noun set — shared as one constant so the recognition tier's _RECOG_NOUN
# below cannot silently drift from the gating _COUNT_RE (a new noun added here reaches both).
_COUNT_NOUNS = r"assertions?|asserts?|checks?|bullets?|items?|entries?|cases?"
_COUNT_RE = re.compile(rf"\b(\d+)\s+({_COUNT_NOUNS})\b", re.IGNORECASE)
# ── R3 recognition-only tier (issue #439), non-gating ──────────────────────────────────
# Spelled-out numeral words two..twelve → their integer value. "one" is deliberately absent
# (idiom-heavy) and thirteen+ is out of scope; see the module header's recognition-tier records.
_WORD_NUM = {
    "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
    "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
}
# The widened noun set: the gating _COUNT_NOUNS (in their ``s?`` forms, interpolated so the
# gating surface stays byte-identical and cannot drift) plus the nine new nouns, matched
# PLURAL-ONLY so a singular ("tag", "rule") never trips the recognition.
_RECOG_NOUN = (
    r"(?:" + _COUNT_NOUNS + r"|tags|members|fields|rows|columns|arms|files|rules|sites)"
)
# A single intervening modifier token: a bare word, optionally wrapped in ``**…**`` / ``*…*`` /
# backticks, followed by whitespace. Because the word body is ``[A-Za-z][\w'-]*`` (no sentence
# punctuation), a token carrying a comma/period/colon cannot form a modifier — it structurally
# breaks the match, which is how the "sentence punctuation disqualifies" guard is realised.
_RECOG_MOD = r"[*`]{0,2}[A-Za-z][\w'-]*[*`]{0,2}\s+"
# The word alternation is DERIVED from _WORD_NUM (single source of truth) so the regex and the
# value map can never drift — a word the regex matched but the map lacked would KeyError. The
# ``\b`` anchors on the alternation below make alternative order irrelevant.
_WORD_ALT = "|".join(_WORD_NUM)
# The numeral: a word numeral (bounded) OR a digit run, NOT directly preceded by ``#`` / ``§`` /
# a digit / ``.`` / ``-`` (kills ``#402`` references, ``§2.3`` section numbers, decimals).
_RECOG_NUM = r"(?<![#§\d.\-])(?:\b(?P<word>" + _WORD_ALT + r")\b|(?P<digit>\d+))"
_RECOG_RE = re.compile(
    _RECOG_NUM + r"\s+(?P<mods>(?:" + _RECOG_MOD + r"){0,2})(?P<noun>" + _RECOG_NOUN + r")\b",
    re.IGNORECASE,
)
# Modifier words that disqualify the recognition (partitives / conjunctions).
_RECOG_MOD_DISQUALIFY = frozenset({"of", "per", "and", "or"})

# Two-item enumeration: "a X and a Y" plus a "both" summary → asserts exactly 2.
_TWO_ITEM_RE = re.compile(r"(?i)\ba\b\s+\S.*\band\b\s+\ba\b\s+\S")
_BOTH_RE = re.compile(r"(?i)\bboth\b")
_BACKTICK_RE = re.compile(r"`([^`]+)`")

# Verdict tokens as module constants, referenced by every emit site AND the exit-code gate
# (``verdict == STALE`` in ``run``). The process exit code hinges on the STALE literal
# matching identically everywhere it is produced and compared; a bare repeated string would
# fail OPEN on a typo (a mistyped ``"STAEL"`` at one append site silently drops that row from
# the exit-code tally → the lint reports a clean pass on real staleness — the exact fail-open
# a fail-safe lint must not have). A constant turns that typo into a ``NameError`` at import.
VERIFIED = "VERIFIED"
STALE = "STALE"
UNRESOLVABLE = "UNRESOLVABLE"


class Row(NamedTuple):
    """One TSV verdict row. A NamedTuple (not a bare 5-tuple) so each field is named at every
    construction site and the arity is pinned structurally — a wrong-arity append is a
    construction-time error, not a silent positional-unpack drift. (Deliberately no count of
    those sites here: an unpinned exact count is the very claim this lint exists to catch, and
    this repo's pin-or-don't-write policy says don't write it.)"""

    verdict: str
    rule: str
    path: str
    line: int
    detail: str


class InternalError(Exception):
    """Raised for a fail-closed exit-2 condition — an unreadable/unresolvable ``--rev``
    (validated up front in ``run``). A general ``git show`` non-zero does NOT raise this:
    it returns None -> UNRESOLVABLE; an unavailable ``git`` binary raises
    ``FileNotFoundError``, caught by ``main``'s catch-all. This is the single raise site."""


# ── Line scoping (issue #434) ─────────────────────────────────────────────────────────
# A claim is prose. A line of CODE that merely *contains* claim-shaped text — a shell
# fixture string, an assertion name — is data, not an assertion about the file, and grading
# it is the helper's dominant false-positive source. These tables decide which lines can
# carry a claim, per file type.
#
# The `None` (unrecognised) arm is the load-bearing one: it FAILS OPEN to "examine every
# line" — today's behavior — never to "examine nothing". A closed allowlist would silently
# reduce a consumer repo in an unlisted language to a permanent no-op (empty TSV, exit 0,
# forever) while the docs still advertised the check. A file type we forgot must degrade to
# the status quo, not to no checking.
_PROSE_EXTS = frozenset({".md", ".markdown", ".mdx", ".rst", ".adoc", ".txt"})
_HASH_EXTS = frozenset({".sh", ".bash", ".zsh", ".yml", ".yaml", ".jq", ".toml",
                        ".rb", ".tf", ".ini", ".cfg"})
_HASH_BASENAMES = frozenset({"makefile", "dockerfile"})
_SLASH_EXTS = frozenset({".ts", ".tsx", ".js", ".jsx", ".go", ".rs", ".java", ".c", ".h",
                         ".cpp", ".cc", ".hpp", ".cs", ".swift", ".kt", ".scala", ".php"})
# A fence opener/closer: >=3 backticks or >=3 tildes. The RUN LENGTH is captured because a
# fence closes only on a run of the SAME character that is at least as long as its opener —
# which is what lets a 4-backtick fence wrap 3-backtick examples (CLAUDE.md does exactly
# this). A naive "toggle on any ```" inverts state for the rest of the file: mass mis-scoping
# in BOTH directions at once.
_FENCE_RE = re.compile(r"^\s{0,3}(`{3,}|~{3,})")

_unrecognised_exts = set()  # reported once, at the end of the run (see `run`)


def _norm_line(line):
    """A line with its trailing CR and a leading UTF-8 BOM removed.

    A CRLF file (routine in a consumer Windows repo) otherwise leaves ``\\r`` on every line,
    so a fence marker reads as ``` + CR`` and never matches — the whole file's code blocks
    would be scoped as prose. A BOM is not whitespace to ``str.strip()``, so it hides a
    leading ``#`` and silently un-examines the first comment of the file."""
    return line.lstrip("﻿").rstrip("\r")


def _path_kind(path):
    """'prose' | 'hash' | 'slash' | 'py' | None (unrecognised -> examine every line)."""
    base = path.rsplit("/", 1)[-1].lower()
    if base in _HASH_BASENAMES:
        return "hash"
    dot = base.rfind(".")
    if dot <= 0:  # no extension (or a dotfile like `.gitignore`)
        _unrecognised_exts.add(base if dot < 0 else base[dot:])
        return None
    ext = base[dot:]
    if ext == ".py":
        return "py"
    if ext in _PROSE_EXTS:
        return "prose"
    if ext in _HASH_EXTS:
        return "hash"
    if ext in _SLASH_EXTS:
        return "slash"
    _unrecognised_exts.add(ext)
    return None


def _fenced_mask(lines):
    """True for each line that sits INSIDE a fenced code block (the fence markers included).

    An UNCLOSED fence fails OPEN: its opener is not treated as a fence at all, so the rest of
    the file stays prose. The alternative — treating everything after a stray backtick run as
    code — would silently un-examine the tail of a file, a false negative created by a typo.
    """
    inside = [False] * len(lines)
    open_at = None
    marker = ""
    for i, raw in enumerate(lines):
        m = _FENCE_RE.match(_norm_line(raw))
        if not m:
            continue
        run = m.group(1)
        if open_at is None:
            open_at, marker = i, run
        elif run[0] == marker[0] and len(run) >= len(marker):
            for j in range(open_at, i + 1):
                inside[j] = True
            open_at, marker = None, ""
    return inside  # an unclosed opener leaves its region False — fail open


def _py_docstring_mask(lines, path):
    """True for each line inside a module/class/function docstring.

    The helper's own counted claims live in docstrings, so `#`-comments-only scoping would
    lose them. Resolved with the stdlib ``ast`` over the post-diff file rather than by
    counting triple quotes: a naive quote-toggle classifies ANY triple-quoted string as a
    docstring, so fixture data in a test file (claim-shaped text inside a string literal)
    would be examined — re-creating in Python the exact false-positive class this change
    removes from shell. On a file that does not parse at ``--rev`` the mask is empty
    (`#`-comments only) and a breadcrumb says so — never a silent skip."""
    mask = [False] * len(lines)
    try:
        tree = ast.parse("\n".join(lines))
    except (SyntaxError, ValueError) as exc:
        sys.stderr.write(
            f"stale-prose-lint.py: {path} does not parse at --rev ({type(exc).__name__}); "
            f"scoping it to '#' comments only (docstring claims in this file are not "
            f"examined)\n")
        return mask
    for node in ast.walk(tree):
        if not isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef,
                                 ast.AsyncFunctionDef)):
            continue
        body = getattr(node, "body", None)
        if not body:
            continue
        first = body[0]
        if not (isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant)
                and isinstance(first.value.value, str)):
            continue
        start = getattr(first, "lineno", 0) - 1
        end = getattr(first, "end_lineno", start + 1) - 1
        for j in range(max(start, 0), min(end + 1, len(mask))):
            mask[j] = True
    return mask


def prose_mask(path, lines):
    """Per-line 'may carry a claim' mask for ``path``, or None to examine every line.

    None (the unrecognised-type arm) means FAIL OPEN — see the table above."""
    kind = _path_kind(path)
    if kind is None:
        return None
    if kind == "prose":
        return [not inside for inside in _fenced_mask(lines)]
    if kind == "hash":
        return [_norm_line(ln).lstrip().startswith("#") for ln in lines]
    if kind == "py":
        doc = _py_docstring_mask(lines, path)
        return [doc[i] or _norm_line(ln).lstrip().startswith("#")
                for i, ln in enumerate(lines)]
    # slash: `//` line comments plus `/* … */` block-comment interiors.
    mask = []
    in_block = False
    for ln in lines:
        text = _norm_line(ln).lstrip()
        if in_block:
            mask.append(True)
            if "*/" in text:
                in_block = False
            continue
        if text.startswith("/*"):
            mask.append(True)
            if "*/" not in text[2:]:
                in_block = True
            continue
        mask.append(text.startswith("//"))
    return mask


def _may_carry_claim(mask, idx):
    """True when line index ``idx`` may carry a claim. A None mask examines everything."""
    if mask is None:
        return True
    return 0 <= idx < len(mask) and mask[idx]


def _run_git(args):
    """Run a git command, returning (rc, stdout_text, stderr_text). Never raises on non-zero.

    ``stderr_text`` is returned, not discarded, so a caller that degrades on a non-zero rc
    can carry git's own reason in its breadcrumb instead of collapsing every failure into
    an unexplained verdict.

    Decode git output with an explicit ``utf-8`` codec and ``errors="replace"`` —
    NEVER the locale-default codec ``text=True`` would pick. Under a ``C``/``POSIX``
    locale (common in CI containers and the cloud sandbox) that default is strict
    ASCII, so ``git show <rev>:<path>`` of any file carrying a non-ASCII byte (an
    en/em-dash, Latin-1, a UTF-8 BOM) would raise ``UnicodeDecodeError`` and abort
    the *entire* lint to exit 2 — masking every other file's verdict, including a
    real STALE. ``errors="replace"`` keeps a single odd byte in one reviewed file
    from detonating the whole pass at *decode* time (that file is still examined — a
    stray replacement char cannot manufacture a false countable claim); ``main``
    likewise reconfigures the output streams to ``utf-8``/``errors="replace"`` so
    emitting that byte cannot detonate the pass at *write* time either — so an odd byte
    in a reviewed file body does not detonate the pass through the git-show *read* or
    the stdout *write*. (A reviewed file's *invalid*-UTF-8 bytes can still reach exit 2
    by a third, intentional channel — the strict stdin-diff decode in ``main``, which
    treats a non-UTF-8 diff as a caller error; see the module header's Exit codes list,
    the single exit-2 catalog.)"""
    proc = subprocess.run(
        ["git", *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        encoding="utf-8",
        errors="replace",
    )
    return proc.returncode, proc.stdout, proc.stderr


def _unquote_path(target):
    """Decode git's C-quoted path form (``"b/caf\\303\\251.md"``) back to real text.

    With the default ``core.quotepath``, a non-ASCII path is emitted quoted and
    octal-escaped. Left as-is, the quotes and escapes reach ``git show`` (which then fails)
    and the extension test (which sees a trailing ``"`` and no known suffix) — so the file
    would land on the unrecognised arm for a reason that has nothing to do with its type."""
    if not (len(target) >= 2 and target.startswith('"') and target.endswith('"')):
        return target
    try:
        raw = target[1:-1].encode("latin-1").decode("unicode_escape").encode("latin-1")
        return raw.decode("utf-8", errors="replace")
    except (UnicodeDecodeError, UnicodeEncodeError):
        return target[1:-1]


def parse_diff(diff_text):
    """Return {path: {post_lineno: added_text}} from a unified diff.

    Only the post-image (added / context) line numbering is tracked; each ``+``
    line is recorded against its post-image line number.

    Structure and content are told apart by the hunk's own **post-image budget**
    (``@@ -a,b +c,d @@`` promises exactly ``d`` post-image lines), not by a bare
    prefix test on each line. This is load-bearing twice over. First, a *content*
    line whose own text begins with ``++ `` is emitted in the diff as ``+++ ``: a
    prefix-only parser reads it as the next file header and silently retargets every
    later claim in the diff onto a phantom path. Second, the real callers (the engine's
    Phase 0.6 and the fix loop's pre-check) feed a ``base...HEAD`` diff — many hunks,
    interleaved context and ``-`` deletions, post-image starts well past 1 — where the
    ``post_ln`` bookkeeping is what aligns each claim with its referent; an off-by-one
    there does not fail loudly, it silently degrades real STALE rows to UNRESOLVABLE.
    A ``-`` line consumes pre-image budget only, so it never advances ``post_ln``.
    """
    files = {}
    path = None
    added = None
    post_ln = 0
    budget = 0  # post-image lines still owed by the current hunk (0 = between hunks)
    for line in diff_text.split("\n"):
        # A content line always carries a ``+``/``-``/space prefix (or is empty), so an
        # unprefixed ``@@`` or ``diff --git`` at column 0 is structure even mid-hunk: resync
        # on it rather than letting an overstated/truncated hunk count silently swallow the
        # next hunk (or file) header — which would drop every claim after it. Note the same
        # argument does NOT hold for ``+++ ``/``--- ``: those ARE reachable as content (a
        # ``++ ``-leading added line renders as ``+++ ``), which is why the budget, not a
        # prefix test, decides those.
        if budget > 0 and (line.startswith("@@") or line.startswith("diff --git ")):
            budget = 0
        if budget <= 0:
            if line.startswith("+++ "):
                target = line[4:].strip()
                if target == "/dev/null":
                    path = None
                    added = None
                    continue
                target = _unquote_path(target)
                # Strip a leading "b/" (git) prefix.
                path = target[2:] if target.startswith("b/") else target
                added = files.setdefault(path, {})
                continue
            if line.startswith("@@"):
                m = re.search(r"\+(\d+)(?:,(\d+))?", line)
                if m:
                    post_ln = int(m.group(1))
                    # An absent count means a one-line post image ("@@ -1 +1 @@").
                    budget = int(m.group(2)) if m.group(2) is not None else 1
                else:
                    post_ln = 0
                    budget = 0
                continue
            continue  # "--- ", "diff ", "index ", and any other between-hunk noise
        if path is None or added is None:
            budget = 0
            continue
        if line.startswith("+"):
            added[post_ln] = line[1:]
            post_ln += 1
            budget -= 1
        elif line.startswith("-"):
            continue  # pre-image only — spends no post-image budget
        elif line.startswith("\\"):  # "\ No newline at end of file" — not a line of either image
            continue
        else:  # context line (leading space, or an empty line)
            post_ln += 1
            budget -= 1
    return files


def post_file_lines(rev, path):
    """Return the post-diff file's lines (1-indexed via index+1), or None when the
    file cannot be resolved at ``rev`` (e.g. deleted) — an UNRESOLVABLE case, NOT an
    internal error (only an unreadable REV itself is exit-2, validated up front).

    Every non-zero ``git show`` lands on the same None -> UNRESOLVABLE arm, but the
    reasons are not the same: an expected absence (the file was deleted/renamed at
    ``rev``) reads identically to a transient/environmental failure on a file that IS
    present. The verdict row cannot tell them apart, so git's own reason goes to stderr
    — the downgrade stays non-gating, but it is never unexplained."""
    rc, out, err = _run_git(["show", f"{rev}:{path}"])
    if rc != 0:
        reason = " ".join(err.split())[:200] or f"git show exited {rc} with no stderr"
        sys.stderr.write(
            f"stale-prose-lint.py: {path} not resolvable at rev (UNRESOLVABLE): {reason}\n")
        return None
    return out.split("\n")


def _forward_maxcase(lines, start_idx):
    """Max ``Case N`` integer strictly after line index ``start_idx`` (0-based)."""
    best = None
    for line in lines[start_idx + 1:]:
        for m in _CASE_ITEM_RE.finditer(line):
            n = int(m.group(1))
            best = n if best is None else max(best, n)
    return best


def _adjacent_list_count(lines, claim_idx):
    """Count contiguous enumeration items directly above (preferred) or below the
    claim line, tolerating blank separators. Returns 0 when no adjacent block."""
    def count_dir(step):
        i = claim_idx + step
        # Skip blank separators — including a bare `#` / `//` line inside a comment block,
        # which is that block's blank line and must not terminate the enumeration.
        while 0 <= i < len(lines) and _uncomment(lines[i]).strip() == "":
            i += step
        c = 0
        while 0 <= i < len(lines) and _LIST_ITEM_RE.match(_uncomment(lines[i])):
            c += 1
            i += step
        return c

    above = count_dir(-1)
    if above:
        return above
    return count_dir(1)


def _adjacent_assert_count(lines, claim_idx):
    """Count contiguous assertion lines below the claim, tolerating blanks. An
    assertion line contains ``assert`` or is an enumeration item."""
    i = claim_idx + 1
    while i < len(lines) and _uncomment(lines[i]).strip() == "":
        i += 1
    c = 0
    while i < len(lines) and (_ASSERT_LINE_RE.search(lines[i])
                              or _LIST_ITEM_RE.match(_uncomment(lines[i]))):
        c += 1
        i += 1
    return c


def _mods_ok(mods):
    """True when every intervening modifier token in ``mods`` is a plain modifier word — not a
    partitive/conjunction (of/per/and/or) and not numeral-shaped. See the recognition-tier
    noise guards in the module header. ``mods`` may be empty (zero modifiers → always OK)."""
    for tok in mods.split():
        bare = tok.strip("*`").lower()
        if bare in _RECOG_MOD_DISQUALIFY:
            return False
        if bare in _WORD_NUM or bare.isdigit():
            return False
    return True


def _recognize_count(text):
    """Recognition-only tier (issue #439): return ``(n, noun)`` for a *widened* count claim that
    today's ``_COUNT_RE`` does not match, or ``None``. NON-GATING — the caller emits an
    ``UNRESOLVABLE`` row and never resolves a referent. ``finditer`` (not ``search``) so a first
    match disqualified by its modifiers does not mask a later valid claim on the same line."""
    for m in _RECOG_RE.finditer(text):
        if not _mods_ok(m.group("mods")):
            continue
        word = m.group("word")
        n = _WORD_NUM[word.lower()] if word else int(m.group("digit"))
        return n, m.group("noun")
    return None


def _excerpt(text):
    return " ".join(text.split())[:120]


def _emit_count(rows, rule, path, post_ln, n, c, unresolvable, stale, verified):
    """Append the shared count-claim verdict for a claimed count ``n`` vs an actual
    adjacent-block count ``c``: 0 → UNRESOLVABLE (no block), ``c != n`` → STALE, else
    VERIFIED. R2/R3/R3b all resolve to this same three-arm shape, differing only in
    their per-verdict detail strings."""
    if c == 0:
        rows.append(Row(UNRESOLVABLE, rule, path, post_ln, unresolvable))
    elif c != n:
        rows.append(Row(STALE, rule, path, post_ln, stale))
    else:
        rows.append(Row(VERIFIED, rule, path, post_ln, verified))


def examine_file(path, added, lines, rows):
    """Append ``Row(verdict, rule, path, line, detail)`` rows to ``rows`` for ``path``.

    ``added`` maps post-image line numbers to added text; ``lines`` is the whole
    post-diff file (0-indexed list). A claim is examined only when it sits on an
    added line **that may carry a claim** — a comment or prose line, per ``prose_mask``.
    A code line that merely contains claim-shaped text is data, not an assertion.
    """
    mask = prose_mask(path, lines)
    for post_ln in sorted(added):
        text = added[post_ln]
        idx = post_ln - 1  # 0-based index into `lines`
        if idx < 0 or idx >= len(lines):
            # The added line's post-image number does not resolve in the post-diff
            # file (deleted/renamed race) — resolve referents defensively by text.
            idx = _locate(lines, text)
            if idx is None:
                continue
        if not _may_carry_claim(mask, idx):
            continue

        # R1 — range outgrowth
        rm = _RANGE_RE.search(text)
        if rm:
            a, b = int(rm.group(1)), int(rm.group(2))
            maxn = _forward_maxcase(lines, idx)
            if maxn is None:
                rows.append(Row(UNRESOLVABLE, "R1", path, post_ln,
                                f"range Cases {a}-{b}: no forward Case items found — {_excerpt(text)}"))
            elif maxn > b:
                rows.append(Row(STALE, "R1", path, post_ln,
                                f"range claims Cases {a}-{b} but forward region reaches Case {maxn} — {_excerpt(text)}"))
            else:
                rows.append(Row(VERIFIED, "R1", path, post_ln,
                                f"range Cases {a}-{b} covers forward max Case {maxn} — {_excerpt(text)}"))
            continue

        # R2 — legend/enumeration sum vs "Expected total = N"
        tm = _TOTAL_RE.search(text)
        if tm:
            n = int(tm.group(1))
            c = _adjacent_list_count(lines, idx)
            _emit_count(rows, "R2", path, post_ln, n, c,
                        f"Expected total = {n}: no adjacent enumeration block — {_excerpt(text)}",
                        f"Expected total = {n} but adjacent enumeration has {c} items — {_excerpt(text)}",
                        f"Expected total = {n} matches {c} enumerated items — {_excerpt(text)}")
            continue

        # R3b — two-item "a X and a Y … both" count-locked claim (asserts 2)
        if _BOTH_RE.search(text) and _TWO_ITEM_RE.search(text):
            c = _adjacent_assert_count(lines, idx)
            _emit_count(rows, "R3", path, post_ln, 2, c,
                        f"count-locked: two-item claim but no adjacent assertion block — {_excerpt(text)}",
                        f"count-locked: claim asserts both (2) but adjacent block has {c} assertions — {_excerpt(text)}",
                        f"count-locked: two-item claim matches {c} assertions — {_excerpt(text)}")
            continue

        # R3 — exact numeric count claim ("N assertions") count-locked
        cm = _COUNT_RE.search(text)
        if cm:
            n = int(cm.group(1))
            c = _adjacent_assert_count(lines, idx)
            _emit_count(rows, "R3", path, post_ln, n, c,
                        f"count-locked: '{n} {cm.group(2)}' claim but no adjacent assertion block — {_excerpt(text)}",
                        f"count-locked: claims {n} {cm.group(2)} but adjacent block has {c} — {_excerpt(text)}",
                        f"count-locked: {n} {cm.group(2)} matches adjacent block — {_excerpt(text)}")
            continue

        # R4 — operator-token modality conflict
        if _DENY_RE.search(text):
            op = None
            for m in _BACKTICK_RE.finditer(text):
                if m.group(1) in OP_TOKENS:
                    op = m.group(1)
                    break
            if op is not None:
                if _permitted_elsewhere(lines, idx, op, mask):
                    rows.append(Row(STALE, "R4", path, post_ln,
                                    f"deny-absolute forbids `{op}` but the same file asserts it permitted — {_excerpt(text)}"))
                else:
                    rows.append(Row(VERIFIED, "R4", path, post_ln,
                                    f"deny-absolute on `{op}`: no contradicting permit found — {_excerpt(text)}"))
            continue

        # R3 recognition-only tier (issue #439) — widened claim recognition, NON-GATING.
        # Placed LAST, after every gating rule (R1/R2/R3/R3b/R4), each of which `continue`s
        # on a match — so the recognition tier is reached ONLY on a line no gating rule
        # claimed. This ordering is load-bearing for the non-gating invariant: an earlier
        # placement let a line matching both the widened count shape AND a gating R4
        # deny-absolute be consumed here (via the `continue` below) before R4 could run,
        # suppressing a real STALE and flipping the exit code — the fail-open this position
        # forecloses. No referent resolution runs; the row is always UNRESOLVABLE and never
        # affects the exit code — its sole purpose is the count-locked policy trigger.
        rec = _recognize_count(text)
        if rec is not None:
            rec_n, rec_noun = rec
            rec_detail = ("count-locked: recognition-only "
                          f"({rec_n} {rec_noun}) — pin or drift-proof this claim — {_excerpt(text)}")
            rows.append(Row(UNRESOLVABLE, "R3", path, post_ln, rec_detail))
            continue


def _permitted_elsewhere(lines, claim_idx, op, mask=None):
    """True when a COMMENT/PROSE line other than the claim asserts operator ``op`` is permitted.

    The permit referent is scoped by the same predicate as the claim (issue #434). A code line
    is not an assertion about the file, so it cannot contradict one: before this, a shell
    fixture string like ``'An in-workspace `>` redirect … is permitted.'`` acted as a real
    "permit" and flipped a genuine comment deny-absolute to STALE. That is an independent
    false-positive source from the claim side, and scoping only the claim would leave it
    minting fresh false positives forever."""
    for i, line in enumerate(lines):
        if i == claim_idx:
            continue
        if not _may_carry_claim(mask, i):
            continue
        if not _PERMIT_RE.search(line):
            continue
        for m in _BACKTICK_RE.finditer(line):
            if m.group(1) == op:
                return True
    return False


def _locate(lines, text):
    stripped = text.strip()
    if not stripped:
        return None
    for i, line in enumerate(lines):
        if line.strip() == stripped:
            return i
    return None


def run(rev, diff_text):
    # Validate the rev up front — an unreadable rev is a caller error (exit 2), not
    # a per-file UNRESOLVABLE. `rev-parse --verify` never derives a diff range.
    rc, _, _ = _run_git(["rev-parse", "--verify", "--quiet", f"{rev}^{{commit}}"])
    if rc != 0:
        raise InternalError(f"--rev '{rev}' does not resolve to a commit")

    files = parse_diff(diff_text)
    rows = []
    for path in sorted(files):
        added = files[path]
        if not added:
            continue
        lines = post_file_lines(rev, path)
        if lines is None:
            for post_ln in sorted(added):
                rows.append(Row(UNRESOLVABLE, "-", path, post_ln,
                                f"post-diff file not resolvable at rev — {_excerpt(added[post_ln])}"))
            continue
        examine_file(path, added, lines, rows)

    # The fail-open arm must be DISCOVERABLE, not silent: a consumer whose language is not in
    # the scoping tables keeps today's examine-every-line behavior (no coverage is lost), but
    # they get the false positives that behavior implies — and with no breadcrumb they would
    # have no way to learn why, or that adding their type is the fix.
    if _unrecognised_exts:
        sys.stderr.write(
            "stale-prose-lint.py: no comment/prose scoping rule for "
            f"{', '.join(sorted(_unrecognised_exts))} — every added line in those files was "
            "examined (fail-open: coverage is never silently dropped for an unlisted type)\n")

    stale = False
    for row in rows:
        sys.stdout.write(f"{row.verdict}\t{row.rule}\t{row.path}\t{row.line}\t{row.detail}\n")
        if row.verdict == STALE:
            stale = True
    return 1 if stale else 0


def main(argv):
    # The ENTIRE body sits inside the exit-2 catch-all. An exception escaping `main` at all
    # would exit with Python's default code 1 — and 1 is a CONTRACTED helper arm ("at least
    # one STALE row"), not an error code, so the callers' exit-code routers (Phase 0.6, the
    # fix loop's pre-check) would read a crashed run as a completed one over its empty
    # stdout. Every failure must therefore surface as 2. Two limbs used to sit outside the
    # guard: the stream reconfigure below (whose except-list is narrower than the set of
    # exceptions an exotic wrapped stream can raise) and the argparse construction.
    # `argparse`'s own usage exit is a SystemExit (a BaseException) and still passes
    # through with its own code, as does `--help`.
    try:
        # Harden the OUTPUT streams the same way `_run_git` hardens its input decode. Under
        # a `C`/`POSIX` locale (the threat model `_run_git` cites) sys.stdout/sys.stderr
        # default to the strict-ASCII codec, so writing a verdict row (or a diagnostic)
        # whose text carries a non-ASCII byte — an en/em-dash, Latin-1, a UTF-8 BOM copied
        # out of a reviewed line — would raise UnicodeEncodeError at write time and abort
        # the ENTIRE lint to exit 2, masking every other file's verdict (the read-side
        # hardening alone did not close this; the failure resurfaced at the stdout write).
        # Reconfigure to utf-8/errors="replace" so an odd byte degrades that one character,
        # never the pass. Guarded because a replaced/wrapped stream (a test harness, a pipe
        # object) may lack reconfigure() or reject the call.
        for _stream in (sys.stdout, sys.stderr):
            try:
                _stream.reconfigure(encoding="utf-8", errors="replace")
            except (AttributeError, ValueError):
                pass
        parser = argparse.ArgumentParser(
            prog="stale-prose-lint.py",
            description="Detect stale countable claims in diff-added prose (issue #423).",
        )
        parser.add_argument(
            "--rev",
            required=True,
            help="the revision whose post-diff file state resolves each claim's referent "
            "(git show <rev>:<path>); the caller supplies the diff on stdin. This helper "
            "never derives the diff range itself.",
        )
        args = parser.parse_args(argv[1:])

        try:
            raw = sys.stdin.buffer.read()
        except Exception as exc:  # noqa: BLE001 — any stdin read failure is exit-2
            sys.stderr.write(f"stale-prose-lint.py: could not read stdin ({exc})\n")
            return 2
        try:
            diff_text = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            sys.stderr.write(f"stale-prose-lint.py: diff is not valid UTF-8 ({exc})\n")
            return 2

        return run(args.rev, diff_text)
    except InternalError as exc:
        sys.stderr.write(f"stale-prose-lint.py: {exc}\n")
        return 2
    except Exception as exc:  # noqa: BLE001 — never surface a traceback as a verdict
        sys.stderr.write(f"stale-prose-lint.py: internal error ({type(exc).__name__}: {exc})\n")
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
