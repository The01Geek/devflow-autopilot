#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Pure-function tests for the devflow Python scripts.

Covers areas that are silent-failure-class regressions if they drift:
- `workpad._apply_mutations` — batch tick/note atomicity, and the "duplicate
  tick inside one batched --tick-* call surfaces an error" invariant.
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
        tick_progress=[], tick_plan=[], tick_ac=[],
        rewrite_ac=None,
        replace_plan_file=None, replace_acs_file=None, set_reproduction_file=None,
        note=[], reflection=[], marker=None,
    )
    base.update(overrides)
    return argparse.Namespace(**base)


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
out = workpad._apply_mutations(WORKPAD_BODY, args)
assert_eq("batch tick-plan: alpha ticked", True, '- [x] Step alpha' in out)
assert_eq("batch tick-plan: beta ticked",  True, '- [x] Step beta'  in out)
assert_eq("batch tick-plan: gamma untouched", True, '- [ ] Step gamma' in out)

# Mixed batch: tick-plan + tick-ac + note in one atomic call.
args = make_args(tick_plan=['gamma'], tick_ac=['AC one'], note=['decision A', 'decision B'])
out = workpad._apply_mutations(WORKPAD_BODY, args)
assert_eq("mixed batch: gamma ticked", True, '- [x] Step gamma' in out)
assert_eq("mixed batch: AC one ticked", True, '- [x] AC one' in out)
assert_eq("mixed batch: note A present", True, '— decision A' in out)
assert_eq("mixed batch: note B present", True, '— decision B' in out)
# Multiple --note values share one timestamp.
note_lines = [ln for ln in out.splitlines() if '— decision' in ln]
ts_a = note_lines[0].split(' — ')[0]
ts_b = note_lines[1].split(' — ')[0]
assert_eq("multi-note: shared timestamp", ts_a, ts_b)

# Duplicate tick in one batched call raises _UpdateError (no silent no-op).
def _dup_tick():
    args = make_args(tick_plan=['alpha', 'alpha'])
    workpad._apply_mutations(WORKPAD_BODY, args)
assert_raises("duplicate --tick-plan in one batch raises _UpdateError",
              workpad._UpdateError, _dup_tick)

# Substring matching only an already-ticked row raises _UpdateError.
PRE_TICKED = WORKPAD_BODY.replace('- [ ] Step alpha', '- [x] Step alpha')
def _already_ticked():
    args = make_args(tick_plan=['alpha'])
    workpad._apply_mutations(PRE_TICKED, args)
assert_raises("--tick-plan vs already-ticked row raises _UpdateError",
              workpad._UpdateError, _already_ticked)

# Ambiguous substring still raises (regression check).
def _ambiguous():
    args = make_args(tick_plan=['Step'])
    workpad._apply_mutations(WORKPAD_BODY, args)
assert_raises("ambiguous --tick-plan raises _UpdateError",
              workpad._UpdateError, _ambiguous)

# Atomicity: a failure in the second mutation leaves no partial update —
# _apply_mutations raises before returning, so the caller never PATCHes.
def _atomic():
    args = make_args(tick_plan=['alpha', 'does-not-exist'])
    workpad._apply_mutations(WORKPAD_BODY, args)
assert_raises("batch tick with one missing match raises (atomic-update guarantee)",
              workpad._UpdateError, _atomic)

# Heading match is case-insensitive: a differently-cased section heading is
# still found and mutated (not a silent "section not found" error).
LOWER_HEADING = WORKPAD_BODY.replace('## Acceptance Criteria', '## acceptance criteria')
out = workpad._apply_mutations(LOWER_HEADING, make_args(tick_ac=['AC one']))
assert_eq("case-insensitive heading: AC one ticked under lowercase heading",
          True, '- [x] AC one' in out)


print("workpad notes: compact timestamp + nesting under ## Progress phase")

# Compact timestamp: note bullet renders `  - HH:MM:SS — {note}` (no date/T/Z),
# nested (indented) under its phase.
out = workpad._apply_mutations(WORKPAD_BODY, make_args(note=['narrowed AC']))
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
out2 = workpad._apply_mutations(out, make_args(note=['second note']))
prog2 = out2.split('## Plan', 1)[0]
assert_eq("note: second same-phase note follows the first chronologically", True,
          prog2.index('narrowed AC') < prog2.index('second note'))
