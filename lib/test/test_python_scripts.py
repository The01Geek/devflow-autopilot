#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Pure-function tests for the devflow Python scripts.

Covers areas that are silent-failure-class regressions if they drift:
- `workpad._apply_mutations` — batch tick/note application, the structural-failure
  abort (missing section aborts with no PATCH), and the issue #169 failure-isolation
  contract: a per-row tick miss inside a present section is collected (the call's
  other mutations still apply) rather than discarding the batch, plus index-based
  ticking (`--tick-ac-n`/`--tick-plan-n`).
- `parse_acs._is_post_merge` — the new workflow/bot-trigger phrases plus
  documented false-positive cases (`monitoring` substring, generic
  "errors swallowed" prose, `click` substring, `workflow runner` vs
  `workflow run`, and `commenting on a` previous-decision prose).
- `parse_acs._extract_section` / `_parse_checkboxes` / `_render_md` — the
  case-insensitive, level-bounded heading match (a differently-cased heading
  still matches, but a trailing-colon / wrong-level heading must yield zero
  items, not a silent miss that trivially passes the implement skill's
  post-merge-exempt gate), bullet variants, and the `(post-merge)` render
  tagging.
- `file_deferrals._derive_area` / `_compute_id` / `_format_line_range` /
  `_render_issue_body` — the `<area>` derivation examples, the deterministic
  ID that must stay stable across regenerations (the verdict engine matches on
  it), and the `PR #<n>` cross-link substring the verdict engine's guard
  validates against ("Do not reformat without updating the matcher").
- `match_deferrals._extract_block` / `_parse_yaml_payload` — the deferred-findings
  payload now lives in a hidden DEVFLOW_DEFERRED_PAYLOAD HTML comment (the PR body
  shows a human-readable table); the matcher must parse the payload from that
  comment, not the visible table, and degrade gracefully on an absent block.

Run from repo root:
    python3 lib/test/test_python_scripts.py
"""

import argparse
import contextlib
import importlib.util
import io
import re
import sys
import types
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[2] / 'scripts'


def _load(modname: str, path: Path) -> types.ModuleType:
    spec = importlib.util.spec_from_file_location(modname, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[modname] = mod
    spec.loader.exec_module(mod)
    return mod


workpad = _load('workpad', SCRIPTS / 'workpad.py')
parse_acs = _load('parse_acs', SCRIPTS / 'parse-acs.py')
file_deferrals = _load('file_deferrals', SCRIPTS / 'file-deferrals.py')
match_deferrals = _load('match_deferrals', SCRIPTS / 'match-deferrals.py')
resolve_review_overrides = _load(
    'resolve_review_overrides', SCRIPTS / 'resolve-review-overrides.py')


PASS = 0
FAIL = 0


def assert_eq(name, expected, actual):
    global PASS, FAIL
    if expected == actual:
        PASS += 1
        print(f"  PASS  {name}")
    else:
        FAIL += 1
        print(f"  FAIL  {name}\n         expected: {expected!r}\n         actual:   {actual!r}")


def assert_raises(name, exc_type, fn):
    global PASS, FAIL
    try:
        fn()
    except exc_type as e:
        PASS += 1
        print(f"  PASS  {name} (raised: {e})")
        return
    except Exception as e:
        FAIL += 1
        print(f"  FAIL  {name}\n         expected {exc_type.__name__}, got {type(e).__name__}: {e}")
        return
    FAIL += 1
    print(f"  FAIL  {name}\n         expected {exc_type.__name__}, no exception raised")


def make_args(**overrides):
    """Build an argparse.Namespace matching cmd_update's expected shape."""
    base = dict(
        status=None, branch=None, run_link=None, pr_link=None,
        tick_progress=[], tick_plan=[], tick_plan_n=[], tick_ac=[], tick_ac_n=[],
        rewrite_ac=None,
        replace_plan_file=None, replace_acs_file=None, set_reproduction_file=None,
        note=[], reflection=[], reflection_kind=None, marker=None,
    )
    base.update(overrides)
    return argparse.Namespace(**base)


def apply_mut(body, args, failed_ticks=None):
    """Test wrapper for `_apply_mutations`, whose production signature now takes a
    required `failed_ticks` out-list (volatile per-row tick misses are appended
    there instead of raising). Most tests pass no list (a throwaway is created);
    failure-isolation tests pass their own list to inspect the collected misses."""
    return workpad._apply_mutations(body, args, failed_ticks if failed_ticks is not None else [])


def _statusline(out):
    """The workpad's `**Status:**` line, for asserting a status mutation landed."""
    return next(ln for ln in out.splitlines() if ln.startswith('**Status:'))


WORKPAD_BODY = """<!-- devflow:workpad -->
# DevFlow Workpad — Issue #999

**Status:** Implementing
**Branch:** `feat/x`
**Last updated:** 2026-05-15T00:00:00Z

## Progress
- [ ] **Setup** — branch & workpad
- [ ] **Implement**
  - [ ] code + sweeps
- [ ] **Review**
- [ ] **Documentation**
- [ ] **PR marked ready**

## Plan
- [ ] Step alpha
- [ ] Step beta
- [ ] Step gamma

## Acceptance Criteria
- [ ] AC one
- [ ] AC two

## Devflow Reflection
"""


print("workpad._workpad_marker (issue #55 review-marker override)")

# Marker override lets /devflow:review target its own <!-- devflow:review-progress
# --> comment with the same helper. Precedence: the `--marker` CLI flag (passed as
# a plain argument, so the command still starts with the allow-listed helper path)
# > the DEVFLOW_WORKPAD_MARKER env var (back-compat) > config > built-in default.
import os as _os  # noqa: E402

_saved = _os.environ.pop('DEVFLOW_WORKPAD_MARKER', None)
try:
    # --marker flag wins, with NO env var set (the cloud /devflow:review path).
    assert_eq("marker: --marker flag wins (no env)", '<!-- devflow:review-progress -->',
              workpad._workpad_marker('<!-- devflow:review-progress -->'))
    # --marker flag wins even over a conflicting env var.
    _os.environ['DEVFLOW_WORKPAD_MARKER'] = '<!-- devflow:env-marker -->'
    assert_eq("marker: --marker flag overrides env", '<!-- devflow:review-progress -->',
              workpad._workpad_marker('<!-- devflow:review-progress -->'))
    # A blank/whitespace flag is ignored — falls through to the env var.
    assert_eq("marker: blank flag falls through to env", '<!-- devflow:env-marker -->',
              workpad._workpad_marker('   '))
    _os.environ.pop('DEVFLOW_WORKPAD_MARKER', None)

    _os.environ['DEVFLOW_WORKPAD_MARKER'] = '<!-- devflow:review-progress -->'
    assert_eq("marker: env override wins", '<!-- devflow:review-progress -->',
              workpad._workpad_marker())
    # A blank/whitespace override is ignored — falls through to config/default.
    # Assert it lands on the documented default marker (not merely non-empty), so
    # a regression in the fall-through wiring that returned the wrong marker is
    # caught. config-get.sh reads `.devflow/config.json` relative to cwd; the repo
    # *does* carry one whose workpad_marker is byte-identical to the default, so to
    # genuinely exercise the default-leg (config absent → config-get.sh returns the
    # passed default) we must run from a cwd with no .devflow/config.json. (Running
    # from the repo root would pass either way and prove nothing.) workpad resolves
    # config-get.sh via __file__, so the chdir does not break locating the helper.
    import tempfile as _tempfile  # noqa: E402
    _os.environ['DEVFLOW_WORKPAD_MARKER'] = '   '
    _orig_cwd = _os.getcwd()
    with _tempfile.TemporaryDirectory() as _td:
        _os.chdir(_td)
        try:
            assert_eq("marker: blank override falls through to default marker (no config in cwd)",
                      workpad._DEFAULT_WORKPAD_MARKER, workpad._workpad_marker())
        finally:
            _os.chdir(_orig_cwd)
finally:
    _os.environ.pop('DEVFLOW_WORKPAD_MARKER', None)
    if _saved is not None:
        _os.environ['DEVFLOW_WORKPAD_MARKER'] = _saved


print("workpad.cmd_id exit-code contract (issue #55 live-comment seeding)")

# The /devflow:review live-comment seeding branches on `workpad.py id`'s exit code
# (0 = found → resume, 2 = scanned-clean-but-absent → create, 1 = gh-api/parse
# error → skip, do NOT create). A regression collapsing the absent case (2) back
# to a generic error (1) would make a transient API hiccup look identical to "no
# comment yet", so the caller would post a DUPLICATE progress comment. These pin
# all three codes by stubbing the gh calls (no network).
import json as _json  # noqa: E402
import subprocess as _subprocess  # noqa: E402


class _FakeRun:
    # Models ONLY `.stdout` — the sole `_run(...)` attribute cmd_id/cmd_update read
    # on the success path. A consumer that later reads `.returncode`/`.stderr` would
    # hit an opaque AttributeError here; extend this double (and this note) if so.
    def __init__(self, stdout):
        self.stdout = stdout


def _cmd_id_exit(comments_stdout=None, *, raise_api=False):
    """Run cmd_id against a stubbed gh layer; return its exit code (None = exit 0).

    `_repo_full` and `_workpad_marker` are stubbed so no real gh/config call
    happens; `_run` returns the canned comments page (or raises to simulate a
    transient gh-api failure).
    """
    rev_marker = '<!-- devflow:review-progress -->'
    saved = (workpad._run, workpad._repo_full, workpad._workpad_marker)
    workpad._repo_full = lambda: 'owner/repo'
    workpad._workpad_marker = lambda explicit=None: rev_marker
    if raise_api:
        def _boom(cmd, **kw):
            raise _subprocess.CalledProcessError(1, cmd, stderr='gh: API error')
        workpad._run = _boom
    else:
        workpad._run = lambda cmd, **kw: _FakeRun(comments_stdout)
    out = io.StringIO()
    code = None
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            workpad.cmd_id(argparse.Namespace(issue=999, marker=None))
    except SystemExit as e:
        code = e.code
    finally:
        workpad._run, workpad._repo_full, workpad._workpad_marker = saved
    return code, out.getvalue().strip()


_MARK = '<!-- devflow:review-progress -->'
# Found: a comment whose body starts with the review marker → print id, exit 0.
_code, _printed = _cmd_id_exit(_json.dumps([{"id": 12345, "body": _MARK + "\nbody"}]))
assert_eq("cmd_id: matching comment → exit 0 (no SystemExit)", None, _code)
assert_eq("cmd_id: matching comment → prints the comment id", "12345", _printed)
# Clean scan, nothing matches (page < 100 → loop breaks) → exit 2 (first run → create).
_code, _ = _cmd_id_exit(_json.dumps([{"id": 1, "body": "an unrelated comment"}]))
assert_eq("cmd_id: scanned cleanly, absent → exit 2 (distinct create signal)", 2, _code)
# Empty issue (no comments at all) is still a clean scan → exit 2, not error.
_code, _ = _cmd_id_exit(_json.dumps([]))
assert_eq("cmd_id: no comments at all → exit 2 (clean-absent, not error)", 2, _code)
# gh api failure → exit 1 (NOT 2): the caller must not mistake a transient error
# for "absent" and post a duplicate comment.
_code, _ = _cmd_id_exit(raise_api=True)
assert_eq("cmd_id: gh-api error → exit 1 (must NOT collapse to absent's 2)", 1, _code)
# Unparseable gh response → exit 1 (parse error path), again distinct from absent.
_code, _ = _cmd_id_exit("this is not json")
assert_eq("cmd_id: unparseable gh response → exit 1 (parse error, not absent)", 1, _code)


def _cmd_id_paginated(pages):
    """Run cmd_id with a stateful _run that returns one stdout string per gh-api
    page call (in order). Returns (exit_code, printed_id, num_page_calls)."""
    saved = (workpad._run, workpad._repo_full, workpad._workpad_marker)
    workpad._repo_full = lambda: 'owner/repo'
    workpad._workpad_marker = lambda explicit=None: _MARK
    calls = {'n': 0}

    def _seq(cmd, **kw):
        i = calls['n']
        calls['n'] += 1
        return _FakeRun(pages[i] if i < len(pages) else pages[-1])

    workpad._run = _seq
    out = io.StringIO()
    code = None
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            workpad.cmd_id(argparse.Namespace(issue=999, marker=None))
    except SystemExit as e:
        code = e.code
    finally:
        workpad._run, workpad._repo_full, workpad._workpad_marker = saved
    return code, out.getvalue().strip(), calls['n']


# Pagination: a FULL first page (100 non-matching comments) forces the loop to
# fetch page 2 (`if len(items) < 100: break` is false, `page += 1`). The match on
# page 2 must be found — a regression collapsing pagination would miss an existing
# comment on a busy PR and post a DUPLICATE, the exact failure exit-2 prevents.
_full_page = _json.dumps([{"id": i, "body": "unrelated comment"} for i in range(100)])
_page2_hit = _json.dumps([{"id": 777, "body": _MARK + "\nfound on page 2"}])
_code, _printed, _ncalls = _cmd_id_paginated([_full_page, _page2_hit])
assert_eq("cmd_id: match on page 2 (after a full page 1) → exit 0", None, _code)
assert_eq("cmd_id: page-2 match prints the correct id", "777", _printed)
assert_eq("cmd_id: pagination actually fetched a 2nd page", 2, _ncalls)
# Full page 1 + short no-match page 2 → clean-absent exit 2 (loop terminates, no hang).
_code, _, _ncalls = _cmd_id_paginated([_full_page, _json.dumps([])])
assert_eq("cmd_id: full page then short no-match page → exit 2 (absent)", 2, _code)
assert_eq("cmd_id: absent-after-pagination terminated at 2 pages", 2, _ncalls)


print("workpad --marker argv → resolver wiring (issue #56 review)")

# End-to-end wiring: prove cmd_id AND cmd_update pass `args.marker` to
# `_workpad_marker`. The other marker tests call `_workpad_marker(...)` directly, so
# a regression reverting the call sites to a no-arg `_workpad_marker()` (dropping
# args.marker) would pass all of them yet silently break the cloud /devflow:review
# path, where the run-keyed marker is supplied only via --marker. Capture the
# explicit arg the resolver receives.
_cap = {}


def _capture_marker(explicit=None):
    _cap['explicit'] = explicit
    return explicit or workpad._DEFAULT_WORKPAD_MARKER


def _boom_repo():
    # cmd_update resolves the marker (args.marker) BEFORE _repo_full; bail here so
    # the test asserts the wiring without mocking the whole id→fetch→patch flow.
    raise SystemExit(99)


