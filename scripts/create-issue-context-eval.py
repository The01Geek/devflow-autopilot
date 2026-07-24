#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Behavioral eval for the runtime main-thread context cost of /devflow:create-issue.

This is a maintainer/CI-adjacent instrument, NEVER invoked by the skill's runtime
path (neither the local nor the cloud tier). It walks a supplied Claude Code
transcript directory and measures the *runtime main-thread context* a
`/devflow:create-issue` run accumulates — a distinct quantity from the static
shipped word count of the skill files (see docs/create-issue-context.md).

A "run" is bounded by `attributionSkill == "devflow:create-issue"` on
`type == "assistant"` records; `isSidechain` records are excluded, so summing the
attributed turns measures the ORCHESTRATOR's main-thread context only (dispatched
subagents are not attributed — intended, per the determination doc). One session
JSONL file that contains at least one attributed assistant record yields one run;
a resume that continues in a separate session file is reported as its own run
(cross-session merging is out of scope — a disclosed proxy, see the doc).

Per-record token usage is read from `message.usage.{input_tokens,
cache_read_input_tokens, cache_creation_input_tokens, output_tokens}`. Per-turn
main-thread context is `input_tokens + cache_read_input_tokens +
cache_creation_input_tokens`. Compaction is observed as
`type == "system", subtype == "compact_boundary"` and only counted, never used as
a run splitter or a remedy lever (the corpus shows it is a near-null population).

Two redundant-addition metrics:

  * repeated-Read: a `Read` tool_use whose `input.file_path` repeats within the run
    returning content byte-identical to ANY content already seen for that path (a
    re-fetch of already-resident bytes). A repeated Read whose content is new for the
    path fetches new bytes (authoritative) and is NOT counted. FAIL CLOSED:
    when a Read's `tool_result` content is absent, truncated, or errored for a record
    (the recognized non-authoritative markers — the exact transcript truncation shape
    is not authoritatively established, so unrecognized encodings are an accepted
    residual), that occurrence is counted as authoritative, never folded into the
    redundant count.

  * re-emission: a large (>= LARGE_BLOCK_MIN_CHARS) assistant text block whose exact
    bytes were already produced earlier in the run (as assistant output or as a
    tool_result the run already holds) — an output restatement of already-resident
    content.

The parser streams records line by line (it never buffers an entire session into
memory) and degrades per malformed record without detonating, reporting how many
records it skipped and why. It is deterministic: re-running over the same corpus
yields byte-identical output. It writes NO transcript contents and embeds no
owner-specific identifiers.

Usage:
    create-issue-context-eval.py <transcript-dir> [--format {text,json}]
                                 [--large-block-chars N]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys

ATTRIBUTION = "devflow:create-issue"
# A run's context growth from re-quotation is dominated by large blocks; small
# restatements (a one-line pointer, a status word) are not the reducible cost this
# eval targets. 500 chars ~ a paragraph, well below any real findings/summary block.
LARGE_BLOCK_MIN_CHARS = 500
# The peak-context bucket thresholds the aggregate summary reports on.
BUCKET_200K = 200_000
BUCKET_400K = 400_000


def _digest(text):
    """Stable, salt-independent content digest for byte-identity comparison."""
    return hashlib.sha1(text.encode("utf-8", "replace")).hexdigest()


def _median(values):
    """Deterministic median of a list of numbers (empty -> 0)."""
    if not values:
        return 0
    ordered = sorted(values)
    n = len(ordered)
    mid = n // 2
    if n % 2 == 1:
        return ordered[mid]
    # Even count: mean of the two central values. Keep an int when it divides
    # evenly so the output stays byte-stable across runs.
    lo, hi = ordered[mid - 1], ordered[mid]
    total = lo + hi
    return total // 2 if total % 2 == 0 else total / 2


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


