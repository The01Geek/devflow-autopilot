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
the rest of devflow). The workpad marker is read from
`.devflow/config.json` via the bundled `config-get.sh` helper, falling
back to the built-in default `<!-- devflow:workpad -->` when the config file or
key is absent (so it works with no config).

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


def _run(cmd, *, stdout=subprocess.PIPE, stdin=None):
    return subprocess.run(
        cmd, check=True, stdin=stdin, stdout=stdout,
        stderr=subprocess.PIPE, text=True,
    )


def _fail(prefix, exc):
    msg = exc.stderr.strip() if isinstance(exc, subprocess.CalledProcessError) else str(exc)
    sys.stderr.write(f"workpad.py {prefix}: {msg}\n")
    sys.exit(1)


def _repo_full():
    try:
        r = _run(['gh', 'repo', 'view', '--json', 'nameWithOwner',
                  '-q', '.nameWithOwner'])
    except subprocess.CalledProcessError as e:
        _fail('repo lookup', e)
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
    # Read the marker from .devflow/config.json, but fall back to the
    # built-in default so the local tier works with no config file at all.
    here = Path(__file__).resolve().parent
    helper = here / 'config-get.sh'
    try:
        r = _run([str(helper), '.devflow.workpad_marker', _DEFAULT_WORKPAD_MARKER])
    except (subprocess.CalledProcessError, OSError):
        return _DEFAULT_WORKPAD_MARKER
    marker = r.stdout.strip()
    return marker or _DEFAULT_WORKPAD_MARKER


def cmd_id(args):
    marker = _workpad_marker(args.marker)
    repo = _repo_full()
    page = 1
    while True:
        try:
            r = _run([
                'gh', 'api',
                f'/repos/{repo}/issues/{args.issue}/comments'
                f'?page={page}&per_page=100',
            ])
        except subprocess.CalledProcessError as e:
            _fail('id', e)
        try:
            items = json.loads(r.stdout)
        except json.JSONDecodeError as e:
            _fail('id', f"could not parse gh comments response: {e}")
        for c in items:
            body = c.get('body') or ''
            if body.startswith(marker):
                print(c['id'])
                return
        if len(items) < 100:
            break
        page += 1
    # Exit 2 (distinct from _fail's exit 1) means "scanned successfully, no
    # matching comment" — i.e. first run / not yet seeded. A real `gh api` or
    # parse failure above exits 1 via _fail. Callers can thus tell a benign
    # "create it" from a transient API error and avoid posting a duplicate
    # workpad comment on a failure they mistook for "not found".
    sys.exit(2)


def cmd_body(args):
    repo = _repo_full()
    try:
        r = _run([
            'gh', 'api',
            f'/repos/{repo}/issues/comments/{args.comment_id}',
            '--jq', '.body',
        ])
    except subprocess.CalledProcessError as e:
        _fail('body', e)
    sys.stdout.write(r.stdout)


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
            'gh', 'api', '-X', 'PATCH',
            f'/repos/{repo}/issues/comments/{args.comment_id}',
            '-F', f'body=@{body_path}',
            '--jq', '.body',
        ])
    except subprocess.CalledProcessError as e:
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
            'gh', 'issue', 'comment', str(args.issue),
            '--body-file', str(body_path),
        ])
    except subprocess.CalledProcessError as e:
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
    # The reproduction sub-item is bug-only. It renders by default because the
    # `gate` job creates the workpad without knowing the issue's labels, so the
    # default must not drop it; the local fresh-issue path (Phase 1.3) passes
    # --no-reproduction for non-bug issues to keep the Progress list free of a
    # permanently-unticked row.
    repro = (
        ''
        if getattr(args, 'no_reproduction', False)
        else '  - [ ] reproduction captured (bug issues only)\n'
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
_(pending — mirrored from the issue when the run begins)_

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

# Canonical status glyphs (reaction-compatible). The Status line always begins
# with one; `_status_glyph` derives it from the status word so the orchestrator
# passes a bare status ("Setup", "Complete", "Blocked") and the helper is the
# single source of truth for the glyph vocabulary. 🚀=running (any in-progress
# phase), 🎉=Complete, 👎=Blocked. These match the triggering-comment reactions
# (rocket / hooray / -1) the implement skill emits.
_STATUS_GLYPHS = ('🚀', '🎉', '👎')


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

    Mapped statuses nest under their phase; an unmapped status (Blocked) or a
    mapped phase that isn't present nests under the most recent *ticked*
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


def _rewrite_checkbox(
    content: str, old_substr: str, new_text: str, section_label: str
) -> str:
    """Find one checkbox matching old_substr; replace its label text with new_text.
    Preserves checkbox state (`[ ]` vs `[x]`) and indentation."""
    matched = []
    new_lines = []
    for line in content.splitlines():
        m = _CHECKBOX_ROW_RE.match(line)
        if m and old_substr.lower() in m.group(4).lower():
            matched.append((len(new_lines), m))
        new_lines.append(line)
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
                'gh', 'api',
                f'/repos/{repo}/issues/{args.issue}/comments'
                f'?page={page}&per_page=100',
            ])
        except subprocess.CalledProcessError as e:
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
            'gh', 'api',
            f'/repos/{repo}/issues/comments/{comment_id}',
            '--jq', '.body',
        ])
    except subprocess.CalledProcessError as e:
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
    with tempfile.NamedTemporaryFile('w', suffix='.md', delete=False) as tf:
        tf.write(body)
        tmp_path = tf.name
    try:
        r = _run([
            'gh', 'api', '-X', 'PATCH',
            f'/repos/{repo}/issues/comments/{comment_id}',
            '-F', f'body=@{tmp_path}',
            '--jq', '.body',
        ])
    except subprocess.CalledProcessError as e:
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
        old, new = args.rewrite_ac
        idx = _find_section(sections, 'Acceptance Criteria')
        if idx is None:
            raise _UpdateError("section '## Acceptance Criteria' not found")
        heading, content = sections[idx]
        sections[idx] = (
            heading,
            _rewrite_checkbox(content, old, new, 'Acceptance Criteria'),
        )

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

    return _join_sections(preamble, sections)


def main():
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
                        'Pass for non-bug issues; the line renders by default so '
                        'the label-agnostic gate job keeps it.')
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
                   'glyph (🚀 running / 🎉 Complete / 👎 Blocked) is derived from '
                   'the status word and prepended automatically.')
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
                   help='Find one AC matching OLD; replace its text with NEW. '
                        'Preserves the checkbox state. For Phase 2.2.6.')
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
    u.add_argument('--marker', default=None, help=_marker_help)
    u.set_defaults(func=cmd_update)

    args = p.parse_args()
    args.func(args)


if __name__ == '__main__':
    main()
