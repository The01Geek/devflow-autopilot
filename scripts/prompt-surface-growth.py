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
`agents/`, or `.prflow/prompt-extensions/`, enumerated from the committed tree at BOTH
endpoints (the merge-base commit and `HEAD`) so a file the branch deletes still produces
a row (total 0, negative delta). Reading the two *trees* rather than the index is what
makes both endpoints addressable — a merge-base commit has no index — and it means
staged-but-uncommitted edits are deliberately not counted.
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


def _repo_root():
    """The repository root, memoized — every git call runs from there.

    Anchoring on the root rather than the process working directory is the repo's
    shared `.prflow/`-reader contract, and here it is load-bearing rather than tidy:
    the `ls-tree` pathspecs below are repo-relative, so from a subdirectory they
    would match nothing and the run would print a confident "no covered path
    changed" — a false statement, rendered into a PR description as a generated
    fact. A root that cannot be resolved falls back to the working directory with a
    breadcrumb, so the degradation is stated rather than silent.
    """
    if _repo_root.cached is None:
        rc, out, _ = _git(["rev-parse", "--show-toplevel"], cwd=os.getcwd())
        root = out.strip() if rc == 0 else ""
        if not root:
            print(
                "prompt-surface growth: could not resolve the repository root; "
                "falling back to the working directory, so a run from a "
                "subdirectory may under-report.",
                file=sys.stderr,
            )
            root = os.getcwd()
        _repo_root.cached = root
    return _repo_root.cached


_repo_root.cached = None


def _git(args, cwd=None):
    """Run git and return (rc, stdout, stderr). Never raises, for any reason.

    `check=False` only covers a git that *runs* and fails. A git that cannot be
    executed at all — absent from `PATH`, a `DEVFLOW_GIT` override naming a moved or
    non-executable path — raises `OSError` before any return code exists, which would
    end this helper in a traceback and defeat its always-exit-0 contract. Converting
    that into an rc sentinel keeps every caller's existing rc check correct.
    """
    try:
        proc = subprocess.run(
            [_GIT, *args],
            cwd=cwd if cwd is not None else _repo_root(),
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as exc:
        return 127, "", f"git (`{_GIT}`) could not be executed: {exc}"
    return proc.returncode, proc.stdout, proc.stderr


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
    rc, out, _ = _git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"])
    if rc == 0 and out.strip():
        refs.append(out.strip())
    for ref in _FALLBACK_REFS:
        if ref not in refs:
            refs.append(ref)
    return refs


def resolve_merge_base():
    """(merge_base_sha, ref, tried) — `tried` is the candidate list, resolved or not.

    The candidates come back even on the failure path so the caller can name them in
    its breadcrumb without re-deriving them, which would re-spawn the `symbolic-ref`
    probe purely to reformat data this call already has.
    """
    tried = default_branch_refs()
    for ref in tried:
        rc, out, _ = _git(["merge-base", "HEAD", ref])
        if rc == 0 and out.strip():
            return out.strip(), ref, tried
    return None, None, tried


def surface_at(ref):
    """({path: (blob_sha, size)}, git_stderr) for covered `*.md` files in `ref`'s tree.

    On a git failure the map is `None` and the second element carries git's own
    message, so the caller's breadcrumb can name a cause rather than only a symptom.

    One `ls-tree` call per endpoint carries the sizes with it (`--long`), so no
    per-file `cat-file -s` round trip is needed. `-z` keeps paths raw: without it
    git quotes any path with unusual bytes and the parse would silently mangle it.
    """
    rc, out, err = _git(
        ["ls-tree", "-r", "-z", "--long", ref, "--", *COVERED_PREFIXES]
    )
    if rc != 0:
        return None, err.strip()
    surface = {}
    skipped = 0
    for record in out.split("\0"):
        if not record:
            continue
        meta, _, path = record.partition("\t")
        if not path or not _covered(path):
            continue
        fields = meta.split()
        # `<mode> <type> <sha> <size>` — a `-` size marks a non-blob entry (a
        # submodule gitlink is the realistic one), which `-r` should not emit here.
        # Such a record is counted, not silently dropped: dropping it would subtract
        # a file from a total the reader is told to treat as a generated fact, and a
        # wrong precise number is worse than a missing one.
        if len(fields) != 4 or fields[1] != "blob" or not fields[3].isdigit():
            skipped += 1
            continue
        surface[path] = (fields[2], int(fields[3]))
    if skipped:
        print(
            f"prompt-surface growth: {skipped} entr(ies) under a covered prefix in "
            f"`{ref}` were not readable blobs (a submodule gitlink, or an "
            "unrecognised ls-tree record); the figures below omit them.",
            file=sys.stderr,
        )
    return surface, ""


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


def main():
    rc, head_out, head_err = _git(["rev-parse", "HEAD"])
    if rc != 0 or not head_out.strip():
        print(
            "prompt-surface growth: `HEAD` could not be resolved (not a git "
            "checkout, a repository with no commits, or an unrunnable git)"
            + (f" — git said: {head_err.strip()}" if head_err.strip() else "")
            + " — no table rendered."
        )
        return 0
    head_sha = head_out.strip()

    base_sha, ref, tried = resolve_merge_base()
    if base_sha is None:
        print(
            "prompt-surface growth: the merge-base could not be resolved (tried "
            + ", ".join(f"`{r}`" for r in tried)
            + ") — no table rendered."
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

    # Name the endpoint that failed, and quote git's own message: "could not be read
    # from A or B" leaves a reader with no starting point, and git already wrote the
    # reason. The message is quoted as data — its only caller-influenced content is a
    # ref name.
    base_surface, base_err = surface_at(base_sha)
    head_surface, head_err = surface_at(head_sha)
    for label, sha, surface, err in (
        ("merge-base", base_sha, base_surface, base_err),
        ("HEAD", head_sha, head_surface, head_err),
    ):
        if surface is None:
            print(
                "prompt-surface growth: the covered file set could not be read from "
                f"{label} `{sha}`"
                + (f" — git said: {err}" if err else "")
                + " — no table rendered."
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

    # The aggregate delta is the sum of the rows above it — an unchanged file
    # contributes nothing, so summing the rows and differencing the two endpoint
    # totals give the same number, and taking it from the rows makes the identity
    # structural rather than a coincidence a reader has to re-derive. The aggregate
    # TOTAL is deliberately the whole covered surface at HEAD, not the changed rows'
    # subtotal: the running total of the surface is what keeps a repeated delta
    # meaningful, which is this table's entire reason for existing.
    surface_delta = sum(delta for _, delta, _ in rows)
    surface_total = sum(size for _, size in head_surface.values())
    print(
        "\n".join(
            render(head_sha, base_sha, ref, rows, surface_delta, surface_total)
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