_CUSTOM = '<!-- devflow:review-progress run=test-1 -->'
_saved = (workpad._workpad_marker, workpad._repo_full, workpad._run)
try:
    workpad._workpad_marker = _capture_marker
    workpad._repo_full = lambda: 'owner/repo'
    # cmd_id: a comment whose body starts with the custom marker must be found via
    # args.marker (capturing resolver returns the explicit arg).
    workpad._run = lambda cmd, **kw: _FakeRun(_json.dumps([{"id": 42, "body": _CUSTOM + "\nx"}]))
    _out = io.StringIO()
    try:
        with contextlib.redirect_stdout(_out), contextlib.redirect_stderr(io.StringIO()):
            workpad.cmd_id(argparse.Namespace(issue=1, marker=_CUSTOM))
    except SystemExit:
        pass
    assert_eq("cmd_id: --marker argv reaches the resolver", _CUSTOM, _cap.get('explicit'))
    assert_eq("cmd_id: comment matched via the --marker value", "42", _out.getvalue().strip())

    # cmd_update: same wiring — capture the explicit arg, then bail at _repo_full.
    _cap.clear()
    workpad._repo_full = _boom_repo
    try:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            workpad.cmd_update(make_args(issue=1, marker=_CUSTOM))
    except SystemExit:
        pass
    assert_eq("cmd_update: --marker argv reaches the resolver", _CUSTOM, _cap.get('explicit'))
finally:
    workpad._workpad_marker, workpad._repo_full, workpad._run = _saved


print("workpad._apply_mutations")

# Batch tick: multiple --tick-plan in one call ticks all of them.
args = make_args(tick_plan=['alpha', 'beta'])
out = apply_mut(WORKPAD_BODY, args)
assert_eq("batch tick-plan: alpha ticked", True, '- [x] Step alpha' in out)
assert_eq("batch tick-plan: beta ticked",  True, '- [x] Step beta'  in out)
assert_eq("batch tick-plan: gamma untouched", True, '- [ ] Step gamma' in out)

# Mixed batch: tick-plan + tick-ac + note in one atomic call.
args = make_args(tick_plan=['gamma'], tick_ac=['AC one'], note=['decision A', 'decision B'])
out = apply_mut(WORKPAD_BODY, args)
assert_eq("mixed batch: gamma ticked", True, '- [x] Step gamma' in out)
assert_eq("mixed batch: AC one ticked", True, '- [x] AC one' in out)
assert_eq("mixed batch: note A present", True, '— decision A' in out)
assert_eq("mixed batch: note B present", True, '— decision B' in out)
# Multiple --note values share one timestamp.
note_lines = [ln for ln in out.splitlines() if '— decision' in ln]
ts_a = note_lines[0].split(' — ')[0]
ts_b = note_lines[1].split(' — ')[0]
assert_eq("multi-note: shared timestamp", ts_a, ts_b)

# Issue #169 failure-isolation: a per-row tick miss inside a present section is
# now a *volatile* failure — `_apply_mutations` collects it into the caller's
# `failed_ticks` list and returns the body with every other mutation applied,
# instead of raising `_UpdateError`. (Pre-#169 these four cases aborted the call.)

# Duplicate tick in one batched call: the first ticks; the second is a volatile
# miss (the row it would match is now ticked), collected, not raised.
_ft = []
out = apply_mut(WORKPAD_BODY, make_args(tick_plan=['alpha', 'alpha']), _ft)
assert_eq("dup --tick-plan: first occurrence ticks the row", True,
          '- [x] Step alpha' in out)
assert_eq("dup --tick-plan: second occurrence collected as one volatile miss",
          1, len(_ft))

# Substring matching only an already-ticked row: volatile miss, body still returns.
PRE_TICKED = WORKPAD_BODY.replace('- [ ] Step alpha', '- [x] Step alpha')
_ft = []
out = apply_mut(PRE_TICKED, make_args(status='Reviewing', tick_plan=['alpha']), _ft)
assert_eq("already-ticked --tick-plan: status still applied (not discarded)", True,
          '🚀 Reviewing' in _statusline(out))
assert_eq("already-ticked --tick-plan: collected as a volatile miss", 1, len(_ft))

# Ambiguous substring: multiple matches → volatile miss, not an abort.
_ft = []
out = apply_mut(WORKPAD_BODY, make_args(status='Reviewing', tick_plan=['Step']), _ft)
assert_eq("ambiguous --tick-plan: status still applied", True,
          '🚀 Reviewing' in _statusline(out))
assert_eq("ambiguous --tick-plan: collected as a volatile miss", 1, len(_ft))
assert_eq("ambiguous --tick-plan: miss descriptor names the flag + value", True,
          _ft and _ft[0].startswith("--tick-plan 'Step'"))

# Isolation in a batch: one resolving tick + one non-matching tick. The resolving
# box is ticked in the returned body; the miss is collected (no abort, no rollback).
_ft = []
out = apply_mut(WORKPAD_BODY, make_args(tick_plan=['alpha', 'does-not-exist']), _ft)
assert_eq("partial batch: the resolving tick is applied", True,
          '- [x] Step alpha' in out)
assert_eq("partial batch: the non-matching tick is the only collected miss",
          1, len(_ft))

# Heading match is case-insensitive: a differently-cased section heading is
# still found and mutated (not a silent "section not found" error).
LOWER_HEADING = WORKPAD_BODY.replace('## Acceptance Criteria', '## acceptance criteria')
out = apply_mut(LOWER_HEADING, make_args(tick_ac=['AC one']))
assert_eq("case-insensitive heading: AC one ticked under lowercase heading",
          True, '- [x] AC one' in out)


print("issue #169: failure-isolation + index-based ticking")


# Fixture with a pre-ticked first AC row, so a naive unticked-only index count
# would address the WRONG row (index counts every [ ] AND [x] in document order).
IDX_BODY = """<!-- devflow:workpad -->
# DevFlow Workpad — Issue #999

**Status:** 🚀 Implementing
**Last updated:** 2026-05-15T00:00:00Z

## Progress
- [ ] **Setup**

## Plan
- [ ] Plan step one
- [ ] Plan step two

## Acceptance Criteria
- [x] AC one
- [ ] AC two
- [ ] AC three
"""

# Failure isolation (AC 1, 2): a non-matching --tick-ac in a present section does
# NOT discard the batched --status/--note; the body carries them and the miss is
# collected with a flag-named descriptor.
_ft = []
out = apply_mut(IDX_BODY, make_args(
    status='Reviewing', note=['keep me'], tick_ac=['NO_SUCH_AC']), _ft)
assert_eq("#169 isolation: --status survives a non-matching --tick-ac", True,
          '🚀 Reviewing' in _statusline(out))
assert_eq("#169 isolation: --note survives a non-matching --tick-ac", True,
          '— keep me' in out)
assert_eq("#169 isolation: the failed tick is collected (exactly one)", 1, len(_ft))
assert_eq("#169 isolation: the descriptor names the flag and value", True,
          _ft[0].startswith("--tick-ac 'NO_SUCH_AC' —"))

# Structural still aborts (AC 3): no ## Acceptance Criteria section → _UpdateError
# raised before returning, so the caller never PATCHes and --status never applies.
# (Proving the isolation path did not swallow a structural error.)
NO_AC = """<!-- devflow:workpad -->
# DevFlow Workpad — Issue #999

**Status:** 🚀 Setup
**Last updated:** 2026-05-15T00:00:00Z

## Progress
- [ ] **Setup**
"""
def _structural_abort():
    apply_mut(NO_AC, make_args(status='Reviewing', tick_ac=['anything']), [])
assert_raises("#169 structural: missing AC section aborts (no isolation)",
              workpad._UpdateError, _structural_abort)

# Index happy path (AC 4): --tick-ac-n 2 ticks the SECOND checkbox counting the
# already-ticked first row — i.e. "AC two", not "AC three".
_ft = []
out = apply_mut(IDX_BODY, make_args(tick_ac_n=[2]), _ft)
assert_eq("#169 index: -n 2 ticks the 2nd row (counting the ticked 1st row)", True,
          '- [x] AC two' in out)
assert_eq("#169 index: -n 2 leaves the 3rd row untouched", True,
          '- [ ] AC three' in out)
assert_eq("#169 index: happy path collects no failure", 0, len(_ft))

# Index + substring + status in one call (AC 4): all apply, body returns once.
_ft = []
out = apply_mut(IDX_BODY, make_args(
    status='Reviewing', tick_ac=['AC two'], tick_ac_n=[3], tick_plan_n=[1]), _ft)
assert_eq("#169 combined: substring --tick-ac applied", True, '- [x] AC two' in out)
assert_eq("#169 combined: index --tick-ac-n applied", True, '- [x] AC three' in out)
assert_eq("#169 combined: index --tick-plan-n applied", True, '- [x] Plan step one' in out)
assert_eq("#169 combined: --status applied", True, '🚀 Reviewing' in _statusline(out))
assert_eq("#169 combined: no failures collected", 0, len(_ft))

# Index boundary/degenerate (AC 5): N=0, N>count, and N on an already-ticked row
# are all volatile failures — reported, non-zero (here: collected), --status still
# applied. The AC section has 3 checkbox rows; row 1 is already [x].
_ft = []
out = apply_mut(IDX_BODY, make_args(status='Blocked', tick_ac_n=[0, 4, 1]), _ft)
assert_eq("#169 boundary: --status applied despite all three index misses", True,
          '👎 Blocked' in _statusline(out))
assert_eq("#169 boundary: three index misses collected (N<1, N>count, already-ticked)",
          3, len(_ft))
assert_eq("#169 boundary: already-ticked descriptor is reported", True,
          any('already ticked' in f for f in _ft))
assert_eq("#169 boundary: out-of-range descriptor is reported", True,
          any('out of range' in f for f in _ft))

# Substring forms unchanged (AC 6): an existing unique --tick-ac still ticks that
# exact row, additively (no behavior removed).
out = apply_mut(IDX_BODY, make_args(tick_ac=['AC three']))
assert_eq("#169 substring unchanged: unique --tick-ac still ticks its row", True,
          '- [x] AC three' in out)

# Progress has no index form (AC 7): --tick-progress-n is an unknown argparse flag.
# Assert the exit CODE is 2 (argparse's usage-error code), not merely that *some*
# SystemExit fired — if Progress accidentally GAINED a --tick-progress-n flag,
# main() would parse cleanly and then exit 1 ("no workpad found"), so a bare
# `assert_raises(SystemExit)` would stay green on the very regression this guards.
# Code 2 uniquely identifies "argparse rejected the unknown flag." `_run` is stubbed
# to raise so that, IF a future refactor let the flag parse, the post-argparse path
# fails deterministically here (→ exit 1 ≠ 2) instead of shelling out to a real `gh`.
def _progress_no_index_form_code():
    saved = (sys.argv[:], workpad._run, workpad._repo_full, workpad._workpad_marker)
    sys.argv = ['workpad.py', 'update', '1', '--tick-progress-n', '1']
    def _boom(cmd, **kw):
        raise _subprocess.CalledProcessError(1, cmd, stderr='gh stubbed out')
    workpad._run = _boom
    workpad._repo_full = lambda: 'owner/repo'
    workpad._workpad_marker = lambda explicit=None: '<!-- devflow:workpad -->'
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            workpad.main()  # argparse rejects the unknown flag before any gh call
        return None
    except SystemExit as e:
        return e.code
    finally:
        sys.argv, workpad._run, workpad._repo_full, workpad._workpad_marker = saved
assert_eq("#169 AC7: --tick-progress-n is rejected by argparse (exit code 2, not a later exit)",
          2, _progress_no_index_form_code())


print("issue #169 (review): cmd_update CLI contract + structural-abort completeness")

# TD-1 (type-design review): the design's single load-bearing invariant — that
# _TickMatchError is a SIBLING of _UpdateError, never a subclass — guarded by name,
# so an accidental re-subclassing (which would silently restore the pre-#169
# batch-discard data loss) names its cause instead of cascading confusingly through
# the isolation tests.
assert_eq("#169 TD-1: _TickMatchError is a sibling, NOT a subclass, of _UpdateError",
          False, issubclass(workpad._TickMatchError, workpad._UpdateError))
assert_eq("#169 TD-1: _TickMatchError is still an Exception",
          True, issubclass(workpad._TickMatchError, Exception))


# cmd_update-level harness: stub _repo_full / _workpad_marker / _run so cmd_update
# runs end-to-end with no gh. _run serves three call shapes — the paginated comments
# list (one marker-matching comment), the body fetch (--jq .body → the fixture body),
# and the PATCH (read the -F body=@<tmp> file back so the test sees the patched body).
# Returns (exit_code, stderr, patched_body); patched_body is None when no PATCH ran.
def _drive_cmd_update(body, patch_fails=False, **arg_overrides):
    marker = '<!-- devflow:workpad -->'
    saved = (workpad._run, workpad._repo_full, workpad._workpad_marker)
    workpad._repo_full = lambda: 'owner/repo'
    workpad._workpad_marker = lambda explicit=None: marker
    state = {'patched': None}
    def _run(cmd, **kw):
        joined = ' '.join(cmd)
        if '/comments?' in joined or joined.endswith('/comments'):
            return _FakeRun(_json.dumps([{'id': 7, 'body': marker + '\n'}]))
        if '-X' in cmd and 'PATCH' in cmd:
            if patch_fails:  # simulate a gh-api PATCH failure (network/auth/5xx)
                raise _subprocess.CalledProcessError(1, cmd, stderr='gh: 503 Service Unavailable')
            for tok in cmd:
                if tok.startswith('body=@'):
                    with open(tok[len('body=@'):]) as fh:
                        state['patched'] = fh.read()
            return _FakeRun(state['patched'] or '')
        return _FakeRun(body)   # the body fetch
    workpad._run = _run
    err = io.StringIO()
    code = None
    try:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
            workpad.cmd_update(make_args(issue=999, **arg_overrides))
    except SystemExit as e:
        code = e.code
    finally:
        workpad._run, workpad._repo_full, workpad._workpad_marker = saved
    return code, err.getvalue(), state['patched']


# Finding 2/(a) (review): the volatile-failure TAIL of cmd_update — the non-zero
# exit + stderr report — is the observable contract ACs 2/5 promise the orchestrator.
# The isolation tests above assert the failed_ticks LIST is populated; these assert
# the process-level exit code and stderr the orchestrator actually consumes.
_code, _err, _patched = _drive_cmd_update(IDX_BODY, status='Reviewing', tick_ac=['NO_SUCH_AC'])
assert_eq("#169 cmd_update: a volatile tick miss exits non-zero (AC 2)", 1, _code)
assert_eq("#169 cmd_update: the volatile-miss stderr names the failed tick (AC 2)", True,
          'NO_SUCH_AC' in _err and 'did not resolve' in _err)
assert_eq("#169 cmd_update: the PATCH still landed (status applied despite the miss)", True,
          _patched is not None and '🚀 Reviewing' in _patched)

# A fully-resolving tick call exits 0 — the gate's evidence-based pass condition.
_code, _err, _patched = _drive_cmd_update(IDX_BODY, tick_ac_n=[2])
assert_eq("#169 cmd_update: a fully-resolving tick call exits 0", None, _code)
assert_eq("#169 cmd_update: the resolving index ticked its row", True,
          _patched is not None and '- [x] AC two' in _patched)