assert_eq("note: second same-phase note still before next phase", True,
          prog2.index('second note') < prog2.index('**Review**'))

# Combined --status + --note nests under the POST-mutation Status's phase.
out3 = workpad._apply_mutations(WORKPAD_BODY, make_args(status='Reviewing', note=['x']))
prog3 = out3.split('## Plan', 1)[0]
assert_eq("note: combined --status/--note nests under NEW status's phase (Review)", True,
          prog3.index('**Review**') < prog3.index('— x')
          and prog3.index('— x') < prog3.index('**Documentation**'))

# Two notes in one call: argument order preserved, both under Implement.
out4 = workpad._apply_mutations(WORKPAD_BODY, make_args(note=['alpha note', 'beta note']))
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

out = workpad._apply_mutations(WORKPAD_V2, make_args(status='Complete'))
assert_eq("status: glyph applied to Status line", True,
          '**Status:** 🎉 Complete' in out)
# Idempotent: passing a glyph-prefixed status doesn't double up.
out_idem = workpad._apply_mutations(WORKPAD_V2, make_args(status='🎉 Complete'))
assert_eq("status: re-applying a glyph-prefixed status is idempotent", 1,
          out_idem.count('🎉'))
# A status transition while a note is added nests the note under the matching
# ## Progress phase (Reviewing → Review), keyed on the bare (glyph-stripped)
# post-mutation Status.
out_note = workpad._apply_mutations(WORKPAD_V2, make_args(status='Reviewing', note=['x']))
prog_note = out_note.split('## Plan', 1)[0]
assert_eq("status+note: note nests under the new status's phase (Review)", True,
          prog_note.index('**Review**') < prog_note.index('— x')
          and prog_note.index('— x') < prog_note.index('**Documentation**'))

# Run / PR links: replace when present.
out = workpad._apply_mutations(WORKPAD_V2, make_args(
    run_link='[logs](https://example/run/2)', pr_link='[#5](https://example/pr/5)'))
assert_eq("run-link: replaced", True, '**Run:** [logs](https://example/run/2)' in out)
assert_eq("pr-link: replaced", True, '**PR:** [#5](https://example/pr/5)' in out)
assert_eq("run-link: regex-special chars in URL kept literal", True,
          '?a=1&b=2' in workpad._apply_mutations(
              WORKPAD_V2, make_args(run_link='https://e/r?a=1&b=2')))

# Run / PR links: inserted after Branch when absent (legacy workpad resume).
LEGACY = WORKPAD_V2.replace('**Run:** [View run](https://example/run/1)\n', '') \
                   .replace('**PR:** _not yet created_\n', '')
assert_eq("legacy: no Run/PR lines in fixture", False,
          '**Run:**' in LEGACY or '**PR:**' in LEGACY)
out = workpad._apply_mutations(LEGACY, make_args(run_link='R', pr_link='P'))
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
out = workpad._apply_mutations(RUN_ONLY, make_args(pr_link='[#9](u)'))
assert_eq("pr-link inserted after an existing Run line (not above it)", True,
          out.index('**Run:**') < out.index('**PR:** [#9](u)')
          and out.index('**PR:** [#9](u)') < out.index('**Last updated:**'))

# ## Progress ticks (incl. a nested sub-item), with the same failure modes as --tick-*.
out = workpad._apply_mutations(WORKPAD_V2, make_args(
    tick_progress=['**Setup**', 'code + sweeps']))
assert_eq("tick-progress: top-level Setup ticked", True,
          '- [x] **Setup**' in out)
assert_eq("tick-progress: nested sub-item ticked", True,
          '- [x] code + sweeps' in out)
def _amb_progress():
    workpad._apply_mutations(WORKPAD_V2, make_args(tick_progress=['**']))
assert_raises("ambiguous --tick-progress raises _UpdateError",
              workpad._UpdateError, _amb_progress)

