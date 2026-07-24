#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Fail the suite when a corpus-aggregating retrospective helper passes a jq
operand through ``--argjson`` (an argv slot) without declaring it a bounded scalar.

Why this exists (issue #783): the weekly retrospective loop's aggregating helpers
build jq invocations whose operands grow monotonically with the corpus. Passed
through ``--argjson``, a corpus-sized operand becomes a single argv string; once it
exceeds the kernel arg limit (Linux ``MAX_ARG_STRLEN`` = 128 KB per argv string,
macOS ``ARG_MAX`` total) ``execve`` rejects it before jq runs and the loop aborts
with ``jq: Argument list too long``. The fix routes every corpus-sized operand
through ``--slurpfile <file>`` (a file read, dereferenced ``[0]``); a genuine
bounded scalar (a count, an epoch int, a boolean flag) may stay ``--argjson`` but
must *declare itself by name* in a ``# argjson-ok: <names> <reason>`` marker. This
guard turns the suite RED when an aggregating helper routes a corpus-sized operand
through ``--argjson`` again — either an ``--argjson`` with no applicable marker, or
one whose operand name the marker does not declare as a bounded scalar (a corpus
operand reverted from ``--slurpfile`` even though marked scalars share its jq
invocation) — so the E2BIG regression cannot ship silently.

It is a member of the repository's declaration-marker lint family, alongside
``# raw-guard-ok:`` / ``# structural-pin-ok:`` / ``# tree-walk-ok:``.

Audited population, closed by enumeration (the three corpus-AGGREGATING helpers):

* ``lib/actionable-patterns.sh`` — the actionable-pattern OUTPUT block.
* ``lib/scan.sh`` — the candidate-accumulation and unprocessed-filter jq.
* ``skills/retrospective-weekly/SKILL.md`` — the Step 9 summary build (invoked
  through the ``scripts/run-jq.sh`` wrapper, recognized identically).

The complement is deliberately out of scope and left unchanged: ``lib/
fetch-pr-context.sh`` is per-PR (bounded by one PR) and already ``--slurpfile``-
compliant; ``lib/materialize-retrospectives.sh`` passes single-PR / single-line
operands; ``skills/retrospective/SKILL.md`` is the Stage A subagent that analyzes
**one** PR from its pre-fetched context bundle, so its ``--argjson`` operands
(``bundle``/``categories``/``descriptors``/``suggested_interventions``) are per-PR
bounded, not corpus-sized; ``lib/efficiency-trace.sh`` is not on the retrospective
loop's path. The file set is a hardcoded closed list — this guard reads exactly
these three named paths and performs **no** repository-tree walk (so the #711
tree-enumeration convention is not engaged).

Marker coverage rule — PER-OPERAND-NAME, not per-line (robust to shell
continuation): jq invocations here span multiple physical lines via backslash-
continuation, and shell forbids a ``#`` comment mid-continuation, so a marker may
not sit inline on each ``--argjson`` line — a ``# argjson-ok:`` marker on the
line's inline comment tail, OR in the contiguous comment/blank block immediately
above the logical line, applies to it. A ``--argjson`` occurrence counts only when
it appears in the *code* portion of a line (before any inline ``#`` comment) — a
``--argjson`` mentioned inside explanatory comment prose is not a jq flag and is
ignored. Symmetrically, a ``# argjson-ok:`` marker only exempts when it sits in the
*comment* portion — a marker string appearing inside a quoted jq/shell literal does
not. Both the code/comment split and the marker split are the family's quote- and
escape-aware ``_comment_split`` (reused from ``lint-tree-enumeration.py``, not
re-derived), so a ``#`` inside a string literal is not mistaken for a comment.

The exemption is **scoped to the operand names the marker declares, never the whole
logical line** (issue #783 review — the load-bearing fix). A single backslash-joined
jq invocation routinely mixes corpus-sized ``--slurpfile`` operands with genuinely
bounded ``--argjson`` scalars carrying the marker; if the marker exempted the whole
line, a corpus operand reverted from ``--slurpfile`` back to ``--argjson`` on that
same invocation would be masked by the scalars' marker — the exact E2BIG regression
this guard exists to catch, silently uncaught. So a marker declares the scalar
operand names it vouches for (the identifier tokens after ``# argjson-ok:`` — e.g.
``min, cooldown_epoch``), and a logical line is COVERED only when it has an applicable
marker AND **every** ``--argjson NAME`` on it is a declared name. A ``--argjson``
operand whose name the marker does not declare (a reverted corpus operand:
``pattern_view`` / ``a`` / ``analyzed`` …) is a violation even though marked scalars
share its line. A logical line with a code ``--argjson`` flag and no applicable marker
at all is likewise a violation.
"""

import importlib.util
import os
import re
import sys
from pathlib import Path

# Reuse the declaration-marker family's quote- and escape-aware comment splitter
# from its reference implementation rather than re-deriving a naive first-``#``
# split here — the same import idiom `lint-issue-body-refetch.py` uses for
# `extract-command-heads.py` (issue #783 /simplify reuse pass). Assert the names
# this file uses at LOAD time so a rename in the sibling lint fails here naming the
# dependency, not silently mid-scan.
_TREE_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "lint-tree-enumeration.py"
)
_tree_spec = importlib.util.spec_from_file_location("lint_tree_enumeration", _TREE_PATH)
_tree = importlib.util.module_from_spec(_tree_spec)
_tree_spec.loader.exec_module(_tree)
_REQUIRED_TREE_ATTRS = ("strip_comment", "_comment_split")
_tree_missing = [name for name in _REQUIRED_TREE_ATTRS if not hasattr(_tree, name)]
if _tree_missing:
    raise SystemExit(
        f"lint-argjson-transport: {_TREE_PATH} no longer provides "
        f"{', '.join(_tree_missing)}; refusing to audit"
    )

FLAG = "--argjson"
MARKER = "# argjson-ok:"

#: The operand name after a ``--argjson`` flag (``--argjson pattern_view`` → ``pattern_view``).
_ARGJSON_NAME_RE = re.compile(r"--argjson\s+([A-Za-z_][A-Za-z0-9_]*)")
#: An identifier token, used to read the DECLARED scalar names out of a marker line.
_NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")

# The closed, hardcoded in-scope set (repo-root-relative). Resolved against this
# file's own location (lib/test/lint-argjson-transport.py → parents[2] == repo
# root), never a tree walk.
IN_SCOPE = (
    "lib/actionable-patterns.sh",
    "lib/scan.sh",
    "skills/retrospective-weekly/SKILL.md",
)


def _logical_lines(lines):
    """Yield (start_index, joined_text) for each logical line, joining physical
    lines across trailing-backslash continuations. start_index is the 0-based
    index of the logical line's first physical line."""
    i = 0
    n = len(lines)
    while i < n:
        start = i
        joined = lines[i]
        while lines[i].rstrip().endswith("\\") and i + 1 < n:
            i += 1
            joined += "\n" + lines[i]
        yield start, joined
        i += 1


def _has_code_flag(joined):
    """True when ``--argjson`` appears in the CODE portion (before an inline ``#``)
    of any physical line of the logical line — i.e. an actual jq flag, not a
    ``--argjson`` mentioned inside comment prose. Uses the family's quote-aware
    splitter, so a ``#`` inside a string literal does not truncate the code half."""
    return any(FLAG in _tree.strip_comment(pl) for pl in joined.split("\n"))


def _argjson_names(joined):
    """The operand name of every ``--argjson`` in the CODE portion of the logical
    line (quote-aware split, so a ``--argjson`` inside a string literal is ignored)."""
    names = []
    for pl in joined.split("\n"):
        names.extend(_ARGJSON_NAME_RE.findall(_tree.strip_comment(pl)))
    return names


def _marker_line_for(lines, start, joined):
    """Return the single comment line carrying ``# argjson-ok:`` that applies to this
    logical line — the inline comment tail of one of its physical lines (never a marker
    inside a quoted literal, thanks to the quote-aware split), or the ``# argjson-ok:``
    line in the contiguous comment/blank block immediately preceding it. ``None`` if no
    marker applies. The DECLARED scalar names are read from this one line."""
    for pl in joined.split("\n"):
        if MARKER in _tree._comment_split(pl)[1]:
            return _tree._comment_split(pl)[1]
    j = start - 1
    while j >= 0 and (lines[j].strip() == "" or lines[j].lstrip().startswith("#")):
        if MARKER in lines[j]:
            return lines[j]
        j -= 1
    return None


def _declared_names(marker_line):
    """The set of scalar operand names a marker line declares as ``--argjson``-safe —
    every identifier token appearing after the ``# argjson-ok:`` token on that line. The
    rationale prose that follows the names is a harmless superset (a prose word is simply
    a name no ``--argjson`` operand happens to use); what matters is that a corpus operand
    name (``pattern_view``/``a``/``analyzed`` …) is NOT among them, so reverting its
    ``--slurpfile`` to ``--argjson`` yields an undeclared name and fires."""
    after = marker_line[marker_line.find(MARKER) + len(MARKER):]
    return set(_NAME_RE.findall(after))


def audit_text(text):
    """Return a list of (physical_line_number, snippet) for each violating logical line.

    A logical line with a code ``--argjson`` flag violates when it carries no applicable
    ``# argjson-ok:`` marker at all, OR carries one but has a ``--argjson`` operand whose
    name the marker does not declare. The latter is the load-bearing case (issue #783
    review): the marker exempts only the *bounded scalar operands it names*, never the
    whole logical line — so a corpus operand reverted from ``--slurpfile`` to ``--argjson``
    on a jq invocation that also carries marked scalars is caught, not masked by the
    scalars' marker."""
    findings = []
    lines = text.split("\n")
    for start, joined in _logical_lines(lines):
        if not _has_code_flag(joined):
            continue
        names = _argjson_names(joined)
        marker_line = _marker_line_for(lines, start, joined)
        if marker_line is None:
            findings.append((start + 1, joined.strip().splitlines()[0][:100]))
            continue
        declared = _declared_names(marker_line)
        undeclared = [n for n in names if n not in declared]
        if undeclared:
            head = joined.strip().splitlines()[0][:80]
            findings.append(
                (start + 1, f"--argjson operand(s) {undeclared} not declared in marker: {head}")
            )
    return findings


def main(argv):
    # Explicit file arguments (used by the suite's positive-control tests) override
    # the default in-scope set; otherwise audit the three named helpers.
    if argv:
        targets = [Path(a) for a in argv]
    else:
        repo_root = Path(__file__).resolve().parents[2]
        targets = [repo_root / p for p in IN_SCOPE]

    total = 0
    violations = 0
    for path in targets:
        total += 1
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as exc:
            print(f"lint-argjson-transport: cannot read {path}: {exc}", file=sys.stderr)
            violations += 1
            continue
        for lineno, snippet in audit_text(text):
            violations += 1
            print(
                f"{path}:{lineno}: unmarked --argjson in a corpus-aggregating "
                f"retrospective helper — route a corpus-sized operand through "
                f"--slurpfile, or declare a bounded scalar with a "
                f"'# argjson-ok: <reason>' marker (issue #783): {snippet}"
            )

    if violations:
        print(
            f"lint-argjson-transport: {violations} unmarked --argjson occurrence(s) "
            f"across {total} audited file(s)",
            file=sys.stderr,
        )
        return 1
    print(f"lint-argjson-transport: audited {total} of {total} files")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