# Finding F1 (silent-failure-hunter): a volatile tick miss collected BEFORE a later
# structural abort is echoed on the abort path, not dropped. F1_BODY has ## Acceptance
# Criteria (so --tick-ac can miss-collect) but NO ## Progress (so the later --note
# raises a structural _UpdateError) — the exact combined call the finding describes.
F1_BODY = """<!-- devflow:workpad -->
# DevFlow Workpad — Issue #999

**Status:** 🚀 Implementing
**Last updated:** 2026-05-15T00:00:00Z

## Acceptance Criteria
- [ ] AC one
- [ ] AC two
"""
_code, _err, _patched = _drive_cmd_update(F1_BODY, tick_ac=['NO_SUCH_AC'], note=['n'])
assert_eq("#169 F1: a structural abort after a volatile miss still exits non-zero", 1, _code)
assert_eq("#169 F1: the structural-abort message is reported", True,
          "section '## Progress' not found" in _err)
assert_eq("#169 F1: the volatile tick miss collected before the abort is ALSO echoed", True,
          'NO_SUCH_AC' in _err)
assert_eq("#169 F1: the structural abort made no PATCH", True, _patched is None)

# Finding 3 (review): missing-front-matter structural abort (AC 3) — a body lacking
# the **Last updated:** line aborts with no return. The front-matter check raises
# BEFORE the section-tick loop runs, so the `--tick-ac` here is never even evaluated
# (failed_ticks stays empty); this test pins only "missing Last-updated → structural
# abort". The *combined* invariant (a volatile tick collected before a LATER structural
# fault is preserved/echoed) is owned by the #169 F1 / shadow-F1 tests, where the tick
# genuinely runs first.
NO_LASTUPDATED = IDX_BODY.replace('**Last updated:** 2026-05-15T00:00:00Z\n', '')
def _missing_lastupdated():
    apply_mut(NO_LASTUPDATED, make_args(tick_ac=['NO_SUCH_AC']), [])
assert_raises("#169 AC3: missing **Last updated:** line aborts (structural, not volatile)",
              workpad._UpdateError, _missing_lastupdated)

# Finding (b) (review): Plan and Progress structural aborts route through the same
# shared helper (AC 3 across all three sections, not only Acceptance Criteria).
NO_PLAN = """<!-- devflow:workpad -->
# DevFlow Workpad — Issue #999

**Status:** 🚀 Setup
**Last updated:** 2026-05-15T00:00:00Z

## Progress
- [ ] **Setup**
"""
def _missing_plan_section():
    apply_mut(NO_PLAN, make_args(tick_plan_n=[1]), [])
assert_raises("#169 AC3: missing ## Plan section aborts a --tick-plan-n (structural)",
              workpad._UpdateError, _missing_plan_section)
def _missing_progress_section():
    apply_mut(NO_PLAN.replace('## Progress\n- [ ] **Setup**\n', ''),
              make_args(tick_progress=['Setup']), [])
assert_raises("#169 AC3: missing ## Progress section aborts a --tick-progress (structural)",
              workpad._UpdateError, _missing_progress_section)

# Finding (c) (review): a --tick-plan-n out-of-range miss is collected as VOLATILE
# (reported, other mutations applied), not a structural abort — for the Plan section
# specifically, not just Acceptance Criteria. IDX_BODY's ## Plan has 2 rows.
_ft = []
out = apply_mut(IDX_BODY, make_args(status='Blocked', tick_plan_n=[5]), _ft)
assert_eq("#169 (c): an out-of-range --tick-plan-n is volatile (status still applied)", True,
          '👎 Blocked' in _statusline(out))
assert_eq("#169 (c): the out-of-range --tick-plan-n miss is collected, not raised", 1, len(_ft))
assert_eq("#169 (c): the Plan miss descriptor names the index flag", True,
          _ft and _ft[0].startswith('--tick-plan-n 5'))


print("issue #169 (shadow): PATCH-failure echo + structural/test-completeness")

# Shadow Finding 1 (silent-failure-hunter, HIGH): a volatile tick miss collected
# before the gh PATCH itself fails must NOT be silently dropped. Previously the
# PATCH-failure path reported only the PATCH error and exited, discarding the
# collected misses — the very no-silent-loss invariant this command establishes,
# re-opened on the API-failure path. Now cmd_update echoes them before _fail exits.
_code, _err, _patched = _drive_cmd_update(
    IDX_BODY, patch_fails=True, status='Reviewing', tick_ac=['NO_SUCH_AC'])
assert_eq("#169 shadow-F1: a PATCH failure still exits non-zero", 1, _code)
assert_eq("#169 shadow-F1: the PATCH-failure path echoes the collected volatile tick miss", True,
          'NO_SUCH_AC' in _err)
assert_eq("#169 shadow-F1: the PATCH-failure breadcrumb says nothing was persisted", True,
          'NO workpad change was persisted' in _err)
assert_eq("#169 shadow-F1: no body was persisted (PATCH failed)", True, _patched is None)
# A PATCH failure with NO pending tick miss still reports the PATCH error (and does
# not fabricate a tick report) — the echo is gated on a non-empty failed_ticks.
_code, _err, _patched = _drive_cmd_update(IDX_BODY, patch_fails=True, tick_ac_n=[2])
assert_eq("#169 shadow-F1: a clean PATCH failure (no tick miss) still exits non-zero", 1, _code)
assert_eq("#169 shadow-F1: a clean PATCH failure emits no spurious tick report", False,
          'did not resolve' in _err or 'had also not resolved' in _err)

# The volatile-PATCHed breadcrumb tells the caller to re-tick only the row(s), NOT
# re-send the whole call (Finding 2 — re-sending would double-write append-only notes).
_code, _err, _patched = _drive_cmd_update(IDX_BODY, note=['n'], tick_ac=['NO_SUCH_AC'])
assert_eq("#169 shadow-F2: the volatile-PATCHed breadcrumb says re-tick only, do not re-send", True,
          'do not' in _err and 're-tick only' in _err and _patched is not None)

# Shadow Finding 3 (silent-failure-hunter, LOW): an index tick against a PRESENT but
# EMPTY section (zero checkbox rows) is a VOLATILE out-of-range miss, NOT a structural
# abort — pins the volatile/structural boundary on the section-shape axis (TD-1 pins
# the class-hierarchy axis). A future edit raising _UpdateError for an empty section
# would silently re-introduce batch-discard for that shape; this guards against it.
EMPTY_PLAN = """<!-- devflow:workpad -->
# DevFlow Workpad — Issue #999

**Status:** 🚀 Setup
**Last updated:** 2026-05-15T00:00:00Z

## Plan

## Acceptance Criteria
- [ ] AC one
"""
_ft = []
out = apply_mut(EMPTY_PLAN, make_args(status='Blocked', tick_plan_n=[1]), _ft)
assert_eq("#169 shadow-F3: index tick on an empty (zero-row) section is volatile, not a structural abort", True,
          '👎 Blocked' in _statusline(out))
assert_eq("#169 shadow-F3: the empty-section index miss is collected (out-of-range)", 1, len(_ft))
assert_eq("#169 shadow-F3: the empty-section descriptor reports the 0-row count", True,
          'section has 0 checkbox row(s)' in _ft[0])

# Shadow pr-test 3a: the --tick-ac-n/--tick-plan-n argparse wiring (type=int) is
# exercised at the PARSE level, not just via pre-built Namespaces. A non-integer is
# rejected by argparse (exit 2) before any gh call — guarding a `type=int` regression
# the make_args-based tests (which bypass argparse) cannot catch.
def _tick_ac_n_noninteger_code():
    saved = (sys.argv[:], workpad._run, workpad._repo_full, workpad._workpad_marker)
    sys.argv = ['workpad.py', 'update', '1', '--tick-ac-n', 'notanint']
    def _boom(cmd, **kw):
        raise _subprocess.CalledProcessError(1, cmd, stderr='gh stubbed out')
    workpad._run = _boom
    workpad._repo_full = lambda: 'owner/repo'
    workpad._workpad_marker = lambda explicit=None: '<!-- devflow:workpad -->'
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            workpad.main()
        return None
    except SystemExit as e:
        return e.code
    finally:
        sys.argv, workpad._run, workpad._repo_full, workpad._workpad_marker = saved
assert_eq("#169 shadow-3a: --tick-ac-n with a non-integer is rejected by argparse (type=int, exit 2)",
          2, _tick_ac_n_noninteger_code())

# Shadow type-design: the _CHECKBOX_ROW_RE group-order contract (group 2 = state cell,
# preserved by _rewrite_checkbox / overwritten by _tick_checkbox_by_index) is pinned
# structurally, so a group reshuffle that happens to keep the index tests green but
# breaks _rewrite_checkbox's group-2 preservation is caught directly.
_m = workpad._CHECKBOX_ROW_RE.match('  - [x] hello world')
assert_eq("#169 group-order: group 1 is indent+bullet", '  - ', _m.group(1))
assert_eq("#169 group-order: group 2 is the [ xX] state cell", '[x]', _m.group(2))
assert_eq("#169 group-order: group 4 is the row text", 'hello world', _m.group(4))

# Re-shadow pr-test Finding 1: the index form counts NESTED (indented) checkbox rows
# and skips interleaved non-checkbox lines — `_CHECKBOX_ROW_RE`'s `\s*` indent group is
# load-bearing for the docstring's "every [ ]/[x] row in document order" claim. Every
# other index fixture is flat+contiguous; this one interleaves a nested sub-item and a
# prose line so a regression anchoring the row regex at column 0 (or counting only
# top-level rows) would mis-address rather than stay green.
NESTED_PLAN = """<!-- devflow:workpad -->
# DevFlow Workpad — Issue #999

**Status:** 🚀 Setup
**Last updated:** 2026-05-15T00:00:00Z

## Plan
- [ ] top one
  - [ ] nested two
- [ ] top three

## Acceptance Criteria
- [ ] AC one
"""
_ft = []
out = apply_mut(NESTED_PLAN, make_args(tick_plan_n=[2]), _ft)
assert_eq("#169 nested-index: -n 2 ticks the NESTED row (counted in document order)", True,
          '  - [x] nested two' in out)
assert_eq("#169 nested-index: the top rows are untouched", True,
          '- [ ] top one' in out and '- [ ] top three' in out)
assert_eq("#169 nested-index: -n 3 ticks the row AFTER the nested one (no row skipped)", True,
          '- [x] top three' in apply_mut(NESTED_PLAN, make_args(tick_plan_n=[3]), []))
# -n 4 is out of range: the section has exactly 3 checkbox rows (top, nested, top),
# so the nested row IS counted (a top-level-only count would make 4 in range here).
_nf = []
apply_mut(NESTED_PLAN, make_args(tick_plan_n=[4]), _nf)
assert_eq("#169 nested-index: -n 4 is out of range (nested fixture has exactly 3 rows)",
          1, len(_nf))
assert_eq("#169 nested-index: the out-of-range descriptor reports the 3-row count", True,
          'section has 3 checkbox row(s)' in _nf[0])

# Re-shadow pr-test Finding 2: the documented substring→index same-row interaction —
# a substring tick processed first makes a later index targeting that SAME row report a
# benign "already ticked" volatile miss (pins both the interaction and the intra-call
# substring-before-index ordering it depends on).
_ft = []
out = apply_mut(IDX_BODY, make_args(status='Reviewing', tick_ac=['AC two'], tick_ac_n=[2]), _ft)
assert_eq("#169 same-row: the substring tick (processed first) ticks AC two", True,
          '- [x] AC two' in out)
assert_eq("#169 same-row: the index targeting the now-ticked same row is a volatile miss", 1, len(_ft))
assert_eq("#169 same-row: the miss is reported as 'already ticked'", True,
          'already ticked' in _ft[0])
assert_eq("#169 same-row: --status still applied (volatile, not abort)", True,
          '🚀 Reviewing' in _statusline(out))


print("workpad notes: compact timestamp + nesting under ## Progress phase")

# Compact timestamp: note bullet renders `  - HH:MM:SS — {note}` (no date/T/Z),
# nested (indented) under its phase.
out = apply_mut(WORKPAD_BODY, make_args(note=['narrowed AC']))
note_line = next(ln for ln in out.splitlines() if '— narrowed AC' in ln)
assert_eq("note: bullet is indented (nested under its phase)", True,
          note_line.startswith('  - '))
ts = note_line.split(' — ')[0].lstrip(' -').strip()
assert_eq("note: timestamp is HH:MM:SS", True,
          bool(re.fullmatch(r'\d{2}:\d{2}:\d{2}', ts)))
assert_eq("note: timestamp has no date / T / Z", True,
          'T' not in ts and 'Z' not in ts and '-' not in ts)

# The note nests under the phase matching the Status (Implementing → Implement):
# it lands inside the Implement block, before the next top-level phase (Review).
prog = out.split('## Plan', 1)[0]
assert_eq("note: Implementing-status note nests under **Implement**", True,
          prog.index('**Implement**') < prog.index('narrowed AC')
          and prog.index('narrowed AC') < prog.index('**Review**'))

# `Last updated` is friendly UTC (YYYY-MM-DD HH:MM UTC), not ISO-8601 — no
# `T` date/time separator and no trailing `Z`.
lu = next(ln for ln in out.splitlines() if ln.startswith('**Last updated:**'))
assert_eq("note: Last updated is friendly UTC (no ISO T-separator / Z)", True,
          bool(re.search(r'\d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC', lu))
          and not re.search(r'\dT\d', lu) and not re.search(r'\dZ', lu))

# Second same-phase note follows the first, still under Implement.
out2 = apply_mut(out, make_args(note=['second note']))
prog2 = out2.split('## Plan', 1)[0]
assert_eq("note: second same-phase note follows the first chronologically", True,
          prog2.index('narrowed AC') < prog2.index('second note'))
assert_eq("note: second same-phase note still before next phase", True,
          prog2.index('second note') < prog2.index('**Review**'))

# Combined --status + --note nests under the POST-mutation Status's phase.
out3 = apply_mut(WORKPAD_BODY, make_args(status='Reviewing', note=['x']))
prog3 = out3.split('## Plan', 1)[0]
assert_eq("note: combined --status/--note nests under NEW status's phase (Review)", True,
          prog3.index('**Review**') < prog3.index('— x')
          and prog3.index('— x') < prog3.index('**Documentation**'))

# Two notes in one call: argument order preserved, both under Implement.
out4 = apply_mut(WORKPAD_BODY, make_args(note=['alpha note', 'beta note']))
prog4 = out4.split('## Plan', 1)[0]
assert_eq("note: two notes in one call preserve argument order", True,
          prog4.index('alpha note') < prog4.index('beta note'))

# Status → phase mapping, incl. the Blocked fallback to the most recent
# *ticked* (completed) top-level phase.
PROGRESS = ("- [x] **Setup** — branch & workpad\n"
            "- [x] **Implement**\n  - [x] code + sweeps\n"
            "- [ ] **Review**\n- [ ] **Documentation**\n- [ ] **PR marked ready**\n")
assert_eq("phase-map: Setup → Setup", "**Setup** — branch & workpad",
          workpad._progress_phase_for_status(PROGRESS, "Setup"))
