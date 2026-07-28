#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Re-check a drafted issue's `Verified:` premises against the current tree.

A `Verified:` bullet is the single most load-bearing line in a DevFlow issue: it
is what licenses an implementing run to skip its own investigation. Those
bullets are true *when the issue is drafted*, and nothing re-checks them when
the issue is later implemented — so a premise that has since become false
converts "go and check" into "this was already checked", and the run builds
confidently on it. Issue #857 is the worked case: three of its premises were
false by the time #864 implemented it, and two acceptance criteria were
literally unimplementable.

This helper is the mechanical half of the fix (issue #868). It has two
consumers, both of which read the same output:

  * `/devflow:create-issue` Step 3.5 (drafting side) — does every load-bearing
    bullet carry a self-contained *re-derivation handle*, so that re-checking is
    mechanical rather than a re-investigation? A `handle=none` bullet is the
    drafting defect.
  * `/devflow:implement` Phase 1.6 Pass 6 (implement side) — does each premise
    still hold against the tree this run will build on?

WHAT IT DOES NOT DO — the security boundary. The issue body is third-party text
that anyone able to comment can influence. This helper therefore performs
**read-only file reads and nothing else**: it never executes a command drawn
from the body, spawns no subprocess, and makes no network call. A bullet whose
handle is a command is *reported* so the caller can re-run it under its own
judgment; the helper declines to decide it. That is why the module imports no
`subprocess`.

Handle classes (the label printed as `handle=`):

  path-quote  a cited repository path AND a quoted sentence — the strongest
              handle, and the only one this helper can fully adjudicate
  path        a cited path with no quoted sentence — existence is checkable
  quote       a quoted sentence naming no path — no domain to search, so the
              helper reports it rather than guessing
  command     a backticked command — reported, never executed
  none        prose asserting a premise with no handle at all; this is the
              shape #857's three false premises took

States (`state=`):

  holds          the premise re-derives against the tree right now
  refuted        the cited path is gone, or the quoted sentence no longer
                 occurs in it — discard the premise and investigate
  unestablished  the helper could not decide (no handle, or a handle it
                 declines to execute) — fall back to ordinary investigation

`unestablished` is deliberately NOT an error: unknown is not zero, and it is
also not a failure. It downgrades the bullet to "go and check", which is the
state the run would have been in with no bullet at all.

Usage:
    check-verified-premises.py --body-file PATH [--repo-root PATH]

Exit codes:
  0  ran and decided; no premise was refuted (this includes a body with no
     bullets at all, and a body whose bullets are merely unestablished)
  2  at least one premise was REFUTED — one refutation dominates the exit code
     even when other bullets hold
  3  the measurement could not be established at all — the body file could not
     be read, it was empty, or the invocation itself was bad. Never conflated
     with a clean pass, and deliberately distinct from 2: a caller who could
     not run the check has not thereby discovered a stale premise.
"""

import argparse
import re
import sys
from pathlib import Path

# Both spellings occur in the wild: `**Verified:**` is the form the create-issue
# template prescribes, and `**Verified** —` is what several filed issues carry
# (issue #868's own body among them). A parser keyed on the colon alone finds
# zero bullets in those and reports a vacuous clean pass, so both are matched.
_MARKER = re.compile(r'\*\*Verified:?\*\*:?')

# A backticked span. Handles are always backticked — that is the drafting
# convention the template mandates — so an unquoted path mentioned in prose is
# deliberately not mined: it would produce false handles from ordinary sentences.
_BACKTICKED = re.compile(r'`([^`\n]+)`')

# A double-quoted sentence, in either the ASCII or the typographic form. Single
# quotes are excluded on purpose: they occur inside shell commands
# (`grep -c '^tombstone:'`) far more often than they delimit a quoted premise.
_QUOTED = re.compile(r'["“]([^"“”]{8,})["”]')

# The leading word of a backticked span that makes it a command rather than a
# path. A command span is never mined for a path, even though it usually
# contains one — `grep -c '^x' lib/test/f.tsv` names a file, but the premise is
# the command's *result*, which this helper will not execute to obtain.
_COMMAND_HEADS = frozenset({
    'grep', 'rg', 'git', 'python3', 'python', 'ls', 'find', 'sed', 'awk',
    'cat', 'head', 'tail', 'wc', 'test', 'bash', 'sh', 'gh', 'jq', 'diff',
})


def normalize(text: str) -> str:
    """Collapse a fragment to the form both sides of a quote match compare in.

    Three normalizations, each closing a way a TRUE premise would otherwise
    read as refuted:

    * whitespace runs collapse to a single space, so a sentence the source file
      wraps across lines still matches the issue's single-line quotation;
    * typographic quotes and dashes fold to ASCII, because GitHub's editor and
      most authoring tools substitute them silently;
    * markdown emphasis (`*` and backticks) is stripped, because a quotation
      lifted out of a prose file keeps the emphasis the source rendered with,
      which the plain source text does not contain.
    """
    folded = (text.replace('“', '"').replace('”', '"')
                  .replace('‘', "'").replace('’', "'")
                  .replace('—', '-').replace('–', '-'))
    stripped = folded.replace('*', '').replace('`', '')
    return ' '.join(stripped.split())


def _looks_like_path(span: str) -> bool:
    """True when a backticked span is plausibly a repository path.

    Requires no whitespace plus either a directory separator or a file
    extension, which excludes the flags, identifiers and literals that make up
    the overwhelming majority of backticked spans in an issue body.

    An **absolute** path is rejected here rather than adjudicated. The span is
    third-party text, and `Path(root) / "/etc/passwd"` discards `root` entirely
    under pathlib's join semantics — so an absolute span would silently point
    the read outside the tree. It is not a repository path, so it is not a
    handle. `_resolves_inside` closes the traversal half of the same hole.
    """
    if not span or any(c.isspace() for c in span):
        return False
    if span.startswith('-') or span.startswith('/') or span.startswith('~'):
        return False
    return '/' in span or re.search(r'\.[A-Za-z0-9]{1,6}$', span) is not None


def _resolves_inside(root: Path, rel: str) -> bool:
    """True when `rel` stays inside `root` once `..` segments are resolved.

    The cited path comes from the issue body, so `../../../etc/passwd` is an
    input this helper must expect rather than trust. Escaping reads are
    refused outright: a premise about a file outside the repository is not a
    premise about the tree this run builds on.
    """
    try:
        candidate = (root / rel).resolve()
    except (OSError, RuntimeError, ValueError):
        return False
    return candidate == root or root in candidate.parents


def _is_command(span: str) -> bool:
    head = span.strip().split()[0] if span.strip() else ''
    return head in _COMMAND_HEADS


def parse_bullets(body: str) -> list:
    """Return one text span per `Verified:` bullet, in document order.

    A bullet's span runs from its marker to whichever comes first: the next
    marker, or a blank line. Terminating at a blank line keeps a bullet from
    swallowing the paragraphs that follow it — several filed issues place the
    marker mid-sentence inside a longer paragraph.
    """
    spans = []
    for match in _MARKER.finditer(body):
        rest = body[match.end():]
        next_marker = _MARKER.search(rest)
        limit = next_marker.start() if next_marker else len(rest)
        blank = rest.find('\n\n')
        if blank != -1:
            limit = min(limit, blank)
        spans.append(rest[:limit])
    return spans


def classify(span: str) -> tuple:
    """Return `(handle, paths, quotes)` for one bullet span."""
    backticked = _BACKTICKED.findall(span)
    commands = [b for b in backticked if _is_command(b)]
    paths = [b for b in backticked if not _is_command(b) and _looks_like_path(b)]
    quotes = [q for q in _QUOTED.findall(span)]
    if paths and quotes:
        handle = 'path-quote'
    elif paths:
        handle = 'path'
    elif quotes:
        handle = 'quote'
    elif commands:
        handle = 'command'
    else:
        handle = 'none'
    return handle, paths, quotes


def recheck(handle: str, paths: list, quotes: list, root: Path) -> tuple:
    """Adjudicate one bullet against the tree. Returns `(state, detail)`."""
    if handle in ('quote', 'command', 'none'):
        # No domain to read, or a handle this helper declines to execute. The
        # premise is not refuted — it is simply undecided, which routes the
        # caller to ordinary investigation.
        return 'unestablished', {
            'quote': 'quoted sentence names no path to search',
            'command': 'command handle reported, never executed',
            'none': 'no re-derivation handle in the bullet',
        }[handle]

    escaping = [p for p in paths if not _resolves_inside(root, p)]
    if escaping:
        # Not refuted — refused. A premise pointing outside the repository is
        # not a premise about the tree this run builds on, and the helper
        # declines to read it rather than answering about a file it should
        # never have opened.
        return 'unestablished', ('cited path resolves outside the repository, '
                                 'refused: ' + ','.join(escaping))

    missing = [p for p in paths if not (root / p).is_file()]
    if missing:
        return 'refuted', 'cited path absent from the tree: ' + ','.join(missing)

    if handle == 'path':
        return 'holds', 'cited path present: ' + ','.join(paths)

    readable = {}
    for rel in paths:
        try:
            readable[rel] = normalize((root / rel).read_text(
                encoding='utf-8', errors='replace'))
        except OSError as exc:
            return 'unestablished', f'cited path {rel} could not be read: {exc}'

    for quote in quotes:
        needle = normalize(quote)
        for rel, haystack in readable.items():
            if needle and needle in haystack:
                return 'holds', f'quote resolves in {rel}'
    return 'refuted', ('quoted sentence no longer occurs in '
                       + ','.join(paths))


class _ArgParser(argparse.ArgumentParser):
    """An argument parser that fails as UNESTABLISHED, not as a refutation.

    `argparse` exits **2** on a bad invocation, and 2 is this helper's
    "a premise was REFUTED" code — so a caller that mistypes a flag would be
    told the issue contains a stale premise it never looked at. A bad
    invocation is a measurement that never happened, which is exactly what
    exit 3 means here.
    """

    def error(self, message):
        self.exit(3, f'VERIFIED_PREMISES unavailable reason=bad-invocation '
                     f'detail={message}\n')


def main(argv=None) -> int:
    parser = _ArgParser(
        description='Re-check an issue body\'s Verified: premises against the tree.')
    parser.add_argument('--body-file', required=True,
                        help='path to the issue body (the Phase 1.1 cache)')
    parser.add_argument('--repo-root', default=None,
                        help='tree to adjudicate against (default: the enclosing '
                             'git working tree, else the current directory)')
    args = parser.parse_args(argv)

    try:
        body = Path(args.body_file).read_text(encoding='utf-8')
    except (OSError, UnicodeDecodeError) as exc:
        # Unestablished, never a clean pass: a body that could not be read is
        # not a body with no stale premises in it.
        print(f'VERIFIED_PREMISES unavailable reason=body-unreadable detail={exc}')
        return 3

    if not body.strip():
        # An empty body and a body carrying no bullets are NOT the same
        # measurement, and collapsing them is the fail-open this guard exists
        # to stop: `total=0` would read as "this issue asserts no premises"
        # when in fact nothing was ever read.
        print('VERIFIED_PREMISES unavailable reason=body-empty '
              'detail=the body file is empty or whitespace-only')
        return 3

    root = Path(args.repo_root).resolve() if args.repo_root else _default_root()

    tally = {'holds': 0, 'refuted': 0, 'unestablished': 0}
    for index, span in enumerate(parse_bullets(body), start=1):
        handle, paths, quotes = classify(span)
        state, detail = recheck(handle, paths, quotes, root)
        tally[state] += 1
        print(f'bullet={index} handle={handle} state={state} detail={detail}')

    print('VERIFIED_PREMISES total={} holds={} refuted={} unestablished={}'.format(
        sum(tally.values()), tally['holds'], tally['refuted'],
        tally['unestablished']))
    return 2 if tally['refuted'] else 0


def _default_root() -> Path:
    """Nearest enclosing git working tree, falling back to the current directory.

    Resolved by walking for a `.git` entry rather than by shelling out to `git
    rev-parse`, so this module keeps its no-subprocess property.
    """
    here = Path.cwd().resolve()
    for candidate in (here, *here.parents):
        if (candidate / '.git').exists():
            return candidate
    return here


if __name__ == '__main__':
    sys.exit(main())
