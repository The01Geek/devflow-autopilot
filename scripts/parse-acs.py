#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Parse Acceptance Criteria from a GitHub issue body, classify post-merge.

Implements the parsing + post-merge tagging rules from /implement's Phase 1.4
once, deterministically, in code — replacing ~25 lines of skill prose that
described the rules in English. The orchestrator still owns per-criterion
override authority; this script just produces the heuristic starting point.

Parsing rules:
  - Match a heading whose text is "Acceptance Criteria" (case-insensitive,
    so `## Acceptance criteria` or `## ACCEPTANCE CRITERIA` all match). A
    trailing colon or other extra characters still do not match — only the
    casing is forgiven. The `## Test Plan` section, when present, is appended
    to the same output (separated by a blank line) per the skill's mirroring
    rule.
  - Heading level may be `##` or `###`.
  - Inside the section, accept `- [ ]`, `- [x]`, `* [ ]`, `* [x]`.
  - Stop at the next heading whose level is equal to or higher than the
    section's heading (i.e. fewer `#` characters, or the same count).

Post-merge classification:
  - Append ` (post-merge)` to any criterion whose text contains a trigger
    phrase from the bundled list (case-insensitive, word-boundary match).
  - Trigger phrases are easy to edit at the top of this file — they're
    intentionally not configurable via a flag so the skill text and the
    helper stay in sync without an extra source of truth.

Usage:
    parse-acs.py --issue ISSUE_NUMBER [--format md|json]
    parse-acs.py --body-file PATH    [--format md|json]

`md` (default) emits checkbox lines ready to splice into the workpad's
`## Acceptance Criteria` section. `json` emits a list of {text, post_merge,
ticked} objects for downstream programmatic use.

When no `## Acceptance Criteria` section exists, prints the literal sentinel
`_(none provided in issue body)_` (md) or an empty array (json). Never
invents criteria.

Exit codes:
  0  parsed and printed
  1  body fetch failed
  2  bad arguments
