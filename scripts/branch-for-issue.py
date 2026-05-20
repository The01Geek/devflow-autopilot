#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Compute the canonical feature-branch name for a GitHub issue.

The /implement skill's Phase 1.2 needs a deterministic branch name from an
issue number + title. Doing it inline in skill prose led to drift between
runs (different unicode handling, different truncation, different special-
char replacement). This script gives one answer.

Format: `issue-{NUMBER}-{slug}` (or `issue-{NUMBER}-{slug}-{YYYYMMDD}` when
the unsuffixed name already exists at `origin/<branch>` or locally).

Slug rules:
  - lowercase
  - ASCII-only (non-ASCII characters dropped)
  - every run of non-[a-z0-9] becomes a single hyphen
  - leading/trailing hyphens stripped
  - truncated to 50 characters at a hyphen boundary when possible
  - if the slug ends up empty, falls back to "issue-<number>"

Usage:
    branch-for-issue.py NUMBER TITLE
    branch-for-issue.py NUMBER --title-file PATH

Exits 0 with the branch name on stdout.
Exits 2 on bad arguments.
"""

import argparse
import re
import subprocess
import unicodedata
from datetime import date


_NON_SLUG_RE = re.compile(r'[^a-z0-9]+')
_MAX_SLUG_LEN = 50
# Minimum length the slug head must keep when we cut at a hyphen boundary
# during truncation. Below this, the hyphen-cut would leave a stub too short
# to be readable, so we accept a mid-word cut instead. Tune together with
# _MAX_SLUG_LEN.
_MIN_SLUG_HEAD_LEN = 20


def _slugify(title: str) -> str:
    normalized = unicodedata.normalize('NFKD', title).encode('ascii', 'ignore').decode('ascii')
    slug = _NON_SLUG_RE.sub('-', normalized.lower()).strip('-')
    if len(slug) <= _MAX_SLUG_LEN:
        return slug
    cut = slug[:_MAX_SLUG_LEN]
    last_hyphen = cut.rfind('-')
    if last_hyphen > _MIN_SLUG_HEAD_LEN:
        cut = cut[:last_hyphen]
    return cut.strip('-')


def _branch_exists(name: str) -> bool:
    """True if the branch exists locally or on origin."""
    for ref in (f'refs/heads/{name}', f'refs/remotes/origin/{name}'):
        r = subprocess.run(
            ['git', 'show-ref', '--verify', '--quiet', ref],
            check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        if r.returncode == 0:
            return True
    return False


def main():
    # argparse mutex groups misbehave with `nargs='?'` positionals (passing
    # `999 --title-file PATH` raises "argument title: not allowed with
    # argument --title-file" even when no title was provided), so we declare
    # both flags as optional and validate the xor manually.
    p = argparse.ArgumentParser(prog='branch-for-issue.py')
    p.add_argument('number', type=int, help='GitHub issue number')
    p.add_argument('title', nargs='?', help='Issue title (positional)')
    p.add_argument('--title-file', help='Read title from this file')
    args = p.parse_args()

    if bool(args.title) == bool(args.title_file):
        p.error('provide exactly one of TITLE (positional) or --title-file')

    if args.title_file:
        with open(args.title_file) as f:
            title = f.read().strip()
    else:
        title = args.title

    slug = _slugify(title)
    if not slug:
        # Empty slug → just `issue-<number>`. Don't run it through the normal
        # `issue-<number>-<slug>` assembly, which would double the prefix to
        # `issue-N-issue-N`.
        base = f'issue-{args.number}'
    else:
        base = f'issue-{args.number}-{slug}'
    if _branch_exists(base):
        base = f'{base}-{date.today().strftime("%Y%m%d")}'

    print(base)


if __name__ == '__main__':
    main()
