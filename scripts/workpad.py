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
    workpad.py id      ISSUE
    workpad.py body    COMMENT_ID
    workpad.py patch   COMMENT_ID BODY_FILE
    workpad.py create  ISSUE BODY_FILE
    workpad.py now
    workpad.py update  ISSUE [mutations...]

`id` exits 1 with empty stdout when no workpad exists yet (so callers can
detect "first run" via `$?` or an empty captured value, the same shape the
previous bash helper had).

`update` is the high-level mutation entry point used by /implement at every
phase boundary. It re-fetches the workpad body, applies the requested
mutations atomically, auto-updates `Last updated`, and PATCHes the result.
The Decisions/Notes section is append-only; Devflow Reflection accumulates
bullets; checkbox sections are mutated in place rather than rewritten. See
`workpad.py update --help` for the available mutation flags.
"""

import argparse
import datetime
import json
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


def _workpad_marker():
    # Read the marker from .devflow/config.json, but fall back to the
    # built-in default so the local tier works with no config file at all.
    here = Path(__file__).resolve().parent
    helper = here / 'config-get.sh'
    try:
        r = _run([str(helper), '.claude.workpad_marker', _DEFAULT_WORKPAD_MARKER])
    except (subprocess.CalledProcessError, OSError):
        return _DEFAULT_WORKPAD_MARKER
    marker = r.stdout.strip()
    return marker or _DEFAULT_WORKPAD_MARKER


def cmd_id(args):
    marker = _workpad_marker()
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
    sys.exit(1)


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
_BRANCH_RE = re.compile(r'^\*\*Branch:\*\*\s+.*$', re.MULTILINE)
_LAST_UPDATED_RE = re.compile(r'^\*\*Last updated:\*\*\s+.*$', re.MULTILINE)
_SECTION_RE = re.compile(r'^(##\s+.+)$', re.MULTILINE)


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


def _tick_checkbox(content: str, text_substr: str, section_label: str) -> str:
    """Tick exactly one matching unticked `- [ ]`/`* [ ]` checkbox in the section.

    Only `[ ]` rows are considered candidates; already-ticked rows are ignored.
    This means a duplicate `--tick-plan`/`--tick-ac` value (or a substring that
    only matches an already-ticked row) raises `_UpdateError` instead of
    silently no-op'ing — repeated calls in a batch loop are surfaced as errors
    rather than swallowed."""
    candidates = []
    new_lines = []
    for line in content.splitlines():
        m = re.match(r'^(\s*[-*]\s+)\[ \](\s+)(.*)$', line)
        if m and text_substr.lower() in m.group(3).lower():
            candidates.append((len(new_lines), m))
        new_lines.append(line)
    if not candidates:
        raise _UpdateError(
            f"no unticked {section_label} checkbox matched substring "
            f"{text_substr!r} (already ticked, or no match)"
        )
    if len(candidates) > 1:
        raise _UpdateError(
            f"{len(candidates)} {section_label} checkboxes match {text_substr!r}; "
            f"be more specific"
        )
    line_idx, m = candidates[0]
    new_lines[line_idx] = f"{m.group(1)}[x]{m.group(2)}{m.group(3)}"
    return '\n'.join(new_lines) + ('\n' if content.endswith('\n') else '')


def _rewrite_checkbox(
    content: str, old_substr: str, new_text: str, section_label: str
) -> str:
    """Find one checkbox matching old_substr; replace its label text with new_text.
    Preserves checkbox state (`[ ]` vs `[x]`) and indentation."""
    matched = []
    new_lines = []
    for line in content.splitlines():
        m = re.match(r'^(\s*[-*]\s+)(\[[ xX]\])(\s+)(.*)$', line)
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
    return '\n'.join(new_lines) + ('\n' if content.endswith('\n') else '')


def _append_note(content: str, note: str, timestamp: str) -> str:
    """Append a `- {timestamp} — {note}` bullet to a bullet-list section."""
    stripped = content.rstrip('\n')
    if stripped and not stripped.endswith('\n'):
        stripped += '\n'
    return stripped + f"- {timestamp} — {note}\n"


def _append_bullet(content: str, text: str) -> str:
    """Append a `- {text}` bullet (no timestamp) to a bullet-list section."""
    stripped = content.rstrip('\n')
    if stripped and not stripped.endswith('\n'):
        stripped += '\n'
    return stripped + f"- {text}\n"


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
    """Raised by mutation helpers in `_apply_mutations` to signal a recoverable
    error (no matching section, ambiguous checkbox, missing front-matter line,
    ...). Caught only in `cmd_update`, where it prints the message and exits
    1 *before* the PATCH call — so a failed mutation guarantees no partial
    workpad update."""


def cmd_update(args):
    # Resolve comment ID from the issue. update is stateless for callers.
    # cmd_id prints + sys.exits; we inline the lookup to capture the ID.
    marker = _workpad_marker()
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

    try:
        body = _apply_mutations(body, args)
    except _UpdateError as e:
        sys.stderr.write(f"workpad.py update: {e}\n")
        sys.exit(1)

    # Write to a temp file and PATCH (same path as cmd_patch).
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
        _fail('update patch', e)
    finally:
        Path(tmp_path).unlink(missing_ok=True)
    sys.stdout.write(r.stdout)


def _apply_mutations(body: str, args) -> str:
    """Apply all mutations from args atomically. Raises _UpdateError on any
    failure; caller should not patch on failure."""
    now = datetime.datetime.now(datetime.timezone.utc).strftime(
        '%Y-%m-%dT%H:%M:%SZ'
    )

    # Front-matter mutations.
    if args.status:
        body, n = _STATUS_RE.subn(f'**Status:** {args.status}', body, count=1)
        if n == 0:
            raise _UpdateError('Status line not found in workpad')
    if args.branch:
        body, n = _BRANCH_RE.subn(f'**Branch:** `{args.branch}`', body, count=1)
        if n == 0:
            raise _UpdateError('Branch line not found in workpad')

    # Always refresh Last updated.
    body, n = _LAST_UPDATED_RE.subn(f'**Last updated:** {now}', body, count=1)
    if n == 0:
        raise _UpdateError('Last updated line not found in workpad')

    # Section-level mutations.
    preamble, sections = _split_sections(body)

    if args.tick_plan:
        idx = _find_section(sections, 'Plan')
        if idx is None:
            raise _UpdateError("section '## Plan' not found")
        heading, content = sections[idx]
        for text in args.tick_plan:
            content = _tick_checkbox(content, text, 'Plan')
        sections[idx] = (heading, content)

    if args.tick_ac:
        idx = _find_section(sections, 'Acceptance Criteria')
        if idx is None:
            raise _UpdateError("section '## Acceptance Criteria' not found")
        heading, content = sections[idx]
        for text in args.tick_ac:
            content = _tick_checkbox(content, text, 'Acceptance Criteria')
        sections[idx] = (heading, content)

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
        idx = _find_section(sections, 'Decisions / Notes')
        if idx is None:
            raise _UpdateError("section '## Decisions / Notes' not found")
        heading, content = sections[idx]
        for text in args.note:
            content = _append_note(content, text, now)
        sections[idx] = (heading, content)

    if args.reflection:
        idx = _find_section(sections, 'Devflow Reflection')
        if idx is None:
            raise _UpdateError("section '## Devflow Reflection' not found")
        heading, content = sections[idx]
        for bullet in args.reflection:
            content = _append_bullet(content, bullet)
        sections[idx] = (heading, content)

    return _join_sections(preamble, sections)


def main():
    p = argparse.ArgumentParser(prog='workpad.py')
    sub = p.add_subparsers(dest='cmd', required=True)

    s = sub.add_parser('id', help='Print workpad comment ID for an issue (exit 1 if absent).')
    s.add_argument('issue', type=int)
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

    u = sub.add_parser(
        'update',
        help='Apply atomic mutations to the workpad and PATCH. Re-fetches the '
             'body internally; Last updated is refreshed automatically.',
    )
    u.add_argument('issue', type=int)
    u.add_argument('--status', help='Replace the Status line value.')
    u.add_argument('--branch', help='Replace the Branch line value.')
    u.add_argument('--tick-plan', metavar='TEXT', action='append', default=[],
                   help='Tick one Plan checkbox matching TEXT (substring). '
                        'May be passed multiple times to tick several boxes '
                        'in one atomic update.')
    u.add_argument('--tick-ac', metavar='TEXT', action='append', default=[],
                   help='Tick one Acceptance Criteria checkbox matching TEXT '
                        '(substring). May be passed multiple times to tick '
                        'several boxes in one atomic update.')
    u.add_argument('--rewrite-ac', nargs=2, metavar=('OLD', 'NEW'),
                   help='Find one AC matching OLD; replace its text with NEW. '
                        'Preserves the checkbox state. For Phase 2.2.6.')
    u.add_argument('--note', metavar='TEXT', action='append', default=[],
                   help='Append an auto-timestamped Decisions/Notes entry. '
                        'May be passed multiple times to append several '
                        'entries in one atomic update.')
    u.add_argument('--reflection', metavar='TEXT', action='append', default=[],
                   help='Append a bullet to Devflow Reflection (no timestamp). '
                        'May be passed multiple times to append several bullets '
                        'in one atomic update.')
    u.add_argument('--replace-plan-file', metavar='FILE',
                   help='Replace the Plan section content with FILE contents.')
    u.add_argument('--replace-acs-file', metavar='FILE',
                   help='Replace Acceptance Criteria content with FILE contents. '
                        'For Phase 2.2.5 scope adjustment.')
    u.add_argument('--set-reproduction-file', metavar='FILE',
                   help='Set the Reproduction section to FILE contents. Inserts '
                        'the section after Acceptance Criteria if missing.')
    u.set_defaults(func=cmd_update)

    args = p.parse_args()
    args.func(args)


if __name__ == '__main__':
    main()