assert_eq("phase-map: Discovering → Implement", "**Implement**",
          workpad._progress_phase_for_status(PROGRESS, "Discovering"))
assert_eq("phase-map: Reproducing → Implement", "**Implement**",
          workpad._progress_phase_for_status(PROGRESS, "Reproducing"))
assert_eq("phase-map: Planning → Implement", "**Implement**",
          workpad._progress_phase_for_status(PROGRESS, "Planning"))
assert_eq("phase-map: Documenting → Documentation", "**Documentation**",
          workpad._progress_phase_for_status(PROGRESS, "Documenting"))
assert_eq("phase-map: Complete → PR marked ready", "**PR marked ready**",
          workpad._progress_phase_for_status(PROGRESS, "Complete"))
assert_eq("phase-map: Blocked → most recent ticked (completed) phase",
          "**Implement**", workpad._progress_phase_for_status(PROGRESS, "Blocked"))
assert_eq("phase-map: no phases → None", None,
          workpad._progress_phase_for_status("(none yet)\n", "Setup"))
# Graceful-degradation fall-through: a mapped phase ABSENT from the checklist
# (e.g. a template that dropped the Documentation row) falls back to the most
# recent ticked phase rather than returning None / crashing — so the note is
# never dropped.
PROGRESS_NO_DOC = "- [x] **Setup**\n- [x] **Implement**\n- [ ] **Review**\n"
assert_eq("phase-map: mapped phase absent → falls back to last ticked (not None)",
          "**Implement**", workpad._progress_phase_for_status(PROGRESS_NO_DOC, "Documenting"))

# _append_progress_note nests under the matched phase; an unmatched/None phase
# appends flat (un-indented) so a note is never dropped.
nested = workpad._append_progress_note(PROGRESS, "hi", "06:00:00", "**Review**")
rl = next(ln for ln in nested.splitlines() if '— hi' in ln)
assert_eq("append-progress-note: nested under Review, indented", True,
          rl.startswith('  - ') and nested.index('— hi') < nested.index('**Documentation**'))
flat = workpad._append_progress_note(PROGRESS, "orphan", "07:00:00", None)
fl = next(ln for ln in flat.splitlines() if '— orphan' in ln)
assert_eq("append-progress-note: phase=None appends flat (un-indented)", True,
          fl.startswith('- ') and not fl.startswith('  - '))


print("workpad: status glyph / run+PR links / ## Progress / <details>")

# A workpad shaped like the single-comment template: status glyph, Run/PR
# front-matter lines, a ## Progress checklist, and Decisions/Reflection wrapped
# in <details>.
WORKPAD_V2 = """<!-- devflow:workpad -->
# DevFlow Workpad — Issue #999

**Status:** 🚀 Setup
**Branch:** `feat/x`
**Run:** [View run](https://example/run/1)
**PR:** _not yet created_
**Last updated:** 2026-05-15T00:00:00Z

## Progress
- [ ] **Setup** — branch & workpad
- [ ] **Implement**
  - [ ] code + sweeps
- [ ] **Review**
- [ ] **Documentation**
- [ ] **PR marked ready**

## Plan
- [ ] Step alpha

## Acceptance Criteria
- [ ] AC one
- [ ] AC two

## Decisions / Notes
<details>
<summary>Decisions / Notes (click to expand)</summary>

### Setup
- 00:00:00 — run started
</details>

## Devflow Reflection
<details>
<summary>Devflow Reflection (click to expand)</summary>

</details>
"""

# Status glyph: derived from the status word, prepended, idempotent.
assert_eq("glyph: running phase → 🚀", '🚀', workpad._status_glyph('Implementing'))
assert_eq("glyph: Complete → 🎉", '🎉', workpad._status_glyph('Complete'))
assert_eq("glyph: Blocked → 👎", '👎', workpad._status_glyph('Blocked'))
assert_eq("glyph: strips an existing leading glyph", 'Implementing',
          workpad._strip_status_glyph('🚀 Implementing'))

out = apply_mut(WORKPAD_V2, make_args(status='Complete'))
assert_eq("status: glyph applied to Status line", True,
          '**Status:** 🎉 Complete' in out)
# Idempotent: passing a glyph-prefixed status doesn't double up.
out_idem = apply_mut(WORKPAD_V2, make_args(status='🎉 Complete'))
assert_eq("status: re-applying a glyph-prefixed status is idempotent", 1,
          out_idem.count('🎉'))
# A status transition while a note is added nests the note under the matching
# ## Progress phase (Reviewing → Review), keyed on the bare (glyph-stripped)
# post-mutation Status.
out_note = apply_mut(WORKPAD_V2, make_args(status='Reviewing', note=['x']))
prog_note = out_note.split('## Plan', 1)[0]
assert_eq("status+note: note nests under the new status's phase (Review)", True,
          prog_note.index('**Review**') < prog_note.index('— x')
          and prog_note.index('— x') < prog_note.index('**Documentation**'))

# Run / PR links: replace when present.
out = apply_mut(WORKPAD_V2, make_args(
    run_link='[logs](https://example/run/2)', pr_link='[#5](https://example/pr/5)'))
assert_eq("run-link: replaced", True, '**Run:** [logs](https://example/run/2)' in out)
assert_eq("pr-link: replaced", True, '**PR:** [#5](https://example/pr/5)' in out)
assert_eq("run-link: regex-special chars in URL kept literal", True,
          '?a=1&b=2' in apply_mut(
              WORKPAD_V2, make_args(run_link='https://e/r?a=1&b=2')))

# Run / PR links: inserted after Branch when absent (legacy workpad resume).
LEGACY = WORKPAD_V2.replace('**Run:** [View run](https://example/run/1)\n', '') \
                   .replace('**PR:** _not yet created_\n', '')
assert_eq("legacy: no Run/PR lines in fixture", False,
          '**Run:**' in LEGACY or '**PR:**' in LEGACY)
out = apply_mut(LEGACY, make_args(run_link='R', pr_link='P'))
assert_eq("run-link: inserted after Branch when absent", True, '**Run:** R' in out)
assert_eq("pr-link: inserted after Branch when absent", True, '**PR:** P' in out)
assert_eq("inserted links sit between Branch and Last updated", True,
          out.index('**Branch:**') < out.index('**Run:** R')
          and out.index('**PR:** P') < out.index('**Last updated:**'))
# Canonical order preserved when BOTH are inserted in one call: Run before PR.
assert_eq("both-absent insert keeps Run before PR", True,
          out.index('**Run:** R') < out.index('**PR:** P'))
# Resume case: Run already present, only PR inserted → PR lands after Run, not
# above it (regression guard for the insert-after-Branch ordering bug).
RUN_ONLY = WORKPAD_V2.replace('**PR:** _not yet created_\n', '')
out = apply_mut(RUN_ONLY, make_args(pr_link='[#9](u)'))
assert_eq("pr-link inserted after an existing Run line (not above it)", True,
          out.index('**Run:**') < out.index('**PR:** [#9](u)')
          and out.index('**PR:** [#9](u)') < out.index('**Last updated:**'))

# ## Progress ticks (incl. a nested sub-item). Progress shares the substring
# failure-isolation contract (issue #169) but has NO index form (AC 7).
out = apply_mut(WORKPAD_V2, make_args(
    tick_progress=['**Setup**', 'code + sweeps']))
assert_eq("tick-progress: top-level Setup ticked", True,
          '- [x] **Setup**' in out)
assert_eq("tick-progress: nested sub-item ticked", True,
          '- [x] code + sweeps' in out)
# Ambiguous --tick-progress is a volatile miss too: the batched --status survives
# and the miss is collected (pre-#169 this aborted the whole call).
_ft = []
out = apply_mut(WORKPAD_V2, make_args(status='Blocked', tick_progress=['**']), _ft)
assert_eq("ambiguous --tick-progress: status still applied (volatile, not abort)", True,
          '👎 Blocked' in _statusline(out))
assert_eq("ambiguous --tick-progress: collected as a volatile miss", 1, len(_ft))

# Legacy resume: WORKPAD_V2 still carries a pre-change separate ## Decisions /
# Notes section. --note now writes into ## Progress, must NOT error, and must
# leave that legacy section (and its existing bullets) intact (AC: resuming a
# pre-change workpad doesn't error or drop note content).
out = apply_mut(WORKPAD_V2, make_args(status='Implementing', note=['fresh note']))
prog = out.split('## Plan', 1)[0]
assert_eq("legacy-resume: new note nests under ## Progress (Implement phase)", True,
          '— fresh note' in prog
          and prog.index('**Implement**') < prog.index('fresh note'))
assert_eq("legacy-resume: legacy ## Decisions / Notes section preserved", True,
          '## Decisions / Notes' in out)
assert_eq("legacy-resume: existing legacy note content not dropped", True,
          'run started' in out)
# <details>: --reflection appends inside the (initially empty) Reflection block.
out = apply_mut(WORKPAD_V2, make_args(reflection=['reflect!']))
rf = out.split('## Devflow Reflection', 1)[1]
assert_eq("details/reflection: bullet before </details>", True,
          'reflect!' in rf and rf.index('reflect!') < rf.index('</details>'))


print("workpad reflection grouping by --reflection-kind (issue #126)")

# Helper: apply a sequence of (kind, text) reflections as SEPARATE update calls
# (each update carries one --reflection-kind), threading the body forward — this
# is exactly how the orchestrator emits them and exercises the cross-call append
# path. kind=None means --reflection-kind omitted (→ default 'note').
def _reflect_seq(*pairs, body=WORKPAD_V2):
    out = body
    for kind, text in pairs:
        out = apply_mut(
            out, make_args(reflection=[text], reflection_kind=kind))
    return out.split('## Devflow Reflection', 1)[1]

# Each kind renders with its glyph + bold label under the right sub-section.
rk = _reflect_seq(('blocked', 'B'), ('deferred', 'D'), ('dropped-failed', 'F'), ('note', 'N'))
assert_eq("kind blocked: glyph + bold label", True, '- ⛔ **Blocked:** B' in rk)
assert_eq("kind deferred: glyph + bold label", True, '- ⏭️ **Deferred:** D' in rk)
assert_eq("kind dropped-failed: glyph + bold label", True, '- ❗ **Dropped/Failed:** F' in rk)
assert_eq("kind note: glyph + bold label", True, '- ℹ️ **Note:** N' in rk)
# Exactly one of each sub-heading (the 3 actionable kinds share Action required).
assert_eq("one Action required sub-heading (shared by 3 actionable kinds)", 1,
          rk.count('### ⚠️ Action required'))
assert_eq("one Notes sub-heading", 1, rk.count('### ℹ️ Notes'))
# Action required precedes Notes; actionable bullets under it, note under Notes.
assert_eq("Action required precedes Notes", True,
          rk.index('### ⚠️ Action required') < rk.index('### ℹ️ Notes'))
assert_eq("actionable bullet sits under Action required (above Notes heading)", True,
          rk.index('### ⚠️ Action required') < rk.index('- ⛔ **Blocked:** B') < rk.index('### ℹ️ Notes'))
assert_eq("note bullet sits under Notes (below its heading)", True,
          rk.index('### ℹ️ Notes') < rk.index('- ℹ️ **Note:** N'))
# Sub-headings are kept before </details> (stay inside the collapsible block).
assert_eq("grouped sub-sections stay before </details>", True,
          rk.index('### ℹ️ Notes') < rk.index('</details>'))

# Omitted --reflection-kind → note (default), never Action required.
rk_def = _reflect_seq((None, 'defaulted'))
assert_eq("omitted kind renders as note", True, '- ℹ️ **Note:** defaulted' in rk_def)
assert_eq("omitted kind → Notes heading, no Action required heading", True,
          '### ℹ️ Notes' in rk_def and '### ⚠️ Action required' not in rk_def)

# Empty group → no heading: a single blocked emits no Notes heading.
rk_one = _reflect_seq(('blocked', 'only'))
assert_eq("single blocked → Action required heading, no Notes heading (empty group)", True,
          '### ⚠️ Action required' in rk_one and '### ℹ️ Notes' not in rk_one)

# Append second-of-kind nests under the existing heading (no duplicate).
rk_two = _reflect_seq(('note', 'first'), ('note', 'second'))
assert_eq("two notes → single Notes heading (no dup)", 1, rk_two.count('### ℹ️ Notes'))
assert_eq("two notes → both bullets present", 2, rk_two.count('- ℹ️ **Note:**'))
assert_eq("appended bullet stays before </details>", True,
          rk_two.index('- ℹ️ **Note:** second') < rk_two.index('</details>'))
# Two actionable kinds also share one Action required heading.
rk_act = _reflect_seq(('blocked', 'b1'), ('deferred', 'd1'))
assert_eq("blocked+deferred → single shared Action required heading", 1,
          rk_act.count('### ⚠️ Action required'))

# Truncation guard: no level-2 (## ) heading is emitted inside the reflection
# region — fetch-pr-context.sh terminates the parse at the first ## , so a level-2
# sub-heading would truncate reflections[].
_region = rk[:rk.index('</details>')]
assert_eq("no level-2 (## ) heading emitted inside the reflection region", True,
          not any(ln.startswith('## ') for ln in _region.split('\n')))

# Markdown metacharacters survive rendering intact.
_mx = 'has `code`, $VAR, and *stars*'
rk_mx = _reflect_seq(('note', _mx))
assert_eq("metacharacters (backticks/$/*) survive rendering", True,
          ('- ℹ️ **Note:** ' + _mx) in rk_mx)

# Canonical ordering holds regardless of call order: a `note` written BEFORE an
# action-kind bullet still renders Action required ABOVE Notes (exercises the
# _rank insertion branch that places a new Action block above an existing Notes
# block — a plain-append regression would survive every action-first test).
rk_no = _reflect_seq(('note', 'N'), ('blocked', 'B'))
assert_eq("note-first then blocked → Action required still precedes Notes", True,
          rk_no.index('### ⚠️ Action required') < rk_no.index('### ℹ️ Notes'))
assert_eq("note-first then blocked → both bullets present", True,
          '- ⛔ **Blocked:** B' in rk_no and '- ℹ️ **Note:** N' in rk_no)

# Multi-line reflection text (e.g. a captured multi-line gh/jq error fed into a
# dropped-failed breadcrumb) collapses to a single bullet line, so the line-based
# fetch-pr-context.sh parser captures the whole message, not just its first line.
rk_ml = _reflect_seq(('dropped-failed', 'line one\nline two\nline three'))
assert_eq("multi-line reflection text collapses to one bullet line", True,
          '- ❗ **Dropped/Failed:** line one line two line three' in rk_ml)
assert_eq("multi-line reflection emits exactly one bullet (no split continuation)", 1,
          rk_ml.count('- ❗ **Dropped/Failed:**'))

# Distinguish the UNCONDITIONAL splitlines() collapse from the old `if '\n' in
# text` guard: a bare \r (or \v) line break — which the old guard let slip
# through to the line-based fetch parser — must also collapse to one bullet line.
# (A regression reverting to the `\n`-only guard would pass the \n test above but
# fail this one.)
rk_cr = _reflect_seq(('dropped-failed', 'cr one\rcr two'))
assert_eq("bare \\r in reflection text also collapses to one bullet line", True,
          '- ❗ **Dropped/Failed:** cr one cr two' in rk_cr)
