#!/usr/bin/env bash
# ============================================================================
# DevFlow cloud-tier installer / updater
# ============================================================================
# Installs (or updates) the DevFlow GitHub Actions "cloud tier" into the CURRENT
# repository. Idempotent — re-run any time to pull the latest from the primary
# repo. It writes:
#   - .claude-plugin/marketplace.json local marketplace pointing at the plugin
#   - .github/workflows/*.yml         devflow.yml / devflow-implement.yml /
#                                     devflow-review.yml (superseded claude*.yml
#                                     are removed on upgrade, Anthropic's left)
#   - .github/actions/*               the composite actions they use
#   - .devflow/config.json            scaffolded from the template ONLY if absent;
#                                     devflow_version pinned to the installed commit
#                                     (unless already hand-pinned to a non-SHA value)
#   - .devflow/config.schema.json     refreshed every run (editor autocomplete)
#   - .devflow/.gitignore             scoped ignore for ephemeral tmp/ scratch
#                                     (created if absent; keeps config.json +
#                                     learnings/ committed). A thin install also
#                                     adds /vendor/ so the runtime-vendored tree
#                                     is never committed; DEVFLOW_VENDOR=1 removes
#                                     that line (it commits the tree on purpose).
#   - .devflow/vendor/devflow/        the plugin tree — ONLY with DEVFLOW_VENDOR=1
#                                     (thin install otherwise; see below)
#
# Thin by default: the workflows materialize the plugin into the workspace at
# RUNTIME via the vendor-plugin composite action (it clones the pinned
# devflow_version), so the tree no longer has to be committed. The plugin SCRIPTS
# still end up at the literal workspace path the claude-code-action runner needs
# (its bash sandbox can't reach ~/.claude / CLAUDE_SKILL_DIR) — just produced by a
# step instead of a commit. Updating then means bumping devflow_version (or
# re-running this installer, now a small diff). Set DEVFLOW_VENDOR=1 to commit the
# plugin tree instead — self-hosting with no runtime fetch, fully auditable in
# your repo. (Local editor use is different again: add the github marketplace with
# autoUpdate — see docs/cloud-setup.md.)
#
# Usage, from the root of your repo:
#   curl -fsSL https://raw.githubusercontent.com/The01Geek/devflow-autopilot/main/install.sh | bash
#   # pin a version / point at a fork:
#   DEVFLOW_REF=v1.2.0 DEVFLOW_REPO=The01Geek/devflow-autopilot bash install.sh
#   # commit the plugin tree instead of fetching it at runtime:
#   DEVFLOW_VENDOR=1 bash install.sh
# ============================================================================
set -euo pipefail

REPO="${DEVFLOW_REPO:-The01Geek/devflow-autopilot}"
REF="${DEVFLOW_REF:-main}"

log() { printf 'devflow-install: %s\n' "$1"; }
die() { printf 'devflow-install: %s\n' "$1" >&2; exit 1; }

