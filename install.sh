#!/usr/bin/env bash
# ============================================================================
# DevFlow cloud-tier installer / updater
# ============================================================================
# Installs (or updates) the DevFlow GitHub Actions "cloud tier" into the CURRENT
# repository. Idempotent — re-run any time to pull the latest from the primary
# repo. It writes:
#   - .claude-plugin/marketplace.json local marketplace pointing at the plugin
#   - .github/workflows/*.yml         devflow.yml / devflow-implement.yml
#                                     (superseded claude*.yml are removed on upgrade,
#                                     Anthropic's left)
#   - .github/actions/*               the composite actions they use
#   - .devflow/install-manifest.json  the provenance digests the upgrade path reads
#                                     to tell an untouched artifact from a hand-edited
#                                     one (see UPGRADING below)
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
# UPGRADING an existing installation (issue: consumer upgrade path)
# ----------------------------------------------------------------
# A repository that already carries a DevFlow installation is an UPGRADE, and an
# upgrade is DRY-RUN BY DEFAULT: the installer prints the full plan and a unified
# diff of every byte it would change, and writes nothing until you re-run it with
# `--apply`. This mirrors the consent-gated provisioners (`provision-auto-mode.sh`,
# `provision-local-settings.sh`, `provision-python3-shim.sh`): no file is touched
# without an explicit opt-in. A FIRST-TIME install (nothing of DevFlow's present)
# still applies immediately, so the documented one-liner below is unchanged.
#
# Local modifications are never silently overwritten. Each artifact the installer
# owns is recorded in `.devflow/install-manifest.json` with the sha256 of the bytes
# the installer wrote. On the next run:
#   - byte-identical to the recorded digest -> unmodified -> updated in place;
#   - different from the recorded digest    -> locally MODIFIED -> PRESERVED, and the
#                                              new version is written beside it as
#                                              `<file>.devflow-new` for you to merge;
#   - no recorded digest (an installation predating the manifest, or a skipped-version
#     jump) -> provenance UNVERIFIED -> preserved the same way, unless the bytes already
#     equal the new version, in which case nothing changes and the digest is recorded;
#   - absent (you deleted it) -> recreated.
# `.devflow/config.json` is never rewritten by this mechanism at all — the shared
# scaffolder only backfills keys the example gained.
#
# Usage, from the root of your repo. Download-read-run is the documented form:
# fetch this file at a PINNED ref — a release tag (vN.N.N), or a commit
# SHA; never mutable main — read it, then run the copy you read. docs/install.md
# carries the current pinned one-liner; docs/cloud-setup.md the full guide.
#   curl -fsSL https://raw.githubusercontent.com/The01Geek/devflow-autopilot/<ref>/install.sh -o devflow-install.sh
#   DEVFLOW_REF=<ref> bash devflow-install.sh
#   # point at a fork (DEVFLOW_REF defaults to main, so pin it too):
#   DEVFLOW_REF=<ref> DEVFLOW_REPO=<owner>/<repo> bash devflow-install.sh
#   # commit the plugin tree instead of fetching it at runtime:
#   DEVFLOW_VENDOR=1 bash devflow-install.sh
#   # upgrade an existing installation: preview first, then apply
#   DEVFLOW_REF=<ref> bash devflow-install.sh            # dry run, writes nothing
#   DEVFLOW_REF=<ref> bash devflow-install.sh --apply
#
# Flags (also settable as env vars, for a `curl | bash` invocation that cannot pass
# arguments):
#   --dry-run   / DEVFLOW_DRY_RUN=1  force the preview even on a first-time install
#   --apply     / DEVFLOW_APPLY=1    write the changes (required to upgrade)
#   --remove-withheld-review-tier / DEVFLOW_REMOVE_WITHHELD_REVIEW_TIER=1
#               opt in to removing the withheld automatic-review tier this repository
#               installed before it was withheld (see the report the installer prints)
# ============================================================================
set -euo pipefail

REPO="${DEVFLOW_REPO:-The01Geek/devflow-autopilot}"
REF="${DEVFLOW_REF:-main}"

# Argument parsing lives in the installer BODY (below the DEVFLOW_SELFTEST return),
# never here: this file is also SOURCED by the test harness, where `"$@"` would be
# the sourcing script's own positional parameters and an unrecognized one would abort
# the harness instead of the installer.

