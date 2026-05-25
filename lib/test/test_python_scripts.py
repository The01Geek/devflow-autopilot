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
        note=[], reflection=[],
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

# DEVFLOW_WORKPAD_MARKER env override wins, so /devflow:review can target its own
# <!-- devflow:review-progress --> comment with the same helper (set inline per
# call so it survives Claude Code's fresh-shell-per-call model).
import os as _os  # noqa: E402

_saved = _os.environ.pop('DEVFLOW_WORKPAD_MARKER', None)
try:
    _os.environ['DEVFLOW_WORKPAD_MARKER'] = '<!-- devflow:review-progress -->'
    assert_eq("marker: env override wins", '<!-- devflow:review-progress -->',
              workpad._workpad_marker())
    # A blank/whitespace override is ignored — falls through to config/default.
    # Assert it lands on the documented default marker (not merely non-empty), so
    # a regression in the fall-through wiring that returned the wrong marker is
    # caught. (No .devflow/config.json in the test cwd → config-get.sh returns the
    # passed default, which is workpad._DEFAULT_WORKPAD_MARKER.)
    _os.environ['DEVFLOW_WORKPAD_MARKER'] = '   '
    assert_eq("marker: blank override falls through to default marker",
              workpad._DEFAULT_WORKPAD_MARKER, workpad._workpad_marker())
finally:
    _os.environ.pop('DEVFLOW_WORKPAD_MARKER', None)
    if _saved is not None:
        _os.environ['DEVFLOW_WORKPAD_MARKER'] = _saved


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
        issue=7, run_link='[View run](https://x/1)', branch=None))
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
    workpad.cmd_new_body(argparse.Namespace(issue=7, run_link=None, branch='issue-7-x'))
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


print()
print(f"{PASS} passed, {FAIL} failed")
sys.exit(0 if FAIL == 0 else 1)
