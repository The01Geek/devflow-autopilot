#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Deterministic stale counted-prose lint (issue #423).

Detects the top defect class escaping DevFlow's in-run review-and-fix loop to the
standalone review: **diff-added prose asserting counts, ranges, sums, or absolutes
that the same PR's later commits outgrow or falsify**. Modeled on
``lib/test/pin-corpus-lint.py`` (deterministic scanner + fail-closed accounting).

The four deterministic rule classes, each evaluated over **diff-added** comment /
prose lines and resolved against the **post-diff file state**:

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
import re
import subprocess
import sys

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
_ASSERT_LINE_RE = re.compile(r"(?i)\bassert\w*\b")
_COUNT_RE = re.compile(
    r"\b(\d+)\s+(assertions?|asserts?|checks?|bullets?|items?|entries?|cases?)\b",
    re.IGNORECASE,
)
# Two-item enumeration: "a X and a Y" plus a "both" summary → asserts exactly 2.
_TWO_ITEM_RE = re.compile(r"(?i)\ba\b\s+\S.*\band\b\s+\ba\b\s+\S")
_BOTH_RE = re.compile(r"(?i)\bboth\b")
_BACKTICK_RE = re.compile(r"`([^`]+)`")


class InternalError(Exception):
    """Raised for a fail-closed exit-2 condition — an unreadable/unresolvable ``--rev``
    (validated up front in ``run``). A general ``git show`` non-zero does NOT raise this:
    it returns None -> UNRESOLVABLE; an unavailable ``git`` binary raises
    ``FileNotFoundError``, caught by ``main``'s catch-all. This is the single raise site."""