assert_eq("bare \\r reflection emits exactly one bullet (no split continuation)", 1,
          rk_cr.count('- ❗ **Dropped/Failed:**'))

# Mid-migration shape: a workpad whose reflection block already holds a
# pre-migration un-kinded flat bullet, into which a new kinded bullet is then
# appended (a real DevFlow workpad created before this PR and updated after it).
# The legacy bullet is retained verbatim as a leading preamble, ABOVE the
# lazily-created sub-section (per _insert_reflection_bullet's docstring contract).
_LEGACY_REFLECTION_BODY = """<!-- devflow:workpad -->
# DevFlow Workpad — Issue #999

**Status:** Reviewing
**Last updated:** 2026-01-01 00:00 UTC

## Progress
- [x] **Setup**

## Devflow Reflection
<details>
<summary>Devflow Reflection (click to expand)</summary>

- a legacy flat bullet
</details>
"""
_legacy_out = apply_mut(
    _LEGACY_REFLECTION_BODY, make_args(reflection=['boom'], reflection_kind='blocked'))
_legacy_rf = _legacy_out.split('## Devflow Reflection', 1)[1]
assert_eq("legacy flat bullet retained verbatim when a kinded bullet is appended", True,
          '- a legacy flat bullet' in _legacy_rf)
assert_eq("legacy bullet stays ABOVE the lazily-created Action required sub-section", True,
          _legacy_rf.index('- a legacy flat bullet') < _legacy_rf.index('### ⚠️ Action required'))
assert_eq("new kinded bullet renders correctly under Action required (mixed shape)", True,
          '- ⛔ **Blocked:** boom' in _legacy_rf)
assert_eq("mixed-shape output stays inside the <details> (bullet before </details>)", True,
          _legacy_rf.index('- ⛔ **Blocked:** boom') < _legacy_rf.index('</details>'))

# Un-wrapped (no <details>) reflection section — the _append_reflection
# `head is None` branch. cmd_new_body always emits <details>, so this only fires
# on a hand-edited / pre-<details> workpad, but the branch exists and must group
# the bullet in place rather than dropping content.
_UNWRAPPED_REFLECTION_BODY = """<!-- devflow:workpad -->
# DevFlow Workpad — Issue #999

**Status:** Reviewing
**Last updated:** 2026-01-01 00:00 UTC

## Progress
- [x] **Setup**

## Devflow Reflection
"""
_unwrapped_out = apply_mut(
    _UNWRAPPED_REFLECTION_BODY, make_args(reflection=['boom'], reflection_kind='dropped-failed'))
_unwrapped_rf = _unwrapped_out.split('## Devflow Reflection', 1)[1]
assert_eq("un-wrapped (no <details>) reflection section groups the bullet in place", True,
          '### ⚠️ Action required' in _unwrapped_rf
          and '- ❗ **Dropped/Failed:** boom' in _unwrapped_rf)

# Mirror of the note-first test: an action block created first, then a note —
# exercises the append-at-end insertion branch with a pre-existing earlier-ranked
# block (a Notes-before-Action regression would survive without this).
rk_an = _reflect_seq(('blocked', 'B'), ('note', 'N'))
assert_eq("action-first then note → Action required still precedes Notes", True,
          rk_an.index('### ⚠️ Action required') < rk_an.index('### ℹ️ Notes'))

# A bad reflection kind from a programmatic caller is converted to a clean
# _UpdateError (caught by cmd_update before the PATCH — no partial workpad
# write), not a bare KeyError traceback. argparse `choices` guards the CLI path;
# this guards the direct-_apply_mutations path the tests themselves use.
def _bad_reflection_kind():
    apply_mut(
        WORKPAD_V2, make_args(reflection=['x'], reflection_kind='bogus'))
assert_raises("bad reflection kind raises _UpdateError (not a bare KeyError)",
              workpad._UpdateError, _bad_reflection_kind)

# Invariants preserved: marker first line; AC section still parseable.
out = apply_mut(WORKPAD_V2, make_args(
    status='Reviewing', note=['n'], reflection=['r'], tick_ac=['AC one']))
assert_eq("invariant: marker is still the first line", True,
          out.startswith('<!-- devflow:workpad -->'))
assert_eq("invariant: ## Acceptance Criteria still present and before Devflow Reflection",
          True, '## Acceptance Criteria' in out
          and out.index('## Acceptance Criteria') < out.index('## Devflow Reflection'))
_ac = parse_acs._parse_checkboxes(
    parse_acs._extract_section(out, 'Acceptance Criteria'))
assert_eq("invariant: AC section parses to 2 checkboxes after mutation", 2, len(_ac))
assert_eq("invariant: AC one ticked is visible to the parser", True,
          any(i['text'] == 'AC one' and i['ticked'] for i in _ac))


print("workpad new-body: lean initial skeleton")

_buf = io.StringIO()
with contextlib.redirect_stdout(_buf):
    workpad.cmd_new_body(argparse.Namespace(
        issue=7, run_link='[View run](https://x/1)', branch=None, marker=None))
_nb = _buf.getvalue()
assert_eq("new-body: starts with the workpad marker", True,
          _nb.startswith(workpad._workpad_marker()))
assert_eq("new-body: Status is 🚀 Setup", True, '**Status:** 🚀 Setup' in _nb)
assert_eq("new-body: friendly Last updated (no T / Z)", True,
          bool(re.search(r'\*\*Last updated:\*\* \d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC', _nb)))
assert_eq("new-body: Branch placeholder", True, '**Branch:** _(creating' in _nb)
assert_eq("new-body: run link applied", True, '[View run](https://x/1)' in _nb)
assert_eq("new-body: has ## Progress checklist", True,
          '## Progress' in _nb and '**Setup**' in _nb)
assert_eq("new-body: run-started note nested (indented) under Setup", True,
          '  - ' in _nb and '/devflow:implement run started' in _nb)
assert_eq("new-body: Plan + AC are placeholders (not populated)", True,
          '_(planning in progress)_' in _nb and '_(pending' in _nb)
assert_eq("new-body: no separate Decisions / Notes section", False,
          '## Decisions / Notes' in _nb)
# Map ↔ template drift guard: every canonical phase (and therefore every value
# the Status→phase map resolves to) must substring-match a top-level row that
# the new-body template actually emits — otherwise a phase rename in one place
# misfiles notes silently. This is the cross-boundary check the import-time
# assert (map ⊆ _PROGRESS_PHASES) can't make on its own.
_nb_rows = [m.group(2) for line in _nb.split('## Plan', 1)[0].split('\n')
            if (m := workpad._TOP_LEVEL_CHECKBOX_RE.match(line))]
for _ph in workpad._PROGRESS_PHASES:
    assert_eq(f"new-body template emits a top-level row matching phase {_ph!r}", True,
              any(_ph.lower() in _r.lower() for _r in _nb_rows))
# The skeleton round-trips through the mutation engine (gate creates it, the
# claude job then mutates the same comment).
_rt = apply_mut(_nb, make_args(tick_progress=['**Setup**'], note=['go']))
assert_eq("new-body: skeleton accepts --tick-progress + --note", True,
          '- [x] **Setup**' in _rt and '— go' in _rt)
# --branch fills the Branch line in backticks instead of the placeholder.
_buf2 = io.StringIO()
with contextlib.redirect_stdout(_buf2):
    workpad.cmd_new_body(argparse.Namespace(issue=7, run_link=None, branch='issue-7-x', marker=None))
_nb2 = _buf2.getvalue()
assert_eq("new-body: --branch fills Branch line", True, '**Branch:** `issue-7-x`' in _nb2)
assert_eq("new-body: omitted --run-link → local placeholder", True,
          '**Run:** _(local run)_' in _nb2)
# --no-reproduction omits the bug-only sub-item (non-bug issues) without
# disturbing the rest of the Implement phase. The default (no flag) keeps it, so
# the label-agnostic gate job is unaffected.
assert_eq("new-body: reproduction sub-item present by default", True,
          'reproduction captured (bug issues only)' in _nb)
_buf3 = io.StringIO()
with contextlib.redirect_stdout(_buf3):
    workpad.cmd_new_body(argparse.Namespace(
        issue=7, run_link=None, branch=None, marker=None, no_reproduction=True))
_nb3 = _buf3.getvalue()
assert_eq("new-body: --no-reproduction omits the bug-only sub-item", False,
          'reproduction captured' in _nb3)
assert_eq("new-body: --no-reproduction keeps code + sweeps under Implement", True,
          '**Implement**' in _nb3 and '- [ ] code + sweeps' in _nb3)


print("parse_acs._is_post_merge")

# True positives — the new workflow/bot-trigger phrases.
for phrase in [
    "Verify the workflow runs on a live PR",
    "Check the artifact link in the workflow run",
    "Comment /screenshot on a PR and confirm",
    "Trigger the bot on a real PR",
    "After merge, comment on the PR to retest",
    "Maintainer should comment on a PR with /screenshot",
]:
    assert_eq(f"post-merge: {phrase!r}", True, parse_acs._is_post_merge(phrase))

# False positives — must NOT match.
for phrase in [
    "Sentry error monitoring is configured",            # `monitor` substring
    "Errors must not be silently swallowed",            # no trigger
    "Add unit tests for the click handler",             # `click` substring
    "Document the CI workflow runner image",            # `workflow runner` — not `workflow run`
    "Note: this is commenting on a previous decision",  # `comment` inside `commenting`, no PR phrase
]:
    assert_eq(f"NOT post-merge: {phrase!r}", False, parse_acs._is_post_merge(phrase))


print("parse_acs._extract_section / _parse_checkboxes / _render_md")

AC_BODY = """## Summary
intro text

## Acceptance Criteria
- [ ] first
- [x] second done
* [ ] star bullet
not a checkbox line
#### sub-note (deeper heading — must NOT terminate the section)
- [ ] after subheading

## Notes
- [ ] should not appear
"""

_items = parse_acs._parse_checkboxes(parse_acs._extract_section(AC_BODY, 'Acceptance Criteria'))
assert_eq("extract: 4 AC checkboxes (deeper heading does not terminate)", 4, len(_items))
assert_eq("extract: first text", 'first', _items[0]['text'])
assert_eq("extract: second ticked", True, _items[1]['ticked'])
assert_eq("extract: '* ' bullet variant parsed", 'star bullet', _items[2]['text'])
assert_eq("extract: stops at sibling '## Notes' (excluded)", False,
          any(i['text'] == 'should not appear' for i in _items))

# Case-insensitive, level-bounded heading match — the silent-miss guards.
# Casing is forgiven, but a trailing colon / wrong level still must not match.
assert_eq("extract: lowercase heading → matches (case-insensitive)", 4,
          len(parse_acs._parse_checkboxes(parse_acs._extract_section(
              AC_BODY.replace('## Acceptance Criteria', '## acceptance criteria'),
              'Acceptance Criteria'))))
assert_eq("extract: uppercase heading → matches (case-insensitive)", 4,
          len(parse_acs._parse_checkboxes(parse_acs._extract_section(
              AC_BODY.replace('## Acceptance Criteria', '## ACCEPTANCE CRITERIA'),
              'Acceptance Criteria'))))
assert_eq("extract: trailing-colon heading → no section", [],
          parse_acs._extract_section(
              AC_BODY.replace('## Acceptance Criteria', '## Acceptance Criteria:'),
              'Acceptance Criteria'))
assert_eq("extract: level-3 heading matches", 1,
          len(parse_acs._parse_checkboxes(
              parse_acs._extract_section("### Acceptance Criteria\n- [ ] x\n",
                                         'Acceptance Criteria'))))
assert_eq("extract: level-4 heading not matched (only ##/###)", 0,
          len(parse_acs._extract_section("#### Acceptance Criteria\n- [ ] x\n",
                                         'Acceptance Criteria')))

assert_eq("render_md: empty → sentinel", '_(none provided in issue body)_',
          parse_acs._render_md([], []))
assert_eq("render_md: post-merge tag appended", True,
          parse_acs._render_md(
              [{'text': 'do X after merge', 'ticked': False, 'post_merge': True}], []
          ).endswith('(post-merge)'))
assert_eq("render_md: no double post-merge tag", 1,
          parse_acs._render_md(
              [{'text': 'already (post-merge)', 'ticked': True, 'post_merge': True}], []
          ).count('(post-merge)'))
assert_eq("render_md: ticked box rendered", True,
          parse_acs._render_md(
              [{'text': 't', 'ticked': True, 'post_merge': False}], []
          ).startswith('- [x]'))
assert_eq("render_md: test plan appended after blank line", True,
          '\n\n- [ ] b' in parse_acs._render_md(
              [{'text': 'a', 'ticked': False, 'post_merge': False}],
              [{'text': 'b', 'ticked': False, 'post_merge': False}]))


print("file_deferrals._derive_area / _compute_id / _format_line_range / _render_issue_body")

assert_eq("derive_area: src/example/transport/http.py → example", 'example',
          file_deferrals._derive_area('src/example/transport/http.py'))
assert_eq("derive_area: src/transport/http.py → transport", 'transport',
          file_deferrals._derive_area('src/transport/http.py'))
assert_eq("derive_area: lib/ is src-like → next segment", 'transport',
          file_deferrals._derive_area('lib/transport/x.py'))
assert_eq("derive_area: pyproject.toml → stem (no dir)", 'pyproject',
          file_deferrals._derive_area('pyproject.toml'))
assert_eq("derive_area: scripts/foo/bar.sh → first segment", 'scripts',
          file_deferrals._derive_area('scripts/foo/bar.sh'))

_e1 = {'file': 'a.py', 'symbol': 'foo', 'kind': 'bug', 'summary': '  bad thing  '}
_e1_stripped = {'file': 'a.py', 'symbol': 'foo', 'kind': 'bug', 'summary': 'bad thing'}
assert_eq("compute_id: 'dfr-' prefix", True,
          file_deferrals._compute_id(_e1).startswith('dfr-'))
assert_eq("compute_id: length = prefix + 6 hex", 10, len(file_deferrals._compute_id(_e1)))
assert_eq("compute_id: deterministic across calls",
          file_deferrals._compute_id(_e1), file_deferrals._compute_id(_e1))
assert_eq("compute_id: summary stripped before hashing",
          file_deferrals._compute_id(_e1), file_deferrals._compute_id(_e1_stripped))
assert_eq("compute_id: differs when summary differs", False,
          file_deferrals._compute_id(_e1)
          == file_deferrals._compute_id(dict(_e1, summary='different')))

assert_eq("format_line_range: equal start/end → single", '5',
          file_deferrals._format_line_range([5, 5]))
assert_eq("format_line_range: distinct → range", '3-9',
          file_deferrals._format_line_range([3, 9]))
assert_eq("format_line_range: tuple accepted", '1-2',
          file_deferrals._format_line_range((1, 2)))
assert_eq("format_line_range: None → (unspecified)", '(unspecified)',
          file_deferrals._format_line_range(None))