"""

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

# The gh binary to shell out to. `DEVFLOW_GH` (the documented override the shell
# helpers resolve via lib/resolve-gh.sh) wins when set and non-empty; else `gh`.
GH = os.environ.get("DEVFLOW_GH") or "gh"


# Trigger phrases that mark a criterion as post-merge. Matched case-
# insensitively as substrings against the criterion text. Keep this short and
# obvious — the skill text references the same list and the orchestrator may
# override per-criterion when a phrase appears incidentally.
POST_MERGE_TRIGGERS = (
    'after merge', 'post-merge', 'post-deploy', 'after deploy',
    'open a pr', 'mark it ready', 'merge button', 'mark the pr',
    'in production', 'on staging', 'live environment',
    # Short bare words like `click` / `manually` / `monitor` produced
    # false-positive tags (`one-click checkout`, `not manually specified`,
    # `Sentry error monitoring`) that silently exempted real ACs from the
    # implement skill's post-merge-exempt gate. They've been replaced with unambiguous multi-word
    # phrases. Combined with the `\b...\b` matcher below, this also stops
    # `monitor` from matching `monitoring`.
    'click to', 'click the button', 'verify manually', 'manual verification',
    'monitor the deploy', 'monitor logs', 'monitor the logs',
    'verify in the ui', 'via the github ui',
    'inspect logs', 'watch the deploy',
    'compare runs', 'the next run', 'next deploy',
    # Workflow / bot-trigger install ACs commonly verify by interacting with a
    # PR that doesn't exist until after merge (e.g. "comment /screenshot on a
    # PR", "verify the workflow runs on a live PR", "check the artifact link").
    # These triggers are intentionally broad: bare 'on a pr' will also tag
    # legitimate pre-merge ACs that incidentally mention a PR (e.g. "Run tests
    # on a PR before merging"), and 'workflow run(s)' will tag general CI-config
    # ACs. We prefer over-tag to under-tag because the implement-skill
    # orchestrator can demote a criterion per-run; an under-tag silently exempts
    # a real post-merge AC from the verification gate, which is the failure
    # mode the short-bare-words removal above was designed to prevent.
    'on a pr', 'on a live pr', 'on a real pr',
    'comment on the pr', 'comment on a pr',
    'workflow run', 'workflow runs', 'artifact link',
)


_CHECKBOX_RE = re.compile(r'^\s*[-*]\s+\[([ xX])\]\s+(.*)$')
_HEADING_RE = re.compile(r'^(#{1,6})\s+(.*?)\s*$')

# Word-boundary regex per trigger phrase. Built once at import time. The
# boundary check stops short bare words like `click` / `monitor` / `manually`
# from incidentally matching inside `one-click checkout`, `Sentry monitoring`,
# or `not manually specified` — a mis-tag would silently exempt a real AC
# from the implement skill's post-merge-exempt gate ("Post-merge criteria are exempt").
_POST_MERGE_RES = tuple(
    re.compile(r'\b' + re.escape(phrase) + r'\b', re.IGNORECASE)
    for phrase in POST_MERGE_TRIGGERS
)


def _force_utf8_streams():
    """Force stdout/stderr to UTF-8, idempotently and defensively. Called from
    the CLI entry path only (not at import) so importing this module for unit
    tests never mutates the importer's global streams. The em-dash this script
    emits in its near-miss error message would otherwise raise
    `UnicodeEncodeError` under a non-UTF-8 ambient codec (Windows' cp1252).
    Reconfigure overrides even a hostile `PYTHONIOENCODING`; the guard tolerates
    a non-`TextIOWrapper` stream (e.g. a test's `io.StringIO`)."""
    for _stream in (sys.stdout, sys.stderr):
        try:
            _stream.reconfigure(encoding="utf-8")
        except (AttributeError, ValueError):
            pass


def _fetch_body(issue: int) -> str:
    """Fetch an issue's body via gh."""
    try:
        # `encoding="utf-8"` so DECODING the issue body (routinely non-ASCII)
        # does not raise under a non-UTF-8 ambient codec. Implies text mode.
        r = subprocess.run(
            [GH, 'issue', 'view', str(issue), '--json', 'body', '-q', '.body'],
            check=True, capture_output=True, encoding="utf-8",
        )
    except (subprocess.CalledProcessError, OSError) as e:
        # OSError covers a gh that cannot execute at all (ENOEXEC shim, absent
        # binary — the host class DEVFLOW_GH exists for); it carries no
        # .stderr, so fall back to str(e).
        msg = e.stderr.strip() if isinstance(e, subprocess.CalledProcessError) else str(e)
        sys.stderr.write(f"parse-acs.py: gh issue view failed: {msg}\n")
        sys.exit(1)
    return r.stdout


def _extract_section(body: str, name: str) -> list[str]:
    """Return the list of lines inside the named section, or [] if not found.

    Stops at the next heading whose level is equal to or higher than the
    section's heading.
    """
    lines = body.splitlines()
    out: list[str] = []
    section_level = None
    for line in lines:
        m = _HEADING_RE.match(line)
        if m:
            level, heading = len(m.group(1)), m.group(2).strip()
            if section_level is None:
                if heading.lower() == name.lower() and level in (2, 3):
                    section_level = level
                continue
            if level <= section_level:
                break
        elif section_level is not None:
            out.append(line)
    return out


def _parse_checkboxes(section_lines: list[str]) -> list[dict]:
    items = []
    for line in section_lines:
        m = _CHECKBOX_RE.match(line)
        if not m:
            continue
        ticked = m.group(1).lower() == 'x'
        text = m.group(2).strip()
        items.append({
            'text': text,
            'ticked': ticked,
            'post_merge': _is_post_merge(text),
        })
    return items


def _is_post_merge(text: str) -> bool:
    return any(r.search(text) for r in _POST_MERGE_RES)


def _warn_near_miss(parsed: list, body: str, canonical: str, needle: str) -> None:
    if parsed:
        return
    if re.search(r'(?im)^#{2,3}\s+.*' + re.escape(needle), body):
        sys.stderr.write(
            f"parse-acs.py: no {canonical} items parsed, but the body contains "
            f"a heading that mentions '{needle}' — check that it is exactly "
            f"'## {canonical}' (any casing is fine, but no trailing colon or "
            f"extra words).\n"
        )


def _render_md(criteria: list[dict], test_plan: list[dict]) -> str:
    if not criteria and not test_plan:
        return '_(none provided in issue body)_'
    lines: list[str] = []
    for item in criteria:
        lines.append(_render_md_line(item))
    if test_plan:
        lines.append('')
        for item in test_plan:
            lines.append(_render_md_line(item))
    return '\n'.join(lines)


def _render_md_line(item: dict) -> str:
    box = '[x]' if item['ticked'] else '[ ]'
    text = item['text']
    if item['post_merge'] and '(post-merge)' not in text:
        text = f'{text} (post-merge)'
    return f'- {box} {text}'


def main():
    _force_utf8_streams()
    p = argparse.ArgumentParser(prog='parse-acs.py')
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument('--issue', type=int, help='Fetch the issue body via gh.')
    src.add_argument('--body-file', help='Read body from a local file.')
    p.add_argument('--format', choices=('md', 'json'), default='md')
    args = p.parse_args()

    if args.issue is not None:
        body = _fetch_body(args.issue)
    else:
        body = Path(args.body_file).read_text()

    ac_lines = _extract_section(body, 'Acceptance Criteria')
    criteria = _parse_checkboxes(ac_lines)
    test_plan = _parse_checkboxes(_extract_section(body, 'Test Plan'))

    # Heading match in _extract_section is case-insensitive but otherwise
    # exact. `## acceptance criteria` (any casing) now matches, but
    # `## Acceptance Criteria:` (trailing colon) or `## ACs` still produce zero
    # items — and the implement skill's post-merge-exempt gate would trivially
    # pass. Surface the near-miss so the orchestrator can correct it. Same risk
    # applies to `## Test Plans` (plural) / `## Tests`.
    _warn_near_miss(criteria, body, 'Acceptance Criteria', 'acceptance')
    _warn_near_miss(test_plan, body, 'Test Plan', 'test plan')

    if args.format == 'json':
        print(json.dumps({'acceptance_criteria': criteria, 'test_plan': test_plan},
                         indent=2))
    else:
        print(_render_md(criteria, test_plan))


if __name__ == '__main__':
    main()
