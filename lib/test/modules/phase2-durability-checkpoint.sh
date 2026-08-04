# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# shellcheck shell=bash
# Sourceable Phase 2 mid-run durability-checkpoint contract module (issue #1139).
# Contract: the caller sets LIB and RESULTS_FILE, defines assert_eq, and sources
# lib/test/module-harness.sh first. This module uses assert_eq plus the `_dc_*`
# domain-private helpers below — it references NO monolith helper, owns its private
# fixture root and cleanup, never invokes the runner or the full-suite boundary, and
# may not self-skip. The inventory in phase2-durability-checkpoint.inventory.md
# records the module's provenance.
#
# The `trap _dc_cleanup EXIT` below relies on the sourcing contract: both callers
# (module-harness.sh's full-suite boundary and run-module.sh) source this module
# inside a ( ... ) subshell, so the trap fires at subshell exit and cannot clobber
# the runner's own EXIT handling.
#
# WHAT THIS MODULE OWNS. The durability helper scripts/phase2-durability-checkpoint.sh
# and its git-state contract (issue #1139). Every assertion is behavioural: the helper
# is driven against a scratch git repository with a REAL bare remote — the git plumbing
# under test is not mocked — and judged on the resulting git state (commits ahead of
# base, presence of content in the pushed commit range, index contents at commit time)
# and the helper's exit code. There is no wording-only pin here (issues #375/#666/#810).

REPO_ROOT="$LIB/.."
DC_HELPER="$REPO_ROOT/scripts/phase2-durability-checkpoint.sh"

# A fresh rig: a bare remote + a work tree whose `feat` branch is created and pushed
# empty (mirroring Phase 1). Prints the work-tree path. Each rig root comes from the
# harness's `git_sandbox` allocator (module-harness.sh) — runner-cleaned, and
# fail-closed to a /dev/null sentinel on `mktemp -d` failure so no assertion can reach
# the live checkout.
_dc_newrig() {
  local rig work
  rig="$(git_sandbox "phase2-durability-checkpoint rig")" || return 1
  work="$rig/work"
  git init -q --bare "$rig/remote.git" || return 1
  git init -q "$work" || return 1
  (
    cd "$work" || exit 1
    git config user.email t@example.com
    git config user.name tester
    git config commit.gpgsign false
    git remote add origin "$rig/remote.git"
    printf 'base\n' > base.txt
    git add base.txt
    git commit -qm base
    git branch -M main
    git push -q origin main
    git checkout -q -b feat
    git push -q -u origin feat
  ) || return 1
  printf '%s\n' "$work"
}

# Invoke the helper with the workflow-edit guard INACTIVE (GITHUB_ACTIONS != true),
# so ordinary staging is exercised. Runs in the caller's cwd.
_dc_cp() {  # <message> <path>...
  GITHUB_ACTIONS=false DEVFLOW_APP_ID=present bash "$DC_HELPER" "$@"
}
# Invoke the helper with the workflow-edit guard ACTIVE (cloud tier, DEVFLOW_APP_ID
# empty — the GITHUB_TOKEN fallback that cannot push .github/workflows/).
_dc_cp_guard() {  # <message> <path>...
  GITHUB_ACTIONS=true DEVFLOW_APP_ID='' bash "$DC_HELPER" "$@"
}
# Commits on feat ahead of base, read from the remote after a fetch.
_dc_remote_ahead() {  # <work>
  ( cd "$1" && git fetch -q origin && git rev-list --count origin/main..origin/feat )
}
# yes/no: does the remote feat tip carry PATH?
_dc_remote_has() {  # <work> <path>
  ( cd "$1" && git fetch -q origin && git cat-file -e "origin/feat:$2" 2>/dev/null && echo yes || echo no )
}

# ── AC1 (RED control) + AC2 (GREEN) ─────────────────────────────────────────
# AC1: the control that reproduces today's behavior — no checkpoint taken between
# branch creation and §2.5 leaves the branch zero commits ahead of base with the
# produced content absent from the remote. The RED baseline is that observable git
# state, not a missing-command error.
W="$(_dc_newrig)"
( cd "$W" && printf 'produced work\n' > feature.txt )
assert_eq "#1139 AC1 control: no checkpoint leaves the branch 0 commits ahead of base" \
  "0" "$(_dc_remote_ahead "$W")"
