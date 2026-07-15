#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# resolve-extra-plugins.sh — emit the extra plugin/marketplace entries a repo's
# .claude/settings.json declares, for the cloud-tier plugin-parity compose (issue #505).
#
# The three claude-code-action call sites bake a fixed plugin/marketplace baseline.
# This helper appends what the repo's trusted-ref .claude/settings.json additionally
# declares (enabledPlugins=true entries; github-kind extraKnownMarketplaces), so a
# consumer repo's cloud plugin surface matches what its local team already sees —
# "commit the settings file once, every tier honors it."
#
# Usage: resolve-extra-plugins.sh <mode> <settings-path>
#   mode           "plugins" or "marketplaces"
#   settings-path  path to a .claude/settings.json — the default-branch checkout copy
#                  on the write tiers; the trusted base-ref materialized copy on the
#                  review tier (never the PR-head checkout's settings file).
#
# Emits zero or more entries, one per line, on stdout. ALWAYS exits 0: a degraded
# input shape emits a specific stderr breadcrumb naming the defect and emits nothing,
# so the composing step proceeds with the baked baseline. An ABSENT settings file is
# the normal consumer case — empty stdout, exit 0, NO breadcrumb (the compose then
# equals the baked baseline exactly, silently).
#
# Every value that decides what is emitted is derived via python3 (preflight-
# guaranteed — lib/preflight.sh requires python3 >= 3.11), never via tr/sed/wc/cut/head
# (guard-class 2: a value that decides an emitted result must not depend on a non-
# preflight PATH tool). Mirrors scripts/config-get.sh's direct-python3 + stdlib-json
# pattern (no jq, no resolve-python.sh). Data crosses the bash->python boundary via
# env vars (DEVFLOW_MODE/DEVFLOW_SETTINGS), not argv, so a settings path containing
# quotes/backticks/$ never traverses shell quoting.
#
# plugins mode — emits the enabledPlugins keys whose JSON value is the boolean true
#   (json.load maps JSON true -> Python True, so `val is True` is the strict boolean
#   test; a value of 1 or "true" is NOT boolean true). Excluded, each as noted:
#     - key equal to a baked baseline entry (code-review@claude-plugins-official,
#       claude-md-management@claude-plugins-official, devflow@devflow-marketplace):
#       silent skip (already installed by the baseline).
#     - key whose plugin name (the part before @) is "devflow": silent skip (always
#       installed via the baked devflow@devflow-marketplace).
#     - key with no @marketplace suffix: breadcrumb, not emitted.
#     - key whose marketplace suffix is outside the known set — the union of
#       claude-plugins-official, devflow-marketplace, and the names of github-kind
#       extraKnownMarketplaces entries in the same file: a suffix declared nowhere in
#       the file -> unknown-marketplace breadcrumb; a suffix declared in
#       extraKnownMarketplaces but with a non-github source kind -> declared-but-
#       unsupported-kind breadcrumb naming the kind and the scope boundary.
#     - value not boolean true: boolean false is silently skipped (the suppression
#       case); the STRING "true" is not emitted and draws a wrong-type breadcrumb.
#
# marketplaces mode — emits https://github.com/<repo>.git for each
#   extraKnownMarketplaces entry whose .source.source is the string "github" and whose
#   .source.repo is a non-empty string; entries named claude-plugins-official and
#   devflow-marketplace are silently skipped (both already registered by the baked
#   baseline; re-registering devflow-marketplace from GitHub would collide with the
#   ./ checkout-root registration every /devflow:init-provisioned repo carries). A
#   non-github source kind, or a github entry whose repo is missing/empty/non-string,
#   is skipped with a breadcrumb naming the entry and the cause.
#
# Exit codes:
#   0  entries (possibly none) on stdout; a degraded shape additionally prints a
#      specific stderr breadcrumb. There is no non-zero path — the compose must
#      never break on a corrupt settings file.

set -u

mode="${1:-}"
settings_path="${2:-}"

if [ -z "$mode" ] || [ -z "$settings_path" ]; then
    echo "resolve-extra-plugins: usage: resolve-extra-plugins.sh <plugins|marketplaces> <settings-path>" >&2
    exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "resolve-extra-plugins: 'python3' is required to read $settings_path" >&2
    exit 0
fi

DEVFLOW_MODE="$mode" DEVFLOW_SETTINGS="$settings_path" python3 -c '
import json, os, sys

mode = os.environ.get("DEVFLOW_MODE", "")
settings_path = os.environ.get("DEVFLOW_SETTINGS", "")


def warn(msg):
    sys.stderr.write("resolve-extra-plugins: " + msg + "\n")


if mode not in ("plugins", "marketplaces"):
    warn("unknown mode " + repr(mode) + " (expected: plugins | marketplaces); emitting nothing")
    sys.exit(0)