# The accepted plugin/marketplace identifiers, compiled from lib/plugin-identity.json +
# .claude-plugin/plugin.json. BAKED (not read at runtime) on purpose: this script is
# curl-pipeable with no repository present, and the tree it inspects below is a
# FOREIGN one. Plain assignments, never `${DEVFLOW_PLUGIN_NAME_ERE:-…}` — an
# inherited environment value must not be able to widen or narrow the prune check.
#
# The ERE is the stale-tree discriminator. The CANONICAL pair is what this installer
# writes into the local marketplace manifest, so the manifest carries no hand-spelled
# name. The SUPERSEDED lists are every accepted identifier that is not canonical —
# what a declared alias means — and drive the identifier-migration report below.
# Adding an alias to lib/plugin-identity.json and regenerating is therefore the ONLY
# edit a rename needs here.
# devflow-plugin-identity:begin identity_version=1 sha256=52916f82601e896b928b823a187514730c0006f39dc393019ab7eea11d0d0455 (generated by lib/generate-plugin-identity.py -- do not hand-edit; source: lib/plugin-identity.json + .claude-plugin/plugin.json)
DEVFLOW_PLUGIN_NAME_ERE='"name"[[:space:]]*:[[:space:]]*"(devflow)"'
DEVFLOW_PLUGIN_CANONICAL='devflow'
DEVFLOW_MARKETPLACE_CANONICAL='devflow-marketplace'
DEVFLOW_SUPERSEDED_MARKETPLACES=''
DEVFLOW_SUPERSEDED_PLUGIN_SPECS=''
# devflow-plugin-identity:end

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
  # The non-empty precondition is not decoration: `grep -Eq ""` matches ANY
  # file, so an emptied discriminator would turn this identity check into an
  # unconditional `rm -rf`. Fail closed on an unestablished set.
  if [ -n "$DEVFLOW_PLUGIN_NAME_ERE" ] \
     && [ -f "$old/.claude-plugin/plugin.json" ] \
     && grep -Eq "$DEVFLOW_PLUGIN_NAME_ERE" "$old/.claude-plugin/plugin.json"; then
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

# ============================================================================
# Upgrade machinery: provenance, non-clobbering installs, and the dry-run preview
# ============================================================================
#
# Every artifact this installer OWNS is recorded in .devflow/install-manifest.json
# as a sha256 of the bytes the installer wrote. That digest is the only thing that
# can distinguish "the consumer never touched this" from "the consumer hand-edited
# this", and consumers DO hand-edit their workflows. Without it an upgrade is a
# `cp` that silently destroys local work; with it, an artifact whose current bytes
# do not match its recorded digest is preserved and the new version is written
# beside it for a human merge.
#
# The digests are computed with python3 (hashlib) — a hard DevFlow prerequisite,
# and the same choice scripts/install-gh-wrapper.sh makes — never sha256sum/shasum,
# which lib/preflight.sh does not guarantee: a value that decides whether a file is
# overwritten must not be derived through a non-preflight PATH tool. When python3
# is absent the provenance layer cannot be established at all, so it FAILS SAFE:
# nothing existing is overwritten, every present artifact reports `unverified`, and
# the manifest is not written. `unknown` is never collapsed onto `unmodified`.
DEVFLOW_PY=""
devflow_resolve_python() {
  if [ -n "$DEVFLOW_PY" ]; then return 0; fi
  if command -v python3 >/dev/null 2>&1 && python3 -c 'pass' >/dev/null 2>&1; then
    DEVFLOW_PY=python3
  fi
  [ -n "$DEVFLOW_PY" ]
}