# Pin .devflow/config.json's devflow_version to the ref we installed, so the
# runtime fetch (vendor-plugin) never tracks mutable main. Adds or updates the
# single key without clobbering the rest of the config — using the FIRST
# USABLE of jq or python3 (both are JSON-safe), each writing to a temp file
# and renaming so a failure can never truncate the config in place. This is
# tool SELECTION, not a retry cascade: the jq/python3 arms are `if`/`elif`
# conditions, so once a tool is selected the other arm is skipped — a
# selected-but-failing tool does NOT fall through to the next one. That is
# fine: the realistic failure (a malformed config.json, a read-only .devflow/)
# would defeat python3 too. Selection is execution-verified (issue #247): a
# present-but-unrunnable Windows `jq` shim must not win this selection over a
# working python3, so the jq arm requires `--version` to actually run. (python3 is a hard DevFlow prerequisite;
# `node` was dropped from this cascade — it is no longer required anywhere in
# DevFlow's config path.)
# NEVER aborts the install: a missing tool OR a present-but-failing tool (e.g. a
# pre-existing config.json that isn't valid JSON, a read-only .devflow/) both
# degrade to a warning telling the user to set the key by hand. The success-path
# `return 0`s live inside the `if` conditions so `set -e` can't fire on a tool
# failure.
#
# Only re-stamps when the EXISTING devflow_version is absent/empty or already
# looks like a commit SHA (7-40 lowercase hex). This is a SHAPE heuristic, not
# true provenance detection: it cannot distinguish a SHA this function itself
# previously wrote from a SHA the user hand-set to pin to one specific commit,
# so a hand-pinned exact SHA is not guaranteed to survive a re-run. A value
# that does NOT match that pattern (a branch name like "main", a tag like
# "v1.2.0") was set by hand, so it IS guaranteed to be treated as a deliberate
# pin/tracking choice and left untouched — re-running the installer must never
# silently convert "track main" into "pinned to a SHA".
set_config_version() {
  local cfg="$1" version="$2" tmp
  [ -f "$cfg" ] || return 0
  tmp="$(mktemp)" || { log "warning: mktemp failed; add \"devflow_version\": \"$version\" to $cfg by hand."; return 0; }
  # jq resolution (#247): adapted from lib/resolve-bin.sh's contract —
  # install.sh must run standalone (curl-piped, before any checkout exists), so
  # it cannot source the shared resolver. An explicit DEVFLOW_JQ wins the
  # SELECTION (no candidate probing happens); deliberately unlike the shared
  # resolver, the selection gate below then re-probes whatever was selected,
  # so a broken override routes to the python3 arm instead of failing the
  # step. Otherwise the first of jq/jq.exe whose `--version` runs is selected.
  local jqbin
  jqbin="${DEVFLOW_JQ:-}"
  if [ -z "$jqbin" ]; then
    if jq --version >/dev/null 2>&1; then jqbin=jq
    elif jq.exe --version >/dev/null 2>&1; then jqbin=jq.exe
    fi
  fi
  # Surface a broken explicit override at the earliest, cheapest point: the
  # runtime helpers honor DEVFLOW_JQ verbatim (never probed), so without this
  # breadcrumb the misconfiguration first detonates far from its cause.
  if [ -n "${DEVFLOW_JQ:-}" ] && ! "$jqbin" --version >/dev/null 2>&1; then
    log "warning: DEVFLOW_JQ is set to '$jqbin' but it does not execute; falling back for this step — fix DEVFLOW_JQ before running DevFlow."
  fi
  if [ -n "$jqbin" ] && "$jqbin" --version >/dev/null 2>&1; then
    if "$jqbin" -e '(.devflow_version // "") as $cur | ($cur == "" or ($cur | test("^[0-9a-f]{7,40}$")))' \
        "$cfg" >/dev/null 2>&1; then
      if "$jqbin" --arg v "$version" '.devflow_version = $v' "$cfg" > "$tmp" 2>/dev/null; then
        if mv "$tmp" "$cfg"; then
          log "pinned devflow_version=$version in $cfg"; return 0
        fi
      fi
    else
      local rc=$?
      if [ "$rc" -eq 1 ]; then
        rm -f "$tmp"
        log "kept existing devflow_version in $cfg (looks like a deliberate pin, not a previous SHA stamp) — not overwriting."
        return 0
      fi
      # rc > 1: jq itself errored on the eligibility check (not a genuine false/null
      # result) — fall through to the generic warning rather than misreport it as a
      # deliberate pin.
    fi
  elif command -v python3 >/dev/null 2>&1; then
    if DEVFLOW_CFG="$cfg" DEVFLOW_VER="$version" DEVFLOW_OUT="$tmp" python3 -c 'import json,os,re,sys
c=json.load(open(os.environ["DEVFLOW_CFG"]))
cur=c.get("devflow_version")
# Only null/false count as "absent", mirroring jq'"'"'s `// ""` exactly (jq'"'"'s // only
# substitutes on false/null, never on other falsy JSON values like 0/[]/{}). A
# non-string, non-null/false value (e.g. 0) then fails the re.match below with an
# uncaught TypeError -> exit 1 -> the generic warning, matching jq'"'"'s test/1 runtime
# error on the same input (rc>1) rather than python silently coercing it to "".
if cur is None or cur is False:
    cur=""
if cur == "" or re.match(r"^[0-9a-f]{7,40}$", cur):
    c["devflow_version"]=os.environ["DEVFLOW_VER"]
    open(os.environ["DEVFLOW_OUT"],"w").write(json.dumps(c,indent=2)+"\n")
    sys.exit(0)
sys.exit(3)' 2>/dev/null; then
      if mv "$tmp" "$cfg"; then
        log "pinned devflow_version=$version in $cfg"; return 0
      fi
    else
      local rc=$?
      rm -f "$tmp"
      if [ "$rc" -eq 3 ]; then
        log "kept existing devflow_version in $cfg (looks like a deliberate pin, not a previous SHA stamp) — not overwriting."
        return 0
      fi
    fi
  fi
  rm -f "$tmp"
  log "warning: could not set devflow_version=$version automatically — add \"devflow_version\": \"$version\" to $cfg by hand so the runtime fetch is pinned."
  return 0
}

