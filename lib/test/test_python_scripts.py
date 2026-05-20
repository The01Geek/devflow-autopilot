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
  case-sensitive, level-bounded heading match (a lowercase / trailing-colon /
  wrong-level heading must yield zero items, not a silent miss that trivially
  passes the implement skill's post-merge-exempt gate), bullet variants, and
  the `(post-merge)` render tagging.
- `file_deferrals._derive_area` / `_compute_id` / `_format_line_range` /
  `_render_issue_body` — the `<area>` derivation examples, the deterministic
  ID that must stay stable across regenerations (the verdict engine matches on
  it), and the `PR #<n>` cross-link substring the verdict engine's guard
  validates against ("Do not reformat without updating the matcher").

Run from repo root:
    python3 lib/test/test_python_scripts.py
"""

import argparse
import importlib.util
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
        status=None, branch=None,
        tick_plan=[], tick_ac=[],
        rewrite_ac=None,
        replace_plan_file=None, replace_acs_file=None, set_reproduction_file=None,
        note=[], reflection=[],
    )
    base.update(overrides)
    return argparse.Namespace(**base)


WORKPAD_BODY = """<!-- devflow:workpad -->
# DevFlow Workpad — Issue #999

**Status:** Implementing
**Branch:** `feat/x`
**Last updated:** 2026-05-15T00:00:00Z

## Plan
- [ ] Step alpha
- [ ] Step beta
- [ ] Step gamma

## Acceptance Criteria
- [ ] AC one
- [ ] AC two

## Decisions / Notes

## Devflow Reflection
"""


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

# Case-sensitive, exact, level-bounded heading match — the silent-miss guards.
assert_eq("extract: lowercase heading → no section", [],
          parse_acs._extract_section(
              AC_BODY.replace('## Acceptance Criteria', '## acceptance criteria'),
              'Acceptance Criteria'))
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


print()
print(f"{PASS} passed, {FAIL} failed")
sys.exit(0 if FAIL == 0 else 1)
