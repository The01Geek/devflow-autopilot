#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Behavioral eval for the runtime main-thread context cost of /prflow:implement.

This is a maintainer/CI-adjacent instrument, NEVER invoked by the skill's runtime
path (neither the local nor the cloud tier), by any workflow, or by any test-suite
gate — its only automated caller is its own focused test
(lib/test/test_implement_context_eval.py). It walks a supplied Claude Code transcript
directory and measures the *runtime main-thread context* a `/prflow:implement` run
accumulates from its session transcripts — a distinct quantity from the static shipped
byte count of the phase files on disk (see docs/implement-context.md).

It is the implement-side sibling of scripts/create-issue-context-eval.py (issue #767),
and reuses that instrument's proven streaming / per-record degradation / symlink-escape
/ determinism design. It deliberately drops the create-issue-only machinery (audit-round
attribution, redundant-Read / re-emission metrics, paired before/after mode); the two
axes it measures are the two the implement skill's cost shape is dominated by
(issue #1209):

  1. **Peak main-thread context per run** — the same per-turn sum the create-issue
     instrument uses: `input_tokens + cache_read_input_tokens +
     cache_creation_input_tokens` over the main-thread (non-`isSidechain`) attributed
     assistant records. This is the residency cost a long implement run pays.

  2. **How many times each of the four phase files was read in a run** — the multiplier
     issue #1209 identifies as the cost shape actually worth measuring. The phase files
     are loaded one per phase ENTRY (not all four at once), and each is re-Read "each
     time you (re-)enter this phase" and after every nested-skill return, so the re-read
     COUNT — not the one-time byte size — is what a run's phase-file cost is driven by.
     This axis is reported SEPARATELY from the peak, because they are different
     quantities (issue #1209 AC2).

A "run" is bounded by `attributionSkill` matching any declared `<ns>:implement` on
`type == "assistant"` records. Only a **main-thread** (non-`isSidechain`) attributed
assistant record contributes to the residency axis and to the phase-read count — the
phase files are read by the orchestrator on the main thread, never by a dispatched
subagent. One session JSONL file that contains at least one main-thread attributed
assistant record yields one run; a run that RESUMES into a separate session file is
reported as its own run (cross-session merging is out of scope, a disclosed proxy).

Per-record token usage is read from `message.usage.{input_tokens,
cache_read_input_tokens, cache_creation_input_tokens}`. Compaction is observed as
`type == "system", subtype == "compact_boundary"` and only counted.

A phase-file read is a `Read` tool_use block whose `input.file_path` BASENAME is one of
the four phase file names. Matching on the basename (not a full path) is deliberate: the
skill anchors the read at `<skill-dir>/phases/phase-N-<name>.md`, which resolves to a
local `skills/implement/phases/…` path on the interactive tier and a vendored
`.prflow/vendor/prflow/skills/implement/phases/…` path on the cloud tier — the basename
is the one component stable across both.

The parser streams records line by line (it never buffers an entire session into
memory) and degrades per malformed record without detonating, reporting how many
records it skipped and why. It is deterministic: re-running over the same corpus
yields byte-identical output. It writes NO transcript contents and embeds no
owner-specific identifiers.

Usage:
    implement-context-eval.py <transcript-dir>
                              [--format {text,json}]
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys

# A run is bounded by `attributionSkill`, which carries the LIVE plugin namespace. That
# namespace is renameable, and historical census rows keep whatever namespace was live
# when they were written — so this must accept EVERY declared namespace, not one literal.
# A single hardcoded id silently matches nothing after a rename (every new run rejected,
# the eval reporting zero runs with no error). Derived from the same identity source the
# rest of the repo single-sources (mirrors scripts/create-issue-context-eval.py).
_IDENTITY_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "lib", "plugin_identity.py"
)


def _attribution_ids():
    """Every accepted `<namespace>:implement` attribution id, canonical first.

    Falls back to the historical id rather than an EMPTY set: an empty set would make
    every record mismatch and report a vacuous zero-run measurement, which is exactly
    the silent failure this function exists to prevent.
    """
    spec = importlib.util.spec_from_file_location("plugin_identity", _IDENTITY_PATH)
    if spec is None or spec.loader is None:
        print(
            f"implement-context-eval: identity source {_IDENTITY_PATH} is not "
            "importable; falling back to the historical attribution id only",
            file=sys.stderr,
        )
        return ("devflow:implement",)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    ids = tuple(ns + "implement" for ns in module.agent_namespaces())
    if not ids:
        print(
            "implement-context-eval: the declared namespace set is empty; falling "
            "back to the historical attribution id only",
            file=sys.stderr,
        )
        return ("devflow:implement",)
    return ids


ATTRIBUTION = _attribution_ids()

# The four phase files whose per-run read count issue #1209 measures. The mapping is
# basename -> the short label the report keys the count on. A phase file renamed on disk
# must be mirrored here in the same change (there is no import from the skill; the eval
# is a standalone instrument). PHASE_READ_LABELS is the report's canonical, sorted key
# order for the per-phase axis — every run reports all four, 0 when a phase was never
# entered.
PHASE_FILES = {
    "phase-1-setup.md": "phase1",
    "phase-2-implement.md": "phase2",
    "phase-3-review.md": "phase3",
    "phase-4-documentation.md": "phase4",
}
PHASE_READ_LABELS = tuple(sorted(PHASE_FILES.values()))

# The peak-context bucket thresholds the aggregate summary reports on.
BUCKET_200K = 200_000
BUCKET_400K = 400_000
# The sentinel a run-derived figure carries when the run population is empty. It is
# NEVER a number and NEVER 0 — an unestablished measurement collapsed onto a real value
# is the bug this instrument (like its create-issue sibling) guards against.
UNESTABLISHED = "unestablished"


def _median(values):
    """Deterministic median of a list of numbers (empty -> 0)."""
    if not values:
        return 0
    ordered = sorted(values)
    n = len(ordered)
    mid = n // 2
    if n % 2 == 1:
        return ordered[mid]
    # Even count: mean of the two central values. Keep an int when it divides evenly so
    # the output stays byte-stable across runs.
    lo, hi = ordered[mid - 1], ordered[mid]
    total = lo + hi
    return total // 2 if total % 2 == 0 else total / 2


def _median_or_unestablished(values):
    """The median of a non-empty list, else the UNESTABLISHED sentinel.

    Never 0 for an empty population: an axis with no established operand reports
    `unestablished`, never a real value it did not measure.
    """
    return _median(values) if values else UNESTABLISHED


def _max_or_unestablished(values):
    """The max of a non-empty list, else the UNESTABLISHED sentinel."""
    return max(values) if values else UNESTABLISHED


def _sum_or_unestablished(values):
    """The sum of a non-empty list, else the UNESTABLISHED sentinel.

    The "empty population -> UNESTABLISHED, never 0" invariant is load-bearing (a
    real `0` and "no runs" must never be the same output), so the sum/count fields go
    through this helper rather than an inline `sum(...) if values else UNESTABLISHED`
    ternary repeated per field — one chokepoint, so a field added later cannot quietly
    reintroduce a 0-collapse.
    """
    return sum(values) if values else UNESTABLISHED


def _usage_field(usage, key):
    """Read one usage sub-field, treating null/missing/non-numeric as 0."""
    if not isinstance(usage, dict):
        return 0
    val = usage.get(key)
    if isinstance(val, bool):  # bool is an int subclass; never a token count
        return 0
    if isinstance(val, (int, float)):
        return int(val)
    return 0


def _context_tokens(usage):
    """Residency tokens = input + cache_read + cache_creation (no output)."""
    return (
        _usage_field(usage, "input_tokens")
        + _usage_field(usage, "cache_read_input_tokens")
        + _usage_field(usage, "cache_creation_input_tokens")
    )


class RunAccumulator:
    """Streams one session file's records and accumulates one run's metrics.

    Holds only bounded per-record state — the per-turn context list and the per-phase
    read tally. It never retains full record bodies (the streaming property).
    """

    def __init__(self, source):
        self.source = source
        self.turn_count = 0
        self.per_turn_context = []
        self.compact_boundary_count = 0
        self.attributed = False
        # Attributed main-thread turns that carried NO `usage` object at all. Such a turn
        # has no recorded residency, so it is tallied here rather than folded into
        # per_turn_context as a 0 (which would collapse an unmeasured turn onto a real
        # value and drag the run's peak down — the silent-zero this instrument exists to
        # avoid, one level below the empty-population guard).
        self.usage_missing_turns = 0
        # phase label -> number of Read tool_use blocks that read that phase file.
        self.phase_reads = {label: 0 for label in PHASE_READ_LABELS}

    def observe_system(self, record):
        if record.get("subtype") == "compact_boundary":
            self.compact_boundary_count += 1

    def observe_assistant(self, record):
        # A sidechain (dispatched-subagent) record never touches the main-thread axes:
        # the phase files are read by the orchestrator on the main thread.
        if record.get("isSidechain") is True:
            return
        if record.get("attributionSkill") not in ATTRIBUTION:
            return
        self.attributed = True
        self.turn_count += 1
        # A truthy non-dict `message` (a JSON array/string) would make `.get()` raise;
        # `(x or {})` only rescues a FALSY value, so guard with isinstance — a
        # well-typed-but-wrong-shape record degrades cleanly.
        message = record.get("message")
        if not isinstance(message, dict):
            message = {}
        usage = message.get("usage")
        if isinstance(usage, dict):
            # A usage object is present: sum its residency sub-fields (an absent SUB-field
            # is a legitimate 0 — see _usage_field).
            self.per_turn_context.append(_context_tokens(usage))
        else:
            # No usage object at all on an attributed turn: residency was never recorded.
            # Tally it instead of appending a 0, so an all-usage-absent run reports an
            # UNESTABLISHED peak (see result()) rather than a real-looking 0.
            self.usage_missing_turns += 1

        content = message.get("content")
        if not isinstance(content, list):
            return
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "tool_use" and block.get("name") == "Read":
                # A Read block's `input` may be a non-dict (a list/string); `(x or {})`
                # passes a truthy non-dict through to `.get()` and raises. isinstance-guard.
                block_input = block.get("input")
                if not isinstance(block_input, dict):
                    block_input = {}
                file_path = block_input.get("file_path")
                if not isinstance(file_path, str):
                    continue
                label = PHASE_FILES.get(os.path.basename(file_path))
                if label is not None:
                    self.phase_reads[label] += 1

    def result(self):
        """The run record's own fields.

        An attributed run whose every turn lacked a `usage` object has an empty
        `per_turn_context`, so its peak/final read UNESTABLISHED (never 0): the residency
        was never measured, and a real-looking 0 there is exactly the unknown-onto-zero
        collapse this instrument guards against. `usage_missing_turns` surfaces the gap.
        """
        peak = max(self.per_turn_context) if self.per_turn_context else UNESTABLISHED
        final = self.per_turn_context[-1] if self.per_turn_context else UNESTABLISHED
        # Emit the per-phase counts in the canonical sorted label order so the JSON /
        # text output is byte-stable across runs.
        phase_reads = {label: self.phase_reads[label] for label in PHASE_READ_LABELS}
        return {
            "source": self.source,
            "turn_count": self.turn_count,
            # Residency axis (issue #1209 axis 1).
            "peak_context": peak,
            "final_context": final,
            "compact_boundary_count": self.compact_boundary_count,
            # Attributed turns whose residency was never recorded (no usage object).
            "usage_missing_turns": self.usage_missing_turns,
            # Phase-file re-read axis (issue #1209 axis 2) — reported SEPARATELY from the
            # peak because they are different quantities (AC2).
            "phase_reads": phase_reads,
            "total_phase_reads": sum(phase_reads.values()),
        }


def _iter_session_files(corpus_root, skipped):
    """Yield JSONL session file paths under the corpus root, deterministically.

    Skips any entry whose real path escapes the corpus root (a symlink out), so the
    eval never reads outside the supplied directory. Sorted for determinism. Both
    walk-level drops are TALLIED and breadcrumbed, never silent.
    """
    root_real = os.path.realpath(corpus_root)
    collected = []

    def _on_walk_error(exc):
        skipped["walk_error"] += 1
        sys.stderr.write(
            "warning: skipping unwalkable corpus directory {}: {}\n".format(
                getattr(exc, "filename", "?"), exc
            )
        )

    for dirpath, dirnames, filenames in os.walk(corpus_root, onerror=_on_walk_error):
        dirnames.sort()
        for name in sorted(filenames):
            if not name.endswith(".jsonl"):
                continue
            full = os.path.join(dirpath, name)
            real = os.path.realpath(full)
            if real != root_real and not real.startswith(root_real + os.sep):
                skipped["escaped_path"] += 1
                sys.stderr.write(
                    "warning: skipping session file escaping corpus root {}\n".format(
                        full
                    )
                )
                continue
            collected.append(full)
    collected.sort()
    return collected


def eval_corpus(corpus_root):
    """Return (runs, skipped) for a corpus directory.

    runs: list of per-run metric dicts (only sessions with attributed turns).
    skipped: dict of {reason: count} of malformed records the parser stepped over.
    """
    runs = []
    skipped = {
        "non_json_line": 0,
        "not_object": 0,
        "no_type": 0,
        "unreadable_file": 0,
        "escaped_path": 0,
        "walk_error": 0,
        "malformed_record": 0,
    }
    for session_file in _iter_session_files(corpus_root, skipped):
        acc = RunAccumulator(os.path.basename(session_file))
        try:
            handle = open(session_file, "r", encoding="utf-8", errors="replace")
        except OSError as exc:
            skipped["unreadable_file"] += 1
            sys.stderr.write(
                "warning: skipping unreadable session file {}: {}\n".format(
                    session_file, exc
                )
            )
            continue
        with handle:
            for line in handle:  # streaming: one record at a time, never buffered
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except (ValueError, TypeError):
                    # A truncated final line or a non-JSON line: skip, do not detonate.
                    skipped["non_json_line"] += 1
                    continue
                if not isinstance(record, dict):
                    skipped["not_object"] += 1
                    continue
                rtype = record.get("type")
                if rtype is None:
                    skipped["no_type"] += 1
                    continue
                # Defensive backstop: the observers isinstance-guard their known field
                # shapes, but a record shape not anticipated here must degrade per-record
                # (tallied + breadcrumbed), never detonate the whole corpus walk.
                try:
                    if rtype == "assistant":
                        acc.observe_assistant(record)
                    elif rtype == "system":
                        acc.observe_system(record)
                except (AttributeError, TypeError, ValueError, KeyError) as exc:
                    skipped["malformed_record"] += 1
                    sys.stderr.write(
                        "warning: skipping malformed record in {}: {}\n".format(
                            session_file, exc
                        )
                    )
                    continue
        if acc.attributed:
            runs.append(acc.result())
    runs.sort(key=lambda r: r["source"])
    return runs, skipped


def aggregate(runs):
    """The exactly-these-fields aggregate summary, complete by construction.

    **One convention across every run-derived field.** On an empty run population every
    figure computed from `runs` reads `unestablished` — a reader must never have to know
    which field they are looking at to tell "measured zero" from "no population".
    `run_count` is the one deliberate exception: `0` is its measurement, not a collapsed
    unknown.

    A run whose peak is `UNESTABLISHED` (every attributed turn lacked a usage object) is
    excluded from the peak population — it stays counted in `run_count` and surfaced via
    `total_usage_missing_turns`, but is never averaged in as a real-looking 0.

    **Soundness of the int/`unestablished` union:** it holds only while every reader is a
    pure formatter (`render_text`, `json.dumps` — both treat each value opaquely); a
    future field consumer doing arithmetic must first branch on `UNESTABLISHED`. A median
    can also be a float on an even population (see `_median`), so the median fields are
    `int | float | str`.
    """
    # Exclude UNESTABLISHED peaks (usage-less runs) from the peak population — never
    # coerce them to 0. `peaks` non-empty therefore means "at least one run with a
    # measured peak", which is the population the buckets below guard on.
    peaks = [r["peak_context"] for r in runs if r["peak_context"] != UNESTABLISHED]
    summary = {
        "run_count": len(runs),
        # Attributed turns across the corpus whose residency was never recorded.
        "total_usage_missing_turns": _sum_or_unestablished(
            [r["usage_missing_turns"] for r in runs]),
        # Residency axis (issue #1209 axis 1) — median AND max, so tail behaviour is
        # visible and not hidden by an average (AC3).
        "median_peak_context": _median_or_unestablished(peaks),
        "max_peak_context": _max_or_unestablished(peaks),
        # These count OVER the measured-peak population, so they guard on `peaks`
        # (not the filtered list): with measured runs present but none over threshold the
        # answer is a real 0, never `unestablished` — so `_sum_or_unestablished` (which
        # keys on its own argument being empty) is deliberately NOT used here.
        "runs_over_200k": (sum(1 for p in peaks if p > BUCKET_200K)
                           if peaks else UNESTABLISHED),
        "runs_over_400k": (sum(1 for p in peaks if p > BUCKET_400K)
                           if peaks else UNESTABLISHED),
    }
    # Phase-file re-read axis (issue #1209 axis 2) — per phase, median + max + corpus
    # total, in the canonical sorted label order. Reported separately from the peak.
    for label in PHASE_READ_LABELS:
        counts = [r["phase_reads"][label] for r in runs]
        summary["median_{}_reads".format(label)] = _median_or_unestablished(counts)
        summary["max_{}_reads".format(label)] = _max_or_unestablished(counts)
        summary["total_{}_reads".format(label)] = _sum_or_unestablished(counts)
    totals = [r["total_phase_reads"] for r in runs]
    summary["median_total_phase_reads"] = _median_or_unestablished(totals)
    summary["max_total_phase_reads"] = _max_or_unestablished(totals)
    return summary


def build_report(corpus_root):
    """One run-set report: runs, the aggregate, and the skip tally."""
    runs, skipped = eval_corpus(corpus_root)
    return {
        "runs": runs,
        "summary": aggregate(runs),
        "skipped": skipped,
    }


def _render_run_line(r):
    phase = " ".join(
        "{}={}".format(label, r["phase_reads"][label]) for label in PHASE_READ_LABELS)
    return (
        "- {source}: turns={turn_count} peak={peak_context} final={final_context} "
        "compactions={compact_boundary_count} usage_missing={usage_missing_turns} "
        "phase_reads=[{phase}] total_phase_reads={total_phase_reads}".format(phase=phase, **r)
    )


def render_text(runs, summary, skipped):
    lines = []
    lines.append("# implement runtime main-thread context eval")
    lines.append("")
    lines.append("## Per-run metrics")
    if not runs:
        lines.append("(no implement runs found in the supplied corpus)")
    for r in runs:
        lines.append(_render_run_line(r))
    lines.append("")
    lines.append("## Aggregate summary")
    # aggregate() builds this dict in the canonical field order, so iterating it renders
    # every field once with no per-field literal to keep in sync.
    for key, value in summary.items():
        lines.append("- {}: {}".format(key, value))
    lines.append("")
    total_skipped = sum(skipped.values())
    lines.append("## Skipped records: {}".format(total_skipped))
    for reason in sorted(skipped):
        if skipped[reason]:
            lines.append("- {}: {}".format(reason, skipped[reason]))
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Measure the runtime main-thread context cost of /prflow:implement.",
    )
    parser.add_argument(
        "transcript_dir",
        help="Path to a Claude Code transcript directory.",
    )
    parser.add_argument(
        "--format", choices=("text", "json"), default="text",
        help="Output format (default: text).",
    )
    args = parser.parse_args(argv)

    corpus = args.transcript_dir
    if not os.path.isdir(corpus):
        # No corpus present: exit non-zero naming the missing path — never a
        # silently-empty baseline.
        sys.stderr.write(
            "error: transcript directory not found: {}\n".format(corpus)
        )
        return 2

    report = build_report(corpus)
    runs, summary, skipped = report["runs"], report["summary"], report["skipped"]

    if args.format == "json":
        # Sort keys for byte-stable, deterministic output.
        sys.stdout.write(
            json.dumps(
                {"runs": runs, "summary": summary, "skipped": skipped},
                indent=2, sort_keys=True,
            )
            + "\n"
        )
    else:
        sys.stdout.write(render_text(runs, summary, skipped) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