# Digest one path (file or directory) as this installer defines identity. A
# directory digests as the sha256 over its sorted relative-path + per-file-digest
# pairs, so a renamed, added, or removed file inside a composite action changes the
# digest exactly like an edited one. Prints the empty string for an absent path.
DEVFLOW_DIGEST_PY='
import hashlib, os, sys
p = sys.argv[1]
def filedig(fp):
    h = hashlib.sha256()
    with open(fp, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()
if os.path.isdir(p):
    h = hashlib.sha256()
    entries = []
    for root, dirs, files in os.walk(p):
        dirs.sort()
        for f in sorted(files):
            fp = os.path.join(root, f)
            entries.append((os.path.relpath(fp, p).replace(os.sep, "/"), filedig(fp)))
    for rel, d in sorted(entries):
        h.update(rel.encode("utf-8")); h.update(b"\0")
        h.update(d.encode("ascii")); h.update(b"\0")
    sys.stdout.write(h.hexdigest())
elif os.path.exists(p):
    sys.stdout.write(filedig(p))
'
devflow_digest() {
  devflow_resolve_python || { printf ''; return 0; }
  "$DEVFLOW_PY" -c "$DEVFLOW_DIGEST_PY" "$1" 2>/dev/null || printf ''
}

# The recorded digest for one artifact, or the empty string when the manifest is
# absent, unreadable, malformed, or simply has no entry. Every one of those is
# "provenance unestablished", which the caller must treat as unverified — never as
# a match. The manifest is a file a human can hand-corrupt, so every shape defect
# degrades to the empty string rather than aborting the installer.
DEVFLOW_MANIFEST_READ_PY='
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
if not isinstance(data, dict):
    sys.exit(0)
arts = data.get("artifacts")
if not isinstance(arts, dict):
    sys.exit(0)
val = arts.get(sys.argv[2])
if isinstance(val, str):
    sys.stdout.write(val)
'
DEVFLOW_MANIFEST_PATH=".devflow/install-manifest.json"
devflow_recorded_digest() {
  devflow_resolve_python || { printf ''; return 0; }
  [ -f "$DEVFLOW_MANIFEST_PATH" ] || { printf ''; return 0; }
  "$DEVFLOW_PY" -c "$DEVFLOW_MANIFEST_READ_PY" "$DEVFLOW_MANIFEST_PATH" "$1" 2>/dev/null || printf ''
}

# Classify one artifact. Run with the target repo root as the working directory.
#   create      the consumer does not have it (fresh install, or they deleted it)
#   unchanged   already byte-identical to what we would write
#   update      unmodified since we wrote it -> safe to replace
#   modified    hand-edited since we wrote it -> PRESERVE
#   unverified  no provenance on record -> PRESERVE (fail safe)
devflow_artifact_action() {
  local rel="$1" srcp="$2" cur new rec
  cur="$(devflow_digest "$rel")"
  [ -n "$cur" ] || { printf 'create'; return 0; }
  new="$(devflow_digest "$srcp")"
  if [ -n "$new" ] && [ "$cur" = "$new" ]; then printf 'unchanged'; return 0; fi
  rec="$(devflow_recorded_digest "$rel")"
  if [ -z "$rec" ]; then printf 'unverified'; return 0; fi
  if [ "$cur" = "$rec" ]; then printf 'update'; else printf 'modified'; fi
}

# Install one owned artifact, honoring the classification above. Never overwrites a
# `modified` / `unverified` artifact: the new bytes go to `<path>.devflow-new` and the
# consumer is told to merge. Accumulates the artifacts whose digest the manifest should
# record — a preserved one is deliberately NOT recorded, so the conflict is reported
# again on every run until the consumer resolves it.
DEVFLOW_RECORD_RELS=""
install_managed() {
  local rel="$1" srcp="$2" act parent
  [ -e "$srcp" ] || return 0
  act="$(devflow_artifact_action "$rel" "$srcp")"
  parent="${rel%/*}"
  case "$act" in
    unchanged)
      log "unchanged: $rel"
      DEVFLOW_RECORD_RELS="$DEVFLOW_RECORD_RELS $rel"
      ;;
    create|update)
      [ "$parent" = "$rel" ] || mkdir -p "$parent"
      if [ -d "$srcp" ]; then rm -rf "$rel"; cp -R "$srcp" "$rel"; else cp "$srcp" "$rel"; fi
      log "$act: $rel"
      DEVFLOW_RECORD_RELS="$DEVFLOW_RECORD_RELS $rel"
      ;;
    modified|unverified)
      rm -rf "$rel.devflow-new"
      if [ -d "$srcp" ]; then cp -R "$srcp" "$rel.devflow-new"; else cp "$srcp" "$rel.devflow-new"; fi
      if [ "$act" = modified ]; then
        log "PRESERVED (locally modified since DevFlow wrote it): $rel — the new version is at $rel.devflow-new; merge it by hand."
      else
        log "PRESERVED (provenance unverified — no recorded digest, so a local edit cannot be ruled out): $rel — the new version is at $rel.devflow-new; merge it by hand, or delete $rel and re-run to take DevFlow's copy."
      fi
      ;;
  esac
}

