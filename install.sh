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
# single key without clobbering the rest of the config — preferring jq, then
# node, then python3 (any one suffices; all are JSON-safe). If none is present
# the key is left as-is (the scaffolded template carries a default) and the user
# is told to set it by hand, so a missing tool never aborts the install.
set_config_version() {
  local cfg="$1" version="$2" tmp
  [ -f "$cfg" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    tmp="$(mktemp)"
    jq --arg v "$version" '.devflow_version = $v' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
  elif command -v node >/dev/null 2>&1; then
    DEVFLOW_CFG="$cfg" DEVFLOW_VER="$version" node -e 'const fs=require("fs"),p=process.env.DEVFLOW_CFG;const c=JSON.parse(fs.readFileSync(p,"utf8"));c.devflow_version=process.env.DEVFLOW_VER;fs.writeFileSync(p,JSON.stringify(c,null,2)+"\n");'
  elif command -v python3 >/dev/null 2>&1; then
    DEVFLOW_CFG="$cfg" DEVFLOW_VER="$version" python3 -c 'import json,os
p=os.environ["DEVFLOW_CFG"]
c=json.load(open(p))
c["devflow_version"]=os.environ["DEVFLOW_VER"]
open(p,"w").write(json.dumps(c,indent=2)+"\n")'
  else
    log "warning: no jq/node/python3 found to set devflow_version=$version — add \"devflow_version\": \"$version\" to $cfg by hand so the runtime fetch is pinned."
    return 0
  fi
  log "pinned devflow_version=$version in $cfg"
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
git clone --quiet --depth 1 --branch "$REF" "https://github.com/${REPO}.git" "$TMP/src" 2>/dev/null \
  || git clone --quiet --depth 1 "https://github.com/${REPO}.git" "$TMP/src" \
  || die "could not clone https://github.com/${REPO} (ref: ${REF})."
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

# 4. Composite actions.
for a in read-project-config setup-project-env; do
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
#    branch, or SHA. Falls back to $REF if the clone has no resolvable HEAD.
PIN="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo "$REF")"
set_config_version ".devflow/config.json" "$PIN"

log "done (from ${REPO}@${REF}). Review with 'git status' / 'git diff' and commit."
