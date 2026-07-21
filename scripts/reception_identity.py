#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Content-based candidate-identity derivation for receiving-review sessions (issue #668).

An importable, python3 standard-library-only routine. It derives ONE value — the
git tree object ID of the working-tree *content*: tracked files at their
working-tree content plus untracked non-ignored files, with gitignored content
excluded, and with HEAD excluded from the input. The current index is an INPUT,
not an exclusion: for an ordinary path `git add -A` resolves the entry to
worktree content, but for an entry git deliberately does not re-stat — a
skip-worktree (cone-mode sparse) entry, which has no on-disk content to read, or
an `assume-unchanged` (CE_VALID) entry, which does — the INDEX content decides
the value, and an `assume-unchanged` path's worktree edit therefore does not
change the derived identity. Both are the documented consequence of seeding from
the real index (see the seeding paragraph below), which is load-bearing for
sparse checkouts. This is the single machine-checkable session identity the
Reception Preflight records and later consumers re-derive.

Derivation is index-cached plumbing, not a hand-rolled tree walk: a temporary
index is SEEDED from the repository's current index, `git add -A` stages every
working-tree content change (edits, deletions, renames, and untracked non-ignored
files) into that temporary index, and `git write-tree` prints the resulting tree
object ID. The repository's own index is never modified (the derivation writes to
a private `GIT_INDEX_FILE`; it does add unreferenced blob/tree objects to the
object database, which are GC-collectable and touch no ref), and no repository
history is read, so the cost scales with the number of changed files rather than
repository size.

Seeding the temporary index from the current index is load-bearing, not an
optimization: a cone-mode sparse checkout leaves skip-worktree entries off disk,
and only the seeded entries preserve them — a fresh empty index would drop those
paths and yield a tree that omits content the eventual commit still records.

Invariants (mirrors scripts/workpad.py's Windows-safe native-git pattern,
issues #275/#295):
  * git is invoked as a native subprocess with an argv list (never a shell
    string), so filenames containing whitespace or newlines never break parsing —
    git stages the content itself rather than this module enumerating paths.
  * No PyYAML import, no `gh` call, no network call, and no decisive value is
    derived through a non-preflight PATH tool (`tr`/`sed`/`wc`/`cut`/`head`).
  * Every failure mode raises IdentityError with a named reason and yields no
    identity — a caller that prints the identity only on success can never print
    a value read as a derived identity when the derivation failed.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile

# git is a hard preflight prerequisite; invoked directly like scripts/workpad.py.
# A DEVFLOW_GIT override mirrors the DEVFLOW_GH escape hatch without probing.
GIT = os.environ.get("DEVFLOW_GIT") or "git"


class IdentityError(Exception):
    """A candidate-identity derivation that could not complete.

    `.reason` is a named machine-readable breadcrumb (never a bare traceback):
    `git_not_found`, `git_exec_error:<class>`, `git_failed:<subcommand>:<code>`,
    `git_output_not_utf8:<subcommand>`, `temp_index_error:<class>`, or
    `empty_tree_output`. The caller prints it to stderr and prints no identity.
    """

    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


def _run_git(args: list[str], cwd: str, extra_env: "dict | None" = None) -> bytes:
    """Run `git <args>` in `cwd`, returning stdout bytes, raising IdentityError.

    Native subprocess with an argv list and no shell. A missing git binary, an
    exec error, and a non-zero exit each become a distinct named IdentityError.
    """
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)
    try:
        proc = subprocess.run(  # noqa: S603 - argv list, no shell
            [GIT, *args],
            cwd=cwd,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except FileNotFoundError as exc:
        raise IdentityError("git_not_found") from exc
    except OSError as exc:
        raise IdentityError(f"git_exec_error:{exc.__class__.__name__}") from exc
    if proc.returncode != 0:
        # The subcommand plus the exit code names the failure; the raw stderr is
        # not folded into the reason (it is attacker-influenceable and unbounded).
        raise IdentityError(f"git_failed:{args[0]}:{proc.returncode}")
    return proc.stdout


def _run_git_text(args: list[str], cwd: str, extra_env: "dict | None" = None) -> str:
    """`_run_git` decoded to stripped UTF-8 text, raising IdentityError on bad bytes.

    Decoding lives here rather than at each call site so the module's
    every-failure-mode-is-a-named-IdentityError contract holds by construction.
    A git-dir path (or any git stdout) that is not valid UTF-8 is reachable on
    Linux, where paths are arbitrary bytes; decoding at the call site would raise
    a bare UnicodeDecodeError that the CLI's `except IdentityError` never catches,
    escaping as a raw traceback instead of the `{"ok": false, "reason": ...}`
    record the caller contract promises.
    """
    raw = _run_git(args, cwd, extra_env)
    try:
        return raw.decode("utf-8").strip()
    except UnicodeDecodeError as exc:
        raise IdentityError(f"git_output_not_utf8:{args[0]}") from exc


def derive_candidate_identity(repo_root: "str | None" = None) -> str:
    """Return the candidate identity — the git tree object ID of working-tree content.

    `repo_root` defaults to the current working directory; git resolves the actual
    repository (including a linked worktree) from there. Raises IdentityError on
    any failure mode, yielding no value.
    """
    cwd = repo_root or os.getcwd()
    # Resolve the real git dir (worktree-aware) so the current index can be seeded.
    git_dir = _run_git_text(["rev-parse", "--absolute-git-dir"], cwd)
    index_path = os.path.join(git_dir, "index")

    try:
        tmp_fd, tmp_index = tempfile.mkstemp(prefix=".reception-index-")
        os.close(tmp_fd)
    except OSError as exc:
        # The temporary index path is unwritable (e.g. a read-only TMPDIR).
        raise IdentityError(f"temp_index_error:{exc.__class__.__name__}") from exc

    try:
        if os.path.exists(index_path):
            # Seed from the current index so skip-worktree (sparse) entries survive.
            shutil.copyfile(index_path, tmp_index)
        else:
            # Absent index: start from an empty index (git creates the file).
            os.remove(tmp_index)
        env = {"GIT_INDEX_FILE": tmp_index}
        # -A stages every working-tree content change: edits, deletions, renames,
        # and untracked non-ignored files. Gitignored content is excluded by git.
        _run_git(["add", "-A"], cwd, env)
        tree = _run_git_text(["write-tree"], cwd, env)
    except OSError as exc:
        raise IdentityError(f"temp_index_error:{exc.__class__.__name__}") from exc
    finally:
        try:
            if os.path.exists(tmp_index):
                os.remove(tmp_index)
        except OSError:
            pass

    if not tree:
        raise IdentityError("empty_tree_output")
    return tree
