#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# telemetry-branch.sh — persist DevFlow observability artifacts to a dedicated,
# long-lived ORPHAN branch (default `devflow-telemetry`, name from the
# `telemetry.branch` config key) WITHOUT ever touching the current branch, HEAD,
# the default branch, or the working tree. Writes go entirely through git
# plumbing against the object store (hash-object → write-tree → commit-tree) and
# a compare-and-swap ref advance, then a fetch → re-parent → push retry loop.
# This is the SINGLE code path both local and cloud persistence use (issue #441):
# the ambient git credential is the only environment-specific input — the push
# lives here, not in the workflow.
#
# Sourced by lib/efficiency-trace.sh (and any future persist caller). Every
# function is BEST-EFFORT: it NEVER aborts the caller and always leaves a
# ::warning:: breadcrumb on a degradation, mirroring the ensure-label.sh /
# apply-labels.sh exit-0 contract. When the branch cannot be pushed (no remote,
# offline, read-only fork-PR token, missing permission, read-only review
# profile) the LOCAL ref still advances so nothing is lost, and the run proceeds.
#
# Selection-deciding values (whether to append, whether a store is valid, whether
# a worktree holds the ref) are derived with `git` + bash builtins only — never a
# non-preflight PATH tool (`grep`/`sed`/`tr`/…) whose absence would silently
# empty the value and corrupt the decision (CLAUDE.md guard-class 2).

