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
import tempfile
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
stale_prose_lint = _load('stale_prose_lint', SCRIPTS / 'stale-prose-lint.py')
issue_audit_state = _load('issue_audit_state', SCRIPTS / 'issue-audit-state.py')


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
        rewrite_ac=[],
        replace_plan_file=None, replace_acs_file=None, set_reproduction_file=None,
        note=[], reflection=[], reflection_kind=None, reflection_file=None,
        marker=None,
        reconcile_reproduction=None, record_classification=None,
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

# #275: _workpad_marker must read .devflow/config.json directly in Python —
# never by exec-ing config-get.sh, which Windows cannot exec ([WinError 193])
# and which therefore silently dropped a configured custom marker back to the
# built-in default. The tests below exercise the REAL config file (a temp cwd
# with a real .devflow/config.json — the config read is not mocked) while
# poisoning workpad._run so any residual subprocess dependency in the marker
# path raises the same OSError class Windows produces: against the pre-#275
# code the custom-marker case fails for the right reason (exec fails → default
# marker), and passes once the marker is read in-process.
_saved_wp_run = workpad._run
_orig_cwd_275 = _os.getcwd()
try:
    def _boom_oserror(*a, **kw):
        raise OSError(8, "Exec format error")
    workpad._run = _boom_oserror
    # Hermetic guard: an operator's ambient DEVFLOW_WORKPAD_MARKER would win the
    # precedence race and fail every config-path assertion below spuriously.
    _saved_275_env = _os.environ.pop('DEVFLOW_WORKPAD_MARKER', None)
    with _tempfile.TemporaryDirectory() as _td:
        _os.chdir(_td)

        # No config file at all (fresh empty dir) → built-in default, silently.
        assert_eq("marker (#275): no .devflow/config.json → built-in default",
                  workpad._DEFAULT_WORKPAD_MARKER, workpad._workpad_marker(None))

        _os.mkdir('.devflow')

        def _write_cfg(text):
            with open(_os.path.join('.devflow', 'config.json'), 'w',
                      encoding='utf-8') as _f:
                _f.write(text)

        # The headline regression: a configured custom marker is honored even
        # when no subprocess can run (the Windows [WinError 193] shape).
        _write_cfg('{"devflow": {"workpad_marker": "<!-- custom:pad -->"}}')
        _stderr_happy = io.StringIO()
        with contextlib.redirect_stderr(_stderr_happy):
            _val = workpad._workpad_marker(None)
        assert_eq("marker (#275): custom config marker honored without exec-ing config-get.sh",
                  '<!-- custom:pad -->', _val)
        assert_eq("marker (#275): happy custom-marker read emits no breadcrumb",
                  '', _stderr_happy.getvalue())

        # Precedence above the config value is unchanged: flag > env > config.
        assert_eq("marker (#275): --marker flag still wins over a config value",
                  '<!-- flag -->', workpad._workpad_marker('<!-- flag -->'))
        _os.environ['DEVFLOW_WORKPAD_MARKER'] = '<!-- env -->'
        try:
            assert_eq("marker (#275): env var still wins over a config value",
                      '<!-- env -->', workpad._workpad_marker(None))
        finally:
            _os.environ.pop('DEVFLOW_WORKPAD_MARKER', None)

        # Key absent at either level → built-in default, silently (normal case).
        _write_cfg('{"devflow": {}}')
        assert_eq("marker (#275): workpad_marker key absent → built-in default",
                  workpad._DEFAULT_WORKPAD_MARKER, workpad._workpad_marker(None))
        _write_cfg('{"other": 1}')
        assert_eq("marker (#275): devflow key absent → built-in default",
                  workpad._DEFAULT_WORKPAD_MARKER, workpad._workpad_marker(None))

        # A non-string or empty value is "not configured", never a coerced
        # garbage marker stamped into a comment — but present-and-invalid
        # leaves a breadcrumb (unlike the silent absent-key cases above).
        _write_cfg('{"devflow": {"workpad_marker": 42}}')
        _stderr_nonstr = io.StringIO()
        with contextlib.redirect_stderr(_stderr_nonstr):
            _val = workpad._workpad_marker(None)
        assert_eq("marker (#275): non-string marker value → built-in default",
                  workpad._DEFAULT_WORKPAD_MARKER, _val)
        assert_eq("marker (#275): non-string marker value → breadcrumb names workpad_marker",
                  True, "workpad_marker" in _stderr_nonstr.getvalue())
        _write_cfg('{"devflow": {"workpad_marker": "   "}}')
        _stderr_blank = io.StringIO()
        with contextlib.redirect_stderr(_stderr_blank):
            _val = workpad._workpad_marker(None)
        assert_eq("marker (#275): blank-string marker value → built-in default",
                  workpad._DEFAULT_WORKPAD_MARKER, _val)
        assert_eq("marker (#275): blank-string marker value → breadcrumb emitted",
                  True, "workpad_marker" in _stderr_blank.getvalue())
        # Wrong-type shapes above the key (adversarial input matrix): a scalar
        # where the devflow object is expected, and a top-level array — both
        # are "not configured" (no key present), silent default.
        _write_cfg('{"devflow": "str"}')
        assert_eq("marker (#275): scalar devflow value → built-in default",
                  workpad._DEFAULT_WORKPAD_MARKER, workpad._workpad_marker(None))
        _write_cfg('[1]')
        assert_eq("marker (#275): top-level array config → built-in default",
                  workpad._DEFAULT_WORKPAD_MARKER, workpad._workpad_marker(None))

        # A UTF-16LE config (the PowerShell `>` redirection pitfall install.md
        # documents) raises UnicodeDecodeError — a ValueError, NOT an OSError or
        # JSONDecodeError — which must take the breadcrumbed fallback, never
        # escape as a traceback that aborts every workpad operation.
        # The BOM is load-bearing: BOM-less UTF-16LE ASCII decodes as valid
        # UTF-8 (interleaved NULs) and raises JSONDecodeError — which the OLD
        # except tuple already caught, making a BOM-less probe vacuous. The
        # real PowerShell `>` write emits the \xff\xfe BOM, whose \xff is an
        # invalid UTF-8 lead byte → UnicodeDecodeError, the arm this pins.
        with open(_os.path.join('.devflow', 'config.json'), 'wb') as _f:
            _f.write(b'\xff\xfe' + '{"devflow": {"workpad_marker": "<!-- utf16 -->"}}'.encode('utf-16-le'))
        _stderr_u16 = io.StringIO()
        with contextlib.redirect_stderr(_stderr_u16):
            _val = workpad._workpad_marker(None)
        assert_eq("marker (#275): UTF-16LE config.json → still returns the default (no raise)",
                  workpad._DEFAULT_WORKPAD_MARKER, _val)
        assert_eq("marker (#275): UTF-16LE config.json → breadcrumb names config.json",
                  True, "config.json" in _stderr_u16.getvalue())

        # A padded configured marker is trimmed (the .strip() contract).
        _write_cfg('{"devflow": {"workpad_marker": "  <!-- padded:pad -->  "}}')
        assert_eq("marker (#275): padded custom marker is stripped",
                  '<!-- padded:pad -->', workpad._workpad_marker(None))

        # Malformed JSON fails open to the default but MUST leave a breadcrumb
        # naming the config file, so a masked failure is distinguishable from
        # "nothing configured".
        _write_cfg('{not json')
        _stderr_capture = io.StringIO()
        with contextlib.redirect_stderr(_stderr_capture):
            _val = workpad._workpad_marker(None)
        assert_eq("marker (#275): malformed config.json → still returns the default (no raise)",
                  workpad._DEFAULT_WORKPAD_MARKER, _val)
        assert_eq("marker (#275): malformed config.json → breadcrumb names config.json",
                  True, "config.json" in _stderr_capture.getvalue())

        _os.chdir(_orig_cwd_275)
finally:
    _os.chdir(_orig_cwd_275)
    workpad._run = _saved_wp_run
    if _saved_275_env is not None:
        _os.environ['DEVFLOW_WORKPAD_MARKER'] = _saved_275_env


# #295: repo-root anchoring — the marker resolves from the ROOT config.json when
# workpad.py is invoked from a nested SUBDIRECTORY of a git repo. The #275 block above
# poisons _run and only exercises the cwd-FALLBACK path (non-git temp dirs); this test
# uses the REAL _run (a live `git rev-parse --show-toplevel` subprocess) to exercise the
# new git-ROOT discovery path directly — the case the reported bug (config silently lost
# from a subdir) actually hit. Asserts the returned VALUE, so it is symlink-robust
# (macOS /tmp → /private/tmp) without comparing resolved paths.
import subprocess as _sp295  # noqa: E402
_orig_cwd_295 = _os.getcwd()
_saved_295_env = _os.environ.pop('DEVFLOW_WORKPAD_MARKER', None)
try:
    with _tempfile.TemporaryDirectory() as _rd295:
        _sp295.run(['git', 'init', '-q', _rd295], check=True)
        _sp295.run(['git', '-C', _rd295, 'config', 'user.email', 't@example.com'], check=True)
        _sp295.run(['git', '-C', _rd295, 'config', 'user.name', 't'], check=True)
        _os.makedirs(_os.path.join(_rd295, '.devflow'))
        _os.makedirs(_os.path.join(_rd295, 'a', 'b', 'c'))
        with open(_os.path.join(_rd295, '.devflow', 'config.json'), 'w',
                  encoding='utf-8') as _f:
            _f.write('{"devflow": {"workpad_marker": "<!-- root:295 -->"}}')
        _os.chdir(_os.path.join(_rd295, 'a', 'b', 'c'))
        assert_eq("marker (#295): resolves the ROOT config marker from a nested subdir",
                  '<!-- root:295 -->', workpad._workpad_marker(None))
        _os.chdir(_orig_cwd_295)
finally:
    _os.chdir(_orig_cwd_295)
    if _saved_295_env is not None:
        _os.environ['DEVFLOW_WORKPAD_MARKER'] = _saved_295_env


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

# Issue #308: --rewrite-ac is repeatable (argparse action='append', nargs=2). A
# single call carrying multiple OLD/NEW pairs applies every pair in argument
# order; each pair is validated by the existing exactly-one-match rule, and a
# pair matching zero/multiple rows aborts the whole call with no PATCH (the
# structural all-or-nothing contract).

# Single pair still works (back-compat with the pre-#308 nargs=2 shape, now one
# element of the append list).
out = apply_mut(WORKPAD_BODY, make_args(rewrite_ac=[['AC one', 'AC one rewritten']]))
assert_eq("single --rewrite-ac: text rewritten", True, '- [ ] AC one rewritten' in out)

# Box state is preserved on a *ticked* row (exercises _rewrite_checkbox's
# group-2 reconstruction, which the unticked fixture above cannot).
AC_TICKED = WORKPAD_BODY.replace('- [ ] AC one', '- [x] AC one')
out = apply_mut(AC_TICKED, make_args(rewrite_ac=[['AC one', 'AC one rewritten']]))
assert_eq("single --rewrite-ac: ticked box state preserved", True,
          '- [x] AC one rewritten' in out)

# Two pairs in one call: BOTH land (the pre-#308 bug silently kept only the last).
out = apply_mut(WORKPAD_BODY, make_args(
    rewrite_ac=[['AC one', 'AC one v2'], ['AC two', 'AC two v2']]))
assert_eq("two-pair --rewrite-ac: first pair landed", True, '- [ ] AC one v2' in out)
assert_eq("two-pair --rewrite-ac: second pair landed", True, '- [ ] AC two v2' in out)

# Pairs apply against the PROGRESSIVELY-rewritten section: the second pair's OLD
# matches the text the FIRST pair just wrote, not the original. A regression that
# re-read the original section per pair would leave 'AC one beta' unfound here.
out = apply_mut(WORKPAD_BODY, make_args(
    rewrite_ac=[['AC one', 'AC one alpha'], ['AC one alpha', 'AC one beta']]))
assert_eq("progressive --rewrite-ac: second pair matches first pair's output",
          True, '- [ ] AC one beta' in out)
assert_eq("progressive --rewrite-ac: intermediate text does not survive",
          True, '- [ ] AC one alpha' not in out)

# A second pair whose OLD matches nothing aborts the whole call with no partial
# application — structural all-or-nothing preserved (raises _UpdateError, so the
# body is never PATCHed).
assert_raises(
    "two-pair --rewrite-ac: non-matching OLD aborts the whole call",
    workpad._UpdateError,
    lambda: apply_mut(WORKPAD_BODY, make_args(
        rewrite_ac=[['AC one', 'AC one v2'], ['nonexistent', 'x']])))

# A pair whose OLD matches MULTIPLE rows also aborts (the "zero OR multiple"
# arm of the exactly-one-match rule). Here the first pair renames 'AC one' to
# 'AC two', so 'AC two' now matches two rows and the second pair aborts —
# exercising both the progressive coupling and the >1-match structural abort.
assert_raises(
    "two-pair --rewrite-ac: OLD matching multiple rows aborts the whole call",
    workpad._UpdateError,
    lambda: apply_mut(WORKPAD_BODY, make_args(
        rewrite_ac=[['AC one', 'AC two'], ['AC two', 'AC two collapsed']])))


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


print("issue #258: terminal --status Complete self-record gate")

# The gate reconciles the workpad self-record against reality at the terminal
# `--status Complete` write: a structural HARD-FAIL (raises _UpdateError → the
# cmd_update abort path exits 1 with NO PATCH) on any non-post-merge unticked AC
# row, and a NON-blocking stderr warning naming any unticked ## Plan row. It fires
# ONLY for Complete, and never modifies a `- [ ]` row.
GATE_BODY = """<!-- devflow:workpad -->
# DevFlow Workpad — Issue #999

**Status:** 🚀 Documenting
**Last updated:** 2026-05-15T00:00:00Z

## Progress
- [x] **Setup**

## Plan
- [x] Plan step one
- [x] Plan step two

## Acceptance Criteria
- [x] AC one
- [x] AC two
"""
_AC_UNTICKED = GATE_BODY.replace('- [x] AC two', '- [ ] AC two')
_AC_POSTMERGE = GATE_BODY.replace('- [x] AC two', '- [ ] AC two (post-merge)')
_PLAN_UNTICKED = GATE_BODY.replace('- [x] Plan step two', '- [ ] Plan step two')

# AC hard-fail is a STRUCTURAL _UpdateError (sibling of the missing-section abort),
# so the shared cmd_update abort path applies: no PATCH, Status not flipped.
def _complete_over_unticked_ac():
    apply_mut(_AC_UNTICKED, make_args(status='Complete'), [])
assert_raises("#258: --status Complete over an unticked non-post-merge AC raises _UpdateError",
              workpad._UpdateError, _complete_over_unticked_ac)

# The gate NEVER modifies a row: a rejected finalize leaves the AC `- [ ]`. (Prove the
# body the abort would have discarded still shows the row untouched — no auto-tick.)
try:
    apply_mut(_AC_UNTICKED, make_args(status='Complete'), [])
except workpad._UpdateError as _e:
    assert_eq("#258: the AC hard-fail names the offending row", True, 'AC two' in str(_e))
# The gate never auto-ticks: a PASSING (un-gated) write over the same unticked-AC body
# returns a body whose AC row is STILL `- [ ]` — a behavioral check on the RETURNED body
# (the earlier `in _AC_UNTICKED` form was vacuous: the input str is immutable, so it could
# never fail regardless of gate behavior). Goes RED if any path silently ticks the row.
_noauto = apply_mut(_AC_UNTICKED, make_args(status='Blocked'), [])
assert_eq("#258: the gate never auto-ticks the offending AC row (returned body still [ ])", True,
          '- [ ] AC two' in _noauto)

# post-merge exclusion (byte-for-byte the Phase 3.4 'line ends in (post-merge)'):
# an outstanding post-merge-only AC does NOT block — the Status flips to Complete.
out = apply_mut(_AC_POSTMERGE, make_args(status='Complete'), [])
assert_eq("#258: a post-merge-only outstanding AC finalizes (Status → 🎉 Complete)", True,
          '🎉 Complete' in _statusline(out))
assert_eq("#258: the post-merge AC row is left unticked (never auto-ticked)", True,
          '- [ ] AC two (post-merge)' in out)

# Plan warning is NON-blocking: the call succeeds (returns a body with Status flipped)
# and writes a warning naming the unticked Plan row to stderr.
_perr = io.StringIO()
with contextlib.redirect_stderr(_perr):
    out = apply_mut(_PLAN_UNTICKED, make_args(status='Complete'), [])
assert_eq("#258: an unticked Plan row does NOT block finalize (Status → 🎉 Complete)", True,
          '🎉 Complete' in _statusline(out))
assert_eq("#258: the Plan warning names the unticked row on stderr", True,
          'Plan step two' in _perr.getvalue())
assert_eq("#258: the Plan warning does not fire on the ticked Plan row", False,
          'Plan step one' in _perr.getvalue())

