#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# refresh-app-credentials.sh — keep a writer job's push/gh credentials fresh
# past the GitHub App installation token's 60-minute lifetime (issue #487).
#
# A GitHub App installation token expires exactly one hour after minting and
# cannot be renewed — only replaced by a fresh mint. DevFlow's writer jobs mint
# ONE token at job start and ride it for the whole run; a `claude` step that
# outlives that hour then spends its remainder with dead credentials (`git push`
# and agent-side `gh` both 401). This helper, started as a background process
# after checkout and before the claude step, holds the App credentials and, on a
# 45-minute cadence, re-mints a fresh installation token and rewrites the two
# repo-controlled credential surfaces in place:
#   1. the checkout-persisted `http.<server>/.extraheader` credential every
#      in-run `git push` authenticates with (the #357 contract — this REWRITES
#      that credential-of-record, it never replaces the mechanism), and
#   2. a mode-0600 token file the agent-side `gh` wrapper (scripts/gh-fresh.sh)
#      reads at call time.
#
# Subcommands:
#   cycle   run ONE mint-and-rewrite cycle, then exit 0 (best-effort; the suite
#           drives this without sleeping). Emits a `::warning::` naming the arm
#           on any failure and leaves the previous credential in place.
#   loop    run cycle on a 45-minute cadence, dropping to a 2-minute backoff
#           after a failed cycle until one succeeds. Writes a pidfile, traps
#           TERM to exit 0, and NEVER exits non-zero — the job's conclusion never
#           rides on background-step failure semantics.
#
# Key hygiene (AC "Key hygiene"): THIS SCRIPT reads the PEM private key from stdin
# into shell memory only; it never re-exports that value into an environment
# variable, never passes it as a process argument, and never writes it to disk
# (openssl signs with the key handed over a file descriptor via process
# substitution, a /dev/fd path, not a real file). Scope note: the *workflow* Start
# step passes the key as its own step-level `DEVFLOW_APP_PRIVATE_KEY` env solely to
# pipe it to this script's stdin. The `/proc/<pid>/environ` exposure of that
# inherited var is closed at the WORKFLOW launch, not here: the detached refresher
# is spawned with `env -u DEVFLOW_APP_PRIVATE_KEY`, so the var is absent from this
# long-lived process's exec-time environment and never appears in its
# `/proc/<pid>/environ` (which snapshots the environment at execve time and is NOT
# updated by a later `unset`/`unsetenv` — proc(5)), which the concurrent same-uid
# (prompt-injectable) `claude` agent step could otherwise read for the whole run.
# read_key_from_stdin ALSO `unset`s the var as belt-and-suspenders — harmless when
# `env -u` already removed it, and it scrubs bash's environment table so any child
# the refresher spawns (openssl/curl/git) can never inherit the PEM. The key lives
# ONLY in the shell-memory `$KEY` (a non-exported shell var, never in any
# `/proc/*/environ`), NEVER in the `claude` agent step's own env, and never on disk.
#
# Testability: the mint honors a DEVFLOW_-prefixed override that wins verbatim
# and is never probed (the lib/resolve-bin.sh DEVFLOW_<TOOL> stub contract), and
# the credential-surface targets + sleep are overridable, so lib/test/run.sh
# drives every arm with no network, no real key, and no real gh.
#
# Cloud-only (ubuntu-latest); tool checks fail closed with a `::warning::` when a
# tool is missing (guard-class 2), never silently.

set -uo pipefail

# ── jq via the shared execution-verified resolver (the new-jq-caller pin) ──
# shellcheck source=../lib/resolve-jq.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/resolve-jq.sh"
: "${DEVFLOW_JQ:=jq}"