# Write the provenance manifest for the artifacts installed on this run. Merges into
# any existing manifest so a preserved artifact keeps its previous digest instead of
# being silently re-blessed. Best-effort: a failure warns and never aborts the install
# (a missing manifest degrades the NEXT run to `unverified`, which is the safe arm).
DEVFLOW_MANIFEST_WRITE_PY='
import hashlib, json, os, sys
path, version, ref = sys.argv[1], sys.argv[2], sys.argv[3]
rels = [r for r in sys.argv[4:] if r]
def filedig(fp):
    h = hashlib.sha256()
    with open(fp, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()
def digest(p):
    if os.path.isdir(p):
        h = hashlib.sha256()
        entries = []
        for root, dirs, files in os.walk(p):
            dirs.sort()
            for f in sorted(files):
                fp = os.path.join(root, f)
                entries.append((os.path.relpath(fp, p).replace(os.sep, "/"), filedig(fp)))
        for rel, d in sorted(entries):
            h.update(rel.encode("utf-8")); h.update(b"\0")
            h.update(d.encode("ascii")); h.update(b"\0")
        return h.hexdigest()
    if os.path.exists(p):
        return filedig(p)
    return None
data = {}
try:
    with open(path, encoding="utf-8") as fh:
        loaded = json.load(fh)
    if isinstance(loaded, dict):
        data = loaded
except Exception:
    data = {}
arts = data.get("artifacts")
if not isinstance(arts, dict):
    arts = {}
for rel in rels:
    d = digest(rel)
    if d is not None:
        arts[rel] = d
out = {
    "manifest_version": 1,
    "devflow_version": version,
    "installed_from_ref": ref,
    "artifacts": dict(sorted(arts.items())),
}
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(out, fh, indent=2, sort_keys=True)
    fh.write("\n")
os.replace(tmp, path)
'
devflow_write_manifest() {
  local version="$1" ref="$2"
  if ! devflow_resolve_python; then
    log "warning: no working python3 — the install provenance manifest ($DEVFLOW_MANIFEST_PATH) was not written, so the next upgrade cannot tell an untouched artifact from a hand-edited one and will preserve everything it finds."
    return 0
  fi
  # shellcheck disable=SC2086  # DEVFLOW_RECORD_RELS is a space-separated list of
  # repo-relative paths this script itself composed; word splitting is the point.
  if "$DEVFLOW_PY" -c "$DEVFLOW_MANIFEST_WRITE_PY" "$DEVFLOW_MANIFEST_PATH" "$version" "$ref" $DEVFLOW_RECORD_RELS; then
    log "recorded install provenance in $DEVFLOW_MANIFEST_PATH"
  else
    log "warning: could not write $DEVFLOW_MANIFEST_PATH; the next upgrade will preserve every existing artifact rather than update it."
  fi
}

# ── The withheld automatic-review tier ──────────────────────────────────────
# The pull-request-triggered review tier is withheld from this release (issue #936)
# and this installer ships none of its three files. A repository that installed it
# BEFORE the withholding still has them, still runs them, and stays exposed to issues
# #930 and #920 — so an upgrade must SAY SO. It must not delete them silently: that
# tier is a required status check in the repositories that adopted it, and removing
# the workflow while a branch protection rule still requires its context wedges every
# subsequent pull request behind a check nothing will report. Removal is therefore an
# explicit opt-in, and even then step 3 of docs/workflow-triggers.md (the branch
# protection context) stays a human action this installer cannot perform.
DEVFLOW_WITHHELD_TIER="devflow-review devflow-runner telemetry-push"
devflow_withheld_tier_present() {
  local _wt found=""
  # `_wt`, not `w`: `for w in …` is the shape lib/test/run.sh parses out of this file to
  # derive the SHIPPED workflow set, and a second loop over that variable name upstream of
  # the copy loop would be the one it found.
  for _wt in $DEVFLOW_WITHHELD_TIER; do
    [ -f ".github/workflows/$_wt.yml" ] && found="$found $_wt"
  done
  printf '%s' "${found# }"
}
devflow_report_withheld_tier() {
  local present="$1"
  [ -n "$present" ] || return 0
  log "NOTICE: this repository carries the withheld automatic-review tier ($present). It is not shipped any more (issue #936) and this installer leaves it alone by default, but it keeps running and keeps this repository exposed to issues #930 and #920 for as long as workflows[\"devflow-review\"] is true in .devflow/config.json. See docs/workflow-triggers.md."
  if [ "${REMOVE_WITHHELD:-}" = "1" ]; then
    log "  --remove-withheld-review-tier was given: the workflow files will be deleted and workflows[\"devflow-review\"] set to false. You must ALSO remove the 'Devflow Review' context from any branch protection rule or ruleset that requires it — otherwise every later pull request wedges against a required check nothing will report. This installer cannot do that for you."
  else
    log "  To remove it, re-run with --remove-withheld-review-tier (and read step 3 of docs/workflow-triggers.md first — the branch protection context is a manual step)."
  fi
}
# Turn off the config key the withheld tier reads. Best-effort and shape-guarded: a
# config that is not a JSON object, or that has a non-object `workflows`, is left
# untouched with a breadcrumb rather than being restructured underneath the consumer.
DEVFLOW_DISABLE_REVIEW_PY='
import json, os, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
if not isinstance(data, dict):
    sys.exit(3)
wf = data.get("workflows")
if wf is None:
    wf = {}
if not isinstance(wf, dict):
    sys.exit(3)
if wf.get("devflow-review") is False:
    sys.exit(4)
wf["devflow-review"] = False
data["workflows"] = wf
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
os.replace(tmp, path)
'
devflow_remove_withheld_tier() {
  local present="$1" _wt rc
  [ -n "$present" ] || return 0
  [ "${REMOVE_WITHHELD:-}" = "1" ] || return 0
  for _wt in $present; do
    # Signature-guarded exactly like prune_stale_devflow_workflows: only ever remove a
    # workflow that is recognizably DevFlow's, so a consumer file that merely happens to
    # share one of these names is never deleted.
    if grep -qi 'devflow' ".github/workflows/$_wt.yml"; then
      rm -f ".github/workflows/$_wt.yml"
      log "removed withheld review-tier workflow $_wt.yml (opted in via --remove-withheld-review-tier)"
    else
      log "warning: .github/workflows/$_wt.yml carries no DevFlow signature; left it untouched — it does not look like DevFlow's copy."
    fi
  done
  if [ ! -f .devflow/config.json ]; then
    return 0
  fi
  if ! devflow_resolve_python; then
    log "warning: no working python3 — could not set workflows[\"devflow-review\"] to false in .devflow/config.json; do it by hand."
    return 0
  fi
  rc=0
  "$DEVFLOW_PY" -c "$DEVFLOW_DISABLE_REVIEW_PY" .devflow/config.json 2>/dev/null || rc=$?
  case "$rc" in
    0) log "set workflows[\"devflow-review\"]=false in .devflow/config.json" ;;
    4) log "workflows[\"devflow-review\"] is already false in .devflow/config.json" ;;
    *) log "warning: could not set workflows[\"devflow-review\"] to false in .devflow/config.json (it is missing, malformed, or holds a non-object at that key); set it by hand." ;;
  esac
}