assert_eq "#1139 AC1 control: produced content is absent from the remote without a checkpoint" \
  "no" "$(_dc_remote_has "$W" feature.txt)"
# AC2: after invoking the durability helper, the produced content is on the remote
# branch and the branch is at least one commit ahead of base.
( cd "$W" && _dc_cp "feat: checkpoint" feature.txt >/dev/null 2>&1 )
assert_eq "#1139 AC2: helper checkpoint leaves the branch 1 commit ahead of base" \
  "1" "$(_dc_remote_ahead "$W")"
assert_eq "#1139 AC2: produced content is present on the remote branch after the checkpoint" \
  "yes" "$(_dc_remote_has "$W" feature.txt)"

# ── AC3: behavior under repeated invocation ─────────────────────────────────
# Driven twice with new work between the calls: the remote gains exactly one commit
# per call and each carries only the work completed since the previous one. Driven a
# third time with nothing new: no empty commit.
W="$(_dc_newrig)"
( cd "$W" && printf 'one\n' > f1.txt && _dc_cp "feat: cp1" f1.txt >/dev/null 2>&1 )
A1="$(_dc_remote_ahead "$W")"
( cd "$W" && printf 'two\n' > f2.txt && _dc_cp "feat: cp2" f2.txt >/dev/null 2>&1 )
A2="$(_dc_remote_ahead "$W")"
assert_eq "#1139 AC3: first checkpoint puts the branch 1 commit ahead" "1" "$A1"
assert_eq "#1139 AC3: second checkpoint adds exactly one more commit" "2" "$A2"
# Each commit carries only its own work: the tip commit touches f2.txt and NOT f1.txt.
TIP_FILES="$( cd "$W" && git diff-tree --no-commit-id --name-only -r HEAD | sort | tr '\n' ' ' )"
assert_eq "#1139 AC3: the second commit carries only the work since the first (f2.txt only)" \
  "f2.txt " "$TIP_FILES"
# Third call, nothing new → no empty commit (count unchanged, exit 0).
DC_RC="$( cd "$W" && _dc_cp "feat: cp3" f2.txt >/dev/null 2>&1; echo $? )"
assert_eq "#1139 AC3: a checkpoint with nothing new exits 0" "0" "$DC_RC"
assert_eq "#1139 AC3: a checkpoint with nothing new adds no empty commit" "2" "$(_dc_remote_ahead "$W")"

# ── AC4: cloud-tier workflow-edit guard (detect & do-not-stage) ─────────────
# On a cloud-tier run with DEVFLOW_APP_ID empty, at a checkpoint that is not §2.5,
# a tracked edit AND an untracked addition under the repo's OWN .github/workflows/
# are neither staged nor committed. A vendored .prflow/vendor/... workflow path is
# NOT the repo's own and is not guarded.
W="$(_dc_newrig)"
(
  cd "$W" || exit 1
  mkdir -p .github/workflows
  printf 'name: x\n' > .github/workflows/tracked.yml
  git add .github/workflows/tracked.yml
  git commit -qm 'add workflow' >/dev/null 2>&1
  # tracked edit + untracked add under the repo's own workflows dir, plus real work
  printf 'name: x\nedited: true\n' > .github/workflows/tracked.yml
  printf 'name: y\n' > .github/workflows/untracked.yml
  printf 'real\n' > app.txt
  _dc_cp_guard "feat: cp-guarded" .github/workflows/tracked.yml .github/workflows/untracked.yml app.txt >/dev/null 2>&1
)
assert_eq "#1139 AC4: the guarded tracked workflow edit does not reach the remote commit" \
  "no" "$( cd "$W" && git fetch -q origin && git show 'origin/feat:.github/workflows/tracked.yml' 2>/dev/null | grep -q 'edited: true' && echo yes || echo no )"
