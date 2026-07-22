#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""State owner for the `/devflow:create-issue` fresh-context audit lifecycle.

The audit lifecycle — rounds, verdicts, revisions, bounded retries, user-chosen
rounds, overrides and presentation eligibility — used to live as procedural prose
in `skills/create-issue/SKILL.md`, re-derived by an LLM on every turn. Deterministic
transition logic does not belong on an instruction-following surface: this module
owns it, and the skill records events through it and obeys its answers (issue #546).

WHAT THIS OWNS vs. WHAT THE SKILL KEEPS. This module owns transition legality,
round numbering, budget/retry accounting, arm routing, digest computation and
comparison, sentinel generation and comparison, T1/T2 evaluation, override records,
presentation eligibility and the audit-summary field set. The skill keeps the audit
*reasoning* — the audit-prompt template, dimension checklist, information diet,
out-of-bounds lists, extension forwarding — plus the subagent dispatch, the
`VERDICT:` token parse (semantic extraction is LLM work; this module then validates
the token fail-closed against its closed set), the draft-file writes, and every user
interaction. This module never posts an issue.

TWO-CLASS CLI CONTRACT (the skill branches on exactly this):
  * Query subcommands ALWAYS exit 0 once their arguments parse (an argparse usage
    error — a missing required flag or an unknown one — exits 2 before the query logic
    runs) and answer on stdout with a decided single-line
    token — fail-closed answers included — with exactly one exception: `query-findings`
    prints one decided line per ledger entry and is the tool's one multi-line query (a
    run with no ledger prints the single line `findings=none`). A crashed read is never
    presented as a value. Queries are strictly READ-ONLY: the tool-unavailability fallback depends
    on a mutation-persistence failure still leaving the queries answering, so no
    query may write. This is why the eligibility token is *derived* on demand rather
    than persisted at issue time.
  * Mutation subcommands exit non-zero with a specific named stderr breadcrumb, for
    an illegal transition and for an unpersistable state alike.
  * `emit-body` is neither: it is a gated emitter. It exits 0 with the audited body
    bytes when eligibility grounds them, and non-zero with EMPTY stdout otherwise —
    so on the file-identity ground a caller that ignores the exit code cannot post an
    unaudited body. A file-arm override is digest-bound too (`record-override` requires
    the draft there), so that ground byte-binds what it emits exactly as file-identity
    does. On the event-ordering ground, and on an override recorded over an embed/inline
    epoch, the gate refuses bytes a recorded revision has staled but cannot byte-bind
    what it emits (those grounds record no trustworthy digest, because no trustworthy
    canonical file exists to record one from — the disclosed weaker identity); the
    post-hoc creation attestation is the detection surface for that residual.

