#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# pattern-state.sh — the retrospective loop's lifecycle reconciler (issue #788).
#
# Owns two operations against .devflow/learnings/overrides.json, run before
# lib/actionable-patterns.sh derives the pattern view:
#
#   1. MIGRATE v1 → v2 in place. A v1 file is `{schema_version:1, dismissed:{}}`
#      where every `dismissed` entry — machine-written or human-written — sits in
#      one map. v2 splits them: a machine-owned `patterns{}` lifecycle map keyed
#      by category slug, and a human-owned `dismissed{}` map reserved for a
#      maintainer saying "stop raising this" (no machine path writes it). Only v1
#      entries whose `dismissed_by` is the loop's own writer `retrospective-weekly`
#      become `patterns{}` records; every other entry is preserved verbatim in the
#      v2 `dismissed{}` map and keeps suppressing.
#
#   2. RECONCILE every meta-issue entry of every lifecycle record against the live
#      state of that issue on GitHub, so a pattern's suppression lasts exactly as
#      long as the fix it is waiting on. A single prefetch supplies covered issues;
#      an uncovered entry resolves through `gh issue view <number>`. Transitions:
#        state OPEN            → entry `filed`   (fixed_at cleared)
#        stateReason COMPLETED → entry `fixed`   (fixed_at = closedAt)
#        stateReason NOT_PLANNED → entry `declined` (fixed_at = closedAt)
#        stateReason DUPLICATE → entry `declined` (fixed_at = closedAt)
#        no / unrecognized stateReason → no transition + ::warning::
#      The pattern's state derives from its entry set: `filed` when any entry is
#      filed, else the state of the entry with the newest closedAt.
#
# The reconciler reads no issue title and parses no title prefix — linkage is the
# stored issue URL/number, never the human-mutable title. Date comparisons go
# through python3, never `date -d`. It reads no git history.
#
# Usage:
#   lib/pattern-state.sh --overrides <path>
#
# Environment:
#   DEVFLOW_GH  override the gh binary (execution-verified resolver; test stub).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# jq binary: resolved once via the sourced sibling resolver (issue #247);
# best-effort — a copied/vendored deployment without lib/ falls back to bare
# `jq` with a breadcrumb rather than aborting under set -e.
# shellcheck source=resolve-jq.sh
. "$HERE/resolve-jq.sh" \
  || { echo "devflow: resolve-jq.sh could not be sourced beside ${BASH_SOURCE[0]} — using bare 'jq' (set DEVFLOW_JQ to override)" >&2; : "${DEVFLOW_JQ:=jq}"; }

# gh binary: resolved once via the single-source resolver (execution-verified);
# an explicit DEVFLOW_GH still wins, so test stubs are untouched.
# shellcheck source=resolve-gh.sh
. "$HERE/resolve-gh.sh"
: "${DEVFLOW_GH:=$(devflow_resolve_gh)}"

OVERRIDES=
while [[ $# -gt 0 ]]; do
    case "$1" in
        --overrides) OVERRIDES="$2"; shift 2 ;;
        *) echo "pattern-state: unknown argument: $1" >&2; exit 1 ;;
    esac
done
[[ -n "$OVERRIDES" ]] || { echo "pattern-state: missing required argument --overrides" >&2; exit 1; }

# The heavy lifting (migration, gh reconciliation, atomic write, date comparison)
# runs in python3 — a hard preflight prerequisite — which reads DEVFLOW_GH from the
# environment and shells out to the resolved gh, mirroring workpad.py's model.
# jq stays the sourced JSON validator ($DEVFLOW_JQ empty) so the sourcing contract
# above is a live dependency, not a dead import.
if [[ -f "$OVERRIDES" ]] && [[ -s "$OVERRIDES" ]]; then
    "$DEVFLOW_JQ" empty "$OVERRIDES" \
      || { echo "::error::pattern-state: ${OVERRIDES} is not valid JSON — refusing to reconcile" >&2; exit 1; }
fi

DEVFLOW_GH="$DEVFLOW_GH" OVERRIDES="$OVERRIDES" python3 - <<'PYEOF'
import json, os, re, subprocess, sys, tempfile

OVERRIDES = os.environ["OVERRIDES"]
GH = os.environ.get("DEVFLOW_GH") or "gh"

V2_STUB = {"schema_version": 2, "patterns": {}, "dismissed": {}}


def err(msg):
    sys.stderr.write("::error::pattern-state: " + msg + "\n")


def warn(msg):
    sys.stderr.write("::warning::pattern-state: " + msg + "\n")


def atomic_write(path, obj):
    # mktemp-then-mv, mirroring meta-issue.sh's overrides write: a failed write
    # leaves the previous file byte-unchanged. Deterministic bytes (sorted keys,
    # 2-space indent, trailing newline) so a second run over unchanged state is
    # byte-identical.
    payload = json.dumps(obj, indent=2, sort_keys=True) + "\n"
    d = os.path.dirname(os.path.abspath(path)) or "."
    try:
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".overrides.", suffix=".tmp")
    except OSError as e:
        err("could not create a temp file beside %s (%s) — the file is byte-unchanged" % (path, e))
        sys.exit(1)
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(payload)
        os.replace(tmp, path)
    except OSError as e:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        err("could not write %s (%s) — the file is byte-unchanged" % (path, e))
        sys.exit(1)