assert_eq "#1139 AC4: the guarded untracked workflow file does not reach the remote commit" \
  "no" "$(_dc_remote_has "$W" .github/workflows/untracked.yml)"
assert_eq "#1139 AC4: the untracked workflow file stays unstaged in the working tree" \
  "yes" "$( cd "$W" && git status --porcelain -- .github/workflows/untracked.yml | grep -q '^?? ' && echo yes || echo no )"
assert_eq "#1139 AC4: the non-workflow work still reaches the remote commit (guard did not block it)" \
  "yes" "$(_dc_remote_has "$W" app.txt)"
# Guard excludes EVERY named path → nothing stageable → a clean no-op (no commit),
# distinct from the AC3/AC8 nothing-new no-op.
W="$(_dc_newrig)"
GUARD_ONLY_RC="$( cd "$W" && mkdir -p .github/workflows && printf 'name: z\n' > .github/workflows/only.yml && _dc_cp_guard "feat: cp" .github/workflows/only.yml >/dev/null 2>&1; echo $? )"
assert_eq "#1139 AC4: a checkpoint whose only named path is guard-excluded is a clean no-op (exit 0)" \
  "0" "$GUARD_ONLY_RC"
assert_eq "#1139 AC4: the guard-only no-op adds no commit to the branch" \
  "0" "$(_dc_remote_ahead "$W")"
# NEGATIVE CONTROL for the guard CONDITION. Every assertion above drives the guard
# ACTIVE, so a guard that broke to be unconditionally on would leave them all green
# while ordinary implement runs silently dropped legitimate workflow edits — the
# inverse of the silent-work-loss class #1139 targets. These two drive the guard
# INACTIVE by each of its two exemptions and assert the workflow path DOES land.
W="$(_dc_newrig)"
(
  cd "$W" || exit 1
  mkdir -p .github/workflows
  printf 'name: local\n' > .github/workflows/wf.yml
  _dc_cp "feat: cp" .github/workflows/wf.yml >/dev/null 2>&1   # local tier: GITHUB_ACTIONS != true
)
assert_eq "#1139 AC4 negative control: on the local tier a named workflow path IS committed and pushed" \
  "yes" "$(_dc_remote_has "$W" .github/workflows/wf.yml)"
W="$(_dc_newrig)"
(
  cd "$W" || exit 1
  mkdir -p .github/workflows
  printf 'name: apptoken\n' > .github/workflows/wf.yml
  # Cloud tier, but with a workflow-capable App token (DEVFLOW_APP_ID set) — the
  # other exemption. `_dc_cp` sets exactly this pair, so the guard must stay off.
  GITHUB_ACTIONS=true DEVFLOW_APP_ID=present bash "$DC_HELPER" "feat: cp" .github/workflows/wf.yml >/dev/null 2>&1
)
assert_eq "#1139 AC4 negative control: on the cloud tier with DEVFLOW_APP_ID set a named workflow path IS committed and pushed" \
  "yes" "$(_dc_remote_has "$W" .github/workflows/wf.yml)"

# A stage-all spelling must not become a guard BYPASS. `./` used to reach
# `git add -- ./` because it matched no refusal pattern, and its `${arg#./}` form is the
# empty string, which matches no `.github/workflows/*` pattern either — so a guard-active
# run staged and committed the repo's own workflow files, the exact edit the guard exists
# to withhold. The refusal is what closes it; these assertions read the remote and the
# working tree rather than the index, because a bypass that COMMITS leaves a clean index.
W="$(_dc_newrig)"
GUARD_STAGE_ALL_RC="$( cd "$W" && mkdir -p .github/workflows && printf 'name: g\n' > .github/workflows/guarded.yml && printf 'real\n' > app2.txt && _dc_cp_guard "feat: cp" ./ >/dev/null 2>&1; echo $? )"
assert_eq "#1139 AC4: a guard-active run given the './' stage-all spelling is refused (exit 2)" \
  "2" "$GUARD_STAGE_ALL_RC"
assert_eq "#1139 AC4: a guard-active './' run puts no repo-own workflow file on the remote" \
  "no" "$(_dc_remote_has "$W" .github/workflows/guarded.yml)"