# Clean run: every row ticked → finalize is silent (no AC abort, no Plan warning).
_cerr = io.StringIO()
with contextlib.redirect_stderr(_cerr):
    out = apply_mut(GATE_BODY, make_args(status='Complete'), [])
assert_eq("#258: a fully-ticked finalize flips Status to 🎉 Complete", True,
          '🎉 Complete' in _statusline(out))
assert_eq("#258: a fully-ticked finalize emits no gate warning", "", _cerr.getvalue())

# Gate is scoped to Complete ONLY: --status Blocked over an unticked AC is never gated.
_berr = io.StringIO()
with contextlib.redirect_stderr(_berr):
    out = apply_mut(_AC_UNTICKED, make_args(status='Blocked'), [])
assert_eq("#258: --status Blocked over an unticked AC is not gated (Status → 👎 Blocked)", True,
          '👎 Blocked' in _statusline(out))
assert_eq("#258: --status Blocked emits no gate warning", "", _berr.getvalue())

# No --status at all → never gated (an update with only ticks/notes is unaffected).
_nerr = io.StringIO()
with contextlib.redirect_stderr(_nerr):
    apply_mut(_AC_UNTICKED, make_args(note=['n']), [])
assert_eq("#258: an update with no --status is never gated", "", _nerr.getvalue())

# A non-Complete in-progress status that merely CONTAINS a mapped word is not gated.
_derr = io.StringIO()
with contextlib.redirect_stderr(_derr):
    out = apply_mut(_AC_UNTICKED, make_args(status='Documenting'), [])
assert_eq("#258: --status Documenting over an unticked AC is not gated", True,
          '🚀 Documenting' in _statusline(out) and _derr.getvalue() == '')

# CLI-level: the AC hard-fail routes through cmd_update's abort path — non-zero exit,
# NO PATCH (uses the existing #169 _drive_cmd_update harness).
_code, _err, _patched = _drive_cmd_update(_AC_UNTICKED, status='Complete')
assert_eq("#258 cmd_update: --status Complete over an unticked AC exits non-zero", 1, _code)
assert_eq("#258 cmd_update: the rejected finalize made NO PATCH", True, _patched is None)
assert_eq("#258 cmd_update: the abort stderr names the offending AC", True, 'AC two' in _err)
# CLI-level: a post-merge-only outstanding AC finalizes (PATCH lands, Status flipped).
_code, _err, _patched = _drive_cmd_update(_AC_POSTMERGE, status='Complete')
assert_eq("#258 cmd_update: a post-merge-only finalize succeeds (exit 0)", None, _code)
assert_eq("#258 cmd_update: the post-merge finalize PATCHed Status → Complete", True,
          _patched is not None and '🎉 Complete' in _patched)

# Post-mutation ordering (the gate's load-bearing placement): the gate runs LAST, over
# the POST-mutation sections, so a SINGLE call that ticks the last outstanding AC *and*
# flips Status to Complete passes — the tick lands before the scan. This is exactly the
# Phase 4.3 finalize shape (it ticks the "PR marked ready" progress box while flipping to
# Complete). Goes RED if the gate is reordered to scan the pre-mutation body/sections.
_oerr = io.StringIO()
with contextlib.redirect_stderr(_oerr):
    out = apply_mut(_AC_UNTICKED, make_args(status='Complete', tick_ac=['AC two']), [])
assert_eq("#258: ticking the last AC and flipping to Complete in one call passes", True,
          '🎉 Complete' in _statusline(out))
assert_eq("#258: the one-shot tick+Complete leaves the AC ticked (post-mutation scan saw [x])", True,
          '- [x] AC two' in out)
assert_eq("#258: the one-shot tick+Complete emits no AC/Plan gate warning", "", _oerr.getvalue())
# Symmetric Plan case: ticking the last Plan row in the same Complete call suppresses the
# non-blocking Plan warning — proving the Plan scan is also post-mutation, not pre-mutation.
_operr = io.StringIO()
with contextlib.redirect_stderr(_operr):
    out = apply_mut(_PLAN_UNTICKED, make_args(status='Complete', tick_plan=['Plan step two']), [])
assert_eq("#258: ticking the last Plan row in the Complete call suppresses the Plan warning", "",
          _operr.getvalue())
assert_eq("#258: the one-shot Plan tick+Complete flipped Status and ticked the row", True,
          '🎉 Complete' in _statusline(out) and '- [x] Plan step two' in out)
# CLI-level: the same one-shot tick+Complete routes cleanly through cmd_update (PATCH lands).
_code, _err, _patched = _drive_cmd_update(_AC_UNTICKED, status='Complete', tick_ac=['AC two'])
assert_eq("#258 cmd_update: one-shot tick-last-AC + Complete finalizes (exit 0)", None, _code)
assert_eq("#258 cmd_update: the one-shot finalize PATCHed Status → Complete with the AC ticked", True,
          _patched is not None and '🎉 Complete' in _patched and '- [x] AC two' in _patched)

# AC hard-fail takes PRECEDENCE over the Plan warning: a Complete write with BOTH an
# unticked non-post-merge AC *and* an unticked Plan row aborts (AC checked first) and
# emits NO Plan warning (the abort raises before the Plan branch runs). Goes RED if the
# gate were reordered to warn on Plan before the AC hard-fail.
_AC_AND_PLAN_UNTICKED = _AC_UNTICKED.replace('- [x] Plan step two', '- [ ] Plan step two')
_bperr = io.StringIO()
def _complete_over_ac_and_plan():
    with contextlib.redirect_stderr(_bperr):
        apply_mut(_AC_AND_PLAN_UNTICKED, make_args(status='Complete'), [])
assert_raises("#258: Complete with both unticked AC and Plan aborts (AC precedence over Plan)",
              workpad._UpdateError, _complete_over_ac_and_plan)
assert_eq("#258: the AC-precedence abort emits NO Plan warning before failing", False,
          'Plan step two' in _bperr.getvalue())

# Fail-open guard (shadow finding): a Complete write whose ## Acceptance Criteria section
# still holds the un-mirrored `new-body` placeholder (AC-mirroring never ran) has NO
# checkbox rows, so it does not hard-fail — but it emits a NON-blocking warning rather
# than passing silently. A genuinely AC-less issue reads the DISTINCT
# `_(none provided in issue body)_` sentinel and finalizes SILENTLY (no false warning).
_AC_PLACEHOLDER = GATE_BODY.replace(
    '- [x] AC one\n- [x] AC two', workpad._AC_PENDING_PLACEHOLDER)
_AC_NONE = GATE_BODY.replace(
    '- [x] AC one\n- [x] AC two', '_(none provided in issue body)_')
_pherr = io.StringIO()
with contextlib.redirect_stderr(_pherr):
    out = apply_mut(_AC_PLACEHOLDER, make_args(status='Complete'), [])
assert_eq("#258: a Complete over an un-mirrored AC placeholder still finalizes (Status → Complete)", True,
          '🎉 Complete' in _statusline(out))
assert_eq("#258: the un-mirrored AC placeholder emits a non-blocking warning", True,
          'un-mirrored placeholder' in _pherr.getvalue())
_nnerr = io.StringIO()
with contextlib.redirect_stderr(_nnerr):
    out = apply_mut(_AC_NONE, make_args(status='Complete'), [])
assert_eq("#258: a genuinely AC-less ('none provided') Complete finalizes SILENTLY", True,
          '🎉 Complete' in _statusline(out) and _nnerr.getvalue() == '')


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

# A --status Complete write now runs the issue #258 terminal self-record gate, which
# hard-fails on an unticked non-post-merge AC — so this glyph-rendering test uses a
# fully-ticked variant (its intent is the glyph, not the gate; the gate itself is
# covered in the issue #258 block above).
WORKPAD_V2_DONE = (WORKPAD_V2.replace('- [ ] AC one', '- [x] AC one')
                             .replace('- [ ] AC two', '- [x] AC two')
                             .replace('- [ ] Step alpha', '- [x] Step alpha'))
out = apply_mut(WORKPAD_V2_DONE, make_args(status='Complete'))
assert_eq("status: glyph applied to Status line", True,
          '**Status:** 🎉 Complete' in out)
# Idempotent: passing a glyph-prefixed status doesn't double up.
out_idem = apply_mut(WORKPAD_V2_DONE, make_args(status='🎉 Complete'))
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
# note is glyph-only now: the `### ℹ️ Notes` heading already names the kind, so
# the redundant `**Note:**` label is dropped (issue #476).
assert_eq("kind note: glyph only, no bold label", True, '- ℹ️ N' in rk)
assert_eq("kind note: no **Note:** label remains", True, '**Note:**' not in rk)
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
          rk.index('### ℹ️ Notes') < rk.index('- ℹ️ N'))
# Sub-headings are kept before </details> (stay inside the collapsible block).
assert_eq("grouped sub-sections stay before </details>", True,
          rk.index('### ℹ️ Notes') < rk.index('</details>'))

# Omitted --reflection-kind → note (default), never Action required.
rk_def = _reflect_seq((None, 'defaulted'))
assert_eq("omitted kind renders as note", True, '- ℹ️ defaulted' in rk_def)
assert_eq("omitted kind → Notes heading, no Action required heading", True,
          '### ℹ️ Notes' in rk_def and '### ⚠️ Action required' not in rk_def)

# Empty group → no heading: a single blocked emits no Notes heading.
rk_one = _reflect_seq(('blocked', 'only'))
assert_eq("single blocked → Action required heading, no Notes heading (empty group)", True,
          '### ⚠️ Action required' in rk_one and '### ℹ️ Notes' not in rk_one)

# Append second-of-kind nests under the existing heading (no duplicate).
rk_two = _reflect_seq(('note', 'first'), ('note', 'second'))
assert_eq("two notes → single Notes heading (no dup)", 1, rk_two.count('### ℹ️ Notes'))
assert_eq("two notes → both bullets present", 2, rk_two.count('- ℹ️ '))
assert_eq("appended bullet stays before </details>", True,
          rk_two.index('- ℹ️ second') < rk_two.index('</details>'))
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
          ('- ℹ️ ' + _mx) in rk_mx)

# Canonical ordering holds regardless of call order: a `note` written BEFORE an
# action-kind bullet still renders Action required ABOVE Notes (exercises the
# _rank insertion branch that places a new Action block above an existing Notes
# block — a plain-append regression would survive every action-first test).
rk_no = _reflect_seq(('note', 'N'), ('blocked', 'B'))
assert_eq("note-first then blocked → Action required still precedes Notes", True,
          rk_no.index('### ⚠️ Action required') < rk_no.index('### ℹ️ Notes'))
assert_eq("note-first then blocked → both bullets present", True,
          '- ⛔ **Blocked:** B' in rk_no and '- ℹ️ N' in rk_no)

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


print("workpad reflection new kinds + interpolation-safe input (issue #476)")

# --- improvement kind: glyph-only under a lazily-created ### 💡 Improvements ---
rk_imp = _reflect_seq(('improvement', 'hoist the resolver'))
assert_eq("improvement: glyph-only bullet (no bold label)", True,
          '- 💡 hoist the resolver' in rk_imp)
assert_eq("improvement: no **Improvement** label rendered", True,
          '**Improvement' not in rk_imp)
assert_eq("improvement: lazily-created ### 💡 Improvements heading", True,
          '### 💡 Improvements' in rk_imp)
assert_eq("improvement alone: no Action required or Notes heading (empty groups)", True,
          '### ⚠️ Action required' not in rk_imp and '### ℹ️ Notes' not in rk_imp)
assert_eq("improvement bullet sits under its heading", True,
          rk_imp.index('### 💡 Improvements') < rk_imp.index('- 💡 hoist the resolver'))

# Full three-sub-section canonical order: Action required → Improvements → Notes,
# regardless of the call order (note emitted first exercises the _rank insertion).
rk_all = _reflect_seq(('note', 'N'), ('improvement', 'I'), ('blocked', 'B'))
assert_eq("three sub-sections: Action required precedes Improvements", True,
          rk_all.index('### ⚠️ Action required') < rk_all.index('### 💡 Improvements'))
assert_eq("three sub-sections: Improvements precedes Notes", True,
          rk_all.index('### 💡 Improvements') < rk_all.index('### ℹ️ Notes'))
assert_eq("three sub-sections: all bullets present", True,
          '- ⛔ **Blocked:** B' in rk_all and '- 💡 I' in rk_all and '- ℹ️ N' in rk_all)

# Legacy un-kinded preamble stays ABOVE a lazily-created Improvements sub-section.
_imp_legacy = apply_mut(
    _LEGACY_REFLECTION_BODY,
    make_args(reflection=['propose a shared helper'], reflection_kind='improvement'))
_imp_legacy_rf = _imp_legacy.split('## Devflow Reflection', 1)[1]
assert_eq("improvement: legacy preamble bullet retained above Improvements heading", True,
          '- a legacy flat bullet' in _imp_legacy_rf
          and _imp_legacy_rf.index('- a legacy flat bullet')
          < _imp_legacy_rf.index('### 💡 Improvements'))

# --- issue-accuracy kind: labeled, under ### ℹ️ Notes (heading does not name it) ---
rk_ia = _reflect_seq(('issue-accuracy', 'the issue claimed 5 skills; there are 6'))
assert_eq("issue-accuracy: 📝 glyph + bold Issue accuracy label", True,
          '- 📝 **Issue accuracy:** the issue claimed 5 skills; there are 6' in rk_ia)
assert_eq("issue-accuracy: rendered under Notes heading", True,
          '### ℹ️ Notes' in rk_ia
          and rk_ia.index('### ℹ️ Notes') < rk_ia.index('- 📝 **Issue accuracy:**'))
assert_eq("issue-accuracy alone: no Action required / Improvements heading", True,
          '### ⚠️ Action required' not in rk_ia and '### 💡 Improvements' not in rk_ia)

# --- Closed kind model: exactly the six kinds, argparse-validated ---
assert_eq("closed kind model: exactly the six kinds", True,
          set(workpad._REFLECTION_KINDS) == {
              'blocked', 'deferred', 'dropped-failed', 'note',
              'improvement', 'issue-accuracy'})

# --- --reflection-file: interpolation-safe verbatim UTF-8 input ---
def _reflect_file(payload_bytes, kind='note', body=WORKPAD_V2, also_reflection=None):
    """Write payload_bytes to a temp file, apply an update carrying
    --reflection-file (+ optional --reflection), return the reflection region."""
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / 'payload.txt'
        p.write_bytes(payload_bytes)
        out = apply_mut(body, make_args(
            reflection=(also_reflection or []),
            reflection_kind=kind,
            reflection_file=str(p)))
    return out.split('## Devflow Reflection', 1)[1]

# Backticks + $(…) round-trip byte-identical (the shell-interpolation hazard the
# flag exists to defeat — passed via a file, never a CLI arg).
_shelly = 'ran `git rev-parse` and $(cmd) with "quotes"'
rk_bf = _reflect_file(_shelly.encode('utf-8'), kind='note')
assert_eq("--reflection-file: backticks/$(…)/quotes round-trip byte-identical", True,
          ('- ℹ️ ' + _shelly) in rk_bf)

# Non-ASCII (em-dash + emoji) round-trips byte-identical via explicit UTF-8.
_nonascii = 'reconciled — see 🚀 the workpad'
rk_na = _reflect_file(_nonascii.encode('utf-8'), kind='improvement')
assert_eq("--reflection-file: non-ASCII (em-dash + emoji) round-trips byte-identical", True,
          ('- 💡 ' + _nonascii) in rk_na)

# Multi-line file text collapses to one bullet line (line-based parser contract).
rk_mlf = _reflect_file(b'first line\nsecond line\nthird line', kind='note')
assert_eq("--reflection-file: multi-line file collapses to one bullet line", True,
          '- ℹ️ first line second line third line' in rk_mlf)
assert_eq("--reflection-file: multi-line file emits exactly one bullet", 1,
          rk_mlf.count('- ℹ️ '))

# The call's --reflection-kind applies to the file bullet; it combines with
# repeatable --reflection flags, and the file bullet appends AFTER them.
rk_comb = _reflect_file(b'from the file', kind='deferred',
                        also_reflection=['from a flag'])
assert_eq("--reflection-file: --reflection-kind applies to the file bullet", True,
          '- ⏭️ **Deferred:** from the file' in rk_comb)
assert_eq("--reflection-file: combines with --reflection (both bullets present)", True,
          '- ⏭️ **Deferred:** from a flag' in rk_comb)
assert_eq("--reflection-file: file bullet appends AFTER the flag bullet", True,
          rk_comb.index('- ⏭️ **Deferred:** from a flag')
          < rk_comb.index('- ⏭️ **Deferred:** from the file'))

# CRLF line endings collapse too (a bare \r must not survive into the bullet).
rk_crlf = _reflect_file(b'win one\r\nwin two', kind='note')
assert_eq("--reflection-file: CRLF collapses to one bullet line", True,
          '- ℹ️ win one win two' in rk_crlf)

# stdin arm: --reflection-file - decodes UTF-8 from sys.stdin.buffer.
class _FakeStdin:
    def __init__(self, data):
        self.buffer = io.BytesIO(data)