def _tool_result_text(block):
    """Extract the resident string a tool_result carries, or None when it is
    absent / truncated / errored / not fully resident (fail-closed comparand).

    The redundant-repeated-Read metric must fail CLOSED — an occurrence we are not
    certain carries fully-resident, authoritative bytes is treated as authoritative
    (returns None, counted as a fresh read), never folded into the redundant count.
    We recognize the documented non-authoritative markers `truncated: true` and
    `is_error: true`; the exact shape a Claude Code transcript uses to flag a
    truncated Read result is NOT authoritatively established here, so any OTHER
    truncation encoding is an accepted residual (documented, not silently assumed).
    Because an unrecognized-but-truncated result that happened to repeat byte-for-byte
    could inflate the redundant count, we keep this recognized-marker set conservative
    and additive: a new confirmed marker is added here, never removed.
    """
    if not isinstance(block, dict):
        return None
    # An explicit truncation or error marker makes the content non-authoritative.
    if block.get("truncated") is True or block.get("is_error") is True:
        return None
    content = block.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for item in content:
            if isinstance(item, dict) and item.get("type") == "text":
                text = item.get("text")
                if isinstance(text, str):
                    parts.append(text)
                else:
                    return None
            else:
                # A non-text block (image, an unrecognized shape) means we cannot
                # assert byte-identity over the whole result: fail closed.
                return None
        return "".join(parts) if parts else None
    return None


class RunAccumulator:
    """Streams one session file's records and accumulates one run's metrics.

    Holds only bounded per-record state — token tallies, sets of content/large-block
    hashes (not the record bodies themselves), and a pending tool_use_id -> file_path
    map. It never retains full record bodies (the streaming property); the hash/pending
    structures still grow with the count of distinct session content, so this is
    bounded-per-record, not constant memory.
    """

    def __init__(self, source, large_block_chars):
        self.source = source
        self.large_block_chars = large_block_chars
        self.turn_count = 0
        self.per_turn_context = []
        self.total_output_tokens = 0
        self.compact_boundary_count = 0
        self.repeated_read_count = 0
        self.reemission_count = 0
        self.attributed = False
        # tool_use_id -> file_path for pending Read calls awaiting their result.
        self._pending_reads = {}
        # file_path -> set of content hashes already resident for that path.
        self._read_content = {}
        # hashes of large blocks already produced (assistant output or resident
        # tool_result) — the "already-resident" set the re-emission metric checks.
        self._produced_blocks = set()

    def observe_system(self, record):
        if record.get("subtype") == "compact_boundary":
            self.compact_boundary_count += 1

    def observe_user(self, record):
        """A user record may carry tool_result blocks (a Read's returned bytes)."""
        message = record.get("message")
        if not isinstance(message, dict):
            return
        content = message.get("content")
        if not isinstance(content, list):
            return
        for block in content:
            if not isinstance(block, dict) or block.get("type") != "tool_result":
                continue
            tool_use_id = block.get("tool_use_id")
            path = self._pending_reads.pop(tool_use_id, None)
            if path is None:
                continue
            text = _tool_result_text(block)
            if text is None:
                # Fail closed: content absent/truncated -> authoritative, the
                # repeated-Read metric records nothing for this occurrence.
                continue
            digest = _digest(text)
            seen = self._read_content.setdefault(path, set())
            if digest in seen:
                # A repeat of already-resident, byte-identical content.
                self.repeated_read_count += 1
            else:
                seen.add(digest)
            # A large resident tool_result counts as already-produced content, so a
            # later assistant re-quotation of it is a re-emission.
            if len(text) >= self.large_block_chars:
                self._produced_blocks.add(digest)

    def observe_assistant(self, record):
        if record.get("isSidechain") is True:
            return
        if record.get("attributionSkill") != ATTRIBUTION:
            return
        self.attributed = True
        self.turn_count += 1
        usage = (record.get("message") or {}).get("usage")
        context = (
            _usage_field(usage, "input_tokens")
            + _usage_field(usage, "cache_read_input_tokens")
            + _usage_field(usage, "cache_creation_input_tokens")
        )
        self.per_turn_context.append(context)
        self.total_output_tokens += _usage_field(usage, "output_tokens")

        content = (record.get("message") or {}).get("content")
        if not isinstance(content, list):
            return
        for block in content:
            if not isinstance(block, dict):
                continue
            btype = block.get("type")
            if btype == "tool_use" and block.get("name") == "Read":
                file_path = (block.get("input") or {}).get("file_path")
                tool_use_id = block.get("id")
                if isinstance(file_path, str) and tool_use_id is not None:
                    self._pending_reads[tool_use_id] = file_path
            elif btype == "text":
                text = block.get("text")
                if not isinstance(text, str) or len(text) < self.large_block_chars:
                    continue
                digest = _digest(text)
                if digest in self._produced_blocks:
                    # An assistant re-statement of already-produced large content.
                    self.reemission_count += 1
                else:
                    self._produced_blocks.add(digest)

    def result(self):
        peak = max(self.per_turn_context) if self.per_turn_context else 0
        final = self.per_turn_context[-1] if self.per_turn_context else 0
        return {
            "source": self.source,
            "turn_count": self.turn_count,
            "peak_context": peak,
            "final_context": final,
            "total_output_tokens": self.total_output_tokens,
            "compact_boundary_count": self.compact_boundary_count,
            "repeated_read_count": self.repeated_read_count,
            "reemission_count": self.reemission_count,
        }