assert_eq "#1139 AC4: after a refused './' the workflow file is still untracked (never staged)" \
  "yes" "$( cd "$W" && git status --porcelain -- .github/workflows/guarded.yml | grep -q '^?? ' && echo yes || echo no )"
assert_eq "#1139 AC4: a guard-active './' run adds no commit to the branch at all" \
  "0" "$(_dc_remote_ahead "$W")"
# The guard's own normalization must survive a repeated `./` prefix: a single
# `${arg#./}` strip leaves `././.github/…` still prefixed, so the workflow path would
# slip the guard and be staged despite it.
W="$(_dc_newrig)"
(
  cd "$W" || exit 1
  mkdir -p .github/workflows
  printf 'name: r\n' > .github/workflows/repeated.yml
  printf 'real\n' > app3.txt
  _dc_cp_guard "feat: cp" ././.github/workflows/repeated.yml app3.txt >/dev/null 2>&1
)
assert_eq "#1139 AC4: a repeated './' prefix does not slip the workflow-edit guard" \
  "no" "$(_dc_remote_has "$W" .github/workflows/repeated.yml)"
assert_eq "#1139 AC4: the non-workflow work still lands beside the repeated-prefix exclusion" \
  "yes" "$(_dc_remote_has "$W" app3.txt)"

# ── AC5: §2.1.5 proof content never enters pushed history ───────────────────
# Explicit scoping is the mechanism: a proof file present in the working tree but not
# named to the helper is never staged, so its content never reaches a commit. The
# helper rewrites no history (no amend/rebase/force) — the base commit stays the tip's
# ancestor.
W="$(_dc_newrig)"
BASE_SHA="$( cd "$W" && git rev-parse HEAD )"
(
  cd "$W" || exit 1
  printf 'DEBUG proof edit\n' > proof.txt          # §2.1.5 temporary proof, NOT named
  printf 'real feature\n' > feature.txt
  _dc_cp "feat: cp" feature.txt >/dev/null 2>&1     # only the real path is named
)
assert_eq "#1139 AC5: proof content is absent from every commit on the remote" \
  "no" "$(_dc_remote_has "$W" proof.txt)"
assert_eq "#1139 AC5: history is not rewritten — the base commit is still an ancestor of the tip" \
  "yes" "$( cd "$W" && git merge-base --is-ancestor "$BASE_SHA" HEAD && echo yes || echo no )"

# ── AC6: no git add -A / . / intent-to-add; explicit scoping only ───────────
# An unrelated untracked file present at checkpoint time is NOT carried into the commit.
W="$(_dc_newrig)"
(
  cd "$W" || exit 1
  printf 'unrelated scratch\n' > unrelated.txt      # never named to the helper
  printf 'real\n' > wanted.txt
  _dc_cp "feat: cp" wanted.txt >/dev/null 2>&1
)
assert_eq "#1139 AC6: the wanted file reaches the remote commit" \
  "yes" "$(_dc_remote_has "$W" wanted.txt)"
assert_eq "#1139 AC6: the unrelated untracked file is NOT carried into the commit" \
  "no" "$(_dc_remote_has "$W" unrelated.txt)"
assert_eq "#1139 AC6: the unrelated file stays untracked locally (never staged)" \
  "yes" "$( cd "$W" && git status --porcelain -- unrelated.txt | grep -q '^?? ' && echo yes || echo no )"
# The helper refuses stage-all tokens as arguments (the AC6 boundary at the helper).
assert_eq "#1139 AC6: the helper refuses the '-A' stage-all token (exit 2)" \
  "2" "$( cd "$W" && _dc_cp "feat: cp" -A >/dev/null 2>&1; echo $? )"
assert_eq "#1139 AC6: the helper refuses the '.' stage-all token (exit 2)" \
  "2" "$( cd "$W" && _dc_cp "feat: cp" . >/dev/null 2>&1; echo $? )"
assert_eq "#1139 AC6: the helper refuses a ':/' magic pathspec (exit 2)" \
  "2" "$( cd "$W" && _dc_cp "feat: cp" :/ >/dev/null 2>&1; echo $? )"