# ── Overridable knobs (defaults are the production values) ──
# The mint override (AC "Suite coverage"): when set, it is run VERBATIM and its
# stdout is the raw installation token; its exit code is the mint status. Never
# probed — mirrors lib/resolve-bin.sh's DEVFLOW_<TOOL> contract.
MINT_OVERRIDE="${DEVFLOW_REFRESH_MINT:-}"
# Credential-surface targets. In production the extraheader config file is
# LOCATED at run time (see locate_extraheader_file); the suite points these at
# fixtures instead.
CONFIG_FILE_OVERRIDE="${DEVFLOW_REFRESH_CONFIG_FILE:-}"
TOKEN_FILE="${DEVFLOW_REFRESH_TOKEN_FILE:-${RUNNER_TEMP:-/tmp}/devflow-gh-token}"
PIDFILE="${DEVFLOW_REFRESH_PIDFILE:-${RUNNER_TEMP:-/tmp}/devflow-refresh.pid}"
# Cadence (seconds) and the sleep command, overridable so the suite never waits.
INTERVAL="${DEVFLOW_REFRESH_INTERVAL:-2700}"   # 45 minutes
BACKOFF="${DEVFLOW_REFRESH_BACKOFF:-120}"       # 2 minutes
SLEEP_CMD="${DEVFLOW_REFRESH_SLEEP:-sleep}"
# Loop bound: production leaves this empty (runs until TERM); the suite sets it
# to a small integer so `loop` returns after N cycles instead of forever.
MAX_CYCLES="${DEVFLOW_REFRESH_MAX_CYCLES:-}"
# The API host and the git server URL that keys the extraheader.
API_URL="${GITHUB_API_URL:-https://api.github.com}"
SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"

warn() { printf '::warning::refresh-app-credentials: %s\n' "$*" >&2; }

# Read the PEM private key from stdin into shell memory (used only by the real
# mint path; the override path ignores it). Never persisted, never exported.
KEY=""
read_key_from_stdin() {
  # -r: no backslash mangling; -d '': read the whole stream including newlines.
  IFS= read -r -d '' KEY || true
  # Belt-and-suspenders scrub of the key from bash's environment table. The primary
  # /proc/<pid>/environ mitigation is at the workflow launch (`env -u
  # DEVFLOW_APP_PRIVATE_KEY` on the detached refresher — see the Key-hygiene header),
  # because /proc/<pid>/environ snapshots the exec-time environment and a later
  # `unset` does NOT rewrite it (proc(5)). This `unset` therefore does not by itself
  # close the /proc vector; what it DOES do is scrub bash's in-memory environment so
  # any child the refresher spawns afterward (openssl/curl/git) never inherits the
  # PEM in its own environment. It is a bash builtin (no non-preflight PATH tool on
  # this path) and is a harmless no-op when `env -u` already removed the var.
  unset DEVFLOW_APP_PRIVATE_KEY
}

# ── The real mint (no override): build an RS256 app JWT, resolve the
# installation id, and mint an installation access token. Echoes the raw token
# on success; returns non-zero (with a specific ::warning::) on any failure. ──
# `tr` is a non-preflight PATH tool on an emitted value (CLAUDE.md guard-class 2),
# but this is a deliberate, safe exemption: the refresher is cloud-only
# (ubuntu-latest, where `tr` is guaranteed) AND it fails closed — a missing `tr`
# yields a malformed JWT → the mint fails → a `::warning::` fires and the previous
# credential is retained, never a wrong-but-emitted value.
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

