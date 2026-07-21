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
# optional comma grouping. Anchored so a token glued to a '#', a letter, or a
# '.' (an issue ref '#618', 'AC3', a version '2.19') is NOT treated as a figure.
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
    except OSError as e:
        print(f"FATAL: could not read partition inputs: {e}")
        return 0
    if not accounted:
        print("FATAL: accounted set is empty (non-vacuity floor) — the live "
              "reconciliation did not render any figure; refusing to pass vacuously")
        return 0
    seen_any = False
    known = accounted | exempt
    for region, fig, raw in _governed_figures(doc):
        seen_any = True
        if fig not in known:
            print(f"UNACCOUNTED[{region}]: {fig}  (line: {raw.strip()})")
    if not seen_any:
        print("FATAL: no governed figure found in any sentinel region — the "
              "governed regions are missing or empty; refusing to pass vacuously")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