assert_eq "#1139 AC6: the helper refuses a missing commit message (exit 2)" \
  "2" "$( cd "$W" && _dc_cp >/dev/null 2>&1; echo $? )"
# A message with ZERO pathspecs is a usage error, not a clean no-op: an argument list
# that expands empty (an unmatched glob, an empty variable expansion) must not report
# success with nothing committed. The rejection is ATTRIBUTED to the no-pathspec gate
# via its own breadcrumb, because the missing-message gate ten lines earlier also
# exits 2 — a bare exit-code assertion could not tell the two apart.
assert_eq "#1139 AC6: a message with no pathspec is a usage error (exit 2)" \
  "2" "$( cd "$W" && _dc_cp "feat: cp" >/dev/null 2>&1; echo $? )"
assert_eq "#1139 AC6: the no-pathspec refusal comes from the no-pathspec gate, not the missing-message gate" \
  "yes" "$( cd "$W" && _dc_cp "feat: cp" 2>&1 >/dev/null | grep -q 'no pathspec given' && echo yes || echo no )"
assert_eq "#1139 AC6: a no-pathspec invocation commits nothing" \
  "0" "$( cd "$W" && _dc_cp "feat: cp" >/dev/null 2>&1; git rev-list --count 'HEAD@{u}'..HEAD 2>/dev/null || echo 0 )"
# Positive control on the same fixture: the identical rig and message DO succeed once
# a path is named, so the refusal above is the empty argument list and not an
# unrelated precondition of the rig.
assert_eq "#1139 AC6: positive control — the same rig and message succeed once a path is named" \
  "0" "$( cd "$W" && printf 'ctl\n' > ctl.txt && _dc_cp "feat: cp" ctl.txt >/dev/null 2>&1; echo $? )"
# The refusal is a CLASS test, not a token denylist. Every spelling git resolves to the
# whole tree is refused, not only the bare `.` — a denylist leaves the defect one
# spelling away, which is exactly how `./` shipped unrefused. Each of these reaches
# `git add --` as a whole-tree pathspec: `git add` is recursive over a directory, so the
# `.`-and-`/` navigation forms stage the entire tree, and a plain (non-`:(glob)`)
# pathspec wildcard matches across `/`, so `*`/`**` do the same.
assert_eq "#1139 AC6: the helper refuses the './' stage-all spelling (exit 2)" \
  "2" "$( cd "$W" && _dc_cp "feat: cp" ./ >/dev/null 2>&1; echo $? )"
assert_eq "#1139 AC6: the helper refuses the './/' stage-all spelling (exit 2)" \
  "2" "$( cd "$W" && _dc_cp "feat: cp" .// >/dev/null 2>&1; echo $? )"
assert_eq "#1139 AC6: the helper refuses the './.' stage-all spelling (exit 2)" \
  "2" "$( cd "$W" && _dc_cp "feat: cp" ./. >/dev/null 2>&1; echo $? )"
assert_eq "#1139 AC6: the helper refuses the '././' stage-all spelling (exit 2)" \
  "2" "$( cd "$W" && _dc_cp "feat: cp" ././ >/dev/null 2>&1; echo $? )"
assert_eq "#1139 AC6: the helper refuses the '..' parent-tree spelling (exit 2)" \
  "2" "$( cd "$W" && _dc_cp "feat: cp" .. >/dev/null 2>&1; echo $? )"
assert_eq "#1139 AC6: the helper refuses the '*' match-everything pathspec (exit 2)" \
  "2" "$( cd "$W" && _dc_cp "feat: cp" '*' >/dev/null 2>&1; echo $? )"
assert_eq "#1139 AC6: the helper refuses the '**' match-everything pathspec (exit 2)" \
  "2" "$( cd "$W" && _dc_cp "feat: cp" '**' >/dev/null 2>&1; echo $? )"
assert_eq "#1139 AC6: the helper refuses an empty-string pathspec (exit 2)" \
  "2" "$( cd "$W" && _dc_cp "feat: cp" '' >/dev/null 2>&1; echo $? )"