def _reflect_stdin(payload_bytes, kind='note'):
    saved = sys.stdin
    sys.stdin = _FakeStdin(payload_bytes)
    try:
        out = apply_mut(WORKPAD_V2, make_args(
            reflection_kind=kind, reflection_file='-'))
    finally:
        sys.stdin = saved
    return out.split('## Devflow Reflection', 1)[1]

rk_stdin = _reflect_stdin('via `stdin` — 🚀'.encode('utf-8'), kind='note')
assert_eq("--reflection-file -: stdin honored, UTF-8 decoded at the bytes level", True,
          '- ℹ️ via `stdin` — 🚀' in rk_stdin)

# Structural aborts before any PATCH: empty, whitespace-only, undecodable, unreadable.
def _empty_file():
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / 'e.txt'
        p.write_bytes(b'')
        apply_mut(WORKPAD_V2, make_args(reflection_file=str(p)))
assert_raises("--reflection-file: empty payload raises _UpdateError",
              workpad._UpdateError, _empty_file)

def _ws_only_file():
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / 'w.txt'
        p.write_bytes(b'   \n\t  \n')
        apply_mut(WORKPAD_V2, make_args(reflection_file=str(p)))
assert_raises("--reflection-file: whitespace-only payload raises _UpdateError",
              workpad._UpdateError, _ws_only_file)

def _undecodable_file():
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / 'u.txt'
        p.write_bytes(b'\xff\xfe\xfd not utf-8')
        apply_mut(WORKPAD_V2, make_args(reflection_file=str(p)))
assert_raises("--reflection-file: undecodable payload raises _UpdateError (no traceback)",
              workpad._UpdateError, _undecodable_file)

def _unreadable_file():
    apply_mut(WORKPAD_V2, make_args(
        reflection_file='/nonexistent/definitely/missing/payload.txt'))
assert_raises("--reflection-file: unreadable path raises _UpdateError",
              workpad._UpdateError, _unreadable_file)

# Atomicity: a bad --reflection-file payload aborts the WHOLE call — the
# accompanying inline --reflection bullet is not partially applied. The reader
# raises _UpdateError before _apply_mutations returns, so no body is produced to
# PATCH; pin that the raise fires even when an inline bullet rode along (proving
# the "no partial write" contract the docstring/comment assert).
def _bad_file_with_inline():
    apply_mut(WORKPAD_V2, make_args(
        reflection=['inline bullet that must not persist'],
        reflection_file='/nonexistent/definitely/missing/payload.txt'))
assert_raises("--reflection-file: a bad payload aborts even with an inline --reflection (no partial write)",
              workpad._UpdateError, _bad_file_with_inline)

# Default kind via the file path: --reflection-file with no --reflection-kind
# defaults to `note` (glyph-only), exercising the `kind = ... or _DEFAULT...`
# default through the file arm (rk_def above exercises it via --reflection).
rk_fdef = _reflect_file(b'defaulted via file', kind=None)
assert_eq("--reflection-file: omitted --reflection-kind defaults to note (glyph-only)", True,
          '- ℹ️ defaulted via file' in rk_fdef)

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
# Coupling pin (#258): the new-body template must emit the EXACT `_AC_PENDING_PLACEHOLDER`
# constant the terminal Complete gate matches on — they are one single source. Goes RED if
# the template is reworded away from the constant (e.g. the em-dash→ASCII-hyphen trap), which
# would silently disarm the gate's un-mirrored-placeholder warning (re-opening its fail-open).
assert_eq("new-body: AC placeholder is the exact gate constant (producer↔guard coupling)", True,
          workpad._AC_PENDING_PLACEHOLDER in _nb)
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


print("workpad reproduction-row reconcile + classification-note supersede (issue #449)")

# The Phase 2.1.5 reproduce-first gate now fires on a recorded *content*
# classification, not the `bug` label. Phase 1.3 records the classification as a
# superseding `classification: ` note and reconciles the bug-only "reproduction
# captured" Progress row to match it, on every entry — so a gate-created skeleton
# (rendered from the label) always agrees with the classification before Phase 2.

# A non-bug skeleton: Implement carries only `code + sweeps` (no repro row).
_WP_NONBUG = """<!-- devflow:workpad -->
# DevFlow Workpad — Issue #449

**Status:** Setup
**Branch:** `x`
**Last updated:** 2026-07-13T00:00:00Z

## Progress
- [ ] **Setup** — branch & workpad
  - 00:00:00 — /devflow:implement run started
- [ ] **Implement**
  - [ ] code + sweeps
- [ ] **Review**
- [ ] **Documentation**
- [ ] **PR marked ready**

## Plan
- [ ] Step alpha

## Acceptance Criteria
- [ ] AC one

## Devflow Reflection
"""

# A bug skeleton: Implement carries the repro row (unticked) above `code + sweeps`.
_WP_BUG = _WP_NONBUG.replace(
    "- [ ] **Implement**\n  - [ ] code + sweeps",
    "- [ ] **Implement**\n  - [ ] reproduction captured (bug issues only)\n  - [ ] code + sweeps",
)
# Same, but the repro row is already ticked (historical evidence).
_WP_BUG_TICKED = _WP_BUG.replace(
    "  - [ ] reproduction captured (bug issues only)",
    "  - [x] reproduction captured (bug issues only)",
)

_REPRO_SUBSTR = 'reproduction captured (bug issues only)'

# add-when-missing: bug-report classification on a non-bug skeleton inserts the
# unticked repro row directly under **Implement**, above `code + sweeps`.
_add = apply_mut(_WP_NONBUG, make_args(reconcile_reproduction='bug-report'))
assert_eq("reconcile: bug-report adds the repro row when absent", True,
          '- [ ] ' + _REPRO_SUBSTR in _add)
assert_eq("reconcile: added repro row sits above code + sweeps", True,
          _add.index(_REPRO_SUBSTR) < _add.index('- [ ] code + sweeps'))
assert_eq("reconcile: added repro row sits below the Implement heading", True,
          _add.index('**Implement**') < _add.index(_REPRO_SUBSTR))

# remove-when-present-unticked: non-bug classification on a bug skeleton drops the
# unticked repro row, leaving `code + sweeps` intact.
_rm = apply_mut(_WP_BUG, make_args(reconcile_reproduction='non-bug'))
assert_eq("reconcile: non-bug removes the unticked repro row", False,
          _REPRO_SUBSTR in _rm)
assert_eq("reconcile: non-bug keeps code + sweeps after removal", True,
          '- [ ] code + sweeps' in _rm)

# ticked-row-preserved: a ticked repro row is historical evidence — non-bug must
# NOT remove it.
_keep = apply_mut(_WP_BUG_TICKED, make_args(reconcile_reproduction='non-bug'))
assert_eq("reconcile: non-bug preserves a TICKED repro row", True,
          '- [x] ' + _REPRO_SUBSTR in _keep)

# ticked-row-preserved, uppercase variant: the drop-set test is exact-`[ ]`, so an
# `[X]`-ticked row (hand-edited workpad) is preserved just like `[x]`.
_WP_BUG_TICKED_UPPER = _WP_BUG.replace(
    "  - [ ] reproduction captured (bug issues only)",
    "  - [X] reproduction captured (bug issues only)",
)
_keep_upper = apply_mut(_WP_BUG_TICKED_UPPER, make_args(reconcile_reproduction='non-bug'))
assert_eq("reconcile: non-bug preserves an uppercase-[X]-ticked repro row", True,
          '- [X] ' + _REPRO_SUBSTR in _keep_upper)

# bug-report against an already-TICKED row is a no-op in any tick state: the row
# matches regardless of its box, so no second (unticked) row is inserted.
_noop_bug_ticked = apply_mut(_WP_BUG_TICKED, make_args(reconcile_reproduction='bug-report'))
assert_eq("reconcile: bug-report is a no-op against a ticked row (no duplicate insert)", True,
          _noop_bug_ticked.split('## Progress', 1)[1].count(_REPRO_SUBSTR) == 1)
assert_eq("reconcile: bug-report no-op keeps the ticked row ticked", True,
          '- [x] ' + _REPRO_SUBSTR in _noop_bug_ticked)

# no-op arms: bug-report on a skeleton that already has the row, and non-bug on a
# skeleton that never had it, both leave Progress byte-identical (idempotent).
_noop_bug = apply_mut(_WP_BUG, make_args(reconcile_reproduction='bug-report'))
assert_eq("reconcile: bug-report is a no-op when the row already exists", True,
          _noop_bug.count(_REPRO_SUBSTR) == 1)
assert_eq("reconcile: bug-report no-op keeps a single repro row (no duplicate)", True,
          _noop_bug.split('## Progress', 1)[1].count(_REPRO_SUBSTR) == 1)
_noop_nonbug = apply_mut(_WP_NONBUG, make_args(reconcile_reproduction='non-bug'))
assert_eq("reconcile: non-bug is a no-op when the row is already absent", False,
          _REPRO_SUBSTR in _noop_nonbug)

# note-supersede: recording a classification replaces any existing `classification: `
# note, so the workpad carries exactly one at all times, in the exact form.
_c1 = apply_mut(_WP_NONBUG, make_args(
    record_classification=['non-bug', 'reads as a feature request']))
assert_eq("record-classification: first record lands in the exact form", True,
          'classification: non-bug — reads as a feature request' in _c1)
assert_eq("record-classification: exactly one classification note after first record",
          1, _c1.count('classification: '))
_c2 = apply_mut(_c1, make_args(
    record_classification=['bug-report', 'quoted stack trace in the body']))
assert_eq("record-classification: second record supersedes the first", True,
          'classification: bug-report — quoted stack trace in the body' in _c2)
assert_eq("record-classification: superseded note is gone", False,
          'reads as a feature request' in _c2)
assert_eq("record-classification: still exactly one classification note after supersede",
          1, _c2.count('classification: '))

# A classification note nests inside ## Progress (not Reflection), so
# lib/fetch-pr-context.sh's reflection parse never picks it up.
assert_eq("record-classification: note lands inside ## Progress", True,
          _c1.split('## Progress', 1)[1].split('## Plan', 1)[0].count('classification: ') == 1)

# Guard rails: an empty rationale and an unknown class both fail structurally
# (an _UpdateError before any PATCH), never a silent malformed record.
assert_raises("record-classification: empty rationale raises", workpad._UpdateError,
              lambda: apply_mut(_WP_NONBUG, make_args(
                  record_classification=['non-bug', '   '])))
assert_raises("record-classification: unknown class raises", workpad._UpdateError,
              lambda: apply_mut(_WP_NONBUG, make_args(
                  record_classification=['maybe-bug', 'rationale'])))
# A multi-line rationale is its own fail-closed guard arm (distinct from empty/unknown):
# a line boundary would split the note bullet and could inject a forged checkbox row, so it
# raises structurally before any PATCH — the same bullet-splitting hazard --rewrite-ac guards.
assert_raises("record-classification: multi-line rationale raises (bullet-split guard)",
              workpad._UpdateError,
              lambda: apply_mut(_WP_NONBUG, make_args(
                  record_classification=['non-bug', 'ok\n- [x] phantom AC'])))

# _reconcile_reproduction_row fails CLOSED (loud) when the ## Progress skeleton has no
# **Implement** anchor row to insert under — a bug-classified run must never silently lose
# its reproduce-first gate row.
_WP_NO_IMPLEMENT = _WP_NONBUG.replace("- [ ] **Implement**\n  - [ ] code + sweeps\n", "")
assert_raises("reconcile: bug-report with no **Implement** anchor raises (fail-closed)",
              workpad._UpdateError,
              lambda: apply_mut(_WP_NO_IMPLEMENT, make_args(
                  reconcile_reproduction='bug-report')))

# The real Phase 1.3 production call shape: record the classification AND reconcile the row
# in one `update` call (both mutate ## Progress sequentially). Confirm both land.
_combo = apply_mut(_WP_NONBUG, make_args(
    record_classification=['bug-report', 'stack trace in the body'],
    reconcile_reproduction='bug-report'))
assert_eq("record+reconcile in one call: classification note lands", True,
          'classification: bug-report — stack trace in the body' in _combo)
assert_eq("record+reconcile in one call: repro row added", True,
          '- [ ] ' + _REPRO_SUBSTR in _combo)
assert_eq("record+reconcile in one call: exactly one classification note", 1,
          _combo.count('classification: '))

# The inverse production shape — the mislabelled-feature-request correction: record
# non-bug AND remove the repro row from a bug skeleton in one `update` call.
_combo_nb = apply_mut(_WP_BUG, make_args(
    record_classification=['non-bug', 'reads as a feature request'],
    reconcile_reproduction='non-bug'))
assert_eq("record+reconcile non-bug in one call: classification note lands", True,
          'classification: non-bug — reads as a feature request' in _combo_nb)
assert_eq("record+reconcile non-bug in one call: unticked repro row removed", False,
          _REPRO_SUBSTR in _combo_nb)
assert_eq("record+reconcile non-bug in one call: code + sweeps kept", True,
          '- [ ] code + sweeps' in _combo_nb)
assert_eq("record+reconcile non-bug in one call: exactly one classification note", 1,
          _combo_nb.count('classification: '))

# supersede against an ALREADY-CORRUPTED workpad carrying TWO classification notes:
# the exactly-one invariant must hold even when the input violates it (a regex
# regression matching only the first bullet would pass every build-it-via-the-tool
# test while leaving the second stale note behind).
_WP_TWO_NOTES = _WP_NONBUG.replace(
    "  - 00:00:00 — /devflow:implement run started",
    "  - 00:00:00 — /devflow:implement run started\n"
    "  - 00:00:01 — classification: non-bug — first stale note\n"
    "  - 00:00:02 — classification: bug-report — second stale note",
)
_c3 = apply_mut(_WP_TWO_NOTES, make_args(
    record_classification=['bug-report', 'quoted stack trace']))
assert_eq("record-classification: BOTH pre-existing corrupted notes superseded", 1,
          _c3.count('classification: '))
assert_eq("record-classification: the fresh note is the survivor", True,
          'classification: bug-report — quoted stack trace' in _c3)
# ...and a NON-classification Progress note is untouched by the supersede sweep: a
# broadened _CLASSIFICATION_NOTE_RE deleting real progress history must fail here.
assert_eq("record-classification: non-classification progress note survives supersede",
          True, '/devflow:implement run started' in _c3)
assert_eq("record-classification: non-classification note also survives plain record",
          True, '/devflow:implement run started' in _c2)

# bug-report insert against a resume-shaped layout: intervening non-checkbox
# sub-bullets under **Implement** (a resume note logged before code + sweeps). The
# anchor is the **Implement** line itself, so the row lands as its FIRST sub-item.
_WP_RESUME = _WP_NONBUG.replace(
    "- [ ] **Implement**\n  - [ ] code + sweeps",
    "- [ ] **Implement**\n  - 00:05:00 — resumed from Implementing\n  - [ ] code + sweeps",
)
_add_resume = apply_mut(_WP_RESUME, make_args(reconcile_reproduction='bug-report'))
assert_eq("reconcile: resume layout — repro row inserted (exactly one)", 1,
          _add_resume.count(_REPRO_SUBSTR))
assert_eq("reconcile: resume layout — row lands directly under **Implement**, above "
          "the intervening resume note", True,
          _add_resume.index('**Implement**') < _add_resume.index(_REPRO_SUBSTR)
          < _add_resume.index('resumed from Implementing'))

# DUPLICATE pre-existing repro rows (a hand-corrupted skeleton): non-bug removes
# every unticked copy; bug-report no-ops without inserting a third.
_WP_BUG_DUP = _WP_BUG.replace(
    "  - [ ] reproduction captured (bug issues only)",
    "  - [ ] reproduction captured (bug issues only)\n"
    "  - [ ] reproduction captured (bug issues only)",
)
_rm_dup = apply_mut(_WP_BUG_DUP, make_args(reconcile_reproduction='non-bug'))
assert_eq("reconcile: non-bug removes ALL duplicate unticked repro rows", False,
          _REPRO_SUBSTR in _rm_dup)
_noop_dup = apply_mut(_WP_BUG_DUP, make_args(reconcile_reproduction='bug-report'))
assert_eq("reconcile: bug-report no-ops on duplicate rows (no third insert)", 2,
          _noop_dup.count(_REPRO_SUBSTR))
# Mixed tick states among duplicates: only the unticked copy drops.
_WP_BUG_DUP_MIXED = _WP_BUG.replace(
    "  - [ ] reproduction captured (bug issues only)",
    "  - [x] reproduction captured (bug issues only)\n"
    "  - [ ] reproduction captured (bug issues only)",
)
_rm_mixed = apply_mut(_WP_BUG_DUP_MIXED, make_args(reconcile_reproduction='non-bug'))
assert_eq("reconcile: mixed duplicates — ticked copy preserved", True,
          '- [x] ' + _REPRO_SUBSTR in _rm_mixed)
assert_eq("reconcile: mixed duplicates — unticked copy removed (one row left)", 1,
          _rm_mixed.count(_REPRO_SUBSTR))