def _iter_session_files(corpus_root, skipped):
    """Yield JSONL session file paths under the corpus root, deterministically.

    Skips any entry whose real path escapes the corpus root (a symlink out), so the
    eval never reads outside the supplied directory. Sorted for determinism.

    Both walk-level drops are TALLIED and breadcrumbed, never silent (mirroring the
    per-record and unreadable-file skip discipline): a `.jsonl` whose real path
    escapes the corpus root is counted under `escaped_path`, and a directory-walk
    error (a permission-denied dir, a vanished tree) is counted under `walk_error`
    via the `os.walk` `onerror` callback — default `onerror=None` would swallow it.
    """
    root_real = os.path.realpath(corpus_root)
    collected = []

    def _on_walk_error(exc):
        # A directory os.walk could not descend (permissions, a race deletion): tally
        # and breadcrumb so the aggregate is never silently computed over a corpus the
        # walk under-enumerated. `exc.filename` names the offending directory.
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
                # A symlink (or other entry) whose real path escapes the corpus root:
                # never read, but tally + breadcrumb so the drop is visible, not silent.
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


def eval_corpus(corpus_root, large_block_chars=LARGE_BLOCK_MIN_CHARS):
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
    }
    for session_file in _iter_session_files(corpus_root, skipped):
        acc = RunAccumulator(os.path.basename(session_file), large_block_chars)
        try:
            handle = open(session_file, "r", encoding="utf-8", errors="replace")
        except OSError as exc:
            # A session file we enumerated but cannot open (permissions, a broken
            # symlink, a vanished file) is a dropped run: tally it and breadcrumb so
            # the aggregate is never silently computed over an under-counted corpus,
            # mirroring the per-record skip discipline below.
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
                if rtype == "assistant":
                    acc.observe_assistant(record)
                elif rtype == "user":
                    acc.observe_user(record)
                elif rtype == "system":
                    acc.observe_system(record)
        if acc.attributed:
            runs.append(acc.result())
    runs.sort(key=lambda r: r["source"])
    return runs, skipped


def aggregate(runs):
    """The exactly-these-fields aggregate summary, complete by construction."""
    peaks = [r["peak_context"] for r in runs]
    return {
        "run_count": len(runs),
        "median_peak_context": _median(peaks),
        "max_peak_context": max(peaks) if peaks else 0,
        "runs_over_200k": sum(1 for p in peaks if p > BUCKET_200K),
        "runs_over_400k": sum(1 for p in peaks if p > BUCKET_400K),
        "median_repeated_read_count": _median([r["repeated_read_count"] for r in runs]),
        "median_reemission_count": _median([r["reemission_count"] for r in runs]),
    }


def render_text(runs, summary, skipped):
    lines = []
    lines.append("# create-issue runtime main-thread context eval")
    lines.append("")
    lines.append("## Per-run metrics")
    if not runs:
        lines.append("(no create-issue runs found in the supplied corpus)")
    for r in runs:
        lines.append(
            "- {source}: turns={turn_count} peak={peak_context} final={final_context} "
            "output={total_output_tokens} compactions={compact_boundary_count} "
            "repeated_reads={repeated_read_count} reemissions={reemission_count}".format(**r)
        )
    lines.append("")
    lines.append("## Aggregate summary")
    # aggregate() builds this dict in the canonical field order, so iterating it
    # renders every field once with no per-field literal to keep in sync.
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
        description="Measure the runtime main-thread context cost of /devflow:create-issue.",
    )
    parser.add_argument(
        "transcript_dir",
        help="Path to a Claude Code transcript directory (the corpus).",
    )
    parser.add_argument(
        "--format", choices=("text", "json"), default="text",
        help="Output format (default: text).",
    )
    parser.add_argument(
        "--large-block-chars", type=int, default=LARGE_BLOCK_MIN_CHARS,
        help="Minimum size (chars) of a block counted for the re-emission metric.",
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

    runs, skipped = eval_corpus(corpus, args.large_block_chars)
    summary = aggregate(runs)

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