# A caller-named directory is NOT in that class — it is recursive by design and is
# exactly what the caller scoped the checkpoint to. This is the negative control that
# keeps the class test from degenerating into "refuse everything".
W="$(_dc_newrig)"
(
  cd "$W" || exit 1
  mkdir -p named-dir
  printf 'in a named dir\n' > named-dir/inside.txt
  printf 'unrelated scratch\n' > outside.txt          # never named
  _dc_cp "feat: cp" named-dir >/dev/null 2>&1
)
assert_eq "#1139 AC6: a caller-named directory is still accepted and its content lands" \
  "yes" "$(_dc_remote_has "$W" named-dir/inside.txt)"
assert_eq "#1139 AC6: the named directory does not widen scope to an unnamed sibling" \
  "no" "$(_dc_remote_has "$W" outside.txt)"
# Path-scoped commit: a pre-existing staged (but unnamed) change is NOT swept into
# the checkpoint even when the index is dirty at entry — the AC6 guarantee is
# enforced by the helper, not left contingent on a clean index.
W="$(_dc_newrig)"
(
  cd "$W" || exit 1
  printf 'pre-staged unrelated\n' > staged-other.txt
  git add staged-other.txt                              # dirty index at entry, unnamed
  printf 'real\n' > named.txt
  _dc_cp "feat: cp" named.txt >/dev/null 2>&1
)
assert_eq "#1139 AC6: the named path reaches the remote commit (dirty index at entry)" \
  "yes" "$(_dc_remote_has "$W" named.txt)"
assert_eq "#1139 AC6: a pre-staged unnamed file is NOT swept into the checkpoint commit" \
  "no" "$(_dc_remote_has "$W" staged-other.txt)"

# ── AC7: a push that does not land is treated as not landed ─────────────────
# Failure shape 1 — a rejected non-fast-forward: another clone advances feat, then a
# local checkpoint's push is rejected; HEAD != @{u}; the helper reports not-landed (3).
W="$(_dc_newrig)"
CLONE="$(dirname "$W")/clone"
git clone -q "$(dirname "$W")/remote.git" "$CLONE"
(
  cd "$CLONE" || exit 1
  git config user.email o@example.com && git config user.name other
  git checkout -q feat
  printf 'other\n' > other.txt && git add other.txt && git commit -qm other && git push -q origin feat
)
NFF_RC="$( cd "$W" && printf 'mine\n' > mine.txt && _dc_cp "feat: cp" mine.txt >/dev/null 2>&1; echo $? )"
assert_eq "#1139 AC7: a rejected non-fast-forward push is treated as not landed (exit 3)" "3" "$NFF_RC"
assert_eq "#1139 AC7: after a non-ff rejection HEAD != @{u}" \
  "no" "$( cd "$W" && [ "$(git rev-parse HEAD)" = "$(git rev-parse '@{u}' 2>/dev/null)" ] && echo yes || echo no )"
# Failure shape 2 — an `Everything up-to-date` no-op: the push refspec is diverted so
# the helper's commit is never sent to feat; git reports up-to-date; HEAD != @{u}; the
# helper reports not-landed (3).
W="$(_dc_newrig)"
UTD_RC="$( cd "$W" && git config remote.origin.push refs/heads/main:refs/heads/main && printf 'x\n' > u.txt && _dc_cp "feat: cp" u.txt >/dev/null 2>&1; echo $? )"
assert_eq "#1139 AC7: an 'Everything up-to-date' no-op push is treated as not landed (exit 3)" "3" "$UTD_RC"
assert_eq "#1139 AC7: after an up-to-date no-op HEAD != @{u}" \
  "no" "$( cd "$W" && [ "$(git rev-parse HEAD)" = "$(git rev-parse '@{u}' 2>/dev/null)" ] && echo yes || echo no )"

