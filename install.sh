#!/usr/bin/env bash
# ============================================================================
# DevFlow cloud-tier installer / updater
# ============================================================================
# Installs (or updates) the DevFlow GitHub Actions "cloud tier" into the CURRENT
# repository. Idempotent — re-run any time to pull the latest from the primary
# repo. It writes:
#   - .claude/plugins/devflow/        the VENDORED plugin (scripts/skills/agents/lib)
#   - .claude-plugin/marketplace.json local marketplace pointing at the above
#   - .github/workflows/*.yml         the @claude / implement / review / board workflows
#   - .github/actions/*               the composite actions they use
#   - .github/project-config.yml      scaffolded from the template ONLY if absent
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
#
# Secret-name mapping (optional): the workflows reference the default secret
# names DEVFLOW_APP_ID, DEVFLOW_APP_PRIVATE_KEY, PROJECT_PAT. If your repo uses
# different names, add a `cloud_secrets:` block to .github/project-config.yml and
# this installer rewrites them on EVERY run (so updates never clobber it):
#   cloud_secrets:
#     app_id: RADMAN_AI_APP_ID
#     app_private_key: RADMAN_AI_PRIVATE_KEY
#     project_pat: DEVFLOW_PAT
# ============================================================================
set -euo pipefail

REPO="${DEVFLOW_REPO:-The01Geek/devflow-autopilot}"
REF="${DEVFLOW_REF:-main}"
CONFIG=".github/project-config.yml"

log() { printf 'devflow-install: %s\n' "$1"; }
die() { printf 'devflow-install: %s\n' "$1" >&2; exit 1; }

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
      "description": "End-to-end dev workflow: /implement, /review + /devflow:review-and-fix, the /docs suite, /create-issue, plus the retrospective loop.",
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
for w in claude claude-implement claude-runner devflow-review comment-on-draft-issues \
         move-to-in-progress sync-pr-status-to-issue close-released-items security-audit; do
  [ -f "$SRC/.github/workflows/$w.yml" ] && cp "$SRC/.github/workflows/$w.yml" ".github/workflows/$w.yml"
done

# 4. Composite actions.
for a in dedupe-pr-events get-app-token read-project-config; do
  if [ -d "$SRC/.github/actions/$a" ]; then
    rm -rf ".github/actions/$a"
    cp -R "$SRC/.github/actions/$a" ".github/actions/$a"
  fi
done

# 5. project-config scaffold — never clobber an existing one.
if [ -f "$CONFIG" ]; then
  log "keeping existing $CONFIG"
else
  cp "$SRC/.github/project-config.example.yml" "$CONFIG"
  log "scaffolded $CONFIG — fill in the YOUR_* placeholders before enabling workflows"
fi

# 6. Apply secret-name mapping from `cloud_secrets:` in project-config.yml (idempotent).
#    Minimal grep/sed parser (no yq dependency on the consumer's machine).
map_secret() {  # $1=config-key  $2=default-secret-name
  local val
  val="$(sed -n "/^cloud_secrets:/,/^[^[:space:]]/p" "$CONFIG" 2>/dev/null \
        | sed -n "s/^[[:space:]]\{1,\}$1:[[:space:]]*[\"']\{0,1\}\([A-Za-z0-9_]\{1,\}\)[\"']\{0,1\}[[:space:]]*$/\1/p" \
        | head -n1)"
  if [ -n "$val" ] && [ "$val" != "$2" ]; then
    log "secret remap: $2 → $val"
    grep -rl --include='*.yml' "$2" .github/workflows .github/actions 2>/dev/null \
      | while IFS= read -r f; do sed -i "s/\\b$2\\b/$val/g" "$f"; done
  fi
}
if [ -f "$CONFIG" ] && grep -q "^cloud_secrets:" "$CONFIG" 2>/dev/null; then
  map_secret app_id           DEVFLOW_APP_ID
  map_secret app_private_key  DEVFLOW_APP_PRIVATE_KEY
  map_secret project_pat      PROJECT_PAT
fi

log "done (from ${REPO}@${REF}). Review with 'git status' / 'git diff' and commit."
