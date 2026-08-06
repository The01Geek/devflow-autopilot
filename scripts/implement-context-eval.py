#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Behavioral eval for the runtime main-thread context cost of /prflow:implement.

This is a maintainer/CI-adjacent instrument. No skill, workflow, or suite gate invokes
it for a measurement or a threshold; the only automated execution is its own focused
unit test (lib/test/test_implement_context_eval.py), which asserts parser behavior. It
walks a supplied Claude Code transcript directory and measures the *runtime main-thread
context* a `/prflow:implement` run accumulates from its session transcripts — a distinct
quantity from the static shipped byte count of the phase files on disk (see
docs/internal/implement-context.md).

It is the implement-side sibling of scripts/create-issue-context-eval.py (issue #767),
and reuses that instrument's proven streaming / per-record degradation / symlink-escape
/ determinism design. It deliberately drops the create-issue-only machinery (audit-round
attribution, redundant-Read / re-emission metrics, paired before/after mode); the four
axes it measures are the ones the implement skill's cost shape is dominated by
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

  3. **Main-thread tool calls, bucketed by category** — file reads, file edits/writes,
     shell commands, subagent dispatches, skill invocations, and an `other` catch-all so
     the buckets sum to the run's whole tool-call population. A turn count alone
     mis-attributes the work: one assistant turn can carry several tool calls, so a run
     that batches its calls looks cheaper than one that does not while doing the same
     work (issue #1209 AC10).

  4. **The distribution of wall-clock gaps between consecutive main-thread tool calls** —
     median, maximum and total, never a mean alone, because a mean hides the tail that
     dominates a long run. A record carrying no usable timestamp is counted in the
     `skipped` accounting under `unusable_timestamp` and NEVER contributes a zero gap
     (issue #1209 AC11; `CLAUDE.md`'s *unknown is not zero* rule).

Axes 3 and 4 are reported per run AND aggregated across the corpus, on the same footing
as the peak-context aggregate (issue #1209 AC12). None of the four introduces a gate,
ceiling, threshold, or budget — they are instrument outputs.

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
import datetime
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
    try:
        spec.loader.exec_module(module)
        ids = tuple(ns + "implement" for ns in module.agent_namespaces())
    except Exception as exc:  # noqa: BLE001 - lib/plugin_identity.py is FAIL-CLOSED and
        # raises IdentityError when the identifier set cannot be established (an absent or
        # malformed .claude-plugin/plugin.json or lib/plugin-identity.json — a vendored or
        # partial-slice tree, a mid-migration checkout). Without this arm that exception
        # propagates out of the module-level ATTRIBUTION assignment below, so the fallback
        # this function documents would be unreachable on its likeliest failure and even
        # `--help` would die with a traceback. Catch broadly and breadcrumb the cause: the
        # exception type is the identity module's to choose, not this instrument's.
        print(
            "implement-context-eval: could not resolve the declared namespace set from "
            "{} ({}: {}); falling back to the historical attribution id only — a run "
            "recorded under a renamed namespace will not be attributed".format(
                _IDENTITY_PATH, type(exc).__name__, exc),
            file=sys.stderr,
        )
        return ("devflow:implement",)
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

# Tool name -> the category bucket its calls are counted under (issue #1209 AC10). The
# five categories the AC names at minimum are file reads, file edits/writes, shell
# commands, subagent dispatches and skill invocations; OTHER_TOOL_CATEGORY is the
# catch-all that makes the buckets sum to the run's WHOLE main-thread tool-call
# population, so `total_tool_calls` is never quietly smaller than the work performed.
# An unmapped name lands in `other` rather than being dropped — a new tool in a later
# harness release is then visible as a rising `other` count instead of vanishing.
# This mapping is a standalone mirror of the harness's tool vocabulary (the eval imports
# nothing from the harness); a renamed tool must be mirrored here in the same change.
TOOL_CATEGORY_BY_NAME = {
    "Read": "file_reads",
    "NotebookRead": "file_reads",
    "Edit": "file_edits_writes",
    "MultiEdit": "file_edits_writes",
    "Write": "file_edits_writes",
    "NotebookEdit": "file_edits_writes",
    "Bash": "shell_commands",
    "BashOutput": "shell_commands",
    "KillShell": "shell_commands",
    "Task": "subagent_dispatches",
    "Agent": "subagent_dispatches",
    "Skill": "skill_invocations",
}
OTHER_TOOL_CATEGORY = "other"
# The report's canonical, sorted key order for the tool-call axis — every run reports
# every category, 0 where that category was never used.
TOOL_CATEGORY_LABELS = tuple(sorted(
    set(TOOL_CATEGORY_BY_NAME.values()) | {OTHER_TOOL_CATEGORY}))

# Wall-clock gaps are rounded to this many decimal places so the rendered output stays
# byte-stable across runs (a float's full repr is not).
GAP_DECIMALS = 3

# The peak-context bucket thresholds the aggregate summary reports on.
BUCKET_200K = 200_000
BUCKET_400K = 400_000
# The sentinel a run-derived figure carries when the run population is empty. It is
# NEVER a number and NEVER 0 — an unestablished measurement collapsed onto a real value
# is the bug this instrument (like its create-issue sibling) guards against.
UNESTABLISHED = "unestablished"


def _median(values):
    """Deterministic median of a NON-EMPTY list of numbers.

    Refuses an empty population rather than returning 0: this module's central
    discipline is that an unestablished measurement is never collapsed onto a real
    value, and a primitive that answers `0` for "nothing was measured" is exactly that
    collapse one call away from every future caller. `_median_or_unestablished` is the
    only sanctioned empty-tolerant entry point.
    """
    if not values:
        raise ValueError("median of an empty population")
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
    real `0` and "no runs" must never be the same output), so the SUM fields go through
    this helper rather than an inline `sum(...) if values else UNESTABLISHED` ternary
    repeated per field. The `runs_over_*` bucket COUNTS deliberately do not — they guard
    on a different population, for the reason recorded at their definition in
    `aggregate`.
    """
    return sum(values) if values else UNESTABLISHED


def _parse_timestamp(value):
    """Epoch seconds for an ISO-8601 record timestamp, or None when unusable.

    None is the *unestablished* answer — the caller tallies it into the skip accounting
    and drops the turn from the gap population rather than contributing a zero gap
    (issue #1209 AC11). A naive (offset-less) stamp is read as UTC so two stamps parsed
    here are always differenced on the same clock.
    """
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip()
    if text.endswith(("Z", "z")):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=datetime.timezone.utc)
    return parsed.timestamp()


def _tool_category(name):
    """The AC10 bucket a tool_use block's `name` counts under (unmapped -> `other`)."""
    if not isinstance(name, str):
        return OTHER_TOOL_CATEGORY
    return TOOL_CATEGORY_BY_NAME.get(name, OTHER_TOOL_CATEGORY)


def _gap_stats(times):
    """Median / max / total of the wall-clock gaps between sorted call timestamps.

    Fewer than two timestamped calls yields no gap at all, so every field reads
    UNESTABLISHED — never 0, which would claim a measured instantaneous run.
    """
    ordered = sorted(times)
    gaps = [round(b - a, GAP_DECIMALS) for a, b in zip(ordered, ordered[1:])]
    return {
        "count": len(gaps),
        "median_seconds": _median_or_unestablished(gaps),
        "max_seconds": _max_or_unestablished(gaps),
        "total_seconds": (round(sum(gaps), GAP_DECIMALS) if gaps else UNESTABLISHED),
    }


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

    Holds only small per-turn scalars — one int per attributed turn, one float per
    timestamped tool-bearing turn, and the fixed per-phase / per-category tallies. It
    never retains full record bodies (the streaming property).

    `skipped` is the caller's skip-tally dict (see `new_skip_tally`); the accumulator
    writes the `unusable_timestamp` key into it, so a turn whose timestamp cannot be
    parsed is *accounted*, never silently dropped and never counted as a zero gap.
    """

    def __init__(self, source, skipped=None):
        self.source = source
        self.skipped = new_skip_tally() if skipped is None else skipped
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
        # AC10: category label -> number of main-thread tool_use blocks in that category.
        self.tool_calls = {label: 0 for label in TOOL_CATEGORY_LABELS}
        # AC11: epoch seconds of each main-thread turn that carried at least one tool
        # call. A turn whose timestamp is unusable is tallied into `skipped` instead of
        # entering this list, so it can never contribute a zero gap.
        self.tool_call_times = []

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
        saw_tool_call = False
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") != "tool_use":
                continue
            saw_tool_call = True
            # AC10: every main-thread tool call lands in exactly one category bucket, so
            # the buckets sum to the run's whole tool-call population.
            self.tool_calls[_tool_category(block.get("name"))] += 1
            if block.get("name") == "Read":
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
        if not saw_tool_call:
            return
        # AC11: a tool-bearing turn joins the gap population only with a usable
        # timestamp. An unusable one is ACCOUNTED in the skip tally — never dropped
        # silently, and never folded in as a zero gap.
        stamp = _parse_timestamp(record.get("timestamp"))
        if stamp is None:
            self.skipped["unusable_timestamp"] += 1
        else:
            self.tool_call_times.append(stamp)

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
        tool_calls = {label: self.tool_calls[label] for label in TOOL_CATEGORY_LABELS}
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
            # Tool-call axis (issue #1209 axis 3 / AC10) — bucketed by category, because
            # a turn count alone cannot tell "did more work" from "took more turns".
            "tool_calls": tool_calls,
            "total_tool_calls": sum(tool_calls.values()),
            # Inter-tool-call wall-clock gap axis (issue #1209 axis 4 / AC11) — median,
            # max AND total, never a mean alone.
            "tool_call_gaps": _gap_stats(self.tool_call_times),
        }


def new_skip_tally():
    """A fresh, fully-seeded skip tally.

    The key vocabulary has ONE home here rather than being seeded in `eval_corpus` and
    written by `_iter_session_files` / `RunAccumulator`, which would make an
    under-seeded dict a KeyError at the far end of the walk.
    """
    return {
        "non_json_line": 0,
        "not_object": 0,
        "no_type": 0,
        "unreadable_file": 0,
        "escaped_path": 0,
        "walk_error": 0,
        "malformed_record": 0,
        # A tool-bearing main-thread turn whose timestamp could not be parsed: it leaves
        # the gap population accounted here rather than contributing a zero gap (AC11).
        "unusable_timestamp": 0,
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
    skipped: dict of {reason: count} of records AND session files the walk stepped over —
        malformed records, unreadable files, corpus-escaping symlinks, unwalkable
        directories, and tool-bearing turns with an unusable timestamp. A non-zero total
        is therefore not necessarily "bad transcript data"; read the per-reason keys.
    """
    runs = []
    skipped = new_skip_tally()
    for session_file in _iter_session_files(corpus_root, skipped):
        # The run's identity is the CORPUS-RELATIVE path, not the basename: a corpus with
        # `a/session.jsonl` and `b/session.jsonl` would otherwise emit two run records
        # with the same `source`, which the sort key and every by-source join treat as
        # one. Normalized to forward slashes so the output is host-independent.
        rel_source = os.path.relpath(session_file, corpus_root).replace(os.sep, "/")
        acc = RunAccumulator(rel_source, skipped)
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
    # Tool-call axis (issue #1209 axis 3 / AC10), aggregated across the corpus on the
    # same footing as the peak above (AC12) — per category, median + max + corpus total,
    # in the canonical sorted label order.
    for label in TOOL_CATEGORY_LABELS:
        counts = [r["tool_calls"][label] for r in runs]
        summary["median_{}_calls".format(label)] = _median_or_unestablished(counts)
        summary["max_{}_calls".format(label)] = _max_or_unestablished(counts)
        summary["total_{}_calls".format(label)] = _sum_or_unestablished(counts)
    call_totals = [r["total_tool_calls"] for r in runs]
    summary["median_total_tool_calls"] = _median_or_unestablished(call_totals)
    summary["max_total_tool_calls"] = _max_or_unestablished(call_totals)
    # Gap axis (issue #1209 axis 4 / AC11), aggregated (AC12). A run with fewer than two
    # timestamped tool calls has no measured gap, so it is EXCLUDED from these
    # populations rather than entering them as a 0 — the same exclusion the usage-less
    # run gets from the peak population above.
    gap_maxima = [r["tool_call_gaps"]["max_seconds"] for r in runs
                  if r["tool_call_gaps"]["max_seconds"] != UNESTABLISHED]
    gap_totals = [r["tool_call_gaps"]["total_seconds"] for r in runs
                  if r["tool_call_gaps"]["total_seconds"] != UNESTABLISHED]
    summary["median_run_max_gap_seconds"] = _median_or_unestablished(gap_maxima)
    summary["max_run_max_gap_seconds"] = _max_or_unestablished(gap_maxima)
    summary["median_run_total_gap_seconds"] = _median_or_unestablished(gap_totals)
    summary["max_run_total_gap_seconds"] = _max_or_unestablished(gap_totals)
    summary["corpus_total_gap_seconds"] = (
        round(sum(gap_totals), GAP_DECIMALS) if gap_totals else UNESTABLISHED)
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
    tools = " ".join(
        "{}={}".format(label, r["tool_calls"][label]) for label in TOOL_CATEGORY_LABELS)
    gaps = r["tool_call_gaps"]
    return (
        "- {source}: turns={turn_count} peak={peak_context} final={final_context} "
        "compactions={compact_boundary_count} usage_missing={usage_missing_turns} "
        "phase_reads=[{phase}] total_phase_reads={total_phase_reads} "
        "tool_calls=[{tools}] total_tool_calls={total_tool_calls} "
        # The unit lives in the KEY, never appended to the value: a `{value}s` suffix
        # renders the UNESTABLISHED sentinel as "unestablisheds".
        "gap_seconds=[n={gap_count} median={gap_median} max={gap_max} "
        "total={gap_total}]".format(
            phase=phase, tools=tools, gap_count=gaps["count"],
            gap_median=gaps["median_seconds"], gap_max=gaps["max_seconds"],
            gap_total=gaps["total_seconds"], **r)
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