# Failure shape 3 — no upstream configured: the branch has no `@{u}`, so the helper
# cannot confirm the checkpoint landed and reports not-landed (3) rather than
# assuming success. Attributed to the no-upstream breadcrumb, since the two shapes
# above also exit 3.
W="$(_dc_newrig)"
NOUP_RC="$( cd "$W" && git checkout -q -b detached-feat && printf 'n\n' > n.txt && _dc_cp "feat: cp" n.txt >/dev/null 2>&1; echo $? )"
assert_eq "#1139 AC7: a branch with no upstream is treated as not landed (exit 3)" "3" "$NOUP_RC"
assert_eq "#1139 AC7: the no-upstream refusal is attributed to the no-upstream arm" \
  "yes" "$( cd "$W" && printf 'n2\n' > n2.txt && _dc_cp "feat: cp" n2.txt 2>&1 >/dev/null | grep -q 'no upstream configured' && echo yes || echo no )"

# ── Exit-0 no-op boundaries are DURABILITY claims, not just "I made no commit" ──
# The caller acts only on a non-zero exit, so a no-op that exits 0 asserts the work so
# far is on the remote. Drive a branch tip that never landed: with the push refspec
# diverted, a commit is made locally but never reaches feat, so the next nothing-new
# boundary must report not-durable (3) instead of a reassuring 0.
W="$(_dc_newrig)"
(
  cd "$W" || exit 1
  git config remote.origin.push refs/heads/main:refs/heads/main   # feat never receives the push
  printf 'stranded\n' > stranded.txt
  _dc_cp "feat: cp" stranded.txt >/dev/null 2>&1                  # commits locally, exits 3 (not landed)
)
assert_eq "#1139: a nothing-new boundary on an unlanded tip reports not-durable (exit 3), not a reassuring 0" \
  "3" "$( cd "$W" && _dc_cp "feat: cp" stranded.txt >/dev/null 2>&1; echo $? )"
assert_eq "#1139: the unlanded-tip no-op is attributed to the tip-not-on-remote arm" \
  "yes" "$( cd "$W" && _dc_cp "feat: cp" stranded.txt 2>&1 >/dev/null | grep -q 'branch tip is NOT on the remote' && echo yes || echo no )"
# Positive control on the same shape: an identical nothing-new boundary on a tip that
# DID land still exits 0, so the assertion above pins the tip check and not the no-op.
W="$(_dc_newrig)"
( cd "$W" && printf 'landed\n' > landed.txt && _dc_cp "feat: cp" landed.txt >/dev/null 2>&1 )
assert_eq "#1139: positive control — a nothing-new boundary on a landed tip still exits 0" \
  "0" "$( cd "$W" && _dc_cp "feat: cp" landed.txt >/dev/null 2>&1; echo $? )"
# The guard-excluded-everything no-op takes the same tip check.
W="$(_dc_newrig)"
(
  cd "$W" || exit 1
  git config remote.origin.push refs/heads/main:refs/heads/main
  printf 'stranded\n' > s.txt
  _dc_cp "feat: cp" s.txt >/dev/null 2>&1
  mkdir -p .github/workflows && printf 'name: g\n' > .github/workflows/g.yml
)
assert_eq "#1139: a guard-excluded-everything no-op on an unlanded tip also reports not-durable (exit 3)" \
  "3" "$( cd "$W" && _dc_cp_guard "feat: cp" .github/workflows/g.yml >/dev/null 2>&1; echo $? )"

# ── Exit 4: a git operation that fails ──────────────────────────────────────
# `git add` failing on a named path that does not exist — the helper must fail closed
# with exit 4 rather than degrade to a silent no-op. Attributed to the add-failure
# breadcrumb, since the not-a-repo arm below also exits 4.
W="$(_dc_newrig)"
assert_eq "#1139: a named nonexistent path fails closed at git add (exit 4)" \
  "4" "$( cd "$W" && _dc_cp "feat: cp" does-not-exist.txt >/dev/null 2>&1; echo $? )"
assert_eq "#1139: the nonexistent-path refusal is attributed to the git-add arm" \
  "yes" "$( cd "$W" && _dc_cp "feat: cp" does-not-exist.txt 2>&1 >/dev/null | grep -q 'git add failed' && echo yes || echo no )"
