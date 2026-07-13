#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""DevFlow workpad helper for the /implement skill.

The /implement orchestrator maintains exactly one marker-tagged comment per
GitHub issue (the workpad). Claude Code's Bash tool spawns a fresh shell per
call, so shell functions and env vars don't survive across phase boundaries.
This script gives the orchestrator a stateless CLI that re-derives everything
from arguments + live GitHub state on each call.

All subcommands shell out to `gh` for GitHub API access (same auth path as
the rest of devflow). The workpad marker is read from the repo-root
`.devflow/config.json` directly in-process (issue #275: no `.sh` exec, so it
works on Windows), anchored to the git repo root via a native `git rev-parse`
subprocess (issue #295: falling back to cwd) so a subdirectory invocation still
reads the consumer's root config, falling back to the built-in default
`<!-- devflow:workpad -->` when the config file or key is absent (so it works
with no config).

Usage:
    workpad.py id        ISSUE [--marker M]
    workpad.py body      COMMENT_ID
    workpad.py patch     COMMENT_ID BODY_FILE
    workpad.py create    ISSUE BODY_FILE
    workpad.py new-body  ISSUE [--run-link V] [--branch V] [--marker M]
    workpad.py now
    workpad.py update    ISSUE [mutations...] [--marker M]

Subcommands that locate the workpad by its marker comment (`id`, `new-body`,
`update`) accept `--marker` to target a non-default marker — /devflow:review
uses it to drive its own `<!-- devflow:review-progress -->` comment. The flag
is preferred over the `DEVFLOW_WORKPAD_MARKER` env var: a leading
env-assignment makes the command un-matchable against the cloud allow-list.

`id` exits 2 with empty stdout when it scanned cleanly but no workpad exists
yet (so callers can detect "first run" via `$?`); exit 1 is reserved for a
real gh-api/parse error, so a transient failure is never mistaken for "first
run" (which would post a duplicate comment).

`update` is the high-level mutation entry point used by /implement at every
phase boundary. It re-fetches the workpad body, applies the requested
mutations, auto-updates `Last updated`, and PATCHes the result. A *structural*
failure (missing section/front-matter line) aborts the call before any PATCH; a
*volatile* per-row tick miss (a `--tick-*`/`--tick-*-n` that does not resolve)
is reported and exits non-zero, but the call's other mutations still PATCH.
Notes (`--note`) are append-only and nest under their lifecycle phase inside
the ## Progress section; Devflow Reflection accumulates bullets; checkbox
sections are mutated in place rather than rewritten. See `workpad.py update
--help` for the available mutation flags.
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys
from pathlib import Path

if sys.version_info < (3, 11):  # fail fast, before any PEP 604 annotation is evaluated below
    sys.stderr.write(
        "devflow: Python 3.11+ required (found %s.%s.%s). This helper requires"
        " features of Python 3.11+. Install Python 3.11+; on Windows/Git-Bash"
        " run scripts/provision-python3-shim.sh --apply (see docs/install.md).\n"
        % sys.version_info[:3]
    )
    sys.exit(1)

# The gh binary to shell out to. `DEVFLOW_GH` (the documented override the shell
# helpers resolve via lib/resolve-gh.sh) wins when set and non-empty; otherwise
# bare `gh`. Read once at import so every subprocess call uses the same binary.
GH = os.environ.get("DEVFLOW_GH") or "gh"


def _force_utf8_streams():
    """Force stdout/stderr to UTF-8, idempotently and defensively. Called from
    the CLI entry path only (not at import) so importing this module for unit
    tests never mutates the importer's global streams. Windows' default codec is
    cp1252, so the rocket/em-dash this script emits would otherwise raise
    `UnicodeEncodeError`; reconfigure overrides even a hostile `PYTHONIOENCODING`.
    The guard tolerates a stream replaced with a non-`TextIOWrapper` (e.g. a
    test's `io.StringIO`), which has no `reconfigure`."""
    for _stream in (sys.stdout, sys.stderr):
        try:
            _stream.reconfigure(encoding="utf-8")
        except (AttributeError, ValueError):
            pass


def _run(cmd, *, stdout=subprocess.PIPE, stdin=None):
    # `encoding="utf-8"` pins both directions of the gh pipe: DECODING gh's
    # output (issue/comment bodies, titles — routinely non-ASCII) and ENCODING
    # any stdin, so neither raises under a non-UTF-8 ambient codec. Implies text
    # mode, so `text=True` is dropped (passing both is redundant/conflicting).
    return subprocess.run(
        cmd, check=True, stdin=stdin, stdout=stdout,
        stderr=subprocess.PIPE, encoding="utf-8",
    )


def _fail(prefix, exc, code=1):
    # `code` defaults to 1 (the historical contract for every subcommand). Only
    # cmd_status overrides it to 3 on its gh-api/transport/auth failure paths, so
    # the cloud stall backstop can tell an auth/transport failure (the workpad
    # may be healthy — the READ failed) apart from a genuinely unreadable
    # workpad. Every other caller keeps exit 1 unchanged.
    msg = exc.stderr.strip() if isinstance(exc, subprocess.CalledProcessError) else str(exc)
    sys.stderr.write(f"workpad.py {prefix}: {msg}\n")
    sys.exit(code)


def _repo_root():
    # Resolve the git repo root so config reads anchor there, not to cwd (issue
    # #295) — the Python mirror of lib/config-source.sh's
    # `git rev-parse --show-toplevel 2>/dev/null || pwd`. A native `git` subprocess
    # (like the existing `gh` calls) is Windows-safe — unlike exec-ing a .sh
    # ([WinError 193], issue #275). Returns the root string, or None when not in a
    # git tree (git rev-parse rc!=0) or git cannot run at all (OSError) — the caller
    # then falls back to Path.cwd(), degrading exactly as the pre-#295 code did.
    try:
        r = _run(['git', 'rev-parse', '--show-toplevel'])
    except (subprocess.CalledProcessError, OSError):
        return None
    root = r.stdout.strip()
    return root or None


def _git_root_error_suffix():
    # Best-effort: capture git's own stderr for the no-root breadcrumb so the real
    # cause (safe.directory refusal, or git absent → OSError) surfaces instead of being
    # discarded. Returns a " (git: …)" suffix, or "" when git succeeded or printed
    # nothing to stderr. Gates on a NON-ZERO rc (mirroring the match-deferrals sibling)
    # so a git that succeeds on this second call but printed a benign advisory to stderr
    # is not misattributed as the failure cause. Catches broadly (not just OSError) so a
    # non-UTF-8 decode or any other subprocess error cannot make the breadcrumb path
    # itself raise — it truly never raises.
    try:
        r = subprocess.run(
            ['git', 'rev-parse', '--show-toplevel'],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, encoding='utf-8',
        )
        err = (r.stderr or '').strip() if r.returncode != 0 else ''
    except OSError as e:
        err = str(e)
    except Exception:  # noqa: BLE001 — breadcrumb path must never raise
        err = ''
    return f" (git: {err})" if err else ""


def _repo_full(api_fail_code=1):
    try:
        r = _run([GH, 'repo', 'view', '--json', 'nameWithOwner',
                  '-q', '.nameWithOwner'])
    except (subprocess.CalledProcessError, OSError) as e:
        _fail('repo lookup', e, code=api_fail_code)
    return r.stdout.strip()


_DEFAULT_WORKPAD_MARKER = '<!-- devflow:workpad -->'


def _workpad_marker(explicit=None):
    # An explicit override wins: /devflow:review uses this to target its own
    # `<!-- devflow:review-progress -->` comment with the same helper, rather
    # than forking a parallel script. Precedence: the `--marker` CLI flag, then
    # the `DEVFLOW_WORKPAD_MARKER` env var, then config, then the built-in
    # default. The flag is preferred over the env var because a leading
    # env-assignment (`DEVFLOW_WORKPAD_MARKER=… workpad.py …`) makes the command
    # un-matchable against the cloud allow-list rule `Bash(.../workpad.py:*)`
    # (the command no longer *starts with* the script path), so those calls are
    # silently denied on the read-only `review` profile; `--marker` keeps the
    # path as the command prefix. The env var is retained for back-compat.
    override = (explicit or '').strip() or os.environ.get('DEVFLOW_WORKPAD_MARKER', '').strip()
    if override:
        return override
    # Read the marker from .devflow/config.json directly in-process (issue
    # #275): Windows cannot exec a .sh helper ([WinError 193]), so the former
    # config-get.sh subprocess hop silently dropped a configured custom marker
    # back to the built-in default there.
    #
    # SHARED REPO-ROOT CONFIG CONTRACT (issue #295, supersedes the #275 cwd-relative
    # contract): this resolver and scripts/config-get.sh both anchor the DEFAULT
    # `.devflow/config.json` to the git repo root (git rev-parse --show-toplevel,
    # falling back to cwd) — NOT relative to the current working directory — so a run
    # invoked from a repo subdirectory reads the consumer's ROOT config, mirroring
    # lib/config-source.sh. Keep the two readers in lockstep: they resolve the same
    # file for the same cwd. An absent file is the normal unconfigured case — silent
    # fallback so the local tier works with no config at all. (Limitation:
    # --show-toplevel returns the NEAREST git root, so a nested submodule/inner repo
    # or a monorepo whose .devflow/ is not at the git root is not covered.)
    _root = _repo_root()
    if _root is not None:
        config_file = Path(_root) / '.devflow' / 'config.json'
    else:
        cwd = Path.cwd()
        config_file = cwd / '.devflow' / 'config.json'
        # Breadcrumb only when NEITHER a git root NOR a .devflow/ dir can be located —
        # the silent-drop class this fix closes. A git root with no .devflow/ is the
        # normal unconfigured case and stays silent (handled by FileNotFoundError below).
        # git can exit non-zero while genuinely INSIDE a repo (safe.directory /
        # dubious-ownership), or be absent — not only "outside a git tree" — so don't
        # assert "not in a git repo"; report the root could not be resolved and surface
        # git's own stderr (re-run on this rare path only).
        if not (cwd / '.devflow').is_dir():
            sys.stderr.write(
                f"workpad.py: could not resolve a git repo root"
                f"{_git_root_error_suffix()} and no .devflow/ at {str(cwd)!r}; "
                f"falling back to default marker\n"
            )
    try:
        with config_file.open(encoding='utf-8') as f:
            data = json.load(f)
    except FileNotFoundError:
        # Absent config (or an absent .devflow/ dir) is the normal
        # unconfigured case — silent, unlike the breadcrumbed failures below.
        return _DEFAULT_WORKPAD_MARKER
    except (OSError, ValueError) as e:
        # ValueError covers json.JSONDecodeError AND UnicodeDecodeError — a
        # config.json written by PowerShell 5.x `>` redirection is UTF-16LE
        # with a BOM (the docs/install.md pitfall), which raises
        # UnicodeDecodeError, not JSONDecodeError, at read time.
        # A present-but-unreadable/malformed config is otherwise
        # indistinguishable from "no marker override configured": both fall
        # back to the built-in default. Leave a breadcrumb naming the file so
        # an operator debugging a "workpad not found" symptom on a repo with
        # `.devflow.workpad_marker` configured can tell the two apart.
        sys.stderr.write(
            f"workpad.py: could not read {str(config_file)!r} ({e}); "
            f"falling back to default marker\n"
        )
        return _DEFAULT_WORKPAD_MARKER
    devflow = data.get('devflow') if isinstance(data, dict) else None
    if not isinstance(devflow, dict) or 'workpad_marker' not in devflow:
        return _DEFAULT_WORKPAD_MARKER
    value = devflow['workpad_marker']
    # A non-string or blank value is "not configured" — never coerce a
    # misconfigured type into a garbage marker stamped into a comment — but a
    # PRESENT-and-invalid key gets a breadcrumb: silently defaulting would be
    # indistinguishable from "nothing configured", the same masked-fallback
    # class the malformed-JSON branch above breadcrumbs.
    if isinstance(value, str) and value.strip():
        return value.strip()
    sys.stderr.write(
        f"workpad.py: ignoring non-string or blank devflow.workpad_marker in "
        f"{str(config_file)!r}; falling back to default marker\n"
    )
    return _DEFAULT_WORKPAD_MARKER


def _find_workpad_comment(cmd, repo, issue, marker, api_fail_code=1):
    """Scan an issue's comments (paginated) and return the first whose body
    starts with `marker`, or None when the scan completed and none matched.

    Single source for the marker-scan that `cmd_id` and `cmd_status` share — the
    `per_page=100`/`< 100` pagination boundary and the API/parse error handling
    live here once. A `gh api` or JSON-parse failure exits via `_fail(cmd, …)`
    with `api_fail_code` (default 1, so the caller's error prefix and historical
    exit code are preserved; cmd_status passes 3 to distinguish a transport/auth
    failure from an unreadable workpad); a clean scan with no match returns None
    so the caller can apply its own "not found" contract (exit 2)."""
    page = 1
    while True:
        try:
            r = _run([
                GH, 'api',
                f'/repos/{repo}/issues/{issue}/comments'
                f'?page={page}&per_page=100',
            ])
        except (subprocess.CalledProcessError, OSError) as e:
            _fail(cmd, e, code=api_fail_code)
        try:
            items = json.loads(r.stdout)
        except json.JSONDecodeError as e:
            _fail(cmd, f"could not parse gh comments response: {e}", code=api_fail_code)
        # A rc-0 gh response that parses but is NOT a JSON array is a transport/API
        # anomaly, not a healthy comment page — most often an error envelope
        # (`{"message":"Bad credentials"}`) some gh/API paths emit at exit 0. Route
        # it through the same api_fail_code as a parse failure (exit 3 for cmd_status,
        # so the exit-3 promise covers a wrong-shape body, not only an unparseable
        # one) rather than iterating a dict's keys into an uncaught AttributeError
        # (which would surface as a bare exit 1, mislabeling an auth error as an
        # unreadable workpad).
        if not isinstance(items, list):
            _fail(
                cmd,
                f"gh comments response was not a JSON array "
                f"(got {type(items).__name__}): {str(items)[:200]}",
                code=api_fail_code,
            )
        for c in items:
            if (c.get('body') or '').startswith(marker):
                return c
        if len(items) < 100:
            return None
        page += 1


def cmd_id(args):
    marker = _workpad_marker(args.marker)
    c = _find_workpad_comment('id', _repo_full(), args.issue, marker)
    if c is not None:
        print(c['id'])
        return
    # Exit 2 (distinct from _fail's exit 1) means "scanned successfully, no
    # matching comment" — i.e. first run / not yet seeded. A real `gh api` or
    # parse failure exits 1 via _fail inside the scan. Callers can thus tell a
    # benign "create it" from a transient API error and avoid posting a duplicate
    # workpad comment on a failure they mistook for "not found".
    sys.exit(2)


def cmd_body(args):
    repo = _repo_full()
    try:
        r = _run([
            GH, 'api',
            f'/repos/{repo}/issues/comments/{args.comment_id}',
            '--jq', '.body',
        ])
    except (subprocess.CalledProcessError, OSError) as e:
        _fail('body', e)
    sys.stdout.write(r.stdout)


def _is_recognized_status_word(word: str) -> bool:
    """True if `word` (already glyph-stripped) is a canonical Status word —
    exactly one of `_STATUS_TO_PROGRESS_PHASE`'s keys (every in-progress phase
    word, plus 'complete') or one of the literal terminal words 'blocked' /
    'failed' (the words `_STATUS_TO_PROGRESS_PHASE` intentionally omits — see
    `_progress_phase_for_status`). Deliberately exact-match, NOT
    `_status_glyph(word) in ('🎉', '👎')`: that delegates to `_status_glyph`'s
    own `startswith('complete'/'blocked')` prefix check, which is intentional
    for its write-path callers but would let a corrupted word like
    'Completely wrong' or 'Blockeddependency' pass this recognition check —
    exactly the fail-open this function exists to close. No independent
    hardcoded word list: 'blocked' and 'failed' are the only two literals not
    already sourced from `_STATUS_TO_PROGRESS_PHASE` — both are terminal words
    that map has no phase for (see `_progress_phase_for_status`); 'failed' is
    the workflow-level stall-backstop "died" status (💥, issue #356)."""
    s = word.strip().lower()
    return s in _STATUS_TO_PROGRESS_PHASE or s in ('blocked', 'failed')


def cmd_status(args):
    """Print the workpad Status as `CLASS GLYPH WORD` (e.g. 'interim 🚀 Reviewing').

    CLASS is 'terminal' for a Complete (🎉), Blocked (👎), or Failed (💥) status,
    else 'interim'. The glyph and classification come from `_status_glyph` — the same
    single source of truth the update path uses — so no caller re-parses the
    glyph vocabulary ad hoc. Exit codes let a caller fail closed:
      0  status printed
      2  no workpad comment exists for this issue (scanned OK, none matched)
      1  the workpad exists but its Status line is missing/empty, OR the Status
         line has a value that isn't a recognized status word
         (present-but-unreadable — a content-shape failure, distinct from 'no
         workpad'). This is NOT a transport failure — the read succeeded, the
         content is unusable.
      3  a gh api / transport / auth failure (the `gh repo view` repo lookup or
         the `gh api` comment fetch failed — e.g. an expired App token — or that
         fetch returned a body that is unparseable (a dropped/truncated
         connection) or parses but is not a JSON array (an error envelope such as
         `{"message":"Bad credentials"}`)). Distinct from exit 1: the workpad may
         be perfectly healthy; the READ failed, not the content. Kept separate so the cloud stall backstop never mislabels
         an auth failure as an unreadable workpad and never burns a resume
         attempt on a workpad it could not read.
    The cloud stall backstop maps exit 1 and exit 2 alike to the 'unreadable'
    decision class, exit 3 to the distinct 'auth-failure' class (both fail
    closed), while a healthy run prints a class it can act on."""
    marker = _workpad_marker(args.marker)
    c = _find_workpad_comment(
        'status', _repo_full(api_fail_code=3), args.issue, marker,
        api_fail_code=3,
    )
    if c is None:
        # Scanned every page, no workpad — same benign exit 2 as `id`.
        sys.exit(2)
    body = c.get('body') or ''
    m = _STATUS_VALUE_RE.search(body)
    if not m:
        sys.stderr.write(
            "workpad.py status: workpad found but no Status line in it\n"
        )
        sys.exit(1)
    word = _strip_status_glyph(m.group(1).strip()).strip()
    if not word:
        sys.stderr.write(
            "workpad.py status: workpad Status line has no value\n"
        )
        sys.exit(1)
    if not _is_recognized_status_word(word):
        recognized = '/'.join(
            [w.capitalize() for w in _STATUS_TO_PROGRESS_PHASE] + ['Blocked', 'Failed']
        )
        sys.stderr.write(
            f"workpad.py status: workpad Status word {word!r} is not a "
            f"recognized status (expected one of {recognized}) — "
            "present-but-unreadable\n"
        )
        sys.exit(1)
    glyph = _status_glyph(word)
    cls = 'terminal' if glyph in ('🎉', '👎', '💥') else 'interim'
    print(f"{cls} {glyph} {word}")


def cmd_patch(args):
    repo = _repo_full()
    body_path = Path(args.body_file)
    if not body_path.is_file():
        sys.stderr.write(
            f"workpad.py patch: body file not found: {body_path}\n"
        )
        sys.exit(1)
    try:
        r = _run([
            GH, 'api', '-X', 'PATCH',
            f'/repos/{repo}/issues/comments/{args.comment_id}',
            '-F', f'body=@{body_path}',
            '--jq', '.body',
        ])
    except (subprocess.CalledProcessError, OSError) as e:
        _fail('patch', e)
    sys.stdout.write(r.stdout)


_COMMENT_URL_RE = re.compile(r'#issuecomment-(\d+)\s*$')


def cmd_create(args):
    body_path = Path(args.body_file)
    if not body_path.is_file():
        sys.stderr.write(
            f"workpad.py create: body file not found: {body_path}\n"
        )
        sys.exit(1)
    try:
        r = _run([
            GH, 'issue', 'comment', str(args.issue),
            '--body-file', str(body_path),
        ])
    except (subprocess.CalledProcessError, OSError) as e:
        _fail('create', e)
    m = _COMMENT_URL_RE.search(r.stdout)
    if m:
        print(m.group(1))
        return
    # `gh issue comment` is documented to print the new comment URL. If the
    # URL is missing (gh output-format change, transient stderr-only output,
    # ...) the comment may already have been posted on GitHub, so falling
    # back to a fresh marker scan would risk picking up an unrelated workpad
    # and silently masking the failure. Fail loud instead — the caller can
    # re-run after inspecting the issue manually.
    sys.stderr.write(
        "workpad.py create: gh did not print a comment URL; the workpad "
        "may or may not have been posted. Inspect the issue manually before "
        "retrying. Raw stdout:\n"
    )
    sys.stderr.write(r.stdout)
    sys.exit(1)


def cmd_now(_args):
    now = datetime.datetime.now(datetime.timezone.utc)
    print(now.strftime('%Y-%m-%dT%H:%M:%SZ'))


# The un-mirrored `## Acceptance Criteria` placeholder — the SINGLE SOURCE seeded by
# `cmd_new_body`'s template below AND matched by the terminal Complete gate. Keeping
# both the producer and the guard on this one constant means a reword (e.g. the ASCII
# vs em-dash trap) can never silently drift them apart and disarm the gate's warning.
# If it survives to a terminal `--status Complete` write, Phase 1.2/1.3 AC-mirroring
# never ran, so the gate's checkbox scan has nothing to check — the "self-record
# matches reality" guarantee would be vacuously satisfied. The gate warns (non-blocking)
# on this exact placeholder; a genuinely AC-less issue carries the DISTINCT sentinel
# `_(none provided in issue body)_` parse-acs.py emits, so no warning fires there.
_AC_PENDING_PLACEHOLDER = '_(pending — mirrored from the issue when the run begins)_'

# The bug-only "reproduction captured" ## Progress sub-row. SINGLE SOURCE for the
# row `cmd_new_body` renders AND the row `_reconcile_reproduction_row` (issue #449)
# adds/removes to match the recorded content classification — so the reconcile can
# never drift from the skeleton the gate/new-body seed. `_REPRODUCTION_ROW_SUBSTR`
# is the substring the reconcile matches an existing row by (tick-state- and
# marker-agnostic), so a future reword of the parenthetical never blinds detection.
_REPRODUCTION_ROW_TEXT = 'reproduction captured (bug issues only)'
_REPRODUCTION_ROW = f'  - [ ] {_REPRODUCTION_ROW_TEXT}'
_REPRODUCTION_ROW_SUBSTR = 'reproduction captured'


def cmd_new_body(args):
    """Print the lean initial workpad skeleton to stdout, for piping into a file
    and `create`. Deliberately minimal — only what's available before the run
    does any work: status, links, friendly timestamp, and the empty ## Progress
    checklist (with the run-started note nested under Setup). The Plan and
    Acceptance Criteria are placeholders the orchestrator fills once it begins
    (Phase 2.2 / Phase 1.2). Used by the `gate` job to post the acknowledgment
    before runtime provisioning, and by the local-tier fresh-issue path."""
    marker = _workpad_marker(args.marker)
    now_dt = datetime.datetime.now(datetime.timezone.utc)
    last_updated = now_dt.strftime('%Y-%m-%d %H:%M UTC')
    seed_ts = now_dt.strftime('%H:%M:%S')
    branch = f'`{args.branch}`' if args.branch else '_(creating…)_'
    run = args.run_link or '_(local run)_'
    # The reproduction sub-item is bug-only. It renders by default so a
    # deterministic producer that cannot judge content (the `gate` job pre-renders
    # from the `bug` label) never drops it on a lookup failure; the local
    # fresh-issue path (Phase 1.3) passes --no-reproduction when the recorded
    # content classification is non-bug. Either way, Phase 1.3's
    # --reconcile-reproduction is the authoritative correction (issue #449) that
    # reconciles this row to the classification, so the default here is only a
    # starting point, not the final word.
    repro = (
        ''
        if getattr(args, 'no_reproduction', False)
        else _REPRODUCTION_ROW + '\n'
    )
    sys.stdout.write(f"""{marker}
# DevFlow Workpad — Issue #{args.issue}

**Status:** 🚀 Setup
**Branch:** {branch}
**Run:** {run}
**PR:** _not yet created_
**Last updated:** {last_updated}

## Progress
- [ ] **Setup** — branch & workpad
  - {seed_ts} — /devflow:implement run started
- [ ] **Implement**
{repro}  - [ ] code + sweeps
- [ ] **Review**
  - [ ] `/simplify`
  - [ ] `review-and-fix`
  - [ ] acceptance-criteria gate
- [ ] **Documentation**
- [ ] **PR marked ready**

## Plan
- [ ] _(planning in progress)_

## Acceptance Criteria
{_AC_PENDING_PLACEHOLDER}

## Devflow Reflection
<details>
<summary>Devflow Reflection (click to expand)</summary>

</details>
""")


# ============================================================================
# update: high-level mutation entry point
# ============================================================================
#
# The workpad body is structured markdown. Earlier flows had the orchestrator
# rebuild the entire body string per-mutation, which led to drift (rewriting
# Decisions/Notes from scratch, missing Last updated, splicing into the wrong
# section, etc.). `update` accepts focused mutation flags, edits the live body
# in place, and PATCHes.
#
# Section model: the body has a fixed front-matter (Status / Branch / Last
# updated lines after the H1), then ## sections in a known order. We split the
# body into a header (everything up to and including the first blank line
# after the metadata block) and an ordered list of section blocks. Each
# section block is the heading line plus all lines until the next ## heading.

_STATUS_RE = re.compile(r'^\*\*Status:\*\*\s+.*$', re.MULTILINE)
_STATUS_VALUE_RE = re.compile(r'^\*\*Status:\*\*\s+(.*?)\s*$', re.MULTILINE)
_BRANCH_RE = re.compile(r'^\*\*Branch:\*\*\s+.*$', re.MULTILINE)
_RUN_RE = re.compile(r'^\*\*Run:\*\*\s+.*$', re.MULTILINE)
_PR_RE = re.compile(r'^\*\*PR:\*\*\s+.*$', re.MULTILINE)
_LAST_UPDATED_RE = re.compile(r'^\*\*Last updated:\*\*\s+.*$', re.MULTILINE)
_SECTION_RE = re.compile(r'^(##\s+.+)$', re.MULTILINE)
# Single source for the checkbox-row grammar shared by `_rewrite_checkbox` and
# `_tick_checkbox_by_index` (4 groups: 1=indent+bullet, 2=`[ xX]` state cell,
# 3=gap, 4=text). The state cell (group 2) is *preserved* by `_rewrite_checkbox`
# and *overwritten* with `[x]` by `_tick_checkbox_by_index` — the two writers index
# the same grammar differently, so keep the group order stable if you edit it.
# `_tick_checkbox` keeps its own `[ ]`-only variant because it filters to unticked
# rows. Hoisted to a constant so the row grammar can't drift between call sites.
_CHECKBOX_ROW_RE = re.compile(r'^(\s*[-*]\s+)(\[[ xX]\])(\s+)(.*)$')

# Canonical status glyphs. The Status line always begins with one;
# `_status_glyph` derives it from the status word so the orchestrator passes a
# bare status ("Setup", "Complete", "Blocked", "Failed") and the helper is the
# single source of truth for the glyph vocabulary. 🚀=running (any in-progress
# phase), 🎉=Complete, 👎=Blocked, 💥=Failed. The first three are
# reaction-compatible — they match the triggering-comment reactions
# (rocket / hooray / -1) the implement skill emits. 💥 (the workflow-level
# stall-backstop "died" flip, issue #356) is the carve-out: it is a workpad-only
# terminal glyph with NO triggering-comment reaction equivalent — the cloud
# backstop writes it when a run dead-ends, but emits no outcome reaction for it.
_STATUS_GLYPHS = ('🚀', '🎉', '👎', '💥')


def _strip_status_glyph(status: str) -> str:
    """Drop a leading canonical glyph (and following spaces) from a status value,
    so re-applying `--status` is idempotent and the note sub-heading uses the
    bare phase word, not '🚀 Implementing'."""
    s = status.lstrip()
    for g in _STATUS_GLYPHS:
        if s.startswith(g):
            return s[len(g):].lstrip()
    return s


def _status_glyph(status: str) -> str:
    s = _strip_status_glyph(status).strip().lower()
    if s.startswith('complete'):
        return '🎉'
    if s.startswith('blocked'):
        return '👎'
    if s.startswith('failed'):
        return '💥'
    return '🚀'


# The canonical ## Progress top-level phase labels, in order — the single
# source of truth that `_STATUS_TO_PROGRESS_PHASE` (below) and the `new-body`
# checklist (cmd_new_body) must both agree with. A note is nested under one of
# these rows by substring match, so renaming a phase here, in the map, or in
# the template without updating the others would misfile notes silently; the
# import-time assert below and the `new-body`-template test guard against that.
_PROGRESS_PHASES = ('Setup', 'Implement', 'Review', 'Documentation', 'PR marked ready')

# Maps a workpad Status word (glyph-stripped, lowercased) to the ## Progress
# top-level phase its notes nest under. Several in-progress statuses share one
# phase (Discovering/Reproducing/Planning/Implementing → Implement). A status
# absent from this map (Blocked) nests under the most recent *ticked* phase —
# see `_progress_phase_for_status`. The lookup degrades gracefully: if the
# mapped phase label isn't present in the checklist (a template rename), it
# falls back the same way, so a note is never dropped.
_STATUS_TO_PROGRESS_PHASE = {
    'setup': 'Setup',
    'discovering': 'Implement',
    'reproducing': 'Implement',
    'planning': 'Implement',
    'implementing': 'Implement',
    'reviewing': 'Review',
    'documenting': 'Documentation',
    'complete': 'PR marked ready',
}

# Fail loudly at import if the map ever names a phase the canonical list doesn't
# — a rename that would otherwise misfile notes with no signal.
assert set(_STATUS_TO_PROGRESS_PHASE.values()) <= set(_PROGRESS_PHASES), (
    'workpad: _STATUS_TO_PROGRESS_PHASE names a phase not in _PROGRESS_PHASES: '
    f'{set(_STATUS_TO_PROGRESS_PHASE.values()) - set(_PROGRESS_PHASES)}'
)

# A top-level (column-0, no leading whitespace) ## Progress checkbox — one row
# per lifecycle phase. Nested sub-items (`  - [ ] code + sweeps`) and nested
# note bullets carry leading whitespace and are deliberately not matched.
_TOP_LEVEL_CHECKBOX_RE = re.compile(r'^[-*] \[([ xX])\]\s+(.*)$')


def _progress_phase_for_status(progress_content: str, status: str | None) -> str | None:
    """Return the label text of the ## Progress top-level phase a note for
    `status` nests under, or None when the section has no top-level phases (the
    caller then appends the note flat).

    Mapped statuses nest under their phase; an unmapped status (Blocked/Failed)
    or a mapped phase that isn't present nests under the most recent *ticked*
    (completed) top-level row, else the first phase."""
    rows = []  # (label_text, ticked)
    for line in progress_content.split('\n'):
        m = _TOP_LEVEL_CHECKBOX_RE.match(line)
        if m:
            rows.append((m.group(2), m.group(1).lower() == 'x'))
    if not rows:
        return None
    key = _strip_status_glyph(status or '').strip().lower()
    mapped = _STATUS_TO_PROGRESS_PHASE.get(key)
    if mapped:
        for text, _ in rows:
            if mapped.lower() in text.lower():
                return text
    ticked = [text for text, t in rows if t]
    return ticked[-1] if ticked else rows[0][0]


def _set_or_insert_header(
    body: str, regex: re.Pattern, label: str, value: str, anchors: list[re.Pattern]
) -> str:
    """Replace a `**{label}:** …` front-matter line with `value`, or insert it
    after the first matching `anchors` line when absent (so a legacy workpad
    created before run/PR links existed still accepts `--run-link`/`--pr-link`
    on a resume instead of erroring). `anchors` is tried in priority order to
    preserve the canonical Status/Branch/Run/PR/Last-updated ordering — e.g. PR
    inserts after Run when Run exists, else after Branch — so a freshly-inserted
    line never jumps above an existing one. `value` is substituted via a
    function replacer so regex-special characters in the value (e.g. URL
    `?`/`&`) are literal."""
    new_line = f'**{label}:** {value}'
    body, n = regex.subn(lambda _m: new_line, body, count=1)
    if n:
        return body
    for anchor in anchors:
        body, n = anchor.subn(lambda m: m.group(0) + '\n' + new_line, body, count=1)
        if n:
            return body
    raise _UpdateError(
        f'{label} line absent and no anchor line ({", ".join(a.pattern for a in anchors)}) '
        f'to insert it after'
    )


def _split_sections(body: str) -> tuple[str, list[tuple[str, str]]]:
    """Return (preamble, [(heading_line, content), ...]).

    `preamble` is everything before the first `## ` heading. Each section's
    content includes the trailing blank lines up to (but not including) the
    next heading line.
    """
    matches = list(_SECTION_RE.finditer(body))
    if not matches:
        return body, []
    preamble = body[: matches[0].start()]
    sections = []
    for i, m in enumerate(matches):
        heading = m.group(1)
        start = m.end() + 1  # skip the newline after the heading
        end = matches[i + 1].start() if i + 1 < len(matches) else len(body)
        content = body[start:end]
        sections.append((heading, content))
    return preamble, sections


def _join_sections(preamble: str, sections: list[tuple[str, str]]) -> str:
    out = [preamble.rstrip('\n')] if preamble.strip() else []
    for heading, content in sections:
        block = heading.rstrip() + '\n' + content
        out.append(block.rstrip('\n'))
    return '\n\n'.join(out) + '\n'


def _find_section(sections: list[tuple[str, str]], name: str) -> int | None:
    """Return index of a section by its heading text (case-insensitive), or None."""
    target = f'## {name}'.lower()
    for i, (heading, _) in enumerate(sections):
        if heading.strip().lower() == target:
            return i
    return None


def _set_section_content(
    sections: list[tuple[str, str]], name: str, new_content: str
) -> list[tuple[str, str]]:
    """Replace the content of an existing section."""
    idx = _find_section(sections, name)
    if idx is None:
        raise _UpdateError(f"section '## {name}' not found in workpad body")
    heading, _ = sections[idx]
    new_sections = list(sections)
    new_sections[idx] = (heading, new_content.rstrip('\n') + '\n')
    return new_sections


def _insert_section_after(
    sections: list[tuple[str, str]], after_name: str, new_heading: str,
    new_content: str,
) -> list[tuple[str, str]]:
    """Insert a new section immediately after the named one."""
    idx = _find_section(sections, after_name)
    if idx is None:
        raise _UpdateError(f"cannot insert after '## {after_name}' (not found)")
    new_sections = list(sections)
    block = (new_heading, new_content.rstrip('\n') + '\n')
    new_sections.insert(idx + 1, block)
    return new_sections


def _join_preserving_newline(new_lines, content: str) -> str:
    """Re-join section lines, preserving whether the original `content` ended in a
    newline. The shared tail of every in-place line-rewrite helper in this file."""
    return '\n'.join(new_lines) + ('\n' if content.endswith('\n') else '')


def _tick_checkbox(content: str, text_substr: str, section_label: str) -> str:
    """Tick exactly one matching unticked `- [ ]`/`* [ ]` checkbox in the section.

    Only `[ ]` rows are considered candidates; already-ticked rows are ignored.
    A duplicate `--tick-plan`/`--tick-ac` value (or a substring that only matches
    an already-ticked row, or that matches nothing, or that matches multiple rows)
    raises `_TickMatchError` — a *volatile* per-row failure that `_apply_mutations`
    collects and `cmd_update` reports without discarding the call's other
    mutations. This is distinct from a structural `_UpdateError` (a missing
    section), which still aborts the whole call before any PATCH."""
    candidates = []
    new_lines = []
    for line in content.splitlines():
        m = re.match(r'^(\s*[-*]\s+)\[ \](\s+)(.*)$', line)
        if m and text_substr.lower() in m.group(3).lower():
            candidates.append((len(new_lines), m))
        new_lines.append(line)
    if not candidates:
        raise _TickMatchError(
            f"no unticked {section_label} checkbox matched substring "
            f"{text_substr!r} (already ticked, or no match)"
        )
    if len(candidates) > 1:
        raise _TickMatchError(
            f"{len(candidates)} {section_label} checkboxes match {text_substr!r}; "
            f"be more specific"
        )
    line_idx, m = candidates[0]
    new_lines[line_idx] = f"{m.group(1)}[x]{m.group(2)}{m.group(3)}"
    return _join_preserving_newline(new_lines, content)


def _tick_checkbox_by_index(content: str, n: int, section_label: str) -> str:
    """Tick the Nth checkbox (1-based) in the section, counting *every*
    `- [ ]`/`* [ ]` and `- [x]`/`* [x]` row in document order.

    Addressing by position avoids the fragile, hand-picked unique-substring
    requirement of `_tick_checkbox` for batched ticks. An out-of-range N, or an N
    that lands on an already-ticked row, is a *volatile* `_TickMatchError` (same
    class the substring path raises) — collected and reported, never a structural
    abort. Mirrors the `_rewrite_checkbox` row-walk (`[ xX]` state class)."""
    rows = []  # (line_idx, match) for every checkbox row, ticked or not
    new_lines = []
    for line in content.splitlines():
        m = _CHECKBOX_ROW_RE.match(line)
        if m:
            rows.append((len(new_lines), m))
        new_lines.append(line)
    if n < 1 or n > len(rows):
        raise _TickMatchError(
            f"index {n} out of range for {section_label} (section has "
            f"{len(rows)} checkbox row(s), valid 1..{len(rows)})"
        )
    line_idx, m = rows[n - 1]
    if m.group(2) != '[ ]':
        raise _TickMatchError(
            f"{section_label} checkbox {n} is already ticked"
        )
    new_lines[line_idx] = f"{m.group(1)}[x]{m.group(3)}{m.group(4)}"
    return _join_preserving_newline(new_lines, content)


def _find_checkbox_row(content: str, old_substr: str, section_label: str):
    """Resolve the ONE checkbox row `old_substr` names, returning
    `(lines, line_idx, match)`. Raises `_UpdateError` when the substring matches
    zero or multiple rows (the exactly-one-match rule).

    Split out of `_rewrite_checkbox` so the `(post-merge)` rationale guard can
    reason over the row's CURRENT text using the very same resolution the rewrite
    will use (issue #338). Sharing the resolution — rather than re-deriving the
    row from the OLD argument string — keeps the guard's view of "which row is
    this pair about" identical to the rewriter's by construction."""
    matched = []
    lines = content.splitlines()
    for i, line in enumerate(lines):
        m = _CHECKBOX_ROW_RE.match(line)
        if m and old_substr.lower() in m.group(4).lower():
            matched.append((i, m))
    if not matched:
        raise _UpdateError(
            f"no {section_label} checkbox matched {old_substr!r} for rewrite"
        )
    if len(matched) > 1:
        raise _UpdateError(
            f"{len(matched)} {section_label} checkboxes match {old_substr!r}; "
            f"be more specific"
        )
    line_idx, m = matched[0]
    return lines, line_idx, m


def _rewrite_checkbox(
    content: str, old_substr: str, new_text: str, section_label: str
) -> str:
    """Find one checkbox matching old_substr; replace its label text with new_text.
    Preserves checkbox state (`[ ]` vs `[x]`) and indentation."""
    new_lines, line_idx, m = _find_checkbox_row(content, old_substr, section_label)
    new_lines[line_idx] = f"{m.group(1)}{m.group(2)}{m.group(3)}{new_text}"
    return _join_preserving_newline(new_lines, content)


def _split_details(content: str) -> tuple[str | None, str, str | None]:
    """If a section's content wraps its body in a `<details>` block, return
    `(head, inner, tail)` where `head` is the opening `<details>`/`<summary>`
    lines (plus the blank line markdown needs to render inside), `inner` is the
    collapsible body, and `tail` is the closing `</details>`. Returns
    `(None, content, None)` when there is no wrapper — so the append helpers
    operate on a legacy (un-wrapped) section unchanged.

    This lets `Devflow Reflection` be collapsed in a `<details>` block while
    `--reflection` still appends *inside* it
    (before `</details>`), never after — which would silently fall outside the
    collapsible region."""
    lines = content.split('\n')
    try:
        o = next(i for i, line in enumerate(lines) if line.strip().startswith('<details'))
        c = next(i for i in range(len(lines) - 1, -1, -1) if lines[i].strip() == '</details>')
    except StopIteration:
        return None, content, None
    if c <= o:
        return None, content, None
    head_end = o + 1
    if head_end < len(lines) and lines[head_end].strip().startswith('<summary'):
        head_end += 1
    if head_end < len(lines) and lines[head_end].strip() == '':
        head_end += 1
    head = '\n'.join(lines[:head_end])
    inner = '\n'.join(lines[head_end:c]).strip('\n')
    tail = '\n'.join(lines[c:])
    return head, inner, tail


def _rewrap_details(head: str, new_inner: str, tail: str) -> str:
    """Reassemble a `<details>` section from its head, freshly-mutated inner
    body, and tail (a blank line after `<summary>` is preserved for markdown)."""
    return head.rstrip('\n') + '\n\n' + new_inner.strip('\n') + '\n' + tail + '\n'


def _append_progress_note(
    content: str, note: str, timestamp: str, phase_label: str | None
) -> str:
    """Insert a `  - {timestamp} — {note}` bullet nested under the ## Progress
    top-level phase whose row text contains `phase_label`.

    Notes live inside the Progress section now (no separate Decisions / Notes
    section): the bullet lands at the end of its phase's block — after that
    phase's sub-checkboxes and any earlier notes, before the next top-level
    phase — so a phase's notes stay grouped and chronological across many
    update calls. `timestamp` is the time-only `HH:MM:SS` string. When
    `phase_label` is None, or no row matches it, the note is appended flat at
    the end of the section so it is never dropped."""
    lines = content.split('\n')
    start = None
    if phase_label:
        for i, line in enumerate(lines):
            m = _TOP_LEVEL_CHECKBOX_RE.match(line)
            if m and phase_label.lower() in m.group(2).lower():
                start = i
                break
    if start is None:
        # No resolvable phase row → flat (un-nested) append at section end.
        stripped = content.rstrip('\n')
        prefix = stripped + '\n' if stripped.strip() else ''
        return prefix + f"- {timestamp} — {note}\n"
    # Block end: the next top-level phase row, else end of section. Nested
    # sub-items carry leading whitespace and never match, so they stay inside
    # the block.
    end = next(
        (j for j in range(start + 1, len(lines))
         if _TOP_LEVEL_CHECKBOX_RE.match(lines[j])),
        len(lines),
    )
    while end > start + 1 and not lines[end - 1].strip():
        end -= 1
    new_lines = lines[:end] + [f"  - {timestamp} — {note}"] + lines[end:]
    return _join_preserving_newline(new_lines, content)


# ── Reproduce-first classification: row reconcile + note supersede (issue #449) ──
#
# The Phase 2.1.5 reproduce-first gate keys on a recorded *content* classification,
# not the `bug` label. Phase 1.3 records that classification as a superseding
# `classification: ` note and reconciles the bug-only "reproduction captured"
# Progress row to match it — on every entry — so a gate-created skeleton (rendered
# deterministically from the label) always agrees with the classification before
# Phase 2 begins. Both operate on the ## Progress section.
_CLASSIFICATION_VALUES = ('bug-report', 'non-bug')
# The fixed, greppable note prefix. Phase 1.1's two exact forms are
# `classification: bug-report — <rationale>` / `classification: non-bug — <rationale>`.
_CLASSIFICATION_NOTE_PREFIX = 'classification: '
# Matches an existing classification note bullet — the `  - HH:MM:SS — ` prefix
# `_append_progress_note` writes (em-dash separator), then the note prefix — so a
# fresh record can supersede it. Anchored at line start; tick-state-irrelevant
# (notes are plain bullets, not checkboxes).
_CLASSIFICATION_NOTE_RE = re.compile(
    r'^\s*[-*]\s+\d{2}:\d{2}:\d{2}\s+—\s+' + re.escape(_CLASSIFICATION_NOTE_PREFIX)
)


def _reconcile_reproduction_row(content: str, classification: str) -> str:
    """Idempotently add or remove the bug-only reproduction-captured Progress
    sub-row so the skeleton matches the recorded content classification (#449).

    - `bug-report` → ensure the row is present: insert `_REPRODUCTION_ROW` directly
      under the `**Implement**` phase row (above `code + sweeps`) when absent; no-op
      when a row is already present in ANY tick state.
    - `non-bug` → remove the row only when present AND unticked; a *ticked* row is
      historical evidence and is preserved; an absent row is a no-op.

    Never removes a ticked row and never inserts a duplicate — so running it on
    every Phase 1.3 entry is safe. Operates on the ## Progress section content."""
    lines = content.split('\n')
    matches = [
        (i, m) for i, ln in enumerate(lines)
        if (m := _CHECKBOX_ROW_RE.match(ln))
        and _REPRODUCTION_ROW_SUBSTR.lower() in m.group(4).lower()
    ]
    if classification == 'bug-report':
        if matches:
            return content  # already present (ticked or not) → idempotent no-op
        for i, ln in enumerate(lines):
            m = _TOP_LEVEL_CHECKBOX_RE.match(ln)
            if m and 'implement' in m.group(2).lower():
                new_lines = lines[:i + 1] + [_REPRODUCTION_ROW] + lines[i + 1:]
                return _join_preserving_newline(new_lines, content)
        # No **Implement** phase row to anchor under — a malformed/legacy skeleton.
        # Fail structurally (loud) rather than silently drop the row into the wrong
        # place: a bug-classified run must not lose its reproduce-first gate row.
        raise _UpdateError(
            "cannot reconcile reproduction row: no '**Implement**' phase row in "
            "## Progress to anchor it under"
        )
    # non-bug: drop only unticked repro rows; keep ticked ones and no-op when absent.
    drop = {i for i, m in matches if m.group(2) == '[ ]'}
    if not drop:
        return content
    new_lines = [ln for i, ln in enumerate(lines) if i not in drop]
    return _join_preserving_newline(new_lines, content)


def _remove_classification_notes(content: str) -> str:
    """Drop every existing `classification: ` note bullet from ## Progress content,
    so a fresh record supersedes it — the workpad carries exactly one at all times
    (issue #449). Read-only otherwise; preserves the section's trailing newline."""
    kept = [ln for ln in content.split('\n')
            if not _CLASSIFICATION_NOTE_RE.match(ln)]
    return _join_preserving_newline(kept, content)


# ── Devflow Reflection: kind taxonomy + grouped rendering ───────────────────
#
# Reflection bullets are grouped by KIND into two `### ` sub-sections inside the
# `## Devflow Reflection` <details> block, so a human scanning a run sees the
# actionable items separated from the informational notes. The helper owns the
# glyph, bold label, and sub-section placement — the caller passes only a bare
# kind token via `--reflection-kind` — the same "helper owns the rendering
# token" idiom as the `--status` glyph and `--note` phase-nesting.
#
# Ordered: kind -> (glyph, bold label, sub-section key). The three actionable
# kinds map to the "action" sub-section; `note` (the default) to "notes".
_REFLECTION_KINDS = {
    'blocked':        ('⛔', 'Blocked',        'action'),
    'deferred':       ('⏭️', 'Deferred',       'action'),
    'dropped-failed': ('❗', 'Dropped/Failed', 'action'),
    'note':           ('ℹ️', 'Note',           'notes'),
}
_DEFAULT_REFLECTION_KIND = 'note'

# Sub-section headings in canonical render order (Action required before Notes).
# Level-3 (`### `) is mandatory: lib/fetch-pr-context.sh terminates the
# reflection parse at the first `## ` heading, so a level-2 sub-heading would
# truncate it — keep these `### `.
_REFLECTION_SUBSECTIONS = (
    ('action', '### ⚠️ Action required'),
    ('notes',  '### ℹ️ Notes'),
)
_SUBSECTION_HEADINGS = dict(_REFLECTION_SUBSECTIONS)            # sub-key -> heading
_SUBSECTION_HEADING_ORDER = [h for _, h in _REFLECTION_SUBSECTIONS]  # canonical order
_SUBSECTION_HEADING_RE = re.compile(r'^###\s')


def _parse_reflection_blocks(inner: str) -> list[list]:
    """Split the reflection <details> inner body into ordered blocks.

    Each block is `[heading_line_or_None, [content_lines...]]`. A leading block
    with heading None holds any pre-heading content (normally empty); every
    `### ` line starts a new block. An empty preamble block is dropped."""
    blocks = []
    current = [None, []]

    def _flush():
        if current[0] is not None or any(ln.strip() for ln in current[1]):
            blocks.append(current)

    for line in inner.split('\n'):
        if _SUBSECTION_HEADING_RE.match(line):
            _flush()
            current = [line.rstrip(), []]
        else:
            current[1].append(line)
    _flush()
    return blocks


def _render_reflection_blocks(blocks: list[list]) -> str:
    """Reassemble blocks into the reflection inner body: each `### ` sub-section
    is its heading followed by its bullets (surrounding blank lines trimmed),
    sub-sections separated by one blank line. A leading heading-None block (legacy
    un-kinded preamble bullets) renders first, before the first `### ` sub-section,
    separated by the same blank line."""
    parts = []
    for heading, lines in blocks:
        body = list(lines)
        while body and not body[-1].strip():
            body.pop()
        if heading is not None:
            while body and not body[0].strip():
                body.pop(0)
            parts.append(heading + ('\n' + '\n'.join(body) if body else ''))
        elif body:
            parts.append('\n'.join(body))
    return '\n\n'.join(parts)


def _insert_reflection_bullet(inner: str, kind: str, text: str) -> str:
    """Insert one reflection bullet of `kind` into the <details> inner body,
    under its canonical `### ` sub-section — creating the heading lazily (in
    Action-required-before-Notes order) when absent, reusing it when present.

    Pre-existing un-kinded (legacy) bullets are retained verbatim as a leading
    heading-None preamble block, *above* the lazily-created sub-sections — they
    are never re-sorted into a sub-section."""
    try:
        glyph, label, sub_key = _REFLECTION_KINDS[kind]
    except KeyError:
        # The argparse `choices=list(_REFLECTION_KINDS)` prevents a bad kind on
        # the CLI path, but a programmatic caller (e.g. a test driving
        # _apply_mutations directly) could pass one — convert it to the file's
        # clean _UpdateError contract (targeted message, no partial PATCH)
        # instead of letting a bare KeyError traceback escape.
        raise _UpdateError(
            f"unknown reflection kind {kind!r}; expected one of "
            f"{', '.join(_REFLECTION_KINDS)}"
        ) from None
    # Reflection bullets are single-line. Collapse any embedded line breaks
    # (`str.splitlines()` handles \n, \r, \v, …) to spaces — e.g. a multi-line
    # gh/jq error captured into a `dropped-failed` breadcrumb — so the whole
    # message stays on one bullet line. The line-based parser in
    # lib/fetch-pr-context.sh captures only a bullet's first line, so a multi-line
    # bullet would silently drop its continuation from reflections[]. (Single-line
    # text round-trips unchanged through splitlines+join.)
    one_line = ' '.join(text.splitlines())
    bullet = f'- {glyph} **{label}:** {one_line}'
    target_heading = _SUBSECTION_HEADINGS[sub_key]
    blocks = _parse_reflection_blocks(inner)
    for blk in blocks:
        if blk[0] == target_heading:
            while blk[1] and not blk[1][-1].strip():
                blk[1].pop()
            blk[1].append(bullet)
            return _render_reflection_blocks(blocks)
    # No existing sub-section for this kind: insert a new block, preserving the
    # canonical order (a None-heading preamble always stays first; an unknown
    # `### ` heading sorts last so it is never reordered above a known one).
    def _rank(heading):
        return (_SUBSECTION_HEADING_ORDER.index(heading)
                if heading in _SUBSECTION_HEADING_ORDER
                else len(_SUBSECTION_HEADING_ORDER))

    new_rank = _rank(target_heading)
    pos = len(blocks)
    for i, blk in enumerate(blocks):
        if blk[0] is not None and _rank(blk[0]) > new_rank:
            pos = i
            break
    blocks.insert(pos, [target_heading, [bullet]])
    return _render_reflection_blocks(blocks)


def _append_reflection(content: str, kind: str, text: str) -> str:
    """`<details>`-aware: insert a grouped reflection bullet *inside* the block
    (before `</details>`), reusing _split_details/_rewrap_details so the
    collapsible region stays intact. A legacy un-wrapped section (no <details>)
    is grouped in place."""
    head, inner, tail = _split_details(content)
    new_inner = _insert_reflection_bullet(inner, kind, text)
    if head is None:
        return new_inner
    return _rewrap_details(head, new_inner, tail)


def _read_section_file(path: str, flag: str) -> str:
    """Read a file passed via one of the --replace-*-file flags. Converts any
    OS-level error into a clean `_UpdateError` so the orchestrator gets a
    targeted message instead of a Python traceback, and the surrounding
    `cmd_update` aborts before the PATCH (no partial update)."""
    try:
        return Path(path).read_text()
    except OSError as e:
        raise _UpdateError(f"{flag}: could not read {path!r}: {e}")


class _UpdateError(Exception):
    """Raised by mutation helpers in `_apply_mutations` to signal a *structural*
    failure — a missing target section, a missing `Status`/`Last updated` line, an
    unreadable `--*-file`. Caught only in `cmd_update`, where it prints the message
    and exits 1 *before* the PATCH call, so a structural failure guarantees no
    partial workpad update. Contrast `_TickMatchError`, a per-row tick miss that is
    collected and reported without aborting the call's other mutations."""


class _TickMatchError(Exception):
    """Raised by the tick helpers (`_tick_checkbox`, `_tick_checkbox_by_index`)
    for a *volatile* per-row failure: a substring matching zero/multiple rows, an
    out-of-range index, or an index landing on an already-ticked row, *inside a
    present section*. Deliberately NOT a subclass of `_UpdateError` so the
    structural `except _UpdateError` in `cmd_update` never captures it. Collected
    per-tick in `_apply_mutations`; the call's other mutations still apply and
    PATCH, and `cmd_update` then exits non-zero naming each failed tick."""


def _report_failed_ticks(failed_ticks, preamble):
    """Write the collected volatile tick misses to stderr under `preamble`.

    The single chokepoint every `cmd_update` exit path routes its `failed_ticks`
    through, so a collected miss is reported on ALL three: the structural-abort
    path, the PATCH-failure path, and the clean-PATCH-but-ticks-missed path. The
    `preamble` states whether a PATCH was persisted, so the caller can tell
    'nothing landed, re-send the whole call' from 'the body PATCHed, re-tick only
    the unresolved row(s)' without re-sending the already-applied status/notes."""
    sys.stderr.write(f"workpad.py update: {preamble}:\n")
    for ft in failed_ticks:
        sys.stderr.write(f"  - {ft}\n")


def cmd_update(args):
    # Resolve comment ID from the issue. update is stateless for callers.
    # cmd_id prints + sys.exits; we inline the lookup to capture the ID.
    marker = _workpad_marker(args.marker)
    repo = _repo_full()
    comment_id = None
    page = 1
    while True:
        try:
            r = _run([
                GH, 'api',
                f'/repos/{repo}/issues/{args.issue}/comments'
                f'?page={page}&per_page=100',
            ])
        except (subprocess.CalledProcessError, OSError) as e:
            _fail('update id-lookup', e)
        try:
            items = json.loads(r.stdout)
        except json.JSONDecodeError as e:
            _fail('update id-lookup', f"could not parse gh comments response: {e}")
        for c in items:
            if (c.get('body') or '').startswith(marker):
                comment_id = c['id']
                break
        if comment_id is not None or len(items) < 100:
            break
        page += 1
    if comment_id is None:
        # Deliberately exit 1 (not cmd_id's exit-2 "scanned-clean-absent"): unlike
        # `id`, `update` has no create-fallback to disambiguate toward, so "absent"
        # here is a caller error (update before create), not a benign first-run
        # signal. Callers resolve create-vs-resume via `id` (which DOES split 2/1);
        # `update` only ever runs against an already-resolved workpad, so it does
        # not carry the exit-2 contract.
        sys.stderr.write(
            f"workpad.py update: no workpad found for issue #{args.issue}; "
            f"call `workpad.py create` first\n"
        )
        sys.exit(1)

    # Fetch live body (re-fetch invariant).
    try:
        r = _run([
            GH, 'api',
            f'/repos/{repo}/issues/comments/{comment_id}',
            '--jq', '.body',
        ])
    except (subprocess.CalledProcessError, OSError) as e:
        _fail('update body-fetch', e)
    body = r.stdout

    # `failed_ticks` collects *volatile* per-row tick misses (see _TickMatchError):
    # the call still applies and PATCHes every other mutation, then exits non-zero
    # naming the ticks that did not land. A *structural* _UpdateError still aborts
    # before any PATCH.
    failed_ticks = []
    try:
        body = _apply_mutations(body, args, failed_ticks)
    except _UpdateError as e:
        sys.stderr.write(f"workpad.py update: {e}\n")
        # A structural failure aborts before any PATCH — but volatile tick misses
        # collected before the abort would otherwise be dropped from this call's
        # output entirely. Echo them too so a combined call (a tick miss + a later
        # structural fault) reports BOTH faults, not just the structural one.
        if failed_ticks:
            _report_failed_ticks(
                failed_ticks,
                f"additionally, {len(failed_ticks)} tick(s) did not resolve before "
                f"the abort (no PATCH was made — re-send the whole call)",
            )
        sys.exit(1)

    # Write to a temp file and PATCH (same path as cmd_patch). The body always
    # carries at least the refreshed `Last updated`, so the PATCH is never a
    # no-op even when every requested tick was volatile.
    import tempfile
    with tempfile.NamedTemporaryFile(
        'w', suffix='.md', delete=False, encoding="utf-8",
    ) as tf:
        tf.write(body)
        tmp_path = tf.name
    try:
        r = _run([
            GH, 'api', '-X', 'PATCH',
            f'/repos/{repo}/issues/comments/{comment_id}',
            '-F', f'body=@{tmp_path}',
            '--jq', '.body',
        ])
    except (subprocess.CalledProcessError, OSError) as e:
        # The PATCH itself failed, so NO workpad change was persisted. Report any
        # volatile tick misses collected before the failure too — otherwise this
        # third exit path silently drops them (the very no-silent-loss invariant
        # this command establishes), leaving the operator unable to tell a clean
        # PATCH failure from one that also had unresolvable ticks.
        if failed_ticks:
            _report_failed_ticks(
                failed_ticks,
                f"the PATCH itself failed, so NO workpad change was persisted; "
                f"these {len(failed_ticks)} tick(s) had also not resolved",
            )
        _fail('update patch', e)
    finally:
        Path(tmp_path).unlink(missing_ok=True)
    sys.stdout.write(r.stdout)

    # Volatile tick failures: the PATCH landed (other mutations applied), but
    # report each unresolved tick to stderr and exit non-zero so the orchestrator
    # sees exactly which tick(s) failed. The body PATCHed, so the caller must
    # re-tick ONLY the named row(s) — NOT re-send the whole call (its --status/
    # --note/--reflection already landed; re-sending would double-write notes).
    if failed_ticks:
        _report_failed_ticks(
            failed_ticks,
            f"PATCHed, but {len(failed_ticks)} tick(s) did not resolve (the call's "
            f"other mutations were applied — re-tick only these row(s), do not "
            f"re-send the call)",
        )
        sys.exit(1)


def _apply_section_ticks(
    sections, section_name, flag_base, substr_texts, index_ns, failed_ticks,
):
    """Tick rows in the named section (`## Progress`/`## Plan`/`## Acceptance
    Criteria`) from the substring and index requests.

    Structural failure (the section is absent while ticks were requested) raises
    `_UpdateError` to abort the whole call. A per-row miss (substring zero/multiple,
    out-of-range/already-ticked index) is *volatile*: it is appended to
    `failed_ticks` as a flag-named descriptor and the remaining ticks still apply.
    Substring ticks are processed before index ticks; index positions count every
    `[ ]`/`[x]` row, so a prior substring tick never shifts an index target — though
    a substring tick that lands on the *same* row a later index targets makes that
    index report a benign "already ticked" volatile miss."""
    if not substr_texts and not index_ns:
        return
    idx = _find_section(sections, section_name)
    if idx is None:
        raise _UpdateError(f"section '## {section_name}' not found")
    heading, content = sections[idx]
    for text in substr_texts:
        try:
            content = _tick_checkbox(content, text, section_name)
        except _TickMatchError as e:
            failed_ticks.append(f"--tick-{flag_base} {text!r} — {e}")
    for n in index_ns:
        try:
            content = _tick_checkbox_by_index(content, n, section_name)
        except _TickMatchError as e:
            failed_ticks.append(f"--tick-{flag_base}-n {n} — {e}")
    sections[idx] = (heading, content)


# The marker parse-acs.py appends to a post-merge criterion, and the byte-for-byte
# token the Phase 3.4 AC gate excludes ("a criterion whose checkbox line ends in
# `(post-merge)`"). The terminal Complete gate reuses the same exclusion so its
# hard-fail set matches the gate's blocking set exactly.
_POST_MERGE_MARKER = '(post-merge)'


def _is_single_line(text: str) -> bool:
    """True when `text` holds no line boundary *as the row parser sees one*.

    Shares the consumer's own operation instead of re-deriving its contract. The
    checkbox-row parsers (`_find_checkbox_row`, `_post_merge_flags`, `_unticked_rows`)
    split with `str.splitlines()`, which breaks on far more than `\\n`/`\\r`: `\\v`,
    `\\f`, `\\x1c`-`\\x1e`, `\\x85` (NEL), `\\u2028` (LINE SEPARATOR) and `\\u2029`
    (PARAGRAPH SEPARATOR). A membership test for `'\\n'`/`'\\r'` accepts a *superset*
    of what `splitlines()` treats as one line, so any of those other separators would
    still split a checkbox row in two — a guard's accepted-input set must be a subset
    of its consumer's, never a guess at it. `''.join(text.splitlines()) == text` holds
    exactly when `splitlines()` finds no boundary (the empty string included, and a
    trailing separator caught too). A few section helpers (`_split_details`,
    `_append_progress_note`) split on `'\\n'` alone — a strict subset of the
    `splitlines()` boundaries — so this guard over-covers them too, never under.
    The same `splitlines()` idiom collapses multi-line `--reflection` text above."""
    return ''.join(text.splitlines()) == text


def _ends_with_post_merge(text: str) -> bool:
    """True when `text` carries the `(post-merge)` marker in TERMINAL position.
    Trailing whitespace is stripped first, so a stray space or newline can't mask
    the comparison (the anti-evasion the retag guard and `_unticked_rows` share)."""
    return text.rstrip().endswith(_POST_MERGE_MARKER)


def _pair_appends_post_merge(old: str, new: str, row_text: str) -> bool:
    """True when a `--rewrite-ac` OLD/NEW pair *appends* the `(post-merge)` tag to
    the row it targets: NEW ends with the marker while NEITHER the OLD argument nor
    `row_text` — the matched row's CURRENT label text, resolved by
    `_find_checkbox_row`, the same resolution the rewrite itself uses — already
    does. This is exactly the mid-run retag channel §3.4 requires a rationale
    `--note` for (issue #338): a pair that tags a previously-untagged criterion.

    Returns False (no rationale needed) when the pair *removes* the tag, or when
    the row it targets is ALREADY terminally tagged — a text tweak on an
    already-post-merge row creates no new deferral. Consulting `row_text` rather
    than the OLD argument alone is what makes that exemption hold for an OLD
    substring that does not itself span the tag (e.g. `--rewrite-ac "AC two"
    "AC two clarified (post-merge)"` against a row already reading
    `AC two (post-merge)`), which the argument-string-only form false-refused.

    The OLD conjunct is retained: a pair whose OLD spans the tag while the row is
    non-terminally tagged is the crafted multi-pair shuttle the state-based
    backstop in `_apply_mutations` exists to catch (it is not caught here, by
    design — see that backstop's comment)."""
    return (_ends_with_post_merge(new)
            and not _ends_with_post_merge(old)
            and not _ends_with_post_merge(row_text))


def _unticked_rows(content: str) -> tuple[list[str], list[str]]:
    """Split a checkbox section's still-unticked `- [ ]` rows into
    (non_post_merge, post_merge) by whether the row text ends in the
    `(post-merge)` marker (the Phase 3.4 exclusion). Non-checkbox lines
    (placeholders, prose) are ignored. Read-only — never mutates a row."""
    non_pm, pm = [], []
    for line in content.splitlines():
        m = _CHECKBOX_ROW_RE.match(line)
        if not m or m.group(2) != '[ ]':
            continue
        text = m.group(4)
        (pm if _ends_with_post_merge(text) else non_pm).append(text)
    return non_pm, pm


def _post_merge_flags(content: str) -> list[bool]:
    """Per-row `(post-merge)`-terminal flags for a checkbox section's rows, in
    document order — one entry per checkbox row, across EVERY tick state (`[ ]` and
    `[x]` alike). Non-checkbox lines (placeholders, prose) contribute nothing.

    This is the retag backstop's population, and it is deliberately WIDER than
    `_unticked_rows`' (which is `[ ]`-only because the Phase 3.4 terminal gate only
    reconciles still-unmet criteria): a marker landing on an already-`[x]` row is
    still a net-added `(post-merge)` row. Read-only — never mutates a row."""
    return [
        _ends_with_post_merge(m.group(4))
        for line in content.splitlines()
        if (m := _CHECKBOX_ROW_RE.match(line))
    ]


def _net_adds_post_merge(pre: list[bool], post: list[bool]) -> bool:
    """True when the `--rewrite-ac` loop tagged a criterion that was not terminally
    `(post-merge)` before it ran — i.e. some row transitioned False -> True.

    Compares POSITIONALLY, not by aggregate count. `_rewrite_checkbox` replaces one
    line in place (never inserts, deletes, or reorders), so a row's index is stable
    across the whole loop and index `i` before is index `i` after. A count-based
    comparison would miss a call that removes the tag from one row while adding it
    to another: the totals net to zero while a criterion was silently deferred.

    Defensive: a differing row count means the positional mapping is meaningless, so
    the comparison cannot answer the question at all. Fail CLOSED — treat it as a
    net-add. `_apply_mutations` rejects a multi-line NEW (`_is_single_line`) before the
    loop runs, so `_rewrite_checkbox` should not be able to change the row count; this
    branch is the backstop for that guard rather than dead code, and it exists so that
    any path which *does* change the count can never silently downgrade this guard to
    an aggregate count (which is blind to a remove-one/add-one swap — exactly the hole
    the positional comparison closes). Do not "simplify" it back to `sum(post) >
    sum(pre)`: that comparison returns False on a shorter-but-newly-tagged post state."""
    if len(pre) != len(post):
        return True
    return any(now and not before for before, now in zip(pre, post))


def _terminal_complete_gate(sections) -> list[str]:
    """Reconcile the workpad self-record on a terminal `--status Complete` write.

    Hard-fail (a *structural* `_UpdateError`, so `cmd_update` aborts before any
    PATCH and the Status is never flipped) when any NON-post-merge `## Acceptance
    Criteria` row is still `- [ ]`, naming each offending row on stderr. Post-merge
    AC rows are excluded (byte-for-byte the Phase 3.4 exclusion). Returns the
    still-unticked `## Plan` rows for the caller to emit a NON-blocking warning on
    (a genuinely dropped/superseded plan step may honestly stay unticked, so Plan
    is not hard-failed). Also emits a NON-blocking warning when the AC section still
    holds the un-mirrored `new-body` placeholder (mirroring never ran — a vacuously
    satisfied hard-fail), so a Complete over an unpopulated self-record is surfaced.
    NEVER modifies a row; an absent section contributes nothing. Called only for
    `--status Complete`, over the post-mutation sections."""
    ac_idx = _find_section(sections, 'Acceptance Criteria')
    if ac_idx is not None:
        ac_content = sections[ac_idx][1]
        non_pm, _pm = _unticked_rows(ac_content)
        if non_pm:
            rows = '\n'.join(f'    - [ ] {t}' for t in non_pm)
            raise _UpdateError(
                "refusing to finalize Status: Complete — "
                f"{len(non_pm)} non-post-merge Acceptance Criteria row(s) still "
                "unticked (tick each once its work is real, or route the run to "
                f"Blocked, before finalizing):\n{rows}"
            )
        # Fail-open guard: no unticked rows can mean the section was never mirrored
        # (still the `new-body` placeholder), not that every AC is satisfied. Warn
        # (non-blocking) so a Complete finalize over an un-mirrored self-record is
        # surfaced rather than passing silently. A genuinely AC-less issue carries
        # the DISTINCT `_(none provided in issue body)_` sentinel, so it is unaffected.
        if _AC_PENDING_PLACEHOLDER in ac_content:
            sys.stderr.write(
                "workpad.py update: warning: finalizing Status: Complete but the "
                "## Acceptance Criteria section still holds the un-mirrored placeholder "
                "— the self-record was never populated from the issue; verify the "
                "acceptance criteria were mirrored before relying on this Complete.\n"
            )
    plan_idx = _find_section(sections, 'Plan')
    if plan_idx is None:
        return []
    non_pm, pm = _unticked_rows(sections[plan_idx][1])
    return non_pm + pm  # Plan has no post-merge concept; warn on every unticked row


def _apply_mutations(body: str, args, failed_ticks) -> str:
    """Apply all mutations from args and return the new body.

    Structural failures (missing section / front-matter line / unreadable file)
    raise `_UpdateError` before returning — the caller must not PATCH. Volatile
    per-row tick misses are appended to the caller-provided `failed_ticks` list
    (a flat list of descriptor strings) and do NOT abort: the body returned still
    carries every other mutation, and the caller PATCHes it then reports the
    failed ticks. `failed_ticks` is a required out-parameter (no silent-swallow
    default); `cmd_update` is the production caller and always supplies one."""
    now_dt = datetime.datetime.now(datetime.timezone.utc)
    # Friendly UTC for the human-facing `Last updated` line (the `now`
    # subcommand still prints full ISO-8601 for machine uses like follow-up
    # issue bodies; note bullets keep their time-only HH:MM:SS prefix).
    last_updated = now_dt.strftime('%Y-%m-%d %H:%M UTC')
    now_time = now_dt.strftime('%H:%M:%S')        # time-only for note bullets

    # Front-matter mutations.
    if args.status:
        clean = _strip_status_glyph(args.status)
        glyph = _status_glyph(clean)
        body, n = _STATUS_RE.subn(f'**Status:** {glyph} {clean}', body, count=1)
        if n == 0:
            raise _UpdateError('Status line not found in workpad')
    if args.branch:
        body, n = _BRANCH_RE.subn(
            lambda _m: f'**Branch:** `{args.branch}`', body, count=1,
        )
        if n == 0:
            raise _UpdateError('Branch line not found in workpad')
    if args.run_link:
        body = _set_or_insert_header(body, _RUN_RE, 'Run', args.run_link, [_BRANCH_RE])
    if args.pr_link:
        # Anchor PR after Run when Run exists (else Branch), so the canonical
        # Run-then-PR order holds whether one or both lines are being inserted.
        body = _set_or_insert_header(
            body, _PR_RE, 'PR', args.pr_link, [_RUN_RE, _BRANCH_RE],
        )

    # Always refresh Last updated.
    body, n = _LAST_UPDATED_RE.subn(f'**Last updated:** {last_updated}', body, count=1)
    if n == 0:
        raise _UpdateError('Last updated line not found in workpad')

    # Notes nest under their lifecycle phase inside ## Progress. Read the
    # post-mutation Status so a combined `--status X --note Y` call files the
    # note under X's phase (the status line was already rewritten above). Strip
    # the leading glyph so the phase lookup keys on the bare word ("Reviewing").
    status_match = _STATUS_VALUE_RE.search(body)
    current_phase = (
        _strip_status_glyph(status_match.group(1).strip()) if status_match else None
    )

    # Section-level mutations.
    preamble, sections = _split_sections(body)

    # Progress has no index form (Progress checkboxes stay substring-addressed);
    # Plan/AC accept both the substring and `-n` index forms in one call.
    _apply_section_ticks(
        sections, 'Progress', 'progress', args.tick_progress, [], failed_ticks,
    )
    _apply_section_ticks(
        sections, 'Plan', 'plan', args.tick_plan, args.tick_plan_n, failed_ticks,
    )
    _apply_section_ticks(
        sections, 'Acceptance Criteria', 'ac', args.tick_ac, args.tick_ac_n,
        failed_ticks,
    )

    if args.rewrite_ac:
        idx = _find_section(sections, 'Acceptance Criteria')
        if idx is None:
            raise _UpdateError("section '## Acceptance Criteria' not found")
        # Rationale-required guard (issue #338): any pair that *appends* the
        # `(post-merge)` tag (NEW ends with it; neither OLD nor the row the pair
        # resolves to already does) is a mid-run retag —
        # the §3.4 channel used to defer a criterion's verification past merge — and
        # MUST carry a non-empty `--note` recording why the deferral qualifies
        # (genuinely-live), so a silently-laundered self-reconfiguration/tooling-gap
        # deferral becomes a recorded, retrospective-auditable claim rather than a
        # trust-me tag. Fail structurally (raise before any PATCH → all-or-nothing,
        # Status never flips) when no non-empty note accompanies such a pair. The
        # guard cannot judge the rationale's *truth* — it enforces that one exists,
        # and does so at *call* scope: any one non-empty `--note` in the same
        # `update` call satisfies it, whether or not that note is *about* the retag
        # (the note is appended to Progress, not bound to the rewritten row). The
        # retrospective auditor reads the recorded note; the guard only guarantees
        # there is one to read. Only `--note` satisfies it: a `--reflection` is a
        # different channel (## Devflow Reflection) and never stands in for the
        # rationale. The check runs per pair INSIDE the rewrite loop below, against
        # the row each pair actually resolves to, so a text tweak on an
        # already-`(post-merge)` row is exempt even when the OLD substring does not
        # itself span the tag.
        # Scope: this covers the `--rewrite-ac` retag channel only; the Phase 2.2.5
        # `--replace-acs-file` channel can introduce `(post-merge)` rows wholesale —
        # a deliberate, known limitation left open here, not closed by this guard.
        has_note = any(n.strip() for n in args.note)
        # A multi-line NEW is structurally invalid, and rejecting it here is load-bearing
        # for BOTH guards below (issue #338). `_rewrite_checkbox` writes NEW verbatim into
        # one line, so an embedded line boundary SPLITS that checkbox row in two: it injects
        # an unreviewed AC row, and it breaks the row-index stability `_net_adds_post_merge`
        # compares against. It also slips the per-pair guard, whose `NEW ends with the
        # marker` test reads the whole string — `X (post-merge)<sep>- [ ] Y` ends with `Y`,
        # so the tag reads non-terminal while landing terminal on the split row. Combined
        # with a compensating tag-removal, that laundered a note-less deferral.
        # `_is_single_line` shares the row parser's own `str.splitlines()` contract, so the
        # rejected set matches the splitting set exactly — a `'\n'`/`'\r'` membership test
        # would accept `\v`, `\f`, `\x1c`-`\x1e`, NEL, LS and PS, every one of which still
        # splits the row. Reject unconditionally (a malformed argument, note or not), before
        # any PATCH, so the all-or-nothing contract holds.
        offending_nl = next((p for p in args.rewrite_ac if not _is_single_line(p[1])),
                            None)
        if offending_nl:
            raise _UpdateError(
                f"--rewrite-ac pair {offending_nl[0]!r} -> {offending_nl[1]!r} has a line "
                f"boundary in NEW; an AC row is a single line (it would split into an "
                f"extra, unreviewed row). No PATCH was made."
            )
        # --rewrite-ac is repeatable (issue #308): apply every OLD/NEW pair in
        # argument order against the progressively-rewritten section. Each pair
        # runs the existing exactly-one-match rule, so a pair matching zero or
        # multiple rows raises _UpdateError here — before any PATCH — preserving
        # the structural all-or-nothing contract for the whole call. Thread
        # `content` through a local and write `sections[idx]` once after the
        # loop, so a mid-loop raise leaves the section fully untouched.
        heading, content = sections[idx]
        # State-based backstop (issue #338 hardening): the per-pair guard consults
        # the resolved row's text, but still exempts any pair whose OLD argument
        # itself spans the tag, so a crafted MULTI-pair call whose pairs each
        # individually dodge `_pair_appends_post_merge` — e.g.
        # pair 1 places the marker non-terminally (`X` -> `(post-merge) X`, NEW
        # doesn't end in the tag), pair 2 makes it terminal (`(post-merge)` ->
        # `X (post-merge)`, OLD ends in the tag) — could net-add a post-merge row
        # with no note and slip past. Snapshot each AC row's post-merge-terminal
        # flag before the loop and compare POSITIONALLY after it: any row that went
        # untagged -> terminally-tagged is a laundered deferral regardless of how the
        # pairs were shaped, so abort here (still before any PATCH → all-or-nothing
        # holds). Row indices are stable because `_rewrite_checkbox` replaces a line
        # in place AND the `_is_single_line` rejection above keeps a NEW from splitting
        # a row. The flags span EVERY tick state (`_post_merge_flags`, not
        # `_unticked_rows`): an unticked-only population would miss the same shuttle
        # aimed at an already-`[x]` row, which still net-adds a tagged row. And the
        # comparison is positional, not an aggregate count, so a call that removes
        # the tag from one row while adding it to another — netting to zero — is
        # caught too. This is additive: it never fires on a call the per-pair guard
        # already caught, and it leaves the tag-preserving/tag-removing cases (no
        # False -> True transition) untouched. Scope: like the per-pair guard, this
        # covers the `--rewrite-ac` channel only — the Phase 2.2.5
        # `--replace-acs-file` channel remains a deliberate, documented exception.
        pre_pm = _post_merge_flags(content)
        for old, new in args.rewrite_ac:
            if not has_note:
                # Resolve the row this pair targets with the rewriter's own
                # resolution, then ask whether the pair terminally tags it.
                _row_text = _find_checkbox_row(
                    content, old, 'Acceptance Criteria',
                )[2].group(4)
                if _pair_appends_post_merge(old, new, _row_text):
                    raise _UpdateError(
                        f"--rewrite-ac pair {old!r} -> {new!r} appends the "
                        f"{_POST_MERGE_MARKER} tag but no non-empty --note "
                        f"rationale was supplied; a mid-run {_POST_MERGE_MARKER} "
                        f"retag must record why the deferral is genuinely-live "
                        f"(§3.4). No PATCH was made."
                    )
            content = _rewrite_checkbox(content, old, new, 'Acceptance Criteria')
        if not has_note and _net_adds_post_merge(pre_pm, _post_merge_flags(content)):
            raise _UpdateError(
                f"a --rewrite-ac in this call net-adds a {_POST_MERGE_MARKER} "
                f"criterion but no non-empty --note rationale was supplied; a "
                f"mid-run {_POST_MERGE_MARKER} retag must record why the deferral "
                f"is genuinely-live (§3.4). No PATCH was made."
            )
        sections[idx] = (heading, content)

    if args.replace_plan_file:
        new_content = _read_section_file(args.replace_plan_file, '--replace-plan-file')
        sections = _set_section_content(sections, 'Plan', new_content)

    if args.replace_acs_file:
        new_content = _read_section_file(args.replace_acs_file, '--replace-acs-file')
        sections = _set_section_content(
            sections, 'Acceptance Criteria', new_content,
        )

    if args.set_reproduction_file:
        new_content = _read_section_file(
            args.set_reproduction_file, '--set-reproduction-file',
        )
        if _find_section(sections, 'Reproduction') is not None:
            sections = _set_section_content(sections, 'Reproduction', new_content)
        else:
            sections = _insert_section_after(
                sections, 'Acceptance Criteria', '## Reproduction', new_content,
            )

    if args.note:
        idx = _find_section(sections, 'Progress')
        if idx is None:
            raise _UpdateError("section '## Progress' not found")
        heading, content = sections[idx]
        phase_label = _progress_phase_for_status(content, current_phase)
        for text in args.note:
            content = _append_progress_note(content, text, now_time, phase_label)
        sections[idx] = (heading, content)

    if args.reflection:
        idx = _find_section(sections, 'Devflow Reflection')
        if idx is None:
            raise _UpdateError("section '## Devflow Reflection' not found")
        heading, content = sections[idx]
        # Direct attribute access (not getattr-with-default), matching the sibling
        # args.note / args.reflection reads above: argparse always supplies
        # reflection_kind (default=None), so a missing attribute is a wiring
        # regression that should fail loud rather than silently file every bullet
        # as a `note`. The `or _DEFAULT_REFLECTION_KIND` handles only the
        # legitimate flag-omitted None case.
        kind = args.reflection_kind or _DEFAULT_REFLECTION_KIND
        for bullet in args.reflection:
            content = _append_reflection(content, kind, bullet)
        sections[idx] = (heading, content)

    # Record the reproduce-first content classification (issue #449) as a
    # superseding `classification: ` Progress note — exactly one at all times.
    if args.record_classification:
        cls, rationale = args.record_classification
        if cls not in _CLASSIFICATION_VALUES:
            raise _UpdateError(
                f"--record-classification: unknown class {cls!r}; expected one of "
                f"{', '.join(_CLASSIFICATION_VALUES)}"
            )
        # Empty-check the STRIPPED value (a whitespace-only rationale is empty), but
        # single-line-check the RAW value so a trailing newline is still rejected
        # rather than silently trimmed into acceptance.
        stripped_rationale = rationale.strip()
        if not stripped_rationale:
            raise _UpdateError(
                "--record-classification: a non-empty rationale is required (the "
                "note form is 'classification: <class> — <rationale>')"
            )
        if not _is_single_line(rationale):
            # A line boundary would split the note bullet (same hazard --rewrite-ac
            # guards against); reject before any PATCH so all-or-nothing holds.
            raise _UpdateError(
                "--record-classification: rationale must be a single line (a line "
                "boundary would split the note bullet). No PATCH was made."
            )
        idx = _find_section(sections, 'Progress')
        if idx is None:
            raise _UpdateError("section '## Progress' not found")
        heading, content = sections[idx]
        content = _remove_classification_notes(content)
        note_text = f'{_CLASSIFICATION_NOTE_PREFIX}{cls} — {stripped_rationale}'
        phase_label = _progress_phase_for_status(content, current_phase)
        content = _append_progress_note(content, note_text, now_time, phase_label)
        sections[idx] = (heading, content)

    # Reconcile the bug-only reproduction Progress row to the classification
    # (issue #449) — idempotent, runs on every Phase 1.3 entry.
    if args.reconcile_reproduction:
        idx = _find_section(sections, 'Progress')
        if idx is None:
            raise _UpdateError("section '## Progress' not found")
        heading, content = sections[idx]
        content = _reconcile_reproduction_row(content, args.reconcile_reproduction)
        sections[idx] = (heading, content)

    # Terminal self-record gate (issue #258): a `--status Complete` write is the
    # deterministic chokepoint that guarantees the workpad's Plan/AC self-record
    # matches reality. It runs LAST, over the *post-mutation* sections, so a call
    # that ticks the final AC row and flips to Complete in one shot still passes.
    # Detection reuses `_status_glyph` (the single source of truth for the
    # Complete/🎉 vocabulary), so a non-Complete status (Blocked/👎, any in-progress
    # 🚀) and a status-less update are never gated.
    if args.status and _status_glyph(args.status) == '🎉':
        unticked_plan = _terminal_complete_gate(sections)  # AC hard-fail raises here
        if unticked_plan:
            rows = '; '.join(t.strip() for t in unticked_plan)
            sys.stderr.write(
                "workpad.py update: warning: finalizing Status: Complete with "
                f"{len(unticked_plan)} unticked ## Plan row(s) — a genuinely "
                "dropped/superseded step may honestly stay unticked, but verify: "
                f"{rows}\n"
            )

    return _join_sections(preamble, sections)


def main():
    _force_utf8_streams()
    p = argparse.ArgumentParser(prog='workpad.py')
    sub = p.add_subparsers(dest='cmd', required=True)

    # Shared marker-override help. Passing the marker as a regular argument
    # (rather than via the DEVFLOW_WORKPAD_MARKER env var, which forced a
    # leading env-assignment onto the command) keeps the helper path as the
    # command prefix so the cloud allow-list rule `Bash(.../workpad.py:*)`
    # still matches — /devflow:review relies on this for its
    # `<!-- devflow:review-progress -->` comment.
    _marker_help = (
        'Marker comment that tags this workpad. Overrides the '
        'DEVFLOW_WORKPAD_MARKER env var and the .devflow/config.json value; '
        "defaults to '<!-- devflow:workpad -->'."
    )

    s = sub.add_parser('id', help='Print workpad comment ID for an issue (exit 2 if absent; exit 1 on API/parse error).')
    s.add_argument('issue', type=int)
    s.add_argument('--marker', default=None, help=_marker_help)
    s.set_defaults(func=cmd_id)

    s = sub.add_parser('body', help='Print the body of an existing workpad comment.')
    s.add_argument('comment_id', type=int)
    s.set_defaults(func=cmd_body)

    s = sub.add_parser(
        'status',
        help='Print the workpad Status as `CLASS GLYPH WORD` (CLASS is '
             'terminal|interim). Exit 2 if no workpad, exit 1 if present but the '
             'Status is unreadable.',
    )
    s.add_argument('issue', type=int)
    s.add_argument('--marker', default=None, help=_marker_help)
    s.set_defaults(func=cmd_status)

    s = sub.add_parser('patch', help='PATCH a workpad comment from a body file; prints new body.')
    s.add_argument('comment_id', type=int)
    s.add_argument('body_file')
    s.set_defaults(func=cmd_patch)

    s = sub.add_parser('create', help='Create the workpad comment for an issue; prints new ID.')
    s.add_argument('issue', type=int)
    s.add_argument('body_file')
    s.set_defaults(func=cmd_create)

    s = sub.add_parser('now', help='UTC ISO-8601 timestamp.')
    s.set_defaults(func=cmd_now)

    s = sub.add_parser(
        'new-body',
        help='Print the lean initial workpad skeleton to stdout (pipe to a '
             'file, then `create`).',
    )
    s.add_argument('issue', type=int)
    s.add_argument('--run-link', metavar='VALUE', default=None,
                   help='Run front-matter value (markdown ok). Defaults to a '
                        '"_(local run)_" placeholder when omitted.')
    s.add_argument('--branch', metavar='VALUE', default=None,
                   help='Branch name. Defaults to a "_(creating…)_" placeholder.')
    s.add_argument('--no-reproduction', action='store_true',
                   help='Omit the bug-only "reproduction captured" sub-item. '
                        'Pass when the recorded content classification is '
                        'non-bug; the line renders by default so a deterministic '
                        'label-based pre-render never drops it, and Phase 1.3 '
                        'reconciles it to the classification (issue #449).')
    s.add_argument('--marker', default=None, help=_marker_help)
    s.set_defaults(func=cmd_new_body)

    u = sub.add_parser(
        'update',
        help='Apply mutations to the workpad and PATCH. Re-fetches the body '
             'internally; Last updated is refreshed automatically. Structural '
             'failures abort with no PATCH; a per-row tick miss is reported and '
             'exits non-zero but still PATCHes the call\'s other mutations.',
    )
    u.add_argument('issue', type=int)
    u.add_argument('--status', help='Replace the Status line value. A canonical '
                   'glyph (🚀 running / 🎉 Complete / 👎 Blocked / 💥 Failed) is '
                   'derived from the status word and prepended automatically.')
    u.add_argument('--branch', help='Replace the Branch line value.')
    u.add_argument('--run-link', metavar='VALUE',
                   help='Set the Run front-matter line to VALUE (markdown ok). '
                        'Inserted after Branch if the line is absent.')
    u.add_argument('--pr-link', metavar='VALUE',
                   help='Set the PR front-matter line to VALUE (markdown ok). '
                        'Inserted after Branch if the line is absent.')
    u.add_argument('--tick-progress', metavar='TEXT', action='append', default=[],
                   help='Tick one ## Progress checkbox matching TEXT (substring). '
                        'Repeatable. A zero/multiple-match miss is a volatile '
                        'failure: the call PATCHes its other mutations and exits '
                        'non-zero naming the miss (no index form for Progress).')
    u.add_argument('--tick-plan', metavar='TEXT', action='append', default=[],
                   help='Tick one Plan checkbox matching TEXT (substring). '
                        'Repeatable. A zero/multiple-match miss is volatile (see '
                        '--tick-progress).')
    u.add_argument('--tick-plan-n', metavar='N', type=int, action='append',
                   default=[],
                   help='Tick the Nth Plan checkbox (1-based, counting every '
                        '[ ] and [x] row within the ## Plan section, in document '
                        'order; section-scoped, not whole-document). Repeatable; '
                        'combinable with --tick-plan and every other flag. An '
                        'out-of-range or already-ticked N is a volatile failure '
                        '(reported, non-zero exit, other mutations applied).')
    u.add_argument('--tick-ac', metavar='TEXT', action='append', default=[],
                   help='Tick one Acceptance Criteria checkbox matching TEXT '
                        '(substring). Repeatable. A zero/multiple-match miss is '
                        'volatile (see --tick-progress).')
    u.add_argument('--tick-ac-n', metavar='N', type=int, action='append',
                   default=[],
                   help='Tick the Nth Acceptance Criteria checkbox (1-based, '
                        'counting every [ ] and [x] row within the ## Acceptance '
                        'Criteria section, in document order; section-scoped, not '
                        'whole-document). '
                        'Repeatable; combinable with --tick-ac and every other '
                        'flag. An out-of-range or already-ticked N is a volatile '
                        'failure (reported, non-zero exit, other mutations '
                        'applied).')
    u.add_argument('--rewrite-ac', nargs=2, metavar=('OLD', 'NEW'),
                   action='append', default=[],
                   help='Find one AC matching OLD; replace its text with NEW. '
                        'Preserves the checkbox state. For Phase 2.2.6. '
                        'Repeatable: multiple pairs apply in argument order, each '
                        'validated by the exactly-one-match rule; any pair '
                        'matching zero or multiple rows aborts the whole call '
                        'with no PATCH (structural all-or-nothing). NEW must be a '
                        'single line: a line boundary would split the criterion '
                        'into an extra, unreviewed row, so it aborts the call. '
                        'A pair that '
                        'appends the (post-merge) tag (NEW ends with it; neither '
                        'OLD nor the row it targets already does) is a mid-run '
                        'retag and requires a non-empty --note rationale (issue '
                        '#338); without one the call aborts structurally before '
                        'any PATCH. A pair targeting a row that already ends '
                        'with the tag, or that removes it, needs no note. Only '
                        '--note satisfies the rationale; a --reflection does not.')
    u.add_argument('--note', metavar='TEXT', action='append', default=[],
                   help='Append a note bullet, prefixed with a time-only '
                        'HH:MM:SS UTC timestamp and nested under the current '
                        'Status\'s phase inside ## Progress. May be passed '
                        'multiple times to append several entries (sharing one '
                        'timestamp) in one atomic update.')
    u.add_argument('--reflection', metavar='TEXT', action='append', default=[],
                   help='Append a bullet to Devflow Reflection (no timestamp). '
                        'May be passed multiple times to append several bullets '
                        'in one atomic update.')
    u.add_argument('--reflection-kind',
                   # Derive choices from the taxonomy dict so the CLI-validated
                   # set and the `_REFLECTION_KINDS[kind]` lookup can never drift
                   # (a kind added to one but not the other would KeyError). Dict
                   # insertion order → blocked, deferred, dropped-failed, note.
                   choices=list(_REFLECTION_KINDS),
                   default=None,
                   help="Kind for this update's --reflection bullet(s). "
                        'blocked/deferred/dropped-failed render under '
                        '"### ⚠️ Action required"; note (the default '
                        'when omitted) under "### ℹ️ Notes". Applies '
                        'to every --reflection bullet in the call.')
    u.add_argument('--replace-plan-file', metavar='FILE',
                   help='Replace the Plan section content with FILE contents.')
    u.add_argument('--replace-acs-file', metavar='FILE',
                   help='Replace Acceptance Criteria content with FILE contents. '
                        'For Phase 2.2.5 scope adjustment.')
    u.add_argument('--set-reproduction-file', metavar='FILE',
                   help='Set the Reproduction section to FILE contents. Inserts '
                        'the section after Acceptance Criteria if missing.')
    u.add_argument('--record-classification', nargs=2,
                   metavar=('CLASS', 'RATIONALE'),
                   help='Record the Phase 2.1.5 reproduce-first content '
                        'classification (issue #449) as a superseding '
                        '"classification: <CLASS> — <RATIONALE>" ## Progress note. '
                        'CLASS is bug-report or non-bug; RATIONALE is a non-empty '
                        'single line. Replaces any existing classification note, so '
                        'the workpad carries exactly one at all times.')
    u.add_argument('--reconcile-reproduction', choices=_CLASSIFICATION_VALUES,
                   help='Idempotently reconcile the bug-only "reproduction '
                        'captured" ## Progress row to the classification: '
                        'bug-report adds it when absent, non-bug removes it when '
                        'present and unticked (a ticked row is preserved), and it '
                        'no-ops when the skeleton already matches. Run on every '
                        'Phase 1.3 entry.')
    u.add_argument('--marker', default=None, help=_marker_help)
    u.set_defaults(func=cmd_update)

    args = p.parse_args()
    args.func(args)


if __name__ == '__main__':
    main()