# Missing `## Progress` SECTION (distinct from the missing **Implement** anchor
# above) fails closed for BOTH new mutations — attributed to the section guard's
# own message, so a rejection from some other guard cannot masquerade as this one.
# Positive control: the identical fixture WITH ## Progress succeeds in the tests
# above (_c1/_add), so the rejection here is attributable to the removed section.
_WP_NO_PROGRESS = _WP_NONBUG.replace(
    "## Progress\n"
    "- [ ] **Setup** — branch & workpad\n"
    "  - 00:00:00 — /devflow:implement run started\n"
    "- [ ] **Implement**\n"
    "  - [ ] code + sweeps\n"
    "- [ ] **Review**\n"
    "- [ ] **Documentation**\n"
    "- [ ] **PR marked ready**\n"
    "\n",
    "",
)
assert_eq("no-progress fixture: section really removed (fixture self-check)", False,
          '## Progress' in _WP_NO_PROGRESS)
for _label, _np_args in (
    ("record-classification", make_args(record_classification=['non-bug', 'r'])),
    ("reconcile-reproduction", make_args(reconcile_reproduction='bug-report')),
):
    try:
        apply_mut(_WP_NO_PROGRESS, _np_args)
        assert_eq(f"{_label}: missing ## Progress raises", "_UpdateError raised",
                  "no exception")
    except workpad._UpdateError as _e:
        assert_eq(f"{_label}: missing ## Progress fails closed naming the section",
                  True, "'## Progress' not found" in str(_e))


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

# ── issue #254: hard-wrapped criteria (the ~80-column format /devflow:create-issue
# emits) must join indented continuation lines into ONE criterion, and a post-merge
# trigger phrase sitting on a continuation line must still classify. The old parser
# matched only the checkbox line itself, truncating each item to its first physical
# line and blinding the classifier to any trigger past the wrap.
WRAPPED_AC = """## Acceptance Criteria
- [ ] The parser joins each checkbox item's indented continuation lines into
      one criterion string so a hard-wrapped criterion round-trips verbatim
      into the workpad mirror.
- [ ] The deploy step is exercised and the result is confirmed
      in production after the release ships.
"""
_w = parse_acs._parse_checkboxes(parse_acs._extract_section(WRAPPED_AC, 'Acceptance Criteria'))
assert_eq("wrap: two items parsed", 2, len(_w))
assert_eq("wrap: item1 continuation lines joined verbatim into one string",
          "The parser joins each checkbox item's indented continuation lines into "
          "one criterion string so a hard-wrapped criterion round-trips verbatim "
          "into the workpad mirror.",
          _w[0]['text'])
assert_eq("wrap: item1 (no trigger anywhere) not post-merge", False, _w[0]['post_merge'])
assert_eq("wrap: item2 joined text carries the continuation-line content", True,
          'in production' in _w[1]['text'])
assert_eq("wrap: item2 trigger phrase on a continuation line classifies post-merge",
          True, _w[1]['post_merge'])

# Review iter 3 (over-join guard): the core risk of a join rewrite is *over*-joining.
# Prove the item-closing boundary (the `else: current = None` arm) actually fires: a
# dedented column-zero prose line must close the item so a *following* indented line
# is NOT absorbed into the criterion — and prove `ticked` is preserved on a wrapped
# `- [x]`. Deleting the `else: current = None` arm turns the "not over-joined" assert RED.
WRAPPED_AC_BOUNDARY = """## Acceptance Criteria
- [x] Ticked item wraps across
      two indented lines.
Prose paragraph at column zero closes the item.
      This indented line belongs to the prose, not the ticked item.
- [ ] Final standalone item.
"""
_b = parse_acs._parse_checkboxes(parse_acs._extract_section(WRAPPED_AC_BOUNDARY, 'Acceptance Criteria'))
assert_eq("over-join: only the two checkbox items are parsed (prose lines are not items)",
          2, len(_b))
assert_eq("over-join: wrapped `- [x]` preserves ticked=True", True, _b[0]['ticked'])
assert_eq("over-join: item1 joins only its own indented continuation",
          "Ticked item wraps across two indented lines.", _b[0]['text'])
assert_eq("over-join: an indented line after a dedented prose line is NOT absorbed (boundary fired)",
          False, 'belongs to the prose' in _b[0]['text'])
assert_eq("over-join: final item after the boundary parses cleanly and unticked",
          ("Final standalone item.", False), (_b[1]['text'], _b[1]['ticked']))

# Review iter (PR #255 receiving-review, Suggestion 2): the blank-line separator boundary,
# distinct from the column-zero-prose boundary above. /devflow:create-issue output can put a
# blank line between an item and following indented content; a blank line closes the item
# (the `else: current = None` arm fires on it too, since `line.strip()` is falsy), so a later
# indented line is NOT over-absorbed into the preceding criterion.
WRAPPED_AC_BLANKSEP = """## Acceptance Criteria
- [ ] First item wraps across
      two indented lines.

      This indented line follows a BLANK line and must not join item 1.
- [ ] Second standalone item.
"""
_bs = parse_acs._parse_checkboxes(parse_acs._extract_section(WRAPPED_AC_BLANKSEP, 'Acceptance Criteria'))
assert_eq("blank-sep: only the two checkbox items are parsed (blank line closed item 1)",
          2, len(_bs))
assert_eq("blank-sep: item1 joins only its pre-blank continuation",
          "First item wraps across two indented lines.", _bs[0]['text'])
assert_eq("blank-sep: an indented line after a blank line is NOT absorbed (boundary fired)",
          False, 'must not join' in _bs[0]['text'])

# Review iter (PR #255 receiving-review, test-gap): TAB-indented continuation lines join too
# (the continuation guard is `line[:1] in (' ', '\t')`); prior fixtures used only space
# indentation, leaving the `\t` branch unexercised.
WRAPPED_AC_TAB = "## Acceptance Criteria\n- [ ] Tab-wrapped criterion first line\n\tand its tab-indented continuation.\n"
_t = parse_acs._parse_checkboxes(parse_acs._extract_section(WRAPPED_AC_TAB, 'Acceptance Criteria'))
assert_eq("tab-cont: one item parsed", 1, len(_t))
assert_eq("tab-cont: tab-indented continuation is joined into the criterion",
          "Tab-wrapped criterion first line and its tab-indented continuation.", _t[0]['text'])

# Review iter (PR #255 receiving-review, test-gap): a post-merge trigger phrase SPLIT across
# the wrap boundary (no single physical line contains it) must still classify post-merge,
# because classification runs on the fully-joined text. This is the core reason the join
# feeds the post-merge scan — pin it directly.
WRAPPED_AC_SPLITTRIG = ("## Acceptance Criteria\n"
                        "- [ ] Update the changelog after\n"
                        "      merge so the entry reconciles.\n")
_st = parse_acs._parse_checkboxes(parse_acs._extract_section(WRAPPED_AC_SPLITTRIG, 'Acceptance Criteria'))
assert_eq("split-trigger: one item parsed", 1, len(_st))
assert_eq("split-trigger: 'after merge' split across the wrap still classifies post-merge",
          True, _st[0]['post_merge'])


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

# --- iterations key (issue #425): default-off "first-only" roster scoping ---
# The resolver only READS/passes the key through; the fix-loop-iteration≥2 exclusion
# is enforced engine-side (skills/review/SKILL.md Phase 3.1). These cases pin the
# resolver's pass-through + drop-with-warning contract, mirroring effort's arm.

# T1: first-only passed through in the resolved map, for its agent only.
_it_res, _it_warn = _rro.resolve_overrides(
    {"devflow:code-reviewer": {"model": "m", "effort": "high", "iterations": "first-only"},
     "devflow:silent-failure-hunter": {"model": "n"}},
    ["devflow:code-reviewer", "devflow:silent-failure-hunter"],
)
assert_eq("resolve(#425): first-only passed through for its agent",
          {"model": "m", "effort": "high", "iterations": "first-only"},
          _it_res["devflow:code-reviewer"])
assert_eq("resolve(#425): an agent without the key has no iterations in its output",
          {"model": "n"}, _it_res["devflow:silent-failure-hunter"])
assert_eq("resolve(#425): first-only pass-through emits no warning", [], _it_warn)

# T2: invalid iterations value dropped with a warning; run never aborts.
_iti_res, _iti_warn = _rro.resolve_overrides(
    {"devflow:code-reviewer": {"iterations": "always"}},
    ["devflow:code-reviewer"],
)
assert_eq("resolve(#425): invalid iterations value dropped → no override", {}, _iti_res)
assert_eq("resolve(#425): invalid iterations emits exactly one warning", 1, len(_iti_warn))
assert_eq("resolve(#425): invalid-iterations warning names the entry + the valid value",
          True, "iterations" in _iti_warn[0] and "first-only" in _iti_warn[0])

# Empty-string iterations follows the invalid-value arm (dropped + warning); model forwarded.
_ite_res, _ite_warn = _rro.resolve_overrides(
    {"devflow:code-reviewer": {"model": "m", "iterations": ""}},
    ["devflow:code-reviewer"],
)
assert_eq("resolve(#425): empty-string iterations dropped, model still forwarded",
          {"model": "m"}, _ite_res["devflow:code-reviewer"])
assert_eq("resolve(#425): empty-string iterations emits exactly one warning", 1, len(_ite_warn))

# An entry carrying ONLY iterations (no model/effort) still resolves.
_ito_res, _ito_warn = _rro.resolve_overrides(
    {"devflow:code-reviewer": {"iterations": "first-only"}},
    ["devflow:code-reviewer"],
)
assert_eq("resolve(#425): entry carrying only iterations still resolves",
          {"iterations": "first-only"}, _ito_res["devflow:code-reviewer"])
assert_eq("resolve(#425): only-iterations entry emits no warning", [], _ito_warn)

# T3: default-entry inheritance + entry-level precedence, identical to model/effort.
_itd_res, _ = _rro.resolve_overrides(
    {"default": {"iterations": "first-only"},
     "devflow:code-reviewer": {"model": "m"}},
    ["devflow:code-reviewer", "devflow:silent-failure-hunter"],
)
assert_eq("resolve(#425): default iterations applies to a no-entry agent",
          {"iterations": "first-only"}, _itd_res["devflow:silent-failure-hunter"])
assert_eq("resolve(#425): own entry does NOT inherit default iterations (entry-level precedence)",
          {"model": "m"}, _itd_res["devflow:code-reviewer"])

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
        '"devflow:silent-failure-hunter":{"iterations":{"nested":"obj"}},'
        '"devflow:code-reviewer":{"model":"m","effort":"low","iterations":"first-only"}}}}'
    )
    _cfg_path = _cf.name
try:
    _rr_raw, _rr_warn = _rro.read_raw(
        ["devflow:checklist-verifier", "devflow:code-reviewer",
         "devflow:silent-failure-hunter", "devflow:comment-analyzer"],
        _config_get_sh, _cfg_path,
    )
    assert_eq("read_raw: present-but-empty entry is represented as {} (shadows default)",
              {}, _rr_raw.get("devflow:checklist-verifier"))
    # #425: the `iterations` leaf round-trips through the real config-get.sh I/O path
    # (the pure-resolver tests never exercise read_raw's field loop for the new key).
    assert_eq("read_raw(#425): full entry reads model+effort+iterations end-to-end",
              {"model": "m", "effort": "low", "iterations": "first-only"},
              _rr_raw.get("devflow:code-reviewer"))
    # #425: an OBJECT-valued iterations leaf is dropped with the sentinel warning (read_raw
    # lines guarding _OBJECT_SENTINEL), leaving the entry empty rather than laundering the
    # sentinel string into a bogus value.
    assert_eq("read_raw(#425): object-valued iterations leaf is dropped (sentinel), entry empty",
              {}, _rr_raw.get("devflow:silent-failure-hunter"))
    assert_eq("read_raw(#425): object-valued iterations leaf surfaces a warning",
              True, any("iterations" in _w and "object" in _w for _w in _rr_warn))
    assert_eq("read_raw: absent agent is not added to raw",
              False, "devflow:comment-analyzer" in _rr_raw)
    assert_eq("read_raw: default entry is read", {"effort": "high"},
              _rr_raw.get("default"))
    # End-to-end resolution off the real config path: empty entry must NOT inherit default.
    _e2e, _ = _rro.resolve_overrides(_rr_raw, ["devflow:checklist-verifier"])
    assert_eq("read_raw+resolve: empty entry shadows default end-to-end", {}, _e2e)
    # #425: end-to-end, the valid iterations value survives into the resolved map.
    _e2e_it, _ = _rro.resolve_overrides(_rr_raw, ["devflow:code-reviewer"])
    assert_eq("read_raw+resolve(#425): valid iterations survives to the resolved map",
              "first-only", _e2e_it.get("devflow:code-reviewer", {}).get("iterations"))
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

# T4 (issue #425): every agent_overrides entry (all nine agents + `default`) declares
# the optional `iterations` property as a string enum whose ONLY value is "first-only",
# and each entry stays additionalProperties:false (so a stale/typo'd entry key — and an
# out-of-enum iterations value in a validated config — is rejected outright). This pins
# the schema surface the resolver's VALID_ITERATIONS mirrors.
_ao_entries = (
    _schema["properties"]["devflow_review"]["properties"]["agent_overrides"]["properties"]
)
for _ent_name, _ent in _ao_entries.items():
    _it = _ent.get("properties", {}).get("iterations")
    assert_eq("#425 schema: agent_overrides[%s] declares iterations enum ['first-only']"
              % _ent_name,
              {"type": "string", "enum": ["first-only"]}, _it)
    assert_eq("#425 schema: agent_overrides[%s] stays additionalProperties:false"
              % _ent_name,
              False, _ent.get("additionalProperties"))
assert_eq("#425 schema: VALID_ITERATIONS mirrors the schema enum",
          ("first-only",), _rro.VALID_ITERATIONS)

# T6 (issue #425): the shipped tracked .devflow/config.json pins the code-reviewer
# override to model+effort+iterations exactly, so a partial edit (dropping iterations,
# or changing model/effort) fails the suite. config.example.json carries iterations too.
_shipped_cfg_path = SCRIPTS.parent / '.devflow' / 'config.json'
with open(_shipped_cfg_path) as _scf:
    _shipped_cfg = json.load(_scf)
_shipped_cr = (
    _shipped_cfg["devflow_review"]["agent_overrides"]["devflow:code-reviewer"]
)
assert_eq("#425 config.json: code-reviewer override is model+effort+iterations exactly",
          {"model": "claude-opus-4-8", "effort": "low", "iterations": "first-only"},
          _shipped_cr)
_example_cfg_path = SCRIPTS.parent / '.devflow' / 'config.example.json'
with open(_example_cfg_path) as _ecf:
    _example_cfg = json.load(_ecf)
assert_eq("#425 config.example.json: code-reviewer override carries iterations first-only",
          "first-only",
          _example_cfg["devflow_review"]["agent_overrides"]
          ["devflow:code-reviewer"].get("iterations"))

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


# #356: `Failed` must stay OUT of _STATUS_TO_PROGRESS_PHASE, so a --note passed with
# --status Failed nests under the most-recent-ticked phase (the same fallback Blocked
# uses) instead of a Failed-specific phase.
#
# Asserted SEMANTICALLY, against the real dict — not by grepping the source for a
# quoting style. A source grep for `'failed':` is evaded by a double-quoted
# `"failed": ...` key, and the behavioral note-nesting test does not catch that either
# (its fixture has no `Review` row, so a `failed -> 'Review'` mapping falls through to
# the same last-ticked fallback and the note still lands where the test expects). This
# assertion is the only guard that cannot be evaded by either route.
assert_eq("#356: 'failed' is absent from _STATUS_TO_PROGRESS_PHASE (quote-agnostic)",
          False, 'failed' in workpad._STATUS_TO_PROGRESS_PHASE)
assert_eq("#356: 'blocked' is likewise absent (the sibling terminal word)",
          False, 'blocked' in workpad._STATUS_TO_PROGRESS_PHASE)
# Positive control: the map is non-empty and carries a known in-progress phase, so the
# two absence assertions above cannot pass vacuously against an empty/renamed dict.
assert_eq("#356: _STATUS_TO_PROGRESS_PHASE is populated (absence assertions not vacuous)",
          True, 'setup' in workpad._STATUS_TO_PROGRESS_PHASE)
# Both terminal words are still RECOGNIZED status words even though they have no phase.
assert_eq("#356: 'failed' is a recognized status word despite having no progress phase",
          True, workpad._is_recognized_status_word('Failed'))

# ── issue #338: _net_adds_post_merge fails CLOSED on a row-count mismatch ────
# The CLI-level tests cannot reach this branch: `--rewrite-ac` structurally rejects a
# newline in NEW, so `_rewrite_checkbox` can never change the row count. Pin the branch
# directly, because the shape that matters is precisely the one an aggregate
# `sum(post) > sum(pre)` fallback gets WRONG: a shorter-but-newly-tagged post state.
# Here sum(pre)=2 > sum(post)=1, so an aggregate compare returns False (fail OPEN) while
# row 1 transitioned untagged -> tagged. Fail-closed must return True.
assert_eq("#338: _net_adds_post_merge fails closed on a row-count mismatch "
          "(aggregate sum compare would fail open here)",
          True, workpad._net_adds_post_merge([True, True], [False, True, False]))