if not os.path.exists(settings_path):
    # Absent file is the normal consumer case: empty stdout, exit 0, no breadcrumb.
    sys.exit(0)

try:
    with open(settings_path, encoding="utf-8") as f:
        data = json.load(f)
except Exception as exc:
    warn(settings_path + " is not valid JSON (" + str(exc) + "); emitting nothing")
    sys.exit(0)

if not isinstance(data, dict):
    warn(settings_path + " is valid JSON but not an object (" + type(data).__name__ + "); emitting nothing")
    sys.exit(0)

# Pre-compute the marketplace index once (used by both modes): the names declared in
# extraKnownMarketplaces, and the subset of those that are github-kind (the only kind
# the compose maps to a URL, and a known-marketplace suffix for plugins mode).
extra = data.get("extraKnownMarketplaces")
if isinstance(extra, dict):
    declared_market_names = set(extra.keys())
    github_market_names = set()
    for nm, val in extra.items():
        if isinstance(val, dict):
            src = val.get("source")
            if isinstance(src, dict) and src.get("source") == "github":
                github_market_names.add(nm)
else:
    declared_market_names = set()
    github_market_names = set()


def market_kind(name):
    v = extra.get(name) if isinstance(extra, dict) else None
    if not isinstance(v, dict):
        return None
    s = v.get("source")
    if not isinstance(s, dict):
        return None
    k = s.get("source")
    return k if isinstance(k, str) else None


BAKED_PLUGINS = frozenset((
    "code-review@claude-plugins-official",
    "claude-md-management@claude-plugins-official",
    "devflow@devflow-marketplace",
))
BASE_MARKETPLACES = frozenset(("claude-plugins-official", "devflow-marketplace"))
SKIP_MARKET_NAMES = frozenset(("claude-plugins-official", "devflow-marketplace"))

if mode == "plugins":
    ep = data.get("enabledPlugins")
    if ep is None:
        # Absent key: empty stdout, exit 0, no breadcrumb (baseline-only compose).
        sys.exit(0)
    if not isinstance(ep, dict):
        warn("enabledPlugins is not an object (" + type(ep).__name__ + "); emitting nothing")
        sys.exit(0)
    known = BASE_MARKETPLACES | github_market_names
    for key, val in ep.items():
        # Strict boolean-true test: json.load maps JSON true -> Python True (the
        # singleton), so `val is True` accepts only a real boolean true. A string
        # "true", the number 1, or boolean false are NOT emitted.
        if val is True:
            pass
        elif isinstance(val, str) and val == "true":
            warn("enabledPlugins entry " + repr(key) + " has string value \"true\" (not boolean true); not emitted")
            continue
        else:
            # boolean false (the suppression case), null, numbers: silent skip.
            continue
        if key in BAKED_PLUGINS:
            continue
        if "@" not in key:
            warn("enabledPlugins entry " + repr(key) + " has no @marketplace suffix; not emitted")
            continue
        plugin_name, _, market = key.partition("@")
        if plugin_name == "devflow":
            continue
        if market not in known:
            if market in declared_market_names:
                k = market_kind(market)
                kstr = k if k else "missing"
                warn("enabledPlugins entry " + repr(key) + " marketplace " + repr(market)
                     + " is declared in extraKnownMarketplaces but with non-github source kind "
                     + repr(kstr) + " (scope boundary: only github-kind marketplaces are mapped); not emitted")
            else:
                warn("enabledPlugins entry " + repr(key) + " marketplace " + repr(market)
                     + " is not declared anywhere in the settings file; not emitted")
            continue
        sys.stdout.write(key + "\n")
    sys.exit(0)

if mode == "marketplaces":
    if extra is None:
        sys.exit(0)
    if not isinstance(extra, dict):
        warn("extraKnownMarketplaces is not an object (" + type(extra).__name__ + "); emitting nothing")
        sys.exit(0)
    for name, val in extra.items():
        if name in SKIP_MARKET_NAMES:
            continue
        if not isinstance(val, dict):
            warn("extraKnownMarketplaces entry " + repr(name) + " is not an object (" + type(val).__name__ + "); not emitted")
            continue
        src = val.get("source")
        if not isinstance(src, dict):
            warn("extraKnownMarketplaces entry " + repr(name) + " has no source object; not emitted")
            continue
        kind = src.get("source")
        if kind == "github":
            repo = src.get("repo")
            if isinstance(repo, str) and repo != "":
                sys.stdout.write("https://github.com/" + repo + ".git\n")
            else:
                warn("extraKnownMarketplaces entry " + repr(name) + " is github-kind but repo is missing, empty, or non-string; not emitted")
        else:
            kstr = kind if isinstance(kind, str) else "missing"
            warn("extraKnownMarketplaces entry " + repr(name) + " has source kind " + repr(kstr)
                 + " (only github is mapped to a URL); not emitted")
    sys.exit(0)
'