def parse_number(entry):
    n = entry.get("number")
    if isinstance(n, int):
        return n
    if isinstance(n, str) and n.isdigit():
        return int(n)
    url = entry.get("url") or entry.get("meta_issue") or ""
    m = re.search(r"/issues/(\d+)\b", str(url))
    return int(m.group(1)) if m else None


# ── Load (absent/empty → v2 stub, nothing to reconcile) ──────────────────────
if not os.path.exists(OVERRIDES) or os.path.getsize(OVERRIDES) == 0:
    atomic_write(OVERRIDES, V2_STUB)
    print("pattern-state: wrote v2 stub (overrides absent/empty)", file=sys.stderr)
    sys.exit(0)

with open(OVERRIDES, encoding="utf-8") as fh:
    data = json.load(fh)
if not isinstance(data, dict):
    err("%s top-level is not a JSON object — refusing to reconcile" % OVERRIDES)
    sys.exit(1)

# ── Migrate v1 → v2 (only loop-written dismissed entries become records) ──────
schema = data.get("schema_version")
if schema == 1:
    patterns, human = {}, {}
    for slug, entry in (data.get("dismissed") or {}).items():
        if isinstance(entry, dict) and entry.get("dismissed_by") == "retrospective-weekly":
            num = parse_number(entry)
            url = entry.get("meta_issue")
            patterns[slug] = {
                "state": "filed",
                "fixed_at": None,
                "provenance_at": entry.get("dismissed_at"),
                "meta_issues": [{"number": num, "url": url, "state": "filed"}],
            }
        else:
            human[slug] = entry
    data = {"schema_version": 2, "patterns": patterns, "dismissed": human}
else:
    # Normalize a v2-ish (or unknown) shape: ensure both maps exist so downstream
    # reads never KeyError; a non-dict map fails closed to empty.
    data.setdefault("schema_version", 2)
    if not isinstance(data.get("patterns"), dict):
        data["patterns"] = {}
    if not isinstance(data.get("dismissed"), dict):
        data["dismissed"] = {}

patterns = data["patterns"]

# ── Prefetch: one gh issue list over the Retrospective label ─────────────────
prefetch = {}
proc = subprocess.run(
    [GH, "issue", "list", "--label", "Retrospective", "--state", "all",
     "--limit", "200", "--json", "number,state,stateReason,closedAt"],
    capture_output=True, text=True,
)
if proc.returncode != 0:
    err("wholesale prefetch failed (gh issue list exited %d): %s"
        % (proc.returncode, (proc.stderr or "").strip()[:200]))
    sys.exit(1)
try:
    rows = json.loads(proc.stdout or "[]")
    if not isinstance(rows, list):
        raise ValueError("not an array")
except ValueError as e:
    err("prefetch body did not parse as a JSON array (%s)" % e)
    sys.exit(1)
for r in rows:
    n = r.get("number")
    if isinstance(n, int):
        prefetch[n] = r


def resolve_issue(num):
    """Return the issue's {state,stateReason,closedAt} row, or None if unresolvable."""
    if num in prefetch:
        return prefetch[num]
    p = subprocess.run(
        [GH, "issue", "view", str(num), "--json", "state,stateReason,closedAt"],
        capture_output=True, text=True,
    )
    if p.returncode != 0:
        return None
    try:
        row = json.loads(p.stdout or "null")
    except ValueError:
        return None
    return row if isinstance(row, dict) else None


def newer(a, b):
    """True if closedAt string a is strictly newer than b (ISO-8601 Z, python3)."""
    if a is None:
        return False
    if b is None:
        return True
    return a > b  # ISO-8601 UTC 'Z' strings order lexicographically == chronologically


# ── Reconcile every entry of every record ────────────────────────────────────
for slug in sorted(patterns.keys()):
    rec = patterns[slug]
    if not isinstance(rec, dict):
        continue
    entries = rec.get("meta_issues")
    if not entries:
        warn("pattern '%s' holds no issue URL — no transition" % slug)
        continue
    for entry in entries:
        num = parse_number(entry)
        if num is None:
            warn("pattern '%s' entry has no resolvable issue number/URL — no transition" % slug)
            continue
        row = resolve_issue(num)
        if row is None:
            warn("pattern '%s' issue #%s resolved through neither prefetch nor by-number fallback — no transition" % (slug, num))
            continue
        state = row.get("state")
        reason = row.get("stateReason")
        closed = row.get("closedAt")
        if state == "OPEN":
            entry["state"] = "filed"
            entry["closed_at"] = None
        elif reason == "COMPLETED":
            entry["state"] = "fixed"
            entry["closed_at"] = closed
        elif reason in ("NOT_PLANNED", "DUPLICATE"):
            entry["state"] = "declined"
            entry["closed_at"] = closed
        else:
            warn("pattern '%s' issue #%s has an unrecognized stateReason '%s' — no transition"
                 % (slug, num, reason))
            continue
    # Derive the record's state + fixed_at from the entry set.
    states = [e.get("state") for e in entries if isinstance(e, dict)]
    if "filed" in states:
        rec["state"] = "filed"
        rec["fixed_at"] = None
    else:
        newest, newest_closed = None, None
        for e in entries:
            if not isinstance(e, dict):
                continue
            c = e.get("closed_at")
            if newer(c, newest_closed):
                newest, newest_closed = e, c
        if newest is not None:
            rec["state"] = newest.get("state", rec.get("state"))
            rec["fixed_at"] = newest.get("closed_at")

atomic_write(OVERRIDES, data)
print("pattern-state: reconciled %d lifecycle record(s)" % len(patterns), file=sys.stderr)
PYEOF