# ── Identifier migration ────────────────────────────────────────────────────
# When the published plugin/marketplace identifier changes, the previous id is declared
# as an alias in lib/plugin-identity.json and every accepted-but-not-canonical id becomes
# SUPERSEDED. The artifacts this installer owns are rewritten to the canonical id by the
# ordinary managed-artifact path above (the marketplace manifest is composed from the
# baked canonical pair, so a rename changes its bytes and the upgrade reports it).
#
# The consumer file this installer must NOT write is `.claude/settings.json`: keeping the
# cloud-only installer out of the local-tier settings is a standing invariant (issue #88),
# and `scripts/provision-local-settings.sh` already OWNS that migration — since PR #943 it
# removes every superseded marketplace entry and enabledPlugins spec on the next
# `/devflow:init`. So the installer DETECTS and REPORTS, and routes the consumer to the one
# provisioner rather than growing a second, drifting copy of the same removal.
DEVFLOW_SETTINGS_SCAN_PY='
import json, sys
path = sys.argv[1]
markets = [m for m in sys.argv[2].split() if m]
specs = [s for s in sys.argv[3].split() if s]
try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
if not isinstance(data, dict):
    sys.exit(0)
hits = []
container = data.get("extraKnownMarketplaces")
if isinstance(container, dict):
    hits += ["extraKnownMarketplaces[" + m + "]" for m in markets if m in container]
container = data.get("enabledPlugins")
if isinstance(container, dict):
    hits += ["enabledPlugins[" + s + "]" for s in specs if s in container]
if hits:
    sys.stdout.write(", ".join(hits))
'
devflow_report_superseded_identifiers() {
  local hits
  # No alias declared -> nothing is superseded -> strict no-op, and no python3 is spent.
  [ -n "$DEVFLOW_SUPERSEDED_MARKETPLACES$DEVFLOW_SUPERSEDED_PLUGIN_SPECS" ] || return 0
  [ -f .claude/settings.json ] || return 0
  devflow_resolve_python || {
    log "warning: no working python3 — could not check .claude/settings.json for superseded DevFlow registrations; run /devflow:init to migrate them."
    return 0
  }
  hits="$("$DEVFLOW_PY" -c "$DEVFLOW_SETTINGS_SCAN_PY" .claude/settings.json \
      "$DEVFLOW_SUPERSEDED_MARKETPLACES" "$DEVFLOW_SUPERSEDED_PLUGIN_SPECS" 2>/dev/null || printf '')"
  [ -n "$hits" ] || return 0
  log "NOTICE: .claude/settings.json still registers superseded DevFlow identifiers ($hits). This installer never writes that file — run /devflow:init, whose scripts/provision-local-settings.sh removes the superseded registrations and adds the current one."
}

# ── The dry-run preview ─────────────────────────────────────────────────────
# The preview is not a second implementation of the plan: it runs the REAL apply
# function against a sandbox copy of the consumer's own tree and then diffs the
# sandbox against the tree. Anything --apply would do, the preview did — to a copy.
#
# The diff is rendered with python3 difflib rather than `diff -u`: `diff` is not one
# of the tools lib/preflight.sh guarantees, and a silently-absent one would print an
# empty (i.e. reassuring) preview.
DEVFLOW_DIFF_PY='
import difflib, os, sys
real, prev = sys.argv[1], sys.argv[2]
scopes = sys.argv[3:]
SKIP = (".devflow/vendor",)
def walk(base):
    out = {}
    for scope in scopes:
        root = os.path.join(base, scope)
        if os.path.isfile(root):
            out[scope] = root
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames.sort()
            for name in sorted(filenames):
                fp = os.path.join(dirpath, name)
                rel = os.path.relpath(fp, base).replace(os.sep, "/")
                if any(rel == s or rel.startswith(s + "/") for s in SKIP):
                    continue
                out[rel] = fp
    return out
a, b = walk(real), walk(prev)
def text(fp):
    try:
        with open(fp, encoding="utf-8") as fh:
            return fh.read().splitlines(keepends=True)
    except (UnicodeDecodeError, OSError):
        return None
