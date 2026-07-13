#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# update-branch-checkpoint.sh — reconcile the current feature branch with the
# configured base branch at a checkpoint (issue #448).
#
# The whole mechanical sequence lives here — off-switch read, pre-state guards,
# fetch, behind-by derivation, base merge, push, and the push-race recovery arm —
# so a cloud-tier call site invokes ONE granted leading-token command instead of a
# chain of individually-granted git verbs (the cloud allowlists grant no inline
# `git rev-list`, so the behind-by derivation and the base merge must both run inside
# this helper's own subprocess rather than at a call site; issue #363). Every recovery
# arm stays deterministic and suite-driveable instead of agent-improvised. (The cloud
# allowlists DO grant `Bash(git merge:*)` — but only for the agent-level `git merge
# --abort` the conflict-resolution contract prescribes at a call site, not for the
# checkpoint's own base merge, which runs here inside the helper.)
#
# Operates on the CURRENT checkout (HEAD's branch). Reads base_branch and the
# off-switch through config-get.sh; calls neither `gh` nor `jq`, so it sources
# neither lib/resolve-gh.sh nor lib/resolve-jq.sh.
#
# Guard-class 2 (issue #448 AC + CLAUDE.md): every value that decides a branch or
# an emitted token is derived from git exit codes/output, config-get.sh (python3),
# and bash builtins — no tr/sed/wc/cut/head in any selection path.
#
# stdout carries EXACTLY the one outcome token. git's own chatter (`git merge`
# prints "Merge made by …" / conflict summaries to stdout, `git reset` prints
# "HEAD is now at …") would otherwise pollute the token stream, so fd 1 is
# rebound to stderr for the whole script and the token is emitted on the saved
# real-stdout fd 3 via emit().
#
# Outcome contract — exactly one token on stdout, matching exit code:
#   UP_TO_DATE         exit 0  behind-by 0; tree untouched
#   UPDATED <behind>   exit 0  merged and pushed (incl. via push-race recovery)
#   DISABLED           exit 0  off-switch; tree untouched
#   CONFLICT           exit 2  base merge left in progress (MERGE_HEAD present);
#                              conflicted paths + resolution contract on stderr
#   UNVERIFIED         exit 3  fetch or behind-by derivation failed, or dirty tree;
#                              nothing merged — never a blind merge
#   PUSH_REJECTED      exit 4  push refused twice (or a conflicted integrate); local
#                              branch restored to its pre-checkpoint SHA; breadcrumb
#   MERGE_IN_PROGRESS  exit 5  MERGE_HEAD existed at invocation; nothing touched

set -u

# Rebind stdout→stderr; keep the real stdout on fd 3 for token emission only.
exec 3>&1 1>&2
emit() { printf '%s\n' "$1" >&3; }