# Guard against double-source (idempotent when a caller sources both this and
# config-source.sh).
if [ -n "${_DEVFLOW_TELEMETRY_BRANCH_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
_DEVFLOW_TELEMETRY_BRANCH_SOURCED=1

# devflow_conf comes from config-source.sh. Source it if the caller has not
# already (efficiency-trace.sh sources it first, so this is a no-op there; a
# standalone/test source of THIS file still resolves the config key).
if ! command -v devflow_conf >/dev/null 2>&1; then
  # shellcheck source=lib/config-source.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config-source.sh" 2>/dev/null || true
fi

# Committer identity for telemetry commits. Deterministic (not the developer's
# git config) so `git commit-tree` NEVER aborts on a checkout with no configured
# user.email (issue #441 AC8) and the orphan branch's history is uniform. These
# are exported into the commit-tree call only.
_DEVFLOW_TELEMETRY_IDENT_NAME="github-actions[bot]"
_DEVFLOW_TELEMETRY_IDENT_EMAIL="41898282+github-actions[bot]@users.noreply.github.com"
# The commit subject is a COUPLED literal: the same
# `chore: persist review-and-fix observability artifacts` string the workflows
# and docs reference. lib/test/run.sh pins it.
_DEVFLOW_TELEMETRY_COMMIT_MSG="chore: persist review-and-fix observability artifacts"
# Bounded retry caps — enough to survive a burst of parallel writers without
# looping forever on a persistently-diverging ref or an unpushable remote.
_DEVFLOW_TELEMETRY_CAS_TRIES=5
_DEVFLOW_TELEMETRY_PUSH_TRIES=4

# Resolve the telemetry branch name (config .telemetry.branch, default
# devflow-telemetry). An empty/absent key → the default (a string key, so the
# #312 valid-falsy trap does not apply — an empty branch name is never a valid
# selection).
devflow_telemetry_branch() {
  # Memoized: the branch name is invariant for a process, and devflow_conf shells
  # to python3 (+ an mktemp) on every call, so a discovery --persist over M run
  # dirs would otherwise do M+ identical config reads. Resolve once, cache.
  if [ -z "${_DEVFLOW_TELEMETRY_BRANCH_CACHE:-}" ]; then
    local b=""
    if command -v devflow_conf >/dev/null 2>&1; then
      b="$(devflow_conf '.telemetry.branch' 'devflow-telemetry')"
    fi
    [ -n "$b" ] || b="devflow-telemetry"
    _DEVFLOW_TELEMETRY_BRANCH_CACHE="$b"
  fi
  printf '%s\n' "$_DEVFLOW_TELEMETRY_BRANCH_CACHE"
}

# The full ref the telemetry branch name maps to (refs/heads/<branch>). Owned by
# the lib so no consumer re-derives `refs/heads/$(devflow_telemetry_branch)`.
devflow_telemetry_ref() {
  printf 'refs/heads/%s\n' "$(devflow_telemetry_branch)"
}

# Verify an EXISTING ref is a telemetry store: its tip tree must hold only
# `.devflow/logs/`-shaped paths. An ABSENT ref returns 0 (a fresh orphan store is
# about to be created). A non-conforming tip returns 1 with a breadcrumb, so the
# write skips rather than committing onto a same-named branch a consumer uses for
# something else (AC4). Pure `case` matching — no grep (selection decision).
devflow_telemetry_verify_store() {
  local root="$1" ref="$2" path tree_out
  git -C "$root" rev-parse --verify --quiet "$ref" >/dev/null 2>&1 || return 0
  # Capture ls-tree's OUTPUT and STATUS together. On a PRESENT ref an ls-tree
  # failure (corrupt/unreadable tree) must NOT read as "empty tree → safe to
  # append": that fails OPEN exactly when the store cannot be read. Fail closed —
  # an unverifiable store is breadcrumb-skipped, not appended onto. (A genuinely
  # empty tree — the orphan root before its first blob — succeeds with empty
  # output and is correctly treated as a valid, appendable store.)
  if ! tree_out="$(git -C "$root" ls-tree -r --name-only "$ref" 2>/dev/null)"; then
    echo "::warning::telemetry-branch: could not read the tip tree of existing ref '${ref}' (git ls-tree failed — corrupt or unreadable tree); cannot verify it is a telemetry store, refusing to append this run" >&2
    return 1
  fi
  # printf-pipe via process substitution (not a `| while`, which would run the
  # loop in a subshell and swallow the `return 1`): keeps the loop — and its
  # early return — in the current shell, with no heredoc temp file.
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
      .devflow/logs/*) ;;
      *)
        echo "::warning::telemetry-branch: existing ref '${ref}' holds a non-.devflow/logs/ path ('${path}') — it is not a DevFlow telemetry store; refusing to append (a consumer may use this branch for something else)" >&2
        return 1 ;;
    esac
  done < <(printf '%s\n' "$tree_out")
  return 0
}

# True (rc 0) when the branch is currently checked out in SOME worktree of this
# repo — in which case advancing its ref out from under that worktree would
# corrupt it, so the caller degrades (AC10). Parsed from `worktree list
# --porcelain` with bash `case` only (this decides the degrade).
devflow_telemetry_branch_checked_out() {
  local root="$1" ref="$2" line
  while IFS= read -r line; do
    case "$line" in
      "branch $ref") return 0 ;;
    esac
  done < <(git -C "$root" worktree list --porcelain 2>/dev/null)
  return 1
}

# Emit the `.devflow/logs/…`-relative paths of every blob under $3 (a path
# prefix, e.g. `.devflow/logs/efficiency/`) on ref $2, one per line. Empty output
# when the ref or prefix is absent — the reader/backstop then degrades to its
# other sources (legacy tracked tree, tmp scratch). Best-effort, always rc 0.
devflow_telemetry_list_blobs() {
  local root="$1" ref="$2" prefix="$3"
  git -C "$root" rev-parse --verify --quiet "$ref" >/dev/null 2>&1 || return 0
  git -C "$root" ls-tree -r --name-only "$ref" -- "$prefix" 2>/dev/null || true
  return 0
}

# rc 0 iff blob path $3 exists on ref $2 (the branch-presence idempotency probe:
# `git cat-file -e <ref>:<path>`). rc non-zero when absent OR the ref itself is
# absent — either way "not yet persisted", the correct answer for both the record
# idempotency check (AC14) and --self-check (AC15).
devflow_telemetry_blob_exists() {
  local root="$1" ref="$2" path="$3"
  git -C "$root" rev-parse --verify --quiet "$ref" >/dev/null 2>&1 || return 1
  git -C "$root" cat-file -e "${ref}:${path}" >/dev/null 2>&1
}

# Print the content of blob $3 from ref $2 to stdout (git show <ref>:<path>).
# rc non-zero (no output) when absent — the caller treats that as "no such blob".
devflow_telemetry_show_blob() {
  local root="$1" ref="$2" path="$3"
  git -C "$root" show "${ref}:${path}" 2>/dev/null
}

# ── The write ────────────────────────────────────────────────────────────────
# devflow_telemetry_persist_tree <root> <staging_root>
#
# Persist every regular file under <staging_root> onto the telemetry branch at
# its <staging_root>-relative path (the paths ARE `.devflow/logs/…` — the caller
# stages them there under .devflow/tmp/, so nothing is materialized in the
# tracked tree). Sequence (issue #441 Implementation Notes):
#   1. resolve the branch; enumerate staged files (nothing staged → clean no-op).
#   2. verify an existing ref is a telemetry store (else breadcrumb-skip).
#   3. degrade if the ref is checked out in a worktree.
#   4. CAS loop: seed a unique temp index from the ref tip (or empty for the
#      orphan root), hash+add every staged file, write-tree; if the tree is
#      UNCHANGED, skip the commit (idempotent no-op — no new branch commit);
#      else commit-tree (explicit identity, parent = tip when present) and
#      `git update-ref <ref> <new> <expected-old>` (compare-and-swap). On CAS
#      failure re-read the tip and retry, bounded.
#   5. push fetch → re-parent-on-fetched-tip → push retry loop, triggered on ANY
#      push rejection (non-ff or the branch-first-created "fetch first" case);
#      give up best-effort after the cap with a ::warning::. No remote → keep the
#      local ref, breadcrumb, return 0.
# Always returns 0. The temp index is uniquely named with bash builtins (not
# mktemp, which the cloud sandbox blocks — AC9) and removed on every exit path
# via the subshell's EXIT trap.
devflow_telemetry_persist_tree() {
  local root="$1" staging_root="$2"
  [ -n "$root" ] && [ -n "$staging_root" ] || return 0
  [ -d "$staging_root" ] || return 0

  local branch ref
  branch="$(devflow_telemetry_branch)"
  ref="$(devflow_telemetry_ref)"

  # Enumerate staged files (relative to staging_root). Builtin globbing via a
  # find-free recursive walk would need bash 4 globstar; instead use `git`'s own
  # object hashing per file discovered with a portable `find`-free approach. We
  # DO need to walk a directory tree — use a small recursive bash walker so no
  # dependency on `find` (not preflight-guaranteed) and no selection value routed
  # through a non-guaranteed tool.
  local staged_rel=()
  _devflow_telemetry_walk() {
    local d="$1" e
    for e in "$d"/* "$d"/.[!.]*; do
      [ -e "$e" ] || continue
      if [ -d "$e" ]; then
        _devflow_telemetry_walk "$e"
      elif [ -f "$e" ]; then
        staged_rel+=("${e#"$staging_root"/}")
      fi
    done
  }
  _devflow_telemetry_walk "$staging_root"
  if [ "${#staged_rel[@]}" -eq 0 ]; then
    return 0   # nothing to persist — clean no-op
  fi

  # Guard: every staged path must be under .devflow/logs/ so a caller bug can
  # never write a stray path onto the store (keeps verify_store's invariant true
  # by construction). A non-conforming path is FILTERED OUT with a per-path
  # breadcrumb — NOT aborting the whole batch — so one stray path from one run's
  # staging never drops every OTHER run's conforming records (the batched write
  # can carry many runs' records). If filtering leaves nothing, it's a clean no-op.
  local rel conforming=()
  for rel in "${staged_rel[@]}"; do
    case "$rel" in
      .devflow/logs/*) conforming+=("$rel") ;;
      *)
        echo "::warning::telemetry-branch: staged path '${rel}' is not under .devflow/logs/ — skipping just this path (caller staged an unexpected path); other conforming records still persist" >&2 ;;
    esac
  done
  staged_rel=("${conforming[@]}")
  if [ "${#staged_rel[@]}" -eq 0 ]; then
    return 0   # every staged path was non-conforming — nothing left to persist
  fi

  # Verify an existing store before appending.
  devflow_telemetry_verify_store "$root" "$ref" || return 0

  # Degrade if the branch is live in a worktree (AC10).
  if devflow_telemetry_branch_checked_out "$root" "$ref"; then
    echo "::warning::telemetry-branch: '${branch}' is checked out in a worktree — refusing to advance its ref (would corrupt that worktree); telemetry not persisted this run" >&2
    return 0
  fi

  # All index-scoped work runs in a subshell so the unique temp index is removed
  # on EVERY exit path by the EXIT trap (AC9), and the caller's set -e / shell
  # state is untouched. Git object/ref writes are global, so the subshell still
  # advances the ref for the parent.
  (
    idx="${root}/.devflow/tmp/telemetry-index-$$-${RANDOM}-${SECONDS}-${RANDOM}"
    trap 'rm -f "$idx" 2>/dev/null' EXIT
    mkdir -p "${root}/.devflow/tmp" 2>/dev/null || true

    # Build a tree of <new blobs on top of `parent_tip`> into the temp index.
    # Echoes the resulting tree sha, or empty (non-zero rc) on failure. The whole
    # body runs in a nested subshell so GIT_INDEX_FILE is scoped to it and cannot
    # leak into the next commit_on call — no manual `unset` on each exit path.
    build_tree() {
      local parent="$1"
      rm -f "$idx" 2>/dev/null || true
      (
        export GIT_INDEX_FILE="$idx"
        local r blob
        if [ -n "$parent" ]; then
          git -C "$root" read-tree "$parent" 2>/dev/null || exit 1
        fi
        for r in "${staged_rel[@]}"; do
          blob="$(git -C "$root" hash-object -w "${staging_root}/${r}" 2>/dev/null)" || exit 1
          git -C "$root" update-index --add --cacheinfo "100644,${blob},${r}" 2>/dev/null || exit 1
        done
        git -C "$root" write-tree 2>/dev/null || exit 1
      )
    }

    commit_on() {  # $1 = parent tip (may be empty → orphan root); echoes new commit sha
      local parent="$1" tree
      tree="$(build_tree "$parent")" || return 1
      [ -n "$tree" ] || return 1
      # No-op guard: if the new tree equals the parent's tree, nothing changed —
      # signal that with the sentinel `NOOP` so the caller skips the commit (no
      # spurious branch commit on an idempotent re-run — AC14).
      if [ -n "$parent" ]; then
        local ptree
        ptree="$(git -C "$root" rev-parse --verify --quiet "${parent}^{tree}" 2>/dev/null)"
        [ "$tree" = "$ptree" ] && { printf 'NOOP\n'; return 0; }
      fi
      local parent_arg=()
      [ -n "$parent" ] && parent_arg=(-p "$parent")
      GIT_AUTHOR_NAME="$_DEVFLOW_TELEMETRY_IDENT_NAME" GIT_AUTHOR_EMAIL="$_DEVFLOW_TELEMETRY_IDENT_EMAIL" \
      GIT_COMMITTER_NAME="$_DEVFLOW_TELEMETRY_IDENT_NAME" GIT_COMMITTER_EMAIL="$_DEVFLOW_TELEMETRY_IDENT_EMAIL" \
        git -C "$root" commit-tree "$tree" "${parent_arg[@]}" -m "$_DEVFLOW_TELEMETRY_COMMIT_MSG" 2>/dev/null
    }

    # Re-parent for the PUSH retry: build a tree that is the UNION of the fetched
    # remote tip's tree and the LOCAL tip's whole tree (issue #441 review — offline
    # data-loss fix). The plain `commit_on "$remote_tip"` re-applied only THIS run's
    # staged files, which would DROP any offline-accumulated local record present on
    # the local ref but absent from the fetched remote tip — real data loss on the
    # exact reconnect path the retry loop exists to protect. Per-run filenames are
    # unique, so overlaying every blob from the local tip onto the remote-tip base is
    # a pure union (this run's staged files are already committed into the local tip,
    # so they come along too). Echoes the new commit sha, `NOOP` when the union tree
    # equals the remote tip's tree (our content already there), or empty on failure.
    commit_union_on() {  # $1 = remote tip (parent), $2 = local tip to overlay
      local base="$1" overlay="$2" tree ptree meta path mode sha
      rm -f "$idx" 2>/dev/null || true
      tree="$(
        export GIT_INDEX_FILE="$idx"
        git -C "$root" read-tree "$base" 2>/dev/null || exit 1
        # `ls-tree -r` here assembles tree CONTENT (a union), not a selection
        # decision, so a loop over its output is appropriate. Format is
        # `<mode> <type> <sha>\t<path>`; split the tab, then take first/last fields.
        while IFS="$(printf '\t')" read -r meta path; do
          [ -n "$path" ] || continue
          mode="${meta%% *}"; sha="${meta##* }"
          git -C "$root" update-index --add --cacheinfo "${mode},${sha},${path}" 2>/dev/null || exit 1
        done < <(git -C "$root" ls-tree -r "$overlay" 2>/dev/null)
        git -C "$root" write-tree 2>/dev/null || exit 1
      )" || return 1
      [ -n "$tree" ] || return 1
      ptree="$(git -C "$root" rev-parse --verify --quiet "${base}^{tree}" 2>/dev/null)"
      [ "$tree" = "$ptree" ] && { printf 'NOOP\n'; return 0; }
      GIT_AUTHOR_NAME="$_DEVFLOW_TELEMETRY_IDENT_NAME" GIT_AUTHOR_EMAIL="$_DEVFLOW_TELEMETRY_IDENT_EMAIL" \
      GIT_COMMITTER_NAME="$_DEVFLOW_TELEMETRY_IDENT_NAME" GIT_COMMITTER_EMAIL="$_DEVFLOW_TELEMETRY_IDENT_EMAIL" \
        git -C "$root" commit-tree "$tree" -p "$base" -m "$_DEVFLOW_TELEMETRY_COMMIT_MSG" 2>/dev/null
    }

    # ── CAS advance loop ───────────────────────────────────────────────────────
    local try old new committed="" upd_err=""
    for ((try = 0; try < _DEVFLOW_TELEMETRY_CAS_TRIES; try++)); do
      old="$(git -C "$root" rev-parse --verify --quiet "$ref" 2>/dev/null || true)"
      new="$(commit_on "$old")" || { new=""; }
      if [ -z "$new" ]; then
        echo "::warning::telemetry-branch: could not build the telemetry commit for '${branch}' (object-store write failed); telemetry not persisted this run" >&2
        exit 0
      fi
      if [ "$new" = "NOOP" ]; then
        committed="$old"   # tree unchanged — the record already exists on the branch
        break
      fi
      # TEST-ONLY race seam (issue #441 AC5): DEVFLOW_TELEMETRY_RACE_HOOK names an
      # executable the test runs ONCE, here — between our `old` read and the CAS
      # update-ref — to advance the ref out from under us and prove the retry
      # rebuilds on the sibling's new tip with no lost commit. It fires at most once
      # (self-clears) so the retry proceeds normally, and is a NO-OP in production
      # (the var is never set). Never a network/state dependency of the real path.
      if [ -n "${DEVFLOW_TELEMETRY_RACE_HOOK:-}" ] && [ -x "${DEVFLOW_TELEMETRY_RACE_HOOK}" ]; then
        "$DEVFLOW_TELEMETRY_RACE_HOOK" "$root" "$ref" "$branch" >/dev/null 2>&1 || true
        DEVFLOW_TELEMETRY_RACE_HOOK=""
      fi
      # Capture update-ref's stderr (NOT 2>/dev/null): a non-zero rc here is NOT
      # always a lost CAS race. git reports a genuine compare-and-swap mismatch as
      # `... but expected ...`, but the same non-zero rc also covers a stale/held
      # ref .lock, a read-only .git, or ENOSPC on the ref/reflog write — where the
      # expected-old matched fine and the WRITE failed. Swallowing the stderr and
      # reporting "lost N races" would steer the operator to hunt phantom
      # concurrency while the real cause (lock/permission/disk) is discarded.
      if upd_err="$(git -C "$root" update-ref "$ref" "$new" "${old:-}" 2>&1)"; then
        committed="$new"
        break
      fi
      # Non-race failure (a ref lock, permission, or disk error — NOT an
      # expected-old mismatch) will not clear on retry, so stop looping and let the
      # terminal breadcrumb below name the git error verbatim. A genuine race
      # (`but expected`) re-reads the new tip and rebuilds, bounded.
      case "$upd_err" in
        *"but expected"*) : ;;   # genuine CAS mismatch — retry
        *) break ;;              # lock/permission/disk — retrying won't help
      esac
    done
    if [ -z "$committed" ]; then
      case "$upd_err" in
        *"but expected"*|"")
          echo "::warning::telemetry-branch: compare-and-swap on '${branch}' lost ${_DEVFLOW_TELEMETRY_CAS_TRIES} races (a sibling worktree/process kept advancing it); telemetry not persisted this run" >&2 ;;
        *)
          echo "::warning::telemetry-branch: could not advance the ref for '${branch}' (git update-ref failed: ${upd_err}) — a held ref .lock, a read-only .git, or a full disk, NOT a concurrent writer; telemetry not persisted this run" >&2 ;;
      esac
      exit 0
    fi

    # ── Push loop (best-effort) ────────────────────────────────────────────────
    # No remote configured → nothing to push; the local ref carries the run
    # (AC7). This is the offline/local-only case.
    if [ -z "$(git -C "$root" remote 2>/dev/null)" ]; then
      echo "::warning::telemetry-branch: no git remote configured — '${branch}' advanced locally but not pushed; telemetry is retained on the local ref only" >&2
      exit 0
    fi

    local ptry push_err remote_tip local_cur
    for ((ptry = 0; ptry < _DEVFLOW_TELEMETRY_PUSH_TRIES; ptry++)); do
      if push_err="$(git -C "$root" push origin "${ref}:${ref}" 2>&1)"; then
        exit 0   # pushed
      fi
      case "$push_err" in
        *"fetch first"*|*"non-fast-forward"*|*"[rejected]"*|*"Updates were rejected"*)
          # The remote advanced (another writer, or the branch was created
          # remotely first). Fetch its tip, re-parent the UNION of the remote tip
          # and our whole local tip on it (preserving offline-accumulated local
          # records — see commit_union_on), CAS-advance the local ref, and retry
          # (AC5/AC6).
          if ! git -C "$root" fetch -q origin "${ref}:refs/remotes/origin/${branch}" 2>/dev/null; then
            echo "::warning::telemetry-branch: push to '${branch}' was rejected and the follow-up fetch failed (no network/auth?); '${branch}' advanced locally but not pushed — telemetry retained on the local ref" >&2
            exit 0
          fi
          remote_tip="$(git -C "$root" rev-parse --verify --quiet "refs/remotes/origin/${branch}" 2>/dev/null || true)"
          [ -n "$remote_tip" ] || { echo "::warning::telemetry-branch: could not resolve the fetched tip of '${branch}'; telemetry retained on the local ref only" >&2; exit 0; }
          local_cur="$(git -C "$root" rev-parse --verify --quiet "$ref" 2>/dev/null || true)"
          new="$(commit_union_on "$remote_tip" "$local_cur")" || new=""
          if [ -z "$new" ]; then
            echo "::warning::telemetry-branch: could not re-parent the telemetry commit onto the fetched tip of '${branch}'; telemetry retained on the local ref only" >&2
            exit 0
          fi
          # Capture the re-parent update-ref's stderr (NOT 2>/dev/null): a failure
          # here (ref lock, permission, disk) must not be swallowed and then
          # misattributed to "a persistently racing remote writer" by the terminal
          # give-up breadcrumb below — name the real git error and stop.
          if [ "$new" = "NOOP" ]; then
            # Our content already lives on the remote tip — fast-forward the local
            # ref to it so a later push is a clean no-op, and stop.
            if ! upd_err="$(git -C "$root" update-ref "$ref" "$remote_tip" "${local_cur:-}" 2>&1)"; then
              echo "::warning::telemetry-branch: could not fast-forward the local ref for '${branch}' to the fetched tip (git update-ref failed: ${upd_err}); telemetry retained on the local ref only" >&2
            fi
            exit 0
          fi
          if ! upd_err="$(git -C "$root" update-ref "$ref" "$new" "${local_cur:-}" 2>&1)"; then
            echo "::warning::telemetry-branch: could not advance the local ref for '${branch}' onto the re-parented commit (git update-ref failed: ${upd_err}) — a held ref .lock, a read-only .git, or a full disk; '${branch}' not pushed this run, telemetry retained on the local ref" >&2
            exit 0
          fi
          ;;
        *)
          # Non-rejection failure: no remote reachable, auth denied, read-only
          # token/profile, missing permission. Best-effort: keep the local ref,
          # breadcrumb, done (AC7).
          echo "::warning::telemetry-branch: push of '${branch}' failed (${push_err:-unknown}) — likely no network, a read-only/fork-PR token, or missing permission; '${branch}' advanced locally but not pushed, telemetry is retained on the local ref" >&2
          exit 0
          ;;
      esac
    done
    echo "::warning::telemetry-branch: push of '${branch}' still rejected after ${_DEVFLOW_TELEMETRY_PUSH_TRIES} fetch/re-parent retries (a persistently racing remote writer?); '${branch}' advanced locally but not pushed this run — the next persist will carry it" >&2
    exit 0
  )
  return 0
}