# Remove DevFlow's OWN superseded workflow files on upgrade. Left behind, the
# old claude.yml keeps listening for @claude and double-fires alongside the new
# devflow.yml. claude-runner.yml / claude-implement.yml are DevFlow-specific
# names (Anthropic never generates them), so removing them is safe. claude.yml,
# however, is SHARED with Anthropic's Claude GitHub App — so remove it ONLY when
# it carries a DevFlow signature (the review_dedupe job / the old header line);
# otherwise it is Anthropic's and must be left untouched.
prune_stale_devflow_workflows() {
  local wf=.github/workflows f
  for f in claude-runner claude-implement; do
    if [ -f "$wf/$f.yml" ]; then
      rm -f "$wf/$f.yml"
      log "removed superseded $f.yml (logic now in devflow.yml / devflow-implement.yml)"
    fi
  done
  if [ -f "$wf/claude.yml" ]; then
    if grep -qE 'review_dedupe:|Light @claude-mention listener for non-implementing' "$wf/claude.yml"; then
      rm -f "$wf/claude.yml"
      log "removed DevFlow's old claude.yml (logic now in devflow.yml)"
    else
      log "left existing claude.yml untouched — it is not DevFlow's (likely Anthropic's Claude GitHub App)."
    fi
  fi
}

# Remove a stale committed plugin tree at the OLD vendored location
# (.claude/plugins/devflow) left by a pre-relocation DEVFLOW_VENDOR=1 install.
# The plugin now lives at .devflow/vendor/devflow because claude-code-action's
# restore-from-base deletes .claude/ on PRs (it is a SENSITIVE_PATH), which wiped
# a tree vendored there. Signature-guarded — only ever removes a directory that
# is actually DevFlow's plugin (carries a devflow plugin.json) so an unrelated
# .claude/plugins/devflow is never touched. Prunes now-empty parents best-effort,
# never the user's wider .claude/ (which holds settings/skills/hooks).
prune_stale_vendored_plugin() {
  local old=.claude/plugins/devflow
  [ -d "$old" ] || return 0   # common case: no old tree → silent no-op.
  if [ -f "$old/.claude-plugin/plugin.json" ] \
     && grep -Eq '"name"[[:space:]]*:[[:space:]]*"devflow"' "$old/.claude-plugin/plugin.json"; then
    rm -rf "$old"
    rmdir .claude/plugins .claude 2>/dev/null || true
    log "removed stale committed plugin at $old (relocated to .devflow/vendor/devflow)"
  else
    # The directory exists but is not a recognizable DevFlow plugin (no devflow
    # plugin.json — e.g. a partial/interrupted older install, or an unrelated
    # tree). Don't rm it blindly; warn so a genuinely-stale tree isn't left to be
    # silently wiped by claude-code-action's .claude/ restore on the next cloud PR.
    log "warning: $old exists but carries no devflow plugin.json; leaving it untouched — if it is a stale pre-relocation vendored tree, remove it by hand (.claude/ is wiped on cloud PRs)."
  fi
}