assert_eq("format_line_range: wrong arity → (unspecified)", '(unspecified)',
          file_deferrals._format_line_range([1]))

_body = file_deferrals._render_issue_body(
    [{'severity': 'High', 'agent': 'sec', 'file': 'a.py', 'line_range': [1, 2],
      'symbol': 'foo', 'kind': 'bug', 'summary': 'x', 'category': 'scope',
      'explanation': 'later'}],
    source_issue=40, pr_number=77)
assert_eq("render_issue_body: 'PR #77' cross-link substring present", True, 'PR #77' in _body)
assert_eq("render_issue_body: references source issue #40", True, '#40' in _body)
assert_eq("render_issue_body: severity/agent heading", True, '### High — sec' in _body)
assert_eq("render_issue_body: file:line-range", True, 'a.py:1-2' in _body)

print("file_deferrals._create_issue (#245: OSError from an unrunnable gh must "
      "raise RuntimeError, not a raw traceback)")

# _create_issue's non-dry-run path must convert a real OSError (unrunnable gh
# shim / absent binary) into RuntimeError with an actionable message, per its
# own docstring contract ("Raises on failure") — never let the bare OSError
# escape uncaught.
_saved_sp_run = file_deferrals.subprocess.run
try:
    def _boom_oserror(*a, **kw):
        raise OSError(8, "Exec format error")
    file_deferrals.subprocess.run = _boom_oserror
    _raised_runtime_error = False
    try:
        file_deferrals._create_issue("t", "b", dry_run=False)
    except RuntimeError as e:
        _raised_runtime_error = True
        _msg = str(e)
    except OSError:
        _raised_runtime_error = False
        _msg = ""
    assert_eq("create_issue: unrunnable gh (OSError) → RuntimeError, not a bare OSError",
              True, _raised_runtime_error)
    assert_eq("create_issue: RuntimeError message names the resolved gh and the escape hatch",
              True, ("DEVFLOW_GH" in _msg))
finally:
    file_deferrals.subprocess.run = _saved_sp_run

# dry_run=True must short-circuit before ever calling subprocess.run — confirms
# the OSError path above genuinely exercises the real (non-dry-run) branch.
_saved_sp_run = file_deferrals.subprocess.run
try:
    file_deferrals.subprocess.run = lambda *a, **kw: (_ for _ in ()).throw(
        AssertionError("dry_run must not invoke subprocess.run"))
    _num, _url = file_deferrals._create_issue("t", "b", dry_run=True)
    assert_eq("create_issue: dry_run short-circuits before subprocess.run", True,
              _url.startswith("https://example.invalid/"))
finally:
    file_deferrals.subprocess.run = _saved_sp_run


print("match_deferrals._extract_block / _parse_yaml_payload (hidden-comment payload)")

# New-format PR body: a human-readable Markdown table is the VISIBLE content
# inside the START/END markers, and the exact machine payload lives in a hidden
# DEVFLOW_DEFERRED_PAYLOAD HTML comment (invisible in rendered Markdown). The
# matcher must parse the payload from the hidden comment, not the visible table.
NEW_FORMAT_BODY = """## Summary
- did a thing

## Deferred Findings
<!-- DEVFLOW_DEFERRED_FINDINGS_START -->
These review-agent findings were deferred under the Scope-Acknowledged Findings contract.

| Severity | File | Finding | Follow-up |
| --- | --- | --- | --- |
| Important | `a.py:10-12` | thing one | #41 |
| Suggestion | `b.py:5-5` | thing two (no issue) | — |

<!-- DEVFLOW_DEFERRED_PAYLOAD
schema_version: 1
deferrals:
  - id: dfr-aaa111
    finding:
      agent: code-reviewer
      severity: Important
      file: a.py
      line_range: [10, 12]
      symbol: foo
      kind: bug
      summary: |
        thing one
    reason:
      category: out-of-scope
      explanation: |
        later
    follow_up:
      issue: 41
      url: https://example/issues/41
      filed_at: 2026-05-26T00:00:00Z
      filed_by: claude
  - id: dfr-bbb222
    finding:
      agent: code-reviewer
      severity: Suggestion
      file: b.py
      line_range: [5, 5]
      symbol: bar
      kind: style
      summary: |
        thing two
    reason:
      category: claim-quality
      explanation: |
        minor
    follow_up: {}
-->
<!-- DEVFLOW_DEFERRED_FINDINGS_END -->

## Test Plan
- [ ] run it
"""

_blk = match_deferrals._extract_block(NEW_FORMAT_BODY)
assert_eq("extract_block: block found between markers", True, _blk is not None)
assert_eq("extract_block: visible table is inside the block", True, '| Severity |' in _blk)
_payload = match_deferrals._parse_yaml_payload(_blk)
_deferrals = _payload.get("deferrals") or []
assert_eq("parse_payload: schema_version preserved", 1, _payload.get("schema_version"))
assert_eq("parse_payload: both deferrals extracted from hidden comment", 2, len(_deferrals))
assert_eq("parse_payload: first id", "dfr-aaa111", _deferrals[0].get("id"))
assert_eq("parse_payload: first finding file", "a.py",
          _deferrals[0].get("finding", {}).get("file"))
assert_eq("parse_payload: first follow_up issue is int", 41,
          _deferrals[0].get("follow_up", {}).get("issue"))
# Entry missing follow_up.issue parses fine here — main()'s loop records it under
# rejected_deferrals with REASON_MISSING_FOLLOW_UP_ISSUE (never honored, but the run
# does not fail); this asserts the data round-trips through extraction.
assert_eq("parse_payload: second entry has no follow_up.issue", None,
          (_deferrals[1].get("follow_up") or {}).get("issue"))

# The visible table is NOT mistaken for the payload — a body whose block has a
# table but no hidden payload comment degrades to an empty dict (no crash).
_no_payload = """<!-- DEVFLOW_DEFERRED_FINDINGS_START -->
| Severity | File | Finding | Follow-up |
| --- | --- | --- | --- |
| Important | `a.py:1-2` | x | #9 |
<!-- DEVFLOW_DEFERRED_FINDINGS_END -->"""
assert_eq("parse_payload: block with table but no hidden payload → {}", {},
          match_deferrals._parse_yaml_payload(
              match_deferrals._extract_block(_no_payload)))

# Absent block → _extract_block returns None (matcher reports block_present:false,
# no run failure).
assert_eq("extract_block: no markers at all → None", None,
          match_deferrals._extract_block("a PR body with no deferrals section"))

# A payload comment whose YAML is a non-mapping (list/scalar) must degrade to {} —
# main() then reads payload.get("deferrals") on a dict and never AttributeErrors on
# a structurally-wrong-but-valid-YAML payload.
_nonmap_payload = """<!-- DEVFLOW_DEFERRED_FINDINGS_START -->
<!-- DEVFLOW_DEFERRED_PAYLOAD
- just
- a
- list
-->
<!-- DEVFLOW_DEFERRED_FINDINGS_END -->"""
assert_eq("parse_payload: non-mapping YAML payload → {}", {},
          match_deferrals._parse_yaml_payload(
              match_deferrals._extract_block(_nonmap_payload)))

# An empty/whitespace-only payload comment (renderer emitted the shell but no body)
# → {} (loaded is None path), so main()'s payload.get("deferrals") stays safe.
_empty_payload = """<!-- DEVFLOW_DEFERRED_FINDINGS_START -->
<!-- DEVFLOW_DEFERRED_PAYLOAD

-->
<!-- DEVFLOW_DEFERRED_FINDINGS_END -->"""
assert_eq("parse_payload: empty payload comment → {}", {},
          match_deferrals._parse_yaml_payload(
              match_deferrals._extract_block(_empty_payload)))

print("match_deferrals._check_issue_cross_link (#245: gh-exec-failure vs. genuine "
      "issue-unreadable must not be conflated)")

# _check_issue_cross_link must no longer silently treat _run's OSError sentinel
# (CompletedProcess(cmd, 127, stdout="", stderr=str(e))) the same as a genuine
# gh/GitHub failure (404, permission, rate limit) — an unusable gh invalidates
# the whole matching run and must fail loudly via _fail() (sys.exit), not just
# return REASON_ISSUE_UNREADABLE and discard the diagnostic.
_saved_run = match_deferrals._run
try:
    match_deferrals._run = lambda cmd, **kw: match_deferrals.subprocess.CompletedProcess(
        cmd, 127, stdout="", stderr="[Errno 8] Exec format error: 'gh'")
    _exited = False
    _exit_code = None
    try:
        match_deferrals._check_issue_cross_link(9, 1)
    except SystemExit as e:
        _exited = True
        _exit_code = e.code
    assert_eq("check_issue_cross_link: OSError sentinel (rc=127, empty stdout) → fails loudly (SystemExit)",
              True, _exited)
    assert_eq("check_issue_cross_link: OSError sentinel → non-zero exit code", True,
              bool(_exit_code))
finally:
    match_deferrals._run = _saved_run

# A genuine gh/GitHub failure (non-127 rc, e.g. 404/permission) must still
# degrade gracefully to REASON_ISSUE_UNREADABLE — this is NOT the OSError path,
# so it must not raise/exit.
_saved_run = match_deferrals._run
try:
    match_deferrals._run = lambda cmd, **kw: match_deferrals.subprocess.CompletedProcess(
        cmd, 1, stdout="", stderr="HTTP 404: Not Found")
    _reason = match_deferrals._check_issue_cross_link(9, 1)
    assert_eq("check_issue_cross_link: genuine gh failure (rc=1) → REASON_ISSUE_UNREADABLE (degrades, no exit)",
              match_deferrals.REASON_ISSUE_UNREADABLE, _reason)
finally:
    match_deferrals._run = _saved_run

# rc==127 with NON-empty stdout is not the OSError sentinel shape (_run's sentinel
# always pairs 127 with empty stdout) — must not be misclassified as an exec
# failure and must degrade gracefully like any other genuine non-zero rc.
_saved_run = match_deferrals._run
try:
    match_deferrals._run = lambda cmd, **kw: match_deferrals.subprocess.CompletedProcess(
        cmd, 127, stdout="some output", stderr="")
    _reason = match_deferrals._check_issue_cross_link(9, 1)
    assert_eq("check_issue_cross_link: rc=127 with non-empty stdout (not the OSError shape) → degrades, no exit",
              match_deferrals.REASON_ISSUE_UNREADABLE, _reason)
finally:
    match_deferrals._run = _saved_run

# The 3 tests above monkeypatch _run itself to hand _check_issue_cross_link a
# pre-built sentinel — they never confirm _run() itself actually PRODUCES that
# (127, empty-stdout) shape from a real OSError. Exercise the real subprocess.run
# call so a regression in _run's own except-OSError block (wrong rc, non-empty
# stdout, wrong exception class) is caught here rather than only in the mocked
# classification tests above.
_saved_sp_run = match_deferrals.subprocess.run
try:
    def _boom_oserror(*a, **kw):
        raise OSError(8, "Exec format error")
    match_deferrals.subprocess.run = _boom_oserror
    _r = match_deferrals._run(["gh-does-not-matter"], check=False)
    assert_eq("_run: real OSError (check=False) → sentinel returncode is 127",
              127, _r.returncode)
    assert_eq("_run: real OSError (check=False) → sentinel stdout is empty",
              "", _r.stdout)
    assert_eq("_run: real OSError (check=False) → stderr carries the exception text",
              True, "Exec format error" in _r.stderr)
finally:
    match_deferrals.subprocess.run = _saved_sp_run

print("match_deferrals._config_get (#245: a broken config-get.sh must not be "
      "silently indistinguishable from a legitimately-unset key)")

# A broken config-get.sh (OSError sentinel: rc=127, empty stdout) must log a
# breadcrumb so an operator can tell "the helper couldn't execute" apart from
# "the key just isn't set" — both otherwise silently return `default`.
_saved_run = match_deferrals._run
try:
    match_deferrals._run = lambda cmd, **kw: match_deferrals.subprocess.CompletedProcess(
        cmd, 127, stdout="", stderr="[Errno 8] Exec format error")
    _stderr_capture = io.StringIO()
    with contextlib.redirect_stderr(_stderr_capture):
        _val = match_deferrals._config_get("some.key", "fallback")
    assert_eq("config_get: OSError sentinel → still returns the default (no raise)",
              "fallback", _val)
    assert_eq("config_get: OSError sentinel → logs a breadcrumb naming config-get.sh",
              True, "config-get.sh" in _stderr_capture.getvalue())
finally:
    match_deferrals._run = _saved_run

# A genuine non-zero rc (config-get.sh ran fine but the key/file doesn't exist)
# must NOT log the broken-helper breadcrumb — that would be a false alarm on
# the ordinary, expected "key not found" path.
_saved_run = match_deferrals._run
try:
    match_deferrals._run = lambda cmd, **kw: match_deferrals.subprocess.CompletedProcess(
        cmd, 1, stdout="", stderr="")
    _stderr_capture = io.StringIO()
    with contextlib.redirect_stderr(_stderr_capture):
        _val = match_deferrals._config_get("some.key", "fallback")
    assert_eq("config_get: ordinary non-zero rc → returns the default", "fallback", _val)
    assert_eq("config_get: ordinary non-zero rc → does NOT log the broken-helper breadcrumb",
              False, "could not execute" in _stderr_capture.getvalue())
finally:
    match_deferrals._run = _saved_run


# ---------------------------------------------------------------------------
# resolve_review_overrides.resolve_overrides — per-subagent model/effort
# overrides for the /devflow:review engine. Covers the four AC cases: specific
# entry wins, default-fallback, no-entry (no override emitted), and invalid
# effort (warn + drop to session effort, model still forwarded).
# ---------------------------------------------------------------------------
_rro = resolve_review_overrides

# Specific entry wins over default; default supplies only no-entry agents.
_raw = {
    "default": {"effort": "medium"},
    "devflow:code-reviewer": {"model": "claude-opus-4-8", "effort": "high"},
    "devflow:checklist-deduper": {"model": "claude-haiku-4-5-20251001", "effort": "low"},
}
_res, _warn = _rro.resolve_overrides(
    _raw,
    ["devflow:code-reviewer", "devflow:checklist-deduper",
     "devflow:checklist-verifier"],
)
assert_eq("resolve: specific code-reviewer entry wins",
          {"model": "claude-opus-4-8", "effort": "high"},
          _res["devflow:code-reviewer"])
assert_eq("resolve: specific deduper entry wins",
          {"model": "claude-haiku-4-5-20251001", "effort": "low"},
          _res["devflow:checklist-deduper"])
assert_eq("resolve: no-entry agent falls back to default",
          {"effort": "medium"}, _res["devflow:checklist-verifier"])
assert_eq("resolve: specific entry does NOT inherit default fields (no warnings)",
          [], _warn)

# default does NOT backfill missing fields of an agent that has its own entry:
# code-reviewer below has only a model, default has effort — effort must NOT leak in.
_res2, _ = _rro.resolve_overrides(
    {"default": {"effort": "max"},
     "devflow:code-reviewer": {"model": "m"}},
    ["devflow:code-reviewer"],
)
assert_eq("resolve: own entry is used whole (no default backfill of effort)",
          {"model": "m"}, _res2["devflow:code-reviewer"])

