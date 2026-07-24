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
must *declare* itself with an inline ``# argjson-ok: <reason>`` marker. This guard
turns the suite RED when an aggregating helper regains an unmarked ``--argjson``,
so the E2BIG regression cannot ship silently.

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
operands; ``lib/efficiency-trace.sh`` is not on the retrospective loop's path. The
file set is a hardcoded closed list — this guard reads exactly these three named
paths and performs **no** repository-tree walk (so the #711 tree-enumeration
convention is not engaged).

Marker coverage rule (robust to shell continuation): jq invocations here span
multiple physical lines via backslash-continuation, and shell forbids a ``#``
comment mid-continuation, so a marker may not always sit inline on the
``--argjson`` line. A ``--argjson`` occurrence counts only when it appears in the
*code* portion of a line (before any inline ``#`` comment) — a ``--argjson``
mentioned inside explanatory comment prose is not a jq flag and is ignored. A real
occurrence is COVERED when either the *logical line* that carries it (physical
lines joined across backslash-continuations) contains a ``# argjson-ok:`` marker,
or the contiguous comment block immediately preceding that logical line contains a
``# argjson-ok:`` marker (the block-marker form placed directly above the jq head,
which may itself span several comment lines). Anything else is a violation.
"""

import sys
from pathlib import Path

FLAG = "--argjson"
MARKER = "# argjson-ok:"

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


def _code_before_comment(line):
    """The portion of a physical line before its first ``#`` (an approximation of
    the code vs. comment split — good enough here, where the audited jq flags never
    embed a literal ``#``)."""
    hashpos = line.find("#")
    return line if hashpos < 0 else line[:hashpos]


def _has_code_flag(joined):
    """True when ``--argjson`` appears in the CODE portion (before an inline ``#``)
    of any physical line of the logical line — i.e. an actual jq flag, not a
    ``--argjson`` mentioned inside comment prose."""
    return any(FLAG in _code_before_comment(pl) for pl in joined.split("\n"))


def audit_text(text):
    """Return a list of (physical_line_number, snippet) for each unmarked
    ``--argjson`` occurrence."""
    findings = []
    lines = text.split("\n")
    for start, joined in _logical_lines(lines):
        if not _has_code_flag(joined):
            continue
        # Covered if the marker rides on the same logical line (inline form, valid
        # for a single-line command with a trailing comment), ...
        covered = MARKER in joined
        if not covered:
            # ... or the contiguous comment/blank block immediately preceding this
            # logical line contains the marker (block-marker form above the jq
            # head, which may itself span several comment lines).
            j = start - 1
            while j >= 0 and (lines[j].strip() == "" or lines[j].lstrip().startswith("#")):
                if MARKER in lines[j]:
                    covered = True
                    break
                j -= 1
        if not covered:
            findings.append((start + 1, joined.strip().splitlines()[0][:100]))
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