# Keep the runtime-vendored tree out of consumer commits — but only for thin
# installs. A thin consumer materializes .devflow/vendor/devflow at RUNTIME (in
# cloud CI); now that it survives the restore-from-base (the whole point of the
# relocation), an implement/review-fix run's `git add -A` would otherwise stage
# the bulky tree into the consumer's PR. So a thin install adds `/vendor/` to
# .devflow/.gitignore (patterns there are relative to .devflow/, matching the
# existing `/tmp/` entry). A DEVFLOW_VENDOR=1 install commits the tree on
# purpose, so the ignore line must be ABSENT there — handle the thin→vendor
# upgrade by removing a previously-added line. Idempotent; no-op when the
# scaffolded .gitignore is missing.
manage_vendor_gitignore() {
  local gi=.devflow/.gitignore
  [ -f "$gi" ] || return 0
  if [ "${DEVFLOW_VENDOR:-}" = "1" ]; then
    if grep -qxF '/vendor/' "$gi"; then
      # Portable in-place delete — NOT `sed -i` (GNU-only; BSD/macOS sed needs a
      # backup-suffix arg, and this is a `curl | bash` installer that must run on
      # macOS — see CONTRIBUTING.md). Filter to a temp, then swap only on a clean
      # filter. grep exit 0 = lines kept, 1 = none kept (/vendor/ was the only
      # line → empty result is correct), 2 = real error: distinguish so a
      # mid-write failure (e.g. ENOSPC) never `mv`s a truncated temp over the
      # tracked .gitignore and silently drops /tmp/.
      local _rc=0
      grep -vxF '/vendor/' "$gi" > "$gi.tmp" || _rc=$?
      if [ "$_rc" -le 1 ]; then
        mv "$gi.tmp" "$gi"
        log "un-ignored .devflow/vendor/ (DEVFLOW_VENDOR=1 commits the plugin tree)"
      else
        rm -f "$gi.tmp"
        log "warning: could not rewrite $gi (grep exit $_rc); left /vendor/ in place — remove it by hand so the committed tree is tracked."
      fi
    fi
  elif ! grep -qxF '/vendor/' "$gi"; then
    printf '/vendor/\n' >> "$gi"
    log "ignored .devflow/vendor/ (runtime-vendored plugin must not be committed by a thin install)"
  fi
}

# On a host with no `python3` on PATH (a stock Windows / Git-Bash install, where Python is
# reachable only as `python` / `py -3`), surface DevFlow's consent-gated Python shim
# provisioner so `install.sh` users hit it regardless of install method. It DELEGATES to the
# one provisioner (scripts/provision-python3-shim.sh in the cloned source) — install.sh never
# re-implements interpreter detection — and is a no-op when `python3` already resolves (native
# marketplace installs that bypass install.sh remain covered by the preflight pointer, which
# /devflow:init relays). Best-effort: a missing provisioner or a refusal never aborts the install.
offer_python3_shim() {
  local src="$1" prov rc
  # Probe RUNNABILITY, not mere presence — mirror lib/preflight.sh's happy-path gate. A
  # `python3` that is on PATH but does not execute (dangling symlink, corrupt install,
  # missing runtime DLL — the broken-Windows-interpreter class this provisioner targets)
  # must NOT short-circuit the offer here; it falls through so the resolver/provisioner can
  # surface the remedy. A bare `command -v python3` would skip the offer on exactly that case.
  if command -v python3 >/dev/null 2>&1 && python3 -c 'pass' >/dev/null 2>&1; then
    return 0   # a WORKING python3 is present → nothing to offer here (preflight still enforces the >=3.11 check).
  fi
  prov="$src/scripts/provision-python3-shim.sh"
  if [ ! -f "$prov" ]; then
    log "no working 'python3' on PATH and the shim provisioner is unavailable in the source tree; see docs/install.md to resolve a Python 3 interpreter."
    return 0
  fi
  log "no working 'python3' on PATH — surfacing DevFlow's consent-gated Python interpreter resolver:"
  # Default (no --apply) prints the plan + manual instructions and writes nothing; the user
  # opts into the write by re-running the provisioner with --apply. ANY non-zero exit — the
  # designed plan-mode refusals (rc 2: no >=3.11 interpreter / too-old) and genuine provisioner
  # breakage (a missing lib/resolve-python.sh source, a syntax error, an unexpected set -e
  # abort) alike — is surfaced with the rc rather than swallowed, and never aborts the install.
  # The single breadcrumb covers both cases (this is intentional — one unconditional log, not a
  # branch): for a benign rc-2 refusal the provisioner's own `devflow-python:` breadcrumb on
  # stderr already names the specific cause; for genuine breakage the rc here makes it
  # diagnosable rather than laundered into apparent success.
  bash "$prov" || { rc=$?; log "the Python interpreter resolver exited non-zero (rc $rc); install continues — re-run 'bash $prov' to see its diagnostics."; }
}