assert_eq "#1139: a failed git add adds no commit to the branch" \
  "0" "$(_dc_remote_ahead "$W")"
# Positive control on the same rig: a path that DOES exist commits and lands, so the
# exit 4 above is the missing path and not an unrelated precondition of the rig.
assert_eq "#1139: positive control — an existing path on the same rig checkpoints cleanly (exit 0)" \
  "0" "$( cd "$W" && printf 'real\n' > real.txt && _dc_cp "feat: cp" real.txt >/dev/null 2>&1; echo $? )"

# ── Disclosed guard-slip spellings: documented, and here PINNED as behavior ──
# The header discloses that the workflow-edit guard matches the RELATIVE
# `.github/workflows/` spelling only. These assertions pin that disclosure as observed
# behavior rather than leaving it a prose claim: on a guard-ACTIVE run each slip
# spelling is staged and reaches the remote. They are characterization tests of a
# disclosed limit, NOT an endorsement — if the guard is ever widened to resolve
# absolute/`..` forms, these flip and are updated with it.
# NOTE ON THE COMPENSATING CONTROL: the header says such a commit "fails loudly at
# push". That guarantee comes from the real GitHub credential, NOT from this suite —
# the rig's plain bare remote imposes no workflow-push restriction, so the push here
# succeeds. The loud-at-push half is therefore UNENFORCED by the suite and is stated
# as a limitation rather than asserted.
W="$(_dc_newrig)"
(
  cd "$W" || exit 1
  mkdir -p .github/workflows
  printf 'name: bare\n' > .github/workflows/bare.yml
  _dc_cp_guard "feat: cp" .github/workflows >/dev/null 2>&1   # bare dir, no trailing slash
)
assert_eq "#1139: the disclosed slip — a bare '.github/workflows' directory is NOT excluded by the guard" \
  "yes" "$(_dc_remote_has "$W" .github/workflows/bare.yml)"
W="$(_dc_newrig)"
(
  cd "$W" || exit 1
  mkdir -p .github/workflows
  printf 'name: abs\n' > .github/workflows/abs.yml
  _dc_cp_guard "feat: cp" "$W/.github/workflows/abs.yml" >/dev/null 2>&1   # absolute form
)
assert_eq "#1139: the disclosed slip — an absolute workflow path is NOT excluded by the guard" \
  "yes" "$(_dc_remote_has "$W" .github/workflows/abs.yml)"

# ── Not a git repository: exit 4 ────────────────────────────────────────────
# The documented exit-4 "not inside a git repository" arm, driven from a scratch
# directory that is not under any repository. Attributed to its own breadcrumb.
NOREPO="$(git_sandbox "phase2-durability-checkpoint no-repo")/plain"
mkdir -p "$NOREPO"
assert_eq "#1139: outside a git repository the helper exits 4" \
  "4" "$( cd "$NOREPO" && printf 'x\n' > x.txt && _dc_cp "feat: cp" x.txt >/dev/null 2>&1; echo $? )"
assert_eq "#1139: the outside-a-repository refusal is attributed to the not-a-repo arm" \
  "yes" "$( cd "$NOREPO" && _dc_cp "feat: cp" x.txt 2>&1 >/dev/null | grep -q 'not inside a git repository' && echo yes || echo no )"

# ── AC8: idempotency — no empty commit, content seen exactly once ───────────
W="$(_dc_newrig)"
( cd "$W" && printf 'once\n' > once.txt && _dc_cp "feat: cp" once.txt >/dev/null 2>&1 )
AH1="$(_dc_remote_ahead "$W")"
( cd "$W" && _dc_cp "feat: cp-again" once.txt >/dev/null 2>&1 )   # nothing new
AH2="$(_dc_remote_ahead "$W")"
assert_eq "#1139 AC8: re-running the durability step with no change adds no empty commit" "$AH1" "$AH2"
assert_eq "#1139 AC8: a resumed run adopting the branch sees the prior content exactly once" \
  "1" "$( cd "$W" && git fetch -q origin && git log --oneline origin/feat -- once.txt | wc -l | tr -d ' ' )"