# No entry and no default → no override emitted for that agent.
_res3, _ = _rro.resolve_overrides({}, ["devflow:code-reviewer"])
assert_eq("resolve: no entry + no default → empty override map", {}, _res3)

# Invalid effort → warning + drop effort (fall back to session); model forwarded.
_res4, _warn4 = _rro.resolve_overrides(
    {"devflow:code-reviewer": {"model": "m", "effort": "turbo"}},
    ["devflow:code-reviewer"],
)
assert_eq("resolve: invalid effort dropped, model forwarded",
          {"model": "m"}, _res4["devflow:code-reviewer"])
assert_eq("resolve: invalid effort emits exactly one warning", 1, len(_warn4))

# An entry that resolves to neither a model nor a valid effort emits no override.
_res5, _ = _rro.resolve_overrides(
    {"devflow:code-reviewer": {"effort": "bogus"}},
    ["devflow:code-reviewer"],
)
assert_eq("resolve: entry with only-invalid-effort emits no override", {}, _res5)

# A present-but-empty own entry still counts as "has an entry" — default must not apply.
_res6, _ = _rro.resolve_overrides(
    {"default": {"effort": "high"}, "devflow:checklist-verifier": {}},
    ["devflow:checklist-verifier"],
)
assert_eq("resolve: empty own entry shadows default → no override", {}, _res6)

# read_raw integration (exercises the real config-get.sh I/O path, not just the
# pure resolver). The empty-own-entry contract must hold END-TO-END: the leaf
# reads alone can't tell {} from an absent key, so read_raw probes the entry
# object — this test guards that the probe stays wired (a pure-function test
# alone would pass while the real config path silently let `default` backfill).
import os as _os  # noqa: E402
import tempfile as _tempfile  # noqa: E402
_config_get_sh = str(SCRIPTS / 'config-get.sh')
with _tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as _cf:
    _cf.write(
        '{"devflow_review":{"agent_overrides":{'
        '"default":{"effort":"high"},'
        '"devflow:checklist-verifier":{},'
        '"devflow:code-reviewer":{"model":"m","effort":"low"}}}}'
    )
    _cfg_path = _cf.name
try:
    _rr_raw, _rr_warn = _rro.read_raw(
        ["devflow:checklist-verifier", "devflow:code-reviewer",
         "devflow:comment-analyzer"],
        _config_get_sh, _cfg_path,
    )
    assert_eq("read_raw: present-but-empty entry is represented as {} (shadows default)",
              {}, _rr_raw.get("devflow:checklist-verifier"))
    assert_eq("read_raw: full entry's fields are read",
              {"model": "m", "effort": "low"},
              _rr_raw.get("devflow:code-reviewer"))
    assert_eq("read_raw: absent agent is not added to raw",
              False, "devflow:comment-analyzer" in _rr_raw)
    assert_eq("read_raw: default entry is read", {"effort": "high"},
              _rr_raw.get("default"))
    assert_eq("read_raw: well-formed config yields no warnings", [], _rr_warn)
    # End-to-end resolution off the real config path: empty entry must NOT inherit default.
    _e2e, _ = _rro.resolve_overrides(_rr_raw, ["devflow:checklist-verifier"])
    assert_eq("read_raw+resolve: empty entry shadows default end-to-end", {}, _e2e)
finally:
    _os.unlink(_cfg_path)

# read_raw on a malformed config must NOT silently swallow the parse error: it
# returns no overrides AND surfaces a warning (config-get.sh exits 2), rather
# than collapsing the parse failure to a silent "no overrides".
with _tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as _bcf:
    _bcf.write('{"devflow_review": {"agent_overrides": {  BROKEN')
    _bad_cfg = _bcf.name
try:
    _braw, _bwarn = _rro.read_raw(
        ["devflow:code-reviewer"], _config_get_sh, _bad_cfg)
    assert_eq("read_raw: malformed config yields no overrides", {}, _braw)
    assert_eq("read_raw: malformed config surfaces a warning (not silent)",
              True, len(_bwarn) >= 1)
    assert_eq("read_raw: malformed-config warnings are deduped (one line, not per-read)",
              1, len(_bwarn))
finally:
    _os.unlink(_bad_cfg)

# A non-object entry hand-edited into the config (e.g. `"agent": "high"`) must,
# on the REAL config-get.sh path, be detected and warned — NOT silently coerced
# to a present-but-empty {} that shadows `default`. read_raw distinguishes the
# object sentinel from a scalar/array stringification.
with _tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as _nocf:
    _nocf.write(
        '{"devflow_review":{"agent_overrides":{'
        '"default":{"effort":"high"},'
        '"devflow:code-reviewer":"high",'
        '"devflow:comment-analyzer":["a","b"]}}}'
    )
    _no_cfg = _nocf.name
try:
    _noraw, _nowarn = _rro.read_raw(
        ["devflow:code-reviewer", "devflow:comment-analyzer"],
        _config_get_sh, _no_cfg)
    assert_eq("read_raw: scalar entry is NOT coerced to {} (treated as no-entry)",
              False, "devflow:code-reviewer" in _noraw)
    assert_eq("read_raw: array entry is NOT coerced to {} (treated as no-entry)",
              False, "devflow:comment-analyzer" in _noraw)
    assert_eq("read_raw: each non-object entry surfaces a warning",
              2, len([w for w in _nowarn if "is not an object" in w]))
    # Since the malformed entries are treated as no-entry, `default` applies.
    _no_e2e, _ = _rro.resolve_overrides(_noraw, ["devflow:code-reviewer"])
    assert_eq("read_raw+resolve: non-object entry falls back to default",
              {"effort": "high"}, _no_e2e["devflow:code-reviewer"])
finally:
    _os.unlink(_no_cfg)

# A non-object entry (hand-edited config bypassing schema validation) must be
# ignored with a warning, NEVER crash resolution — the engine never aborts on
# config shape. (resolve_overrides-level guard, belt-and-suspenders for direct callers.)
_nd_res, _nd_warn = _rro.resolve_overrides(
    {"devflow:code-reviewer": "high"},
    ["devflow:code-reviewer"],
)
assert_eq("resolve: non-object entry is ignored (no override, no crash)",
          {}, _nd_res)
assert_eq("resolve: non-object entry emits a warning", 1, len(_nd_warn))
# A non-object `default` is likewise ignored, not crashed.
_ndd_res, _ndd_warn = _rro.resolve_overrides(
    {"default": ["not", "an", "object"]}, ["devflow:code-reviewer"])
assert_eq("resolve: non-object default is ignored (no override)", {}, _ndd_res)
assert_eq("resolve: non-object default emits a warning", 1, len(_ndd_warn))

# A present-but-unusable model (empty/non-string) is dropped WITH a warning,
# mirroring the invalid-effort path (no silent asymmetry).
_bm_res, _bm_warn = _rro.resolve_overrides(
    {"devflow:code-reviewer": {"model": "", "effort": "high"}},
    ["devflow:code-reviewer"],
)
assert_eq("resolve: empty-string model dropped, effort kept",
          {"effort": "high"}, _bm_res["devflow:code-reviewer"])
assert_eq("resolve: empty-string model emits a warning", 1, len(_bm_warn))

# A whitespace-only model is as unusable as an empty one — dropped WITH a warning,
# not forwarded verbatim as a bogus model id.
_wm_res, _wm_warn = _rro.resolve_overrides(
    {"devflow:code-reviewer": {"model": "   ", "effort": "high"}},
    ["devflow:code-reviewer"],
)
assert_eq("resolve: whitespace-only model dropped, effort kept",
          {"effort": "high"}, _wm_res["devflow:code-reviewer"])
assert_eq("resolve: whitespace-only model emits a warning", 1, len(_wm_warn))

# A bad value on the shared `default` must NOT emit one warning per no-entry agent
# (warning spam: up to nine lines for one fat-fingered default). The default-sourced
# message is agent-agnostic, so the per-agent warnings are IDENTICAL and collapse to
# a single line under main()'s cross-source dedup.
_de_res, _de_warn = _rro.resolve_overrides(
    {"default": {"effort": "turbo"}},
    ["devflow:code-reviewer", "devflow:comment-analyzer",
     "devflow:silent-failure-hunter"],
)
assert_eq("resolve: bad default effort → no override for any no-entry agent", {}, _de_res)
assert_eq("resolve: bad default effort warnings are identical (collapse to one)",
          1, len(set(_de_warn)))
# Pin the agent-agnostic SCOPE wording, not just the collapse count: a regression that
# re-introduced a per-agent token would still collapse for a single agent but lose the
# "affects every agent" meaning that is the load-bearing UX of the dedup.
assert_eq("resolve: default-sourced warning is agent-agnostic (names the shared scope)",
          True, any("affects every agent" in w for w in _de_warn))

# The model branch carries the SAME agent-agnostic scope as the effort branch — a bad
# `default.model` across several no-entry agents must ALSO collapse to one line. (Only
# the effort branch was exercised before; a regression re-adding {agent} to the model
# message would pass every other test while restoring per-agent model spam.)
# NOTE: this is a direct-call guard for the resolve_overrides contract — the
# `default.model=""` branch is NOT reachable via the real engine path, since read_raw
# drops empty/whitespace leaves before resolve_overrides sees them (unlike the
# effort branch, which has the end-to-end main() twin below).
_dm_res, _dm_warn = _rro.resolve_overrides(
    {"default": {"model": ""}},
    ["devflow:code-reviewer", "devflow:comment-analyzer",
     "devflow:silent-failure-hunter"],
)
assert_eq("resolve: bad default model → no override for any no-entry agent", {}, _dm_res)
assert_eq("resolve: bad default model warnings collapse to one", 1, len(set(_dm_warn)))

# Symmetric contract: distinct OWN entries with bad values stay agent-specific (must
# NOT collapse), so each names its own misconfigured entry.
_oe_res, _oe_warn = _rro.resolve_overrides(
    {"devflow:code-reviewer": {"effort": "turbo"},
     "devflow:comment-analyzer": {"effort": "turbo"}},
    ["devflow:code-reviewer", "devflow:comment-analyzer"],
)
assert_eq("resolve: distinct own-entry bad-effort warnings stay distinct (not collapsed)",
          2, len(set(_oe_warn)))

# An object-valued model/effort leaf (hand-edited) must be dropped with a clear
# warning on the real path, not laundered into the "[object Object]" sentinel
# and forwarded as a model id (or surfaced as a misleading "not in enum" effort).
with _tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as _objf:
    _objf.write(
        '{"devflow_review":{"agent_overrides":{'
        '"devflow:code-reviewer":{"model":{"nested":1},"effort":"high"}}}}'
    )
    _obj_cfg = _objf.name
try:
    _objraw, _objwarn = _rro.read_raw(
        ["devflow:code-reviewer"], _config_get_sh, _obj_cfg)
    assert_eq("read_raw: object-valued model is dropped (not laundered to sentinel)",
              {"effort": "high"}, _objraw.get("devflow:code-reviewer"))
    assert_eq("read_raw: object-valued leaf surfaces a warning",
              1, len([w for w in _objwarn if "is an object, not a scalar" in w]))
finally:
    _os.unlink(_obj_cfg)

# main() CLI contract the engine depends on: pure JSON to stdout, warnings to
# stderr (never stdout), exit 0 on config shape, and an unknown-agent warning.
import json  # noqa: E402
_out, _err = io.StringIO(), io.StringIO()
with contextlib.redirect_stdout(_out), contextlib.redirect_stderr(_err):
    _rc = _rro.main(["devflow:code-reviewer", "--config", "/nonexistent/c.json"])
assert_eq("main: exit 0 on absent config", 0, _rc)
assert_eq("main: stdout is parseable JSON ({} when no overrides)",
          {}, json.loads(_out.getvalue()))
assert_eq("main: no warning leaked to stdout", True, "::warning::" not in _out.getvalue())

_out2, _err2 = io.StringIO(), io.StringIO()
with contextlib.redirect_stdout(_out2), contextlib.redirect_stderr(_err2):
    _rc2 = _rro.main(["pr-review-tookit:code-reviewer", "--config", "/nonexistent/c.json"])
assert_eq("main: unknown agent id still exits 0", 0, _rc2)
assert_eq("main: unknown agent id warns on stderr",
          True, "is not a known" in _err2.getvalue())
assert_eq("main: stdout stays pure JSON even with an unknown-agent warning",
          {}, json.loads(_out2.getvalue()))

# main() collapses the now-identical default-sourced warnings to a SINGLE stderr
# line (the warning-spam fix), even with several no-entry agents dispatched.
with _tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as _deff:
    _deff.write('{"devflow_review":{"agent_overrides":{"default":{"effort":"turbo"}}}}')
    _def_cfg = _deff.name
try:
    _od, _ed = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(_od), contextlib.redirect_stderr(_ed):
        _rc_def = _rro.main([
            "devflow:code-reviewer", "devflow:comment-analyzer",
            "devflow:silent-failure-hunter", "--config", _def_cfg])
    assert_eq("main: bad default effort exits 0", 0, _rc_def)
    assert_eq("main: bad default effort → {} overrides", {}, json.loads(_od.getvalue()))
    _eff_lines = [ln for ln in _ed.getvalue().splitlines()
                  if "falling back to session effort" in ln]
    assert_eq("main: bad default effort emits exactly one deduped warning line",
              1, len(_eff_lines))
finally:
    _os.unlink(_def_cfg)

# A non-object `default` on the real read_raw path: the warning must name the real
# consequence (no fallback for no-entry agents), NOT the nonsensical "default still
# applies" phrasing meaningful only for a real agent key.
with _tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as _ndf:
    _ndf.write('{"devflow_review":{"agent_overrides":{"default":"high"}}}')
    _nd_cfg = _ndf.name
try:
    _ndraw, _ndwarn = _rro.read_raw(
        ["devflow:code-reviewer"], _config_get_sh, _nd_cfg)
    assert_eq("read_raw: non-object default is not added to raw",
              False, "default" in _ndraw)
    _dmsg = [w for w in _ndwarn if "[default]" in w and "is not an object" in w]
    assert_eq("read_raw: non-object default surfaces a warning", 1, len(_dmsg))
    assert_eq("read_raw: non-object default warning avoids 'default still applies'",
              False, any("default still applies" in w for w in _dmsg))
    assert_eq("read_raw: non-object default warning names the real consequence",
              True, any("no fallback default" in w for w in _dmsg))
finally:
    _os.unlink(_nd_cfg)

# Drift guard: KNOWN_AGENTS must stay byte-identical to the schema's
# agent_overrides property keys (minus `default`). A tenth subagent added to the
# schema but not here (or vice versa) breaks config/dispatch/telemetry alignment.
_schema_path = SCRIPTS.parent / '.devflow' / 'config.schema.json'
with open(_schema_path) as _sf:
    _schema = json.load(_sf)
