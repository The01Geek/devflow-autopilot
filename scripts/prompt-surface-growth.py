#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Render the prompt-surface byte delta a PR introduces, plus the running total.

DevFlow's prompt surface — the markdown an agent reads while it works — grows one
review-answering sentence at a time, and no PR ever showed anyone it was happening
(issue #1350). This helper makes that growth a rendered fact in the PR description:
for every covered `*.md` file the branch changed it prints the byte delta between the
merge-base and `HEAD` **and** the file's byte total at `HEAD`, closing with an
aggregate row for the whole covered surface.

Both columns are load-bearing. A delta alone ("+3 KB") normalizes into wallpaper the
third time a reader sees it; the running total beside it is what keeps the number
meaningful as it repeats.

Covered population: tracked files whose path ends in exactly `.md` under `skills/`,
`agents/`, or `.prflow/prompt-extensions/`, enumerated from the git index at BOTH
endpoints so a file the branch deletes still produces a row (total 0, negative delta).
The exact-`.md` suffix test is what excludes `*.md.example` templates and every
non-markdown asset — no separate exclusion mechanism exists or is needed.

This is measurement, never a gate. It defines no threshold, ceiling, or budget, and
compares nothing against a limit: every path — including an unresolvable merge-base
and a checkout with nothing to measure — exits 0 with a stated one-line breadcrumb
instead of a table. A table of zeros is deliberately never printed: a reader would
misread it as "this PR added nothing", which is worse than no table at all.

Invoke it as a direct leading token (`scripts/prompt-surface-growth.py`, or the
vendored `.prflow/vendor/prflow/scripts/…` literal on the cloud tier) — the
`python3 <path>` interpreter-head shape is denied by the cloud permission matcher.

stdlib-only; shells out to `git` alone, honoring a non-probing `DEVFLOW_GIT` override
in the same shape `scripts/checkout-fingerprint.py` uses (`git` is a hard preflight
prerequisite, and there is no `resolve-git.sh`).
"""

import os
import subprocess
import sys

# The three covered prefixes. `skills/**` + `agents/**` mirrors the shipped-prompt
# population `lib/test/lint-shipped-pruned-path.py` already audits as one set; the
# prompt extensions are added because they load into the same context budget and
# were the surface nothing measured at all.
COVERED_PREFIXES = ("skills/", "agents/", ".prflow/prompt-extensions/")

# Merge-base candidates, tried in order (issue #1350 AC1): the remote's own recorded
# default branch first, then the two literal fallbacks.
_FALLBACK_REFS = ("origin/main", "main")

# Honor the DEVFLOW_GIT override without probing, mirroring the DEVFLOW_GH escape
# hatch and scripts/checkout-fingerprint.py's sibling GIT resolution.
_GIT = os.environ.get("DEVFLOW_GIT") or "git"


def _git(args):
    """Run git and return (rc, stdout). Never raises on a failed invocation."""
    proc = subprocess.run(
        [_GIT, *args], capture_output=True, text=True, check=False
    )
    return proc.returncode, proc.stdout


def _covered(path):
    """A tracked path is covered when it ends in exactly `.md` under a covered prefix.

    `endswith('.md')` is what excludes `*.md.example`: that name ends in `.example`.
    """
    return path.endswith(".md") and path.startswith(COVERED_PREFIXES)


def default_branch_refs():
    """Merge-base candidate refs, most specific first.

    The remote's recorded default branch (already spelled `origin/<name>`) leads;
    `origin/main` and `main` follow it as the AC-stated fallbacks. Duplicates are
    dropped so a repo whose default branch *is* `main` does not probe it twice.
    """
    refs = []
    rc, out = _git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"])
    if rc == 0 and out.strip():
        refs.append(out.strip())
    for ref in _FALLBACK_REFS:
        if ref not in refs:
            refs.append(ref)
    return refs


def resolve_merge_base():
    """(merge_base_sha, ref) for the first candidate that resolves, else (None, None)."""
    for ref in default_branch_refs():
        rc, out = _git(["merge-base", "HEAD", ref])
        if rc == 0 and out.strip():
            return out.strip(), ref
    return None, None


def surface_at(ref):
    """{path: (blob_sha, size)} for every covered `*.md` file in `ref`'s tree.

    One `ls-tree` call per endpoint carries the sizes with it (`--long`), so no
    per-file `cat-file -s` round trip is needed. `-z` keeps paths raw: without it
    git quotes any path with unusual bytes and the parse would silently mangle it.
    """
    rc, out = _git(
        ["ls-tree", "-r", "-z", "--long", ref, "--", *COVERED_PREFIXES]
    )
    if rc != 0:
        return None
    surface = {}
    for record in out.split("\0"):
        if not record:
            continue
        meta, _, path = record.partition("\t")
        if not path or not _covered(path):
            continue
        fields = meta.split()
        # `<mode> <type> <sha> <size>` — a `-` size marks a non-blob entry, which
        # `-r` should never emit, so skip rather than guess a number for it.
        if len(fields) != 4 or fields[1] != "blob" or not fields[3].isdigit():
            continue
        surface[path] = (fields[2], int(fields[3]))
    return surface


def changed_rows(base_surface, head_surface):
    """Sorted (path, delta, head_bytes) for every covered path the branch changed.

    Change is decided by blob identity, not size, so an edit that happens to keep a
    file's byte count still earns a row (with a delta of 0) rather than vanishing.
    """
    rows = []
    for path in sorted(set(base_surface) | set(head_surface)):
        base_sha, base_bytes = base_surface.get(path, (None, 0))
        head_sha, head_bytes = head_surface.get(path, (None, 0))
        if base_sha != head_sha:
            rows.append((path, head_bytes - base_bytes, head_bytes))
    return rows


def _signed(n):
    return f"{n:+,}"


def render(head_sha, base_sha, ref, rows, surface_delta, surface_total):
    """The markdown table, as a list of lines."""
    lines = [
        "### Prompt-surface size",
        "",
        f"Derived at `{head_sha}` against merge-base `{base_sha}` (`{ref}`). "
        "Covered: tracked `*.md` under `skills/`, `agents/`, "
        "`.prflow/prompt-extensions/`.",
        "",
        "| Path | Δ bytes | Bytes at HEAD |",
        "| --- | ---: | ---: |",
    ]
    for path, delta, head_bytes in rows:
        lines.append(f"| `{path}` | {_signed(delta)} | {head_bytes:,} |")
    lines.append(
        f"| **Whole covered surface** | **{_signed(surface_delta)}** "
        f"| **{surface_total:,}** |"
    )
    return lines


def main(argv=None):
    rc, head_out = _git(["rev-parse", "HEAD"])
    if rc != 0 or not head_out.strip():
        print(
            "prompt-surface growth: `HEAD` could not be resolved (not a git "
            "checkout, or a repository with no commits) — no table rendered."
        )
        return 0
    head_sha = head_out.strip()

    base_sha, ref = resolve_merge_base()
    if base_sha is None:
        tried = ", ".join(f"`{r}`" for r in default_branch_refs())
        print(
            "prompt-surface growth: the merge-base could not be resolved "
            f"(tried {tried}) — no table rendered."
        )
        return 0

    # AC1a arm (i): a checkout pinned to the default branch has no PR-side commits,
    # so every row would read zero. Say so instead of printing that table.
    if base_sha == head_sha:
        print(
            f"prompt-surface growth: `HEAD` (`{head_sha}`) is the merge-base with "
            f"`{ref}`, so this checkout carries no branch commits to measure — "
            "no table rendered."
        )
        return 0

    base_surface = surface_at(base_sha)
    head_surface = surface_at(head_sha)
    if base_surface is None or head_surface is None:
        print(
            "prompt-surface growth: the covered file set could not be read from "
            f"`{base_sha}` or `{head_sha}` — no table rendered."
        )
        return 0

    rows = changed_rows(base_surface, head_surface)

    # AC1a arm (ii): the branch has commits, but none of them touched the covered
    # surface. This is the common, healthy case and it is reported, not rendered.
    if not rows:
        print(
            "prompt-surface growth: no tracked `*.md` under `skills/`, `agents/`, "
            f"or `.prflow/prompt-extensions/` changed between `{base_sha}` and "
            f"`{head_sha}` — no table rendered."
        )
        return 0

    surface_total = sum(size for _, size in head_surface.values())
    surface_delta = surface_total - sum(size for _, size in base_surface.values())
    print(
        "\n".join(
            render(head_sha, base_sha, ref, rows, surface_delta, surface_total)
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