# Legacy resume: WORKPAD_V2 still carries a pre-change separate ## Decisions /
# Notes section. --note now writes into ## Progress, must NOT error, and must
# leave that legacy section (and its existing bullets) intact (AC: resuming a
# pre-change workpad doesn't error or drop note content).
out = workpad._apply_mutations(WORKPAD_V2, make_args(status='Implementing', note=['fresh note']))
prog = out.split('## Plan', 1)[0]
assert_eq("legacy-resume: new note nests under ## Progress (Implement phase)", True,
          '— fresh note' in prog
          and prog.index('**Implement**') < prog.index('fresh note'))
assert_eq("legacy-resume: legacy ## Decisions / Notes section preserved", True,
          '## Decisions / Notes' in out)
assert_eq("legacy-resume: existing legacy note content not dropped", True,
          'run started' in out)
# <details>: --reflection appends inside the (initially empty) Reflection block.
out = workpad._apply_mutations(WORKPAD_V2, make_args(reflection=['reflect!']))
rf = out.split('## Devflow Reflection', 1)[1]
assert_eq("details/reflection: bullet before </details>", True,
          'reflect!' in rf and rf.index('reflect!') < rf.index('</details>'))

# Invariants preserved: marker first line; AC section still parseable.
out = workpad._apply_mutations(WORKPAD_V2, make_args(
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
_rt = workpad._apply_mutations(_nb, make_args(tick_progress=['**Setup**'], note=['go']))
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
    "pr-review-toolkit:code-reviewer": {"model": "claude-opus-4-7", "effort": "high"},
    "devflow:checklist-deduper": {"model": "claude-haiku-4-5-20251001", "effort": "low"},
}
_res, _warn = _rro.resolve_overrides(
    _raw,
    ["pr-review-toolkit:code-reviewer", "devflow:checklist-deduper",
     "devflow:checklist-verifier"],
)
assert_eq("resolve: specific code-reviewer entry wins",
          {"model": "claude-opus-4-7", "effort": "high"},
          _res["pr-review-toolkit:code-reviewer"])
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
     "pr-review-toolkit:code-reviewer": {"model": "m"}},
    ["pr-review-toolkit:code-reviewer"],
)
assert_eq("resolve: own entry is used whole (no default backfill of effort)",
          {"model": "m"}, _res2["pr-review-toolkit:code-reviewer"])

# No entry and no default → no override emitted for that agent.
_res3, _ = _rro.resolve_overrides({}, ["pr-review-toolkit:code-reviewer"])
assert_eq("resolve: no entry + no default → empty override map", {}, _res3)

# Invalid effort → warning + drop effort (fall back to session); model forwarded.
_res4, _warn4 = _rro.resolve_overrides(
    {"pr-review-toolkit:code-reviewer": {"model": "m", "effort": "turbo"}},
    ["pr-review-toolkit:code-reviewer"],
)
assert_eq("resolve: invalid effort dropped, model forwarded",
          {"model": "m"}, _res4["pr-review-toolkit:code-reviewer"])
assert_eq("resolve: invalid effort emits exactly one warning", 1, len(_warn4))

# An entry that resolves to neither a model nor a valid effort emits no override.
_res5, _ = _rro.resolve_overrides(
    {"pr-review-toolkit:code-reviewer": {"effort": "bogus"}},
    ["pr-review-toolkit:code-reviewer"],
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
        '"pr-review-toolkit:code-reviewer":{"model":"m","effort":"low"}}}}'
    )
    _cfg_path = _cf.name
try:
    _rr_raw, _rr_warn = _rro.read_raw(
        ["devflow:checklist-verifier", "pr-review-toolkit:code-reviewer",
         "pr-review-toolkit:comment-analyzer"],
        _config_get_sh, _cfg_path,
    )
    assert_eq("read_raw: present-but-empty entry is represented as {} (shadows default)",
              {}, _rr_raw.get("devflow:checklist-verifier"))
    assert_eq("read_raw: full entry's fields are read",
              {"model": "m", "effort": "low"},
              _rr_raw.get("pr-review-toolkit:code-reviewer"))
    assert_eq("read_raw: absent agent is not added to raw",
              False, "pr-review-toolkit:comment-analyzer" in _rr_raw)
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
        ["pr-review-toolkit:code-reviewer"], _config_get_sh, _bad_cfg)
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
        '"pr-review-toolkit:code-reviewer":"high",'
        '"pr-review-toolkit:comment-analyzer":["a","b"]}}}'
    )
    _no_cfg = _nocf.name