# Equal-length: positional add detected even though the totals are unchanged (the
# remove-one/add-one swap an aggregate count is blind to).
assert_eq("#338: _net_adds_post_merge catches a net-zero remove-one/add-one swap",
          True, workpad._net_adds_post_merge([True, False], [False, True]))
# Equal-length no-op / tag-removal must NOT fire.
assert_eq("#338: _net_adds_post_merge does not fire on a tag-preserving rewrite",
          False, workpad._net_adds_post_merge([True, False], [True, False]))
assert_eq("#338: _net_adds_post_merge does not fire on a tag removal",
          False, workpad._net_adds_post_merge([True, False], [False, False]))
# `_is_single_line` must accept no more than its consumer (`str.splitlines()`) does.
# A `'\n' in s or '\r' in s` membership test accepts every separator below and each one
# still splits a checkbox row — the validator-superset bug class. Sweep the full set.
for _sep in ('\n', '\r', '\r\n', '\v', '\f', '\x1c', '\x1d', '\x1e',
             '\x85', ' ', ' '):
    assert_eq(f"#338: _is_single_line rejects {_sep!r} (a str.splitlines() boundary)",
              False, workpad._is_single_line(f"AC two (post-merge){_sep}- [x] Phantom"))
    # A trailing separator also splits/reflows the row, so it is rejected too.
    assert_eq(f"#338: _is_single_line rejects a trailing {_sep!r}",
              False, workpad._is_single_line(f"AC two{_sep}"))
# ...and accepts ordinary single-line text, including a LITERAL backslash-n (two chars),
# internal whitespace, the empty string, and a tab.
for _ok in ('AC two', 'AC two (post-merge)', r'a literal \n backslash-n', 'a  b   c',
            '', '\tindented'):
    assert_eq(f"#338: _is_single_line accepts {_ok!r}", True, workpad._is_single_line(_ok))
# Contract check: the accepted set is exactly the set splitlines() does not split.
assert_eq("#338: _is_single_line agrees with str.splitlines() on every accepted input",
          True, all(len(s.splitlines()) <= 1
                    for s in ('AC two', '', '\tx', r'a \n b')
                    if workpad._is_single_line(s)))

# `_post_merge_flags` spans every tick state and ignores non-checkbox lines.
assert_eq("#338: _post_merge_flags flags ticked and unticked rows alike, skipping prose",
          [False, True, True],
          workpad._post_merge_flags(
              "- [ ] plain\n"
              "- [x] done (post-merge)\n"
              "some prose (post-merge)\n"
              "- [ ] deferred (post-merge)\n"))


# ── stale_prose_lint.parse_diff / main (#423 helper, hardened per the #424 review) ────────
# parse_diff is driven end-to-end by run.sh only over `git diff <empty-tree> HEAD` — a single
# all-`+` hunk. The REAL callers feed a `base...HEAD` diff. These tests pin the post-image
# bookkeeping directly on the shapes that diff actually has.
_MULTI_HUNK = (
    "diff --git a/f.md b/f.md\n"
    "index 1111111..2222222 100644\n"
    "--- a/f.md\n"
    "+++ b/f.md\n"
    "@@ -3,4 +3,5 @@ ctx\n"
    " keep three\n"
    "+added four\n"
    "-gone five\n"
    " keep six\n"
    "+added seven\n"
    " keep eight\n"
    "@@ -40,3 +42,4 @@ ctx\n"
    " keep forty\n"
    "+added forty-three\n"
    " keep forty-one\n"
    " keep forty-two\n"
)
# Hunk 1 starts at post-image line 3: " keep three"=3, "+added four"=4, "-gone five" spends NO
# post-image budget, " keep six"=5, "+added seven"=6, " keep eight"=7.
# Hunk 2 starts at post-image line 42: " keep forty"=42, "+added forty-three"=43.
assert_eq("#424: parse_diff tracks post-image line numbers across context, deletions, and a "
          "second hunk starting past line 1",
          {'f.md': {4: 'added four', 6: 'added seven', 43: 'added forty-three'}},
          stale_prose_lint.parse_diff(_MULTI_HUNK))

# A diff-ADDED content line whose own text begins "++ " is emitted as "+++ ". A prefix-only
# parser reads it as the next file header and retargets every later added line onto a phantom
# path; the hunk budget consumes it as content.
_PLUSPLUS = (
    "diff --git a/f.md b/f.md\n"
    "--- a/f.md\n"
    "+++ b/f.md\n"
    "@@ -0,0 +1,2 @@\n"
    "+++ leading plus-plus is content, not a header\n"
    "+real claim line\n"
)
assert_eq("#424: a '++ '-leading added line is content, not a file header (no phantom path)",
          {'f.md': {1: '++ leading plus-plus is content, not a header', 2: 'real claim line'}},
          stale_prose_lint.parse_diff(_PLUSPLUS))

# "@@ -1 +1 @@" (no comma) promises a ONE-line post image.
assert_eq("#424: parse_diff reads a countless '@@ -1 +1 @@' hunk header as a 1-line post image",
          {'f.md': {1: 'only line'}},
          stale_prose_lint.parse_diff(
              "--- a/f.md\n+++ b/f.md\n@@ -1 +1 @@\n-old line\n+only line\n"))

# An OVERSTATED hunk count (a hand-rolled or truncated diff claiming more post-image lines
# than it carries) must not let the leftover budget swallow the NEXT hunk header — that would
# silently drop every claim after it. A bare `@@` at column 0 is unambiguously structure (a
# content line always carries a +/-/space prefix), so the parser resyncs on it.
assert_eq("#424: an overstated hunk count does not swallow the next hunk header",
          {'f.md': {4: 'added four', 43: 'added forty-three'}},
          stale_prose_lint.parse_diff(
              "--- a/f.md\n+++ b/f.md\n"
              "@@ -3,1 +3,9 @@\n keep three\n+added four\n"      # claims 9, carries 2
              "@@ -40,1 +42,2 @@\n keep forty\n+added forty-three\n"))

# A `+++ /dev/null` target (a deletion) contributes no added lines.
assert_eq("#424: parse_diff attributes nothing to a /dev/null target",
          {}, stale_prose_lint.parse_diff(
              "--- a/f.md\n+++ /dev/null\n@@ -1,1 +0,0 @@\n-gone\n"))

# main()'s exit-2 catch-all must cover the WHOLE body. Before the #424 fix the stream
# reconfigure and the argparse construction sat OUTSIDE the guard, so an exception there
# escaped and Python exited 1 — and 1 is a contracted helper arm ("at least one STALE row"),
# so a crashed run read to the callers' routers as a completed one over its empty stdout.
# Anything unexpected must surface as 2.


def _main_rc_when_argparse_explodes():
    _real = stale_prose_lint.argparse.ArgumentParser

    def _boom(*_a, **_kw):
        raise OSError("simulated: argparse construction failed")

    stale_prose_lint.argparse.ArgumentParser = _boom
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            return stale_prose_lint.main(['stale-prose-lint.py', '--rev', 'HEAD'])
    finally:
        stale_prose_lint.argparse.ArgumentParser = _real


assert_eq("#424: an exception outside the old guard (argparse construction) exits 2, "
          "never Python's default 1 (which the routers read as the STALE arm)",
          2, _main_rc_when_argparse_explodes())

# The positive control: the same call path with argparse intact does NOT exit 2 — so the
# assertion above is attributable to the raised OSError, not to a broken fixture that would
# have failed anyway. `--rev` is a real commit here (HEAD of this repo) and stdin is an empty
# diff, so the contract says exit 0.


def _main_rc_on_empty_diff():
    _real_stdin = sys.stdin
    sys.stdin = type('S', (), {'buffer': io.BytesIO(b'')})()
    try:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return stale_prose_lint.main(['stale-prose-lint.py', '--rev', 'HEAD'])
    finally:
        sys.stdin = _real_stdin


assert_eq("#424: positive control — the same fixture with argparse intact exits 0 on an empty "
          "diff (the exit-2 above is the raised error, not an unrelated precondition)",
          0, _main_rc_on_empty_diff())

# ── stale_prose_lint.prose_mask (#434 line scoping) ───────────────────────────────────────
# The predicate is FILE-STATEFUL: fence / docstring / block-comment membership cannot be
# decided from an added line's own text (a hunk can begin *inside* a fence, so the opening
# delimiter is often not in the diff at all). These drive it over whole post-file content,
# which is what the helper actually feeds it.
assert_eq("#434: an unrecognised extension returns None — FAIL OPEN, examine every line",
          None, stale_prose_lint.prose_mask('x.zzz', ['# Cases 1-2', 'code']))
assert_eq("#434: a .sh mask is True only for '#' comment lines",
          [True, False, True],
          stale_prose_lint.prose_mask('x.sh', ['# a comment', "printf '# Cases 1-2'", '  # indented']))
assert_eq("#434: a .go mask covers '//' comments and /* … */ interiors",
          [True, False, True, True, True, False],
          stale_prose_lint.prose_mask(
              'x.go', ['// line comment', 'x := 1', '/* block', '   still block', '   end */', 'y := 2']))
assert_eq("#434: markdown prose is True, fenced-block interior is False",
          [True, False, False, False, True],
          stale_prose_lint.prose_mask('x.md', ['prose', '```bash', '# Cases 1-2', '```', 'more prose']))
# A 4-backtick fence wrapping a 3-backtick run: a naive "toggle on any ```" would invert fence
# state for the rest of the file — mis-scoping every later line in BOTH directions.
assert_eq("#434: a 4-backtick fence wrapping a 3-backtick run closes on the 4-run, not the 3",
          [False, False, False, True],
          stale_prose_lint.prose_mask('x.md', ['````md', '```', '````', 'prose after']))
# An unclosed fence fails OPEN: a stray backtick run must not un-examine the file's tail.
assert_eq("#434: an UNCLOSED fence fails open (its region stays prose, not code)",
          [True, True], stale_prose_lint.prose_mask('x.md', ['```', 'still examined']))
# Python: a real docstring is prose; a claim-shaped assigned string literal is fixture DATA.
assert_eq("#434: a .py module docstring is prose; an assigned triple-quoted literal is not",
          [True, False, False],
          stale_prose_lint.prose_mask(
              'x.py', ['"""Cases 1-2 below."""', 'FIXTURE = """Cases 1-2 below."""', 'x = 1']))
assert_eq("#434: a .py '#' comment is prose",
          [True, False], stale_prose_lint.prose_mask('x.py', ['# Cases 1-2', 'x = 1']))
# CRLF and a UTF-8 BOM must not hide a comment marker (consumer Windows repos).
assert_eq("#434: a CRLF '#' comment is still prose (trailing \\r stripped)",
          [True], stale_prose_lint.prose_mask('x.sh', ['# Cases 1-2\r']))
assert_eq("#434: a BOM before '#' does not hide the comment marker",
          [True], stale_prose_lint.prose_mask('x.sh', ['﻿# Cases 1-2']))
assert_eq("#434: an uppercase extension is matched case-insensitively (.MD is markdown prose)",
          [True, True], stale_prose_lint.prose_mask('X.MD', ['prose', 'more prose']))
# Extensionless / dotfile paths fall open (None), never to "examine nothing".
assert_eq("#434: an extensionless path falls OPEN (None), never to no-checking",
          None, stale_prose_lint.prose_mask('CHANGELOG', ['Cases 1-2']))
assert_eq("#434: Makefile/Dockerfile are recognised '#'-comment basenames",
          [True, False], stale_prose_lint.prose_mask('Makefile', ['# Cases 1-2', 'all:']))

# git C-quotes a non-ASCII path; left encoded it would fail `git show` AND land on the
# unrecognised arm for a reason unrelated to its type.
assert_eq("#434: a C-quoted non-ASCII path is decoded back to real text",
          {'café.md': {1: 'prose'}},
          stale_prose_lint.parse_diff(
              '--- a/x\n+++ "b/caf\\303\\251.md"\n@@ -0,0 +1,1 @@\n+prose\n'))

print()
print("issue-audit-state: the motivating regression (issue #546)")

# The named test-first regression. State holds a `VERDICT: REVISE` round on digest
# D1 plus a subsequently recorded revision; the draft file's bytes now hash to
# D2 != D1 and no further round completed. `approve` mode must refuse.
#
# This is the exact shape of the incident that motivated extracting the lifecycle
# out of prose: revised draft bytes proceeding toward presentation after a REVISE
# verdict, with no clean audit verdict on those exact bytes.
_REGRESSION_STATE = {
    'schema_version': issue_audit_state.SCHEMA_VERSION,
    'slug': 'motivating-regression',
    'nonce': 'a1b2c3d4e5f60718',
    'reinit_forced': False,
    'automatic_reaudits_used': 0,
    'user_rounds_used': 0,
    'rounds': [{
        'round': 1,
        'attempts': [{'arm': 'file', 'digest': 'D1', 'body_digest': 'B1',
                      'sentinel_open': None, 'sentinel_close': None}],
        'no_parseable_retry_used': False,
        'unreadable_retry_used': False,
        'outcome': 'REVISE',
        'findings_count': 2,
        'consumer_dimensions_appended': False,
        'embed_markers': [],
        'degraded': False,
    }],
    'revisions': [{'ordinal': 1, 'after_round': 1}],
    'overrides': [],
    'creation': None,
}

_regression = issue_audit_state.evaluate_eligibility(
    _REGRESSION_STATE, 'approve', current_digest='D2')

assert_eq("#546 eligibility_unaudited_revision_regression: REVISE on D1 + a recorded "
          "revision, approve mode, draft now hashes to D2 -> not-eligible",
          'not-eligible', _regression['answer'])
assert_eq("#546 eligibility_unaudited_revision_regression: the refusal reason is "
          "unaudited-revision",
          'unaudited-revision', _regression['reason'])
assert_eq("#546 eligibility_unaudited_revision_regression: a refused answer issues "
          "no eligibility token",
          None, _regression['token'])

print()
print("issue-audit-state: the transition table (issue #546)")

# One row here per module table row, counted and content-matched in LOCKSTEP (a
# metadata lockstep over event/condition/legality — not itself a behavioral drive;
# the behavioral arms are driven by the function-level rows below and the CLI blocks
# in the shell suite, including the illegal-mutation guards). The lockstep assert
# derives the expected count from the module's OWN table, so a row added to the
# module without a row added here turns the suite RED rather than shipping an
# untracked transition.
_TRANSITION_ROWS = [
    ('init', 'cold-start-no-nonce', True),
    ('init', 'same-run-nonce-no-rounds', True),
    ('init', 'same-run-nonce-over-rounds-unforced', False),
    ('init', 'same-run-nonce-over-rounds-forced', True),
    ('init', 'foreign-nonce', False),
    ('dispatch', 'file-arm-write-landed', True),
    ('dispatch', 'embed-arm-entry', True),
    ('dispatch', 'inline-arm-entry', True),
    ('dispatch', 'no-open-round', False),
    ('return', 'verdict-on-arm', True),      # file/FILE
    ('return', 'verdict-on-arm', True),      # file/REVISE
    ('return', 'verdict-on-arm', True),      # file/DRAFT-UNREADABLE
    ('return', 'verdict-on-arm', True),      # embed/FILE
    ('return', 'verdict-on-arm', True),      # embed/REVISE
    ('return', 'verdict-on-arm', False),     # embed/DRAFT-UNREADABLE — illegal
    ('return', 'verdict-on-arm', True),      # inline/FILE
    ('return', 'verdict-on-arm', True),      # inline/REVISE
    ('return', 'verdict-on-arm', False),     # inline/DRAFT-UNREADABLE — illegal
    ('return', 'no-verdict-line', True),
    ('return', 'carriage-absent-or-mismatched', True),
    ('return', 'no-open-round', False),
    ('return', 'round-already-returned', False),
    ('revision', 'after-completed-round', True),
    ('revision', 'no-rounds-recorded', False),
    ('override', 'user-decline-recorded', True),
    ('override', 'cap-reached-recorded', True),
    ('degraded', 'inline-arm-entered', True),
    ('creation-epoch', 'bound-to-round', True),
    ('creation-epoch', 'no-round-recorded', False),
    ('creation-attestation', 'body-matches', True),
    ('creation-attestation', 'body-mismatches', True),
    ('creation-attestation', 'fetch-failed', True),
    ('creation-attestation', 'no-epoch-recorded', False),
    ('creation-attestation', 'already-recorded', False),
    ('creation-epoch', 'rebind-after-attestation', False),
]

# table_test_lockstep_count — the exact-count lockstep. Derived from the module's own
# table, never a literal transcribed by hand.
assert_eq("#546 table_test_lockstep_count: one driven test row per module transition row",
          len(issue_audit_state.TRANSITIONS), len(_TRANSITION_ROWS))