_schema_keys = set(
    _schema["properties"]["devflow_review"]["properties"]["agent_overrides"]["properties"]
)
assert_eq("schema agent_overrides keys == KNOWN_AGENTS + 'default'",
          set(_rro.KNOWN_AGENTS) | {"default"}, _schema_keys)

# Migration: the documented schema-rejection of a stale externally-namespaced override key
# (PR #143 review, Major #1 + Minor #1). CHANGELOG/migration-doc prose promise that a stale
# pre-rename key is REJECTED by config validation; that promise rests entirely on
# agent_overrides being additionalProperties:false (an undeclared key is invalid). Pin that
# property directly — flip it to true and a stale key would silently validate, falsifying the
# migration note. Then assert no stale key (the externally-namespaced colon form) survives in
# either the schema's properties OR config.example.json: the set-equality above already
# catches a stale key ADDED ALONGSIDE the new ones in the schema, but this names the exact old
# ids so an additive regression fails with a legible message rather than an opaque set diff,
# and extends the guard to config.example.json (which the schema set-equality does not cover).
# Literal split ("pr-review-" "toolkit:") so neither this value nor any comment reintroduces a
# colon-form id the run.sh #141 residual scan flags.
_ao_schema = (
    _schema["properties"]["devflow_review"]["properties"]["agent_overrides"]
)
assert_eq("#141 migration: schema agent_overrides is additionalProperties:false "
          "(a stale override key is REJECTED, not silently validated)",
          False, _ao_schema.get("additionalProperties"))
_PRT_PREFIX = "pr-review-" "toolkit:"
_PRT_OLD_KEYS = [
    _PRT_PREFIX + n for n in (
        "code-reviewer", "silent-failure-hunter", "comment-analyzer",
        "type-design-analyzer", "pr-test-analyzer",
    )
]
assert_eq("#141 migration: no stale pre-rename override key survives in config.schema.json",
          [], [k for k in _PRT_OLD_KEYS if k in _schema_keys])
_example_path = SCRIPTS.parent / '.devflow' / 'config.example.json'
with open(_example_path) as _exf:
    _example = json.load(_exf)
_example_ao = (
    _example.get("devflow_review", {}).get("agent_overrides", {})
)
assert_eq("#141 migration: no stale pre-rename override key survives in config.example.json",
          [], [k for k in _PRT_OLD_KEYS if k in _example_ao])

# The published KNOWN_AGENTS roster stays byte-identical to the nine telemetry ids.
assert_eq("resolve: KNOWN_AGENTS is the nine review-engine identifiers",
          ("devflow:checklist-generator", "devflow:checklist-deduper",
           "devflow:checklist-verifier", "devflow:code-reviewer",
           "devflow:silent-failure-hunter",
           "devflow:comment-analyzer",
           "devflow:type-design-analyzer",
           "devflow:pr-test-analyzer",
           "devflow:requesting-code-review"),
          _rro.KNOWN_AGENTS)

# Migration guard (#141): the old code-reviewer override key (the pre-rename, externally
# namespaced form) was renamed into the devflow: namespace. docs/review-agent-overrides.md
# + CHANGELOG promise that a STALE old key is treated as UNKNOWN (the resolver ignores it
# with a `::warning::`; the override silently stops applying) rather than silently matching
# the renamed agent. Pin that promise on the exact old string so the migration note is
# *tested*, not merely asserted — the unverified-assumption bug class CLAUDE.md flags
# (#62/#98). The literal is split ("pr-review-" "toolkit:...") so neither this value nor any
# comment/description here reintroduces a colon-form id the run.sh #141 residual scan flags.
_OLD_CR_KEY = "pr-review-" "toolkit:code-reviewer"
assert_eq("#141 migration: stale pre-rename code-reviewer override key is NOT a known id",
          False, _OLD_CR_KEY in _rro.KNOWN_AGENTS)
_mo, _me = io.StringIO(), io.StringIO()
with contextlib.redirect_stdout(_mo), contextlib.redirect_stderr(_me):
    _mrc = _rro.main([_OLD_CR_KEY, "--config", "/nonexistent/c.json"])
assert_eq("#141 migration: main() with the stale old key exits 0 (never aborts)", 0, _mrc)
assert_eq("#141 migration: main() warns the stale old key is not a known subagent",
          True, "is not a known" in _me.getvalue())

# Migration guard (#142): seam 3 renamed the final-pass reviewer override key from its
# pre-rename superpowers-namespaced form into the devflow: namespace. The 2.8.12 CHANGELOG
# + docs/review-agent-overrides.md migration table make the same promise as #141's rename.
# This block pins the DISPATCHED-unknown path: a stale old key passed as a dispatched id is
# UNKNOWN, so main() warns it is not a known subagent and exits 0 (never aborts). (The
# config-layer silent-drop half — a stale override key left in agent_overrides — is pinned
# separately below.) Pin the promise on the exact old string so the migration note is
# *tested*, not merely asserted (the #62/#98 unverified-assumption class). The literal is
# split ("superpowers:" "requesting-code-review") so neither this value nor the surrounding
# comment reintroduces a colon-form id the run.sh #142 residual scan flags.
_OLD_RCR_KEY = "superpowers:" "requesting-code-review"
assert_eq("#142 migration: stale pre-rename requesting-code-review override key is NOT a known id",
          False, _OLD_RCR_KEY in _rro.KNOWN_AGENTS)
_ro, _re = io.StringIO(), io.StringIO()
with contextlib.redirect_stdout(_ro), contextlib.redirect_stderr(_re):
    _rrc = _rro.main([_OLD_RCR_KEY, "--config", "/nonexistent/c.json"])
assert_eq("#142 migration: main() with the stale old key exits 0 (never aborts)", 0, _rrc)
assert_eq("#142 migration: main() warns the stale old key is not a known subagent",
          True, "is not a known" in _re.getvalue())

# Migration (config layer): the OTHER half of the stale-key story (PR #143 review, Major #1).
# The block above proves the DISPATCHED-unknown path (a stale id passed as a dispatched
# agent warns). The real operator scenario is the inverse: a stale override key is left in
# agent_overrides CONFIG while the engine dispatches only the renamed devflow: ids. The
# resolver reads overrides per DISPATCHED agent (+ "default"), so it never probes the stale
# key — the override silently stops applying with NO override and NO warning. That silent
# drop is the documented, honest behavior; pin it so a future resolver change that started
# (mis)matching or warning on the stale key would turn this red. Reuses the split-literal
# old key from the dispatched-unknown block above.
with _tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as _stalef:
    _stalef.write(
        '{"devflow_review":{"agent_overrides":{'
        '"' + _OLD_CR_KEY + '":{"model":"claude-opus-4-8","effort":"high"}}}}'
    )
    _stale_cfg = _stalef.name
try:
    _stale_dispatched = ["devflow:code-reviewer"]
    _stale_raw, _stale_rwarn = _rro.read_raw(
        _stale_dispatched, _config_get_sh, _stale_cfg)
    _stale_res, _stale_reswarn = _rro.resolve_overrides(_stale_raw, _stale_dispatched)
    assert_eq("#141 migration (config layer): stale override key yields NO override for the "
              "renamed agent (silently stops applying)",
              {}, _stale_res)
    assert_eq("#141 migration (config layer): stale override key drop emits no reader warning",
              [], _stale_rwarn)
    assert_eq("#141 migration (config layer): stale override key drop emits no resolver warning",
              [], _stale_reswarn)
finally:
    _os.unlink(_stale_cfg)

# Migration (config layer), seam 3: the same inverse scenario for the requesting-code-review
# rename. A stale superpowers: override key left in agent_overrides while the engine
# dispatches only the renamed devflow:requesting-code-review id — the resolver never probes
# the stale key, so the override silently stops applying (no override, no warning). Mirrors
# the #141 config-layer block above so seam 3's rename gets the same honest-behavior pin.
with _tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as _stalerf:
    _stalerf.write(
        '{"devflow_review":{"agent_overrides":{'
        '"' + _OLD_RCR_KEY + '":{"model":"claude-opus-4-8","effort":"high"}}}}'
    )
    _stale_rcfg = _stalerf.name
try:
    _stale_rdispatched = ["devflow:requesting-code-review"]
    _stale_rraw, _stale_rrwarn = _rro.read_raw(
        _stale_rdispatched, _config_get_sh, _stale_rcfg)
    _stale_rres, _stale_rreswarn = _rro.resolve_overrides(_stale_rraw, _stale_rdispatched)
    assert_eq("#142 migration (config layer): stale override key yields NO override for the "
              "renamed final-pass reviewer (silently stops applying)",
              {}, _stale_rres)
    assert_eq("#142 migration (config layer): stale override key drop emits no reader warning",
              [], _stale_rrwarn)
    assert_eq("#142 migration (config layer): stale override key drop emits no resolver warning",
              [], _stale_rreswarn)
finally:
    _os.unlink(_stale_rcfg)

# Characterization: pins the documented array-leaf gap so it can only change
# deliberately. config-get.sh joins an array leaf with commas before the resolver
# sees it, so a SINGLE-element array is indistinguishable from a scalar string.
with _tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as _arrf:
    _arrf.write(
        '{"devflow_review":{"agent_overrides":{'
        '"devflow:code-reviewer":{"effort":["high"]},'
        '"devflow:silent-failure-hunter":{"effort":["high","low"]},'
        '"devflow:pr-test-analyzer":{"model":["a","b"]}}}}'
    )
    _arr_cfg = _arrf.name
try:
    _arr_dispatched = ["devflow:code-reviewer",
                       "devflow:silent-failure-hunter",
                       "devflow:pr-test-analyzer"]
    _arr_raw, _ = _rro.read_raw(_arr_dispatched, _config_get_sh, _arr_cfg)
    _arr_res, _arr_rwarn = _rro.resolve_overrides(_arr_raw, _arr_dispatched)
    # Single-element array effort → joined to a bare scalar that passes the enum.
    assert_eq("char: single-element array effort ['high'] laundered to 'high' (documented gap)",
              {"effort": "high"}, _arr_res["devflow:code-reviewer"])
    # Multi-element array effort → 'high,low' → fails the enum → dropped + warned.
    assert_eq("char: multi-element array effort is dropped (fails enum)",
              None, _arr_res.get("devflow:silent-failure-hunter"))
    assert_eq("char: multi-element array effort warns",
              True, any("high,low" in w for w in _arr_rwarn))
    # Array model → 'a,b' → forwarded verbatim as a model id (documented gap).
    assert_eq("char: array model ['a','b'] laundered to 'a,b' (documented gap)",
              {"model": "a,b"}, _arr_res["devflow:pr-test-analyzer"])
finally:
    _os.unlink(_arr_cfg)

# Unknown/typo'd agent id WITH a matching agent_overrides entry: resolution keys
# off the dispatched id (not KNOWN_AGENTS), so the override is still emitted AND
# the unknown-id warning fires. (The existing unknown test used an absent config.)
with _tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as _tyf:
    _tyf.write(
        '{"devflow_review":{"agent_overrides":{'
        '"devflow:code-reviewter":{"effort":"high"}}}}'
    )
    _ty_cfg = _tyf.name
try:
    _to, _te = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(_to), contextlib.redirect_stderr(_te):
        _trc = _rro.main(["devflow:code-reviewter", "--config", _ty_cfg])
    assert_eq("main: typo'd id with a matching override still exits 0", 0, _trc)
    assert_eq("main: typo'd id override is emitted in stdout JSON",
              {"devflow:code-reviewter": {"effort": "high"}},
              json.loads(_to.getvalue()))
    assert_eq("main: typo'd id also warns it is not a known subagent",
              True, "is not a known" in _te.getvalue())
finally:
    _os.unlink(_ty_cfg)

# Duplicate dispatched ids must not destabilize output: read_raw/resolve key by
# agent, and the unknown-id warning is deduped (dict.fromkeys) to one line.
_do, _de = io.StringIO(), io.StringIO()
with contextlib.redirect_stdout(_do), contextlib.redirect_stderr(_de):
    _drc = _rro.main(["devflow:typo", "devflow:typo",
                      "--config", "/nonexistent/c.json"])
assert_eq("main: duplicate dispatched ids exit 0", 0, _drc)
assert_eq("main: duplicate dispatched ids yield stable JSON ({} here)",
          {}, json.loads(_do.getvalue()))
assert_eq("main: duplicate unknown id warns exactly once (deduped)",
          1, _de.getvalue().count("is not a known"))

# _config_get OSError branch: a bogus helper path makes subprocess.run raise
# OSError; it must be caught (warned, returns "") rather than propagated. The
# non-zero-exit branch (e.g. parse error / missing python3) is covered above by the
# malformed-config read_raw test.
_oserr_warn = []
_oserr_out = _rro._config_get(
    "/nonexistent/definitely-not-a-real-config-get.sh", None,
    ".devflow_review.agent_overrides.default.effort", _oserr_warn)
assert_eq("_config_get: OSError on bogus helper path returns '' (no raise)", "", _oserr_out)
assert_eq("_config_get: OSError on bogus helper path surfaces a warning",
          True, any("cannot run" in w for w in _oserr_warn))


# ── issue #222: UTF-8 stream-forcing is entry-path-scoped, not import-time ────
# Every hardened scripts/*.py reconfigures sys.stdout/sys.stderr to UTF-8 inside
# its main() (the CLI entry path), NOT at module top-level — so importing the
# module for these in-process tests must leave the importer's streams untouched.
# (The cp1252 RED->GREEN behavior when run AS a CLI is proven by subprocess in
# lib/test/run.sh; this asserts the complementary no-side-effect-on-import half.)
_stdout_before, _stderr_before = sys.stdout, sys.stderr
_enc_before = (getattr(sys.stdout, "encoding", None), getattr(sys.stderr, "encoding", None))
_reimported = _load('workpad_reimport', SCRIPTS / 'workpad.py')
assert_eq("#222: importing a hardened module leaves sys.stdout object unchanged",
          True, sys.stdout is _stdout_before)
assert_eq("#222: importing a hardened module leaves sys.stderr object unchanged",
          True, sys.stderr is _stderr_before)
assert_eq("#222: importing a hardened module leaves stream encodings unchanged",
          _enc_before,
          (getattr(sys.stdout, "encoding", None), getattr(sys.stderr, "encoding", None)))
# Each hardened module DOES expose the entry-path helper (so main() can call it).
# branch-for-issue.py is loaded here (it is not used elsewhere in this file) so all
# six hardened scripts are covered, not five.
_branch_for_issue = _load('branch_for_issue', SCRIPTS / 'branch-for-issue.py')
for _modname, _mod in (
    ('workpad', workpad), ('parse_acs', parse_acs), ('file_deferrals', file_deferrals),
    ('match_deferrals', match_deferrals),
    ('resolve_review_overrides', resolve_review_overrides),
    ('branch_for_issue', _branch_for_issue),
):
    assert_eq(f"#222: {_modname} defines _force_utf8_streams (entry-path helper)",
              True, hasattr(_mod, '_force_utf8_streams'))


print()
print(f"{PASS} passed, {FAIL} failed")
sys.exit(0 if FAIL == 0 else 1)