try:
    _noraw, _nowarn = _rro.read_raw(
        ["pr-review-toolkit:code-reviewer", "pr-review-toolkit:comment-analyzer"],
        _config_get_sh, _no_cfg)
    assert_eq("read_raw: scalar entry is NOT coerced to {} (treated as no-entry)",
              False, "pr-review-toolkit:code-reviewer" in _noraw)
    assert_eq("read_raw: array entry is NOT coerced to {} (treated as no-entry)",
              False, "pr-review-toolkit:comment-analyzer" in _noraw)
    assert_eq("read_raw: each non-object entry surfaces a warning",
              2, len([w for w in _nowarn if "is not an object" in w]))
    # Since the malformed entries are treated as no-entry, `default` applies.
    _no_e2e, _ = _rro.resolve_overrides(_noraw, ["pr-review-toolkit:code-reviewer"])
    assert_eq("read_raw+resolve: non-object entry falls back to default",
              {"effort": "high"}, _no_e2e["pr-review-toolkit:code-reviewer"])
finally:
    _os.unlink(_no_cfg)

# A non-object entry (hand-edited config bypassing schema validation) must be
# ignored with a warning, NEVER crash resolution — the engine never aborts on
# config shape. (resolve_overrides-level guard, belt-and-suspenders for direct callers.)
_nd_res, _nd_warn = _rro.resolve_overrides(
    {"pr-review-toolkit:code-reviewer": "high"},
    ["pr-review-toolkit:code-reviewer"],
)
assert_eq("resolve: non-object entry is ignored (no override, no crash)",
          {}, _nd_res)
assert_eq("resolve: non-object entry emits a warning", 1, len(_nd_warn))
# A non-object `default` is likewise ignored, not crashed.
_ndd_res, _ndd_warn = _rro.resolve_overrides(
    {"default": ["not", "an", "object"]}, ["pr-review-toolkit:code-reviewer"])
assert_eq("resolve: non-object default is ignored (no override)", {}, _ndd_res)
assert_eq("resolve: non-object default emits a warning", 1, len(_ndd_warn))

# A present-but-unusable model (empty/non-string) is dropped WITH a warning,
# mirroring the invalid-effort path (no silent asymmetry).
_bm_res, _bm_warn = _rro.resolve_overrides(
    {"pr-review-toolkit:code-reviewer": {"model": "", "effort": "high"}},
    ["pr-review-toolkit:code-reviewer"],
)
assert_eq("resolve: empty-string model dropped, effort kept",
          {"effort": "high"}, _bm_res["pr-review-toolkit:code-reviewer"])
assert_eq("resolve: empty-string model emits a warning", 1, len(_bm_warn))

# A whitespace-only model is as unusable as an empty one — dropped WITH a warning,
# not forwarded verbatim as a bogus model id.
_wm_res, _wm_warn = _rro.resolve_overrides(
    {"pr-review-toolkit:code-reviewer": {"model": "   ", "effort": "high"}},
    ["pr-review-toolkit:code-reviewer"],
)
assert_eq("resolve: whitespace-only model dropped, effort kept",
          {"effort": "high"}, _wm_res["pr-review-toolkit:code-reviewer"])
assert_eq("resolve: whitespace-only model emits a warning", 1, len(_wm_warn))

