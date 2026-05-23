#!/usr/bin/env bash
# ============================================================================
# DevFlow cloud-tier installer / updater
# ============================================================================
# Installs (or updates) the DevFlow GitHub Actions "cloud tier" into the CURRENT
# repository. Idempotent — re-run any time to pull the latest from the primary
# repo. It writes:
#   - .claude/plugins/devflow/        the VENDORED plugin (scripts/skills/agents/lib
#                                     + .devflow/ templates, so /devflow:init can
#                                     find them from the vendored copy too)
#   - .claude-plugin/marketplace.json local marketplace pointing at the above
#   - .github/workflows/*.yml         devflow.yml / devflow-implement.yml /
#                                     devflow-review.yml (superseded claude*.yml
#                                     are removed on upgrade, Anthropic's left)
#   - .github/actions/*               the composite actions they use
#   - .devflow/config.json            scaffolded from the template ONLY if absent
#   - .devflow/config.schema.json     refreshed every run (editor autocomplete)
#   - .devflow/.gitignore             scoped ignore for ephemeral tmp/ scratch
#                                     (created if absent; keeps config.json +
#                                     learnings/ committed)
#
# Why vendored (not a github marketplace): in the claude-code-action runner the
# bash sandbox can't reach ~/.claude and CLAUDE_SKILL_DIR is unset, so the plugin
# SCRIPTS must live in the workspace. (Local editor use should instead add the
# github marketplace with autoUpdate — see docs/cloud-setup.md.)
#
# Usage, from the root of your repo:
#   curl -fsSL https://raw.githubusercontent.com/The01Geek/devflow-autopilot/main/install.sh | bash
#   # pin a version / point at a fork:
#   DEVFLOW_REF=v1.2.0 DEVFLOW_REPO=The01Geek/devflow-autopilot bash install.sh
# ============================================================================
set -euo pipefail

REPO="${DEVFLOW_REPO:-The01Geek/devflow-autopilot}"
REF="${DEVFLOW_REF:-main}"

log() { printf 'devflow-install: %s\n' "$1"; }
die() { printf 'devflow-install: %s\n' "$1" >&2; exit 1; }

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

# 1. Vendor the plugin into the workspace (CI needs the scripts here).
log "vendoring plugin → .claude/plugins/devflow/"
rm -rf .claude/plugins/devflow
mkdir -p .claude/plugins/devflow
cp -R "$SRC/.claude-plugin" "$SRC/agents" "$SRC/lib" "$SRC/scripts" "$SRC/skills" .claude/plugins/devflow/
# Vendor ONLY the committed templates/registry (not the whole .devflow/ tree —
# that would drag in learnings/ and, from a dirty source, a live config.json).
# They let the vendored /devflow:init resolve templates at scripts/../.devflow/:
# config.example.json + config.schema.json (scaffolding) and tool-presets.json
# (the registry scripts/detect-project-tools.sh reads for language detection).
mkdir -p .claude/plugins/devflow/.devflow
cp "$SRC/.devflow/config.example.json" "$SRC/.devflow/config.schema.json" \
   "$SRC/.devflow/tool-presets.json" \
   .claude/plugins/devflow/.devflow/
# The vendored copy is a plugin, not a marketplace — keep only plugin.json.
rm -f .claude/plugins/devflow/.claude-plugin/marketplace.json
find .claude/plugins/devflow -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true

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
for w in devflow devflow-implement devflow-review; do
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

log "done (from ${REPO}@${REF}). Review with 'git status' / 'git diff' and commit."