changed = 0
for rel in sorted(set(a) | set(b)):
    # A file that exists on only ONE side is an add or a delete, and its whole body is
    # not a diff a reader needs: report it as one line with its size. Only a file that
    # exists on BOTH sides gets a unified diff, which is the case where the bytes that
    # changed are the thing to inspect.
    if rel not in b:
        changed += 1
        sys.stdout.write("DELETE " + rel + "\n")
        continue
    if rel not in a:
        body = text(b[rel])
        size = "binary" if body is None else str(len(body)) + " lines"
        changed += 1
        sys.stdout.write("ADD    " + rel + " (" + size + ")\n")
        continue
    left, right = text(a[rel]), text(b[rel])
    if left is None or right is None:
        # A binary artifact on both sides: compare bytes, and never try to diff them.
        with open(a[rel], "rb") as fh1, open(b[rel], "rb") as fh2:
            if fh1.read() != fh2.read():
                changed += 1
                sys.stdout.write("MODIFY " + rel + " (binary)\n")
        continue
    if left == right:
        continue
    changed += 1
    sys.stdout.write("MODIFY " + rel + "\n")
    for line in difflib.unified_diff(left, right, fromfile="a/" + rel, tofile="b/" + rel):
        sys.stdout.write(line if line.endswith("\n") else line + "\n")
sys.stdout.write("devflow-install: " + str(changed) + " file(s) would change.\n")
'
# The subtrees the preview copies and diffs. `.devflow/vendor` is excluded from the
# diff body (a DEVFLOW_VENDOR=1 tree is thousands of files and its churn is reported
# as one line by the apply log instead), and only the two `.claude/` paths this
# installer READS are copied — never the consumer's wider `.claude/`.
DEVFLOW_PREVIEW_SCOPES=".claude-plugin .github .devflow"

devflow_render_preview() {
  local real="$1" prev="$2"
  if ! devflow_resolve_python; then
    log "warning: no working python3 — cannot render the dry-run diff. The plan lines above are the whole preview."
    return 0
  fi
  # shellcheck disable=SC2086  # DEVFLOW_PREVIEW_SCOPES is a fixed, space-separated
  # literal this script owns; word splitting into separate arguments is intended.
  "$DEVFLOW_PY" -c "$DEVFLOW_DIFF_PY" "$real" "$prev" $DEVFLOW_PREVIEW_SCOPES
}

# Materialize the sandbox: a copy of the consumer subtrees the apply path reads or
# writes. Missing subtrees are simply absent in the copy, which is exactly what the
# apply path would see. `.devflow/vendor` is skipped — the apply path recreates it
# from $SRC when DEVFLOW_VENDOR=1 and never reads the existing one.
devflow_build_preview() {
  local real="$1" prev="$2" d
  mkdir -p "$prev"
  for d in .claude-plugin .github; do
    [ -e "$real/$d" ] && cp -R "$real/$d" "$prev/$d"
  done
  if [ -d "$real/.devflow" ]; then
    mkdir -p "$prev/.devflow"
    for d in "$real"/.devflow/*; do
      [ -e "$d" ] || continue
      case "${d##*/}" in vendor) continue ;; esac
      cp -R "$d" "$prev/.devflow/"
    done
    [ -f "$real/.devflow/.gitignore" ] && cp "$real/.devflow/.gitignore" "$prev/.devflow/.gitignore"
  fi
  if [ -e "$real/.claude/plugins" ]; then
    mkdir -p "$prev/.claude"
    cp -R "$real/.claude/plugins" "$prev/.claude/plugins"
  fi
  if [ -f "$real/.claude/settings.json" ]; then
    mkdir -p "$prev/.claude"
    cp "$real/.claude/settings.json" "$prev/.claude/settings.json"
  fi
}