def _run_git(args):
    """Run a git command, returning (rc, stdout_text). Never raises on non-zero.

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
    return proc.returncode, proc.stdout


def parse_diff(diff_text):
    """Return {path: {post_lineno: added_text}} from a unified diff.

    Only the post-image (added / context) line numbering is tracked; each ``+``
    line is recorded against its post-image line number.
    """
    files = {}
    path = None
    added = None
    post_ln = 0
    for line in diff_text.split("\n"):
        if line.startswith("+++ "):
            target = line[4:].strip()
            if target == "/dev/null":
                path = None
                added = None
                continue
            # Strip a leading "b/" (git) prefix.
            path = target[2:] if target.startswith("b/") else target
            added = files.setdefault(path, {})
            continue
        if line.startswith("--- ") or line.startswith("diff ") or line.startswith("index "):
            continue
        if line.startswith("@@"):
            m = re.search(r"\+(\d+)", line)
            post_ln = int(m.group(1)) if m else 0
            continue
        if path is None or added is None:
            continue
        if line.startswith("+"):
            added[post_ln] = line[1:]
            post_ln += 1
        elif line.startswith("-"):
            continue
        elif line.startswith("\\"):  # "\ No newline at end of file"
            continue
        else:  # context line (leading space, or an empty line)
            post_ln += 1
    return files


def post_file_lines(rev, path):
    """Return the post-diff file's lines (1-indexed via index+1), or None when the
    file cannot be resolved at ``rev`` (e.g. deleted) — an UNRESOLVABLE case, NOT an
    internal error (only an unreadable REV itself is exit-2, validated up front)."""
    rc, out = _run_git(["show", f"{rev}:{path}"])
    if rc != 0:
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
        # skip blank lines between the claim and the block
        while 0 <= i < len(lines) and lines[i].strip() == "":
            i += step
        c = 0
        while 0 <= i < len(lines) and _LIST_ITEM_RE.match(lines[i]):
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
    while i < len(lines) and lines[i].strip() == "":
        i += 1
    c = 0
    while i < len(lines) and (_ASSERT_LINE_RE.search(lines[i]) or _LIST_ITEM_RE.match(lines[i])):
        c += 1
        i += 1
    return c


def _excerpt(text):
    return " ".join(text.split())[:120]


def _emit_count(rows, rule, path, post_ln, n, c, unresolvable, stale, verified):
    """Append the shared count-claim verdict for a claimed count ``n`` vs an actual
    adjacent-block count ``c``: 0 → UNRESOLVABLE (no block), ``c != n`` → STALE, else
    VERIFIED. R2/R3/R3b all resolve to this same three-arm shape, differing only in
    their per-verdict detail strings."""
    if c == 0:
        rows.append(("UNRESOLVABLE", rule, path, post_ln, unresolvable))
    elif c != n:
        rows.append(("STALE", rule, path, post_ln, stale))
    else:
        rows.append(("VERIFIED", rule, path, post_ln, verified))


def examine_file(path, added, lines, rows):
    """Append (verdict, rule, path, line, detail) tuples to ``rows`` for ``path``.

    ``added`` maps post-image line numbers to added text; ``lines`` is the whole
    post-diff file (0-indexed list). A claim is examined only when it sits on an
    added line.
    """
    for post_ln in sorted(added):
        text = added[post_ln]
        idx = post_ln - 1  # 0-based index into `lines`
        if idx < 0 or idx >= len(lines):
            # The added line's post-image number does not resolve in the post-diff
            # file (deleted/renamed race) — resolve referents defensively by text.
            idx = _locate(lines, text)
            if idx is None:
                continue

        # R1 — range outgrowth
        rm = _RANGE_RE.search(text)
        if rm:
            a, b = int(rm.group(1)), int(rm.group(2))
            maxn = _forward_maxcase(lines, idx)
            if maxn is None:
                rows.append(("UNRESOLVABLE", "R1", path, post_ln,
                             f"range Cases {a}-{b}: no forward Case items found — {_excerpt(text)}"))
            elif maxn > b:
                rows.append(("STALE", "R1", path, post_ln,
                             f"range claims Cases {a}-{b} but forward region reaches Case {maxn} — {_excerpt(text)}"))
            else:
                rows.append(("VERIFIED", "R1", path, post_ln,
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
                if _permitted_elsewhere(lines, idx, op):
                    rows.append(("STALE", "R4", path, post_ln,
                                 f"deny-absolute forbids `{op}` but the same file asserts it permitted — {_excerpt(text)}"))
                else:
                    rows.append(("VERIFIED", "R4", path, post_ln,
                                 f"deny-absolute on `{op}`: no contradicting permit found — {_excerpt(text)}"))
            continue


def _permitted_elsewhere(lines, claim_idx, op):
    """True when a line OTHER than the claim asserts operator ``op`` is permitted."""
    for i, line in enumerate(lines):
        if i == claim_idx:
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
    rc, _ = _run_git(["rev-parse", "--verify", "--quiet", f"{rev}^{{commit}}"])
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
                rows.append(("UNRESOLVABLE", "-", path, post_ln,
                             f"post-diff file not resolvable at rev — {_excerpt(added[post_ln])}"))
            continue
        examine_file(path, added, lines, rows)

    stale = False
    for verdict, rule, path, line, detail in rows:
        sys.stdout.write(f"{verdict}\t{rule}\t{path}\t{line}\t{detail}\n")
        if verdict == "STALE":
            stale = True
    return 1 if stale else 0


def main(argv):
    # Harden the OUTPUT streams the same way `_run_git` hardens its input decode. Under a
    # `C`/`POSIX` locale (the threat model `_run_git` cites) sys.stdout/sys.stderr default
    # to the strict-ASCII codec, so writing a verdict row (or a diagnostic) whose text
    # carries a non-ASCII byte — an en/em-dash, Latin-1, a UTF-8 BOM copied out of a
    # reviewed line — would raise UnicodeEncodeError at write time and abort the ENTIRE
    # lint to exit 2, masking every other file's verdict (the read-side hardening alone did
    # not close this; the failure resurfaced at the stdout write). Reconfigure to
    # utf-8/errors="replace" so an odd byte degrades that one character, never the pass.
    # Guarded because a replaced/wrapped stream (a test harness, a pipe object) may lack
    # reconfigure() or reject the call.
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

    try:
        return run(args.rev, diff_text)
    except InternalError as exc:
        sys.stderr.write(f"stale-prose-lint.py: {exc}\n")
        return 2
    except Exception as exc:  # noqa: BLE001 — never surface a traceback as a verdict
        sys.stderr.write(f"stale-prose-lint.py: internal error ({type(exc).__name__}: {exc})\n")
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