# When sourced by the test harness (DEVFLOW_SELFTEST=1), define the functions
# above and stop — the installer body below (which clones + writes files) does
# not run. `return` only executes on the sourced path; `|| true` keeps `set -e`
# happy on the unlikely executed-with-the-flag path.
if [ "${DEVFLOW_SELFTEST:-}" = "1" ]; then return 0 2>/dev/null || true; fi

command -v git >/dev/null 2>&1 || die "git is required."
[ -d .git ] || die "run this from the root of a git repository."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log "fetching ${REPO}@${REF} …"
# Fast path: shallow clone of a branch/tag. Fallback: full clone + checkout,
# which is what resolves a commit SHA (--branch rejects SHAs). Without the
# fallback's checkout, a SHA ref would silently land on the default branch and
# we'd pin devflow_version to the wrong commit. rm -rf before the fallback so a
# cleaned-up-or-not partial first attempt never blocks the reclone. stderr is
# suppressed ONLY on the --branch attempt (a SHA legitimately fails it, and that
# expected failure must stay quiet); the fallback clone and checkout each
# capture their stderr so a genuine failure reports its real cause, and a failed
# checkout after a successful clone is distinguishable from a total clone failure.
CLONE_URL="https://github.com/${REPO}.git"
if ! git clone --quiet --depth 1 --branch "$REF" "$CLONE_URL" "$TMP/src" 2>/dev/null; then
  rm -rf "$TMP/src"
  if ! CLONE_ERR="$(git clone --quiet "$CLONE_URL" "$TMP/src" 2>&1)"; then
    die "could not clone $CLONE_URL (ref: ${REF}) — clone failed: $CLONE_ERR"
  fi
  if ! CHECKOUT_ERR="$(git -C "$TMP/src" checkout --quiet "$REF" 2>&1)"; then
    die "could not clone $CLONE_URL (ref: ${REF}) — clone succeeded but checkout failed: $CHECKOUT_ERR"
  fi
fi
SRC="$TMP/src"

# 1. Plugin tree. Thin by default — the vendor-plugin composite action puts it
#    in the workspace at runtime, so it need not be committed. DEVFLOW_VENDOR=1
#    commits it instead (self-hosting). Both paths copy through the ONE shared
#    slice definition (sourced here), so the file set can never drift between the
#    installer and CI.
# shellcheck source=.github/actions/vendor-plugin/vendor-slice.sh
DEVFLOW_VENDOR_SOURCE=1 . "$SRC/.github/actions/vendor-plugin/vendor-slice.sh"
if [ "${DEVFLOW_VENDOR:-}" = "1" ]; then
  log "vendoring plugin → .devflow/vendor/devflow/ (DEVFLOW_VENDOR=1)"
  devflow_copy_slice "$SRC" ".devflow/vendor/devflow"
else
  log "thin install: the plugin is fetched at runtime (set DEVFLOW_VENDOR=1 to commit it instead)"
fi

# Upgrade migration: remove a stale committed tree at the old .claude/plugins/devflow
# location (relocated to .devflow/vendor/devflow). Runs for both install modes.
prune_stale_vendored_plugin

# 2. Root marketplace manifest so `plugin_marketplaces: ./` resolves the vendored plugin.
log "writing .claude-plugin/marketplace.json"
mkdir -p .claude-plugin
cat > .claude-plugin/marketplace.json <<'JSON'
{
  "$schema": "https://anthropic.com/claude-code/marketplace.schema.json",
  "name": "devflow-marketplace",
  "description": "Local marketplace for the vendored DevFlow plugin (.devflow/vendor/devflow). Installed by devflow-autopilot/install.sh.",
  "owner": { "name": "Daniel Radman", "email": "daniel@radman.ai" },
  "allowCrossMarketplaceDependenciesOn": [],
  "plugins": [
    {
      "name": "devflow",
      "source": "./.devflow/vendor/devflow",
      "description": "End-to-end dev workflow: /devflow:implement, /devflow:review + /devflow:review-and-fix, the /devflow:docs suite, /devflow:create-issue, plus the retrospective loop.",
      "author": { "name": "Daniel Radman", "email": "daniel@radman.ai" },
      "homepage": "https://github.com/The01Geek/devflow-autopilot",
      "category": "development"
    }
  ]
}
JSON