real_mint() {
  local app_id="${DEVFLOW_APP_ID:-}"
  if [ -z "$app_id" ]; then warn "mint: DEVFLOW_APP_ID empty — cannot mint"; return 1; fi
  if [ -z "$KEY" ]; then warn "mint: no private key on stdin — cannot mint"; return 1; fi
  for tool in openssl curl; do
    command -v "$tool" >/dev/null 2>&1 || { warn "mint: required tool '$tool' not found on PATH"; return 1; }
  done
  local repo="${GITHUB_REPOSITORY:-}"
  if [ -z "$repo" ]; then warn "mint: GITHUB_REPOSITORY empty — cannot resolve installation"; return 1; fi

  # JWT: iat 60s in the past (clock skew), exp 9 minutes out (< the 10-minute max).
  local now iat exp header payload signing_input sig jwt
  now="$(date +%s)"; iat=$((now - 60)); exp=$((now + 540))
  header="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
  payload="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$iat" "$exp" "$app_id" | b64url)"
  signing_input="${header}.${payload}"
  # Sign with the key over a file descriptor (process substitution → /dev/fd/N),
  # never a disk path — key hygiene.
  sig="$(printf '%s' "$signing_input" \
    | openssl dgst -sha256 -sign <(printf '%s' "$KEY") -binary 2>/dev/null | b64url)" \
    || { warn "mint: JWT signing failed (bad private key?)"; return 1; }
  [ -n "$sig" ] || { warn "mint: JWT signing produced no signature"; return 1; }
  jwt="${signing_input}.${sig}"

  # Disclosed residual (symmetric to the /proc/<pid>/environ PEM vector closed at
  # launch): the two curl calls below pass the app JWT in argv (`-H "Authorization:
  # Bearer $jwt"`), so it is briefly readable via /proc/<curl_pid>/cmdline by the
  # same-uid agent step during the sub-second mint. Accepted, not closed: the JWT is
  # short-lived (exp 9 min). Within that window it is an APP-level credential that can
  # mint installation tokens at attacker-chosen scope, up to the FULL installation
  # (the broad scope the POST below deliberately narrows to this repo) — so this is
  # NOT bounded to what the agent's ambient (this-repo) GH_TOKEN already holds; it is
  # bounded only by the 9-min exp, still a far smaller blast radius than the permanent
  # raw PEM. Passing the header on argv is standard curl usage; if this ever needs
  # hardening, move the header to a stdin curl-config (-K -).
  # Capture curl's own diagnostic (stderr merged via 2>&1) and exit code so a persistent
  # mint failure (wrong app id, revoked PEM, 404, rate-limit) surfaces an ACTIONABLE
  # ::warning::, not just a generic arm name. Under `-fsS`, a SUCCESS writes only the JSON
  # body to stdout (nothing to stderr); a FAILURE writes only curl's short diagnostic to
  # stderr and NO body (so the merged capture is the diagnostic, and no response body —
  # in particular no token, since `-f` suppresses the error body — is ever logged).
  local inst_json inst_rc inst_id tok_json tok_rc token
  inst_json="$(curl -fsS -H "Authorization: Bearer $jwt" \
    -H "Accept: application/vnd.github+json" \
    "$API_URL/repos/$repo/installation" 2>&1)"; inst_rc=$?
  [ "$inst_rc" -eq 0 ] \
    || { warn "mint: could not resolve installation id (GET /repos/$repo/installation failed; curl exit $inst_rc: $inst_json)"; return 1; }
  inst_id="$(printf '%s' "$inst_json" | "$DEVFLOW_JQ" -r '.id // empty' 2>/dev/null)"
  [ -n "$inst_id" ] || { warn "mint: installation id missing from response"; return 1; }

  # Scope the minted token to THIS repository only (least privilege), matching the
  # job-start token's default scope. actions/create-github-app-token@v3 mints
  # current-repo-only by default; a bodyless POST here would instead mint an
  # installation token carrying ALL installation permissions across ALL repos the
  # App is installed on — a strictly larger blast radius for the credential we write
  # into the extraheader and the token file. Restrict it to the repo name.
  local repo_name="${repo##*/}"
  tok_json="$(curl -fsS -X POST -H "Authorization: Bearer $jwt" \
    -H "Accept: application/vnd.github+json" \
    -d "{\"repositories\":[\"${repo_name}\"]}" \
    "$API_URL/app/installations/$inst_id/access_tokens" 2>&1)"; tok_rc=$?
  [ "$tok_rc" -eq 0 ] \
    || { warn "mint: access-token POST failed (curl exit $tok_rc: $tok_json)"; return 1; }
  token="$(printf '%s' "$tok_json" | "$DEVFLOW_JQ" -r '.token // empty' 2>/dev/null)"
  [ -n "$token" ] || { warn "mint: access token missing from response"; return 1; }
  printf '%s' "$token"
}

mint_token() {
  if [ -n "$MINT_OVERRIDE" ]; then
    # Verbatim, never probed. stdout = raw token; exit code = mint status.
    eval "$MINT_OVERRIDE"
    return $?
  fi
  real_mint
}

