#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Partition scan for the review-bundle budget record (issue #656).

Enumerates every *current-measured* figure inside the sentinel-delimited
governed regions of ``docs/review-bundle-budget.md`` and reports any figure
that is in neither the machine-reconciled (live-rendered) set nor the
registered-exempt set. A governed figure in neither state is the silent-drift
this guard exists to kill, so it is printed on stdout and the caller
(``lib/test/run.sh``) turns the suite RED.

This is deliberately a *partition* check, complementary to the positional
per-cell row assertions in ``run.sh``: those prove every reconciled cell still
renders its live value (drift -> RED); this proves no figure was *added* to a
governed region without being accounted (un-sentineled/un-registered add ->
RED), which per-cell assertions on the rows they already cover cannot see.

The scan is **add-directional**: it flags only a figure *present* in a governed
region but absent from the accounted+exempt sets. Two sibling cases it does NOT
catch are covered by the positional pins instead, not here — a governed cell
that *drifts to a value equal to another accounted figure* (still "known", so no
UNACCOUNTED), and the *deletion* of a governed figure (the enumerated set merely
shrinks). Both are caught because every accounted figure ALSO carries a
positional whole-row pin in ``run.sh`` that REDs on the wrong value or a vanished
row; that coupling is load-bearing (see the note at the accounted-set build).

A prose figure is governed only when the ``<!-- rb:fig -->`` marker sits on the
*same physical line* as the figure. A maintainer who wraps a marked bullet so a
figure lands on the unmarked continuation line silently un-governs it — keep each
governed prose figure on its marked line.

Governed regions are delimited in the doc by::

    <!-- rb:governed-begin NAME -->
    ... table rows / marked prose ...
    <!-- rb:governed-end NAME -->

Within a region, a figure is extracted from any Markdown table row (a line
whose first non-space char is ``|``) and from any line carrying an inline
``<!-- rb:fig -->`` marker. Everything else in the region (headings, prose,
formula narration) is ignored, so the frozen decision-record illustrations that
live *outside* the sentinels are out-of-governed by construction.

Usage:
    rb-figure-partition.py DOC ACCOUNTED_FILE EXEMPT_FILE

ACCOUNTED_FILE / EXEMPT_FILE each carry one normalized figure per line
(comma-stripped, ``−`` folded to ``-``); blank lines and ``#``-comment lines are
ignored, so the caller may annotate the exempt registry with rationale.

Exit status is always 0 (a diagnostic, not a gate); the caller decides RED/GREEN
from whether stdout is empty. Any unreadable input prints a ``FATAL:`` line so a
missing file fails closed (non-empty stdout -> RED) rather than vacuously green.
"""
import re
import sys

# A figure token: an optional minus (ASCII or U+2212) then a digit run with
# optional comma grouping. The lookbehind rejects a token whose immediately
# preceding char is a word char, '#', '.', or a minus — so an issue ref '#618',
# the digits of 'AC3', and the fractional part of a version ('2.19' -> '19'
# excluded) are not figures. (A version's *leading* digit, e.g. the '2' of
# '2.19', is not excluded by this — but no bare 'N.NN' version sits inside a
# governed sentinel region, so it never reaches the scan.)
_FIG = re.compile(r"(?<![\w#.\-−])[\-−]?\d[\d,]*")


def _norm(tok: str) -> str:
    """Normalize a matched token to compare against the accounted/exempt sets."""
    return tok.replace(",", "").replace("−", "-")


def _load_set(path: str) -> set:
    out = set()
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            out.add(_norm(s))
    return out


def _regions_declared(doc: str):
    """Return every governed region name the doc opens, in document order."""
    return re.findall(r"<!--\s*rb:governed-begin\s+(\S+)\s*-->", doc)


def _governed_figures(doc: str):
    """Yield (region, normalized_figure, raw_line) for every governed figure."""
    region = None
    for raw in doc.splitlines():
        b = re.search(r"<!--\s*rb:governed-begin\s+(\S+)\s*-->", raw)
        if b:
            region = b.group(1)
            continue
        if re.search(r"<!--\s*rb:governed-end\b", raw):
            region = None
            continue
        if region is None:
            continue
        stripped = raw.lstrip()
        is_row = stripped.startswith("|")
        is_fig = "<!-- rb:fig -->" in raw
        if not (is_row or is_fig):
            continue
        for m in _FIG.finditer(raw):
            yield region, _norm(m.group(0)), raw


def main(argv):
    if len(argv) != 4:
        print("FATAL: usage: rb-figure-partition.py DOC ACCOUNTED_FILE EXEMPT_FILE")
        return 0
    doc_path, acc_path, exempt_path = argv[1], argv[2], argv[3]
    try:
        doc = open(doc_path, encoding="utf-8").read()
        accounted = _load_set(acc_path)
        exempt = _load_set(exempt_path)
    except (OSError, ValueError) as e:
        # ValueError covers UnicodeDecodeError (a non-UTF-8/corrupted doc or set
        # file). Catching only OSError would let the decode traceback go to
        # stderr with an EMPTY stdout — which the caller's output-is-empty
        # assertion reads as a clean pass. That is the fail-open this guard exists
        # to prevent, inside the guard.
        print(f"FATAL: could not read partition inputs: {e}")
        return 0
    if not accounted:
        print("FATAL: accounted set is empty (non-vacuity floor) — the live "
              "reconciliation did not render any figure; refusing to pass vacuously")
        return 0
    seen_any = False
    known = accounted | exempt
    populated = set()
    for region, fig, raw in _governed_figures(doc):
        seen_any = True
        populated.add(region)
        if fig not in known:
            print(f"UNACCOUNTED[{region}]: {fig}  (line: {raw.strip()})")
    # Per-region non-vacuity floor. A governed region that yields NO figure is a
    # region whose figures stopped being seen — the prose-figure case is the live
    # one: `_governed_figures` only reads a non-table line when `<!-- rb:fig -->`
    # is on that SAME physical line, so an editor who rewraps the sentence and
    # pushes the marker onto its own line silently un-governs the figure. The
    # whole-doc floor below cannot catch that (other regions still yield figures),
    # so each declared region carries its own floor.
    for region in _regions_declared(doc):
        if region not in populated:
            print(f"FATAL: governed region '{region}' yields no figure — its "
                  "figures are un-sentineled or its `<!-- rb:fig -->` marker no "
                  "longer sits on the figure's own line; refusing to pass vacuously")
    if not seen_any:
        print("FATAL: no governed figure found in any sentinel region — the "
              "governed regions are missing or empty; refusing to pass vacuously")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