WINDOWS-SAFETY (#275/#295): this module never executes a `.sh` helper ([WinError 193])
and reads no config file. Its only subprocess is native `git`, and its state file is
anchored to the git repo root (falling back to the cwd) — deliberately NOT to the main
worktree root the draft file uses via `resolve-main-root.sh`. That divergence is
load-bearing and must not be unified: main-root anchoring would share one record across
concurrent worktree runs, letting a foreign delete-first wipe this run's state.
"""

import argparse
import functools
import hashlib
import json
import os
import re
import secrets
import subprocess
import sys
from pathlib import Path

if sys.version_info < (3, 11):
    sys.stderr.write(
        'issue-audit-state.py: python3 >= 3.11 required (found '
        f'{sys.version_info.major}.{sys.version_info.minor})\n'
    )
    raise SystemExit(1)

# Bumped 1 → 2 for issue #562: the additive `draft_binding` / `write_failures` /
# revision-`stdin_digest` fields. The bump is deliberate even though those fields are
# additive-optional — a pre-change v1 state file answers through the existing
# schema-version-mismatch fail-closed matrix row (#546's matrix; no new versioning
# discipline is invented), forcing a re-init of any in-flight v1 run. Blast radius is
# small: these state files are ephemeral per-run scratch under .devflow/tmp/.
SCHEMA_VERSION = 2

# ── Canonical token sets ────────────────────────────────────────────────────────
# The transition table below may reference no token outside these sets; the
# import-time assert enforces that. Adding a lifecycle token means adding it here,
# which is what keeps the table and the vocabulary from drifting apart silently.

_EVENTS = (
    'init', 'dispatch', 'return', 'revision', 'override', 'degraded',
    'creation-epoch', 'creation-attestation', 'draft-binding', 'write-failure',
)
# These are bare-string tuples, not Enums — a deliberate, recorded trade-off (raised on
# PR #552 and deferred). The cost is real but narrow: because arms and verdicts are both
# plain `str`, a TRANSPOSED `classify_return(arm, verdict)` is not a type error. It does not
# fail open, though — a transposed call takes the verdict-not-in-_VERDICTS path and answers
# `no-parseable-verdict`, the same fail-CLOSED retry token an unreadable return earns, and
# every live caller passes these positionally from _validate'd state that already proved each
# field is in its canonical set. The benefit kept: these tuples ARE the vocabulary the
# import-time transition-table assert checks every row against, and membership tests
# (`x not in _ARMS`) read directly against the JSON state file's bare strings with no
# serialization layer. Revisit if either changes: (a) a caller starts passing an arm/verdict
# that did NOT come through _validate (e.g. a new CLI flag read straight into classify_return),
# or (b) a transposition ever survives to a wrong ANSWER rather than the closed retry token.
_ARMS = ('file', 'embed', 'inline')
_VERDICTS = ('FILE', 'REVISE', 'DRAFT-UNREADABLE')
_ROUND_OUTCOMES = ('FILE', 'REVISE', 'no-verdict')
# The post-adjudication verdict a completed round may carry (issue #548). Distinct from the
# raw auditor `--verdict` (`_VERDICTS`), which stays recorded as provenance: adjudication is
# the orchestrator's reconciled judgment over the round's findings, and a lifecycle input is
# accepted only when this verdict and the unresolved-must-revise count agree. `DRAFT-UNREADABLE`
# is not an adjudicated verdict — it names an unread draft, which carries no findings.
_ADJUDICATED_VERDICTS = ('FILE', 'REVISE')
# The literal a round records for its unresolved-must-revise count when the count could not be
# established (unknown is not zero — an unestablished count is never collapsed onto 0).
_UNESTABLISHED = 'unestablished'
# The closed set of return classifications. `classify_return` is validated against it, so a
# renamed classification fails loudly instead of routing a live return to a rule that no
# longer matches.
_CLASSIFICATIONS = ('accept-file', 'accept-revise', 'retry-embed', 'no-parseable-verdict')

# Every decided outcome a transition row may name. Declared independently of TRANSITIONS on
# purpose — the import-time assert compares the table against THIS, so it can actually fail.
_RESULTS = _CLASSIFICATIONS + (
    'nonce-minted', 'nonce-echoed', 'reinit-forced', 'illegal-reinit',
    'digest-recorded', 'sentinels-generated', 'illegal-dispatch',
    'illegal-return', 'ordinal-incremented', 'illegal-revision',
    'override-recorded', 'degraded-recorded', 'epoch-recorded', 'illegal-epoch',
    'match', 'mismatch', 'attestation-unavailable', 'illegal-attestation',
    'draft-binding-recorded', 'illegal-draft-binding', 'write-failure-recorded',
)

# The three embed-arm entry markers, preserved verbatim from the prose this module
# replaces. `lib/test/run.sh` pins the rendered text byte-for-byte: the audit summary
# line carries whichever of these the run entered the embed arm under.
# `digest-unrecorded`'s rendered text predates the cutover, while its trigger is now
# "the tool's own hash of the draft file failed" (see route_arm) — the wording is
# kept because marker strings are preserved verbatim by the extraction contract, and
# a failed hash does leave the digest unrecorded, so the text stays literally true.
_EMBED_MARKER_TOKENS = ('write-failed', 'file-unreadable', 'digest-unrecorded')
_EMBED_MARKER_TEXT = {
    'write-failed': 'draft embedded (file write failed)',
    'file-unreadable': 'draft embedded (file unreadable)',
    'digest-unrecorded': 'draft embedded (digest unrecorded)',
}

_ATTESTATIONS = ('match', 'mismatch', 'attestation-unavailable')
_OVERRIDE_KINDS = ('user-decline', 'cap-reached')
_OVERRIDE_SURFACES = (
    't1t2-boundary', 'step4-offer', 'step4-approval-after-exhausted-offer',
)
_DEGRADED_REASONS = ('no-subagent-tool', 'dispatch-error', 'no-parseable-verdict-exhausted')
_NEXT_ACTIONS = (
    'dispatch-embed-retry', 'dispatch-retry-same-arm', 'dispatch-inline-degraded',
    'proceed', 'revise-and-reaudit', 'revise-then-evaluate-offer', 'round-closed-no-verdict',
    'round-open-awaiting-return',
)
_ELIGIBILITY_REASONS = (
    'unaudited-revision', 'stale-override', 'no-verdict-round', 'state-unestablished',
    'foreign-nonce', 'no-revision-recorded', 'draft-undigestible',
    'no-digest-supplied',
)
_GROUNDS = ('file-identity', 'event-ordering', 'override')

# The tiered canonical-draft-root binding (issue #562). A run binds exactly one
# successfully-writable draft root; `tier` names which ladder rung landed. The
# non-bound root is recorded verbatim when a resolver-answered tier-1 main root and a
# divergent tier-2 worktree root both exist, so the divergent-roots out-of-bounds
# enumerations can name the non-bound same-slug draft path. A closed token set —
# record-time validation (`record-draft-binding`) and `_validate` reject any value
# outside it. Unlike the transition-token sets, no import-time assert covers this set:
# it is not a transition-row column, so it is guarded at record time and in `_validate`
# only (the same footing as the embed markers and override kinds).
_DRAFT_TIERS = ('main-root', 'worktree-root')

# ── Per-finding ledger vocabulary (issue #603) ────────────────────────────────────
# A ledger entry's status. Closed set, guarded at record time and in `_validate` (the
# same footing as the embed markers and override kinds). `superseded` is TERMINAL: a
# FILE adjudication sweeps every prior unresolved entry into it, and the three
# post-close mutations refuse to touch it — so an auditor-accepted clean round
# converges the run regardless of earlier bookkeeping.
_LEDGER_STATUSES = ('unresolved', 'resolved', 'invalidated', 'superseded')

# The ingestion provenance stamped on an entry ingested ALREADY resolved (a `resolved: `
# line on the adjudication ledger). That shape is legal because record-adjudication
# accepts an unresolved count BELOW the must-revise total, so such an entry has no
# revision behind it — which is why `_PRE_REVISION` exists as its provenance ordinal.
_LEDGER_INGESTED_RESOLVED = 'resolved-at-adjudication'

# The provenance token standing in for ordinal zero: a post-close status change made
# before any revision was recorded. The staleness comparison counts it as 0.
_PRE_REVISION = 'pre-revision'

# The two statuses a `--ledger-stdin` line may ingest as. The line prefix IS the status
# followed by ": ", so the prefix is derived rather than stored beside it — one spelling,
# no way for the two halves to disagree.
_LEDGER_PREFIXES = ('unresolved', 'resolved')

# ── Per-dimension coverage vocabulary (issue #708) ─────────────────────────────────
# The closed set of coverage outcomes an auditor records per required audit dimension,
# guarded at record time and re-enforced at the read boundary in `_validate_coverage`.
# Complete by construction:
#   exercised    — the dimension was engaged, backed by a checkable anchor.
#   valid-N/A    — the draft plainly does not touch the dimension (a cheap one-line reason).
#   unestablished— the outcome could not be established (a degraded arm, a floor failure);
#                  unknown is never collapsed onto exercised or onto a clean backing.
#   skipped      — the auditor did not genuinely engage the dimension (the coverage gap).
_COVERAGE_OUTCOMES = ('exercised', 'valid-N/A', 'unestablished', 'skipped')
# The two outcomes that back coverage. A run is coverage-backed only when EVERY required
# dimension resolved to one of these with adjudication-surviving evidence — totality is
# enforced at record time against `--expected-keys`, the orchestrator's authoritative
# enumeration, by synthesizing `unestablished` for every enumerated key with no line.
_COVERAGE_BACKING_OUTCOMES = ('exercised', 'valid-N/A')
# The outcomes that require a non-empty anchor/reason passing the text-only floor. An
# `exercised` outcome whose anchor fails the floor is DOWNGRADED to `unestablished` at
# record time (unknown is not zero), never rejected. The two roles — what BACKS coverage
# and what CARRIES an anchor — are the same set by construction, so the coupling is
# spelled as an alias rather than a second literal that a later edit could silently
# desync (a divergence would be invisible: nothing compares the two).
_COVERAGE_ANCHORED = _COVERAGE_BACKING_OUTCOMES
# One structurally-enforced bound (issue #708): a hard per-anchor character cap over the
# quoted line plus one concern clause, so no single anchor can balloon. The state owner
# READ BOUNDARY rejects an over-cap anchor; at record time an over-cap anchor fails the
# floor and DOWNGRADES to `unestablished` like any other floor failure, never a rejection.
_COVERAGE_ANCHOR_MAX = 600
# The render state a coverage round records. `full` — the auditor rendered every dimension
# on the orchestrator's authoritative enumeration; `degraded` — a render divergence narrowed
# the auditor's dimension set (un-rendered dimensions record `unestablished`), which
# discloses but does NOT fire the coverage offer. (`none` is never RECORDED — it is the
# derivation's no-coverage-round token; see `evaluate_coverage`, whose choices this tuple
# does not gate.)
_COVERAGE_RENDERS = ('full', 'degraded')
# The run-level coverage-backing tokens the derivation reports and the summary renders.
_COVERAGE_BACKINGS = ('backed', 'not-backed', 'unestablished')

# Every `key=` token this tool's queries and mutations PRINT. Ledger summaries and
# invalidation reasons are refused when they contain a word of the form `<token>=` drawn
# from this set: ledger text is identity data, never instruction and NEVER protocol, so
# auditor-derived text can never forge a field of the tool's own printed surface. One
# closed module-level list shared by ledger ingestion and the invalidation-reason
# refusal, so the two can never drift; a suite row asserts it covers every token the
# printers emit through a direct literal, a one-level helper return, or a line assembled
# into a local — the three emission shapes this module uses (a deeper helper chain would
# need a new arm in that row). Widening it beyond `query-findings`' own fields is deliberate — the
# never-protocol property must hold for the whole printed surface, not one line of it.
_PROTOCOL_TOKENS = (
    'action', 'adjudicated', 'adjudicated_verdict', 'advisory', 'anchor', 'arm',
    'attestation',
    'basis', 'body_digest', 'bound', 'bound_path', 'bound_root', 'bound_tier', 'cap',
    'cap_reached', 'classification', 'consumer_dimensions_appended', 'converged',
    'convergence_basis', 'count', 'coverage', 'coverage_backing', 'coverage_render',
    'degraded', 'digest', 'effective_unresolved',
    'eligible', 'epoch_round', 'findings', 'findings_count', 'frozen', 'ground', 'id',
    'invalid', 'invalidated', 'iterate', 'key', 'kind', 'latest_revision_landed',
    'marker', 'markers',
    'must_revise', 'non_bound_root', 'nonce', 'ordinal', 'outcome', 'reason',
    'reinit_forced', 'remaining', 'reopened', 'revision_ordinal', 'revisions_applied',
    'round', 'rounds_run', 'sentinel_close', 'sentinel_open', 'state', 'status',
    'stdin_digest', 'summary', 'superseded', 't1', 't2', 'tier', 'token',
    'unledgered_revise', 'unresolved',
    'unresolved_must_revise', 'user_declined', 'user_rounds_used', 'verdict',
)


# The settling-provenance keys `_clear_settling` drops, and the set each status may
# legally carry at the read boundary. Stated once so `_validate_ledger`'s residual-key
# arm and that helper cannot drift apart: `_clear_settling` clears every member, so any
# settling key a status is not listed with here is a shape the writer never emits.
# `supersession_round` is a member: it is written by a status change (the FILE sweep in
# `cmd_record_adjudication`) exactly like the others, so excluding it would have made
# `_clear_settling`'s status-agnostic sufficiency false in precisely the way its own
# docstring claims it is not — a future channel able to act on a `superseded` entry would
# carry the key onto the new status and the residual arm, which iterates this tuple,
# would not catch it (PR #612 review).
_SETTLING_KEYS = ('resolution_ordinal', 'ingest_provenance',
                  'invalidation_provenance', 'invalidation_reason',
                  'supersession_round')
_LEGAL_SETTLING_KEYS = {
    'unresolved': frozenset(),
    'superseded': frozenset(('supersession_round',)),
    'resolved': frozenset(('resolution_ordinal', 'ingest_provenance')),
    'invalidated': frozenset(('invalidation_provenance', 'invalidation_reason')),
}

# Fail FAST on the `_LEDGER_STATUSES` ↔ `_LEGAL_SETTLING_KEYS` coupling rather than fail
# LATE inside `_validate_ledger`. That arm indexes `_LEGAL_SETTLING_KEYS[status]` on a
# status already checked against `_LEDGER_STATUSES`, so a future status added to one
# constant and not the other would raise a raw `KeyError` from inside the read boundary —
# escaping the StateError→unestablished contract as an unhandled traceback on a state file
# the tool itself wrote. An import-time check turns that into a named startup failure at
# the desk, on the commit that introduces the drift. Deliberately not a bare `assert`
# (stripped under `python3 -O`) and deliberately not a `.get(status, frozenset())` default
# at the call site, which would silently accept the new status as carrying NO legal
# settling key — quietly wrong rather than loudly absent.
if set(_LEGAL_SETTLING_KEYS) != set(_LEDGER_STATUSES):
    raise RuntimeError(
        'issue-audit-state: _LEGAL_SETTLING_KEYS and _LEDGER_STATUSES have drifted '
        f'(symmetric difference {sorted(set(_LEGAL_SETTLING_KEYS) ^ set(_LEDGER_STATUSES))!r}); '
        'a ledger status must declare the settling-provenance keys it may legally carry')


def _forged_protocol_token(text):
    """The first protocol token `text` forges as a `<token>=` word, else None.

    Shared by ledger-summary ingestion and the invalidation-reason guard so one closed
    vocabulary governs both. The decided recovery on a hit is to reword without the
    `<field>=` form and re-issue the call.

    The match is deliberately CASE-SENSITIVE: the capture is case-insensitive by character
    class, but `_PROTOCOL_TOKENS` holds the printers' exact lowercase spellings, so only a
    byte-identical token forges a field. `Status=x` prints as literal text and forges
    nothing, so refusing it would cost a legitimate summary for no safety gain.
    """
    for tok in re.findall(r'([A-Za-z_][A-Za-z0-9_]*)=', text or ''):
        if tok in _PROTOCOL_TOKENS:
            return tok
    return None


def _record_splitting_char(text):
    """The first record-splitting byte (`\\n` or `\\r`) in `text`, else None.

    The sibling of `_forged_protocol_token`: that guard stops auditor-derived text from
    forging a FIELD of the printed surface, this one stops it from forging a LINE. Both
    ledger summaries and invalidation reasons land in `query-findings`' `summary=<text>`
    trailing field (and in state a later round reconciles against), so an embedded CR or
    LF could visually clobber or split the reconciliation surface — the same reason
    `_is_bound_path` refuses both bytes in a bound path. The two INGESTION callers
    (`_ingest_ledger` and `cmd_record_invalidate`) check the STRIPPED text, so a trailing
    CRLF from a Windows-shell heredoc is normalized away rather than refused and only an
    INTERIOR splitter is a hit there. The two `_validate_ledger` READ-BOUNDARY callers
    pass stored text verbatim, where any splitter — a trailing one included — is corrupt
    state by construction, since the ingestion guards already stripped it before it was
    ever persisted. The decided recovery mirrors the vocabulary refusal: reword the text
    onto one line and re-issue the call.
    """
    for ch in ('\n', '\r'):
        if ch in (text or ''):
            return ch
    return None

# Ported budgets and bounds. These are the prose's numbers, preserved verbatim.
_MAX_AUTOMATIC_REAUDITS = 1
_USER_ROUND_CAP = 3

# ── The transition table (the vocabulary registry and lockstep record) ─────────────────
# One row per transition. The verdict-on-arm rows are consulted at runtime by
# _legality(); the other events' rows are the audited record of each cmd_* guard,
# kept honest by the tests' count-and-content lockstep rather than by a runtime read.
#
# This table is deliberately NOT a "single source of truth", and nothing here claims it is
# — read the split above literally. Only the verdict-on-arm rows decide anything at runtime;
# every other row is DOCUMENTATION of a guard that is hand-coded imperatively in its cmd_*
# function. Known, accepted limitation (raised on PR #552 and kept): a cmd_* guard edited
# without its row (or vice versa) can silently disagree, and the lockstep does not catch it
# — the lockstep checks table-vs-registry consistency, not table-vs-cmd_*-behavior.
# It is accepted rather than fixed because the fail-direction is bounded: the guards ARE the
# enforcement, so a drifted row cannot admit a wrong value, corrupt state, or skip a guard —
# it can only mislead a reader. That is a docs-accuracy risk, not a fail-open one.
# Revisit if any of these change: (a) a non-verdict-on-arm row acquires a runtime reader (at
# which point drift stops being cosmetic and this table must become authoritative for it),
# (b) a drift between a row and its guard actually reaches main, or (c) the cmd_* guards are
# reworked such that consulting legal/reason from the rows stops being a rewrite of each one.
# Every row names the tokens it references; the import-time
# assert below rejects any token outside its canonical set, so a renamed event, arm,
# verdict, reason or result token fails the import loudly instead of silently
# routing a lifecycle event to a rule that no longer matches. (Embed markers and
# override kinds are not transition-row columns, so the transition assert cannot name
# them; they are guarded independently — markers by the `_EMBED_MARKER_TEXT` ↔
# `_EMBED_MARKER_TOKENS` equality assert below, override kinds by argparse `choices=`
# and `_validate`.) The tests derive their
# expected row count from this table (`len(TRANSITIONS)`), so a row added here without
# a matching test row turns the suite RED.
#
# Columns: event, condition, arm, verdict, legal, result, reason
#   `arm`/`verdict` are None where the event does not discriminate on them.
#   `result` is the decided outcome token; `reason` is the breadcrumb/answer token
#   an illegal or refused transition carries.

_T = dict


def _row(event, condition, *, arm=None, verdict=None, legal=True, result=None, reason=None):
    return _T(event=event, condition=condition, arm=arm, verdict=verdict,
              legal=legal, result=result, reason=reason)


TRANSITIONS = (
    # init — the cold-start wipe is the ported delete-leftover-first rule and raises
    # no alarm; a same-run re-init is illegal absent an explicit force flag, so a
    # fresh automatic budget is never obtainable silently within a run.
    _row('init', 'cold-start-no-nonce', result='nonce-minted'),
    _row('init', 'same-run-nonce-no-rounds', result='nonce-echoed'),
    _row('init', 'same-run-nonce-over-rounds-unforced', legal=False,
         result='illegal-reinit', reason='reinit-requires-force'),
    _row('init', 'same-run-nonce-over-rounds-forced', result='reinit-forced'),
    _row('init', 'foreign-nonce', legal=False, result='illegal-reinit',
         reason='foreign-nonce'),

    # dispatch — one row per arm. The arm itself is decided by `query-arm` from
    # recorded facts alone; these rows say what a dispatch on each arm records.
    _row('dispatch', 'file-arm-write-landed', arm='file', result='digest-recorded'),
    _row('dispatch', 'embed-arm-entry', arm='embed', result='sentinels-generated'),
    _row('dispatch', 'inline-arm-entry', arm='inline', result='digest-recorded'),
    _row('dispatch', 'no-open-round', legal=False, result='illegal-dispatch',
         reason='round-not-open'),

    # return — the arm x verdict cross product, plus the carriage and verdict-line
    # rows. Retry precedence is fixed and lives in `_classify_return`: an absent
    # verdict line is classified by its absence before any arm/verdict rule applies.
    _row('return', 'verdict-on-arm', arm='file', verdict='FILE', result='accept-file'),
    _row('return', 'verdict-on-arm', arm='file', verdict='REVISE', result='accept-revise'),
    _row('return', 'verdict-on-arm', arm='file', verdict='DRAFT-UNREADABLE',
         result='retry-embed'),
    _row('return', 'verdict-on-arm', arm='embed', verdict='FILE', result='accept-file'),
    _row('return', 'verdict-on-arm', arm='embed', verdict='REVISE', result='accept-revise'),
    # DRAFT-UNREADABLE is legal only against a file-arm dispatch: on the embed arm the
    # auditor was handed the bytes inline, so it cannot truthfully report the draft
    # unreadable. Rejected as illegal and classified as a no-parseable-verdict
    # completion, never a second dispatch.
    _row('return', 'verdict-on-arm', arm='embed', verdict='DRAFT-UNREADABLE',
         legal=False, result='no-parseable-verdict', reason='unreadable-illegal-on-arm'),
    _row('return', 'verdict-on-arm', arm='inline', verdict='FILE', result='accept-file'),
    _row('return', 'verdict-on-arm', arm='inline', verdict='REVISE', result='accept-revise'),
    _row('return', 'verdict-on-arm', arm='inline', verdict='DRAFT-UNREADABLE',
         legal=False, result='no-parseable-verdict', reason='unreadable-illegal-on-arm'),
    _row('return', 'no-verdict-line', result='no-parseable-verdict'),
    # Absent carriage evidence is treated exactly like mismatched evidence: a FILE or
    # REVISE the auditor cannot prove it read is not a verdict, it is an unproven
    # claim, so it fails closed into the no-parseable-verdict retry accounting.
    _row('return', 'carriage-absent-or-mismatched', result='no-parseable-verdict'),
    _row('return', 'no-open-round', legal=False, result='illegal-return',
         reason='round-not-open'),
    _row('return', 'round-already-returned', legal=False, result='illegal-return',
         reason='duplicate-return'),

    # revision
    _row('revision', 'after-completed-round', result='ordinal-incremented'),
    _row('revision', 'no-rounds-recorded', legal=False, result='illegal-revision',
         reason='no-round-to-revise'),

    # override — the two kinds. Each is valid only while the revision ordinal (and,
    # on a file-arm epoch, the draft digest) recorded on it stays current.
    _row('override', 'user-decline-recorded', result='override-recorded'),
    _row('override', 'cap-reached-recorded', result='override-recorded'),

    # degraded
    _row('degraded', 'inline-arm-entered', arm='inline', result='degraded-recorded'),

    # creation
    _row('creation-epoch', 'bound-to-round', result='epoch-recorded'),
    _row('creation-epoch', 'no-round-recorded', legal=False, result='illegal-epoch',
         reason='no-round-to-bind'),
    _row('creation-attestation', 'body-matches', result='match'),
    _row('creation-attestation', 'body-mismatches', result='mismatch'),
    _row('creation-attestation', 'fetch-failed', result='attestation-unavailable'),
    _row('creation-attestation', 'no-epoch-recorded', legal=False,
         result='illegal-attestation', reason='no-epoch-to-attest'),
    # The attestation is tamper-evidence: once recorded it is forward-only. A second
    # attestation, and an epoch re-bind that would silently reset a recorded one,
    # are both illegal — a recorded mismatch must never be overwritable.
    _row('creation-attestation', 'already-recorded', legal=False,
         result='illegal-attestation', reason='attestation-already-recorded'),
    _row('creation-epoch', 'rebind-after-attestation', legal=False,
         result='illegal-epoch', reason='attestation-already-recorded'),

    # draft-binding (issue #562) — the tiered canonical-draft-root binding, recorded
    # exactly once per run by the first landed write. A second record is illegal (the
    # forced-reinit path stays the only route to a fresh binding); a non-absolute bound
    # path, a missing or unknown tier token, and a present-but-non-absolute non-bound
    # root each fail closed.
    _row('draft-binding', 'first-landed-write', result='draft-binding-recorded'),
    _row('draft-binding', 'already-recorded', legal=False,
         result='illegal-draft-binding', reason='binding-already-recorded'),
    _row('draft-binding', 'bound-path-not-absolute', legal=False,
         result='illegal-draft-binding', reason='binding-path-not-absolute'),
    _row('draft-binding', 'tier-missing', legal=False,
         result='illegal-draft-binding', reason='binding-tier-missing'),
    _row('draft-binding', 'tier-unknown', legal=False,
         result='illegal-draft-binding', reason='binding-tier-unknown'),
    _row('draft-binding', 'nonbound-not-absolute', legal=False,
         result='illegal-draft-binding', reason='binding-nonbound-not-absolute'),

    # write-failure (issue #562) — a canonical-draft overwrite that failed to land at
    # the bound path is recorded, so `latest_revision_landed` reports the latest revision
    # as unlanded and the presentation renders from the in-context revision bytes rather
    # than the stale file. (The dispatch write-path cross-check landed in issue #569 as an
    # additive guard in cmd_record_dispatch — it is not a transition row, so none is declared
    # for it here. The STRICT half — `binding-required-on-file-arm` — remains deferred.)
    _row('write-failure', 'recorded', result='write-failure-recorded'),
)


def _require(cond, msg):
    """An import-time invariant that survives `python3 -O` (a bare `assert` does not)."""
    if not cond:
        raise AssertionError(msg)


def _assert_transition_tokens():
    """Fail the import loudly when a transition names a token outside its set.

    A transition referencing an unknown event type, arm, verdict, reason or result
    token is a rule that can never fire — the exact silent-drift this module exists to
    remove from prose. Import fails rather than routing a live lifecycle event to a
    stale rule. (Embed markers and override kinds are not transition-row columns, so
    this assert cannot name them; they are guarded independently — see the
    `_EMBED_MARKER_TEXT`/`_EMBED_MARKER_TOKENS` equality assert and `_validate`.)
    """
    for r in TRANSITIONS:
        where = f"{r['event']}/{r['condition']}"
        _require(r['event'] in _EVENTS,
                 f'issue-audit-state: transition {where} names an event not in _EVENTS')
        _require(r['arm'] is None or r['arm'] in _ARMS,
                 f'issue-audit-state: transition {where} names an arm not in _ARMS: {r["arm"]}')
        _require(r['verdict'] is None or r['verdict'] in _VERDICTS,
                 f'issue-audit-state: transition {where} names a verdict not in _VERDICTS: '
                 f'{r["verdict"]}')
        _require(r['reason'] is None or r['reason'] in _ALL_REASONS,
                 f'issue-audit-state: transition {where} names a reason token not in the '
                 f'canonical reason sets: {r["reason"]}')
        # `_RESULTS` is declared INDEPENDENTLY of the table (never derived from it): an
        # assert whose comparand is built from the very rows it checks is a tautology that
        # cannot fail, which is a false signal of coverage rather than a guard.
        _require(r['result'] is None or r['result'] in _RESULTS,
                 f'issue-audit-state: transition {where} names a result not in _RESULTS: '
                 f'{r["result"]}')
    # The arm x verdict cross product must be total — an unrouted combination would
    # fall through to whatever the caller improvised, which is the prose failure mode.
    covered = {(r['arm'], r['verdict']) for r in TRANSITIONS
               if r['condition'] == 'verdict-on-arm'}
    _require(covered == {(a, v) for a in _ARMS for v in _VERDICTS},
             'issue-audit-state: the arm x verdict cross product is not total: missing '
             f'{ {(a, v) for a in _ARMS for v in _VERDICTS} - covered }')


# Reason tokens a transition row may carry: the eligibility reasons plus the
# transition-legality breadcrumbs.
_TRANSITION_REASONS = (
    'reinit-requires-force', 'foreign-nonce', 'round-not-open', 'duplicate-return',
    'unreadable-illegal-on-arm', 'no-round-to-revise', 'no-round-to-bind',
    'no-epoch-to-attest', 'attestation-already-recorded',
    # issue #562 draft-binding / write-failure legality breadcrumbs
    'binding-already-recorded', 'binding-path-not-absolute', 'binding-tier-missing',
    'binding-tier-unknown', 'binding-nonbound-not-absolute',
)
_ALL_REASONS = set(_ELIGIBILITY_REASONS) | set(_TRANSITION_REASONS)

_require(set(_EMBED_MARKER_TEXT) == set(_EMBED_MARKER_TOKENS),
         'issue-audit-state: _EMBED_MARKER_TEXT keys must exactly match _EMBED_MARKER_TOKENS: '
         f'{set(_EMBED_MARKER_TEXT) ^ set(_EMBED_MARKER_TOKENS)}')
_require(set(_ROUND_OUTCOMES) <= set(_VERDICTS) | {'no-verdict'},
         'issue-audit-state: _ROUND_OUTCOMES names an outcome that is neither a verdict '
         'nor the decided verdict-less terminal')
_assert_transition_tokens()


# ── Process plumbing ───────────────────────────────────────────────────────────

def _fail(prefix, msg, code=1):
    """Emit a named stderr breadcrumb and exit non-zero (the mutation contract)."""
    sys.stderr.write(f'issue-audit-state.py {prefix}: {msg}\n')
    raise SystemExit(code)


def _run(cmd, *, data=None):
    return subprocess.run(
        cmd, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True,
    )


@functools.lru_cache(maxsize=1)
def _repo_root():
    """The git repo root, or None. Native `git` subprocess — never a `.sh` exec (#275).

    Memoized: the value cannot change within a process (the cwd never moves mid-run), but
    `state_path()` is called by both `load_state` and `save_state`, so every mutation would
    otherwise re-spawn `git rev-parse` for the same answer. An explicit `root=` argument
    bypasses this entirely (the shell tests instead anchor by `git init`-ing each sandbox).
    """
    try:
        r = _run(['git', 'rev-parse', '--show-toplevel'])
    except (subprocess.CalledProcessError, OSError) as exc:
        # The anchor SELECTION is changing (cwd fallback): breadcrumb the cause so a
        # split-state mystery (state one directory up, fresh file here) is diagnosable.
        print(f'issue-audit-state.py: git rev-parse failed ({exc}); anchoring state '
              f'to the current directory', file=sys.stderr)
        return None
    root = r.stdout.decode('utf-8', 'replace').strip()
    return Path(root) if root else None


def state_path(slug, root=None):
    """`.devflow/tmp/issue-audit-state-<slug>.json`, anchored to the repo/worktree root.

    Deliberately NOT the main-worktree root the draft file uses: sharing one record
    across concurrent worktree runs would let a foreign cold-start wipe this run's state.
    """
    # The slug keys a filesystem path (guard-class 2): an escaping shape would read,
    # write, and — worst — cold-start-DELETE outside .devflow/tmp. Fail closed.
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', slug or ''):
        raise StateError(f'slug {slug!r} is not a safe path segment '
                         f'([A-Za-z0-9][A-Za-z0-9._-]*)')
    base = root if root is not None else (_repo_root() or Path.cwd())
    return Path(base) / '.devflow' / 'tmp' / f'issue-audit-state-{slug}.json'


def _is_bound_path(p):
    """True iff `p` is a non-empty absolute path string with no embedded newline or CR.

    The binding is recorded and compared as an opaque string (Windows-safe, #275/#295):
    the tool never execs a `.sh` helper and never touches the filesystem to validate it.
    Absoluteness is the one structural check — a relative bound path would resolve
    differently at each write site and defeat the whole point of a bound root. An
    embedded newline OR carriage return is rejected: `recorded verbatim` means no
    normalization, not acceptance of record-splitting bytes that could forge a second
    field on readback. A space is NOT rejected — a real absolute path legitimately
    contains one (e.g. macOS `/Users/jo/My Repos/...`), so consumers of the space-
    delimited query lines must extract path fields by their `key=` anchor, never by a
    positional whitespace split.
    """
    return (isinstance(p, str) and bool(p) and os.path.isabs(p)
            and '\n' not in p and '\r' not in p)


# ── Digests ────────────────────────────────────────────────────────────────────

class _DigestError(Exception):
    """Raised by every digest helper below when a digest cannot be established.

    Defined ahead of its first raise: the raises are all inside function bodies, so a
    later definition would still bind at call time, but a reader auditing whether the
    fail-closed digest paths are real should not have to scroll past the raise to find
    the type.
    """


def hash_bytes(data):
    """Hash bytes with `git hash-object --stdin --no-filters`.

    ONE filter-free mode at every compare site. The path-mode form is never used
    anywhere in this module: it applies clean/CRLF content filters, so under
    `core.autocrlf=true` (or `* text=auto`) it returns a different object ID than
    stdin-mode does for the same bytes — and a dispatch digest that disagrees with an
    eligibility digest on the same file would refuse an untouched clean draft. The
    surviving audit-prompt template instructs the auditor to use `--no-filters` for
    exactly this reason, so all three digests agree byte-for-byte on every host.
    """
    try:
        r = _run(['git', 'hash-object', '--stdin', '--no-filters'], data=data)
    except subprocess.CalledProcessError as exc:
        err = exc.stderr.decode('utf-8', 'replace').strip()
        raise _DigestError(f'git hash-object failed: {err}') from exc
    except OSError as exc:
        raise _DigestError(f'could not execute git: {exc}') from exc
    oid = r.stdout.decode('ascii', 'replace').strip()
    if not oid:
        # `_DigestError` is otherwise raised only on a non-zero exit / OSError, but a
        # shimmed or broken `git` can exit 0 with empty stdout. An empty object ID must
        # never read as a successful digest: `''` compares equal to another `''` on the
        # override ground (`_valid_override`'s `want != current_digest`), which would
        # ground eligibility on unaudited bytes. Fail closed at the single source that
        # feeds every compare site rather than trusting each site to reject `''`.
        raise _DigestError('git hash-object returned an empty object id on exit 0')
    return oid


def hash_file(path):
    """Hash a file's bytes, read in binary. Raises _DigestError when unreadable."""
    try:
        data = Path(path).read_bytes()
    except OSError as exc:
        raise _DigestError(f'could not read draft file {path}: {exc}') from exc
    return hash_bytes(data)


def split_body(raw):
    """Return the draft body below the title heading, as bytes.

    The body-only digest is what a created issue's fetched body is attested against,
    so the split rule is decided rather than heuristic:
      * leading blank lines are skipped when looking for the title;
      * the title is a level-1 (`# `) heading — a bare `#` line is accepted as a
        title too — and only the first non-blank line is ever inspected; a `##`
        there means there is no title, and any later heading is ordinary body
        content;
      * when no title heading is found the whole content is the body;
      * blank separator lines between the title and the body are dropped;
      * line endings are preserved verbatim (bytes throughout, never decoded), so a
        CRLF draft attests against its own bytes rather than a normalized copy.
    """
    lines = raw.splitlines(keepends=True)
    if not lines:
        return raw
    first = 0
    while first < len(lines) and not lines[first].strip():
        first += 1
    if first >= len(lines):
        return raw
    candidate = lines[first].strip()
    if candidate != b'#' and not candidate.startswith(b'# '):
        return raw
    j = first + 1
    while j < len(lines) and not lines[j].strip():
        j += 1
    return b''.join(lines[j:])


# ── State I/O ──────────────────────────────────────────────────────────────────

class StateError(Exception):
    """State that cannot be trusted or safely persisted.

    Raised for three causes, deliberately sharing one fail-closed treatment (queries
    answer state-unestablished; mutations exit non-zero with the breadcrumb): a state
    file that cannot be trusted (unreadable, unparseable, foreign, or shape-invalid),
    a slug that is not a safe path segment (refused before any filesystem I/O), and a
    state document that could not be persisted.
    """


_REQUIRED_TOP = ('schema_version', 'slug', 'nonce', 'rounds', 'revisions', 'overrides')


def _validate_ledger(doc, rnd, num):
    """Re-enforce the per-finding-ledger invariants at the READ boundary (issue #603).

    Scope, stated exactly: every invariant the ingestion boundary enforces is re-enforced
    here, over the settling-provenance surface `_SETTLING_KEYS` names. The one key outside
    that surface is `reopen_provenance`, which is deliberately exempt from clearing (see
    `_clear_settling`) as the entry's genuine regression history — a residual copy IS
    readable, by `_convergence_basis`, and its absence-shape is NOT enforced here. Read
    "every invariant" as bounded by that stated exemption, not as coverage of every key an
    entry could physically carry.

    Absent is legal (a FILE round, a `REVISE … unestablished` round, and every
    pre-change round record no ledger) — present-but-wrong-shape is corrupt, the same
    pattern `draft_binding` and `write_failures` follow. Every violation raises
    StateError, which collapses the whole file to unestablished: the skill's fallback
    triage reads that as the ENVIRONMENTAL class, distinct from an argument-validation
    breadcrumb about a value the caller just supplied.
    """
    if 'findings' not in rnd:
        return
    ledger = rnd.get('findings')
    if not isinstance(ledger, list):
        raise StateError(f'round {num} findings ledger {ledger!r} is not a list')
    av = rnd.get('adjudicated_verdict')
    umr = rnd.get('unresolved_must_revise')
    if av != 'REVISE' or not isinstance(umr, int) or isinstance(umr, bool):
        raise StateError(f'round {num} carries a findings ledger but is not adjudicated '
                         f'REVISE with a settled unresolved count')
    mrc = rnd.get('must_revise_count')
    if len(ledger) != mrc:
        raise StateError(f'round {num} findings ledger holds {len(ledger)} entries but '
                         f'must_revise_count is {mrc!r}')
    revision_ordinals = set()
    for rev in doc.get('revisions') or []:
        if isinstance(rev, dict) and isinstance(rev.get('ordinal'), int):
            revision_ordinals.add(rev['ordinal'])
    file_rounds = {r.get('round') for r in doc.get('rounds') or []
                   if isinstance(r, dict) and r.get('adjudicated_verdict') == 'FILE'}
    ingested_unresolved = 0
    for pos, entry in enumerate(ledger, start=1):
        if not isinstance(entry, dict):
            raise StateError(f'round {num} findings entry {pos} is not an object')
        if entry.get('id') != pos:
            raise StateError(f'round {num} findings ids are not the sequence 1..K: '
                             f'position {pos} holds id {entry.get("id")!r}')
        summary = entry.get('summary')
        if not isinstance(summary, str) or not summary.strip():
            raise StateError(f'round {num} findings entry {pos} summary {summary!r} is '
                             f'not a non-empty string')
        splitter = _record_splitting_char(summary)
        if splitter is not None:
            raise StateError(f'round {num} findings entry {pos} summary contains the '
                             f'record-splitting character {splitter!r}')
        forged = _forged_protocol_token(summary)
        if forged is not None:
            raise StateError(f'round {num} findings entry {pos} summary contains the '
                             f'protocol token {forged + "="!r}')
        status = entry.get('status')
        if status not in _LEDGER_STATUSES:
            raise StateError(f'round {num} findings entry {pos} names a status outside '
                             f'the canonical set: {status!r}')
        ingested = entry.get('ingested_status')
        if ingested not in ('unresolved', 'resolved'):
            raise StateError(f'round {num} findings entry {pos} ingested_status '
                             f'{ingested!r} is outside the ingestion set')
        if ingested == 'unresolved':
            ingested_unresolved += 1
        # The ingestion provenance is what excuses a `resolved` entry from naming a revision
        # ordinal, so it must be legal ON THIS ENTRY — the write path emits it only alongside
        # an ingested-resolved status, and `_clear_settling` pops it on every later change.
        # Uncoupled, a hand-forged provenance on an ingested-UNRESOLVED entry passes every
        # other arm and drops the finding out of the effective count, converging the run on a
        # finding that was never fixed.
        prov = entry.get('ingest_provenance')
        if prov is not None and (prov != _LEDGER_INGESTED_RESOLVED or ingested != 'resolved'):
            raise StateError(f'round {num} findings entry {pos} carries ingest provenance '
                             f'{prov!r} but was ingested {ingested!r}')
        # Read-boundary mirror of `_clear_settling`'s writer set. It re-enforces the FULL
        # set of keys that helper clears, keyed on the status, rather than only the keys
        # a resolved/invalidated entry happens to read back: a partial check leaves a
        # reader/writer asymmetry where a residual `invalidation_reason` (or an
        # `ingest_provenance` a reopen should have popped) survives load on a status the
        # writer never emits it for. Coupled site — a key added to `_clear_settling`
        # belongs in `_LEGAL_SETTLING_KEYS` in the same change.
        residual = sorted(k for k in _SETTLING_KEYS
                          if k in entry and k not in _LEGAL_SETTLING_KEYS[status])
        if residual:
            raise StateError(f'round {num} findings entry {pos} is {status} but retains '
                             f'the settling provenance key {residual[0]!r}')
        if status == 'resolved':
            # `_LEGAL_SETTLING_KEYS` is a MEMBERSHIP test, so it cannot express that the
            # two resolved-provenance keys are mutually exclusive. They are: the writer
            # pops `ingest_provenance` (via `_clear_settling`) before setting
            # `resolution_ordinal`, so an entry carrying both is writer-unreachable — but
            # representable by hand, and on such an entry the ingest short-circuit below
            # would skip the recorded-revision check entirely (PR #612 review). Refuse the
            # combination rather than silently disabling the check it bypasses.
            if ('ingest_provenance' in entry and 'resolution_ordinal' in entry):
                raise StateError(f'round {num} findings entry {pos} is resolved but '
                                 f'carries both settling-provenance keys '
                                 f'(ingest_provenance and resolution_ordinal); they are '
                                 f'mutually exclusive by construction')
            if entry.get('ingest_provenance') != _LEDGER_INGESTED_RESOLVED:
                ordinal = entry.get('resolution_ordinal')
                if ordinal not in revision_ordinals:
                    raise StateError(
                        f'round {num} findings entry {pos} is resolved but its '
                        f'resolution ordinal {ordinal!r} names no recorded revision')
        if status == 'invalidated':
            reason = entry.get('invalidation_reason')
            if not isinstance(reason, str) or not reason.strip():
                raise StateError(f'round {num} findings entry {pos} is invalidated but '
                                 f'carries no non-empty reason')
            if _record_splitting_char(reason) is not None:
                raise StateError(f'round {num} findings entry {pos} invalidation reason '
                                 f'contains a record-splitting character')
            if _forged_protocol_token(reason) is not None:
                raise StateError(f'round {num} findings entry {pos} invalidation reason '
                                 f'contains a protocol token')
            prov = entry.get('invalidation_provenance')
            if prov != _PRE_REVISION and prov not in revision_ordinals:
                raise StateError(f'round {num} findings entry {pos} invalidation '
                                 f'provenance {prov!r} names no recorded revision')
        if status == 'superseded' and entry.get('supersession_round') not in file_rounds:
            raise StateError(f'round {num} findings entry {pos} is superseded but its '
                             f'provenance {entry.get("supersession_round")!r} names no '
                             f'FILE-adjudicated round')
        reopen = entry.get('reopen_provenance')
        if reopen is not None and reopen != _PRE_REVISION and (
                reopen not in revision_ordinals):
            raise StateError(f'round {num} findings entry {pos} reopen provenance '
                             f'{reopen!r} names no recorded revision')
    if ingested_unresolved != umr:
        raise StateError(f'round {num} findings ledger ingested {ingested_unresolved} '
                         f'unresolved entries but unresolved_must_revise is {umr}')


def _coverage_anchor_floor(text):
    """The text-only anchor floor (issue #708), as an error token or None.

    Split by where the operand lives: this is the TOOL-SIDE floor over the anchor text
    ALONE — non-empty, within the per-anchor length cap, no record-splitting byte, and no
    protocol-vocabulary `<field>=` token drawn from the tool's own printed surface. It
    reuses the ledger-anchor guard family (`_record_splitting_char` / `_forged_protocol_token`)
    so one closed vocabulary governs both — auditor-derived coverage text is identity data,
    never protocol and never an instruction to obey. The DATA-dependent checks (byte-identity
    against the rendered dimension text, and the cited-draft-line existence check) are the
    ORCHESTRATOR's, run against data the state owner does not hold; they are not enforced here.
    """
    if not isinstance(text, str) or not text.strip():
        return 'anchor-empty'
    if len(text) > _COVERAGE_ANCHOR_MAX:
        return 'anchor-over-cap'
    if _record_splitting_char(text) is not None:
        return 'anchor-control-char'
    if _forged_protocol_token(text) is not None:
        return 'anchor-protocol-vocabulary'
    return None


def _validate_coverage(rnd, num):
    """Re-enforce the per-dimension-coverage invariants at the READ boundary (issue #708).

    Absent is legal (a round records no coverage, and every pre-change round record none) —
    present-but-wrong-shape is corrupt, the same additive-optional pattern the per-finding
    ledger and `draft_binding` follow. Every violation raises StateError, collapsing the
    whole file to unestablished (the fail-closed environmental class), so a hand-corrupted
    coverage entry can never reach the derivation/trigger/summary as if established.
    """
    render = rnd.get('coverage_render')
    if render is not None and render not in _COVERAGE_RENDERS:
        raise StateError(f'round {num} names a coverage render outside the canonical set: '
                         f'{render!r}')
    if 'coverage' not in rnd:
        return
    if render is None:
        raise StateError(f'round {num} records coverage but no coverage_render; the render '
                         f'state is required whenever coverage is present (the derivation '
                         f'would otherwise default onto `full`, the one value that arms the '
                         f'coverage offer)')
    coverage = rnd.get('coverage')
    if not isinstance(coverage, list):
        raise StateError(f'round {num} coverage {coverage!r} is not a list')
    seen = set()
    for pos, entry in enumerate(coverage, start=1):
        if not isinstance(entry, dict):
            raise StateError(f'round {num} coverage entry {pos} is not an object')
        key = entry.get('key')
        if not isinstance(key, str) or not key.strip():
            raise StateError(f'round {num} coverage entry {pos} key {key!r} is not a '
                             f'non-empty string')
        if key in seen:
            raise StateError(f'round {num} coverage entry {pos} duplicates key {key!r}')
        seen.add(key)
        outcome = entry.get('outcome')
        if outcome not in _COVERAGE_OUTCOMES:
            raise StateError(f'round {num} coverage entry {pos} names an outcome outside '
                             f'the canonical set: {outcome!r}')
        anchor = entry.get('anchor')
        if outcome in _COVERAGE_ANCHORED:
            # An anchored outcome that reached persistence carries a floor-passing anchor:
            # ingestion downgrades a floor-failing exercised/valid-N/A to `unestablished`
            # BEFORE the write, so a hand-corrupted anchor on such an outcome is refused.
            err = _coverage_anchor_floor(anchor)
            if err is not None:
                raise StateError(f'round {num} coverage entry {pos} ({outcome}) anchor '
                                 f'fails the text-only floor ({err})')
        elif anchor is not None and not isinstance(anchor, str):
            raise StateError(f'round {num} coverage entry {pos} anchor {anchor!r} is not '
                             f'a string')


def _validate(doc, slug):
    """Validate a loaded document, or raise StateError naming the specific violation.

    Malformed state collapses the WHOLE file to unestablished rather than trusting a
    valid prefix: a corrupted record means the writer's invariants did not hold, so
    no earlier record's grounding is trustworthy either. Unknown is not zero.
    """
    if not isinstance(doc, dict):
        raise StateError(f'top-level JSON is not an object (found {type(doc).__name__})')
    for key in _REQUIRED_TOP:
        if key not in doc:
            raise StateError(f'required key {key!r} is missing')
    if doc['schema_version'] != SCHEMA_VERSION:
        raise StateError(
            f'schema_version {doc["schema_version"]!r} in file, tool expects '
            f'{SCHEMA_VERSION} (no migration path)')
    if doc['slug'] != slug:
        raise StateError(f'slug mismatch: file holds {doc["slug"]!r}, asked for {slug!r}')
    if not isinstance(doc['nonce'], str) or not doc['nonce']:
        raise StateError('nonce is missing or not a non-empty string')
    for key in ('rounds', 'revisions', 'overrides'):
        if not isinstance(doc[key], list):
            raise StateError(f'{key!r} is not a list (found {type(doc[key]).__name__})')
    seen = set()
    last = 0
    for rnd in doc['rounds']:
        if not isinstance(rnd, dict):
            raise StateError('a round record is not an object')
        for key in ('round', 'attempts', 'outcome'):
            if key not in rnd:
                raise StateError(f'a round record is missing required key {key!r}')
        num = rnd['round']
        if not isinstance(num, int) or isinstance(num, bool):
            raise StateError(f'round number {num!r} is not an integer')
        if num in seen:
            raise StateError(f'duplicate round number {num}')
        if num <= last:
            raise StateError(f'out-of-order round number {num} (previous was {last})')
        seen.add(num)
        last = num
        if not isinstance(rnd['attempts'], list) or not rnd['attempts']:
            raise StateError(f'round {num} has no attempts recorded')
        for att in rnd['attempts']:
            if not isinstance(att, dict) or 'arm' not in att:
                raise StateError(f'round {num} has a malformed attempt record')
            if att['arm'] not in _ARMS:
                raise StateError(f'round {num} names an arm outside the canonical set: '
                                 f'{att["arm"]!r}')
            # Mutation paths index these unconditionally (_carriage_ok, creation-epoch):
            # a corrupted field must collapse HERE to a named breadcrumb, never surface
            # later as a raw KeyError traceback.
            for key in ('digest', 'body_digest'):
                val = att.get(key)
                if not isinstance(val, str) or not val:
                    raise StateError(f'round {num} has an attempt whose {key} is missing '
                                     f'or not a non-empty string')
            for key in ('sentinel_open', 'sentinel_close'):
                val = att.get(key)
                if val is not None and not isinstance(val, str):
                    raise StateError(f'round {num} has an attempt whose {key} is not a '
                                     f'string')
        if rnd['outcome'] is not None and rnd['outcome'] not in _ROUND_OUTCOMES:
            raise StateError(f'round {num} names an outcome outside the canonical set: '
                             f'{rnd["outcome"]!r}')
        fc = rnd.get('findings_count')
        if fc is not None and (not isinstance(fc, int) or isinstance(fc, bool)
                               or fc < 0):
            raise StateError(f'round {num} findings_count {fc!r} is not a '
                             f'non-negative integer')
        # `pending` decides the next dispatch, so a hand-corrupted value outside the closed
        # answer set must fail closed here rather than reach the skill as an unroutable token.
        pend = rnd.get('pending')
        # The WRITER's domain, not the full answer vocabulary: record-return persists
        # only the three dispatch-* retry tokens (or None). A hand-corrupted
        # pending='proceed' would otherwise walk the orchestrator past an audit it
        # never received.
        if pend is not None and pend not in ('dispatch-embed-retry',
                                             'dispatch-retry-same-arm',
                                             'dispatch-inline-degraded'):
            raise StateError(f'round {num} names a pending action outside the canonical '
                             f'set: {pend!r}')
        # The per-round retry booleans DECIDE dispatch routing (`no_parseable_retry_used`
        # gates the same-arm-vs-inline escalation; `unreadable_retry_used` gates the
        # DRAFT-UNREADABLE embed retry and the `prior_unreadable` route), so a
        # hand-corrupted or absent value must fail closed here for exactly the reason
        # `pending`/`findings_count`/`outcome` above do — a falsy-corrupted
        # `unreadable_retry_used` would admit a SECOND DRAFT-UNREADABLE re-dispatch,
        # breaching the "exactly one per round" bound (a fail OPEN this read boundary
        # exists to catch). `degraded`/`consumer_dimensions_appended` feed the summary
        # line, so shape them too rather than trusting a corrupted flag.
        for bkey in ('no_parseable_retry_used', 'unreadable_retry_used',
                     'degraded', 'consumer_dimensions_appended'):
            bval = rnd.get(bkey)
            if bval is not None and not isinstance(bval, bool):
                raise StateError(f'round {num} {bkey} {bval!r} is not a boolean')
        for mk in rnd.get('embed_markers', []):
            if mk not in _EMBED_MARKER_TOKENS:
                raise StateError(f'round {num} names an embed marker outside the '
                                 f'canonical set: {mk!r}')
        # Post-adjudication payload (issue #548). T1, convergence, and the summary line
        # read these, so a hand-corrupted value must fail closed HERE — a bogus
        # adjudicated verdict or a negative count would otherwise reach the offer/convergence
        # decision as if established (unknown is not zero: an unestablished count is the
        # literal _UNESTABLISHED, never a coerced 0).
        av = rnd.get('adjudicated_verdict')
        if av is not None and av not in _ADJUDICATED_VERDICTS:
            raise StateError(f'round {num} names an adjudicated verdict outside the '
                             f'canonical set: {av!r}')
        for ckey in ('must_revise_count', 'advisory_count', 'invalid_count'):
            cval = rnd.get(ckey)
            if cval is not None and (not isinstance(cval, int) or isinstance(cval, bool)
                                     or cval < 0):
                raise StateError(f'round {num} {ckey} {cval!r} is not a non-negative '
                                 f'integer')
        umr = rnd.get('unresolved_must_revise')
        if umr is not None and umr != _UNESTABLISHED and (
                not isinstance(umr, int) or isinstance(umr, bool) or umr < 0):
            raise StateError(f'round {num} unresolved_must_revise {umr!r} is not a '
                             f'non-negative integer or the literal {_UNESTABLISHED!r}')
        # Re-assert the record-time verdict<->count agreement at the READ boundary, exactly as
        # the revision after_round<floor_round guard is re-checked here: cmd_record_adjudication
        # enforces FILE<=>0 / REVISE<=>>=1 and unresolved<=must_revise on write, but a
        # hand-corrupted state file must not smuggle a self-inconsistent payload (e.g.
        # adjudicated_verdict='FILE' with unresolved_must_revise=5) past that gate to reach
        # T1/convergence/summary as if established. Only enforce when both operands are present
        # and the count is settled — an _UNESTABLISHED count agrees with neither verdict and
        # (per the write path) can only accompany REVISE, which is checked too.
        if av is not None:
            if umr == _UNESTABLISHED and av == 'FILE':
                raise StateError(f'round {num} adjudicated verdict FILE cannot pair with an '
                                 f'{_UNESTABLISHED!r} unresolved must-revise count')
            if isinstance(umr, int) and not isinstance(umr, bool):
                if av == 'FILE' and umr != 0:
                    raise StateError(f'round {num} adjudicated verdict FILE disagrees with '
                                     f'unresolved_must_revise {umr} (FILE requires 0)')
                if av == 'REVISE' and umr < 1:
                    raise StateError(f'round {num} adjudicated verdict REVISE disagrees with '
                                     f'unresolved_must_revise {umr} (REVISE requires >= 1)')
                mrc = rnd.get('must_revise_count')
                if (isinstance(mrc, int) and not isinstance(mrc, bool)
                        and mrc >= 0 and umr > mrc):
                    raise StateError(f'round {num} unresolved_must_revise {umr} exceeds '
                                     f'must_revise_count {mrc} (unresolved is a subset)')
        # Per-finding ledger (issue #603). T1, convergence, query-findings and the summary
        # line all read these, so a hand-corrupted entry must fail closed HERE — a bogus
        # status or a resolution naming no recorded revision would otherwise reach the
        # convergence decision as if it were a verified fix.
        _validate_ledger(doc, rnd, num)
        # Per-dimension coverage (issue #708). The coverage derivation, the offer trigger,
        # and the summary line read these, so a hand-corrupted entry must fail closed HERE.
        _validate_coverage(rnd, num)
    for ov in doc['overrides']:
        if not isinstance(ov, dict) or ov.get('kind') not in _OVERRIDE_KINDS:
            raise StateError('an override record names a kind outside the canonical set')
        surface = ov.get('surface')
        if surface is not None and surface not in _OVERRIDE_SURFACES:
            raise StateError(f'an override record names a surface outside the canonical '
                             f'set: {surface!r}')
        rao = ov.get('recorded_at_ordinal')
        if not isinstance(rao, int) or isinstance(rao, bool):
            raise StateError(f'an override record recorded_at_ordinal {rao!r} is not an '
                             f'integer')
        dd = ov.get('draft_digest')
        if dd is not None and (not isinstance(dd, str) or not dd):
            # Non-empty when present, mirroring the round `digest`/`body_digest` rule: an
            # empty bound digest would compare equal to an empty computed digest on the
            # override ground and ground eligibility on unaudited bytes (fail open).
            raise StateError('an override record draft_digest is not a non-empty string')
    # Read-surface fields the QUERIES consume must be shape-checked here too: a
    # corrupted revision record, counter, or creation record would otherwise crash a
    # query (AttributeError/TypeError), presenting a crashed read as a non-zero query
    # exit — the exact two-class-contract violation _validate exists to prevent.
    for i, rev in enumerate(doc['revisions']):
        if not isinstance(rev, dict):
            raise StateError('a revision record is not an object')
        for key in ('ordinal', 'after_round', 'floor_round'):
            val = rev.get(key)
            if not isinstance(val, int) or isinstance(val, bool):
                raise StateError(f'a revision record {key} {val!r} is not an integer')
        # revision_ordinal() is len(revisions); the stored ordinals must agree with it
        # (a 1..N chain) or the record tells a different story than the derivation.
        if rev['ordinal'] != i + 1:
            raise StateError(f'revision ordinal chain broken: position {i + 1} holds '
                             f'ordinal {rev["ordinal"]}')
        # Re-check record-revision's OWN guard at the read boundary, against the floor
        # that call recorded. `after_round` is the sole invalidation evidence on the
        # event-ordering ground (_revision_postdates keys eligibility and T2 on it), so a
        # value below the floor fails that guard OPEN — a revised, never-audited draft
        # answers eligible and emit-body emits it at exit 0. The write boundary refuses
        # that value, but this is the gate: a hand-corrupted record must not smuggle it
        # past, exactly as _valid_override re-checks its own write guards here.
        if rev['after_round'] < rev['floor_round']:
            raise StateError(
                f'revision {rev["ordinal"]} names after_round {rev["after_round"]} '
                f'below the floor {rev["floor_round"]} recorded with it (a value below '
                f'the last completed round fails the event-ordering staleness guard '
                f'open)')
        # issue #562: the revision bytes' stdin digest, when the revision was recorded
        # with its bytes. Non-empty-when-present (the round `digest` rule): the
        # post-revision `approve` ground compares it against a later landed dispatch
        # digest, and an empty one would compare equal to nothing meaningfully.
        sd = rev.get('stdin_digest')
        if sd is not None and (not isinstance(sd, str) or not sd):
            raise StateError(f'revision {rev["ordinal"]} stdin_digest is present but not '
                             f'a non-empty string')
    for key in ('automatic_reaudits_used', 'user_rounds_used'):
        val = doc.get(key, 0)
        if not isinstance(val, int) or isinstance(val, bool):
            raise StateError(f'{key} {val!r} is not an integer')
    rf = doc.get('reinit_forced')
    if rf is not None and not isinstance(rf, bool):
        raise StateError(f'reinit_forced {rf!r} is not a boolean')
    creation = doc.get('creation')
    if creation is not None:
        if not isinstance(creation, dict):
            raise StateError('the creation record is not an object')
        # Shape-checked exactly like the sibling round/override/revision records. The
        # digest is the attestation's comparand: a non-string one does NOT crash the
        # compare, it silently loses it (`got == <non-str>` is False), so a corrupted
        # record would render a confident `attestation=mismatch` about a comparison
        # that never meaningfully happened — a guard failing open as misattribution
        # rather than closed. epoch_round/epoch_arm have no reader today, but they are
        # checked here on the same rule the sibling records follow: a later consumer
        # must inherit a validated record, not an unvalidated hole.
        digest = creation.get('body_only_digest')
        if not isinstance(digest, str) or not digest:
            raise StateError('the creation record body_only_digest is missing or not a '
                             'non-empty string')
        epoch_round = creation.get('epoch_round')
        if not isinstance(epoch_round, int) or isinstance(epoch_round, bool):
            raise StateError(f'the creation record epoch_round {epoch_round!r} is not an '
                             f'integer')
        epoch_arm = creation.get('epoch_arm')
        if epoch_arm not in _ARMS:
            raise StateError(f'the creation record names an epoch arm outside the '
                             f'canonical set: {epoch_arm!r}')
        att = creation.get('attestation')
        if att is not None and att not in _ATTESTATIONS:
            raise StateError(f'the creation record names an attestation status outside '
                             f'the canonical set: {att!r}')
    # issue #562: the tiered draft-root binding. Read by the digest/eligibility/
    # body-emission operations and by the binding/summary queries, so a hand-corrupted
    # record must fail closed HERE (a named breadcrumb collapsing the whole state to
    # unestablished), never surface later as a KeyError/AttributeError in a query that
    # is contractually always-exit-0.
    binding = doc.get('draft_binding')
    if binding is not None:
        if not isinstance(binding, dict):
            raise StateError('the draft_binding record is not an object')
        if not _is_bound_path(binding.get('path')):
            raise StateError('the draft_binding record path is missing or not an '
                             'absolute, single-line string')
        if binding.get('tier') not in _DRAFT_TIERS:
            raise StateError(f'the draft_binding record names a tier outside the '
                             f'canonical set: {binding.get("tier")!r}')
        nbr = binding.get('non_bound_root')
        # Absent (recorded None) is legal — the breadcrumb/no-answer/failed-.git-test
        # arm records no non-bound root; present-but-non-absolute is corrupt.
        if nbr is not None and not _is_bound_path(nbr):
            raise StateError('the draft_binding record non_bound_root is present but not '
                             'an absolute, single-line string')
    # issue #562: the canonical-write-failure log at the bound path. Each entry names the
    # revision ordinal whose overwrite failed (an int) — a bare integer list is enough
    # for the post-revision `approve` ground, which only asks "did the latest revision's
    # overwrite land".
    wf = doc.get('write_failures')
    # Absent is legal (a pre-binding or legacy record has none); present-but-non-list is
    # corrupt and fails closed like every other read-surface field.
    if wf is not None:
        if not isinstance(wf, list):
            raise StateError(f'write_failures is not a list (found {type(wf).__name__})')
        for entry in wf:
            if not isinstance(entry, int) or isinstance(entry, bool):
                raise StateError(f'a write_failures entry {entry!r} is not an integer')
    return doc


def load_state(slug, root=None):
    """Load and validate. Raises StateError for every untrustworthy shape."""
    path = state_path(slug, root)
    try:
        raw = path.read_bytes()
    except FileNotFoundError as exc:
        raise StateError(f'no state file at {path}; run init first') from exc
    except OSError as exc:
        raise StateError(f'state file at {path} is unreadable: {exc}') from exc
    if not raw.strip():
        raise StateError(f'state file at {path} is present but empty')
    try:
        doc = json.loads(raw.decode('utf-8'))
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise StateError(f'state file at {path} is not parseable JSON: {exc}') from exc
    return _validate(doc, slug)


def save_state(doc, slug, root=None):
    """Persist atomically. Raises StateError when the state cannot be persisted."""
    path = state_path(slug, root)
    # Re-validate at the construction boundary: a mutation bug that assembled an
    # invalid document fails HERE, loudly, instead of persisting silently and
    # collapsing the whole file to unestablished at the next load.
    _validate(doc, slug)
    tmp = path.with_suffix('.json.tmp')
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp.write_text(json.dumps(doc, indent=2, sort_keys=True) + '\n', encoding='utf-8')
        os.replace(tmp, path)
    except OSError as exc:
        # Best-effort cleanup of a partial temp file so a failed persist never leaves
        # a stray .json.tmp in the evidence-bearing tmp directory.
        try:
            tmp.unlink()
        except OSError:
            pass
        raise StateError(f'could not persist state to {path}: {exc}') from exc
    return path


def _check_nonce(doc, nonce):
    if nonce != doc['nonce']:
        raise StateError(
            'nonce mismatch — this call does not belong to the run that owns this '
            f'state file (passed {nonce!r})')


# ── Pure decision functions ────────────────────────────────────────────────────

def classify_return(arm, verdict, has_verdict_line, carriage_ok):
    """Classify an auditor return. Retry precedence is fixed and lives here.

    A return that is both unreadable-prose and verdict-less is classified by the
    ABSENT VERDICT LINE — the absent line is tested before any arm/verdict rule, so
    the precedence cannot be reordered by accident. Absent carriage evidence is
    treated exactly like mismatched evidence.
    """
    if not has_verdict_line or verdict is None:
        return 'no-parseable-verdict'
    if verdict not in _VERDICTS:
        return 'no-parseable-verdict'
    if verdict == 'DRAFT-UNREADABLE':
        # Carriage evidence is not applicable: the auditor is reporting it could not
        # read the draft at all, so it has nothing to quote.
        return _legality(arm, verdict)
    if not carriage_ok:
        return 'no-parseable-verdict'
    return _legality(arm, verdict)


def _legality(arm, verdict):
    for r in TRANSITIONS:
        if r['condition'] == 'verdict-on-arm' and r['arm'] == arm and r['verdict'] == verdict:
            if r['result'] not in _CLASSIFICATIONS:
                raise AssertionError(
                    f'issue-audit-state: the verdict-on-arm row for arm={arm!r} '
                    f'verdict={verdict!r} names {r["result"]!r}, which is not a return '
                    f'classification in _CLASSIFICATIONS')
            return r['result']
    raise KeyError(f'no transition row for arm={arm!r} verdict={verdict!r}')


def completed_rounds(state):
    return [r for r in state['rounds'] if r.get('outcome') is not None]


def last_completed(state):
    done = completed_rounds(state)
    return done[-1] if done else None


def revision_ordinal(state):
    return len(state['revisions'])


def _revision_postdates(state, rnd):
    return any(rev.get('after_round', 0) >= rnd['round'] for rev in state['revisions'])


def _unresolved_int(rnd):
    """The round's adjudicated unresolved-must-revise count as a concrete int, else None.

    The count is meaningful ONLY post-adjudication, so a round whose `adjudicated_verdict`
    is absent has no established count regardless of any stored `unresolved_must_revise`
    value: `None` is returned first on that path. Keying on the verdict here — not solely on
    the count field — closes a co-presence gap a hand-corrupted state could open: a completed
    REVISE round hand-edited to carry `adjudicated_verdict = None` with a settled
    `unresolved_must_revise` of 0 would otherwise return that 0 as established, making T1 read
    it clean AND the `unadjudicated-round` T2 arm (guarded on `u is None`) NOT fire — the exact
    silent boundary-offer drop that arm exists to prevent (issue #548 re-review). Deriving
    "is the count established" from the verdict makes T1, the `unadjudicated-round` T2 arm, and
    `evaluate_convergence` (which already gates on `adjudicated_verdict` first) agree that a
    count without a verdict is unestablished — the write path never emits that pairing (an
    un-adjudicated round carries a `None` count), so the guard bites only corruption.

    Past that early return the round is adjudicated, and `None` still covers every remaining
    case that is NOT a settled integer: a round adjudicated but unestablished (the literal
    `_UNESTABLISHED`), or a stored `None`/non-int count. (A never-adjudicated round carries a
    `None` verdict, so it is caught by the early return above, not here.) A bool is not an int
    here (Python's `isinstance(True, int)` is True), so it is excluded explicitly. Non-negativity
    is enforced upstream by `_validate` (and by `cmd_record_adjudication` at the write boundary),
    so any stored int reaching here is already >= 0.
    """
    if rnd.get('adjudicated_verdict') is None:
        return None
    v = rnd.get('unresolved_must_revise')
    if isinstance(v, bool) or not isinstance(v, int):
        return None
    return v


# ── The per-finding ledger and the effective unresolved count (issue #603) ────────

def _ledger(rnd):
    """The round's per-finding ledger as a list, or None when the round carries none.

    A ledger is recorded only on a round adjudicated REVISE with a SETTLED count. A FILE
    round, a `REVISE … unestablished` round, and every pre-change round in an older state
    file are ledger-less — `None`, never an empty list, so callers can distinguish
    "no ledger" from "a ledger with nothing on it".
    """
    led = rnd.get('findings')
    return led if isinstance(led, list) else None


def _all_entries(state):
    """Every recorded ledger entry in the run, as `(round, entry)` pairs.

    The single run-wide traversal. Several consumers walk the ledgers, and stating "what
    is a ledger, and which rounds contribute" once here is what keeps them from drifting
    apart as the status set grows.
    """
    for rnd in state['rounds']:
        for entry in (_ledger(rnd) or []):
            yield rnd, entry


def _provenance_ordinal(value):
    """A provenance stamp as a comparable ordinal, or None when it names none.

    The `pre-revision` token counts as ordinal 0, so a stamp made before any revision
    existed is correctly older than every recorded revision.
    """
    if value == _PRE_REVISION:
        return 0
    if isinstance(value, int) and not isinstance(value, bool):
        return value
    return None


def _settling_ordinal(entry):
    """The revision ordinal an entry's post-close settling change was verified against.

    Only a post-close-settled entry has one: `resolved` (via record-resolution, or the
    ingestion provenance, which predates every revision) or `invalidated`. Stamps are
    compared through `_provenance_ordinal`, which owns the `_PRE_REVISION`-is-ordinal-0
    rationale. Returns None for an entry that is not post-close-settled (`unresolved`, and `superseded`, which rests on
    the auditor's own FILE verdict rather than on a self-attested change).
    """
    status = entry.get('status')
    if status == 'resolved':
        if entry.get('ingest_provenance') == _LEDGER_INGESTED_RESOLVED:
            return 0
        ordinal = entry.get('resolution_ordinal')
    elif status == 'invalidated':
        ordinal = entry.get('invalidation_provenance')
    else:
        return None
    return _provenance_ordinal(ordinal)


def _effective_unresolved(state):
    """The RUN-WIDE effective unresolved-must-revise count, or None when unestablished.

    The count is the number of ledger entries still `unresolved` across EVERY recorded
    ledger — resolved, invalidated, and superseded entries excluded — plus the latest
    completed round's adjudicated count when that round is REVISE-adjudicated but carries
    no ledger. That passthrough is what keeps a pre-change state file behaving exactly as
    it does today.

    Establishedness is delegated wholesale to `_unresolved_int` on the latest completed
    round, so this derivation returns None in exactly the places that one does (an
    un-adjudicated round, an `unestablished` count, a non-int count) and the
    `unadjudicated-round` T2 arm keeps its comparand. Unknown is not zero: a ledger that
    happens to sum to 0 never launders an unestablished latest round into a clean answer.

    Disclosed limitation, mandated by AC5: only the LATEST completed round's count is
    passed through, so unresolved findings from any **earlier** ledger-less round are
    invisible to the aggregate. Two distinct shapes reach that state, and the second is
    NOT a migration artifact — do not read this as legacy-only:
      * a PRE-CHANGE earlier round, written before ledgers existed; and
      * a post-change round adjudicated `REVISE` with an `unestablished` count, which
        `cmd_record_adjudication` accepts WITHOUT a ledger (the `--ledger-stdin`
        requirement is keyed on a SETTLED count), and which stops being the latest
        completed round as soon as a further round completes.
    So a run whose earlier round holds unestablished findings can report `converged=yes
    basis=resolution` once a later ledgered round settles. AC5 fixes this passthrough
    ("returns not-established exactly where `_unresolved_int` does today"), so the
    boundary is stated rather than silently widened here; re-auditing re-surfaces a
    genuinely unfixed defect onto a later ledgered round, which bounds the residual.
    """
    last = last_completed(state)
    if last is None:
        return None
    frozen = _unresolved_int(last)
    if frozen is None:
        return None
    total = sum(1 for _, entry in _all_entries(state)
                if entry.get('status') == 'unresolved')
    if last.get('adjudicated_verdict') == 'REVISE' and _ledger(last) is None:
        total += frozen
    return total


def _convergence_basis(state, converged):
    """The basis token for a convergence answer, keyed on the LATEST accepted adjudication.

    `adjudicated` when the latest completed round is FILE-adjudicated — the auditor's own
    verdict vouches for the state, including everything that round superseded.
    `resolution` when the latest completed round is REVISE-adjudicated and the effective
    count reached zero through post-close status changes, and `resolution-stale` when any
    post-close-settled entry's settling provenance ordinal is BELOW the latest recorded
    revision ordinal — staleness judged PER ENTRY, so an interleaved
    resolve → revise → resolve run stays stale on the earlier entry's account, whose
    verification predates the intervening revision. `none` on every not-converged answer.

    Keying on the latest accepted adjudication rather than on the mere existence of
    post-close records is load-bearing: because a REVISE adjudication requires an
    unresolved count of at least 1, every ledger carries an unresolved entry at ingestion,
    so an existence-keyed rule would make `adjudicated` unreachable on any run that ever
    went REVISE.
    """
    if not converged:
        return 'none'
    last = last_completed(state)
    if last is not None and last.get('adjudicated_verdict') == 'FILE':
        return 'adjudicated'
    latest_revision = revision_ordinal(state)
    for _, entry in _all_entries(state):
        settled_at = _settling_ordinal(entry)
        if settled_at is None:
            continue
        if settled_at < latest_revision:
            return 'resolution-stale'
        # A reopen RECORDS that the entry's previous settling did not hold, so re-settling it
        # against the very same (already-disproven) ordinal is not fresh evidence. Without
        # this, reopen -> re-resolve on the same ordinal converges on a plain `resolution`
        # basis and the reopen — the run's own contradiction of that ordinal — never reaches
        # the currency judgment.
        reopened_at = _provenance_ordinal(entry.get('reopen_provenance'))
        if reopened_at is not None and settled_at <= reopened_at:
            return 'resolution-stale'
    return 'resolution'


# ── Draft-root binding (issue #562) ──────────────────────────────────────────────

def _binding(state):
    """The recorded draft-root binding dict, or None when no write has bound one yet."""
    return (state or {}).get('draft_binding')


def _bound_path(state):
    """The absolute bound draft ROOT, or None when unbound. `_validate` proved it
    absolute at load. This is the root the display and `bound_root` report and the tier
    token classifies — NOT the draft file itself (see `_bound_draft_file`)."""
    b = _binding(state)
    return b['path'] if b else None


def _bound_draft_file(state, slug):
    """The absolute bound canonical draft FILE, or None when unbound.

    The binding records the bound *root* (`_bound_path`); the canonical draft file is
    that root joined with the fixed `.devflow/tmp/issue-draft-<slug>.md` subpath — the
    same path the skill writes and displays. The digest / eligibility / body-emitting
    readers resolve THIS from the recorded binding so a compacted context that hands a
    drifted `--draft-file` cannot redirect them; they fall back to the caller-supplied
    `--draft-file` only on an unbound run.
    """
    root = _bound_path(state)
    if root is None:
        return None
    return str(Path(root) / '.devflow' / 'tmp' / f'issue-draft-{slug}.md')


def latest_revision_landed(state):
    """True when the latest recorded revision's bytes have landed at the bound path.

    Vacuously true when no revision is recorded (nothing is unlanded). Otherwise the
    latest revision counts as landed once a **subsequent** recorded landed write at the
    bound path (a round-initiating file-arm dispatch record qualifies) carries a digest
    equal to that revision's recorded stdin digest — the clearing predicate that lets a
    recovered run re-enter the full file-arm contract (issue #562).

    Two fail-closed conditions, both load-bearing:
      - A recorded overwrite failure for the latest revision (its ordinal in
        `write_failures`) means the bound file does NOT hold the revised bytes, so the
        revision has NOT landed — even if its stdin digest coincidentally equals some
        earlier audited dispatch's digest (the user revised back to bytes a prior round
        already saw). Without this the write-failure log and this predicate would be
        disconnected and a known-failed write could still read as landed. This check is
        deliberately checked BEFORE the clearing scan, so a recorded write-failure is
        **terminal for that ordinal**: the general clearing clause above does NOT re-fire
        for it — not even a genuinely subsequent matching dispatch clears a write-failed
        ordinal (the flag stays `not landed` until a *fresh* revision without a recorded
        failure supersedes it). This flag governs presentation source only; the `approve`
        eligibility ground recovers independently through its fresh-clean-round staleness
        gate (`_revision_postdates`): a subsequent clean round that no revision postdates
        re-enables the eligibility ground, so a recovered run still re-enters file-sourced
        creation there even while this flag stays conservatively `not landed`.
      - The matching dispatch must be **subsequent** — recorded in a round whose number
        is greater than the revision's `after_round` — so a *predating* dispatch that
        happens to share the digest never satisfies the clearing predicate. A revision
        with NO stdin digest (a legacy/embed-epoch revision) cannot be proven landed and
        fails closed to `not landed`, the conservative presentation choice.
    """
    revs = state['revisions']
    if not revs:
        return True
    latest = revs[-1]
    # The latest revision's ordinal is len(revs) (the 1..N chain). A recorded overwrite
    # failure for it means it never landed.
    if len(revs) in (state.get('write_failures') or []):
        return False
    want = latest.get('stdin_digest')
    if not want:
        return False
    after = latest.get('after_round', 0)
    for rnd in state['rounds']:
        if rnd['round'] <= after:
            continue  # only a write recorded AFTER the revision proves it landed
        for att in rnd['attempts']:
            if att['arm'] == 'file' and att.get('digest') == want:
                return True
    return False


def evaluate_triggers(state):
    """T1/T2, evaluated from recorded state.

    T1 (issue #548, comparand widened by #603) consumes the RUN-WIDE EFFECTIVE unresolved
    must-revise count (`_effective_unresolved`) — never the raw `VERDICT: REVISE` token, and
    no longer the count frozen at the latest completed round's close: it holds only when at
    least one unresolved must-revise finding remains across every recorded ledger (a settled
    count ≥ 1). An un-adjudicated or unestablished count does NOT hold T1 — a *verified*
    finding is required.
    T2 provides the fail-closed unknown-state coverage: it holds when a revision record
    postdates the last completed round's record; when the last completed round hit the
    verdict-less (`no-verdict`) terminal (the content is effectively unaudited); when a
    completed **REVISE** round's post-adjudication unresolved-must-revise count (this arm's own
    comparand — T1 itself reads the effective count since #603) is absent — whether the round was never adjudicated OR was adjudicated with an `unestablished`
    count (the pre-#548 raw-REVISE token fired the offer, so either low-evidence path must not
    silently drop it — the offer fires rather than being skipped, exactly the absent-comparand
    fail-closed the guard would otherwise fail open on); and whenever state is unestablishable
    (unknown is not zero). A naming `reason` is surfaced on exactly the three fail-closed arms
    that need one — `state-unestablished`, `no-verdict-round`, and `unadjudicated-round` — and is `None` when
    T2 holds purely because a revision postdates a known, audited last round (the offer fires,
    but there is no anomaly to name). An un-adjudicated *FILE* round is NOT any of these — its
    raw signal is clean and pre-#548 it fired no offer, so T2's behavior on it is unchanged.
    """
    if state is None:
        return {'t1': False, 't2': True, 'coverage': False,
                'reason': 'state-unestablished'}
    last = last_completed(state)
    if last is None:
        return {'t1': False, 't2': False, 'coverage': False, 'reason': None}
    u = _unresolved_int(last)
    # issue #603: T1's comparand is the RUN-WIDE EFFECTIVE count, so a round whose ledger
    # entries the drafter verified fixed (or retired as invalid, or that a FILE re-audit
    # superseded) releases the trigger instead of holding it forever on a count frozen at
    # round close. `_effective_unresolved` delegates establishedness to `_unresolved_int`,
    # so it is None in exactly the same places — the `unadjudicated-round` T2 arm below
    # keeps reading `u` and its behavior is unchanged.
    eff = _effective_unresolved(state)
    t1 = eff is not None and eff >= 1
    t2 = _revision_postdates(state, last)
    reason = None
    if last.get('outcome') == 'no-verdict':
        # The verdict-less terminal: T1 does not hold (there is no adjudicated must-revise
        # finding on an unaudited round), but the content is effectively unaudited, so T2 is
        # treated as holding and the boundary offer fires naming the state.
        t2 = True
        reason = 'no-verdict-round'
    elif last.get('outcome') == 'REVISE' and u is None:
        # A completed REVISE round whose POST-ADJUDICATION unresolved-must-revise count (this
        # arm's own comparand since #603 — T1 now reads the effective count) is absent — `_unresolved_int` returned None. That covers BOTH low-evidence
        # paths: the round was never adjudicated (`adjudicated_verdict is None`), OR it was
        # adjudicated with the literal `unestablished` count (a legal REVISE+unestablished
        # pairing `cmd_record_adjudication`/`_validate` both accept). Pre-#548 the raw REVISE
        # token fired T1 unconditionally, so on EITHER path the boundary offer would be SILENTLY
        # dropped without this arm — a guard failing open on exactly the unknown-count path it
        # exists to catch (unknown is not zero). Fail closed to the offer and surface the reason.
        # A clean FILE round left un-adjudicated is deliberately NOT this case (pre-#548 it fired
        # no offer either); a REVISE round adjudicated with a settled count >= 1 is caught by T1
        # above (u is not None), never here.
        t2 = True
        reason = 'unadjudicated-round'
    return {'t1': t1, 't2': t2, 'coverage': evaluate_coverage_trigger(state),
            'reason': reason}


def evaluate_convergence(state):
    """Whether the run has converged (issue #548).

    A converged run is one with ZERO effective unresolved must-revise axis-attributable
    findings — either because its final accepted, post-adjudication verdict is
    `VERDICT: FILE` (basis `adjudicated`), or because every recorded ledger entry was
    settled post-close by a self-verified resolution or invalidation (basis `resolution`,
    or `resolution-stale` when a later revision postdates an entry's verification).
    Advisory and invalid/unverified findings do not block convergence. A final round that
    is un-adjudicated, or whose unresolved-must-revise count is unestablished, is NOT
    converged (unknown is not zero); unestablishable state is not converged either.

    Budget legality is NOT read here and never was — it is enforced upstream at round
    funding (`_MAX_AUTOMATIC_REAUDITS` / `_USER_ROUND_CAP`); the pre-#603 wording claimed
    a budget clause this function does not compute (issue #603 AC7).
    """
    if state is None:
        return {'converged': False, 'reason': 'state-unestablished', 'basis': 'none',
                'effective': None}
    last = last_completed(state)
    if last is None:
        return {'converged': False, 'reason': 'no-completed-round', 'basis': 'none',
                'effective': None}
    adjudicated = last.get('adjudicated_verdict')
    if adjudicated is None:
        return {'converged': False, 'reason': 'unadjudicated', 'basis': 'none',
                'effective': None}
    eff = _effective_unresolved(state)
    if eff is None:
        # Adjudicated but the count is the literal _UNESTABLISHED (or otherwise not a
        # settled int): unknown is not zero, so this is not a converged run.
        return {'converged': False, 'reason': 'unresolved-unestablished',
                'basis': 'none', 'effective': None}
    # issue #603: the count is the run-wide EFFECTIVE one, so a REVISE-latest run whose
    # ledgers were all settled post-close converges too — reported on a basis token that
    # keeps it distinguishable from an auditor-accepted FILE convergence.
    converged = eff == 0
    # `effective` rides along so a caller wanting BOTH the count and the basis — the
    # summary line does — derives them from ONE evaluation. Two independent call sites
    # could otherwise render two fields describing different states.
    return {'converged': converged,
            'reason': None if converged else 'unresolved-must-revise-remain',
            'basis': _convergence_basis(state, converged),
            'effective': eff}


def _coverage_round(state):
    """The final accepted round coverage-backing derives from, or None.

    Coverage attaches ONLY to a run whose final accepted round is a clean auditor
    `VERDICT: FILE` (issue #708): a no-clean-round convergence (the resolution-basis /
    resolution-stale path) carries no per-dimension coverage, so it derives
    `unestablished`. `last_completed` is the run's final accepted round; it is a
    coverage round only when its outcome is `FILE`.
    """
    if state is None:
        return None
    last = last_completed(state)
    if last is None or last.get('outcome') != 'FILE':
        return None
    return last


def evaluate_coverage(state):
    """The run's coverage-backing, derived from the final accepted clean round (issue #708).

    Returns `{'backing': <token>, 'render': <token>}`:
      - `backing` in `_COVERAGE_BACKINGS`. `backed` only when the final accepted round is
        a clean `FILE` round carrying a recorded coverage list in which EVERY entry is
        `exercised` or `valid-N/A`; `not-backed` when any surviving `skipped`/`unestablished`
        entry remains on that otherwise-clean round; `unestablished` when there is no clean
        auditor round to carry coverage, or the clean round recorded no coverage at all
        (unknown is never collapsed onto backed).
      - `render` in `('full', 'degraded', 'none')` — the coverage round's recorded render
        state, or `none` when there is no coverage round. A `degraded` render discloses but
        does not fire the coverage offer (that is the trigger's job).

    Coverage-backing is a DISTINCT axis from convergence: it never redefines
    `evaluate_convergence`, never gates `emit-body`/`query-eligibility`. Its only teeth are
    the coverage offer trigger.
    """
    if state is None:
        # The state could not be established at all (unreadable/corrupt — including a
        # `_validate_coverage` raise). Byte-identical to the two BENIGN unestablished arms
        # below unless the cause rides on the answering line, which is how a corrupt file
        # reads as "no coverage round yet" — so each arm names its own reason.
        return {'backing': 'unestablished', 'render': 'none', 'round': None,
                'reason': 'state-unestablished'}
    rnd = _coverage_round(state)
    if rnd is None:
        return {'backing': 'unestablished', 'render': 'none', 'round': None,
                'reason': 'no-clean-round'}
    coverage = rnd.get('coverage')
    if not coverage:
        # A clean round that recorded no coverage: unknown is not backed.
        return {'backing': 'unestablished', 'render': 'none', 'round': rnd,
                'reason': 'no-coverage-recorded'}
    backed = all(e.get('outcome') in _COVERAGE_BACKING_OUTCOMES for e in coverage)
    backing = 'backed' if backed else 'not-backed'
    # The closed backing vocabulary is asserted, not merely documented: a token typo'd
    # here would otherwise ship green, since nothing downstream re-checks it.
    assert backing in _COVERAGE_BACKINGS
    return {'backing': backing, 'render': rnd.get('coverage_render') or 'full',
            'round': rnd, 'reason': None}


def evaluate_coverage_trigger(state):
    """Whether the unbacked-coverage offer trigger holds (issue #708).

    A sibling of T1/T2, routed through the existing offer machinery and the existing
    user-round cap. It fires ONLY on a genuinely-unbacked FULL-render clean audit — a
    `skipped`/empty/generic-adjudicated anchor on a dimension the auditor DID render. A
    legitimately narrowed (`degraded`) render discloses but never fires, so a consumer whose
    auditor takes a fallback rung is not offered-at every run; a non-clean or no-coverage run
    (backing `unestablished`) never fires either — filing is never blocked by this trigger.
    """
    cov = evaluate_coverage(state)
    return cov['backing'] == 'not-backed' and cov['render'] == 'full'


def issue_token(nonce, ground, key):
    """The deterministic eligibility token.

    A pure function of the run nonce and the answering key, so repeated queries
    re-emit an identical token while any change of that key produces a different one.
    The key is the operand that actually answered: the digest on the file-identity
    ground and on a digest-bound (file-arm) override; the revision ordinal on the
    event-ordering ground and on an override with no digest bound, where no
    trustworthy canonical file exists to key on. `hashlib` rather than git: the token
    is not a content hash and the tool's only subprocess is git for object IDs.
    """
    material = f'{nonce}:{ground}:{key}'.encode('utf-8')
    return 'eat_' + hashlib.sha256(material).hexdigest()[:16]


def _valid_override(state, current_digest):
    """The newest override still current, or None.

    An override is valid only while the revision ordinal recorded on it stays
    current, and — on a file-arm epoch — while the digest recorded on it still
    matches the draft. A later revision record invalidates every earlier override,
    and a stale override never re-arms.

    Two preconditions fail CLOSED here, mirroring the guards `record-override`
    applies at the write boundary. They are re-checked at this read boundary because
    this is the gate: a hand-edited state file, or a record written by an older
    build, must not smuggle an override past them.

      - No completed round means nothing was ever audited, so there is no audit for
        an override to override. Without this, `init` -> `record-override` alone
        answered `eligible`, and `emit-body` emitted a never-audited body at exit 0.
      - On a file-arm epoch an override carrying no digest was never compared against
        any bytes, so honouring it would pass a draft the tool never inspected. An
        absent comparand fails closed rather than skipping the comparison.
    """
    epoch = last_completed(state)
    if epoch is None:
        return None
    file_arm_epoch = epoch['attempts'][-1]['arm'] == 'file'
    now = revision_ordinal(state)
    for ov in reversed(state['overrides']):
        if ov.get('recorded_at_ordinal') != now:
            continue
        want = ov.get('draft_digest')
        if want is None:
            if file_arm_epoch:
                continue
        elif want != current_digest:
            continue
        return ov
    return None


_STALE_OVERRIDE_ELECTION = (
    're-present the revised draft and record a new override only on a fresh explicit '
    'user election through the offer surfaces (a fresh clean audit round is the other '
    'eligibility ground)'
)


def stale_override_remedy(state, current_digest):
    """The arm-selected recovery text for a `stale-override` refusal.

    The refusal itself is fail-closed and correct; what it lacked was a remedy, so an
    agent that hit it rediscovered the recovery by trial — costliest at `emit-body`,
    after the creation epoch is already recorded.

    **The arm is selected by the staling operand observed on the newest CURRENT-ORDINAL
    override, never by the epoch's query-time arm.** An override's digest binding is
    fixed at record time while the epoch arm is keyed at query time, so the two
    legitimately diverge — a file-write failure and embed retry landing between the
    record and the query leaves a digest-bound override on an embed-arm epoch. Keying
    on the epoch arm would name the wrong remedy on exactly that divergence.

      * arm a — a current-ordinal override whose recorded digest differs from the draft:
        the revision is NOT yet recorded, so lead with `record-revision`.
      * arm b — no current-ordinal override AND the newest override's recorded ordinal
        is LESS than the current revision ordinal: the revision is already recorded, so
        naming it again would send the caller to re-record state it already holds.
        Absence of a current-ordinal override does not select this arm on its own.
      * arm c (fail-safe) — every other skipped shape: a current-ordinal override whose
        digest binding could not be compared (it carries no digest on a file-arm epoch,
        OR no draft digest was supplied at query time), a future-ordinal record, or any
        further hand-edited / older-build shape. It makes NO claim about the revision
        state, because none was established.

    No arm names a bare `record-revision`-then-`record-override` pair: that sequence
    would re-arm a user election the user never made, which is the defect the skill's
    edit-sequencing rule exists to prevent. Arm a names `record-revision` only as a
    step that must be followed by a fresh election.
    """
    now = revision_ordinal(state)
    overrides = state.get('overrides') or []
    current = None
    for ov in reversed(overrides):
        if ov.get('recorded_at_ordinal') == now:
            current = ov
            break
    newest = overrides[-1] if overrides else None
    # Each branch selects only its CAUSE clause; the shared election clause is appended
    # once below, so "every arm ends in the election" is structural rather than a
    # convention each return site must separately remember. Arm c of the docstring is
    # implemented as separate branches with distinct causes (an unvalidatable
    # current-ordinal override; no current override at all), deliberately not renumbered
    # here.
    if (current is not None and current_digest is not None
            and current.get('draft_digest') not in (None, current_digest)):
        cause = ('the recorded override was digest-bound to draft bytes that have '
                 'since changed, so it no longer grounds eligibility; record the '
                 'revision with `record-revision`, then ')
    elif current is not None:
        # A current-ordinal override that is not digest-staled reached the refusal with
        # an uncomparable digest binding — the override carries none, or none was
        # supplied at query time. Either way the cause is unestablished, so claim
        # nothing about the revision state.
        cause = ('the recorded override could not be validated against the draft bytes, '
                 'so it no longer grounds eligibility; ')
    elif (newest is not None
            # `not isinstance(..., bool)` is load-bearing, not defensive noise: bool is a
            # subclass of int in Python, so a `true` ordinal in a hand-edited state file
            # passes a bare isinstance check and then compares as 1 — letting arm b assert
            # "the revision is already recorded" from a value that is not an ordinal at all.
            and isinstance(newest.get('recorded_at_ordinal'), int)
            and not isinstance(newest.get('recorded_at_ordinal'), bool)
            and newest['recorded_at_ordinal'] < now):
        cause = ('the revision is already recorded, which invalidated the earlier '
                 'override; ')
    else:
        cause = 'no recorded override is still current, so none grounds eligibility; '
    return cause + _STALE_OVERRIDE_ELECTION


def _emit_stale_override_remedy(prefix, elig, state, current_digest):
    """Write the arm-selected remedy to stderr beside a `stale-override` refusal.

    Called from the two REFUSAL surfaces only — `cmd_query_eligibility` and
    `cmd_emit_body` — never from the shared `evaluate_eligibility` they both call. The
    reason token's third reader, `summary_fields` (rendering `query-summary`), is a
    RENDERING surface, not a refusal: emitting from the shared evaluation would grow an
    unplanned stderr line on every summary render of a stale-override-shaped state.

    The `stale-override` test lives HERE rather than at each call site so the guard
    cannot be forgotten: a refusal surface added later calls this unconditionally and
    gets the remedy for free, instead of silently shipping without one.
    """
    if elig.get('reason') != 'stale-override':
        return
    sys.stderr.write(
        f'issue-audit-state.py {prefix}: {stale_override_remedy(state, current_digest)}\n')


def evaluate_eligibility(state, mode, current_digest=None, digest_failed=False):
    """Presentation eligibility.

    `approve` gates the presentation-for-approval of bytes with no pending re-audit
    offer, and the creation step itself. It answers `eligible` on exactly two grounds:
      (a) a completed `VERDICT: FILE` round whose identity holds for the current draft
          — on a file-arm round, its recorded dispatch digest equals the current
          canonical-file digest (an absent or unreadable file answers not-eligible —
          at the CLI with the distinct reason draft-undigestible — fail closed); on
          an embed-arm or inline-arm round, where no trustworthy canonical file exists,
          identity holds when no revision record postdates the round (the event-ordering
          ground — weaker than byte identity, and disclosed as such).
      (b) an explicitly recorded override that is still current.

    `iterate` covers only the in-loop re-presentation of a just-revised draft while its
    re-audit offer is pending. `iterate-ok` is never a ground for acting on approval and
    never a ground for creation.

    Reason precedence when several could apply is decided, not incidental:
      state-unestablished > draft-undigestible > no-verdict-round > no-digest-supplied >
      stale-override > unaudited-revision.

    `no-digest-supplied` outranks `stale-override` deliberately: an override queried
    with no draft digest was never compared, so nothing went stale — naming the
    caller's omission is the honest cause. See the refusal chain below.
    """
    if mode not in ('approve', 'iterate'):
        # The mode is a closed vocabulary like every other: an off-set value must
        # never silently take the permissive approve path.
        raise AssertionError(
            f'issue-audit-state: eligibility queried with mode {mode!r}, which is not '
            f"one of ('approve', 'iterate')")
    if mode == 'iterate':
        if state is None:
            return _no('state-unestablished')
        if revision_ordinal(state) >= 1:
            return {'answer': 'iterate-ok', 'reason': None, 'ground': None,
                    'token': None, 'ordinal': revision_ordinal(state)}
        return _no('no-revision-recorded')

    if state is None:
        return _no('state-unestablished')
    if digest_failed:
        # A supplied draft file that could not be read or hashed never grounds
        # eligibility on ANY ground (overrides included) — fail closed with the
        # distinct reason, never misattributed as unaudited-revision.
        return _no('draft-undigestible')

    clean = None
    for rnd in reversed(completed_rounds(state)):
        # The clean ground requires the NEWEST completed verdict-bearing round to be
        # FILE: a later completed REVISE round on the same bytes invalidates an older
        # clean verdict (probe-confirmed fail-open otherwise — the newest verdict wins).
        # The scan deliberately FALLS THROUGH a `no-verdict` round: an inconclusive
        # re-audit is not a revocation, so a clean verdict on unchanged bytes (digest
        # identity on the file arm; no later revision on embed/inline) still grounds
        # eligibility. This diverges from evaluate_triggers on purpose — T2 treats the
        # same trailing no-verdict round as "effectively unaudited" and fires the
        # boundary offer, so the inconclusive re-audit is surfaced to the user rather
        # than laundered, while eligibility on the previously-audited, unchanged bytes
        # is not revoked by inconclusiveness alone. Pinned in both directions in the
        # suite (no-verdict does not shadow; REVISE does).
        if rnd.get('outcome') == 'FILE':
            clean = rnd
            break
        if rnd.get('outcome') == 'REVISE':
            break

    if clean is not None:
        arm = clean['attempts'][-1]['arm']
        if arm == 'file':
            recorded = clean['attempts'][-1].get('digest')
            # issue #562 post-revision write-failure closure: byte-digest equality is no
            # longer sufficient on its own. A recorded revision that postdates the clean
            # round and whose overwrite FAILED leaves the bound file still holding the
            # clean round's byte-identical bytes — so `recorded == current_digest` holds
            # over bytes the user revised away. Require, in addition, that no revision
            # postdates the clean round (mirroring the event-ordering ground): a landed
            # revision normally changes the file's bytes, so the equality usually fails
            # there. Equality can still hold WITH a postdating revision in two ways — the
            # write-failure case (the overwrite never landed, so the file keeps the clean
            # round's bytes) and a revise-back-to-clean case (the revision's bytes happen
            # to equal the clean round's) — and this guard refuses BOTH by keying on the
            # revision's existence, not its bytes (answered `unaudited-revision` below).
            if (current_digest is not None and recorded == current_digest
                    and not _revision_postdates(state, clean)):
                return _yes(state, 'file-identity', current_digest)
        elif not _revision_postdates(state, clean):
            return _yes(state, 'event-ordering', str(revision_ordinal(state)))

    ov = _valid_override(state, current_digest)
    if ov is not None:
        # Key on whichever operand actually answered, per issue_token's contract. A
        # file-arm override is digest-bound (record-override enforces it), so the DIGEST
        # answered and the token must name it: keying on the revision ordinal alone
        # minted one identical token for byte-distinct drafts at the same ordinal —
        # exactly the replay the token exists to expose. Where no digest is bound (an
        # embed/inline epoch, which has no trustworthy canonical file), the ordinal is
        # what answered and remains the key.
        bound = ov.get('draft_digest')
        return _yes(state, 'override',
                    bound if bound is not None else str(revision_ordinal(state)))

    # Refusal precedence, decided (the docstring's tail, in the order checked below):
    # no-verdict-round > no-digest-supplied > stale-override > unaudited-revision.
    # `no-verdict-round` is scoped to the genuinely verdict-less states — nothing has
    # completed yet, or the last completed round hit the inline arm's verdict-less
    # terminal. A completed REVISE round is NOT verdict-less: a verdict exists, it is
    # merely not clean, so bytes carrying it refuse as `unaudited-revision` (the
    # motivating regression's own shape).
    last = last_completed(state)
    if last is None or last.get('outcome') == 'no-verdict':
        return _no('no-verdict-round')
    if state['overrides']:
        if current_digest is None and any(
                ov.get('draft_digest') for ov in state['overrides']
                if ov.get('recorded_at_ordinal') == revision_ordinal(state)):
            # A digest-bound override queried with NO digest was never compared:
            # nothing went stale — the caller omitted the draft file.
            return _no('no-digest-supplied')
        return _no('stale-override')
    if current_digest is None and clean is not None:
        arm = clean['attempts'][-1]['arm']
        if arm == 'file' and not _revision_postdates(state, clean):
            # A file-arm clean epoch queried with NO digest supplied was never
            # compared at all: refusing as unaudited-revision would assert a revision
            # that may not exist. Name the real cause.
            return _no('no-digest-supplied')
    return _no('unaudited-revision')


def _yes(state, ground, key):
    # The ground is printed and feeds the eligibility token's derivation, so an
    # off-vocabulary ground would mint a token no reader can attribute to a known ground.
    if ground not in _GROUNDS:
        raise AssertionError(
            f'issue-audit-state: eligibility answered on ground {ground!r}, which is not '
            f'in _GROUNDS')
    return {'answer': 'eligible', 'reason': None, 'ground': ground,
            'token': issue_token(state['nonce'], ground, key), 'key': key}


# The eligibility result is an UNTAGGED union of three shapes, discriminated by `answer`:
#   eligible    -> ground + token + key      (from _yes)
#   iterate-ok  -> ordinal                   (from the iterate branch above)
#   not-eligible-> reason                    (from _no)
# The variant-only keys (`key`, `ordinal`) are therefore absent on the other variants, and
# reading one off the wrong variant is a KeyError rather than a type error. Recorded as an
# accepted trade-off (raised on PR #552), NOT a live defect: every read of a variant-only key
# sits inside an arm that already discriminated on `answer` — see cmd_query_eligibility, whose
# `ordinal`/`key` reads are each guarded by their own answer check — and the suite drives all
# three variants. The discrimination is enforced by convention, not by the type; a dataclass
# or tagged union would make the illegal read unrepresentable. Revisit if a consumer reads a
# variant-only key OUTSIDE an answer-discriminated arm, or if a fourth variant is added (three
# is where hand-discrimination is still auditable at a glance).
def _no(reason):
    # Every refusal carries a machine-readable reason from the canonical set: the skill
    # routes on these tokens, so an unlisted one is a refusal it cannot act on.
    if reason not in _ELIGIBILITY_REASONS:
        raise AssertionError(
            f'issue-audit-state: eligibility refused with reason {reason!r}, which is not '
            f'in _ELIGIBILITY_REASONS')
    return {'answer': 'not-eligible', 'reason': reason, 'ground': None, 'token': None}


def next_action(state, round_no):
    """The retry/next-action answer for an open or just-closed round."""
    if state is None:
        return 'round-closed-no-verdict'
    rnd = _find_round(state, round_no)
    if rnd is None:
        return 'round-closed-no-verdict'
    outcome = rnd.get('outcome')
    if outcome == 'FILE':
        return 'proceed'
    if outcome == 'REVISE':
        if state.get('automatic_reaudits_used', 0) < _MAX_AUTOMATIC_REAUDITS:
            return 'revise-and-reaudit'
        # The automatic budget is spent: revise, then evaluate the user-chosen-round
        # offer. The audit informs, it never deadlocks filing.
        return 'revise-then-evaluate-offer'
    if outcome == 'no-verdict':
        return 'round-closed-no-verdict'
    # `pending` is written by `record-return` from the round's own retry accounting; this
    # query only reads it, so the retry arm cannot be re-derived (and re-decided) differently
    # here than it was recorded. One field, one read — no order-dependent if-chain.
    # An open round with NO pending action is a dispatch whose return was never
    # recorded: answer the fail-closed awaiting token, never `proceed` (an orchestrator
    # in a confused mid-round state must not be told to walk past an audit it never
    # received).
    return _checked_action(rnd.get('pending') or 'round-open-awaiting-return')


def _checked_action(token):
    """Fail closed on an answer outside the canonical set.

    The skill is contractually required to obey this answer verbatim against a closed
    vocabulary it enumerates. An answer outside `_NEXT_ACTIONS` is therefore a token the
    skill has no route for — it would read as an unrecognized string mid-lifecycle. Making
    the set constrain the return keeps `_NEXT_ACTIONS` load-bearing rather than decorative.
    """
    if token not in _NEXT_ACTIONS:
        raise AssertionError(
            f'issue-audit-state: next_action produced {token!r}, which is not in '
            f'_NEXT_ACTIONS — the skill obeys this answer against a closed set')
    return token


def _find_round(state, round_no):
    for r in state['rounds']:
        if r['round'] == round_no:
            return r
    return None


def route_arm(write_landed, hash_ok, prior_unreadable):
    """Decide a dispatch's arm.

    Returns (arm, marker_token|None). The three embed markers are the ported entry
    conditions, preserved verbatim in `_EMBED_MARKER_TEXT`.

    The three inputs are not equals: `hash_ok` the tool observes itself, `prior_unreadable`
    it recorded at the previous return (`cmd_query_arm` reads it back rather than trusting
    the caller), and `write_landed` is the one genuinely orchestrator-reported fact — the
    tool does not own the draft write, so it cannot observe whether it landed.
    """
    if prior_unreadable:
        return 'embed', 'file-unreadable'
    if not write_landed:
        return 'embed', 'write-failed'
    if not hash_ok:
        # Delta 1: the digest-unrecorded entry now fires when the tool failed to
        # establish the file-arm comparand (its own hash of the draft file failed).
        return 'embed', 'digest-unrecorded'
    return 'file', None


# The audit-summary field set, named once. `summary_fields` answers on two independent
# branches (state-unestablished and ok), and the query surface renders the returned mapping
# key-by-key — so a field added to one branch and forgotten on the other is a KeyError at
# that surface, i.e. a query that cannot answer. Queries are contractually always-exit-0, so
# that is a two-class-contract violation, not a cosmetic slip. `_summary` is the ONE
# constructor both branches go through: it fails loudly, at the call, on a missing or unknown
# field, so the two branches cannot drift apart silently.
_SUMMARY_FIELDS = (
    'state', 'findings_count', 'revisions_applied', 'verdict', 'rounds_run',
    'consumer_dimensions_appended', 'degraded', 'user_declined', 'cap_reached',
    'markers', 'token', 'stale_token', 'reinit_forced', 'attestation',
    # Post-adjudication actionability of the LATEST completed round (issue #548): the
    # adjudicated verdict, the per-class counts, and the unresolved-must-revise count.
    'adjudicated_verdict', 'must_revise', 'advisory', 'invalid',
    'unresolved_must_revise',
    # issue #562: the bound draft root + its tier token, so the display renders the
    # `draft bound to worktree root` marker from the tool-emitted token rather than
    # from the orchestrator's recall.
    'bound_root', 'bound_tier',
    # issue #603: the run-wide EFFECTIVE unresolved count (what T1 and convergence now
    # consult) alongside the at-close count above, and the convergence basis token. Both
    # render as space-free tokens BEFORE `bound_root`, so `attestation` stays the
    # contractually-trailing field the #546 CLI pins anchor on.
    'effective_unresolved', 'convergence_basis',
    # issue #708: the run's coverage-backing and the coverage round's render state, so the
    # mandatory audit summary line carries the coverage evidence on EVERY arm and outcome —
    # a backed clean run, an unbacked clean run, and every degraded arm alike. Both render
    # as space-free tokens BEFORE `bound_root`, keeping `attestation` the trailing field.
    'coverage_backing', 'coverage_render',
)


def _summary(**fields):
    missing = [k for k in _SUMMARY_FIELDS if k not in fields]
    unknown = [k for k in fields if k not in _SUMMARY_FIELDS]
    _require(not missing and not unknown,
             f'issue-audit-state: the audit-summary field set is fixed by _SUMMARY_FIELDS; '
             f'this branch omits {missing!r} and adds {unknown!r}. Every summary_fields '
             f'branch must answer with exactly the same fields, or the query surface that '
             f'renders them raises KeyError on the branch that forgot one.')
    return {k: fields[k] for k in _SUMMARY_FIELDS}


def summary_fields(state, current_digest=None, digest_failed=False):
    """The audit-summary-line field set, derived from recorded state.

    The eligibility token is DERIVED here rather than read back from state: queries
    are read-only, so nothing recorded it at issue time. A token is re-emitted only
    while its issuing ground still holds; once a later revision invalidates it — a
    FILE round's digest, an event-ordering ordinal, or a recorded override — the
    distinct stale-token marker is emitted, so a reader string-comparing the
    transcript's token against the state file sees a replayed pre-revision token fail
    to match.
    """
    if state is None:
        return _summary(state='unestablished', findings_count=None, revisions_applied=0,
                        verdict=None, rounds_run=0, consumer_dimensions_appended=False,
                        degraded=False, user_declined=False, cap_reached=False,
                        markers=[], token=None, stale_token=False, reinit_forced=False,
                        attestation=None, adjudicated_verdict=None, must_revise=None,
                        advisory=None, invalid=None, unresolved_must_revise=None,
                        bound_root=None, bound_tier=None,
                        effective_unresolved=None, convergence_basis='none',
                        coverage_backing='unestablished', coverage_render='none')
    done = completed_rounds(state)
    # Cumulative across every round this run: "how many things did the auditors
    # collectively flag", not merely the last round's tally.
    counts = [r['findings_count'] for r in done if r.get('findings_count') is not None]
    markers = []
    for r in state['rounds']:
        for mk in r.get('embed_markers', []):
            if mk not in markers:
                markers.append(mk)
    last = last_completed(state)
    # ONE convergence evaluation feeds both summary fields (issue #603): derived from two
    # independent call sites they could render two fields describing different states.
    _convergence = evaluate_convergence(state)
    # issue #708: one coverage evaluation feeds both coverage summary fields, for the same
    # single-source reason.
    _coverage = evaluate_coverage(state)
    elig = evaluate_eligibility(state, 'approve', current_digest,
                                digest_failed=digest_failed)
    token = elig['token']
    stale = False
    if token is None and not digest_failed:
        # An undigestible draft is NOT evidence the token went stale — the stderr
        # breadcrumb names the real cause; rendering stale-token here would be the
        # same misattribution the draft-undigestible reason exists to prevent.
        # A token that was issued and is now invalidated should render stale-token, so
        # a reader string-comparing a replayed token still sees a positive mismatch.
        # TWO grounds can issue a token, so both must be able to stale it:
        #   - a clean FILE round (its token staled by a later revision), covered by the
        #     `any(outcome == 'FILE')` scan below; and
        #   - a recorded override invalidated by a later revision, which can exist on a
        #     REVISE or no-verdict epoch with NO FILE round in `done` at all, so the
        #     FILE scan alone missed it and rendered `token=none` — the override-ground
        #     fail-open this OR closes. Derived from STATE (an override recorded at a
        #     non-current ordinal), not from the eligibility reason alone: refusal
        #     precedence answers `no-verdict-round` before `stale-override` whenever
        #     the last completed round is verdict-less, so on a no-verdict epoch the
        #     reason never reads `stale-override` and a reason-only derivation rendered
        #     `token=none` there. The reason stays OR-ed in for the current-ordinal
        #     digest-mismatch case (a byte-distinct draft at the same ordinal), which
        #     the ordinal predicate cannot see.
        override_staled = (
            elig.get('reason') == 'stale-override'
            or any(ov.get('recorded_at_ordinal') != revision_ordinal(state)
                   for ov in state['overrides']))
        stale = any(r.get('outcome') == 'FILE' for r in done)
        if stale and not override_staled and current_digest is None:
            # One carve-out, scoped to the FILE-round ground only (never the override
            # ground, which the OR below restores): a file-arm clean epoch queried with
            # NO digest supplied was never compared at all — claiming stale there would
            # be the same misattribution in another coat.
            latest_clean = next((r for r in reversed(done)
                                 if r.get('outcome') == 'FILE'), None)
            if (latest_clean is not None
                    and latest_clean['attempts'][-1]['arm'] == 'file'
                    and not _revision_postdates(state, latest_clean)):
                # ...unless a recorded revision positively postdates the clean round —
                # that invalidation needs no digest comparison, so the stale marker
                # stays honest even when no draft file was supplied.
                stale = False
        stale = stale or override_staled
    return _summary(
        state='ok',
        findings_count=sum(counts) if counts else None,
        revisions_applied=revision_ordinal(state),
        verdict=last.get('outcome') if last else None,
        rounds_run=len(state['rounds']),
        consumer_dimensions_appended=any(
            r.get('consumer_dimensions_appended') for r in state['rounds']),
        degraded=any(r.get('degraded') for r in state['rounds']),
        user_declined=any(o['kind'] == 'user-decline' for o in state['overrides']),
        cap_reached=any(o['kind'] == 'cap-reached' for o in state['overrides']),
        markers=[_EMBED_MARKER_TEXT[m] for m in markers],
        token=token,
        stale_token=stale,
        reinit_forced=bool(state.get('reinit_forced')),
        # The creation-attestation status is part of the audit-summary field set (a
        # mismatch is surfaced here, not only in record-creation-attestation's own
        # output): 'match' | 'mismatch' | 'attestation-unavailable' | 'none'.
        attestation=(state.get('creation') or {}).get('attestation') or 'none',
        # Post-adjudication actionability of the LATEST completed round (issue #548). Read
        # from that round only — the observables the reader checks against the artifact are
        # the final round's, not a cumulative sum. `None` on every field until adjudicated.
        adjudicated_verdict=(last.get('adjudicated_verdict') if last else None),
        must_revise=(last.get('must_revise_count') if last else None),
        advisory=(last.get('advisory_count') if last else None),
        invalid=(last.get('invalid_count') if last else None),
        unresolved_must_revise=(last.get('unresolved_must_revise') if last else None),
        # issue #562: the bound root + tier token (None on an unbound run — an
        # embed/inline epoch that never bound a canonical file).
        bound_root=(_binding(state) or {}).get('path'),
        bound_tier=(_binding(state) or {}).get('tier'),
        # issue #603: the effective count is run-wide (it aggregates every ledger), not
        # the latest round's frozen tally above — the Step 4 summary line renders both so
        # a reader can see the at-close count AND what post-close settling left.
        effective_unresolved=_convergence['effective'],
        convergence_basis=_convergence['basis'],
        # issue #708: the run's coverage-backing and the coverage round's render state,
        # derived from the final accepted clean round. A distinct axis from convergence —
        # this derivation never feeds `effective_unresolved` or the convergence basis.
        coverage_backing=_coverage['backing'],
        coverage_render=_coverage['render'],
    )


# ── Command implementations ────────────────────────────────────────────────────

def _new_doc(slug, nonce):
    return {'schema_version': SCHEMA_VERSION, 'slug': slug, 'nonce': nonce,
            'reinit_forced': False, 'automatic_reaudits_used': 0, 'user_rounds_used': 0,
            'rounds': [], 'revisions': [], 'overrides': [], 'creation': None,
            # issue #562: the tiered draft-root binding (recorded once) and the
            # per-run canonical-write-failure log at the bound path.
            'draft_binding': None, 'write_failures': []}


def cmd_init(args):
    load_error = None
    try:
        existing = load_state(args.slug)
    except StateError as exc:
        existing = None
        load_error = str(exc)
    if args.nonce:
        if existing is None:
            # Carry the load failure's own detail: "no readable state file" alone would
            # mask a present-but-corrupt file behind a message recommending the
            # budget-resetting cold start.
            detail = f' (the load failed: {load_error})' if load_error else ''
            _fail('init', 'a nonce was supplied but no readable state file exists for '
                          f'slug {args.slug!r}{detail}; omit --nonce for a cold start')
        if existing['nonce'] != args.nonce:
            _fail('init', 'nonce mismatch — this call does not belong to the run that '
                          'owns this state file; refusing to re-init a foreign run')
        if existing['rounds'] and not args.force:
            _fail('init', 'a same-run re-init over recorded rounds is an illegal '
                          'transition without --force (it would hand this run a fresh '
                          'automatic budget silently)')
        # The attestation is forward-only tamper evidence: record-creation-epoch and
        # record-creation-attestation both refuse to overwrite a recorded match/mismatch,
        # through this same shared accessor. Re-init discards the whole document, so
        # without this third guard --force walked past both of them and query-summary then
        # rendered `attestation=none` — which the skill defines as "before any creation
        # attempt", indistinguishable from never-attempted. Unknown is not zero, and a
        # wiped mismatch must never read as an absent one.
        if _attestation_frozen(existing):
            _fail('init', 'a creation attestation is already recorded for this run; '
                          're-initialising would discard that forward-only tamper '
                          'evidence and render the summary as though no creation had '
                          'been attempted')
        doc = _new_doc(args.slug, args.nonce)
        # Sticky once set: a forced re-init wipes rounds, so a LATER same-nonce re-init
        # takes the no-rounds echo path (rounds now empty, so the --force guard above no
        # longer fires) and would otherwise recompute this as False — laundering the
        # budget-reset disclosure in two legal calls. Preserve a prior `reinit_forced`
        # so `query-summary` cannot lose the evidence that this run took a fresh budget.
        doc['reinit_forced'] = (bool(existing.get('reinit_forced'))
                                or bool(existing['rounds'] and args.force))
    else:
        # Cold start: the ported delete-leftover-first rule. Raises no alarm.
        doc = _new_doc(args.slug, secrets.token_hex(8))
        try:
            path = state_path(args.slug)
        except StateError as exc:
            # An unsafe slug must fail with the named breadcrumb BEFORE the delete-first
            # unlink can act on an escaped path.
            _fail('init', str(exc))
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        except OSError as exc:
            _fail('init', f'could not delete leftover state at {path}: {exc}')
    try:
        save_state(doc, args.slug)
    except StateError as exc:
        _fail('init', str(exc))
    print(f'nonce={doc["nonce"]}')


def _load_for_mutation(prefix, slug, nonce):
    try:
        doc = load_state(slug)
        _check_nonce(doc, nonce)
    except StateError as exc:
        _fail(prefix, str(exc))
    return doc


def _attestation_frozen(doc):
    """True once the creation attestation is forward-only tamper evidence.

    The exemption set is the whole rule: `None` (nothing attested yet) and
    `attestation-unavailable` (the honest unknown — a failed fetch, which is NOT
    evidence about the body and so may be re-attested). Any other recorded value is a
    real comparison result (`match`/`mismatch`) and is frozen: overwriting it would
    discard the tamper evidence.

    One accessor, three callers — `init`'s re-init guard, `record-creation-epoch`'s
    rebind guard, and `record-creation-attestation`'s re-attest guard. They were three
    copy-pasted predicates that had to agree by hand: this repo's dominant defect class
    is exactly that shape (a coupled invariant whose mirror sites silently drift), and a
    single site that admits one extra value re-opens the wipe the other two refuse.
    """
    return (doc.get('creation') or {}).get('attestation') not in (
        None, 'attestation-unavailable')


def _permitted_retry_arms(rnd):
    """The arms a pending retry action permits, as a tuple.

    The pending action names the arm the retry was routed to; a mismatched arm would
    silently switch the carriage comparand class mid-round, so the set is closed.

    `dispatch-retry-same-arm` on a FILE-arm round additionally permits the embed arm.
    The canonical file can become unhashable between the return and the retry — the
    concurrent-overwrite/delete race this design contemplates and that `route_arm`
    exists to answer — and `query-arm` then routes the retry to embed. Without this
    escalation the run DEADLOCKS with no legal next call: the embed dispatch the tool
    itself just prescribed is refused as an illegal transition, the file dispatch
    cannot read the file, `query-next-action` re-answers the same spent token forever,
    and the skill is forbidden from improvising around an illegal transition or routing
    it to the unavailable fallback. The escalation is never silent — the embed arm
    requires `--marker` (enforced at the call site), so the entry cause is recorded in
    `embed_markers` and rendered in the audit summary, which is exactly how the sibling
    `dispatch-embed-retry` escalation already reports itself. It is deliberately NOT
    extended to an inline-arm round: inline is the terminal degraded arm, so there is
    nothing to escalate to.

    Disclosed residual: the escalation is permitted, not verified. The tool does not
    re-hash the file at dispatch to confirm it really is unhashable — doing so would
    re-race the very condition the escalation answers — so an orchestrator may take the
    embed arm on any file-arm same-arm retry and thereby self-downgrade from byte-bound
    file-identity to the weaker embed comparand. The entry marker is therefore
    orchestrator-asserted, not tool-observed. This is the same trust boundary
    `route_arm` already documents for `write_landed`, and it is bounded by the same
    disclosure: the downgrade is recorded and rendered, never silent.
    """
    same = rnd['attempts'][-1]['arm']
    permitted = {'dispatch-embed-retry': ('embed',),
                 'dispatch-inline-degraded': ('inline',),
                 'dispatch-retry-same-arm': (same,)}[rnd['pending']]
    if rnd['pending'] == 'dispatch-retry-same-arm' and same == 'file':
        permitted = permitted + ('embed',)
    return permitted


def cmd_record_dispatch(args):
    doc = _load_for_mutation('record-dispatch', args.slug, args.nonce)
    if args.arm == 'file':
        if not args.draft_file:
            _fail('record-dispatch', '--draft-file is required on the file arm')
        # Tiered-draft-root binding cross-check (issue #569): when the run has bound a
        # canonical-draft root (the first landed write records it via record-draft-binding)
        # and the skill reports where its write landed via --write-path, the reported path
        # MUST match the file the tool derives from the recorded binding
        # (`<bound-root>/.devflow/tmp/issue-draft-<slug>.md`, via _bound_draft_file). A
        # divergence is a strong signal that a compacted context drifted which file the
        # dispatch audits, so fail closed with the write-path-mismatch breadcrumb.
        #
        # SCOPE (do not overstate this guard): it validates the REPORTED path only. The bytes
        # digested below still come from the caller's --draft-file, which this command does
        # NOT resolve from the binding — unlike its siblings emit-body / query-eligibility /
        # query-summary, which all read through _bound_draft_file. So a caller that reports a
        # correct --write-path while passing a drifted --draft-file is still recorded. Closing
        # that is the bound-first reader reconciliation deferred with the strict half below.
        # The check is scoped to a bound run with
        # a reported write path — an unbound run (an embed/inline epoch that never bound a
        # canonical file) and a caller that omits --write-path both proceed unchanged, so
        # the cross-check is additive, never a new mandatory field on the file arm.
        #
        # An OMITTED --write-path is an opt-out; a PRESENT-BUT-EMPTY one is not. A caller that
        # composes this value from a shell-resolved root yields an empty string when that root
        # is unresolved — an *unestablished* report, which a truthiness test would silently
        # collapse onto "caller opted out" and disarm the check on exactly the drift it exists
        # to catch (the repo's unknown-is-not-zero rule). Refuse it by name instead. (This is
        # defense in depth, not a description of the shipped skill: create-issue substitutes an
        # already-resolved literal path here, so it is a hazard for other callers and runners.)
        #
        # NOTE (issue #569 scope split): making the binding itself REQUIRED on every file-arm
        # dispatch (fail-closed `binding-required-on-file-arm` when absent) is the strict half
        # deferred to a follow-up — it ripples into every pre-binding file-arm unit test's
        # bound-first reader setup and must land with that reconciliation, not this pass.
        if args.write_path is not None and not args.write_path.strip():
            _fail('record-dispatch',
                  'an empty --write-path is an unestablished report, not an opt-out '
                  '(write-path-empty): omit the flag entirely to skip the cross-check, or '
                  'report the absolute canonical-draft path the write landed at')
        if doc.get('draft_binding') is not None and args.write_path:
            expected_write_path = _bound_draft_file(doc, args.slug)
            if args.write_path != expected_write_path:
                _fail('record-dispatch',
                      f'the reported write path {args.write_path!r} does not match the bound '
                      f'canonical-draft file {expected_write_path!r} (write-path-mismatch): '
                      'the file arm must write and audit the draft at the bound root')
        try:
            data = Path(args.draft_file).read_bytes()
        except OSError as exc:
            _fail('record-dispatch', f'could not read draft file {args.draft_file}: {exc}')
    else:
        # The sibling draft-file read above routes its failure through _fail; stdin is the
        # same external input and gets the same treatment, or a broken fd 0 escapes as a
        # raw traceback — breaking the mutation contract (non-zero WITH a named
        # breadcrumb) the caller parses, and handing its stderr classification a Python
        # traceback rather than one of this tool's own vocabulary strings.
        #
        # TWO distinct failures, deliberately handled separately. A CLOSED fd 0 does not
        # raise from the read at all: CPython sets `sys.stdin = None` at startup, so the
        # attribute access itself is what fails (AttributeError, never OSError) — an
        # `except OSError` around the read is blind to exactly the shape the skill's shell
        # pipelines can produce. Test the object first; keep the except for a genuine
        # read-time error (an I/O failure part-way through a redirected file).
        if sys.stdin is None:
            _fail('record-dispatch', 'could not read draft bytes from stdin: no stdin is '
                                     'attached (fd 0 is closed)')
        try:
            data = sys.stdin.buffer.read()
        except OSError as exc:
            _fail('record-dispatch', f'could not read draft bytes from stdin: {exc}')
        if not data:
            _fail('record-dispatch', f'the {args.arm} arm requires the draft bytes on '
                                     'stdin; received none')
    try:
        digest = hash_bytes(data)
        body_digest = hash_bytes(split_body(data))
    except _DigestError as exc:
        _fail('record-dispatch', str(exc))
    attempt = {'arm': args.arm, 'digest': digest, 'body_digest': body_digest,
               'sentinel_open': None, 'sentinel_close': None}
    if args.arm == 'embed':
        # Delta 3: the sentinels are generated by the tool at dispatch, not chosen ad
        # hoc by the orchestrator, so the carriage compare is against a recorded value.
        tag = secrets.token_hex(3).upper()
        attempt['sentinel_open'] = f'AUDIT-{tag}-OPEN'
        attempt['sentinel_close'] = f'AUDIT-{tag}-CLOSE'
    rnd = _find_round(doc, args.round)
    if rnd is None:
        expected = (doc['rounds'][-1]['round'] + 1) if doc['rounds'] else args.round
        if doc['rounds'] and args.round != expected:
            _fail('record-dispatch', f'round {args.round} is out of order (the last '
                                     f'recorded round is {doc["rounds"][-1]["round"]}; '
                                     f'the next round is {expected})')
        # A new round cannot open while an earlier one is still open: two concurrently
        # open rounds would let a later verdict close the wrong round's accounting, and
        # every budget/retry counter is per-round.
        if doc['rounds'] and doc['rounds'][-1].get('outcome') is None:
            _fail('record-dispatch',
                  f'round {doc["rounds"][-1]["round"]} is still open; record its return '
                  f'before dispatching round {args.round}')
        # Spend the automatic re-audit budget HERE, where the round actually opens.
        # A new round whose predecessor closed REVISE is the automatic re-audit while the
        # budget is unspent; once it is spent, a further round can only be a user-chosen
        # one (whose ceiling `record-offer` enforces). Deriving this from recorded facts
        # keeps the orchestrator from having to declare which budget a round draws on.
        prev = doc['rounds'][-1] if doc['rounds'] else None
        if (prev is not None and prev.get('outcome') == 'REVISE'
                and doc.get('automatic_reaudits_used', 0) < _MAX_AUTOMATIC_REAUDITS):
            doc['automatic_reaudits_used'] = doc.get('automatic_reaudits_used', 0) + 1
        # Round funding: every round past the initial one is funded by the automatic
        # budget spent above or an accepted user-chosen offer (record-offer). Opening
        # an unfunded round would hand the run re-audits the cap never sees.
        if len(doc['rounds']) >= (1 + doc.get('automatic_reaudits_used', 0)
                                  + doc.get('user_rounds_used', 0)):
            _fail('record-dispatch',
                  f'round {args.round} is not funded: the automatic budget is spent '
                  f'and no accepted user-chosen round funds it (record-offer '
                  f'--accepted first)')
        rnd = {'round': args.round, 'attempts': [], 'no_parseable_retry_used': False,
               'unreadable_retry_used': False, 'outcome': None, 'findings_count': None,
               'consumer_dimensions_appended': False, 'embed_markers': [],
               'degraded': False,
               # Post-adjudication payload (issue #548), filled by record-adjudication after
               # the round is accepted. `None` = not yet adjudicated (distinct from an
               # adjudicated-but-unestablished count, which is the literal _UNESTABLISHED).
               'adjudicated_verdict': None, 'must_revise_count': None,
               'advisory_count': None, 'invalid_count': None,
               'unresolved_must_revise': None}
        doc['rounds'].append(rnd)
    elif rnd.get('outcome') is not None:
        _fail('record-dispatch', f'round {args.round} is already closed with outcome '
                                 f'{rnd["outcome"]!r}; a dispatch cannot reopen it')
    elif rnd.get('pending') not in ('dispatch-embed-retry', 'dispatch-retry-same-arm',
                                    'dispatch-inline-degraded'):
        # An open round accepts a further dispatch only when a retry is actually
        # pending: an unrequested re-dispatch would append a second attempt whose
        # digest/sentinels silently become the carriage comparand.
        _fail('record-dispatch', f'round {args.round} is open awaiting its return; a '
                                 f're-dispatch was not requested')
    elif args.arm not in _permitted_retry_arms(rnd):
        # The pending action names the arm the retry was routed to; a mismatched arm
        # would silently switch the carriage comparand class mid-round.
        _fail('record-dispatch', f'the pending action {rnd["pending"]} does not permit '
                                 f'a dispatch on the {args.arm} arm')
    # This dispatch consumes any pending retry action: between this dispatch and its
    # record-return, next-action must answer round-open-awaiting-return, never re-issue
    # the already-spent retry (a duplicate dispatch would append a second attempt whose
    # digest/sentinels become the carriage comparand).
    if args.arm == 'embed' and not args.marker:
        # Every embed-arm entry carries its cause marker into the evidence surface; an
        # unmarked embed attempt would lose the entry diagnosis forever.
        _fail('record-dispatch', 'the embed arm requires --marker naming the entry cause')
    rnd['pending'] = None
    rnd['attempts'].append(attempt)
    if args.marker:
        if args.marker not in _EMBED_MARKER_TOKENS:
            _fail('record-dispatch', f'unknown embed marker {args.marker!r}')
        if args.marker not in rnd['embed_markers']:
            rnd['embed_markers'].append(args.marker)
    try:
        save_state(doc, args.slug)
    except StateError as exc:
        _fail('record-dispatch', str(exc))
    out = f'round={args.round} arm={args.arm} digest={digest} body_digest={body_digest}'
    if attempt['sentinel_open']:
        out += (f' sentinel_open={attempt["sentinel_open"]}'
                f' sentinel_close={attempt["sentinel_close"]}')
    print(out)


def cmd_record_return(args):
    doc = _load_for_mutation('record-return', args.slug, args.nonce)
    rnd = _find_round(doc, args.round)
    if rnd is None:
        _fail('record-return', f'no dispatch recorded for round {args.round}; a verdict '
                               'cannot precede its dispatch')
    if rnd.get('outcome') is not None:
        _fail('record-return', f'round {args.round} already returned outcome '
                               f'{rnd["outcome"]!r}; a duplicate return is illegal')
    attempt = rnd['attempts'][-1]
    arm = attempt['arm']
    carriage_ok = _carriage_ok(attempt, args)
    verdict = args.verdict
    cls = classify_return(arm, verdict, args.verdict is not None, carriage_ok)

    # `pending` is ONE field holding at most one next action, not a set of mutually-exclusive
    # booleans. Three separate flags let the persisted state hold a genuine contradiction
    # (two pending arms true at once), with correctness resting silently on the read-order of
    # the consumer's if-chain; a single assignment site cannot express that state at all.
    rnd['pending'] = None
    if cls == 'accept-file':
        rnd['outcome'] = 'FILE'
    elif cls == 'accept-revise':
        rnd['outcome'] = 'REVISE'
    elif cls == 'retry-embed':
        if rnd.get('unreadable_retry_used'):
            # Exactly one DRAFT-UNREADABLE re-dispatch per round.
            cls = 'no-parseable-verdict'
        else:
            rnd['unreadable_retry_used'] = True
            rnd['pending'] = 'dispatch-embed-retry'
    if cls == 'no-parseable-verdict':
        # Read the retry flag BEFORE setting it: exactly one no-parseable-verdict retry
        # per round, and only a SECOND such completion routes to the inline degraded arm.
        # Setting and reading it in one branch would make the first completion look like
        # the second and skip the same-arm retry entirely.
        if rnd.get('no_parseable_retry_used'):
            if arm == 'inline':
                # The arm past both defined retries: the round closes verdict-less.
                rnd['outcome'] = 'no-verdict'
                rnd['pending'] = None
            else:
                rnd['pending'] = 'dispatch-inline-degraded'
        else:
            rnd['no_parseable_retry_used'] = True
            rnd['pending'] = 'dispatch-retry-same-arm'
    # Evidence from a REFUSED completion (failed carriage / no parseable verdict) is
    # never recorded: an unproven findings tally must not leak into the summary via a
    # later clean retry that omits its own count.
    if cls in ('accept-file', 'accept-revise'):
        if args.findings_count is not None:
            if args.findings_count < 0:
                _fail('record-return', f'--findings-count {args.findings_count} is '
                                       'negative; a findings tally cannot be')
            rnd['findings_count'] = args.findings_count
        if args.consumer_dimensions_appended:
            rnd['consumer_dimensions_appended'] = True
    try:
        save_state(doc, args.slug)
    except StateError as exc:
        _fail('record-return', str(exc))
    print(f'classification={cls} outcome={rnd["outcome"] or "pending"}')


def cmd_record_adjudication(args):
    """Record the post-adjudication actionability payload for a completed round (issue #548).

    Round acceptance and carriage validation remain record-return's completion boundary;
    this call records the orchestrator's reconciled judgment (the per-class counts and the
    unresolved-must-revise count) AFTER that boundary, before any T1/convergence/summary
    query. The raw auditor verdict stays recorded as provenance; a raw token never
    substitutes for adjudication, so the state owner accepts this payload only when the
    adjudicated verdict and the unresolved-must-revise count agree — checked when that count
    is established. A `FILE` verdict asserts convergence-worthiness, so it may NOT pair with
    an `unestablished` count (that is precisely a not-established state); a `REVISE` count may
    be `unestablished` (a verified finding may exist though the tally was not established), and
    that is the only verdict the `unestablished` count pairs with.
    """
    doc = _load_for_mutation('record-adjudication', args.slug, args.nonce)
    rnd = _find_round(doc, args.round)
    if rnd is None:
        _fail('record-adjudication', f'no round {args.round} recorded; an adjudication '
                                     'cannot precede its dispatch and return')
    # Write-once (issue #603 AC9), the treatment record-return, record-draft-binding,
    # record-creation-epoch and record-creation-attestation already have. Before this
    # guard a second call silently overwrote the round's payload, so a mis-keyed
    # adjudication could be papered over with no record that it happened — and the
    # post-close channels below could be bypassed entirely.
    # A FILE adjudication supersedes prior findings run-wide, so recording one BEHIND a
    # later completed round would retire findings raised AFTER it — and because the latest
    # round would still be REVISE, `_convergence_basis` would report the resulting clean
    # answer as `resolution`, attributing it to post-close settling that never happened.
    _latest = last_completed(doc)
    if (args.verdict == 'FILE' and _latest is not None
            and args.round < _latest['round']):
        _fail('record-adjudication',
              f'round {args.round} precedes the latest completed round '
              f'{_latest["round"]} (adjudication-out-of-order); a FILE adjudication '
              f'supersedes prior findings and cannot be recorded behind a later round')
    if rnd.get('adjudicated_verdict') is not None:
        _fail('record-adjudication',
              f'round {args.round} is already adjudicated '
              f'(adjudication-already-recorded); a round\'s adjudication is written '
              f'once — the post-close channels for its effective count are '
              f'record-resolution, record-reopen and record-invalidate')
    if rnd.get('outcome') not in ('FILE', 'REVISE'):
        # Only an accepted FILE/REVISE round carries findings to adjudicate — a no-verdict
        # or still-open round has none.
        _fail('record-adjudication', f'round {args.round} is not an accepted, completed '
                                     f'round (outcome {rnd.get("outcome")!r}); only a '
                                     f'FILE/REVISE round carries findings to adjudicate')
    for name, val in (('--must-revise', args.must_revise),
                      ('--advisory', args.advisory), ('--invalid', args.invalid)):
        if val < 0:
            _fail('record-adjudication', f'{name} {val} is negative; an actionability '
                                         'count cannot be')
    raw = args.unresolved_must_revise
    if raw == _UNESTABLISHED:
        unresolved = _UNESTABLISHED
        # A FILE verdict asserts convergence-worthiness, which an unknown unresolved count
        # cannot support: FILE means "zero unresolved must-revise findings", and an
        # unestablished count is precisely a not-established state, not a zero. Reject the
        # pairing so a self-inconsistent `FILE + unestablished` record can never reach the
        # summary/consumers. REVISE + unestablished is the only legal unestablished pairing.
        if args.verdict == 'FILE':
            _fail('record-adjudication', 'adjudicated verdict FILE cannot pair with an '
                                         f'{_UNESTABLISHED!r} unresolved must-revise count: '
                                         'a FILE verdict requires zero unresolved findings, '
                                         'and an unestablished count is not a zero')
    else:
        try:
            unresolved = int(raw)
        except ValueError:
            _fail('record-adjudication', f'--unresolved-must-revise {raw!r} is neither a '
                                         f'non-negative integer nor the literal '
                                         f'{_UNESTABLISHED!r}')
        if unresolved < 0:
            _fail('record-adjudication', f'--unresolved-must-revise {unresolved} is '
                                         f'negative; unknown is the literal '
                                         f'{_UNESTABLISHED!r}, never a negative count')
    # Agreement — only decidable when the count is a settled integer. An unestablished count
    # names an unknown, so it agrees with neither verdict and is not rejected here (the
    # convergence/T1 queries treat it as not-established, never as zero).
    if isinstance(unresolved, int):
        if args.verdict == 'FILE' and unresolved != 0:
            _fail('record-adjudication', f'adjudicated verdict FILE disagrees with '
                                         f'unresolved must-revise count {unresolved}: a '
                                         f'FILE verdict requires zero unresolved must-revise '
                                         f'findings')
        if args.verdict == 'REVISE' and unresolved < 1:
            _fail('record-adjudication', f'adjudicated verdict REVISE disagrees with '
                                         f'unresolved must-revise count {unresolved}: a '
                                         f'REVISE verdict requires at least one verified '
                                         f'unresolved must-revise finding')
        # Unresolved must-revise findings are a subset of the round's must-revise findings, so
        # the unresolved count can never exceed the total. A record that violates this is
        # self-inconsistent; reject it rather than let a nonsensical tally reach the summary.
        if unresolved > args.must_revise:
            _fail('record-adjudication', f'unresolved must-revise count {unresolved} exceeds '
                                         f'the must-revise total {args.must_revise}: unresolved '
                                         f'findings are a subset of must-revise findings')
    # ── The per-finding ledger (issue #603 AC1/AC20) ──────────────────────────────
    # A REVISE adjudication with a SETTLED count records one ledger entry per must-revise
    # finding. The flag gate mirrors record-revision's `--stdin-digest`: the tool never
    # performs a BARE stdin read, so a legacy caller that pipes nothing can never block.
    # Recording is not skippable on that shape — its absence is a refusal — which is the
    # property that makes the run-wide aggregate and the reconciliation discipline total
    # over post-change rounds. A FILE verdict and a `REVISE … unestablished` adjudication
    # take no flag, read no stdin, and record no ledger: their call shapes stay
    # byte-compatible with the pre-#603 CLI.
    ledger_shape = args.verdict == 'REVISE' and isinstance(unresolved, int)
    ledger = None
    if getattr(args, 'ledger_stdin', False):
        if not ledger_shape:
            _fail('record-adjudication',
                  '--ledger-stdin is only accepted on a REVISE adjudication with a '
                  'settled unresolved count (ledger-not-applicable); a FILE verdict and '
                  f'a REVISE + {_UNESTABLISHED!r} adjudication record no ledger')
        ledger = _ingest_ledger(args.must_revise, unresolved)
    elif ledger_shape:
        _fail('record-adjudication',
              f'a REVISE adjudication with a settled unresolved count requires '
              f'--ledger-stdin carrying {args.must_revise} status-prefixed finding '
              f'summaries (ledger-required); the ledger is the durable identity record '
              f'the post-close resolution channels name entries from')
    rnd['adjudicated_verdict'] = args.verdict
    rnd['must_revise_count'] = args.must_revise
    rnd['advisory_count'] = args.advisory
    rnd['invalid_count'] = args.invalid
    rnd['unresolved_must_revise'] = unresolved
    if ledger is not None:
        rnd['findings'] = ledger
    # ── FILE supersession (issue #603 AC21) ───────────────────────────────────────
    # An auditor-accepted clean round is the strongest terminal, exactly as before this
    # change: recording a FILE adjudication marks every PRIOR unresolved entry
    # `superseded`, naming this round as the provenance. That preserves the pre-#603
    # latest-round-wins convergence semantics now that the count is run-wide — without it
    # an earlier round's stale bookkeeping would hold a clean re-audit hostage.
    superseded = 0
    if args.verdict == 'FILE':
        for _, entry in _all_entries(doc):
            if entry.get('status') == 'unresolved':
                # Clear-then-set, like every other status-change writer. Today this is a
                # no-op — the sweep filters on `unresolved`, whose legal settling set is
                # empty — but `_clear_settling`'s docstring claims a sufficiency that only
                # binds channels which CALL it, and this sweep is the one status-change
                # writer that did not. Widen the filter to retire `resolved` entries, or
                # give `unresolved` a legal settling key, and the sweep would carry a
                # `resolution_ordinal` onto a `superseded` entry — which the read boundary
                # then refuses on a file the tool itself just wrote, with every post-close
                # channel already refusing superseded entries, so nothing could repair it.
                _clear_settling(entry)
                entry['status'] = 'superseded'
                entry['supersession_round'] = args.round
                superseded += 1
    _save_or_fail('record-adjudication', doc, args.slug)
    print(f'adjudicated={args.verdict} unresolved={unresolved} '
          f'must_revise={args.must_revise} advisory={args.advisory} '
          f'invalid={args.invalid} superseded={superseded}')


def _read_stdin_lines(command, what, token):
    """Read a quoted-heredoc line payload from stdin, or fail closed (issue #708).

    ONE implementation of the fail-closed byte-read the line-oriented stdin transports
    share — a closed fd (CPython sets `sys.stdin` to None, so an attribute access would
    otherwise leak a raw traceback), a read error, an undecodable payload, and an empty
    one. Callers supply their own `command` (for the breadcrumb prefix), the human `what`
    they are reading, and the `token` their triage vocabulary uses, so every named
    breadcrumb stays exactly what it was when each caller inlined this block.

    The transport is deliberately line-oriented text, not a structured payload: the
    skill's fence pipes the lines through a QUOTED-delimiter heredoc, so the shell never
    expands the `$(...)`, backticks, and quotes that auditor-derived text routinely
    contains.

    Reading BYTES and decoding explicitly (rather than reading the text wrapper) is
    load-bearing: decoding INSIDE the read `try` would let a UnicodeDecodeError (a
    ValueError, not an OSError) escape as a raw traceback on routine input — text lifted
    from a terminal transcript carrying a mangled smart quote or a truncated multibyte
    char — breaking the mutation contract's named-breadcrumb half and leaving the skill's
    stderr triage nothing to match.

    Returns the non-blank lines. Never returns on any degraded shape.
    """
    if sys.stdin is None:
        _fail(command, f'could not read the {what} from stdin: no stdin is attached '
                       f'(fd 0 is closed)')
    try:
        data = sys.stdin.buffer.read()
    except OSError as exc:
        _fail(command, f'could not read the {what} from stdin: {exc}')
    try:
        raw = data.decode('utf-8')
    except UnicodeDecodeError as exc:
        _fail(command, f'the {what} is not valid UTF-8 text ({token}-undecodable): {exc}; '
                       f'reword the text in plain text and re-issue the call')
    if not raw.strip():
        _fail(command, f'--{token}-stdin was given but no {what} lines were received on '
                       f'stdin ({token}-empty)')
    return [ln for ln in raw.split('\n') if ln.strip()]


def _ingest_ledger(must_revise, unresolved):
    """Read `--ledger-stdin` and build the round's ledger, or fail closed.

    The transport is deliberately line-oriented text, not a structured payload: the
    skill's fence pipes the lines through a QUOTED-delimiter heredoc (`<<'LEDGER-EOF'`),
    so the shell never expands the `$(…)`, backticks, and quotes that auditor-derived
    summaries routinely contain. A summary line byte-equal to the delimiter truncates the
    stream, which is caught downstream (typically by the `ledger-line-count` refusal below,
    though a truncation leaving the count intact trips a different arm); the decided
    recovery for that and for a vocabulary refusal is the same — reword the summary and
    re-issue the call.

    The byte read and its two fail-closed checks mirror record-revision's — a closed fd
    (CPython sets `sys.stdin` to None, so an attribute access would otherwise leak a raw
    traceback) and a read error. The undecodable-payload and empty-payload arms are this
    command's own: record-revision hashes the bytes and never decodes them, so it has no
    decode step to mirror.
    """
    lines = _read_stdin_lines('record-adjudication', 'finding ledger', 'ledger')
    if len(lines) != must_revise:
        _fail('record-adjudication',
              f'the ledger carries {len(lines)} finding summaries but the adjudication '
              f'names {must_revise} must-revise findings (ledger-line-count); one '
              f'status-prefixed line per must-revise finding is required')
    ledger = []
    for idx, line in enumerate(lines, start=1):
        status = None
        for candidate in _LEDGER_PREFIXES:
            prefix = f'{candidate}: '
            if line.startswith(prefix):
                status, summary = candidate, line[len(prefix):]
                break
        if status is None:
            _fail('record-adjudication',
                  f'ledger line {idx} carries no status prefix (ledger-status-prefix); '
                  f'each line must begin with '
                  + ' or '.join(repr(f'{c}: ') for c in _LEDGER_PREFIXES))
        summary = summary.strip()
        if not summary:
            _fail('record-adjudication',
                  f'ledger line {idx} carries an empty finding summary '
                  f'(ledger-empty-summary); a summary is the entry\'s identity anchor')
        splitter = _record_splitting_char(summary)
        if splitter is not None:
            _fail('record-adjudication',
                  f'ledger line {idx} contains the record-splitting character '
                  f'{splitter!r} (ledger-summary-control-char); a summary is one line of '
                  f'identity data — reword it without the embedded newline or carriage '
                  f'return and re-issue the call')
        forged = _forged_protocol_token(summary)
        if forged is not None:
            _fail('record-adjudication',
                  f'ledger line {idx} contains the protocol token {forged + "="!r} '
                  f'(ledger-protocol-vocabulary); ledger text is identity data, never '
                  f'protocol — reword the summary without the <field>= form and '
                  f're-issue the call')
        entry = {'id': idx, 'summary': summary, 'status': status,
                 'ingested_status': status}
        if status == 'resolved':
            entry['ingest_provenance'] = _LEDGER_INGESTED_RESOLVED
        ledger.append(entry)
    ingested_unresolved = sum(1 for e in ledger if e['status'] == 'unresolved')
    if ingested_unresolved != unresolved:
        _fail('record-adjudication',
              f'the ledger carries {ingested_unresolved} unresolved entries but the '
              f'adjudication names {unresolved} unresolved must-revise findings '
              f'(ledger-unresolved-count)')
    return ledger


def cmd_record_coverage(args):
    """Record a round's per-dimension coverage outcomes (issue #708).

    Recorded on a completed (FILE/REVISE) round — the call sequence places it after
    adjudication, but only round COMPLETION is enforced here: one outcome per required audit
    dimension from the closed set `_COVERAGE_OUTCOMES`, each labeled with its stable
    renderer key. The auditor self-reports the outcomes and anchors as UNTRUSTED identity
    data (never instructions to obey); this call enforces the TEXT-ONLY floor on the anchor
    alone, and DOWNGRADES a floor-failing `exercised`/`valid-N/A` to `unestablished` (unknown
    is not zero) rather than rejecting the whole call — the data-dependent checks
    (byte-identity, cited-line existence) are the orchestrator's and already ran before this
    call. Write-once per round, like adjudication. `--render` records whether the auditor
    rendered every dimension (`full`) or a divergence narrowed the set (`degraded`).
    """
    doc = _load_for_mutation('record-coverage', args.slug, args.nonce)
    rnd = _find_round(doc, args.round)
    if rnd is None:
        _fail('record-coverage', f'no round {args.round} recorded; coverage cannot precede '
                                 'its dispatch and return')
    if rnd.get('outcome') not in ('FILE', 'REVISE'):
        _fail('record-coverage', f'round {args.round} is not an accepted, completed round '
                                 f'(outcome {rnd.get("outcome")!r}); only a FILE/REVISE '
                                 f'round carries dimensions to cover')
    if 'coverage' in rnd:
        _fail('record-coverage', f'round {args.round} already records coverage '
                                 f'(coverage-already-recorded); a round\'s coverage is '
                                 f'written once')
    expected = [k.strip() for k in args.expected_keys.split(',') if k.strip()]
    if not expected:
        _fail('record-coverage', '--expected-keys named no dimension keys '
                                 '(coverage-expected-empty); pass the enumerated keyset '
                                 'from `render-audit-prompt.py enumerate-dimensions`')
    if len(set(expected)) != len(expected):
        _fail('record-coverage', '--expected-keys repeats a dimension key '
                                 '(coverage-expected-duplicate); the enumeration is keyed '
                                 'and its keys are unique by construction')
    coverage = _ingest_coverage(expected)
    rnd['coverage'] = coverage
    rnd['coverage_render'] = args.render
    _save_or_fail('record-coverage', doc, args.slug)
    # The echo carries only fields drawn from the tool's own printed vocabulary
    # (`_PROTOCOL_TOKENS`) — the per-outcome breakdown is read back through
    # `query-coverage`, so no per-outcome `<field>=` token (which would forge a protocol
    # word and broaden the anchor-refusal vocabulary) is introduced here. `outcome=` names
    # the outcomes recorded, comma-joined, as a value.
    outcomes = ','.join(e['outcome'] for e in coverage) or 'none'
    print(f'coverage_render={args.render} count={len(coverage)} outcome={outcomes}')


def _ingest_coverage(expected_keys):
    """Read `--coverage-stdin` and build the round's coverage list, or fail closed.

    One line per required dimension: ``<key> <outcome> [anchor text...]`` — the key and
    outcome are the first two whitespace-delimited tokens; the anchor is the rest of the
    line (a quoted draft line plus one concern clause, for `exercised`; a one-line reason,
    for `valid-N/A`). Mirrors `_ingest_ledger`'s byte-read + fail-closed decode/empty arms
    and its quoted-heredoc transport, so auditor-derived anchor text never traverses shell
    quoting. An `exercised`/`valid-N/A` line whose anchor FAILS the text-only floor is
    DOWNGRADED to `unestablished` with its anchor dropped — never rejected (unknown is not
    zero, and the coverage record must stay total over required dimensions).
    """
    lines = _read_stdin_lines('record-coverage', 'coverage list', 'coverage')
    coverage = []
    seen = set()
    for idx, line in enumerate(lines, start=1):
        parts = line.strip().split(None, 2)
        if len(parts) < 2:
            _fail('record-coverage',
                  f'coverage line {idx} needs at least a key and an outcome '
                  f'(coverage-line-shape); the form is "<key> <outcome> [anchor]"')
        key, outcome = parts[0], parts[1]
        anchor = parts[2].strip() if len(parts) == 3 else None
        if outcome not in _COVERAGE_OUTCOMES:
            _fail('record-coverage',
                  f'coverage line {idx} names an outcome outside the canonical set '
                  f'{_COVERAGE_OUTCOMES} (coverage-outcome): {outcome!r}')
        if key in seen:
            _fail('record-coverage',
                  f'coverage line {idx} duplicates key {key!r} (coverage-duplicate-key)')
        seen.add(key)
        if outcome not in _COVERAGE_ANCHORED:
            anchor = None
        else:
            floor_err = _coverage_anchor_floor(anchor)
            if floor_err is not None:
                # Downgrade, never reject: unknown is not zero. A floor-failing anchor does
                # not back coverage, so the dimension records `unestablished` with no
                # anchor — and the CAUSE is breadcrumbed rather than collapsed onto the
                # outcome, so a reader can tell a tool-side text refusal (which the auditor
                # could fix by rewording) from the auditor's own substantive judgment.
                print(f'record-coverage: dimension {key!r} anchor fails the text-only floor '
                      f'({floor_err}); recorded unestablished', file=sys.stderr)
                outcome, anchor = 'unestablished', None
        # ONE append for all three arms — the entry shape has a single construction site,
        # so a later field cannot be added to two arms and missed on the third.
        coverage.append({'key': key, 'outcome': outcome, 'anchor': anchor})
    # TOTALITY over the authoritative enumeration (issue #708). `evaluate_coverage`'s
    # `all(...)` is vacuously true over a SHORT list, so without this a one-line return
    # against a twelve-dimension enumeration would derive `backed` — the mechanism passing
    # on exactly the input it exists to catch. A returned key outside the enumeration is
    # refused (the join has no dimension to attach it to); an enumerated key the auditor
    # returned no line for is synthesized `unestablished` — never dropped, never assumed
    # covered (unknown is not zero).
    unknown = [k for k in seen if k not in set(expected_keys)]
    if unknown:
        _fail('record-coverage',
              f'coverage names {len(unknown)} key(s) outside the authoritative enumeration '
              f'(coverage-unknown-key): {sorted(unknown)}; the auditor outcomes join the '
              f'enumerated dimensions by shared key, so an unenumerated key has no '
              f'dimension to attach to')
    for key in expected_keys:
        if key not in seen:
            coverage.append({'key': key, 'outcome': 'unestablished', 'anchor': None})
    return coverage


def cmd_query_coverage(args):
    """The run's coverage-backing, read back durably (issue #708).

    Read-only and exit-0 like its sibling queries, with the same inline fail-closed
    foreign-nonce answer. The FIRST line is the decided token line
    `coverage_backing=<token> coverage_render=<token>` — the orchestrator reads its
    coverage decision from state, never from context recall, so the decision survives a
    compaction. Subsequent lines (one per dimension of the coverage round) carry the durable
    per-dimension outcomes: `key=<k> outcome=<o> anchor=<text>` (anchor trailing, may
    contain spaces — the anchor floor bars it forging a `<field>=` token).
    """
    state = _query_state(args.slug)
    if state is not None and state['nonce'] != args.nonce:
        print('coverage_backing=unestablished coverage_render=none reason=foreign-nonce')
        return
    cov = evaluate_coverage(state)
    reason = f' reason={cov["reason"]}' if cov.get('reason') else ''
    print(f'coverage_backing={cov["backing"]} coverage_render={cov["render"]}{reason}')
    # The coverage round rides on the SAME derivation that decided the tokens — deriving
    # it a second time would be two call sites that must agree on which round is
    # authoritative, the drift #603 removed from the summary fields.
    rnd = cov['round']
    if rnd is not None:
        for e in rnd.get('coverage') or []:
            anchor = e.get('anchor')
            trailer = f' anchor={anchor}' if anchor is not None else ''
            print(f'key={e["key"]} outcome={e["outcome"]}{trailer}')


# ── The post-close ledger channels (issue #603) ───────────────────────────────────
# record-adjudication is write-once, so these three are the only sanctioned ways to move
# an INDIVIDUAL entry after its round closes. They are not the only way a closed round's
# effective count changes: a LATER round's FILE adjudication reaches backwards through the
# supersession sweep in `cmd_record_adjudication`, retiring every prior unresolved entry
# run-wide. Write-once bars re-adjudicating the SAME round; it does not bar that first
# write on a later one. They share one resolution/validation
# spine: locate a ledgered round no later than the latest completed round, resolve the
# named ids against its ledger, refuse every illegal transition with a named breadcrumb,
# then re-derive and print the run-wide remaining count (never a caller-supplied tally —
# a recall-fabricated number is unrepresentable on these CLIs by construction).

def _ledgered_round(prefix, doc, round_no):
    """The named round's ledger, or fail closed naming why it has none."""
    rnd = _find_round(doc, round_no)
    if rnd is None:
        _fail(prefix, f'no round {round_no} recorded (unknown-round)')
    latest = last_completed(doc)
    if latest is None or round_no > latest['round']:
        _fail(prefix, f'round {round_no} is later than the latest completed round '
                      f'(round-not-completed); a round\'s findings are only nameable '
                      f'once it has closed')
    if rnd.get('adjudicated_verdict') is None:
        _fail(prefix, f'round {round_no} is not adjudicated (round-unadjudicated); its '
                      f'findings have no recorded ledger')
    ledger = _ledger(rnd)
    if ledger is None:
        _fail(prefix, f'round {round_no} carries no finding ledger (round-unledgered); a '
                      f'FILE round, a REVISE + {_UNESTABLISHED!r} round, and a '
                      f'pre-change round record none')
    return rnd, ledger


def _named_entries(prefix, ledger, raw_ids, flag):
    """Resolve a comma-separated id list against a ledger, or fail closed.

    Repeated ids collapse to ONE entry, first occurrence winning, so the order the
    caller named survives. The mutations are idempotent per entry, so a duplicate never
    corrupted state — but `record-reopen` and `record-invalidate` print
    `reopened=`/`invalidated=` from this list's length, and the skill parses those
    echoes, so an un-deduped list reported more entries moved than exist.
    `record-resolution` echoes no such count: it prints the frozen at-close tally and
    the run-wide re-derived `remaining=`, neither of which varies with `len(entries)`,
    so that channel is insensitive to duplicates. The de-duplication is nonetheless
    shared by all three channels, so the property holds for every id flag rather than
    only the ones whose echo happens to expose it.
    """
    ids = [tok.strip() for tok in (raw_ids or '').split(',') if tok.strip()]
    if not ids:
        _fail(prefix, f'{flag} named no ledger entries (empty-id-list)')
    by_id = {entry['id']: entry for entry in ledger}
    resolved = []
    seen = set()
    for tok in ids:
        try:
            eid = int(tok)
        except ValueError:
            _fail(prefix, f'{flag} names {tok!r}, which is not a ledger entry id '
                          f'(unknown-id)')
        if eid not in by_id:
            _fail(prefix, f'{flag} names entry id {eid}, which is not on the round\'s '
                          f'ledger (unknown-id)')
        if eid in seen:
            continue
        seen.add(eid)
        resolved.append(by_id[eid])
    return resolved


def _render_count(eff):
    """Render an effective count: the integer, else the literal `unestablished`.

    The single None -> token mapping, so the mutation echo lines and `query-summary`
    can never disagree about how an unestablished effective count prints.
    """
    return _UNESTABLISHED if eff is None else str(eff)


def _remaining(doc):
    """The run-wide effective remaining count, rendered for a mutation's echo line."""
    return _render_count(_effective_unresolved(doc))


def _save_or_fail(prefix, doc, slug):
    try:
        save_state(doc, slug)
    except StateError as exc:
        _fail(prefix, str(exc))


def _find_revision(doc, ordinal):
    """The recorded revision with this ordinal, or None. The `_find_round` sibling."""
    for rev in doc['revisions']:
        if rev.get('ordinal') == ordinal:
            return rev
    return None


def _settling_provenance(doc):
    """The provenance stamp a post-close status change carries: the current revision
    ordinal, else the `pre-revision` token when no revision is recorded yet."""
    return revision_ordinal(doc) or _PRE_REVISION


def _clear_settling(entry):
    """Drop EVERY settling-provenance key a previous status change left, so a later change
    never leaves a stale ordinal behind for `_settling_ordinal` to read.

    Deliberately not "only the keys reachable today". The invalidation keys are a no-op on
    the current channels (all three refuse an `invalidated` entry), and `supersession_round`
    is likewise unreachable today — each of the three post-close channels refuses a
    superseded entry before it arrives here, though NOT all by the same guard:
    `_refuse_terminal` in `record-resolution` and `record-invalidate`, and the separate
    `status != 'resolved'` (`not-resolved`) arm in `record-reopen`, which has no
    `_refuse_terminal` call site at all — but clearing them unconditionally is
    what makes this helper's sufficiency independent of which statuses a future post-close
    channel can act on — the alternative is a comment-enforced obligation on every such
    channel to remember to add its key here. `reopen_provenance` is the one deliberate
    exemption and is NOT cleared, because it is the entry's genuine regression history.
    Note the exemption is NOT "it can never be read stale": `_convergence_basis` reads
    `reopen_provenance` for every entry whose `_settling_ordinal` is non-None, which
    includes `invalidated` — so a resolve → reopen → invalidate sequence at one ordinal
    really does surface `basis=resolution-stale` off the residual copy. That is retained
    behavior, not an accident: an entry that regressed once has a genuine staleness
    history, and reporting it is the conservative direction. It is why the key is exempt
    from clearing rather than why clearing it would be harmless.

    The cleared set is `_SETTLING_KEYS`, shared with `_validate_ledger`'s residual-key
    arm, so the writer and the read boundary cannot drift apart.
    """
    for key in _SETTLING_KEYS:
        entry.pop(key, None)


def _refuse_terminal(prefix, entry):
    """Refuse a post-close mutation on a superseded entry (terminal by construction)."""
    if entry['status'] == 'superseded':
        _fail(prefix,
              f'entry {entry["id"]} is superseded by a FILE-adjudicated round '
              f'(entry-superseded); supersession is terminal')


def cmd_record_resolution(args):
    """Mark named ledger entries resolved against a recorded revision (issue #603 AC2/AC3).

    Cross-round resolution is deliberate and legal: any LEDGERED round up to the latest
    completed round is a valid target, so a fix that lands late still clears the round
    that found the defect — and a defect listed on two rounds' ledgers is cleared by
    naming its entry on each.
    """
    doc = _load_for_mutation('record-resolution', args.slug, args.nonce)
    rnd, ledger = _ledgered_round('record-resolution', doc, args.round)
    entries = _named_entries('record-resolution', ledger, args.resolved_ids,
                             '--resolved-ids')
    if not doc['revisions']:
        _fail('record-resolution',
              'no revision is recorded for this run (no-revision-recorded); a resolution '
              'binds the fix to the revision that landed it')
    named = _find_revision(doc, args.revision_ordinal)
    if named is None:
        _fail('record-resolution',
              f'--revision-ordinal {args.revision_ordinal} names no recorded revision '
              f'(unknown-revision-ordinal)')
    if named['after_round'] < args.round:
        _fail('record-resolution',
              f'--revision-ordinal {args.revision_ordinal} names a revision recorded '
              f'after round {named["after_round"]}, below round {args.round} '
              f'(revision-predates-round); a revision cannot have fixed a finding a '
              f'later round raised')
    for entry in entries:
        status = entry['status']
        if status == 'resolved':
            _fail('record-resolution', f'entry {entry["id"]} is already resolved '
                                       f'(already-resolved)')
        if status == 'invalidated':
            _fail('record-resolution',
                  f'entry {entry["id"]} is invalidated (entry-invalidated); an entry '
                  f'retired as misclassified is not resolved as a fix that happened')
        _refuse_terminal('record-resolution', entry)
    for entry in entries:
        _clear_settling(entry)
        entry['status'] = 'resolved'
        entry['resolution_ordinal'] = args.revision_ordinal
    _save_or_fail('record-resolution', doc, args.slug)
    frozen = rnd.get('unresolved_must_revise')
    print(f'round={args.round} revision_ordinal={args.revision_ordinal} '
          f'frozen={frozen} remaining={_remaining(doc)}')


def cmd_record_reopen(args):
    """Mark named resolved entries unresolved again (issue #603 AC4).

    The honest correction channel the write-once adjudication guard would otherwise
    close: a fix that did not land, or a resolution recorded in error, re-holds T1 rather
    than being silently absorbed. Provenance is the CURRENT revision ordinal when at
    least one revision is recorded, else the literal `pre-revision` token — so a
    `resolved-at-adjudication` entry that turns out wrong BEFORE any revision exists is
    still honestly reopenable.
    """
    doc = _load_for_mutation('record-reopen', args.slug, args.nonce)
    _, ledger = _ledgered_round('record-reopen', doc, args.round)
    entries = _named_entries('record-reopen', ledger, args.ids, '--ids')
    for entry in entries:
        if entry['status'] != 'resolved':
            _fail('record-reopen',
                  f'entry {entry["id"]} is {entry["status"]}, not resolved '
                  f'(not-resolved); only a resolved entry can regress')
    ordinal = _settling_provenance(doc)
    for entry in entries:
        _clear_settling(entry)
        entry['status'] = 'unresolved'
        entry['reopen_provenance'] = ordinal
    _save_or_fail('record-reopen', doc, args.slug)
    print(f'round={args.round} reopened={len(entries)} remaining={_remaining(doc)}')


def cmd_record_invalidate(args):
    """Retire named ledger entries as misclassified (issue #603 AC19).

    A finding adjudicated must-revise in error is retired as INVALID with a mandatory
    one-line reason and visible provenance — never laundered through record-resolution as
    a fix that never happened. An erroneous invalidation needs no amend path of its own:
    the defect re-enters through the recurrence-of-an-invalidated-entry arm as a fresh
    entry on a new round's ledger.
    """
    doc = _load_for_mutation('record-invalidate', args.slug, args.nonce)
    _, ledger = _ledgered_round('record-invalidate', doc, args.round)
    entries = _named_entries('record-invalidate', ledger, args.ids, '--ids')
    reason = (args.reason or '').strip()
    if not reason:
        _fail('record-invalidate', '--reason is empty (empty-reason); retiring a finding '
                                   'as misclassified requires a recorded rationale')
    # argv carries what a heredoc cannot: --reason reaches this guard with an embedded
    # newline intact, so the splitter check is not redundant with _ingest_ledger's.
    splitter = _record_splitting_char(reason)
    if splitter is not None:
        _fail('record-invalidate',
              f'--reason contains the record-splitting character {splitter!r} '
              f'(reason-control-char); the rationale is one line of identity data — '
              f'reword it without the embedded newline or carriage return and re-issue '
              f'the call')
    forged = _forged_protocol_token(reason)
    if forged is not None:
        _fail('record-invalidate',
              f'--reason contains the protocol token {forged + "="!r} '
              f'(reason-protocol-vocabulary); reword it without the <field>= form and '
              f're-issue the call')
    for entry in entries:
        if entry['status'] == 'invalidated':
            _fail('record-invalidate', f'entry {entry["id"]} is already invalidated '
                                       f'(already-invalidated)')
        _refuse_terminal('record-invalidate', entry)
    ordinal = _settling_provenance(doc)
    for entry in entries:
        _clear_settling(entry)
        entry['status'] = 'invalidated'
        entry['invalidation_reason'] = reason
        entry['invalidation_provenance'] = ordinal
    _save_or_fail('record-invalidate', doc, args.slug)
    print(f'round={args.round} invalidated={len(entries)} remaining={_remaining(doc)}')


def _carriage_ok(attempt, args):
    """Compare the auditor's quoted carriage evidence against recorded values.

    Absent evidence is treated exactly like mismatched evidence — fail closed on
    missing evidence, so an auditor that quotes nothing cannot pass off an unproven
    verdict as a proven one.
    """
    if attempt['arm'] == 'file':
        return bool(args.carriage_object_id) and args.carriage_object_id == attempt['digest']
    if attempt['arm'] == 'embed':
        return (bool(args.carriage_sentinel_open) and bool(args.carriage_sentinel_close)
                and args.carriage_sentinel_open == attempt['sentinel_open']
                and args.carriage_sentinel_close == attempt['sentinel_close'])
    # The inline arm carries no auditor-quoted evidence: the orchestrator handed the
    # bytes to the auditor in its own context, so there is no carriage to prove.
    return True


def cmd_record_revision(args):
    doc = _load_for_mutation('record-revision', args.slug, args.nonce)
    if not doc['rounds']:
        _fail('record-revision', 'no rounds are recorded; there is nothing to revise')
    # issue #705: the file-arm staged-write guarantee, enforced by the tool rather than
    # carried by prose a context compaction can evict. When the latest recorded round's
    # LAST dispatch attempt is on the file arm, the canonical draft file is currently the
    # audit substrate — so a revision recorded here MUST carry the intended-bytes digest,
    # or the post-revision write-failure closure (`latest_revision_landed`,
    # `record-write-failure`) has no durable comparand and cannot tell a landed replace
    # from a lost one. The predicate is the PER-ROUND shape
    # `rounds[-1]['attempts'][-1]['arm']`, deliberately NOT the eligibility site's
    # `file_arm_epoch` (which reads the creation-epoch round, a record that does not exist
    # at revision time). On the embed/inline arms the auditor was handed the bytes inline,
    # so there is no canonical file to bind and the bare (no-digest) call stays legal —
    # including a run whose earlier round dispatched on the file arm but whose latest round
    # fell back to embed. On the read-only arm no staging artifact can be written, but the
    # flag reads `sys.stdin.buffer`, never a file, so a run that merely cannot write a file
    # satisfies this guard by piping the intended bytes from context.
    if (doc['rounds'][-1]['attempts'][-1]['arm'] == 'file'
            and not getattr(args, 'stdin_digest', False)):
        _fail('record-revision',
              'the latest recorded round dispatched on the file arm, so this revision must '
              'carry the intended-bytes digest (file-arm-requires-stdin-digest): pipe the '
              'revised title-and-body bytes to --stdin-digest. Without it the write-failure '
              'closure has no durable comparand and a lost canonical replace cannot be '
              'distinguished from a landed one.')
    # --after-round is the SOLE invalidation evidence on the event-ordering ground
    # (_revision_postdates keys eligibility and T2 on it), so a caller-supplied value
    # below the last completed round would fail that guard OPEN — a revised draft would
    # still answer eligible. Validate the operand against recorded facts: it must name
    # a round at or above the last completed one and no higher than the last recorded.
    last_num = doc['rounds'][-1]['round']
    lc = last_completed(doc)
    floor = lc['round'] if lc else 0
    if args.after_round < floor or args.after_round > last_num:
        _fail('record-revision',
              f'--after-round {args.after_round} does not name a plausible round: the '
              f'last completed round is {floor} and the last recorded round is '
              f'{last_num} (a value below the last completed round would fail the '
              f'event-ordering staleness guard open)')
    # Persist the floor this call validated against, so _validate can re-check the same
    # rule at the READ boundary — the treatment _valid_override already gets, which
    # `after_round` did not inherit. The floor is NOT reconstructible at load: rounds
    # complete forward, so the CURRENT last-completed round is >= the floor that applied
    # when this revision was recorded, and re-deriving it would wrongly reject a
    # legitimately-older revision (recorded when only round 1 was complete, now with
    # round 3 complete). Recording it is what makes the invariant checkable later.
    # issue #562: when the revised bytes are piped on stdin (gated by an explicit flag so
    # a legacy caller that pipes nothing never blocks on a read), record their digest.
    # The post-revision `approve` closure and the landed-clearing predicate compare it
    # against a later landed file-arm dispatch digest, so a revision whose overwrite
    # failed cannot masquerade as audited bytes.
    stdin_digest = None
    if getattr(args, 'stdin_digest', False):
        if sys.stdin is None:
            _fail('record-revision', 'could not read revised bytes from stdin: no stdin '
                                     'is attached (fd 0 is closed)')
        try:
            data = sys.stdin.buffer.read()
        except OSError as exc:
            _fail('record-revision', f'could not read revised bytes from stdin: {exc}')
        if not data:
            _fail('record-revision', '--stdin-digest was given but no revised bytes were '
                                     'received on stdin')
        try:
            stdin_digest = hash_bytes(data)
        except _DigestError as exc:
            _fail('record-revision', str(exc))
    rev = {'ordinal': len(doc['revisions']) + 1, 'after_round': args.after_round,
           'floor_round': floor}
    if stdin_digest is not None:
        rev['stdin_digest'] = stdin_digest
    doc['revisions'].append(rev)
    try:
        save_state(doc, args.slug)
    except StateError as exc:
        _fail('record-revision', str(exc))
    # The bare `ordinal=N` form is preserved for the no-byte-binding path (the legacy
    # contract); the stdin_digest field is appended only when a digest was recorded.
    out = f'ordinal={len(doc["revisions"])}'
    if stdin_digest is not None:
        out += f' stdin_digest={stdin_digest}'
    print(out)


def cmd_record_draft_binding(args):
    """Record the tiered draft-root binding, once per run (issue #562).

    The first landed canonical-draft write binds one absolute root for the rest of the
    run. Recorded two-rooted: the bound absolute ROOT (the readers join
    `.devflow/tmp/issue-draft-<slug>.md` onto it — see `_bound_draft_file`), its tier
    token, and the non-bound root (absolute when a resolver-answered tier-1 main root and
    a divergent tier-2 worktree root both exist; absent otherwise). Immutable — a second
    record is illegal, the forced-reinit path staying the only route to a fresh binding.
    """
    doc = _load_for_mutation('record-draft-binding', args.slug, args.nonce)
    if doc.get('draft_binding') is not None:
        _fail('record-draft-binding',
              'a draft-root binding is already recorded for this run '
              '(binding-already-recorded); it is immutable — a fresh binding requires the '
              'forced-reinit path (init --nonce --force)')
    if not _is_bound_path(args.path):
        _fail('record-draft-binding',
              f'the bound draft path {args.path!r} is not an absolute, single-line path '
              '(binding-path-not-absolute)')
    if not args.tier:
        _fail('record-draft-binding',
              'a bound-tier token is required (binding-tier-missing): one of '
              f'{", ".join(_DRAFT_TIERS)}')
    if args.tier not in _DRAFT_TIERS:
        _fail('record-draft-binding',
              f'the bound-tier token {args.tier!r} is outside the canonical set '
              f'(binding-tier-unknown): one of {", ".join(_DRAFT_TIERS)}')
    # An empty (or omitted) --non-bound-root is treated as "recorded absent" (the
    # breadcrumb/no-answer/failed-.git-test arm), so the skill can pass it unconditionally;
    # normalize once here.
    non_bound = args.non_bound_root or None
    if non_bound is not None and not _is_bound_path(non_bound):
        _fail('record-draft-binding',
              f'the non-bound root {non_bound!r} is present but not an absolute, '
              'single-line path (binding-nonbound-not-absolute)')
    doc['draft_binding'] = {
        'path': args.path,
        'tier': args.tier,
        'non_bound_root': non_bound,
    }
    try:
        save_state(doc, args.slug)
    except StateError as exc:
        _fail('record-draft-binding', str(exc))
    b = doc['draft_binding']
    print(f'bound_path={b["path"]} tier={b["tier"]} '
          f'non_bound_root={b["non_bound_root"] or "none"}')


def cmd_record_write_failure(args):
    """Record a canonical-draft overwrite that failed to land at the bound path (#562).

    Each entry names the revision ordinal whose overwrite failed. `latest_revision_landed`
    reads this log: a recorded failure for the latest revision's ordinal makes it report
    unlanded, so the skill renders the presentation from the in-context revision bytes
    rather than the stale file — even when the revised bytes coincidentally hash to some
    earlier audited dispatch's digest. (The `approve` eligibility ground refuses the same
    write-failure shape independently, via `_revision_postdates`.)
    """
    doc = _load_for_mutation('record-write-failure', args.slug, args.nonce)
    # DEFERRED (issue #562 review, Suggestion): `--ordinal` is intentionally NOT validated
    # against the current revision chain here. A bogus/non-latest ordinal is recorded and
    # reported as success — but the effect is bounded and fails safe: `latest_revision_landed`
    # only consults `len(revs)`, and the `approve` eligibility gate backstops independently
    # via `_revision_postdates`, so a mis-supplied ordinal is a silent no-op, never a
    # fail-open. Strict chain-validation is withheld deliberately because the valid range is
    # not settled — a canonical-write failure at a round-initiating (non-revision) site is
    # also conceptually recordable here — so a `1..len(revisions)` guard risks over-rejecting
    # a legitimate entry. Revisit if a non-revision write-failure consumer is added.
    doc.setdefault('write_failures', []).append(args.ordinal)
    try:
        save_state(doc, args.slug)
    except StateError as exc:
        _fail('record-write-failure', str(exc))
    print(f'write_failure_recorded ordinal={args.ordinal} '
          f'count={len(doc["write_failures"])}')


def _binding_line(state):
    """The binding query's single-line answer, from recorded facts (fail-closed).

    A crash is never the answer (the query exit contract): with no binding recorded it
    answers the decided `bound=none` token so the enumerations and fallback marker read
    a token, never a traceback.
    """
    b = _binding(state) if state is not None else None
    if not b:
        # `latest_revision_landed=yes` here is vacuous by construction, NOT a dropped
        # `latest_revision_landed(state)` call: an unbound run is an embed/inline epoch
        # that never bound a canonical file, so there is no bound-path write that could
        # fail to land. The bound branch below emits the real predicate.
        return 'bound=none tier=none non_bound_root=none latest_revision_landed=yes'
    return (f'bound={b["path"]} tier={b["tier"]} '
            f'non_bound_root={b["non_bound_root"] or "none"} '
            f'latest_revision_landed={_yn(latest_revision_landed(state))}')


def cmd_query_draft_binding(args):
    """Emit the recorded binding: bound path, tier token, non-bound root, landed flag."""
    state = _query_state(args.slug)
    # Nonce check inline like the sibling queries: a foreign-nonce query answers the
    # fail-closed token rather than a foreign run's binding.
    if state is not None and args.nonce and state.get('nonce') != args.nonce:
        sys.stderr.write('issue-audit-state.py query-draft-binding: nonce mismatch — '
                         'answering fail-closed\n')
        # Reuse the unbound answer shape (never drift a second copy) + the reason.
        print(f'{_binding_line(None)} reason=foreign-nonce')
        return
    # DEFERRED (issue #562 review, Suggestion): a genuinely-unbound run and an unestablished
    # (corrupt/unreadable) state both answer the identical fail-closed `bound=none …` token —
    # `_query_state` collapses "no state file" and "state failed validation" to the same None
    # (a pre-existing property shared by every sibling query). Distinguishing them with a
    # `reason=state-unestablished` clause would require reworking that shared `_query_state`
    # contract to signal absent-vs-corrupt to all callers, out of proportion for this
    # state-owner foundation. Both cases are correct and fail-closed today (bound=none);
    # revisit as a shared-query-surface seam if the caller needs the distinction.
    print(_binding_line(state))


def cmd_record_override(args):
    doc = _load_for_mutation('record-override', args.slug, args.nonce)
    digest = None
    if args.draft_file:
        try:
            digest = hash_file(args.draft_file)
        except _DigestError as exc:
            _fail('record-override', str(exc))
    if args.kind == 'user-decline' and not args.surface:
        _fail('record-override', 'a user-decline override must name the surface it was '
                                 'recorded at')
    # Validate the override against recorded facts, exactly as record-revision does with
    # --after-round: an override grounds eligibility, so an operand this path accepts
    # without checking is a gate that fails OPEN. Both kinds presuppose an audit — you
    # cannot decline further auditing, or reach the round ceiling, before any round ran.
    epoch = last_completed(doc)
    if epoch is None:
        _fail('record-override',
              'no round has completed, so there is no audit for an override to '
              'override: recording one here would ground eligibility on a draft the '
              'tool never audited')
    if epoch['attempts'][-1]['arm'] == 'file' and not digest:
        # --draft-file is optional in the argparse surface because the embed/inline arms
        # have no trustworthy canonical file to bind. On a file-arm epoch one exists, so
        # an unbound override would skip the byte comparison entirely and pass ANY bytes.
        # `not digest` (not `digest is None`) so an empty-string digest is refused too.
        _fail('record-override',
              'the current epoch is a file-arm round, so this override must bind the '
              'draft it permits: pass --draft-file (an override with no recorded digest '
              'is never compared against the draft, so it would permit any bytes)')
    doc['overrides'].append({'kind': args.kind, 'surface': args.surface,
                             'recorded_at_ordinal': len(doc['revisions']),
                             'draft_digest': digest})
    if args.kind == 'cap-reached':
        if doc.get('user_rounds_used', 0) < _USER_ROUND_CAP:
            _fail('record-override',
                  f'cap-reached recorded before the ceiling: user_rounds_used is '
                  f'{doc.get("user_rounds_used", 0)} of {_USER_ROUND_CAP} — a premature '
                  f'cap record would silently burn the remaining user rounds')
        doc['user_rounds_used'] = _USER_ROUND_CAP
    try:
        save_state(doc, args.slug)
    except StateError as exc:
        _fail('record-override', str(exc))
    print(f'kind={args.kind} ordinal={len(doc["revisions"])} digest={digest or "none"}')


def cmd_record_degraded(args):
    doc = _load_for_mutation('record-degraded', args.slug, args.nonce)
    rnd = _find_round(doc, args.round)
    if rnd is None:
        _fail('record-degraded', f'no round {args.round} is recorded')
    rnd['degraded'] = True
    try:
        save_state(doc, args.slug)
    except StateError as exc:
        _fail('record-degraded', str(exc))
    print(f'round={args.round} degraded=true reason={args.reason}')


def cmd_record_offer(args):
    doc = _load_for_mutation('record-offer', args.slug, args.nonce)
    used = doc.get('user_rounds_used', 0)
    if args.accepted:
        if used >= _USER_ROUND_CAP:
            _fail('record-offer', f'user-chosen rounds are capped at {_USER_ROUND_CAP} '
                                  'per run; the ceiling is already reached')
        doc['user_rounds_used'] = used + 1
    try:
        save_state(doc, args.slug)
    except StateError as exc:
        _fail('record-offer', str(exc))
    print(f'user_rounds_used={doc["user_rounds_used"]} cap={_USER_ROUND_CAP}')


def cmd_record_creation_epoch(args):
    doc = _load_for_mutation('record-creation-epoch', args.slug, args.nonce)
    rnd = _find_round(doc, args.round)
    if rnd is None:
        _fail('record-creation-epoch', f'no round {args.round} is recorded to bind '
                                       'creation to')
    if rnd.get('outcome') is None:
        _fail('record-creation-epoch', f'round {args.round} is still open; creation '
                                       'can only bind a completed round')
    if _attestation_frozen(doc):
        # attestation-unavailable is NOT tamper evidence (it is the honest unknown), so
        # a corrective retry may re-bind past it; match/mismatch stay frozen.
        _fail('record-creation-epoch',
              'an attestation is already recorded; re-binding the creation epoch would '
              'silently discard that tamper evidence')
    attempt = rnd['attempts'][-1]
    # The attestation comparand is the digest of the bytes the creation will ACTUALLY post,
    # not the audited round's dispatch digest. On a file-arm epoch the posting sources from
    # the current canonical file via emit-body, and eligibility may ground on a still-current
    # override whose bytes postdate the audited round (a user-elected "file anyway" over a
    # REVISE verdict) — so binding attempt['body_digest'] there would record the OLD audited
    # bytes and make the post-hoc attestation a structurally-guaranteed `mismatch` on a
    # legitimate override filing that GitHub stored faithfully (a false tamper signal, PR #552
    # review). Bind the current draft-file body digest instead, so the attestation compares
    # fetched-vs-posted like-for-like. On the file-identity ground the two are equal by
    # construction (eligibility required the file's full digest to equal the round's), so this
    # is a no-op there. On embed/inline epochs there is no trustworthy canonical file to point
    # at (the disclosed weaker-identity residual the module header describes), so the audited
    # round body digest remains the comparand and the attestation stays their detection surface.
    body_only_digest = attempt['body_digest']
    if args.draft_file and attempt['arm'] == 'file':
        try:
            raw = Path(args.draft_file).read_bytes()
            body_only_digest = hash_bytes(split_body(raw))
        except (OSError, _DigestError) as exc:
            _fail('record-creation-epoch',
                  f'could not hash the draft file to bind the creation epoch: {exc}')
    doc['creation'] = {'epoch_round': args.round, 'epoch_arm': attempt['arm'],
                       'body_only_digest': body_only_digest, 'attestation': None}
    try:
        save_state(doc, args.slug)
    except StateError as exc:
        _fail('record-creation-epoch', str(exc))
    print(f'epoch_round={args.round} body_digest={body_only_digest}')


def cmd_record_creation_attestation(args):
    doc = _load_for_mutation('record-creation-attestation', args.slug, args.nonce)
    if not doc.get('creation'):
        _fail('record-creation-attestation', 'no creation epoch is recorded; there is '
                                             'nothing to attest against')
    if _attestation_frozen(doc):
        _fail('record-creation-attestation',
              'an attestation is already recorded for this epoch; the attestation is '
              'forward-only tamper evidence and cannot be overwritten')
    if args.attestation_unavailable:
        status = 'attestation-unavailable'
    else:
        # Fail with the named breadcrumb rather than a raw traceback: this command IS the
        # tamper-detection surface, so a crash here would leave the run with no
        # attestation record at all — rendering `attestation=none` ("before any creation
        # attempt"), the never-attempted misattribution that `attestation-unavailable`
        # exists to prevent. A closed fd 0 fails at the ATTRIBUTE access (CPython sets
        # `sys.stdin = None`), not from the read, so it is tested separately — an
        # `except OSError` alone is blind to it. See record-dispatch's twin.
        if sys.stdin is None:
            _fail('record-creation-attestation',
                  'could not read the fetched body from stdin: no stdin is attached '
                  '(fd 0 is closed)')
        try:
            data = sys.stdin.buffer.read()
        except OSError as exc:
            _fail('record-creation-attestation',
                  f'could not read the fetched body from stdin: {exc}')
        # Empty fetched bytes are COMPARED, not laundered into unavailable: an empty
        # created body from a successful fetch is exactly the empty-bodied-issue
        # failure the posting guard exists to catch, and the recorded digest makes the
        # compare well-defined either way. A genuinely failed fetch is the explicit
        # --attestation-unavailable flag, never inferred from emptiness.
        try:
            got = hash_bytes(data)
        except _DigestError as exc:
            _fail('record-creation-attestation', str(exc))
        status = 'match' if got == doc['creation']['body_only_digest'] else 'mismatch'
        if status == 'mismatch' and data.endswith(b'\n'):
            # Bounded, disclosed tolerance: gh/jq fetch framing appends exactly one
            # trailing newline the posted bytes never carried. Retry the compare
            # with ONE trailing newline stripped; anything else stays a mismatch.
            # Accepted residual: server-side trailing-whitespace normalization, or a
            # second framing newline, still renders a spurious `mismatch`. Widening
            # the tolerance would blunt the tamper-evidence surface, and the false
            # positive is loud and post-hoc (creation is never rolled back), so the
            # one-byte bound is kept.
            try:
                if hash_bytes(data[:-1]) == doc['creation']['body_only_digest']:
                    status = 'match'
                    print('record-creation-attestation: matched modulo the '
                          "fetch's single trailing newline", file=sys.stderr)
            except _DigestError:
                pass
    # Stored as the BARE status token — the summary field renders it verbatim into the
    # single-line key=value surface, so a nested object here would corrupt that line.
    doc['creation']['attestation'] = status
    try:
        save_state(doc, args.slug)
    except StateError as exc:
        _fail('record-creation-attestation', str(exc))
    print(f'attestation={status}')


def cmd_emit_body(args):
    """Gated body emitter. Non-zero + EMPTY stdout when eligibility does not ground it."""
    try:
        doc = load_state(args.slug)
        _check_nonce(doc, args.nonce)
    except StateError as exc:
        _fail('emit-body', str(exc))
    # issue #562: resolve the draft file from the recorded binding when one exists — the
    # bound root is the single source of truth for which file is canonical, so a compacted
    # context that hands a drifted --draft-file cannot redirect the emit. Fall back to the
    # caller-supplied --draft-file only on an unbound run (an embed/inline epoch that never
    # bound a canonical file).
    source = _bound_draft_file(doc, args.slug) or args.draft_file
    try:
        raw = Path(source).read_bytes()
        digest = hash_bytes(raw)
    except (OSError, _DigestError) as exc:
        _fail('emit-body', f'could not hash the draft file: {exc}')
    elig = evaluate_eligibility(doc, 'approve', digest)
    if elig['answer'] != 'eligible':
        # issue #611: name the recovery at this refusal too. This is the costliest
        # point to rediscover it by trial — the creation epoch is already recorded —
        # so the remedy is emitted BEFORE _fail, which does not return. The helper
        # self-guards on the reason, so this call is unconditional.
        _emit_stale_override_remedy('emit-body', elig, doc, digest)
        _fail('emit-body', 'refusing to emit an unaudited body: eligibility answered '
                           f'not-eligible ({elig["reason"]})')
    body = split_body(raw)
    if not body:
        # Emitting an empty body on exit 0 would be indistinguishable from a successful
        # emit; an eligible draft with an empty body below its title must fail loudly
        # (the refusal signature: non-zero with EMPTY stdout) instead of stalling the
        # posting recipe undiagnosably.
        _fail('emit-body', 'the audited draft has an empty body below its title')
    sys.stdout.buffer.write(body)


def _query_state(slug):
    try:
        return load_state(slug)
    except StateError as exc:
        sys.stderr.write(f'issue-audit-state.py query: state unestablished — {exc}\n')
        return None


def cmd_query_arm(args):
    hash_ok = True
    try:
        hash_file(args.draft_file)
    except _DigestError as exc:
        # Same breadcrumb discipline as the sibling queries: the CAUSE (missing file,
        # permission, git absent) must never be silently collapsed onto the
        # digest-unrecorded marker.
        print(f'query: could not hash draft file {args.draft_file}: {exc}',
              file=sys.stderr)
        hash_ok = False
    state = _query_state(args.slug)
    if state is not None and state['nonce'] != args.nonce:
        # Every sibling query fails closed on a foreign nonce; this one must too, rather
        # than answering a routing decision for a run it does not belong to.
        print('arm=embed marker=digest-unrecorded reason=foreign-nonce')
        return
    # A prior within-round DRAFT-UNREADABLE is a fact the tool RECORDED at record-return
    # (`unreadable_retry_used` on the open round) — so read it rather than trusting the
    # caller to hand back something already written down. The reported flag is still OR'd
    # in so a caller that knows better than unestablished state is not overridden, but the
    # recorded fact alone is sufficient: this is what makes "decides from recorded facts"
    # true of the retry input rather than a claim the caller has to honor.
    prior_unreadable = bool(args.prior_unreadable)
    if state is not None and state['rounds']:
        last = state['rounds'][-1]
        if last.get('outcome') is None and last.get('unreadable_retry_used'):
            prior_unreadable = True
    arm, marker = route_arm(args.write_landed == 'yes', hash_ok, prior_unreadable)
    print(f'arm={arm} marker={marker or "none"}')


def cmd_query_next_action(args):
    state = _query_state(args.slug)
    if state is not None and state['nonce'] != args.nonce:
        print('action=round-closed-no-verdict reason=foreign-nonce')
        return
    print(f'action={next_action(state, args.round)}')


def cmd_query_triggers(args):
    state = _query_state(args.slug)
    if state is not None and state['nonce'] != args.nonce:
        # Fail closed like the sibling queries, but NAME the cause: the state file is
        # valid, the caller is foreign — 'state-unestablished' would misattribute. The
        # coverage field stays present (not-hold) so the line shape is identical on every
        # arm and the orchestrator's hand-parse never sees a field appear/disappear.
        print('t1=not-hold t2=hold coverage=not-hold reason=foreign-nonce')
        return
    t = evaluate_triggers(state)
    reason = t['reason'] or ''
    # issue #708: the unbacked-coverage offer trigger is a sibling of T1/T2 on the SAME
    # boundary offer, so it is produced by the SAME evaluation rather than a second call
    # concatenated in the printer (the one-producer discipline #603 established for the
    # summary fields). `coverage=` renders BEFORE `reason=` so `reason` stays the trailing
    # field the orchestrator's parse already anchors on.
    print(f't1={"hold" if t["t1"] else "not-hold"} '
          f't2={"hold" if t["t2"] else "not-hold"} '
          f'coverage={"hold" if t["coverage"] else "not-hold"} reason={reason}')


def _unledgered_revise(state):
    """Completed rounds adjudicated REVISE that recorded NO ledger, comma-joined or `none`.

    The AC5 residual, made observable (issue #603, PR #612 review iteration 2). Such a
    round's findings never enter the run-wide effective count, and once a later ledgered
    round becomes the latest completed round neither T1 nor T2's `unadjudicated-round` arm
    (which reads only that latest round) can still see it — so the orchestrator has to
    check for it, and could not: no query named it.

    Two rejected approximations, both measured wrong against HEAD before this existed. A
    **gap in the round numbers `query-findings` returns** is blind to the base case, where
    the unledgered round is the FIRST one and its absence leaves no gap to see. Comparing
    the ledgered rounds against `rounds_run=` is worse in the other direction: that field
    is `len(state['rounds'])` — every RECORDED round, since `record-dispatch` adds one
    before any outcome exists — and it counts the two shapes that legitimately record no
    ledger (a FILE round, which records none precisely because it is clean, and a
    no-verdict round), so it fires on runs with no unestablished round at all and sends
    the orchestrator to name a round that does not exist.

    This predicate is exactly the residual: adjudicated REVISE, completed, no ledger.
    """
    out = [str(r.get('round')) for r in completed_rounds(state or {'rounds': []})
           if r.get('adjudicated_verdict') == 'REVISE' and _ledger(r) is None]
    return ','.join(out) if out else 'none'


def cmd_query_convergence(args):
    state = _query_state(args.slug)
    if state is not None and state['nonce'] != args.nonce:
        # Fail closed like the sibling queries, naming the cause: a foreign caller cannot
        # read a converged verdict off another run's state. The field set must stay
        # IDENTICAL to the answering arm's — a fail-closed answer that drops a field is a
        # different shape for a parser to handle, and `unledgered_revise=none` here means
        # "no rounds are named", which is exactly right when nothing was read.
        print('converged=no reason=foreign-nonce basis=none unledgered_revise=none')
        return
    c = evaluate_convergence(state)
    reason = c['reason'] or ''
    print(f'converged={"yes" if c["converged"] else "no"} reason={reason} '
          f'basis={c["basis"]} unledgered_revise={_unledgered_revise(state)}')


def _findings_line(rnd, entry):
    """One `query-findings` ledger line.

    Hoisted out of `cmd_query_findings` so the AC1 protocol-token coverage audit can see
    it. That audit resolves emission shapes structurally, and a list-comprehension literal
    printed through an `IfExp` was a shape it could not reach — so `id=`, `status=` and
    `summary=`, the very line the vocabulary refusal exists to protect, were in
    `_PROTOCOL_TOKENS` by hand alone with nothing proving it (PR #612 review iteration 2).
    A `return`ed literal in a named helper is a shape the audit already covers.
    """
    return (f'round={rnd["round"]} id={entry["id"]} '
            f'status={entry["status"]} summary={entry["summary"]}')


def cmd_query_findings(args):
    """One line per ledger entry across all rounds (issue #603 AC8).

    The orchestrator's reconciliation input: a DURABLE read-back of prior rounds'
    findings, never context recall, so the classification of a new finding against the
    prior ledgers survives a compaction. Read-only and exit-0 like its sibling queries,
    with the same inline fail-closed foreign-nonce answer (never the mutations'
    exception path, which would break the two-class contract).

    `summary=` is the FINAL field on every line because it is the one field whose value
    may contain spaces; the AC1 vocabulary refusal is what keeps that unambiguous, since
    no summary can carry a `<field>=` word of the tool's own printed surface. This is the
    tool's one multi-line query.

    INVARIANT for any future field: `summary=` must REMAIN trailing. A field appended
    after it would end the unambiguous split — the reader could no longer tell a space
    inside the summary from the delimiter before the next field — and the vocabulary
    refusal does not rescue that, since it bars a summary from forging a field NAME, not
    from containing spaces. Pinned by the `#603-17/AC8` suite row.
    """
    state = _query_state(args.slug)
    if state is not None and state['nonce'] != args.nonce:
        print('findings=none reason=foreign-nonce')
        return
    if state is None:
        print('findings=none reason=state-unestablished')
        return
    lines = [_findings_line(rnd, entry) for rnd, entry in _all_entries(state)]
    print('\n'.join(lines) if lines else 'findings=none')


def cmd_query_eligibility(args):
    state = _query_state(args.slug)
    if state is not None and state['nonce'] != args.nonce:
        print('eligible=no reason=foreign-nonce')
        return
    digest = None
    digest_failed = False
    # issue #562: prefer the recorded bound draft file over the caller's --draft-file, so
    # a compacted context cannot drift which file eligibility grounds on. Fall back to
    # --draft-file only when unbound.
    source = _bound_draft_file(state, args.slug) or args.draft_file
    if source:
        try:
            digest = hash_file(source)
        except _DigestError as exc:
            # Surface the real cause — a swallowed digest failure would misattribute
            # the refusal as unaudited-revision. Queries stay exit-0; this is a
            # breadcrumb, not a failure exit.
            print(f'query: could not hash draft file {source}: {exc}',
                  file=sys.stderr)
            digest_failed = True
    r = evaluate_eligibility(state, args.mode, digest, digest_failed=digest_failed)
    if args.mode == 'iterate':
        if r['answer'] == 'iterate-ok':
            print(f'iterate=ok ordinal={r["ordinal"]}')
        else:
            print(f'iterate=no reason={r["reason"]}')
        return
    if r['answer'] == 'eligible':
        print(f'eligible=yes ground={r["ground"]} token={r["token"]} key={r["key"]}')
    else:
        print(f'eligible=no reason={r["reason"]}')
        # issue #611: the stdout token line above is the closed one-token contract and
        # stays byte-identical; the remedy is additive on stderr, matching this tool's
        # existing breadcrumb idiom (the `query: could not hash draft file ...` line).
        # The helper self-guards on the reason, so this call is unconditional.
        _emit_stale_override_remedy('query-eligibility', r, state, digest)


def cmd_query_summary(args):
    state = _query_state(args.slug)
    if state is not None and state['nonce'] != args.nonce:
        # The rendered line stays the fail-closed unestablished shape, but the CAUSE is
        # named on stderr so a transcript reader can tell a foreign nonce from a
        # missing/corrupt record.
        print(f'query: nonce mismatch for slug {args.slug} (the state file is owned by '
              f'another run); answering unestablished', file=sys.stderr)
        state = None
    digest = None
    digest_failed = False
    # issue #562: prefer the recorded bound draft file (consistency with query-eligibility,
    # whose derivation this summary shares) over the caller's --draft-file.
    source = _bound_draft_file(state, args.slug) or args.draft_file
    if source:
        try:
            digest = hash_file(source)
        except _DigestError as exc:
            # Same breadcrumb discipline as query-eligibility: never a silent swallow —
            # and the failure threads into the eligibility derivation so the summary can
            # never render a live token the approve gate would refuse.
            print(f'query: could not hash draft file {source}: {exc}',
                  file=sys.stderr)
            digest_failed = True
    f = summary_fields(state, digest, digest_failed=digest_failed)
    fc = 'none' if f['findings_count'] is None else str(f['findings_count'])
    token = f['token'] or ('stale-token' if f['stale_token'] else 'none')
    markers = ','.join(f['markers']) if f['markers'] else 'none'
    # The post-adjudication actionability fields render `none` before adjudication and
    # `unestablished` when the count could not be established (unknown is not zero).
    adj_v = f['adjudicated_verdict'] or 'none'
    mr = 'none' if f['must_revise'] is None else str(f['must_revise'])
    adv = 'none' if f['advisory'] is None else str(f['advisory'])
    inv = 'none' if f['invalid'] is None else str(f['invalid'])
    umr = 'none' if f['unresolved_must_revise'] is None else str(f['unresolved_must_revise'])
    # issue #603: `none` when the latest completed round is unadjudicated (or none exists);
    # `unestablished` when it IS adjudicated but the count could not be established (unknown
    # is not zero, exactly as `umr` one line above).
    eff_v = f['effective_unresolved']
    eff = 'none' if eff_v is None and f['adjudicated_verdict'] is None else _render_count(eff_v)
    # issue #562: the tool emits the bound root + the bound-tier TOKEN; the skill derives
    # the human `draft bound to worktree root` marker from `bound_tier=worktree-root`.
    # A space-containing marker value is deliberately NOT emitted here. bound_root itself
    # can contain a space (a real absolute path may — see _is_bound_path), so consumers
    # extract each field by its `key=` anchor, never by a positional whitespace split;
    # bound_tier and attestation stay space-free tokens found that way. These render
    # BEFORE `attestation`: attestation is the contractually-trailing final field (the
    # skill and the #546 suite anchor `attestation=<token>$` to end-of-line), so nothing
    # may follow it.
    print(f'state={f["state"]} findings_count={fc} '
          f'revisions_applied={f["revisions_applied"]} verdict={f["verdict"] or "none"} '
          f'rounds_run={f["rounds_run"]} '
          f'consumer_dimensions_appended={_yn(f["consumer_dimensions_appended"])} '
          f'degraded={_yn(f["degraded"])} user_declined={_yn(f["user_declined"])} '
          f'cap_reached={_yn(f["cap_reached"])} markers={markers} token={token} '
          f'reinit_forced={_yn(f["reinit_forced"])} '
          # Post-adjudication actionability fields (#548) and the bound-root fields (#562)
          # both precede `attestation` so that field stays the trailing token the #546 CLI
          # pins anchor on (`attestation=…$`).
          f'adjudicated_verdict={adj_v} must_revise={mr} advisory={adv} invalid={inv} '
          f'unresolved_must_revise={umr} effective_unresolved={eff} '
          f'convergence_basis={f["convergence_basis"]} '
          # issue #708: the coverage-backing and render tokens — space-free, before
          # bound_root, so attestation stays the trailing anchored field.
          f'coverage_backing={f["coverage_backing"]} '
          f'coverage_render={f["coverage_render"]} '
          f'bound_root={f["bound_root"] or "none"} bound_tier={f["bound_tier"] or "none"} '
          f'attestation={f["attestation"] or "none"}')


def _yn(v):
    return 'yes' if v else 'no'


def cmd_query_nonce(args):
    """Re-read the nonce from state — the compaction-recovery path.

    Recovery restores single-run continuity; it cannot discriminate a foreign
    same-slug run in the same cwd (the disclosed limitation).
    """
    state = _query_state(args.slug)
    print(f'nonce={state["nonce"] if state else "unknown"}')


# ── CLI ────────────────────────────────────────────────────────────────────────

def main():
    p = argparse.ArgumentParser(
        prog='issue-audit-state.py',
        description='State owner for the /devflow:create-issue fresh-context audit '
                    'lifecycle. Queries always exit 0 once the arguments parse and '
                    'print a decided token; '
                    'mutations exit non-zero with a named breadcrumb.')
    sub = p.add_subparsers(dest='cmd', required=True)

    s = sub.add_parser('init', help='Start a run: mint a nonce (cold start deletes any '
                                    'leftover same-slug state), or re-init this run.')
    s.add_argument('slug')
    s.add_argument('--nonce', help='This run nonce; omit for a cold start.')
    s.add_argument('--force', action='store_true',
                   help='Permit a same-run re-init over recorded rounds (recorded as '
                        'reinit-forced).')
    s.set_defaults(func=cmd_init)

    s = sub.add_parser('record-dispatch', help='Record an audit round dispatch and its '
                                               'draft digest.')
    s.add_argument('slug')
    s.add_argument('--nonce', required=True)
    s.add_argument('--round', type=int, required=True)
    s.add_argument('--arm', choices=_ARMS, required=True)
    s.add_argument('--write-path', help='Optional on the file arm (issue #569): the '
                   'absolute canonical-draft file path the skill observed its write land '
                   'at. When the run has a recorded draft-root binding and this is '
                   'passed, it is cross-checked against the bound canonical file '
                   '(write-path-mismatch on divergence). Omitted, or on an unbound run, '
                   'the dispatch proceeds unchanged; an empty value is refused '
                   '(write-path-empty) rather than read as an opt-out. Ignored on the '
                   'embed and inline arms.')
    s.add_argument('--draft-file', help='Required on the file arm; bytes on stdin '
                                        'otherwise.')
    s.add_argument('--marker', choices=_EMBED_MARKER_TOKENS,
                   help='The embed-arm entry marker, when entering the embed arm.')
    s.set_defaults(func=cmd_record_dispatch)

    s = sub.add_parser('record-return', help="Record an auditor's return: verdict, "
                                             'findings and carriage evidence.')
    s.add_argument('slug')
    s.add_argument('--nonce', required=True)
    s.add_argument('--round', type=int, required=True)
    s.add_argument('--verdict', choices=_VERDICTS,
                   help='Omit when the return carried no parseable VERDICT line.')
    s.add_argument('--findings-count', type=int)
    s.add_argument('--consumer-dimensions-appended', action='store_true')
    s.add_argument('--carriage-object-id', help='The object ID the auditor quoted '
                                                '(file arm).')
    s.add_argument('--carriage-sentinel-open')
    s.add_argument('--carriage-sentinel-close')
    s.set_defaults(func=cmd_record_return)

    s = sub.add_parser('record-adjudication',
                       help='Record a completed round\'s post-adjudication actionability '
                            'payload (issue #548).')
    s.add_argument('slug')
    s.add_argument('--nonce', required=True)
    s.add_argument('--round', type=int, required=True)
    s.add_argument('--verdict', choices=_ADJUDICATED_VERDICTS, required=True,
                   help='The adjudicated verdict (FILE or REVISE); the raw auditor token '
                        'stays recorded separately as provenance.')
    s.add_argument('--must-revise', type=int, required=True,
                   help='Count of verified must-revise findings.')
    s.add_argument('--advisory', type=int, required=True,
                   help='Count of advisory findings.')
    s.add_argument('--invalid', type=int, required=True,
                   help='Count of invalid/unverified findings.')
    s.add_argument('--unresolved-must-revise', required=True,
                   help="A non-negative integer, or the literal 'unestablished' when the "
                        'count could not be established (unknown is not zero).')
    s.add_argument('--ledger-stdin', action='store_true',
                   help='Required on a REVISE adjudication with a settled unresolved '
                        'count (#603): read exactly --must-revise status-prefixed '
                        "one-line finding summaries on stdin (each 'unresolved: <text>' "
                        "or 'resolved: <text>') and record them as the round's findings "
                        'ledger. Flag-gated like --stdin-digest, so the tool never '
                        'performs a bare stdin read. A FILE verdict and a REVISE + '
                        "'unestablished' adjudication take no flag and record no ledger.")
    s.set_defaults(func=cmd_record_adjudication)

    s = sub.add_parser('record-coverage',
                       help="Record a completed round's per-dimension coverage outcomes "
                            '(issue #708).')
    s.add_argument('slug')
    s.add_argument('--nonce', required=True)
    s.add_argument('--round', type=int, required=True)
    s.add_argument('--render', choices=_COVERAGE_RENDERS, required=True,
                   help="'full' when the auditor rendered every dimension on the "
                        "orchestrator's authoritative enumeration; 'degraded' when a render "
                        'divergence narrowed the auditor set (un-rendered dimensions record '
                        'unestablished; a degraded render discloses but never fires the '
                        'coverage offer).')
    s.add_argument('--expected-keys', required=True,
                   help="The AUTHORITATIVE enumerated dimension keys, comma-separated, as "
                        "printed by `render-audit-prompt.py enumerate-dimensions` (issue "
                        "#708). Coverage must be TOTAL over this set: an enumerated key "
                        "the auditor returned no line for is synthesized as unestablished "
                        "(unknown is not zero), and a returned key outside the set is "
                        "refused. Without it a truncated return would derive `backed` "
                        "vacuously — `all()` over a short list is trivially true.")
    s.add_argument('--coverage-stdin', action='store_true', required=True,
                   help='Read one line per required dimension on stdin: '
                        '"<key> <outcome> [anchor]", outcome in '
                        + repr(_COVERAGE_OUTCOMES) + '. An exercised/valid-N/A anchor '
                        'failing the text-only floor is downgraded to unestablished.')
    s.set_defaults(func=cmd_record_coverage)

    s = sub.add_parser('record-revision', help='Record that the draft was revised.')
    s.add_argument('slug')
    s.add_argument('--nonce', required=True)
    s.add_argument('--after-round', type=int, required=True)
    s.add_argument('--stdin-digest', action='store_true',
                   help='Read the revised bytes on stdin and record their digest (#562); '
                        'used by the post-revision write-failure closure. Omit to record a '
                        'revision with no byte binding (a legacy/embed-epoch revision).')
    s.set_defaults(func=cmd_record_revision)

    s = sub.add_parser('record-resolution',
                       help='Mark named ledger entries resolved against a recorded '
                            'revision (#603).')
    s.add_argument('slug')
    s.add_argument('--nonce', required=True)
    s.add_argument('--round', type=int, required=True,
                   help='Any ledgered round up to the latest completed round; '
                        'cross-round resolution lets a late fix clear the round that '
                        'found the defect.')
    s.add_argument('--revision-ordinal', type=int, required=True,
                   help='The recorded revision ordinal that landed the fix.')
    s.add_argument('--resolved-ids', required=True,
                   help='Comma-separated ledger entry ids the per-finding verification '
                        'confirmed fixed.')
    s.set_defaults(func=cmd_record_resolution)

    s = sub.add_parser('record-reopen',
                       help='Mark named resolved ledger entries unresolved again (#603).')
    s.add_argument('slug')
    s.add_argument('--nonce', required=True)
    s.add_argument('--round', type=int, required=True)
    s.add_argument('--ids', required=True,
                   help='Comma-separated ledger entry ids that regressed.')
    s.set_defaults(func=cmd_record_reopen)

    s = sub.add_parser('record-invalidate',
                       help='Retire named ledger entries as misclassified, with a '
                            'mandatory reason (#603).')
    s.add_argument('slug')
    s.add_argument('--nonce', required=True)
    s.add_argument('--round', type=int, required=True)
    s.add_argument('--ids', required=True,
                   help='Comma-separated ledger entry ids adjudicated must-revise in '
                        'error.')
    s.add_argument('--reason', required=True,
                   help='One line naming why the finding was misclassified; refused when '
                        'empty, when it carries a newline or carriage return, or when it '
                        'carries a protocol `<field>=` token.')
    s.set_defaults(func=cmd_record_invalidate)

    s = sub.add_parser('record-draft-binding',
                       help='Record the tiered canonical-draft-root binding, once per run '
                            '(#562): the bound absolute path, its tier token, and the '
                            'non-bound root.')
    s.add_argument('slug')
    s.add_argument('--nonce', required=True)
    s.add_argument('--path', required=True,
                   help='The absolute root directory under which the canonical draft '
                        '.devflow/tmp/issue-draft-<slug>.md was written (the landed root).')
    s.add_argument('--tier', help='The bound-tier token: main-root or worktree-root.')
    s.add_argument('--non-bound-root',
                   help='The divergent non-bound root, absolute, when both a '
                        'resolver-answered main root and a divergent worktree root exist; '
                        'pass empty or omit to record it absent.')
    s.set_defaults(func=cmd_record_draft_binding)

    s = sub.add_parser('record-write-failure',
                       help='Record a canonical-draft overwrite that failed to land at '
                            'the bound path (#562).')
    s.add_argument('slug')
    s.add_argument('--nonce', required=True)
    s.add_argument('--ordinal', type=int, required=True,
                   help='The revision ordinal whose overwrite failed.')
    s.set_defaults(func=cmd_record_write_failure)

    s = sub.add_parser('record-override', help='Record an override permitting '
                                               'presentation without a clean verdict.')
    s.add_argument('slug')
    s.add_argument('--nonce', required=True)
    s.add_argument('--kind', choices=_OVERRIDE_KINDS, required=True)
    s.add_argument('--surface', choices=_OVERRIDE_SURFACES)
    s.add_argument('--draft-file', help='Binds the override to the current draft digest '
                                        'on a file-arm epoch.')
    s.set_defaults(func=cmd_record_override)

    s = sub.add_parser('record-degraded', help='Record that a round ran the inline '
                                               'degraded audit arm.')
    s.add_argument('slug')
    s.add_argument('--nonce', required=True)
    s.add_argument('--round', type=int, required=True)
    s.add_argument('--reason', choices=_DEGRADED_REASONS, required=True)
    s.set_defaults(func=cmd_record_degraded)

    s = sub.add_parser('record-offer', help='Record a user-chosen-round offer outcome.')
    s.add_argument('slug')
    s.add_argument('--nonce', required=True)
    s.add_argument('--accepted', action='store_true')
    s.set_defaults(func=cmd_record_offer)

    s = sub.add_parser('record-creation-epoch', help='Bind creation to a completed round; '
                                                     'on the file arm bind the digest of '
                                                     'the bytes actually being posted.')
    s.add_argument('slug')
    s.add_argument('--nonce', required=True)
    s.add_argument('--round', type=int, required=True)
    s.add_argument('--draft-file', help='The canonical draft file the file-arm posting '
                                        'sources from. On a file-arm epoch it binds the '
                                        'body digest of the bytes emit-body will actually '
                                        'post, so the post-hoc attestation compares '
                                        'like-for-like even on an override filing; absent, '
                                        'or on an embed/inline epoch, the audited round '
                                        'body digest is used.')
    s.set_defaults(func=cmd_record_creation_epoch)

    s = sub.add_parser('record-creation-attestation',
                       help='Compare a fetched created-issue body against the epoch '
                            'body digest (bytes on stdin).')
    s.add_argument('slug')
    s.add_argument('--nonce', required=True)
    s.add_argument('--attestation-unavailable', action='store_true',
                   help='The fetch failed; report unavailable, never a pass.')
    s.set_defaults(func=cmd_record_creation_attestation)

    s = sub.add_parser('emit-body', help='Emit the audited body bytes; refuses with '
                                         'empty stdout when not eligible.')
    s.add_argument('slug')
    s.add_argument('--nonce', required=True)
    s.add_argument('--draft-file', required=True)
    s.set_defaults(func=cmd_emit_body)

    s = sub.add_parser('query-arm', help='Decide a dispatch arm from recorded facts.')
    s.add_argument('slug')
    s.add_argument('--nonce', required=True)
    s.add_argument('--write-landed', choices=('yes', 'no'), required=True)
    s.add_argument('--draft-file', required=True)
    s.add_argument('--prior-unreadable', action='store_true')
    s.set_defaults(func=cmd_query_arm)

    s = sub.add_parser('query-next-action', help='The retry/next-action answer for a '
                                                 'round.')
    s.add_argument('slug')
    s.add_argument('--nonce', required=True)
    s.add_argument('--round', type=int, required=True)
    s.set_defaults(func=cmd_query_next_action)

    s = sub.add_parser('query-triggers', help='Evaluate the T1 and T2 offer triggers.')
    s.add_argument('slug')
    s.add_argument('--nonce', required=True)
    s.set_defaults(func=cmd_query_triggers)

    s = sub.add_parser('query-convergence',
                       help='Whether the run has converged: zero EFFECTIVE unresolved '
                            'must-revise findings, reported with the basis it rests on '
                            '(#548/#603).')
    s.add_argument('slug')
    s.add_argument('--nonce', required=True)
    s.set_defaults(func=cmd_query_convergence)

    s = sub.add_parser('query-findings',
                       help='One line per per-finding ledger entry across all rounds '
                            '(#603); the durable reconciliation read-back.')
    s.add_argument('slug')
    s.add_argument('--nonce', required=True)
    s.set_defaults(func=cmd_query_findings)

    s = sub.add_parser('query-coverage',
                       help="The run's coverage-backing, derived from the final accepted "
                            'clean round (#708); the durable coverage read-back.')
    s.add_argument('slug')
    s.add_argument('--nonce', required=True)
    s.set_defaults(func=cmd_query_coverage)

    s = sub.add_parser('query-eligibility', help='Presentation eligibility in approve or '
                                                 'iterate mode.')
    s.add_argument('slug')
    s.add_argument('--nonce', required=True)
    s.add_argument('--mode', choices=('approve', 'iterate'), required=True)
    s.add_argument('--draft-file')
    s.set_defaults(func=cmd_query_eligibility)

    s = sub.add_parser('query-summary', help='The audit-summary-line fields.')
    s.add_argument('slug')
    s.add_argument('--nonce', required=True)
    s.add_argument('--draft-file')
    s.set_defaults(func=cmd_query_summary)

    s = sub.add_parser('query-draft-binding',
                       help='Emit the recorded tiered draft-root binding (#562): bound '
                            'path, tier token, non-bound root, and the latest-revision '
                            'landed flag. Fail-closed bound=none when unbound.')
    s.add_argument('slug')
    s.add_argument('--nonce', required=True)
    s.set_defaults(func=cmd_query_draft_binding)

    s = sub.add_parser('query-nonce', help='Re-read this run nonce from state (recovery '
                                           'after context compaction).')
    s.add_argument('slug')
    s.set_defaults(func=cmd_query_nonce)

    args = p.parse_args()
    args.func(args)


if __name__ == '__main__':
    main()