# Each driven row corresponds, in order, to a real (event, condition, legal) triple in
# the module's table — so the counts matching is not a coincidence of two equal numbers.
assert_eq("#546 table_test_lockstep_count: each driven row matches its module row's "
          "event/condition/legality, in order",
          [(r['event'], r['condition'], r['legal']) for r in issue_audit_state.TRANSITIONS],
          _TRANSITION_ROWS)

# Positive controls for the two locksteps above (raised on PR #552): the sibling locksteps
# each carry an explicit planted-defect control observed distinguishing; these give this one
# the same. They plant a defect into a COPY of the derived module rows and assert the exact
# comparison each lockstep makes would reject it — proving neither assert is a tautology of two
# coincidentally-equal shapes. The module's own TRANSITIONS is never mutated (route (a): the
# defect lives on a copy), so a green run leaves the real table untouched.
_derived_rows = [(r['event'], r['condition'], r['legal']) for r in issue_audit_state.TRANSITIONS]
# (a) count control — dropping a row makes the count lockstep's operands unequal.
assert_eq("#546 table_test_lockstep_count: POSITIVE CONTROL — a dropped module row breaks the "
          "count lockstep (len no longer matches the driven rows)",
          True, len(_derived_rows[:-1]) != len(_TRANSITION_ROWS))
# (b) content control — flipping one legality bit makes the in-order content lockstep's
# operands unequal even though the count still matches (so the count assert alone would miss it).
_flipped = list(_derived_rows)
_flipped[0] = (_flipped[0][0], _flipped[0][1], not _flipped[0][2])
assert_eq("#546 table_test_lockstep_count: POSITIVE CONTROL — a flipped legality bit breaks the "
          "content lockstep while the count still matches",
          (True, True),
          (len(_flipped) == len(_TRANSITION_ROWS), _flipped != _TRANSITION_ROWS))

# arm_routing_rows — arm decisions from recorded facts alone, and the three marker
# literals byte-for-byte.
for (landed, hash_ok, prior, want_arm, want_marker) in [
    (True, True, False, 'file', None),
    (False, True, False, 'embed', 'write-failed'),
    (True, False, False, 'embed', 'digest-unrecorded'),
    # Both non-prior conditions false at once: the decided precedence tests
    # write_landed BEFORE hash_ok, so the write-failed marker wins.
    (False, False, False, 'embed', 'write-failed'),
    (True, True, True, 'embed', 'file-unreadable'),
    (False, False, True, 'embed', 'file-unreadable'),   # a prior unreadable wins
]:
    assert_eq(f"#546 arm_routing_rows: landed={landed} hash_ok={hash_ok} prior={prior}",
              (want_arm, want_marker),
              issue_audit_state.route_arm(landed, hash_ok, prior))

assert_eq("#546 arm_routing_rows: the three embed markers are preserved verbatim",
          ['draft embedded (file write failed)',
           'draft embedded (file unreadable)',
           'draft embedded (digest unrecorded)'],
          [issue_audit_state._EMBED_MARKER_TEXT[t]
           for t in ('write-failed', 'file-unreadable', 'digest-unrecorded')])

# carriage_evidence_rows / budget_retry_rows — classification, incl. the fixed retry
# precedence. Absent carriage evidence must behave EXACTLY like mismatched evidence.
for (arm, verdict, has_line, carriage, want) in [
    ('file', 'FILE', True, True, 'accept-file'),
    ('file', 'REVISE', True, True, 'accept-revise'),
    ('file', 'DRAFT-UNREADABLE', True, True, 'retry-embed'),
    ('embed', 'FILE', True, True, 'accept-file'),
    ('embed', 'REVISE', True, True, 'accept-revise'),
    ('inline', 'FILE', True, True, 'accept-file'),
    ('inline', 'REVISE', True, True, 'accept-revise'),
    ('embed', 'DRAFT-UNREADABLE', True, True, 'no-parseable-verdict'),
    ('inline', 'DRAFT-UNREADABLE', True, True, 'no-parseable-verdict'),
    # carriage mismatched vs. absent — the same classification, fail closed
    ('file', 'FILE', True, False, 'no-parseable-verdict'),
    ('embed', 'REVISE', True, False, 'no-parseable-verdict'),
    # a return that is both unreadable-prose AND verdict-less is classified by the
    # ABSENT VERDICT LINE — the fixed precedence
    ('file', None, False, True, 'no-parseable-verdict'),
    ('file', 'DRAFT-UNREADABLE', False, True, 'no-parseable-verdict'),
]:
    assert_eq(f"#546 carriage_evidence_rows/budget_retry_rows: arm={arm} verdict={verdict} "
              f"line={has_line} carriage={carriage}",
              want, issue_audit_state.classify_return(arm, verdict, has_line, carriage))


def _state(rounds, revisions=(), overrides=(), nonce='n0', reinit=False):
    return {'schema_version': issue_audit_state.SCHEMA_VERSION, 'slug': 's',
            'nonce': nonce, 'reinit_forced': reinit, 'automatic_reaudits_used': 0,
            'user_rounds_used': 0, 'rounds': list(rounds),
            'revisions': [{'ordinal': i + 1, 'after_round': r}
                          for i, r in enumerate(revisions)],
            'overrides': list(overrides), 'creation': None}


def _round(num, arm, outcome, digest='D1', findings=0, degraded=False, markers=()):
    return {'round': num,
            'attempts': [{'arm': arm, 'digest': digest, 'body_digest': 'B' + digest,
                          'sentinel_open': None, 'sentinel_close': None}],
            'no_parseable_retry_used': False, 'unreadable_retry_used': False,
            'outcome': outcome, 'findings_count': findings,
            'consumer_dimensions_appended': False, 'embed_markers': list(markers),
            'degraded': degraded}


# eligibility_grounds_table — the two approve-mode grounds and every not-eligible class.
_clean_file = _state([_round(1, 'file', 'FILE', 'D1')])
assert_eq("#546 eligibility_grounds_table: file-arm clean verdict, digest current -> eligible",
          ('eligible', 'file-identity'),
          (lambda r: (r['answer'], r['ground']))(
              issue_audit_state.evaluate_eligibility(_clean_file, 'approve', 'D1')))

# eligibility_byte_source_rows — the clean-run re-presentation row (no drift-induced
# false mismatch) and the revision-landed row.
assert_eq("#546 eligibility_byte_source_rows: an untouched clean draft re-presents "
          "eligible (no drift false-negative)",
          'eligible',
          issue_audit_state.evaluate_eligibility(_clean_file, 'approve', 'D1')['answer'])
assert_eq("#546 eligibility_byte_source_rows: a rewritten file refuses as unaudited-revision",
          ('not-eligible', 'unaudited-revision'),
          (lambda r: (r['answer'], r['reason']))(
              issue_audit_state.evaluate_eligibility(
                  _state([_round(1, 'file', 'FILE', 'D1')], revisions=(1,)),
                  'approve', 'D2')))

# The file-arm fail-closed row: the canonical file is absent at query time.
assert_eq("#546 eligibility_grounds_table: a file-arm epoch whose canonical file is "
          "absent at query time answers not-eligible (fail closed)",
          'not-eligible',
          issue_audit_state.evaluate_eligibility(_clean_file, 'approve', None)['answer'])

# The event-ordering ground: embed/inline arms, where no trustworthy canonical file exists.
for arm in ('embed', 'inline'):
    assert_eq(f"#546 eligibility_grounds_table: {arm}-arm clean verdict with no later "
              "revision -> eligible via the event-ordering ground",
              ('eligible', 'event-ordering'),
              (lambda r: (r['answer'], r['ground']))(
                  issue_audit_state.evaluate_eligibility(
                      _state([_round(1, arm, 'FILE', 'D1')]), 'approve', None)))
    assert_eq(f"#546 eligibility_grounds_table: {arm}-arm clean verdict PLUS a later "
              "revision -> unaudited-revision",
              ('not-eligible', 'unaudited-revision'),
              (lambda r: (r['answer'], r['reason']))(
                  issue_audit_state.evaluate_eligibility(
                      _state([_round(1, arm, 'FILE', 'D1')], revisions=(1,)),
                      'approve', None)))

assert_eq("#546 eligibility_grounds_table: unestablished state -> state-unestablished",
          ('not-eligible', 'state-unestablished'),
          (lambda r: (r['answer'], r['reason']))(
              issue_audit_state.evaluate_eligibility(None, 'approve', 'D1')))
assert_eq("#546 eligibility_grounds_table: fresh init, zero rounds -> no-verdict-round",
          ('not-eligible', 'no-verdict-round'),
          (lambda r: (r['answer'], r['reason']))(
              issue_audit_state.evaluate_eligibility(_state([]), 'approve', 'D1')))
assert_eq("#546 eligibility_grounds_table: the inline arm's verdict-less terminal -> "
          "no-verdict-round",
          ('not-eligible', 'no-verdict-round'),
          (lambda r: (r['answer'], r['reason']))(
              issue_audit_state.evaluate_eligibility(
                  _state([_round(1, 'inline', 'no-verdict', 'D1')]), 'approve', 'D1')))
# A no-verdict round does NOT shadow an older clean FILE round on unchanged bytes: the
# clean-scan breaks on REVISE (a positive "needs changes" signal) but falls through a
# no-verdict round (an inconclusive re-audit, not a revocation), so bytes cleanly
# audited in the FILE round still ground eligibility. Pin the current, deliberate
# behavior in BOTH directions so a regression that adds no-verdict to the break set
# (invalidating a legitimately-clean draft) turns the suite RED.
assert_eq("#546 eligibility_grounds_table: a newer no-verdict round does NOT shadow an "
          "older clean FILE round on unchanged bytes",
          ('eligible', 'file-identity'),
          (lambda r: (r['answer'], r['ground']))(
              issue_audit_state.evaluate_eligibility(
                  _state([_round(1, 'file', 'FILE', 'D1'),
                          _round(2, 'inline', 'no-verdict', 'D1')]), 'approve', 'D1')))
# The embed-arm sibling of the interleaving above: eligibility grounds on event
# ordering (no revision postdates the clean round), and the trailing no-verdict round
# does not shadow it — while evaluate_triggers fires T2 on the same state (asserted in
# t1_t2_rows below), the documented deliberate divergence: the boundary offer surfaces
# the inconclusive re-audit instead of revoking the clean verdict.
assert_eq("#546 eligibility_grounds_table: a newer no-verdict round does NOT shadow an "
          "older clean EMBED round with no revision (event-ordering ground holds)",
          ('eligible', 'event-ordering'),
          (lambda r: (r['answer'], r['ground']))(
              issue_audit_state.evaluate_eligibility(
                  _state([_round(1, 'embed', 'FILE', 'D1'),
                          _round(2, 'embed', 'no-verdict', 'D1')]), 'approve', None)))
# ...but a newer REVISE round DOES invalidate the older clean FILE round (the contrast
# that proves the no-verdict fall-through above is deliberate, not a scan bug).
assert_eq("#546 eligibility_grounds_table: a newer REVISE round DOES invalidate an older "
          "clean FILE round",
          'not-eligible',
          issue_audit_state.evaluate_eligibility(
              _state([_round(1, 'file', 'FILE', 'D1'),
                      _round(2, 'file', 'REVISE', 'D1')]), 'approve', 'D1')['answer'])

# override_epoch_rows — a current override grounds eligible; a stale one refuses.
_cur_override = _state([_round(1, 'file', 'REVISE', 'D1')], revisions=(1,), overrides=[
    {'kind': 'user-decline', 'surface': 'step4-offer', 'recorded_at_ordinal': 1,
     'draft_digest': 'D2'}])
assert_eq("#546 override_epoch_rows: an override recorded at the current ordinal and "
          "digest grounds eligible",
          ('eligible', 'override'),
          (lambda r: (r['answer'], r['ground']))(
              issue_audit_state.evaluate_eligibility(_cur_override, 'approve', 'D2')))
_stale_override = _state([_round(1, 'file', 'REVISE', 'D1')], revisions=(1, 1), overrides=[
    {'kind': 'user-decline', 'surface': 'step4-offer', 'recorded_at_ordinal': 1,
     'draft_digest': 'D2'}])
assert_eq("#546 override_epoch_rows: a later revision invalidates an earlier override "
          "-> stale-override",
          ('not-eligible', 'stale-override'),
          (lambda r: (r['answer'], r['reason']))(
              issue_audit_state.evaluate_eligibility(_stale_override, 'approve', 'D3')))
assert_eq("#546 override_epoch_rows: an override whose recorded digest no longer matches "
          "does not re-arm",
          'not-eligible',
          issue_audit_state.evaluate_eligibility(_cur_override, 'approve', 'D9')['answer'])

# approval_override_row — the accepted-re-audit -> REVISE -> revise terminal: an explicit
# user approval recorded as the third user-decline surface grounds eligible.
_approval_terminal = _state([_round(1, 'file', 'REVISE', 'D1')], revisions=(1,), overrides=[
    {'kind': 'user-decline', 'surface': 'step4-approval-after-exhausted-offer',
     'recorded_at_ordinal': 1, 'draft_digest': 'D2'}])
assert_eq("#546 approval_override_row: explicit approval past the exhausted offer surface "
          "grounds eligible (the audit informs, it never deadlocks filing)",
          'eligible',
          issue_audit_state.evaluate_eligibility(_approval_terminal, 'approve', 'D2')['answer'])

# iterate_mode_rows — iterate-ok on recorded-revision bytes; approve refuses the same state.
_mid_iterate = _state([_round(1, 'file', 'REVISE', 'D1')], revisions=(1,))
assert_eq("#546 iterate_mode_rows: just-revised bytes answer iterate-ok in iterate mode",
          'iterate-ok',
          issue_audit_state.evaluate_eligibility(_mid_iterate, 'iterate', 'D2')['answer'])
assert_eq("#546 iterate_mode_rows: the SAME state refuses in approve mode "
          "(iterate-ok is never a ground for approval)",
          ('not-eligible', 'unaudited-revision'),
          (lambda r: (r['answer'], r['reason']))(
              issue_audit_state.evaluate_eligibility(_mid_iterate, 'approve', 'D2')))
assert_eq("#546 iterate_mode_rows: iterate mode with no revision recorded refuses",
          ('not-eligible', 'no-revision-recorded'),
          (lambda r: (r['answer'], r['reason']))(
              issue_audit_state.evaluate_eligibility(_state([]), 'iterate', None)))

# eligibility_token_rows — deterministic, idempotent, digest-bound.
_t1 = issue_audit_state.evaluate_eligibility(_clean_file, 'approve', 'D1')['token']
_t2 = issue_audit_state.evaluate_eligibility(_clean_file, 'approve', 'D1')['token']
assert_eq("#546 eligibility_token_rows: repeated queries re-emit an identical token",
          _t1, _t2)
assert_eq("#546 eligibility_token_rows: an eligible answer emits a token", True,
          bool(_t1) and _t1.startswith('eat_'))
assert_eq("#546 eligibility_token_rows: tokens differ across digests", False,
          _t1 == issue_audit_state.issue_token('n0', 'file-identity', 'D2'))
assert_eq("#546 eligibility_token_rows: tokens differ across run nonces", False,
          issue_audit_state.issue_token('n0', 'file-identity', 'D1')
          == issue_audit_state.issue_token('n1', 'file-identity', 'D1'))
assert_eq("#546 eligibility_token_rows: summary re-emits the expected token as the "
          "string-compare comparand",
          _t1, issue_audit_state.summary_fields(_clean_file, 'D1')['token'])
# A token issued on D1 is NOT re-emitted after a revision record: the stale marker appears.
_revised = _state([_round(1, 'file', 'FILE', 'D1')], revisions=(1,))
_sf = issue_audit_state.summary_fields(_revised, 'D2')
assert_eq("#546 eligibility_token_rows: after a revision the pre-revision token is not "
          "re-emitted", None, _sf['token'])
assert_eq("#546 eligibility_token_rows: ... and the distinct stale-token marker appears "
          "instead", True, _sf['stale_token'])
# The OVERRIDE ground can also issue a token — over a REVISE/no-verdict epoch with NO
# FILE round in `done` at all — so a later revision must stale THAT token too, or a
# replayed override-ground token renders `token=none` (indistinguishable from
# never-eligible) instead of the distinct stale marker. Regression pin for the
# override-ground fail-open: `stale` keyed only on `any(outcome == 'FILE')` missed it.
_ovr_staled_sf = issue_audit_state.summary_fields(_stale_override, 'D3')
assert_eq("#546 eligibility_token_rows: a staled OVERRIDE-ground token (no FILE round) "
          "does not re-emit", None, _ovr_staled_sf['token'])
assert_eq("#546 eligibility_token_rows: ... and renders the distinct stale-token marker, "
          "not token=none (override-ground fail-open regression)",
          True, _ovr_staled_sf['stale_token'])
