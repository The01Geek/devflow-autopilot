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
#   - .devflow/config.schema.json     refreshed every run (editor autocomplete)
#   - .devflow/.gitignore             scoped ignore for ephemeral tmp/ scratch
#                                     (created if absent; keeps config.json +
#                                     learnings/ committed)
#   - .claude/plugins/devflow/        the plugin tree — ONLY with DEVFLOW_VENDOR=1
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
# available of jq, node, or python3 (whichever is installed; all are JSON-safe),
# each writing to a temp file and renaming so a failure can never truncate the
# config in place. This is tool SELECTION, not a retry cascade: the `command -v`
# checks are `if`/`elif` conditions, so once a tool is found the other arms are
# skipped — a present-but-failing tool does NOT fall through to the next one.
# That is fine: the realistic failure (a malformed config.json, a read-only
# .devflow/) would defeat node/python3 too.
# NEVER aborts the install: a missing tool OR a present-but-failing tool (e.g. a
# pre-existing config.json that isn't valid JSON, a read-only .devflow/) both
# degrade to a warning telling the user to set the key by hand. The success-path
# `return 0`s live inside the `if` conditions so `set -e` can't fire on a tool
# failure.
set_config_version() {
  local cfg="$1" version="$2" tmp
  [ -f "$cfg" ] || return 0
  tmp="$(mktemp)" || { log "warning: mktemp failed; add \"devflow_version\": \"$version\" to $cfg by hand."; return 0; }
  if command -v jq >/dev/null 2>&1; then
    if jq --arg v "$version" '.devflow_version = $v' "$cfg" > "$tmp" 2>/dev/null && mv "$tmp" "$cfg"; then
      log "pinned devflow_version=$version in $cfg"; return 0
    fi
  elif command -v node >/dev/null 2>&1; then
    if DEVFLOW_CFG="$cfg" DEVFLOW_VER="$version" DEVFLOW_OUT="$tmp" node -e 'const fs=require("fs");const c=JSON.parse(fs.readFileSync(process.env.DEVFLOW_CFG,"utf8"));c.devflow_version=process.env.DEVFLOW_VER;fs.writeFileSync(process.env.DEVFLOW_OUT,JSON.stringify(c,null,2)+"\n");' 2>/dev/null && mv "$tmp" "$cfg"; then
      log "pinned devflow_version=$version in $cfg"; return 0
    fi
  elif command -v python3 >/dev/null 2>&1; then
    if DEVFLOW_CFG="$cfg" DEVFLOW_VER="$version" DEVFLOW_OUT="$tmp" python3 -c 'import json,os
c=json.load(open(os.environ["DEVFLOW_CFG"]))
c["devflow_version"]=os.environ["DEVFLOW_VER"]
open(os.environ["DEVFLOW_OUT"],"w").write(json.dumps(c,indent=2)+"\n")' 2>/dev/null && mv "$tmp" "$cfg"; then
      log "pinned devflow_version=$version in $cfg"; return 0
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
  log "vendoring plugin → .claude/plugins/devflow/ (DEVFLOW_VENDOR=1)"
  devflow_copy_slice "$SRC" ".claude/plugins/devflow"
else
  log "thin install: the plugin is fetched at runtime (set DEVFLOW_VENDOR=1 to commit it instead)"
fi

# 2. Root marketplace manifest so `plugin_marketplaces: ./` resolves the vendored plugin.
log "writing .claude-plugin/marketplace.json"
mkdir -p .claude-plugin
cat > .claude-plugin/marketplace.json <<'JSON'
{
  "$schema": "https://anthropic.com/claude-code/marketplace.schema.json",
  "name": "devflow-marketplace",
  "description": "Local marketplace for the vendored DevFlow plugin (.claude/plugins/devflow). Installed by devflow-autopilot/install.sh.",
  "owner": { "name": "Daniel Radman", "email": "daniel@radman.ai" },
  "allowCrossMarketplaceDependenciesOn": ["claude-plugins-official"],
  "plugins": [
    {
      "name": "devflow",
      "source": "./.claude/plugins/devflow",
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
#    and the /devflow:init skill can never drift. It never clobbers an existing
#    config.json and always refreshes config.schema.json. Templates resolve
#    relative to the script ($SRC/.devflow), and we target the current repo root.
bash "$SRC/scripts/scaffold-config.sh" "$PWD"

# 6. Pin devflow_version to the exact commit we installed from, so the runtime
#    fetch is reproducible and never tracks mutable main. Re-running the
#    installer re-stamps it; a maintainer can also bump it by hand to any tag,
#    branch, or SHA. The clone+checkout above gives $SRC a resolvable HEAD, so
#    this essentially always yields a SHA; only a broken clone falls back to
#    $REF — warn there, since $REF may be a mutable branch (the very thing the
#    pin exists to avoid).
if PIN="$(git -C "$SRC" rev-parse HEAD 2>/dev/null)"; then :; else
  PIN="$REF"
  log "warning: could not resolve the installed commit SHA; pinning devflow_version=$PIN (if that is a mutable branch, set it to a tag or SHA by hand to freeze the runtime fetch)."
fi
set_config_version ".devflow/config.json" "$PIN"

log "done (from ${REPO}@${REF}). Review with 'git status' / 'git diff' and commit."