# 3. Workflows (only those the primary repo actually ships).
log "installing workflows + composite actions"
mkdir -p .github/workflows .github/actions
for w in devflow devflow-runner devflow-implement devflow-review; do
  [ -f "$SRC/.github/workflows/$w.yml" ] && cp "$SRC/.github/workflows/$w.yml" ".github/workflows/$w.yml"
done
# devflow-review.yml's CI-completion re-trigger (issue #304) re-fires a review
# that was deferred behind the branch-freshness / other-CI-green preconditions
# once your CI completes. The `workflow_run:` trigger REQUIRES an explicit
# workflow-name list (a GitHub platform constraint — no wildcards) and ships as
# `[CI]`. If your CI workflow is named anything else, that re-trigger silently
# never fires until you add its name. Prompt for it prominently here.
if [ -f ".github/workflows/devflow-review.yml" ]; then
  log "ACTION REQUIRED: edit '.github/workflows/devflow-review.yml' — set the 'workflow_run:' 'workflows:' list (ships as [CI]) to your repo's actual CI workflow name(s), or the auto-review's CI-completion re-trigger will not fire for deferred reviews. External non-Actions CI is covered by 'check_suite', and legacy commit-status-only CI (classic Jenkins, legacy CircleCI) by the 'status' trigger — both need no naming. See docs/workflow-triggers.md."
fi
# Drop DevFlow's superseded claude*.yml on upgrade (signature-guarded so an
# Anthropic-owned claude.yml is never touched).
prune_stale_devflow_workflows

# 4. Composite actions. vendor-plugin is REQUIRED even for a thin install — the
#    workflows reference `./.github/actions/vendor-plugin` to materialize the
#    plugin at runtime, so it (unlike the plugin tree) must always be committed.
for a in read-project-config setup-project-env vendor-plugin; do
  if [ -d "$SRC/.github/actions/$a" ]; then
    rm -rf ".github/actions/$a"
    cp -R "$SRC/.github/actions/$a" ".github/actions/$a"
  fi
done

# 5. config scaffold — delegated to the ONE shared scaffolder so the cloud tier
#    and the /devflow:init skill can never drift. It never overwrites a value the
#    user has set (it only backfills keys newly added to the example) and always
#    refreshes config.schema.json. Templates resolve relative to the script
#    ($SRC/.devflow), and we target the current repo root.
bash "$SRC/scripts/scaffold-config.sh" "$PWD"

# 5b. Gitignore the runtime-vendored tree for thin installs (and un-ignore it for
#     DEVFLOW_VENDOR=1, which commits it). Runs after scaffold so .devflow/.gitignore exists.
manage_vendor_gitignore

# 6. Pin devflow_version to the exact commit we installed from, so the runtime
#    fetch is reproducible and never tracks mutable main. Re-running the
#    installer re-stamps it when eligible (see set_config_version above for the
#    empty/SHA-shape rule — a hand-set non-SHA value is preserved, not
#    re-stamped); a maintainer can also bump it by hand to any tag, branch, or
#    SHA. The clone+checkout above gives $SRC a resolvable HEAD, so
#    this essentially always yields a SHA; only a broken clone falls back to
#    $REF — warn there, since $REF may be a mutable branch (the very thing the
#    pin exists to avoid).
if PIN="$(git -C "$SRC" rev-parse HEAD 2>/dev/null)"; then :; else
  PIN="$REF"
  log "warning: could not resolve the installed commit SHA; pinning devflow_version=$PIN (if that is a mutable branch, set it to a tag or SHA by hand to freeze the runtime fetch)."
fi
set_config_version ".devflow/config.json" "$PIN"

# 7. On a host with no `python3` (stock Windows / Git-Bash), offer the consent-gated shim
#    provisioner so the toolchain can resolve a Python 3 interpreter. No-op where python3 works.
offer_python3_shim "$SRC"

log "done (from ${REPO}@${REF}). Review with 'git status' / 'git diff' and commit."