# The NO-VERDICT-epoch sibling of the staled-override row above: refusal precedence
# answers `no-verdict-round` before `stale-override` on a verdict-less epoch, so a
# reason-keyed derivation never sees the staled override there and rendered
# `token=none` (defined as "no token was ever issued") for a token that WAS issued and
# later invalidated. The state-derived predicate (an override recorded at a
# non-current ordinal) must render the distinct stale marker on this epoch too.
_nv_stale_override = _state(
    [_round(1, 'inline', 'no-verdict', 'D1')], revisions=(1,), overrides=[
        {'kind': 'user-decline', 'surface': 'step4-offer', 'recorded_at_ordinal': 0,
         'draft_digest': None}])
_nv_sf = issue_audit_state.summary_fields(_nv_stale_override, 'D2')
assert_eq("#546 eligibility_token_rows: a staled override token on a NO-VERDICT epoch "
          "does not re-emit", None, _nv_sf['token'])
assert_eq("#546 eligibility_token_rows: ... and renders stale-token, not token=none "
          "(refusal precedence hides stale-override behind no-verdict-round there)",
          True, _nv_sf['stale_token'])
# The still-current override (a token IS live) must NOT render stale — guards against the
# fix over-firing the marker on a legitimately-eligible override.
_ovr_live_sf = issue_audit_state.summary_fields(_cur_override, 'D2')
assert_eq("#546 eligibility_token_rows: a still-current override renders its live token, "
          "not the stale marker", False, _ovr_live_sf['stale_token'])

# t1_t2_rows — including state_unestablished_t2_holds.
assert_eq("#546 t1_t2_rows: T1 holds when the most recent completed round is REVISE",
          (True, False),
          (lambda t: (t['t1'], t['t2']))(
              issue_audit_state.evaluate_triggers(_state([_round(1, 'file', 'REVISE')]))))
assert_eq("#546 t1_t2_rows: T1 does not hold on a clean FILE round",
          False,
          issue_audit_state.evaluate_triggers(_clean_file)['t1'])
assert_eq("#546 t1_t2_rows: T2 holds when a revision postdates the last completed round",
          True,
          issue_audit_state.evaluate_triggers(
              _state([_round(1, 'file', 'FILE')], revisions=(1,)))['t2'])
assert_eq("#546 t1_t2_rows/state_unestablished_t2_holds: unestablished state -> T2 holds "
          "with reason state-unestablished (unknown is not zero)",
          (False, True, 'state-unestablished'),
          (lambda t: (t['t1'], t['t2'], t['reason']))(
              issue_audit_state.evaluate_triggers(None)))
assert_eq("#546 t1_t2_rows: the verdict-less terminal -> T1 does not hold, T2 does",
          (False, True),
          (lambda t: (t['t1'], t['t2']))(
              issue_audit_state.evaluate_triggers(
                  _state([_round(1, 'inline', 'no-verdict')]))))
assert_eq("#546 t1_t2_rows: zero completed rounds -> neither trigger holds",
          (False, False),
          (lambda t: (t['t1'], t['t2']))(issue_audit_state.evaluate_triggers(_state([]))))

# Valid-falsy: a recorded findings count of 0 is a REAL zero, distinct from unestablished.
assert_eq("#546 valid-falsy: a recorded findings count of 0 is a real zero", 0,
          issue_audit_state.summary_fields(
              _state([_round(1, 'file', 'FILE', findings=0)]), 'D1')['findings_count'])
assert_eq("#546 valid-falsy: no completed round -> findings count is None, not 0 "
          "(unknown is not zero)",
          None, issue_audit_state.summary_fields(_state([]), None)['findings_count'])
assert_eq("#546 valid-falsy: an empty rounds list is a legal live state that answers, "
          "never an error",
          'ok', issue_audit_state.summary_fields(_state([]), None)['state'])
# rounds_run is its OWN derivation (len(state['rounds'])), distinct from revisions_applied
# and verdict — pin its VALUE (not just its presence in the field set) over a multi-round
# fixture so a regression emitting len(completed_rounds) or an off-by-one turns RED. This
# re-establishes the deleted #522 "audit summary states the total rounds run" guarantee.
_two_rounds = _state([_round(1, 'file', 'REVISE', 'D1'), _round(2, 'file', 'FILE', 'D1')])
assert_eq("#546 summary rounds_run: the total number of rounds run is reported by value",
          2, issue_audit_state.summary_fields(_two_rounds, 'D1')['rounds_run'])
# An open (uncompleted) round still counts toward rounds_run (len of state['rounds'], not
# completed_rounds) — the discriminator against the len(completed_rounds) regression.
_open_plus_done = _state([_round(1, 'file', 'FILE', 'D1')])
_open_plus_done['rounds'].append({'round': 2, 'attempts': [], 'no_parseable_retry_used': False,
                                  'unreadable_retry_used': False, 'outcome': None,
                                  'findings_count': None, 'consumer_dimensions_appended': False,
                                  'embed_markers': [], 'degraded': False})
assert_eq("#546 summary rounds_run: an open round still counts (len(rounds), not "
          "len(completed_rounds))",
          2, issue_audit_state.summary_fields(_open_plus_done, 'D1')['rounds_run'])

print()
print("issue-audit-state: the malformed-state matrix (issue #546)")

# The CLAUDE.md adversarial input-shape matrix, widened to this tool-owned state JSON.
# Every row must raise StateError (queries then answer state-unestablished, exit 0;
# mutations exit non-zero with a named breadcrumb) — never a crash presented as a value.
_GOOD = {'schema_version': issue_audit_state.SCHEMA_VERSION, 'slug': 's', 'nonce': 'n0',
         'rounds': [], 'revisions': [], 'overrides': []}


def _malformed(name, doc, slug='s'):
    assert_raises(f"#546 malformed-state matrix: {name}", issue_audit_state.StateError,
                  lambda: issue_audit_state._validate(doc, slug))


_malformed('wrong-type top level (array)', [])
_malformed('wrong-type top level (bare scalar)', 'nope')
_malformed('wrong-type top level (null)', None)
_malformed('missing required key (nonce)', {k: v for k, v in _GOOD.items() if k != 'nonce'})
_malformed('missing required key (rounds)', {k: v for k, v in _GOOD.items() if k != 'rounds'})
_malformed('schema-version mismatch', dict(_GOOD, schema_version=999))
_malformed('slug mismatch', dict(_GOOD, slug='other'))
_malformed('wrong-type field (rounds is an object)', dict(_GOOD, rounds={}))
_malformed('wrong-type field (nonce is an int)', dict(_GOOD, nonce=7))
_malformed('empty nonce', dict(_GOOD, nonce=''))
_malformed('duplicate round numbers',
           dict(_GOOD, rounds=[_round(1, 'file', 'FILE'), _round(1, 'file', 'FILE')]))
_malformed('out-of-order round numbers',
           dict(_GOOD, rounds=[_round(2, 'file', 'FILE'), _round(1, 'file', 'FILE')]))
_malformed('an arm outside the canonical set',
           dict(_GOOD, rounds=[_round(1, 'bogus-arm', 'FILE')]))
_malformed('an outcome outside the canonical set',
           dict(_GOOD, rounds=[_round(1, 'file', 'MAYBE')]))
_malformed('an embed marker outside the canonical set',
           dict(_GOOD, rounds=[_round(1, 'embed', 'FILE', markers=('bogus',))]))
_malformed('an override kind outside the canonical set',
           dict(_GOOD, overrides=[{'kind': 'bogus', 'recorded_at_ordinal': 0}]))
_malformed('wrong-type findings_count (a string)',
           dict(_GOOD, rounds=[dict(_round(1, 'file', 'FILE'), findings_count='two')]))
_malformed('a round with no attempts recorded',
           dict(_GOOD, rounds=[dict(_round(1, 'file', 'FILE'), attempts=[])]))
_malformed('a round missing a required key', dict(_GOOD, rounds=[{'round': 1}]))

# The valid-falsy control: an empty rounds list is NOT malformed — it must validate.
assert_eq("#546 malformed-state matrix (valid-falsy control): an empty rounds list is "
          "valid state, not a malformed shape",
          's', issue_audit_state._validate(dict(_GOOD), 's')['slug'])

print()
print("issue-audit-state: review-round hardening (issue #546, PR #552 review)")

# (1) Malformed read-surface fields the QUERIES consume. Pre-fix, each of these passed
# _validate and then crashed a query (AttributeError/TypeError) — a crashed read
# presented as a non-zero query exit, violating the two-class contract.
_malformed('a revision record that is not an object', dict(_GOOD, revisions=['x']))
_malformed('a revision record missing its ordinal', dict(_GOOD, revisions=[{'after_round': 0}]))
_malformed('a non-integer revision ordinal',
           dict(_GOOD, revisions=[{'ordinal': 'one', 'after_round': 0}]))
_malformed('a non-integer after_round on a revision record',
           dict(_GOOD, revisions=[{'ordinal': 1, 'after_round': 'zero'}]))
# The per-round retry booleans DRIVE dispatch routing, so a hand-corrupted non-bool must
# fail closed at the read boundary exactly like pending/outcome/findings_count above: a
# falsy-corrupted unreadable_retry_used would admit a SECOND DRAFT-UNREADABLE re-dispatch,
# a fail OPEN of the 'exactly one per round' bound this boundary exists to catch.
_bad_unreadable = _round(1, 'file', 'FILE')
_bad_unreadable['unreadable_retry_used'] = 'yes'
_malformed('a non-boolean unreadable_retry_used (routing-decision fail-open)',
           dict(_GOOD, rounds=[_bad_unreadable]))
_bad_noparse = _round(1, 'file', 'FILE')
_bad_noparse['no_parseable_retry_used'] = 1
_malformed('a non-boolean no_parseable_retry_used (routing-decision fail-open)',
           dict(_GOOD, rounds=[_bad_noparse]))
_malformed('a non-integer automatic_reaudits_used counter',
           dict(_GOOD, automatic_reaudits_used='two'))
_malformed('a non-integer user_rounds_used counter', dict(_GOOD, user_rounds_used='three'))
_malformed('a creation record that is not an object', dict(_GOOD, creation='yes'))
_malformed('a creation record missing its body_only_digest',
           dict(_GOOD, creation={'epoch_round': 1}))
assert_eq("#546 review-round (valid-falsy control): creation=None is a legal live state",
          's', issue_audit_state._validate(dict(_GOOD, creation=None), 's')['slug'])

# (2) The creation-attestation status is surfaced in the audit-summary fields (AC:
# "a mismatch is surfaced in the reported outcome and the audit-summary fields").
_att_state = _state([_round(1, 'file', 'FILE', 'D1')])
_att_state['creation'] = {'epoch_round': 1, 'epoch_arm': 'file',
                          'body_only_digest': 'BD1', 'attestation': 'mismatch'}
assert_eq("#546 attestation_summary_rows: a recorded attestation mismatch is surfaced "
          "in the summary fields", 'mismatch',
          issue_audit_state.summary_fields(_att_state, 'D1')['attestation'])
assert_eq("#546 attestation_summary_rows: no creation epoch -> attestation reads none "
          "(unknown is not a pass)", 'none',
          issue_audit_state.summary_fields(_clean_file, 'D1')['attestation'])

# The summary derivation threads digest_failed like the approve gate does: an
# undigestible draft yields NO live token and NO false stale-token marker.
assert_eq("#546 draft_undigestible_rows: the summary never renders a live token for an "
          "undigestible draft",
          (None, False),
          (lambda f: (f['token'], f['stale_token']))(
              issue_audit_state.summary_fields(_clean_file, None, digest_failed=True)))

# summary_schema_rows — `summary_fields` answers on two INDEPENDENT branches
# (state-unestablished and ok). The query surface renders the returned mapping key by key,
# so a field added to one branch and forgotten on the other is a KeyError at a surface whose
# contract is always-exit-0 — a two-class-contract violation, not a cosmetic slip. Both
# branches are routed through the single `_summary` constructor, which fails loudly at the
# call. These rows pin BOTH halves: that the two live branches actually agree, and that the
# constructor is a real guard (a non-tautological positive control — it rejects the drift it
# exists to catch, rather than merely existing).
assert_eq("#546 summary_schema_rows: the two summary_fields branches answer with the "
          "IDENTICAL field set (a KeyError at the query surface otherwise)",
          sorted(issue_audit_state.summary_fields(None)),
          sorted(issue_audit_state.summary_fields(_clean_file, 'D1')))
assert_eq("#546 summary_schema_rows: ... and that field set is exactly _SUMMARY_FIELDS",
          sorted(issue_audit_state._SUMMARY_FIELDS),
          sorted(issue_audit_state.summary_fields(None)))
# Positive control for the two rows above: the constructor REJECTS a branch that drops a
# field, so their agreement is enforced rather than coincidental.
assert_raises("#546 summary_schema_rows: _summary rejects a branch that OMITS a field",
              AssertionError,
              lambda: issue_audit_state._summary(
                  **{k: None for k in issue_audit_state._SUMMARY_FIELDS[:-1]}))
assert_raises("#546 summary_schema_rows: _summary rejects a branch that adds an UNKNOWN "
              "field (a typo'd key would otherwise render as a silently missing field)",
              AssertionError,
              lambda: issue_audit_state._summary(
                  **{k: None for k in issue_audit_state._SUMMARY_FIELDS}, bogus_field=1))

print()
print("issue-audit-state: shadow-round hardening (issue #546, PR #552 shadow review)")

# (1) Read-surface sub-shapes the mutations index unconditionally: a corrupted attempt
# record (missing digest/body_digest, non-string sentinel), a malformed override record
# (bad surface, non-int ordinal), a non-sequential revision ordinal chain, and an
# off-set creation attestation must all collapse to StateError — never a KeyError
# traceback from a mutation that promised a named breadcrumb.
_malformed('an attempt record missing its digest',
           dict(_GOOD, rounds=[dict(_round(1, 'file', 'FILE'),
                                    attempts=[{'arm': 'file', 'body_digest': 'B'}])]))
_malformed('an attempt record missing its body_digest',
           dict(_GOOD, rounds=[dict(_round(1, 'file', 'FILE'),
                                    attempts=[{'arm': 'file', 'digest': 'D'}])]))
_malformed('a non-string attempt sentinel',
           dict(_GOOD, rounds=[dict(_round(1, 'embed', 'FILE'),
                                    attempts=[{'arm': 'embed', 'digest': 'D',
                                               'body_digest': 'B', 'sentinel_open': 7,
                                               'sentinel_close': 'X'}])]))
_malformed('an override record with a surface outside the canonical set',
           dict(_GOOD, overrides=[{'kind': 'user-decline', 'surface': 'bogus',
                                   'recorded_at_ordinal': 0, 'draft_digest': None}]))
_malformed('an override record with a non-integer recorded_at_ordinal',
           dict(_GOOD, overrides=[{'kind': 'user-decline', 'surface': 't1t2-boundary',
                                   'recorded_at_ordinal': 'zero', 'draft_digest': None}]))
# A present-but-EMPTY override draft_digest must be rejected at the read boundary: an empty
# bound digest would compare equal to an empty computed digest on the override ground (a
# fail-open). Double-defended in practice (hash_bytes can never emit ''), so this pins the
# read-boundary half explicitly. Well-formed up to the draft_digest check (kind/surface/
# ordinal all valid) so the reject attributes to that guard, not a precondition.
_malformed('an override record with a present-but-empty draft_digest',
           dict(_GOOD, overrides=[{'kind': 'user-decline', 'surface': 't1t2-boundary',
                                   'recorded_at_ordinal': 0, 'draft_digest': ''}]))
# De-vacuumed: the old fixture omitted `floor_round`, so it was rejected by the
# floor_round-not-integer precondition and NEVER reached the ordinal-chain guard it
# names — a regression deleting that guard would have kept it green. Supply floor_round
# so the fixture is well-formed up to the ordinal-chain check, and ATTRIBUTE the reject
# to that guard's own breadcrumb (not a bare StateError) so a sibling guard firing first
# can no longer masquerade as this rejection.
try:
    issue_audit_state._validate(
        dict(_GOOD, revisions=[{'ordinal': 2, 'after_round': 0, 'floor_round': 0}]), 's')
    assert_eq("#546 malformed-state matrix: a revision ordinal chain that is not 1..N",
              "raised StateError", "no exception raised")
except issue_audit_state.StateError as _e:
    assert_eq("#546 malformed-state matrix: a revision ordinal chain that is not 1..N "
              "(rejected by the ordinal-chain guard, not a precondition)",
              True, 'ordinal chain broken' in str(_e))
# The read-boundary staleness gate: a WELL-FORMED revision record (all three ints, valid
# ordinal chain) whose after_round < floor_round must be rejected here — the source flags
# this as "the gate": below-floor after_round fails the event-ordering staleness guard
# OPEN, so a revised-never-audited draft would answer eligible and emit-body would emit it
# at exit 0. Only the WRITE boundary was tested before; this pins the READ boundary.
try:
    issue_audit_state._validate(
        dict(_GOOD, revisions=[{'ordinal': 1, 'after_round': 0, 'floor_round': 1}]), 's')
    assert_eq("#546 malformed-state matrix: a below-floor after_round (read-boundary "
              "staleness gate)", "raised StateError", "no exception raised")