# ── The one apply path ──────────────────────────────────────────────────────
# Every write this installer performs happens here, and the dry run performs it too —
# against a sandbox. A SUBSHELL function, so the `cd` cannot move the resolution base
# of anything outside it and every path below stays the repo-relative literal it has
# always been.
devflow_apply_all() (
  cd "$1" || die "could not enter $1"
  local pin="$2" ref="$3" withheld

  # 1. Plugin tree. Thin by default — the vendor-plugin composite action puts it
  #    in the workspace at runtime, so it need not be committed. DEVFLOW_VENDOR=1
  #    commits it instead (self-hosting). Both paths copy through the ONE shared
  #    slice definition, so the file set can never drift between installer and CI.
  if [ "${DEVFLOW_VENDOR:-}" = "1" ]; then
    log "vendoring plugin → .devflow/vendor/devflow/ (DEVFLOW_VENDOR=1)"
    devflow_copy_slice "$SRC" ".devflow/vendor/devflow"
  else
    log "thin install: the plugin is fetched at runtime (set DEVFLOW_VENDOR=1 to commit it instead)"
  fi

  # Upgrade migration: remove a stale committed tree at the old .claude/plugins/devflow
  # location (relocated to .devflow/vendor/devflow). Runs for both install modes.
  prune_stale_vendored_plugin

  # 2. Root marketplace manifest so `plugin_marketplaces: ./` resolves the vendored
  #    plugin. Composed from the BAKED canonical identifiers, never hand-spelled, so a
  #    declared rename reaches it without this heredoc being re-edited. Rendered to a
  #    temp file and installed through the managed-artifact path, so a consumer who
  #    added their own plugin entry to it is not silently overwritten.
  log "composing .claude-plugin/marketplace.json"
  cat > "$TMP/marketplace.json" <<JSON
{
  "\$schema": "https://anthropic.com/claude-code/marketplace.schema.json",
  "name": "$DEVFLOW_MARKETPLACE_CANONICAL",
  "description": "Local marketplace for the vendored DevFlow plugin (.devflow/vendor/devflow). Installed by devflow-autopilot/install.sh.",
  "owner": { "name": "Daniel Radman", "email": "daniel@radman.ai" },
  "allowCrossMarketplaceDependenciesOn": [],
  "plugins": [
    {
      "name": "$DEVFLOW_PLUGIN_CANONICAL",
      "source": "./.devflow/vendor/devflow",
      "description": "End-to-end dev workflow: /devflow:implement, /devflow:review + /devflow:review-and-fix, the /devflow:docs suite, /devflow:create-issue, plus the retrospective loop.",
      "author": { "name": "Daniel Radman", "email": "daniel@radman.ai" },
      "homepage": "https://github.com/The01Geek/devflow-autopilot",
      "category": "development"
    }
  ]
}
JSON
  mkdir -p .claude-plugin
  install_managed ".claude-plugin/marketplace.json" "$TMP/marketplace.json"

  # 2b. Prompt-extension directory. Created empty so a maintainer who wants to extend a
  # skill has somewhere to commit the file without hand-creating the path, and so the
  # review job's unconditional truncation step (issue #874) has a directory to write
  # into on a fresh consumer. That step creates the directory itself as well — this is
  # a convenience for the human, not the workflow's guarantee, which cannot depend on
  # install.sh having run.
  log "creating .devflow/prompt-extensions"
  mkdir -p .devflow/prompt-extensions

  # 3. Workflows (only those the primary repo actually ships).
  #
  # The automatic pull-request-triggered review tier is WITHHELD from this release
  # (issue #936) and is therefore not installed: none of devflow-review.yml,
  # devflow-runner.yml or telemetry-push.yml is copied. That tier triggered on
  # pull-request events, called a reusable workflow with `secrets: inherit`, checked
  # out the pull-request head, and carried no actor-authorization gate; issues #930
  # and #920 describe the open defects. The supported review path is a repository
  # collaborator commenting `/devflow:review` on a pull request, which devflow.yml
  # authorizes through scripts/authorize-actor.sh.
  #
  # A repository that already installed those three files KEEPS them —
  # prune_stale_devflow_workflows() is deliberately not extended to remove them, so
  # an existing installation's auto-review keeps working (and stays exposed to #930
  # and #920 while its `workflows["devflow-review"]` config key is true). The upgrade
  # path SURFACES that exposure (devflow_report_withheld_tier) and removes the tier
  # only on the explicit --remove-withheld-review-tier opt-in; docs/workflow-triggers.md
  # gives the full procedure, including the branch-protection step no installer can do.
  log "installing workflows + composite actions"
  mkdir -p .github/workflows .github/actions
  for w in devflow devflow-implement; do
    [ -f "$SRC/.github/workflows/$w.yml" ] && install_managed ".github/workflows/$w.yml" "$SRC/.github/workflows/$w.yml"
  done
  # Drop DevFlow's superseded claude*.yml on upgrade (signature-guarded so an
  # Anthropic-owned claude.yml is never touched).
  prune_stale_devflow_workflows
  # The withheld auto-review tier: reported always, removed only on the opt-in.
  withheld="$(devflow_withheld_tier_present)"
  devflow_report_withheld_tier "$withheld"
  devflow_remove_withheld_tier "$withheld"

  # 4. Composite actions. vendor-plugin is REQUIRED even for a thin install — the
  #    workflows reference `./.github/actions/vendor-plugin` to materialize the
  #    plugin at runtime, so it (unlike the plugin tree) must always be committed.
  for a in read-project-config setup-project-env vendor-plugin; do
    if [ -d "$SRC/.github/actions/$a" ]; then
      install_managed ".github/actions/$a" "$SRC/.github/actions/$a"
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
  #    SHA.
  set_config_version ".devflow/config.json" "$pin"

  # 7. Record what we installed, so the NEXT upgrade can tell an untouched artifact
  #    from a hand-edited one instead of clobbering both alike.
  devflow_write_manifest "$pin" "$ref"

  # 8. Report (never rewrite) a consumer settings file still carrying a superseded
  #    plugin/marketplace identifier.
  devflow_report_superseded_identifiers
)

# When sourced by the test harness (DEVFLOW_SELFTEST=1), define the functions
# above and stop — the installer body below (which clones + writes files) does
# not run. `return` only executes on the sourced path; `|| true` keeps `set -e`
# happy on the unlikely executed-with-the-flag path.
if [ "${DEVFLOW_SELFTEST:-}" = "1" ]; then return 0 2>/dev/null || true; fi