# ── Locate the checkout-persisted extraheader config file at run time (never a
# hardcoded path). Honors the suite override. ──
locate_extraheader_file() {
  if [ -n "$CONFIG_FILE_OVERRIDE" ]; then printf '%s' "$CONFIG_FILE_OVERRIDE"; return 0; fi
  local key raw line file first="" multi=no
  key="http.${SERVER_URL}/.extraheader"
  # `--show-origin` prints `file:<path>\t<value>` per match. The path DECIDES which
  # file gets rewritten, so it must be derived with bash builtins, never `head`/`sed`
  # (non-preflight PATH tools — CLAUDE.md guard-class 2; and `sed`'s `\t` is a GNU
  # extension BSD sed does not honor). Strip the `file:` prefix, then strip from the
  # first TAB onward — all builtins. This is the external git-credentials-<UUID>.config
  # checkout wrote.
  raw="$(git config --show-origin --get-all "$key" 2>/dev/null)"
  # Walk EVERY match, not just the first line (IMP-1 / PR #491 review). A single file
  # holding MULTIPLE values is fine — run_cycle's `--replace-all` collapses them to the
  # one fresh value (the #487 arm21 design). But matches spanning MORE THAN ONE distinct
  # file break the single-file-rewrite assumption: `git push` reads the LAST/highest-
  # precedence value, so rewriting only the first file would leave a stale credential
  # winning in another and `run_cycle` would still print `cycle OK` — a silent-freshness
  # path in an otherwise loud-degrade design. actions/checkout persists exactly one
  # extraheader (the assumption this rests on), so a multi-file chain is anomalous:
  # fail CLOSED with a `::warning::` rather than silently refresh just one file.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    file="${line#file:}"      # strip the `file:` prefix
    file="${file%%$'\t'*}"    # strip from the first TAB onward (no `sed`)
    if [ -z "$first" ]; then
      first="$file"
    elif [ "$file" != "$first" ]; then
      multi=yes
    fi
  done <<<"$raw"
  if [ "$multi" = yes ]; then
    warn "cycle: http.*/.extraheader is set in MORE THAN ONE config file — refusing to rewrite just one (git push would read a higher-precedence stale value); push credential NOT rewritten"
    return 1
  fi
  # Not found anywhere (git config failed, or no match). locate_extraheader_file owns the
  # specific reason on EVERY failure path so its caller does NOT add a second, contradictory
  # `::warning::` (PR #491 review: on the multi-file branch above, run_cycle's old generic
  # "could not locate" line falsely claimed the file was unlocatable when it was in fact
  # found in several places). One accurate breadcrumb per failure mode.
  if [ -z "$first" ]; then
    warn "cycle: could not locate the persisted http.${SERVER_URL}/.extraheader config file — push credential NOT rewritten"
    return 1
  fi
  printf '%s' "$first"
}