except issue_audit_state.StateError as _e:
    assert_eq("#546 malformed-state matrix: a below-floor after_round is rejected at the "
              "read boundary (fail-open staleness gate)",
              True, 'below the floor' in str(_e))
# De-vacuumed: the old fixture omitted epoch_round/epoch_arm, so it was rejected by the
# epoch_round-not-integer precondition and NEVER reached the attestation-canonical guard it
# names — a regression deleting that guard would have stayed green. The attestation field
# has a LIVE reader (summary_fields renders `attestation=<token>` and treats it as
# forward-only tamper evidence), so this guard is load-bearing. Supply a well-formed
# creation record up to the attestation check and ATTRIBUTE the reject to that guard's own
# breadcrumb, exactly as the ordinal-chain row above does.
try:
    issue_audit_state._validate(
        dict(_GOOD, creation={'body_only_digest': 'B', 'epoch_round': 1, 'epoch_arm': 'file',
                              'attestation': 'maybe'}), 's')
    assert_eq("#546 malformed-state matrix: a creation attestation outside the canonical set",
              "raised StateError", "no exception raised")
except issue_audit_state.StateError as _e:
    assert_eq("#546 malformed-state matrix: a creation attestation outside the canonical set "
              "(rejected by the attestation guard, not a precondition)",
              True, 'attestation status outside the canonical set' in str(_e))
# The two sibling creation sub-guards (no reader today, but closed at the read boundary):
# each fixture is well-formed up to the guard it names so the reject is not a precondition.
_malformed('a creation record with a non-integer epoch_round',
           dict(_GOOD, creation={'body_only_digest': 'B', 'epoch_round': 'one',
                                 'epoch_arm': 'file'}))
_malformed('a creation record with an epoch_arm outside the canonical set',
           dict(_GOOD, creation={'body_only_digest': 'B', 'epoch_round': 1,
                                 'epoch_arm': 'bogus'}))

# (2) evaluate_eligibility's mode is a closed set like every other vocabulary: an
# off-set mode must raise loudly, never silently take the permissive approve path.
assert_raises("#546 shadow-round: an off-vocabulary eligibility mode raises, never "
              "defaults to approve", AssertionError,
              lambda: issue_audit_state.evaluate_eligibility(_clean_file, 'aprove', 'D1'))

# (3) A file-arm clean round queried with NO digest supplied must not claim the token
# went stale (nothing was compared) — token None, stale_token False.
assert_eq("#546 shadow-round: absent draft digest on a file-arm epoch never renders "
          "stale-token", (None, False),
          (lambda f: (f['token'], f['stale_token']))(
              issue_audit_state.summary_fields(_clean_file, None)))
assert_eq("#546 shadow-round: ... while a genuinely staled event-ordering epoch still "
          "marks stale with no digest supplied", True,
          issue_audit_state.summary_fields(
              _state([_round(1, 'embed', 'FILE')], revisions=(1,)), None)['stale_token'])
assert_eq("#546 shadow-round: a file-arm epoch whose clean round a revision postdates "
          "marks stale even with no digest supplied (positive invalidation evidence)",
          True,
          issue_audit_state.summary_fields(
              _state([_round(1, 'file', 'FILE')], revisions=(1,)), None)['stale_token'])

# (4) A dispatch recorded for a pending retry clears the pending action: next-action
# then answers the fail-closed awaiting token, never the already-spent retry action.
_pending_round = _state([dict(_round(1, 'file', None), outcome=None,
                              pending='dispatch-embed-retry')])
assert_eq("#546 shadow-round: pending survives until the retry dispatch is recorded",
          'dispatch-embed-retry',
          issue_audit_state.next_action(_pending_round, 1))

# (5) A slug that escapes .devflow/tmp is refused as untrustworthy state, fail closed.
assert_raises("#546 shadow-round: a path-escaping slug raises StateError",
              issue_audit_state.StateError,
              lambda: issue_audit_state.state_path('../../evil'))
assert_raises("#546 shadow-round: a slash-carrying slug raises StateError",
              issue_audit_state.StateError,
              lambda: issue_audit_state.state_path('a/b'))

print()
print("issue-audit-state: iteration-3 hardening (issue #546, PR #552 review)")

# State-shape hardening for the iteration-3 fields (the after-round bounds themselves
# are driven at the CLI in run.sh's iter3_hardening_rows; these rows pin the sibling
# _validate additions).
_malformed('a negative findings_count',
           dict(_GOOD, rounds=[dict(_round(1, 'file', 'FILE'), findings_count=-3)]))
_malformed('a non-boolean reinit_forced', dict(_GOOD, reinit_forced='yes'))
assert_eq("#546 iter3: _TRANSITION_REASONS gains attestation-already-recorded",
          True, 'attestation-already-recorded' in issue_audit_state._TRANSITION_REASONS)

# iteration-5: the no-digest-supplied reason is distinct from unaudited-revision (a
# file-arm clean epoch queried with no digest was never compared at all).
assert_eq("#546 iter5: no digest supplied over a file-arm clean epoch names its own reason",
          ('not-eligible', 'no-digest-supplied'),
          (lambda r: (r['answer'], r['reason']))(
              issue_audit_state.evaluate_eligibility(_clean_file, 'approve', None)))
assert_eq("#546 iter5: ... while a revision-postdated file-arm epoch still refuses "
          "unaudited-revision with no digest",
          'unaudited-revision',
          issue_audit_state.evaluate_eligibility(
              _state([_round(1, 'file', 'FILE')], revisions=(1,)),
              'approve', None)['reason'])

print()
print("issue-audit-state: convergence-shadow hardening (issue #546, PR #552 shadow)")

# The newest completed verdict-bearing round wins: a later REVISE round on the SAME
# bytes invalidates an older clean FILE round (probe-confirmed fail-open otherwise).
assert_eq("#546 conv-shadow: a later REVISE round invalidates an earlier clean FILE "
          "round on unchanged bytes",
          ('not-eligible', 'unaudited-revision'),
          (lambda r: (r['answer'], r['reason']))(
              issue_audit_state.evaluate_eligibility(
                  _state([_round(1, 'file', 'FILE', 'D1'),
                          _round(2, 'file', 'REVISE', 'D1')]),
                  'approve', 'D1')))
assert_eq("#546 conv-shadow: ... and a later clean FILE round still grounds eligibility",
          'eligible',
          issue_audit_state.evaluate_eligibility(
              _state([_round(1, 'file', 'REVISE', 'D1'),
                      _round(2, 'file', 'FILE', 'D1')]),
              'approve', 'D1')['answer'])

# The persisted pending domain is the WRITER's domain: a corrupted 'proceed' collapses
# the file rather than walking the orchestrator past an unreturned audit.
_malformed('a pending value outside the writer domain (proceed)',
           dict(_GOOD, rounds=[dict(_round(1, 'file', None), outcome=None,
                                    pending='proceed')]))

# A digest-bound override queried with no digest names the caller omission.
assert_eq("#546 conv-shadow: a digest-bound override with no digest supplied names "
          "no-digest-supplied, not stale-override",
          'no-digest-supplied',
          issue_audit_state.evaluate_eligibility(
              _state([_round(1, 'file', 'REVISE', 'D1')],
                     overrides=[{'kind': 'user-decline', 'surface': 't1t2-boundary',
                                 'recorded_at_ordinal': 0, 'draft_digest': 'D1'}]),
              'approve', None)['reason'])

# (3) An unreadable/unhashable supplied draft refuses with the DISTINCT reason
# draft-undigestible in approve mode — never misattributed as unaudited-revision,
# and never eligible on any ground (fail closed, overrides included).
assert_eq("#546 draft_undigestible_rows: digest failure refuses with its own reason, "
          "not unaudited-revision",
          ('not-eligible', 'draft-undigestible'),
          (lambda r: (r['answer'], r['reason']))(
              issue_audit_state.evaluate_eligibility(
                  _state([_round(1, 'file', 'FILE', 'D1')]), 'approve', None,
                  digest_failed=True)))
assert_eq("#546 draft_undigestible_rows: a digest failure blocks even the override ground",
          'draft-undigestible',
          issue_audit_state.evaluate_eligibility(
              _state([_round(1, 'file', 'FILE', 'D1')],
                     overrides=[{'kind': 'user-decline', 'surface': 't1t2-boundary',
                                 'recorded_at_ordinal': 0, 'draft_digest': None}]),
              'approve', None, digest_failed=True)['reason'])

# (4) An open, unreturned round answers a fail-closed token, never `proceed`.
_open_round = _state([dict(_round(1, 'file', None), outcome=None)])
assert_eq("#546 next_action_rows: an open unreturned round answers "
          "round-open-awaiting-return, never proceed",
          'round-open-awaiting-return',
          issue_audit_state.next_action(_open_round, 1))

# (5) split_body edge-case rows — the producer of the body-only digest, driven directly.
_sb = issue_audit_state.split_body
assert_eq("#546 split_body_rows: no title heading -> whole content is the body",
          b'plain text\nmore\n', _sb(b'plain text\nmore\n'))
assert_eq("#546 split_body_rows: a level-2 heading first is NOT a title",
          b'## Context\nbody\n', _sb(b'## Context\nbody\n'))
assert_eq("#546 split_body_rows: a bare '#' line is accepted as the title",
          b'body\n', _sb(b'#\n\nbody\n'))
assert_eq("#546 split_body_rows: leading blank lines are skipped before the title",
          b'body\n', _sb(b'\n\n# Title\n\nbody\n'))
assert_eq("#546 split_body_rows: a title-only draft yields an empty body",
          b'', _sb(b'# Title\n'))
assert_eq("#546 split_body_rows: CRLF line endings are preserved byte-for-byte",
          b'body\r\nmore\r\n', _sb(b'# Title\r\n\r\nbody\r\nmore\r\n'))
assert_eq("#546 split_body_rows: empty input returns the empty bytes unchanged "
          "(the no-lines early return, never an index into an empty list)",
          b'', _sb(b''))

# (6) findings_count from a REFUSED completion (failed carriage / no parseable verdict)
# is never recorded onto the round — an unproven tally must not leak into the summary.
# Driven at the classify/record seam: classify_return refuses, and the recording gate
# keys on the accepted classifications only (exercised end-to-end by the run.sh CLI
# block; here the pure gate predicate is pinned).
assert_eq("#546 refused_return_rows: a refused completion classification is never an "
          "accepted one", False,
          issue_audit_state.classify_return('file', 'FILE', True, False)
          in ('accept-file', 'accept-revise'))

print()
print("issue-audit-state: coverage-gap rows (issue #546, PR #552 review)")

# (1) save_state's failed-persist cleanup: when os.replace cannot land (here the
# target path is occupied by a directory), the failure surfaces as StateError with
# the could-not-persist breadcrumb AND the partial .json.tmp is removed — a failed
# persist never leaves a stray temp file in the evidence-bearing tmp directory.
with tempfile.TemporaryDirectory() as _td:
    _ss_root = Path(_td)
    (_ss_root / '.devflow' / 'tmp' / 'issue-audit-state-s.json').mkdir(parents=True)
    try:
        issue_audit_state.save_state(_state([]), 's', root=_ss_root)
        assert_eq("#546 save_state_cleanup_rows: a persist the OS refuses raises "
                  "StateError", "raised StateError", "no exception raised")
    except issue_audit_state.StateError as _e:
        assert_eq("#546 save_state_cleanup_rows: a persist the OS refuses raises "
                  "StateError with the could-not-persist breadcrumb",
                  True, 'could not persist state' in str(_e))
    assert_eq("#546 save_state_cleanup_rows: ... and no partial .json.tmp survives "
              "the failed persist",
              [], list((_ss_root / '.devflow' / 'tmp').glob('*.json.tmp')))

# (2) The attestation trailing-newline tolerance swallows a _DigestError raised by
# the SECOND (newline-stripped) hash: the compare stays a well-defined mismatch —
# never an unhandled exception, which would leave the run with no attestation record
# at all (rendering attestation=none, the never-attempted misattribution). Driven
# with hash_bytes stubbed so the swallow itself is what the row exercises: the first
# call establishes the mismatch, the retry raises.
with tempfile.TemporaryDirectory() as _td:
    _att_root = Path(_td)
    _att_doc = _state([_round(1, 'file', 'FILE', 'D1')])
    _att_doc['creation'] = {'epoch_round': 1, 'epoch_arm': 'file',
                            'body_only_digest': 'BD1', 'attestation': None}
    issue_audit_state.save_state(_att_doc, 's', root=_att_root)
    _hash_calls = []

    def _hash_stub(data):
        _hash_calls.append(data)
        if len(_hash_calls) > 1:
            raise issue_audit_state._DigestError('stub: retry hash unavailable')
        return 'NOT-BD1'

    _orig_repo_root = issue_audit_state._repo_root
    _orig_hash = issue_audit_state.hash_bytes
    _orig_stdin = sys.stdin
    _att_out = io.StringIO()
    try:
        issue_audit_state._repo_root = lambda: _att_root
        issue_audit_state.hash_bytes = _hash_stub
        sys.stdin = types.SimpleNamespace(buffer=io.BytesIO(b'fetched body\n'))
        try:
            with contextlib.redirect_stdout(_att_out), \
                    contextlib.redirect_stderr(io.StringIO()):
                issue_audit_state.cmd_record_creation_attestation(
                    argparse.Namespace(slug='s', nonce='n0',
                                       attestation_unavailable=False))
            _att_ended = 'returned'
        except SystemExit as _e:
            _att_ended = f'SystemExit({_e.code})'
        except Exception as _e:
            _att_ended = f'{type(_e).__name__}: {_e}'
    finally:
        issue_audit_state._repo_root = _orig_repo_root
        issue_audit_state.hash_bytes = _orig_hash
        sys.stdin = _orig_stdin
    assert_eq("#546 attestation_swallow_rows: a _DigestError on the newline-stripped "
              "retry hash is swallowed (the command completes)",
              'returned', _att_ended)
    assert_eq("#546 attestation_swallow_rows: ... the retry hash WAS attempted, so "
              "the swallow (not a skipped tolerance) is what ran",
              2, len(_hash_calls))
    assert_eq("#546 attestation_swallow_rows: ... and the outcome stays the "
              "well-defined mismatch",
              'attestation=mismatch\n', _att_out.getvalue())
    assert_eq("#546 attestation_swallow_rows: ... persisted as mismatch, never "
              "half-recorded",
              'mismatch',
              issue_audit_state.load_state('s', root=_att_root)['creation']['attestation'])

# (3) record-return's negative --findings-count guard fires its OWN breadcrumb (a
# tally cannot be negative) before anything persists; findings-count 0 on the SAME
# fixture is the valid-falsy positive control — a real zero is accepted and recorded.
with tempfile.TemporaryDirectory() as _td:
    _rr_root = Path(_td)
    issue_audit_state.save_state(_state([_round(1, 'inline', None)]), 's', root=_rr_root)

    def _rr_args(count):
        return argparse.Namespace(slug='s', nonce='n0', round=1, verdict='FILE',
                                  findings_count=count,
                                  consumer_dimensions_appended=False,
                                  carriage_object_id=None,
                                  carriage_sentinel_open=None,
                                  carriage_sentinel_close=None)

    _orig_repo_root = issue_audit_state._repo_root
    _rr_err = io.StringIO()
    try:
        issue_audit_state._repo_root = lambda: _rr_root
        try:
            with contextlib.redirect_stdout(io.StringIO()), \
                    contextlib.redirect_stderr(_rr_err):
                issue_audit_state.cmd_record_return(_rr_args(-1))
            _rr_code = None
        except SystemExit as _e:
            _rr_code = _e.code
        assert_eq("#546 record_return_findings_rows: a negative findings count exits "
                  "non-zero", 1, _rr_code)
        assert_eq("#546 record_return_findings_rows: ... attributed to the "
                  "negative-tally guard's own breadcrumb",
                  True, 'is negative; a findings tally cannot be' in _rr_err.getvalue())
        assert_eq("#546 record_return_findings_rows: ... and the refused return never "
                  "persisted (the round is still open)",
                  None,
                  issue_audit_state.load_state('s', root=_rr_root)['rounds'][0]['outcome'])
        _rr_out = io.StringIO()
        with contextlib.redirect_stdout(_rr_out):
            issue_audit_state.cmd_record_return(_rr_args(0))
        assert_eq("#546 record_return_findings_rows: findings-count 0 on the same "
                  "fixture is accepted (valid-falsy, a real zero)",
                  'classification=accept-file outcome=FILE\n', _rr_out.getvalue())
        assert_eq("#546 record_return_findings_rows: ... and the real zero is recorded",
                  0,
                  issue_audit_state.load_state(
                      's', root=_rr_root)['rounds'][0]['findings_count'])
    finally:
        issue_audit_state._repo_root = _orig_repo_root

print()
print(f"{PASS} passed, {FAIL} failed")
sys.exit(0 if FAIL == 0 else 1)