# ── Installer body ──────────────────────────────────────────────────────────
# Argument parsing lives HERE, below the DEVFLOW_SELFTEST return: sourced by the test
# harness, `"$@"` would be the sourcing script's own positional parameters.
DEVFLOW_MODE_REQUEST=""            # "", dry-run, or apply
REMOVE_WITHHELD="${DEVFLOW_REMOVE_WITHHELD_REVIEW_TIER:-}"
[ "${DEVFLOW_DRY_RUN:-}" = "1" ] && DEVFLOW_MODE_REQUEST=dry-run
[ "${DEVFLOW_APPLY:-}" = "1" ] && DEVFLOW_MODE_REQUEST=apply
for _arg in "$@"; do
  case "$_arg" in
    --dry-run) DEVFLOW_MODE_REQUEST=dry-run ;;
    --apply) DEVFLOW_MODE_REQUEST=apply ;;
    --remove-withheld-review-tier) REMOVE_WITHHELD=1 ;;
    *)
      # A typo must not silently select the writing mode. `--dryrun` is not `--dry-run`.
      printf 'devflow-install: unknown argument %s (accepted: --dry-run, --apply, --remove-withheld-review-tier)\n' "$_arg" >&2
      exit 2
      ;;
  esac
done

command -v git >/dev/null 2>&1 || die "git is required."
[ -d .git ] || die "run this from the root of a git repository."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The source tree. DEVFLOW_SRC points at an already-materialized plugin tree and skips
# the clone entirely — the offline seam the test suite (network-free, gh-stubbed) drives
# real end-to-end upgrades through, and the same escape hatch for an air-gapped install.
if [ -n "${DEVFLOW_SRC:-}" ]; then
  [ -d "$DEVFLOW_SRC" ] || die "DEVFLOW_SRC is set to '$DEVFLOW_SRC' but that is not a directory."
  SRC="$DEVFLOW_SRC"
  log "using the pre-materialized source tree at $SRC (DEVFLOW_SRC; no clone)"
else
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
fi

# The ONE shared slice definition, sourced so the installer and CI can never disagree
# about which files are the plugin.
# shellcheck source=.github/actions/vendor-plugin/vendor-slice.sh
DEVFLOW_VENDOR_SOURCE=1 . "$SRC/.github/actions/vendor-plugin/vendor-slice.sh"

# Pin devflow_version to the exact commit we installed from, so the runtime fetch is
# reproducible and never tracks mutable main. The clone+checkout above gives $SRC a
# resolvable HEAD, so this essentially always yields a SHA; only a broken clone (or a
# DEVFLOW_SRC tree that is not a git repository) falls back to $REF — warn there, since
# $REF may be a mutable branch (the very thing the pin exists to avoid).
if PIN="$(git -C "$SRC" rev-parse HEAD 2>/dev/null)"; then :; else
  PIN="$REF"
  log "warning: could not resolve the installed commit SHA; pinning devflow_version=$PIN (if that is a mutable branch, set it to a tag or SHA by hand to freeze the runtime fetch)."
fi

# ── First install vs UPGRADE, and therefore apply vs dry-run ────────────────
# An UPGRADE is any repository already carrying something this installer owns. The
# predicate is deliberately a union over the artifacts, not a manifest lookup: an
# installation that predates the manifest, or one whose manifest a consumer deleted,
# is still an upgrade and must not be treated as a green field.
#
# A first install APPLIES (the documented one-liner is unchanged and there is nothing to
# destroy). An upgrade is DRY-RUN BY DEFAULT and needs --apply, because there is.
DEVFLOW_INSTALL_STATE="a first-time"
for _probe in .devflow/config.json .claude-plugin/marketplace.json \
              .github/workflows/devflow.yml .github/workflows/devflow-implement.yml \
              "$DEVFLOW_MANIFEST_PATH"; do
  if [ -e "$_probe" ]; then DEVFLOW_INSTALL_STATE="an existing"; break; fi
done
case "$DEVFLOW_INSTALL_STATE:$DEVFLOW_MODE_REQUEST" in
  *:apply)            MODE=apply ;;
  *:dry-run)          MODE=dry-run ;;
  "a first-time:")    MODE=apply ;;
  *)                  MODE=dry-run ;;
esac
log "detected ${DEVFLOW_INSTALL_STATE} installation; running in ${MODE} mode."

if [ "$MODE" = dry-run ]; then
  # The preview runs the REAL apply path against a sandbox copy of this repository, then
  # diffs the sandbox against it. There is no second implementation of the plan to drift.
  PREVIEW="$TMP/preview"
  devflow_build_preview "$PWD" "$PREVIEW"
  log "───── dry run: the plan ─────"
  devflow_apply_all "$PREVIEW" "$PIN" "$REF"
  log "───── dry run: the diff ─────"
  devflow_render_preview "$PWD" "$PREVIEW"
  log "DRY RUN — nothing in this repository was written. Re-run with --apply to make the changes above."
  exit 0
fi

devflow_apply_all "$PWD" "$PIN" "$REF"

# On a host with no `python3` (stock Windows / Git-Bash), offer the consent-gated shim
# provisioner so the toolchain can resolve a Python 3 interpreter. No-op where python3
# works, and never run under a dry run (it is an interactive offer, not a plan step).
offer_python3_shim "$SRC"

log "done (from ${REPO}@${REF}). Review with 'git status' / 'git diff' and commit."