# A bad value on the shared `default` must NOT emit one warning per no-entry agent
# (warning spam: up to nine lines for one fat-fingered default). The default-sourced
# message is agent-agnostic, so the per-agent warnings are IDENTICAL and collapse to
# a single line under main()'s cross-source dedup.
_de_res, _de_warn = _rro.resolve_overrides(
    {"default": {"effort": "turbo"}},
    ["pr-review-toolkit:code-reviewer", "pr-review-toolkit:comment-analyzer",
     "pr-review-toolkit:silent-failure-hunter"],
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
    ["pr-review-toolkit:code-reviewer", "pr-review-toolkit:comment-analyzer",
     "pr-review-toolkit:silent-failure-hunter"],
)
assert_eq("resolve: bad default model → no override for any no-entry agent", {}, _dm_res)
assert_eq("resolve: bad default model warnings collapse to one", 1, len(set(_dm_warn)))

# Symmetric contract: distinct OWN entries with bad values stay agent-specific (must
# NOT collapse), so each names its own misconfigured entry.
_oe_res, _oe_warn = _rro.resolve_overrides(
    {"pr-review-toolkit:code-reviewer": {"effort": "turbo"},
     "pr-review-toolkit:comment-analyzer": {"effort": "turbo"}},
    ["pr-review-toolkit:code-reviewer", "pr-review-toolkit:comment-analyzer"],
)
assert_eq("resolve: distinct own-entry bad-effort warnings stay distinct (not collapsed)",
          2, len(set(_oe_warn)))

# An object-valued model/effort leaf (hand-edited) must be dropped with a clear
# warning on the real path, not laundered into the "[object Object]" sentinel
# and forwarded as a model id (or surfaced as a misleading "not in enum" effort).
with _tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as _objf:
    _objf.write(
        '{"devflow_review":{"agent_overrides":{'
        '"pr-review-toolkit:code-reviewer":{"model":{"nested":1},"effort":"high"}}}}'
    )
    _obj_cfg = _objf.name
try:
    _objraw, _objwarn = _rro.read_raw(
        ["pr-review-toolkit:code-reviewer"], _config_get_sh, _obj_cfg)
    assert_eq("read_raw: object-valued model is dropped (not laundered to sentinel)",
              {"effort": "high"}, _objraw.get("pr-review-toolkit:code-reviewer"))
    assert_eq("read_raw: object-valued leaf surfaces a warning",
              1, len([w for w in _objwarn if "is an object, not a scalar" in w]))
finally:
    _os.unlink(_obj_cfg)

# main() CLI contract the engine depends on: pure JSON to stdout, warnings to
# stderr (never stdout), exit 0 on config shape, and an unknown-agent warning.
import json  # noqa: E402
_out, _err = io.StringIO(), io.StringIO()
with contextlib.redirect_stdout(_out), contextlib.redirect_stderr(_err):
    _rc = _rro.main(["pr-review-toolkit:code-reviewer", "--config", "/nonexistent/c.json"])
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
            "pr-review-toolkit:code-reviewer", "pr-review-toolkit:comment-analyzer",
            "pr-review-toolkit:silent-failure-hunter", "--config", _def_cfg])
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
        ["pr-review-toolkit:code-reviewer"], _config_get_sh, _nd_cfg)
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

# The published KNOWN_AGENTS roster stays byte-identical to the nine telemetry ids.
assert_eq("resolve: KNOWN_AGENTS is the nine review-engine identifiers",
          ("devflow:checklist-generator", "devflow:checklist-deduper",
           "devflow:checklist-verifier", "pr-review-toolkit:code-reviewer",
           "pr-review-toolkit:silent-failure-hunter",
           "pr-review-toolkit:comment-analyzer",
           "pr-review-toolkit:type-design-analyzer",
           "pr-review-toolkit:pr-test-analyzer",
           "superpowers:requesting-code-review"),
          _rro.KNOWN_AGENTS)

# Characterization: pins the documented array-leaf gap so it can only change
# deliberately. config-get.sh joins an array leaf with commas before the resolver
# sees it, so a SINGLE-element array is indistinguishable from a scalar string.
with _tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as _arrf:
    _arrf.write(
        '{"devflow_review":{"agent_overrides":{'
        '"pr-review-toolkit:code-reviewer":{"effort":["high"]},'
        '"pr-review-toolkit:silent-failure-hunter":{"effort":["high","low"]},'
        '"pr-review-toolkit:pr-test-analyzer":{"model":["a","b"]}}}}'
    )
    _arr_cfg = _arrf.name
