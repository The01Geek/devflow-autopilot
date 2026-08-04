#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
#
# Phase 2 mid-run durability checkpoint (issue #1139).
#
# An implement run holds every change it makes in an uncommitted working tree
# until Phase 2 §2.5 — the first commit and push. A run that terminates before
# §2.5 loses all of it. This helper is the executable durability step the Phase 2
# prose invokes at each sub-step boundary (and §2.5 itself) so work already
# produced survives on the run's own remote branch — the branch the §1.4 resume
# path already reads.
#
# Contract (leading-token invocation; the message is $1, the rest are explicit
# pathspecs):
#
#   phase2-durability-checkpoint.sh <commit-message> <path> [<path> ...]
#
# Behavior:
#   - Staging is EXPLICITLY SCOPED. The helper stages ONLY the named paths via
#     `git add -- <paths>`. It NEVER stages with `git add -A`, `git add .`, or
#     intent-to-add, and it REFUSES those tokens as arguments (AC6): an unscoped
#     stage would defeat §2.2's sweep guidance and the fix loop's explicit-path
#     scoping, and would carry unrelated untracked files into pushed history.
#   - Cloud-tier workflow-edit guard (AC4). On a run whose credential cannot push
#     `.github/workflows/` — cloud tier (GITHUB_ACTIONS=true) with DEVFLOW_APP_ID
#     empty/unset, i.e. the GITHUB_TOKEN fallback — the helper DETECTS any named
#     path under the repo's own `.github/workflows/` and does NOT stage it (nor
#     commit it), emitting a breadcrumb per excluded path. It matches the repo's
#     own workflows dir only, never a vendored `.prflow/vendor/.../.github/...`
#     path. Only the detect-and-do-not-stage half lives here; the guard's
#     coupled-file enumeration and 2.2.5 scope-adjustment routing stay Phase 2
#     prose.
#   - No empty commit (AC3/AC8). When nothing is staged after filtering — a
#     boundary reached with no new work, or every named path excluded by the
#     guard — the helper makes NO commit and exits 0.
#   - Landing verification (AC7). After pushing, the helper treats the push as
#     landed ONLY when `git rev-parse HEAD` equals `git rev-parse @{u}`, mirroring
#     skills/implement/phases/phase-4-documentation.md step 3. A rejected
#     non-fast-forward and an `Everything up-to-date` no-op both leave the two
#     unequal and are reported as a failure to land (exit 3), never as success.
#   - History is never rewritten: no amend, no rebase, no force-push (AC5). Proof
#     content stays out of history by ORDERING — the Phase 2 prose invokes this
#     helper only after §2.1.5 proof edits are reverted, and explicit scoping
#     means an unnamed proof file is never staged regardless.
#
# Exit codes:
#   0  committed+pushed+landed, OR a clean no-op (nothing to checkpoint)
#   2  usage error (missing message, or a forbidden stage-all token)
#   3  push did not land (HEAD != @{u})
#   4  a git operation failed (add/commit/not a repo/no upstream)

set -u

_bc() { printf 'phase2-durability-checkpoint: %s\n' "$1" >&2; }

if [ "$#" -lt 1 ] || [ -z "${1:-}" ]; then
  _bc "usage: phase2-durability-checkpoint.sh <commit-message> <path> [<path> ...]"
  exit 2
fi
MESSAGE="$1"
shift

KEEP=()
GUARD_ACTIVE=no
if [ "${GITHUB_ACTIONS:-}" = "true" ] && [ -z "${DEVFLOW_APP_ID:-}" ]; then
  GUARD_ACTIVE=yes
fi

for arg in "$@"; do
  # Explicit paths only (AC6): every argument must name a concrete path. Reject the
  # whole class of non-path / stage-all arguments rather than a denylist of specific
  # tokens — an option-shaped token (git add's `-A`/`-u`/`-N`/`--all`/`--update`/
  # `--intent-to-add` all begin with `-`), the whole-tree `.`, or a git magic pathspec
  # (`:/` repo-root, `:(glob)…`) — any of which would stage more than the caller named
  # and defeat §2.2's sweep-scoping and the fix loop's explicit-path scoping.
  case "$arg" in
    -* | . | :*)
      _bc "refusing non-path staging argument '$arg' — staging must be explicitly scoped to concrete file paths (AC6)."
      exit 2
      ;;
  esac
  # Cloud-tier workflow-edit guard: on a run whose GITHUB_TOKEN fallback cannot push
  # .github/workflows/, do not stage a repo-own workflow path (normalize a leading ./
  # so the match is not defeated by it). A vendored .prflow/vendor/… path is not the
  # repo's own and is not guarded.
  if [ "$GUARD_ACTIVE" = yes ]; then
    case "${arg#./}" in
      .github/workflows/*)
        _bc "workflow-edit guard: NOT staging '$arg' (cloud tier, DEVFLOW_APP_ID empty — the GITHUB_TOKEN fallback cannot push .github/workflows/). Defer it via the Phase 2.2.5 scope-adjustment."
        continue
        ;;
    esac
  fi
  KEEP+=("$arg")
done

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  _bc "not inside a git repository — cannot checkpoint"
  exit 4
fi

if [ "${#KEEP[@]}" -eq 0 ]; then
  _bc "nothing to checkpoint (no stageable paths after the workflow-edit guard); no commit made"
  exit 0
fi

# Explicitly-scoped staging — never `git add -A`/`.`/intent-to-add.
if ! git add -- "${KEEP[@]}"; then
  _bc "git add failed for the named paths; no commit made"
  exit 4
fi

# No empty commit: if nothing is staged, this boundary produced no new durable
# work — exit cleanly without committing (AC3/AC8).
if git diff --cached --quiet; then
  _bc "no staged changes at this boundary; no commit made (no empty commit)"
  exit 0
fi

if ! git commit -q -m "$MESSAGE"; then
  _bc "git commit failed"
  exit 4
fi

# Push, then verify the push actually landed. The push exit and output feed the
# breadcrumb; the HEAD==@{u} comparison is the authoritative landing decision.
PUSH_OUT="$(git push 2>&1)"
PUSH_RC=$?
if [ "$PUSH_RC" -ne 0 ]; then
  _bc "git push returned non-zero: ${PUSH_OUT}"
fi

LOCAL_HEAD="$(git rev-parse HEAD 2>/dev/null)"
UPSTREAM="$(git rev-parse '@{u}' 2>/dev/null)"
if [ -z "$UPSTREAM" ]; then
  _bc "no upstream configured for the current branch; cannot confirm the checkpoint landed — treating as NOT landed. (${PUSH_OUT})"
  exit 3
fi
if [ "$LOCAL_HEAD" != "$UPSTREAM" ]; then
  _bc "checkpoint did NOT land: HEAD ($LOCAL_HEAD) != @{u} ($UPSTREAM). Push output: ${PUSH_OUT}"
  exit 3
fi

_bc "checkpoint landed: $LOCAL_HEAD pushed to @{u}"
exit 0
