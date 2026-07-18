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
    token — fail-closed answers included. A crashed read is never presented as a
    value. Queries are strictly READ-ONLY: the tool-unavailability fallback depends
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
    # than the stale file. (The dispatch write-path cross-check is a separate, strict
    # enforcement deferred to the skill-side follow-up; no dead row is declared for it
    # here.)
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

    T1 holds when the most recent completed round's verdict is `VERDICT: REVISE`.
    T2 holds in three cases: when a revision record postdates the last completed
    round's record; when the last completed round hit the verdict-less (`no-verdict`)
    terminal (the content is effectively unaudited); and whenever state is
    unestablishable (unknown is not zero: an unreadable state means the content is
    effectively unaudited, so the boundary offer must fire rather than be silently
    skipped).
    """
    if state is None:
        return {'t1': False, 't2': True, 'reason': 'state-unestablished'}
    last = last_completed(state)
    if last is None:
        return {'t1': False, 't2': False, 'reason': None}
    t1 = last.get('outcome') == 'REVISE'
    t2 = _revision_postdates(state, last)
    if last.get('outcome') == 'no-verdict':
        # The verdict-less terminal: T1 does not hold (there is no REVISE), but the
        # content is effectively unaudited, so T2 is treated as holding and the
        # boundary offer fires naming the state.
        t2 = True
    return {'t1': t1, 't2': t2, 'reason': None}


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
    # issue #562: the bound draft root + its tier token, so the display renders the
    # `draft bound to worktree root` marker from the tool-emitted token rather than
    # from the orchestrator's recall.
    'bound_root', 'bound_tier',
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
                        attestation=None, bound_root=None, bound_tier=None)
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
        # issue #562: the bound root + tier token (None on an unbound run — an
        # embed/inline epoch that never bound a canonical file).
        bound_root=(_binding(state) or {}).get('path'),
        bound_tier=(_binding(state) or {}).get('tier'),
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
               'degraded': False}
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
        # valid, the caller is foreign — 'state-unestablished' would misattribute.
        print('t1=not-hold t2=hold reason=foreign-nonce')
        return
    t = evaluate_triggers(state)
    reason = t['reason'] or ''
    print(f't1={"hold" if t["t1"] else "not-hold"} '
          f't2={"hold" if t["t2"] else "not-hold"} reason={reason}')


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

    s = sub.add_parser('record-revision', help='Record that the draft was revised.')
    s.add_argument('slug')
    s.add_argument('--nonce', required=True)
    s.add_argument('--after-round', type=int, required=True)
    s.add_argument('--stdin-digest', action='store_true',
                   help='Read the revised bytes on stdin and record their digest (#562); '
                        'used by the post-revision write-failure closure. Omit to record a '
                        'revision with no byte binding (a legacy/embed-epoch revision).')
    s.set_defaults(func=cmd_record_revision)

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
