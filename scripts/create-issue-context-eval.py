#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Behavioral eval for the runtime main-thread context cost of /devflow:create-issue.

This is a maintainer/CI-adjacent instrument, NEVER invoked by the skill's runtime
path (neither the local nor the cloud tier). It walks a supplied Claude Code
transcript directory and measures the *runtime main-thread context* a
`/devflow:create-issue` run accumulates — a distinct quantity from the static
shipped word count of the skill files (see docs/create-issue-context.md).

Issue #889 extends the instrument to attribute the **Step 3.6 audit round** cost
that #793 introduced. That cost is spent by the auditor **subagent**, whose turns
the harness emits as `isSidechain` records — records the pre-#889 instrument
dropped with a single line. This module now attributes those sidechain `usage`
records to rounds, deriving the round boundaries from the transcript's own
`issue-audit-state.py record-dispatch --round N` tool-use records and reading the
round->kind labelling (and the per-finding quoted draft line + per-round scope) from
the audit state file **best-effort**: every degraded state-file shape yields
`unestablished` per-kind figures with a stderr breadcrumb, never a number and never
a crash.

One of the three escaped-defect proxies is NOT reportable against any state file this
repository writes today: the scope-escape proxy needs a `scope.draft_lines` span on a
targeted round, and `scripts/issue-audit-state.py`'s `record-dispatch` records no such
key (see `_scope_draft_span`). It therefore reports `unestablished` on every real
state file rather than the `0` that would read as "no defects escaped scope". The
other two proxies — the `record-reopen` count and the declared post-filing class —
are unaffected.

A "run" is bounded by `attributionSkill == "devflow:create-issue"` on
`type == "assistant"` records. A **main-thread** (non-`isSidechain`) attributed
assistant record measures the ORCHESTRATOR's main-thread context — reported as a
**secondary** axis (never the sole basis of a reduction claim). A **sidechain**
attributed assistant record is the auditor's own turn; its total token cost is
attributed to the round the most recent `record-dispatch --round N` marker opened.
One session JSONL file that contains at least one main-thread attributed assistant
record yields one run.

Per-record token usage is read from `message.usage.{input_tokens,
cache_read_input_tokens, cache_creation_input_tokens, output_tokens}`. Per-turn
main-thread context is `input_tokens + cache_read_input_tokens +
cache_creation_input_tokens`; the auditor's per-round cost is the full token total
(context sub-fields + output). Compaction is observed as
`type == "system", subtype == "compact_boundary"` and only counted.