# ── One mint-and-rewrite cycle. Returns 0 on success, 1 on failure (leaving the
# previous credential untouched and emitting a ::warning:: naming the arm). ──
run_cycle() {
  local token cfg header b64
  token="$(mint_token)" || { warn "cycle: mint arm failed — previous credential left in place"; return 1; }
  [ -n "$token" ] || { warn "cycle: mint returned an empty token — previous credential left in place"; return 1; }

  # Surface 1: the checkout-persisted extraheader (the git-push credential).
  # locate_extraheader_file emits the specific failure reason itself (not-found vs.
  # multi-file), so do NOT add a second breadcrumb here — a generic "could not locate"
  # contradicts the callee's accurate multi-file warning (PR #491 review).
  cfg="$(locate_extraheader_file)" || return 1
  b64="$(printf 'x-access-token:%s' "$token" | openssl base64 -A 2>/dev/null)" \
    || { warn "cycle: base64 encode of the token failed — push credential NOT rewritten"; return 1; }
  header="AUTHORIZATION: basic ${b64}"
  # git config writes via a lockfile + atomic rename, so a concurrent push reading
  # this credential sees the old-or-new value, never a torn/partial file.
  # --replace-all: if the located config ever held MULTIPLE values for this key, a
  # plain set fails ("multiple values") and the credential would go stale; collapse
  # them to the one fresh value instead.
  git config --file "$cfg" --replace-all "http.${SERVER_URL}/.extraheader" "$header" 2>/dev/null \
    || { warn "cycle: rewriting the extraheader in '$cfg' failed — push credential NOT rewritten"; return 1; }

  # Surface 2: the mode-0600 token file the gh wrapper reads at call time. Write to
  # a temp file in the same dir and atomically rename into place, so a concurrent
  # gh-fresh.sh read never observes a truncated/partial token (mirroring the
  # atomic-rename guarantee git config gives surface 1). A plain `> "$TOKEN_FILE"`
  # would truncate-then-write, and a read landing in that window would see an empty
  # or partial token and silently degrade the wrapper to the ambient credential.
  # NOTE: surface 1 (the extraheader) has already been rewritten to the fresh token by
  # this point, so a surface-2 failure below leaves the two surfaces DIVERGED — the
  # push credential is fresh while the gh token file is stale (the reverse of the mint/
  # locate failures above, which leave BOTH surfaces on the previous credential). Both
  # warnings name that divergence so the operator knows only the gh surface is at risk
  # (both tokens are usually still valid — the stale one merely ages out sooner).
  local dir tmp; dir="$(dirname "$TOKEN_FILE")"; tmp="$TOKEN_FILE.tmp.$$"
  mkdir -p "$dir" 2>/dev/null || true
  ( umask 077; printf '%s' "$token" > "$tmp" ) \
    || { warn "cycle: writing the token temp file '$tmp' failed — push credential (surface 1) IS fresh but the gh token file (surface 2) is now stale"; rm -f "$tmp" 2>/dev/null; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$TOKEN_FILE" \
    || { warn "cycle: renaming the token file into place ('$TOKEN_FILE') failed — push credential (surface 1) IS fresh but the gh token file (surface 2) is now stale"; rm -f "$tmp" 2>/dev/null; return 1; }
  # Positive success breadcrumb (stdout → the same log the workflow redirects). The
  # Stop step's scripts/stop-refresher.sh reads the LAST refresh-app-credentials:
  # line to tell a recovered transient (last line = this OK) from a sustained failure
  # (last line = a ::warning::) — so its job-level alert never over-fires on a
  # transient that the backoff already recovered from.
  printf 'refresh-app-credentials: cycle OK (credentials refreshed)\n'
  return 0
}

cmd_cycle() {
  read_key_from_stdin
  run_cycle || true   # best-effort: always exit 0 (the warning already fired)
  return 0
}

cmd_loop() {
  read_key_from_stdin
  # Record our PID so the workflow's `if: always()` step can kill us by pidfile —
  # job completion never depends on background-step auto-cancel semantics.
  # Ensure the pidfile's parent dir exists first (the most common write-failure cause),
  # so a running refresher is not misreported by stop-refresher.sh as a never-started
  # defeat for want of its retirement handle. If the write STILL fails (a genuinely
  # unwritable path), the refresher keeps running but has no handle: name that
  # consequence in the breadcrumb, since stop-refresher.sh — with no pidfile to probe —
  # will then report a false "did not start" defeat it cannot distinguish from the real one.
  mkdir -p "$(dirname "$PIDFILE")" 2>/dev/null || true
  printf '%s' "$$" > "$PIDFILE" 2>/dev/null \
    || warn "loop: could not write pidfile '$PIDFILE' — the refresher is running but has no retirement handle; stop-refresher.sh may report a false 'did not start' defeat"
  trap 'exit 0' TERM
  local count=0
  while :; do
    # Sleep in the BACKGROUND and `wait` on it, so the TERM trap interrupts the
    # wait and retires the process promptly — a foreground `sleep` would only let
    # `trap 'exit 0' TERM` fire after the full interval elapsed, delaying
    # stop-refresher.sh's kill by up to 45 min (harmless on an ephemeral
    # ubuntu-latest runner torn down at job end, but a lingering minter on a
    # self-hosted one). The `|| true` keeps the loop's never-exit-nonzero contract.
    if run_cycle; then
      "$SLEEP_CMD" "$INTERVAL" & wait $! || true
    else
      # Backoff retry: a single transient mint failure never produces a
      # dead-credential window; sustained failure is required.
      "$SLEEP_CMD" "$BACKOFF" & wait $! || true
    fi
    count=$((count + 1))
    if [ -n "$MAX_CYCLES" ] && [ "$count" -ge "$MAX_CYCLES" ]; then break; fi
  done
  return 0
}

main() {
  local sub="${1:-cycle}"
  case "$sub" in
    cycle) cmd_cycle ;;
    loop)  cmd_loop ;;
    *) warn "unknown subcommand '$sub' (expected: cycle | loop)"; return 0 ;;
  esac
}

main "$@"