try:
    _arr_dispatched = ["pr-review-toolkit:code-reviewer",
                       "pr-review-toolkit:silent-failure-hunter",
                       "pr-review-toolkit:pr-test-analyzer"]
    _arr_raw, _ = _rro.read_raw(_arr_dispatched, _config_get_sh, _arr_cfg)
    _arr_res, _arr_rwarn = _rro.resolve_overrides(_arr_raw, _arr_dispatched)
    # Single-element array effort → joined to a bare scalar that passes the enum.
    assert_eq("char: single-element array effort ['high'] laundered to 'high' (documented gap)",
              {"effort": "high"}, _arr_res["pr-review-toolkit:code-reviewer"])
    # Multi-element array effort → 'high,low' → fails the enum → dropped + warned.
    assert_eq("char: multi-element array effort is dropped (fails enum)",
              None, _arr_res.get("pr-review-toolkit:silent-failure-hunter"))
    assert_eq("char: multi-element array effort warns",
              True, any("high,low" in w for w in _arr_rwarn))
    # Array model → 'a,b' → forwarded verbatim as a model id (documented gap).
    assert_eq("char: array model ['a','b'] laundered to 'a,b' (documented gap)",
              {"model": "a,b"}, _arr_res["pr-review-toolkit:pr-test-analyzer"])
finally:
    _os.unlink(_arr_cfg)

# Unknown/typo'd agent id WITH a matching agent_overrides entry: resolution keys
# off the dispatched id (not KNOWN_AGENTS), so the override is still emitted AND
# the unknown-id warning fires. (The existing unknown test used an absent config.)
with _tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as _tyf:
    _tyf.write(
        '{"devflow_review":{"agent_overrides":{'
        '"pr-review-toolkit:code-reviewter":{"effort":"high"}}}}'
    )
    _ty_cfg = _tyf.name
try:
    _to, _te = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(_to), contextlib.redirect_stderr(_te):
        _trc = _rro.main(["pr-review-toolkit:code-reviewter", "--config", _ty_cfg])
    assert_eq("main: typo'd id with a matching override still exits 0", 0, _trc)
    assert_eq("main: typo'd id override is emitted in stdout JSON",
              {"pr-review-toolkit:code-reviewter": {"effort": "high"}},
              json.loads(_to.getvalue()))
    assert_eq("main: typo'd id also warns it is not a known subagent",
              True, "is not a known" in _te.getvalue())
finally:
    _os.unlink(_ty_cfg)

# Duplicate dispatched ids must not destabilize output: read_raw/resolve key by
# agent, and the unknown-id warning is deduped (dict.fromkeys) to one line.
_do, _de = io.StringIO(), io.StringIO()
with contextlib.redirect_stdout(_do), contextlib.redirect_stderr(_de):
    _drc = _rro.main(["pr-review-toolkit:typo", "pr-review-toolkit:typo",
                      "--config", "/nonexistent/c.json"])
assert_eq("main: duplicate dispatched ids exit 0", 0, _drc)
assert_eq("main: duplicate dispatched ids yield stable JSON ({} here)",
          {}, json.loads(_do.getvalue()))
assert_eq("main: duplicate unknown id warns exactly once (deduped)",
          1, _de.getvalue().count("is not a known"))

# _config_get OSError branch: a bogus helper path makes subprocess.run raise
# OSError; it must be caught (warned, returns "") rather than propagated. The
# non-zero-exit branch (e.g. parse error / missing node) is covered above by the
# malformed-config read_raw test.
_oserr_warn = []
_oserr_out = _rro._config_get(
    "/nonexistent/definitely-not-a-real-config-get.sh", None,
    ".devflow_review.agent_overrides.default.effort", _oserr_warn)
assert_eq("_config_get: OSError on bogus helper path returns '' (no raise)", "", _oserr_out)
assert_eq("_config_get: OSError on bogus helper path surfaces a warning",
          True, any("cannot run" in w for w in _oserr_warn))


print()
print(f"{PASS} passed, {FAIL} failed")
sys.exit(0 if FAIL == 0 else 1)
