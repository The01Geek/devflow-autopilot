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

# A file extension, used only as the WEAK arm of path detection — see
# `_path_strength`.
_EXTENSION = re.compile(r'\.[A-Za-z0-9]{1,6}$')

# Why the undecidable handles cannot be adjudicated, keyed by handle. Module
# level so the vocabulary sits beside the patterns that produce it, and so the
# set of undecidable handles has exactly one definition.
_UNDECIDABLE_REASONS = {
    'quote': 'quoted sentence names no path to search',
    'command': 'command handle reported, never executed',
    'none': 'no re-derivation handle in the bullet',
}


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


def _path_strength(span: str) -> str:
    """Classify a backticked span as a `strong` path, a `weak` one, or `no`.

    The distinction is what stops a *guess* from becoming a *refutation*. A
    span carrying a directory separator is a **strong** path claim: little else
    in an issue body looks like `lib/test/run.sh`. A span that merely ends in a
    dotted tail is **weak**, because so do the identifiers this repo's own
    issues are full of — `devflow_review.stale_prose.enabled`, `tally.refuted`,
    `_MARKER.finditer`. Reporting "no such file" about one of those as
    `refuted` would tell the run to discard a true premise and record false
    issue-accuracy feedback against the issue, so a missing *weak* path
    resolves to `unestablished` instead (see `recheck`).

    An **absolute** path is rejected outright rather than adjudicated. The span
    is third-party text, and `Path(root) / "/etc/passwd"` discards `root`
    entirely under pathlib's join semantics, so an absolute span would silently
    point the read outside the tree. It is not a repository path, so it is not
    a handle. `_resolves_inside` closes the traversal half of the same hole.
    """
    if not span or any(c.isspace() for c in span):
        return 'no'
    if span.startswith('-') or span.startswith('/') or span.startswith('~'):
        return 'no'
    if '/' in span:
        return 'strong'
    return 'weak' if _EXTENSION.search(span) else 'no'


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
    """True when a backticked span is a command rather than a path.

    Structural, not a name allowlist. An earlier draft matched the span's first
    word against a hardcoded set of tool names, which rotted in two directions
    at once: a consumer repo's own toolchain (`npm test`, `cargo test`,
    `pytest -k x`) fell outside the set and its best-grounded bullets were
    reported as carrying no handle at all, while a bare tool name sitting in
    ordinary prose was reported as a command handle — laundering exactly the
    handle-less shape #857's three false premises took. Multi-token *is* the
    discriminator: a repository path never contains whitespace, and a command
    almost always does.
    """
    return bool(span.strip()) and any(c.isspace() for c in span.strip())


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
    """Return `(handle, paths, quotes)` for one bullet span.

    `paths` carries each cited path with its strength, as `(strength, span)`
    pairs, so `recheck` can tell a confident path claim from a guess.
    """
    paths, commands = [], []
    for backticked in _BACKTICKED.findall(span):
        if _is_command(backticked):
            # A command span is never mined for a path even though it usually
            # contains one — `grep -c '^x' lib/test/f.tsv` names a file, but
            # the premise is the command's *result*, which this helper will
            # not execute to obtain.
            commands.append(backticked)
            continue
        strength = _path_strength(backticked)
        if strength != 'no':
            paths.append((strength, backticked))
    quotes = _QUOTED.findall(span)
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
    if handle in _UNDECIDABLE_REASONS:
        # No domain to read, or a handle this helper declines to execute. The
        # premise is not refuted — it is simply undecided, which routes the
        # caller to ordinary investigation.
        return 'unestablished', _UNDECIDABLE_REASONS[handle]

    escaping = [p for _, p in paths if not _resolves_inside(root, p)]
    if escaping:
        # Not refuted — refused. A premise pointing outside the repository is
        # not a premise about the tree this run builds on, and the helper
        # declines to read it rather than answering about a file it should
        # never have opened.
        return 'unestablished', ('cited path resolves outside the repository, '
                                 'refused: ' + ','.join(escaping))

    missing = [(s, p) for s, p in paths if not (root / p).is_file()]
    if missing:
        # Only a STRONG path claim earns a refutation. A weak one — a dotted
        # identifier that merely looks filename-shaped — is a guess, and
        # refuting a premise on a guess is worse than declining to decide it:
        # the run would discard a true premise and record false issue-accuracy
        # feedback against the issue.
        strong = [p for s, p in missing if s == 'strong']
        if strong:
            return 'refuted', 'cited path absent from the tree: ' + ','.join(strong)
        return 'unestablished', (
            'cited span looks filename-shaped but names no directory, so its '
            'absence is not evidence of a stale premise: '
            + ','.join(p for _, p in missing))

    if handle == 'path':
        return 'holds', 'cited path present: ' + ','.join(p for _, p in paths)

    readable = {}
    for _, rel in paths:
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

    # Same asymmetry as the missing-path arm: a quotation that fails to resolve
    # in a STRONG path is a refutation, but in a weak one it is only evidence
    # that the guess was wrong about which file was meant.
    if any(s == 'strong' for s, _ in paths):
        return 'refuted', ('quoted sentence no longer occurs in '
                           + ','.join(p for _, p in paths))
    return 'unestablished', (
        'quoted sentence does not occur in the filename-shaped span cited, '
        'which names no directory: ' + ','.join(p for _, p in paths))


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