# Resolve the sibling config-get.sh inline via bash parameter expansion (never a
# non-preflight PATH tool). When BASH_SOURCE carries no slash (bare-name exec),
# `%/*` leaves it unchanged, so fall back to the current directory.
_self="${BASH_SOURCE[0]}"
case "$_self" in
  */*) _self_dir="${_self%/*}" ;;
  *)   _self_dir="." ;;
esac
CONFIG_GET="$_self_dir/config-get.sh"

# (1) Off-switch. Only an explicit JSON `false` disables (issue #312 valid-falsy):
# a missing file/key, empty string, or wrong-typed value leaves it enabled.
enabled="$("$CONFIG_GET" .devflow_implement.update_branch_checkpoints "" 2>/dev/null || true)"
if [ "$enabled" = "false" ]; then
  emit "DISABLED"
  exit 0
fi

# (2) Pre-state guards — run BEFORE any fetch or merge.
# MERGE_HEAD at invocation → do not absorb an abandoned resolution into an ordinary
# commit; hard-stop so the caller resolves it deliberately.
if git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
  echo "update-branch-checkpoint: a merge is already in progress (MERGE_HEAD present) — resolve or abort it deliberately (git merge --abort), never absorb it into an ordinary commit" >&2
  emit "MERGE_IN_PROGRESS"
  exit 5
fi
# Uncommitted tracked changes → never layer a base merge over dirty work.
if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
  echo "update-branch-checkpoint: working tree has uncommitted tracked changes — refusing to fetch or merge over a dirty tree; commit or stash first" >&2
  emit "UNVERIFIED"
  exit 3
fi

# (3) Derive the base branch (fail-closed empty-read fallback to main — the Phase 3.1
# pattern).
BASE="$("$CONFIG_GET" .base_branch main 2>/dev/null || true)"
[ -n "$BASE" ] || BASE=main

# Record the pre-checkpoint SHA and the current branch for the recovery/restore arms.
PRE_SHA="$(git rev-parse HEAD 2>/dev/null || true)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
if [ -z "$PRE_SHA" ] || [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
  echo "update-branch-checkpoint: could not resolve HEAD SHA or a branch name (detached HEAD or corrupt repo) — nothing merged" >&2
  emit "UNVERIFIED"
  exit 3
fi

# (4) Fetch the base.
if ! git fetch origin "$BASE"; then
  echo "update-branch-checkpoint: could not fetch origin/$BASE (network/auth or wrong base_branch) — nothing merged" >&2
  emit "UNVERIFIED"
  exit 3
fi

# (5) Behind-by via git rev-list; validate as a non-negative integer with a bash
# builtin case (guard-class 2 — never wc/cut).
BEHIND="$(git rev-list --count "HEAD..origin/$BASE" 2>/dev/null || true)"
case "$BEHIND" in
  '' | *[!0-9]*)
    echo "update-branch-checkpoint: could not derive behind-by count from HEAD..origin/$BASE — nothing merged" >&2
    emit "UNVERIFIED"
    exit 3
    ;;
esac

# (6) Already current.
if [ "$BEHIND" -eq 0 ]; then
  emit "UP_TO_DATE"
  exit 0
fi

# --- restore the branch to its pre-checkpoint SHA and terminate PUSH_REJECTED with the
# given breadcrumb (shared by every push-race reject arm). ---
_reject_restore() {  # message
  # Surface the restore's own failure rather than asserting a restore that did not
  # happen: a swallowed `git reset --hard` failure (a locked index, an invalid PRE_SHA)
  # would otherwise leave the breadcrumb claiming "branch restored" while the tree still
  # carries the base-merge commit — the exact silent divergence PUSH_REJECTED exists to
  # rule out. The token stays PUSH_REJECTED (the push WAS rejected), but the breadcrumb
  # is honest about the tree's actual state.
  if git reset --hard "$PRE_SHA" >/dev/null 2>&1; then
    echo "$1" >&2
  else
    echo "update-branch-checkpoint: WARNING push rejected AND the restore to pre-checkpoint SHA $PRE_SHA failed — the tree may still carry the base-merge commit; resolve manually before the next push. ($1)" >&2
  fi
  emit "PUSH_REJECTED"
  exit 4
}

# --- push helper: push the merged branch; on a non-fast-forward refusal, run the
# push-race recovery arm exactly once. Emits the final token and exits. ---
_push_or_recover() {
  if git push; then
    emit "UPDATED $BEHIND"
    exit 0
  fi
  # Non-fast-forward: the remote feature ref advanced during the run. Integrate it
  # (preserving the base-merge commit) and retry the push once.
  echo "update-branch-checkpoint: push refused (remote $BRANCH advanced); integrating origin/$BRANCH and retrying once" >&2
  git fetch origin "$BRANCH" || _reject_restore "update-branch-checkpoint: could not fetch origin/$BRANCH to integrate; branch restored to pre-checkpoint SHA"
  if ! git merge --no-edit "origin/$BRANCH"; then
    # A conflicted integrate is aborted and the branch restored — this is remote
    # divergence, never the base-merge CONFLICT contract.
    git merge --abort >/dev/null 2>&1 || true
    _reject_restore "update-branch-checkpoint: integrating origin/$BRANCH conflicted (remote divergence); merge aborted and branch restored to pre-checkpoint SHA"
  fi
  if git push; then
    emit "UPDATED $BEHIND"
    exit 0
  fi
  _reject_restore "update-branch-checkpoint: push refused twice; branch restored to pre-checkpoint SHA so no unpushed divergence remains"
}

# --- base-merge conflict emitter (shared by the direct and post-unshallow arms). ---
_emit_conflict() {
  {
    echo "update-branch-checkpoint: base merge of origin/$BASE conflicted. Conflicted paths:"
    git diff --name-only --diff-filter=U
    echo "Resolution contract: resolve the conflicts, run the project test suite, git add + git commit to conclude the merge, push, and re-run the changed-contract sweep. If the suite fails, git merge --abort and hard-stop."
  } >&2
  emit "CONFLICT"
  exit 2
}

# --- merge origin/$BASE and dispatch: a clean merge pushes (or recovers) and exits; a
# conflict emits CONFLICT and exits. It RETURNS to the caller only when the merge failed
# WITHOUT creating a MERGE_HEAD — the no-merge-base case the shallow-history arm handles. ---
_merge_and_dispatch() {
  if git merge --no-edit "origin/$BASE"; then
    _push_or_recover
  fi
  if git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    _emit_conflict
  fi
}

# (7) Merge the base.
_merge_and_dispatch

# (8) Shallow-history arm: no merge base was reachable (the merge above returned without a
# MERGE_HEAD). Unshallow exactly once and retry the merge once; an unrecoverable history is
# a clean UNVERIFIED with the tree untouched.
if git fetch --unshallow origin >/dev/null 2>&1; then
  _merge_and_dispatch
fi

# `_merge_and_dispatch` returns here on ANY base-merge failure that left no MERGE_HEAD —
# no reachable merge base, unrelated histories, or (after the unshallow retry) a still-
# unextendable shallow history. git's own `fatal:` line already printed to stderr above
# (fd 1 is rebound to stderr), so this breadcrumb stays cause-neutral rather than asserting
# "shallow history" as the sole cause of a failure that may be unrelated-histories.
echo "update-branch-checkpoint: could not complete a base merge with origin/$BASE — no reachable merge base (unrelated histories, or a shallow history that could not be extended; see the git error above) — nothing merged" >&2
emit "UNVERIFIED"
exit 3