Two redundant-addition metrics are also reported (pre-#889, retained): repeated-Read
(a `Read` re-fetching bytes already resident for that path — fail-closed on a
truncated/errored/absent tool_result) and re-emission (a large assistant text block
whose exact bytes were already produced earlier in the run).

Wall-clock is deliberately NOT claimed as a measured axis on this tier: it is
reported `unestablished`, citing docs/efficiency-trace.md's local-tier row, rather
than asserted as something the orchestrator observes. No cost figure is sourced
from a value the orchestrator volunteers — the harness emits the same data
deterministically (docs/efficiency-trace.md, agent-volunteered-operand record).

The parser streams records line by line (it never buffers an entire session into
memory) and degrades per malformed record without detonating, reporting how many
records it skipped and why. It is deterministic: re-running over the same corpus
yields byte-identical output. It writes NO transcript contents and embeds no
owner-specific identifiers.

Usage:
    create-issue-context-eval.py <transcript-dir> [--state-file F]
                                 [--format {text,json}] [--large-block-chars N]
    create-issue-context-eval.py --before <dir> --after <dir>
                                 [--before-state F] [--after-state F]
                                 [--format {text,json}] [--large-block-chars N]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys

ATTRIBUTION = "devflow:create-issue"
# A run's context growth from re-quotation is dominated by large blocks; small
# restatements (a one-line pointer, a status word) are not the reducible cost this
# eval targets. 500 chars ~ a paragraph, well below any real findings/summary block.
LARGE_BLOCK_MIN_CHARS = 500
# The peak-context bucket thresholds the aggregate summary reports on.
BUCKET_200K = 200_000
BUCKET_400K = 400_000
# The sentinel a per-kind / proxy figure carries when the state file could not
# supply the operand it needs. It is NEVER a number and NEVER 0 — an unestablished
# measurement collapsed onto a real value is the bug the whole axis guards against.
UNESTABLISHED = "unestablished"
# The closed round-kind vocabulary #793 records on each round.
#
# Coupled with `_ROUND_KINDS` in scripts/issue-audit-state.py — the closed, complete
# round-kind vocabulary that module owns (issue #793). This is a deliberate duplicated
# literal (the eval is a standalone stdlib-only instrument that imports nothing from the
# state owner); a new kind added there must be mirrored here in the same change.
# `ROUND_KINDS_COUPLING_ASSERTED_BY` names the test that reconciles the two tuples, so
# the drift this comment warns about goes RED rather than shipping green.
#
# The degradation it causes, stated exactly: `read_state` returns None for the WHOLE
# state file when any round carries a PRESENT-but-unmirrored kind — collapsing both
# per-kind medians, both scope-escape fields and every other round's labelling, not
# merely the one round. An ABSENT kind is legal in a persisted round (a pre-#793 record)
# and is defaulted to `discovery`, exactly as the state owner's own read boundary does.
ROUND_KINDS = ("discovery", "targeted")
ROUND_KINDS_COUPLING_ASSERTED_BY = (
    "lib/test/test_create_issue_context_eval.py::RoundKindCouplingTest")
# The kind a round record carrying no `kind` field is read as — the same permissive
# default `scripts/issue-audit-state.py`'s readers apply to a pre-#793 round.
_ABSENT_KIND_DEFAULT = "discovery"
# The `record-dispatch --round N` marker the state owner writes on the main thread —
# the sole round-boundary source (the state file carries no clock to join on).
#
# Anchored on the state-owner script name so the marker is a CONTRACT rather than a
# substring: a `grep record-dispatch`, an `echo`, or a `cat` of this skill reference in
# a main-thread Bash block no longer opens a spurious round boundary or inflates the
# reopen tally. The round value is accepted quoted or bare because the skill's rendered
# fence writes `--round "<round>"` (quoted) while the fixtures write it bare — a regex
# that required a bare digit derived NO round boundary on a faithful real transcript.
_DISPATCH_ROUND_RE = re.compile(
    r"issue-audit-state\.py\s+record-dispatch\b[^\n]*?--round\s+[\"']?(\d+)")
_REOPEN_RE = re.compile(r"issue-audit-state\.py\s+record-reopen\b")


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


def _median_or_unestablished(values):
    """The median of a non-empty list, else the UNESTABLISHED sentinel.

    Never 0 for an empty population: an axis with no established operand reports
    `unestablished`, never a real value it did not measure.
    """
    return _median(values) if values else UNESTABLISHED


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
    """Main-thread context = input + cache_read + cache_creation (no output)."""
    return (
        _usage_field(usage, "input_tokens")
        + _usage_field(usage, "cache_read_input_tokens")
        + _usage_field(usage, "cache_creation_input_tokens")
    )


def _auditor_cost(usage):
    """The auditor's per-turn cost = every token the sidechain turn consumed.

    Distinct from `_context_tokens`: the auditor's own output is part of the cost
    #793 buys down, so output_tokens is included here (it is excluded from the
    main-thread *context* axis, which measures residency, not spend).
    """
    return _context_tokens(usage) + _usage_field(usage, "output_tokens")


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
    hashes (not the record bodies themselves), a pending tool_use_id -> file_path
    map, and the per-round auditor-cost tally. It never retains full record bodies
    (the streaming property); the hash/pending structures still grow with the count
    of distinct session content, so this is bounded-per-record, not constant memory.
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
        # Round boundaries are derived from the transcript's own record-dispatch
        # markers (issue #889): the most recent `--round N` marker names the round a
        # subsequent sidechain (auditor) turn is attributed to.
        self.current_round = None
        self.dispatch_rounds = set()         # rounds seen (deduped; order is irrelevant)
        self.round_auditor_cost = {}         # round_num -> total auditor token cost
        self.unrounded_auditor_cost = 0      # sidechain cost before any dispatch marker
        self.record_reopen_count = 0         # escaped-defect proxy 1
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

    def _observe_sidechain(self, record):
        """Attribute one auditor (sidechain) turn's cost to the current round.

        The sidechain record is NOT a main-thread turn: it never sets `attributed`
        (a session of only sidechain turns yields no run), never increments
        `turn_count`, and never touches the residency (context) axis — it feeds only
        the round-attributed auditor-cost tally.
        """
        if record.get("attributionSkill") != ATTRIBUTION:
            return
        message = record.get("message")
        if not isinstance(message, dict):
            message = {}
        cost = _auditor_cost(message.get("usage"))
        if self.current_round is None:
            # A sidechain turn before any dispatch marker cannot be keyed to a round;
            # it is held separately, never silently folded into round 1.
            self.unrounded_auditor_cost += cost
        else:
            self.round_auditor_cost[self.current_round] = (
                self.round_auditor_cost.get(self.current_round, 0) + cost
            )

    def _observe_markers(self, block_input):
        """Scan one main-thread Bash tool_use for round-boundary / reopen markers."""
        if not isinstance(block_input, dict):
            return
        command = block_input.get("command")
        if not isinstance(command, str):
            return
        m = _DISPATCH_ROUND_RE.search(command)
        if m is not None:
            rnd = int(m.group(1))
            self.current_round = rnd
            self.dispatch_rounds.add(rnd)
        if _REOPEN_RE.search(command):
            self.record_reopen_count += 1

    def observe_assistant(self, record):
        if record.get("isSidechain") is True:
            self._observe_sidechain(record)
            return
        if record.get("attributionSkill") != ATTRIBUTION:
            return
        self.attributed = True
        self.turn_count += 1
        # A truthy non-dict `message` (a JSON array/string) would make `.get()` raise;
        # `(x or {})` only rescues a FALSY value, so guard with isinstance (mirroring
        # observe_user) — a well-typed-but-wrong-shape record degrades cleanly.
        message = record.get("message")
        if not isinstance(message, dict):
            message = {}
        usage = message.get("usage")
        self.per_turn_context.append(_context_tokens(usage))
        self.total_output_tokens += _usage_field(usage, "output_tokens")

        content = message.get("content")
        if not isinstance(content, list):
            return
        for block in content:
            if not isinstance(block, dict):
                continue
            btype = block.get("type")
            if btype == "tool_use" and block.get("name") == "Read":
                # A Read block's `input` may be a non-dict (a list/string); `(x or {})`
                # passes a truthy non-dict through to `.get()` and raises. isinstance-guard.
                block_input = block.get("input")
                if not isinstance(block_input, dict):
                    block_input = {}
                file_path = block_input.get("file_path")
                tool_use_id = block.get("id")
                if isinstance(file_path, str) and tool_use_id is not None:
                    self._pending_reads[tool_use_id] = file_path
            elif btype == "tool_use" and block.get("name") == "Bash":
                # The main-thread state-owner invocations that mark round boundaries
                # (record-dispatch) and reopen events (record-reopen) — issue #889.
                self._observe_markers(block.get("input"))
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
        round_cost = {n: self.round_auditor_cost[n]
                      for n in sorted(self.round_auditor_cost)}
        return {
            "source": self.source,
            "turn_count": self.turn_count,
            # Main-thread residency (SECONDARY axis, issue #889 — never the sole
            # basis of the reduction claim).
            "peak_context": peak,
            "final_context": final,
            "total_output_tokens": self.total_output_tokens,
            "compact_boundary_count": self.compact_boundary_count,
            "repeated_read_count": self.repeated_read_count,
            "reemission_count": self.reemission_count,
            # Round-attributed auditor cost (PRIMARY axis, issue #889).
            "round_auditor_cost": round_cost,
            "unrounded_auditor_cost": self.unrounded_auditor_cost,
            "attributed_auditor_cost": sum(round_cost.values()) + self.unrounded_auditor_cost,
            "dispatch_rounds": sorted(self.dispatch_rounds),
            "record_reopen_count": self.record_reopen_count,
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
        "malformed_record": 0,
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
                # Defensive backstop: the observers isinstance-guard their known field
                # shapes, but a record shape not anticipated here must degrade per-record
                # (tallied + breadcrumbed), never detonate the whole corpus walk. This is
                # what makes the module docstring's "without detonating" guarantee true.
                try:
                    if rtype == "assistant":
                        acc.observe_assistant(record)
                    elif rtype == "user":
                        acc.observe_user(record)
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


# ── State-file reader (issue #889) — best-effort, never a number on a bad shape ──

def _degraded_state(state_path, reason):
    """Emit the degraded-read breadcrumb and return the None sentinel.

    Every degraded arm routes through here so an operator who supplied a path can tell
    "I passed nothing" from "the path I passed could not be used" — without it a
    mistyped `--state-file` is byte-identical in output to omitting the flag, and the
    honest `unestablished` reads as a disclosure about the data rather than about the
    operator's own typo. `state_path` is falsy only on the omitted-flag arm, which is
    not a degradation and emits nothing.
    """
    if state_path:
        sys.stderr.write(
            "create-issue-context-eval: state file {} not usable ({}); "
            "every state-derived figure reads {}\n".format(
                state_path, reason, UNESTABLISHED))
    return None


def read_state(state_path):
    """Read one audit state file's round labelling, best-effort.

    Returns a dict {round_num(int): {"kind": str, "scope": dict|None,
    "findings": list}} on success, or None when the state file is absent, unreadable,
    undecodable, empty, malformed, carries a wrong-typed `rounds` container, or carries
    a round whose PRESENT kind is outside `ROUND_KINDS`. A None return makes every
    per-kind and scope-escape figure read `unestablished` — never a number and never a
    crash (AC8); every degraded arm also writes a stderr breadcrumb naming the path and
    the reason.

    An ABSENT `kind` is NOT a degradation: `scripts/issue-audit-state.py` accepts a
    round record carrying none (a pre-#793 round) and its readers default it to
    `discovery`, so this reader applies the same default rather than collapsing a whole
    otherwise-valid state file over one legacy round.

    The state file supplies ONLY what the transcript cannot: the round→kind
    labelling, the per-round scope, and the per-finding quoted draft line. It carries
    no time or ordering coordinate — round boundaries come from the transcript alone
    (this module imports no time facility), so there is no join to attempt here.
    """
    if not state_path:
        return None
    try:
        with open(state_path, "r", encoding="utf-8") as fh:
            raw = fh.read()
    # UnicodeDecodeError is a ValueError, NOT an OSError: a state file carrying any
    # non-UTF-8 byte is squarely inside AC8's "unreadable" shape and must degrade here,
    # never propagate out of the instrument as a traceback.
    except (OSError, ValueError) as exc:
        return _degraded_state(state_path, "unreadable: {}".format(exc))
    if not raw.strip():
        return _degraded_state(state_path, "empty")
    try:
        doc = json.loads(raw)
    except (ValueError, TypeError) as exc:
        return _degraded_state(state_path, "not parseable JSON: {}".format(exc))
    if not isinstance(doc, dict):
        return _degraded_state(state_path, "top level is not an object")
    rounds = doc.get("rounds")
    if not isinstance(rounds, list):
        return _degraded_state(state_path, "`rounds` is not a list")
    by_num = {}
    for rnd in rounds:
        if not isinstance(rnd, dict):
            return _degraded_state(state_path, "a round record is not an object")
        num = rnd.get("round")
        if not isinstance(num, int) or isinstance(num, bool):
            return _degraded_state(
                state_path, "a round carries no integer round number")
        kind = rnd.get("kind")
        if kind is None:
            kind = _ABSENT_KIND_DEFAULT
        elif kind not in ROUND_KINDS:
            # A PRESENT-but-unmirrored kind collapses the whole labelling to
            # unestablished rather than silently reporting a partial per-kind figure.
            return _degraded_state(
                state_path,
                "round {} names the unrecognized kind {!r}".format(num, kind))
        scope = rnd.get("scope") if isinstance(rnd.get("scope"), dict) else None
        findings = rnd.get("findings") if isinstance(rnd.get("findings"), list) else []
        by_num[num] = {"kind": kind, "scope": scope, "findings": findings}
    return by_num


def _scope_draft_span(scope):
    """The [start, end] draft-line span a round's scope declares, or None.

    Draft-space coordinates (issue #889): the scope-escape proxy compares two
    coordinates in the DRAFT's own space, so the operand is a draft-line span, not a
    repository path:line.

    KNOWN GAP, disclosed rather than papered over: no producer in this repository
    writes `scope.draft_lines` today. `scripts/issue-audit-state.py`'s `record-dispatch`
    composes a targeted round's scope as `{basis_digest, sections, claim_ids}`, and
    `sections` holds heading strings, not line spans. Every caller therefore reaches the
    `None` return on a real state file — which is exactly why `scope_escape_proxy`
    reports `unestablished` rather than a confident `0` in that case. Adding the
    producer is tracked as follow-up work; until it lands the proxy is honest about
    being unfillable instead of reporting the value that reads as "nothing escaped".
    """
    if not isinstance(scope, dict):
        return None
    span = scope.get("draft_lines")
    if (isinstance(span, list) and len(span) == 2
            and all(isinstance(x, int) and not isinstance(x, bool) for x in span)
            and span[0] <= span[1]):
        return (span[0], span[1])
    return None


def _finding_draft_line(finding):
    """The draft line a finding quoted as the line it attacks, or None (unattributable).

    Accepts exactly what `scripts/issue-audit-state.py` accepts at BOTH its own
    boundaries for this field — a non-bool int `>= 1`. A re-derived, wider predicate
    (any non-bool int, admitting `0` and negatives) would treat a hand-edited `-5` as
    attributable and silently shrink the honest denominator, the accepted-set-drift the
    repo's share-the-contract rule exists to stop.
    """
    if not isinstance(finding, dict):
        return None
    q = finding.get("quoted_draft_line")
    if isinstance(q, int) and not isinstance(q, bool) and q >= 1:
        return q
    return None


# The ledger status a must-revise finding carries while it is still outstanding. AC9
# scopes the scope-escape proxy to must-revise findings, and a `resolved`/`invalidated`/
# `superseded` entry in a later round is a settled one — counting it would report a
# scope escape that the round itself already disposed of, and would also inflate the
# unattributable denominator. Mirrors `_LEDGER_STATUSES` in scripts/issue-audit-state.py.
_UNRESOLVED_STATUS = "unresolved"


def _is_outstanding_must_revise(finding):
    """True for a ledger entry that is still an outstanding must-revise finding."""
    return (isinstance(finding, dict)
            and finding.get("status") == _UNRESOLVED_STATUS)


def scope_escape_proxy(state):
    """The scope-escape proxy and its own denominator (AC9 proxy 2 + AC11).

    Returns {"count": int|UNESTABLISHED, "unattributable": int|UNESTABLISHED} where
    `count` is the number of later-round OUTSTANDING must-revise findings whose quoted
    draft line falls inside an earlier `targeted` round's recorded draft-space scope,
    and `unattributable` is the denominator: later-round outstanding must-revise
    findings carrying NO recorded draft line. An unattributable finding is never counted
    as attributable and never counted as zero.

    Both figures read `unestablished` — never `0` — whenever the comparand cannot be
    established: no state at all, or ANY `targeted` round whose scope yields no usable
    draft-line span. That second arm is the load-bearing one: no producer in this repo
    writes `scope.draft_lines` yet (see `_scope_draft_span`), so on every real state
    file the proxy is unfillable, and reporting `0` there would publish the value that
    reads as "no defects escaped scope" about a comparison that never ran. A state
    carrying NO targeted round at all is a different case — nothing could escape a scope
    that was never dispatched — and that is a genuine, established `0`.
    """
    if state is None:
        return {"count": UNESTABLISHED, "unattributable": UNESTABLISHED}
    targeted = []  # (round_num, start, end)
    for num, rnd in state.items():
        if rnd["kind"] != "targeted":
            continue
        span = _scope_draft_span(rnd["scope"])
        if span is None:
            # A targeted round whose span is absent, wrong-typed or inverted makes the
            # whole comparison partial. Fail the WHOLE proxy to unestablished rather
            # than dropping the round silently and emitting a real-looking integer.
            return {"count": UNESTABLISHED, "unattributable": UNESTABLISHED}
        targeted.append((num, span[0], span[1]))
    count = 0
    unattributable = 0
    for num, rnd in state.items():
        earlier_targeted = [(s, e) for t_num, s, e in targeted if t_num < num]
        if not earlier_targeted:
            continue  # not a "later round" relative to any targeted scope
        for finding in rnd["findings"]:
            if not _is_outstanding_must_revise(finding):
                continue
            line = _finding_draft_line(finding)
            if line is None:
                unattributable += 1
                continue
            if any(s <= line <= e for s, e in earlier_targeted):
                count += 1
    return {"count": count, "unattributable": unattributable}


def per_kind_medians(runs, state):
    """Median attributed auditor cost per round kind across the runs (AC6).

    A round contributes its attributed cost to its kind's population only when the
    state file established that kind; with no state (or a degraded one) every per-kind
    figure reads `unestablished`.
    """
    if state is None:
        return {k: UNESTABLISHED for k in ROUND_KINDS}
    buckets = {k: [] for k in ROUND_KINDS}
    for run in runs:
        for rnum, cost in run["round_auditor_cost"].items():
            rnd = state.get(rnum)
            if rnd is not None and rnd["kind"] in buckets:
                buckets[rnd["kind"]].append(cost)
    return {k: _median_or_unestablished(buckets[k]) for k in ROUND_KINDS}


def aggregate(runs, state=None):
    """The exactly-these-fields aggregate summary, complete by construction.

    `state` (issue #889) supplies the round→kind labelling the per-kind medians need;
    absent or degraded state makes those figures `unestablished` (never a number).
    """
    peaks = [r["peak_context"] for r in runs]
    medians = per_kind_medians(runs, state)
    escape = scope_escape_proxy(state)
    return {
        "run_count": len(runs),
        # Secondary residency axis.
        "median_peak_context": _median(peaks),
        "max_peak_context": max(peaks) if peaks else 0,
        "runs_over_200k": sum(1 for p in peaks if p > BUCKET_200K),
        "runs_over_400k": sum(1 for p in peaks if p > BUCKET_400K),
        "median_repeated_read_count": _median([r["repeated_read_count"] for r in runs]),
        "median_reemission_count": _median([r["reemission_count"] for r in runs]),
        # Primary round-attributed auditor-cost axis (issue #889). An empty run
        # population reads `unestablished`, never `0` — "the auditor cost nothing" is a
        # real value this instrument must not publish about a corpus it never measured.
        "median_attributed_auditor_cost": _median_or_unestablished(
            [r["attributed_auditor_cost"] for r in runs]),
        # How much of that primary axis is sidechain cost NO round boundary could key.
        # `attributed_auditor_cost` folds it in, so publishing it beside the median is
        # what keeps a wholly-unattributed total from reading as a round-attributed one.
        "total_unrounded_auditor_cost": sum(
            r["unrounded_auditor_cost"] for r in runs),
        "median_auditor_cost_discovery": medians["discovery"],
        "median_auditor_cost_targeted": medians["targeted"],
        # Escaped-defect axis proxies. Flattened into two scalars so every summary field
        # renders as a scalar in the text report rather than one raw dict repr.
        "total_record_reopen": sum(r["record_reopen_count"] for r in runs),
        "scope_escape_count": escape["count"],
        "scope_escape_unattributable": escape["unattributable"],
        # A declared post-filing class the instrument reports unestablished, never a
        # number: escaped defects found AFTER the issue is filed are outside any
        # transcript or state file this instrument reads.
        "post_filing_escapes": UNESTABLISHED,
        # Wall-clock is not a measured axis on this tier (AC4).
        "wall_clock": UNESTABLISHED,
    }


def _join_round_kinds(runs, state):
    """Stamp each run's per-round breakdown with the round's RECORDED kind (AC6).

    AC6 asks for a per-run breakdown carrying each round's recorded kind alongside its
    attributed cost, so the kind must not live only in the aggregate per-kind medians —
    a reader of one run's report has to be able to tell which of ITS rounds were
    targeted. With no state (or a degraded one) each entry reads `unestablished`, never
    a guessed kind.

    KNOWN GAP, disclosed: the state file keys rounds by NUMBER alone, so a corpus of
    several runs joined against a single state file labels every run's round N with that
    one state's round N. The join is correct for the one-run-per-state case the paired
    mode uses; a multi-run corpus needs a per-run state file, which the state owner does
    not yet emit a run coordinate for.
    """
    for run in runs:
        run["round_kinds"] = {
            n: (state[n]["kind"] if state is not None and n in state
                else UNESTABLISHED)
            for n in run["round_auditor_cost"]
        }
    return runs


def build_report(corpus_root, state_path=None, large_block_chars=LARGE_BLOCK_MIN_CHARS):
    """One run-set report: runs, the aggregate, and the skip tally."""
    runs, skipped = eval_corpus(corpus_root, large_block_chars)
    state = read_state(state_path)
    _join_round_kinds(runs, state)
    return {
        "runs": runs,
        "summary": aggregate(runs, state),
        "skipped": skipped,
        "state_established": state is not None,
        # Finding count comes from the state we already read here — the paired path
        # reuses this rather than re-parsing the state file (single-corpus reports
        # carry it too, so both modes share one report shape).
        "finding_count": _finding_count(state),
    }


def _paired_delta(before, after):
    """The after-minus-before paired deltas (AC7).

    Reports the deltas the tier can measure: attributed auditor cost, total peak context
    (secondary), round count, and finding count. Latency is NOT here — the wall-clock
    axis reads `unestablished`, so a paired latency delta would present a number the
    tier never measured.
    """
    def _sum(report, key):
        return sum(r[key] for r in report["runs"])

    def _rounds(report):
        return sum(len(r["dispatch_rounds"]) for r in report["runs"])

    def _findings_delta():
        # Finding count is a state-file axis: the total ledger entries across rounds.
        # A side whose state could not be read carries the UNESTABLISHED sentinel, and
        # subtracting against it would publish a measured-looking delta about a side
        # that was never read — so the delta itself reads `unestablished`.
        b, a = before.get("finding_count"), after.get("finding_count")
        if b == UNESTABLISHED or a == UNESTABLISHED or b is None or a is None:
            return UNESTABLISHED
        return a - b

    return {
        "attributed_auditor_cost": _sum(after, "attributed_auditor_cost")
        - _sum(before, "attributed_auditor_cost"),
        # Named for what it is: a CORPUS-WIDE sum of per-run peaks, not a per-run figure.
        # Under the old `per_run_context` name a 3-run before corpus against a 1-run
        # after corpus reported a large "context reduction" that was pure population
        # difference. The run counts are on each side's summary for the reader to divide.
        "total_peak_context": _sum(after, "peak_context") - _sum(before, "peak_context"),
        "round_count": _rounds(after) - _rounds(before),
        "finding_count": _findings_delta(),
    }


def _finding_count(state):
    """Total ledger entries across rounds, or UNESTABLISHED when there is no state.

    NEVER `0` on a degraded/absent state: `0` is a real value meaning "the audit
    recorded no findings", and publishing it about a state file that was never read is
    the unknown-collapsed-onto-zero bug the whole axis guards against.
    """
    if state is None:
        return UNESTABLISHED
    return sum(len(rnd["findings"]) for rnd in state.values())


def build_paired_report(before_dir, after_dir, before_state=None, after_state=None,
                        large_block_chars=LARGE_BLOCK_MIN_CHARS):
    """A before/after paired report with the AC7 deltas."""
    before = build_report(before_dir, before_state, large_block_chars)
    after = build_report(after_dir, after_state, large_block_chars)
    return {
        "before": before,
        "after": after,
        "delta": _paired_delta(before, after),
    }


def _render_run_line(r):
    parts = [
        "- {source}: turns={turn_count} peak={peak_context} final={final_context} "
        "output={total_output_tokens} compactions={compact_boundary_count} "
        "repeated_reads={repeated_read_count} reemissions={reemission_count} "
        "auditor_cost={attributed_auditor_cost} reopens={record_reopen_count}".format(**r)
    ]
    if r["round_auditor_cost"]:
        # AC6: each per-round entry carries the round's RECORDED kind beside its cost,
        # so one run's report is readable without the aggregate per-kind medians.
        kinds = r.get("round_kinds") or {}
        by_round = " ".join(
            "r{}={}({})".format(n, c, kinds.get(n, UNESTABLISHED))
            for n, c in sorted(r["round_auditor_cost"].items()))
        parts.append("\n  - per-round auditor cost: {}".format(by_round))
    return "".join(parts)


def render_text(runs, summary, skipped, state_established=None):
    lines = []
    lines.append("# create-issue runtime main-thread context eval")
    lines.append("")
    lines.append("## Per-run metrics")
    if not runs:
        lines.append("(no create-issue runs found in the supplied corpus)")
    for r in runs:
        lines.append(_render_run_line(r))
    lines.append("")
    lines.append("## Aggregate summary")
    # aggregate() builds this dict in the canonical field order, so iterating it
    # renders every field once with no per-field literal to keep in sync.
    for key, value in summary.items():
        lines.append("- {}: {}".format(key, value))
    if state_established is not None:
        # Whether the state file was established at all decides how every
        # `unestablished` figure above should be read, so it is part of the report.
        lines.append("- state_established: {}".format(state_established))
    lines.append("")
    total_skipped = sum(skipped.values())
    lines.append("## Skipped records: {}".format(total_skipped))
    for reason in sorted(skipped):
        if skipped[reason]:
            lines.append("- {}: {}".format(reason, skipped[reason]))
    return "\n".join(lines)


def render_paired_text(report):
    lines = ["# create-issue context eval — before/after paired deltas", ""]
    for label in ("before", "after"):
        side = report[label]
        lines.append("## {}".format(label.capitalize()))
        lines.append(render_text(side["runs"], side["summary"], side["skipped"],
                                 side.get("state_established")))
        lines.append("")
    lines.append("## Paired deltas (after - before)")
    for key, value in report["delta"].items():
        lines.append("- {}: {}".format(key, value))
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Measure the runtime main-thread context cost of /devflow:create-issue.",
    )
    parser.add_argument(
        "transcript_dir", nargs="?",
        help="Path to a Claude Code transcript directory (single-corpus mode).",
    )
    parser.add_argument("--state-file", default=None,
                        help="Audit state file for the round->kind labelling (single-corpus mode).")
    parser.add_argument("--before", default=None, help="Before transcript dir (paired mode).")
    parser.add_argument("--after", default=None, help="After transcript dir (paired mode).")
    parser.add_argument("--before-state", default=None, help="Before audit state file (paired mode).")
    parser.add_argument("--after-state", default=None, help="After audit state file (paired mode).")
    parser.add_argument(
        "--format", choices=("text", "json"), default="text",
        help="Output format (default: text).",
    )
    parser.add_argument(
        "--large-block-chars", type=int, default=LARGE_BLOCK_MIN_CHARS,
        help="Minimum size (chars) of a block counted for the re-emission metric.",
    )
    args = parser.parse_args(argv)

    paired = args.before is not None or args.after is not None
    if paired:
        if args.before is None or args.after is None:
            sys.stderr.write("error: paired mode requires both --before and --after\n")
            return 2
        # A flag the parser accepts and the selected mode then discards is silently
        # dropped input: the operator reads the resulting `unestablished` as an honest
        # disclosure when the real cause is their own mismatched flag. Refuse it.
        if args.state_file is not None:
            sys.stderr.write("error: --state-file is a single-corpus flag; paired mode "
                             "takes --before-state/--after-state\n")
            return 2
        if args.transcript_dir is not None:
            sys.stderr.write("error: a positional transcript directory is a "
                             "single-corpus input; paired mode takes --before/--after\n")
            return 2
        for label, path in (("--before", args.before), ("--after", args.after)):
            if not os.path.isdir(path):
                sys.stderr.write("error: {} directory not found: {}\n".format(label, path))
                return 2
        # Hold the state operands to the same standard as their sibling directory
        # operands: an explicitly-supplied path that does not exist is an operator
        # error, not an occasion to report `unestablished` about it.
        for label, path in (("--before-state", args.before_state),
                            ("--after-state", args.after_state)):
            if path is not None and not os.path.isfile(path):
                sys.stderr.write("error: {} file not found: {}\n".format(label, path))
                return 2
        report = build_paired_report(
            args.before, args.after, args.before_state, args.after_state,
            args.large_block_chars)
        if args.format == "json":
            sys.stdout.write(json.dumps(report, indent=2, sort_keys=True) + "\n")
        else:
            sys.stdout.write(render_paired_text(report) + "\n")
        return 0

    corpus = args.transcript_dir
    if corpus is None:
        # Returned, not `parser.error`'d: every sibling operand failure in this function
        # returns 2, and a SystemExit here would be the one arm a caller driving main()
        # in-process has to catch differently.
        sys.stderr.write(
            "error: a transcript directory (or --before/--after) is required\n")
        return 2
    for label, path in (("--before-state", args.before_state),
                        ("--after-state", args.after_state)):
        if path is not None:
            sys.stderr.write("error: {} is a paired-mode flag; single-corpus mode "
                             "takes --state-file\n".format(label))
            return 2
    if args.state_file is not None and not os.path.isfile(args.state_file):
        sys.stderr.write(
            "error: --state-file file not found: {}\n".format(args.state_file))
        return 2
    if not os.path.isdir(corpus):
        # No corpus present: exit non-zero naming the missing path — never a
        # silently-empty baseline.
        sys.stderr.write(
            "error: transcript directory not found: {}\n".format(corpus)
        )
        return 2

    report = build_report(corpus, args.state_file, args.large_block_chars)
    runs, summary, skipped = report["runs"], report["summary"], report["skipped"]

    if args.format == "json":
        # Sort keys for byte-stable, deterministic output.
        sys.stdout.write(
            json.dumps(
                {"runs": runs, "summary": summary, "skipped": skipped,
                 "state_established": report["state_established"],
                 "finding_count": report["finding_count"]},
                indent=2, sort_keys=True,
            )
            + "\n"
        )
    else:
        sys.stdout.write(
            render_text(runs, summary, skipped, report["state_established"]) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
