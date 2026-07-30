#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
#
# Tag the merge-time version bump and publish its GitHub Release (issue #953).
#
# .github/workflows/version-consolidate.yml calls this immediately after it pushes the
# `chore: bump version` commit, so the release tag names the exact tree whose docs the
# same commit repinned — the docs at tag vN say vN. Extracted from the workflow (rather
# than left inline) because it SELECTS branches and COMPOSES user-facing messages, which
# CLAUDE.md requires be drivable by lib/test/run.sh: an inline `if` chain is a selection
# the suite cannot catch defeated.
#
# Usage:
#   scripts/publish-release.sh --version <N.N.N> [--notes-file <path>] [--repo <owner/repo>]
#                              [--remote <name>] [--commit <ref>] [--release <mode>]
#
#   --release always   publish a GitHub Release for every tag (the default; see below)
#   --release never    create the annotated tag only
#
# WHY `always` IS THE DEFAULT. docs/install.md and docs/cloud-setup.md both send readers
# to the repository's `releases/latest` page to find the current pin. That link only ever
# names the newest *Release*, not the newest tag — so skipping Releases on patch merges
# would leave a documented link pointing at a superseded version. The Release body is the
# CHANGELOG entry the same run just assembled, so it costs no hand-written artifact, and
# the notification it raises reaches only users who opted into release notifications, at
# the same cadence as the CHANGELOG they would read anyway. To switch to minor/major-only,
# pass `--release never` from the workflow under a bump-kind condition.
#
# Every step is idempotent: an existing remote tag or Release is reported and left alone,
# so a re-run never fails on work already done. The tag-existence VERIFICATION after the
# push is the network-side half of the release-pin drift guard — the offline half
# (`scripts/version_pins.py --check`) runs in the suite, which is network-free by contract.
set -euo pipefail

_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/resolve-gh.sh
. "$_SELF_DIR/../lib/resolve-gh.sh"
: "${DEVFLOW_GH:=$(devflow_resolve_gh)}"

VERSION=""
NOTES_FILE=""
REPO="${GITHUB_REPOSITORY:-}"
REMOTE="origin"
COMMIT="HEAD"
RELEASE_MODE="always"

die() { printf 'publish-release.sh: %s\n' "$1" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)      VERSION="${2:-}"; shift 2 ;;
    --notes-file)   NOTES_FILE="${2:-}"; shift 2 ;;
    --repo)         REPO="${2:-}"; shift 2 ;;
    --remote)       REMOTE="${2:-}"; shift 2 ;;
    --commit)       COMMIT="${2:-}"; shift 2 ;;
    --release)      RELEASE_MODE="${2:-}"; shift 2 ;;
    *)              die "unknown argument '$1'" ;;
  esac
done

case "$VERSION" in
  '') die "--version is required (an N.N.N string)" ;;
  *[!0-9.]*|*..*|.*|*.) die "--version '$VERSION' is not an N.N.N string" ;;
esac
# Shape check with builtins only: a value that decides an EMITTED result must not be
# derived through a non-preflight PATH tool (grep/sed/tr are not preflight-guaranteed).
case "$VERSION" in
  *.*.*.*) die "--version '$VERSION' is not an N.N.N string" ;;
  *.*.*)   : ;;
  *)       die "--version '$VERSION' is not an N.N.N string" ;;
esac

case "$RELEASE_MODE" in
  always|never) : ;;
  *) die "--release '$RELEASE_MODE' is not one of: always, never" ;;
esac

TAG="v$VERSION"

# Three-way remote-tag probe. `git ls-remote --exit-code` distinguishes its own two
# answers: 0 = the ref resolves, 2 = the query succeeded and matched nothing. ANY other
# status is the query itself failing (no network, bad remote, auth), which is NOT
# evidence of absence — folding it into "absent" would route a connectivity blip into
# the create/POST path and misattribute a probe-time problem to the mutation.
# Echoes the status; the callers branch on it.
_tag_probe() {
  local rc=0
  git ls-remote --exit-code --tags "$REMOTE" "refs/tags/$TAG" >/dev/null 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

# ── 1. The annotated tag ────────────────────────────────────────────────────────────
_PROBE="$(_tag_probe)"
case "$_PROBE" in
  2) : ;;  # queried cleanly, no such tag — fall through to create it
  0) : ;;  # already there
  *) printf '::error::Could not determine whether %s exists on %s (git ls-remote exited ' "$TAG" "$REMOTE"
     printf '%s). Refusing to guess: an unreachable remote is not evidence the tag is absent.\n' "$_PROBE"
     exit 1 ;;
esac
if [ "$_PROBE" = "0" ]; then
  printf '::notice::%s already exists on %s — leaving it alone.\n' "$TAG" "$REMOTE"
else
  # Annotated (not lightweight): a release tag carries its own object, date and message,
  # and `git describe` prefers it.
  git tag -a "$TAG" -m "DevFlow $TAG" "$COMMIT"
  if git push "$REMOTE" "refs/tags/$TAG"; then
    printf '::notice::Created and pushed annotated tag %s.\n' "$TAG"
  else
    printf '::error::Pushed the version bump but could not push %s. The docs in that ' "$TAG"
    printf 'commit pin a tag that does not exist; create it by hand.\n'
    exit 1
  fi
fi

# ── 2. Tag-existence verification (the network half of the drift guard) ─────────────
# A `git push` that reports success is not proof the ref landed — verify against the
# remote, because the commit we just pushed documents this tag as installable.
_PROBE="$(_tag_probe)"
if [ "$_PROBE" = "0" ]; then
  printf '::notice::Verified %s resolves on %s.\n' "$TAG" "$REMOTE"
elif [ "$_PROBE" = "2" ]; then
  printf '::error::%s does not resolve on %s after the tag push — the docs in this ' "$TAG" "$REMOTE"
  printf 'bump pin a release tag that does not exist.\n'
  exit 1
else
  # The verification query failed. Unknown is not "verified" — fail closed, but say which
  # of the two it is, so the operator retries the probe rather than hunting a lost ref.
  printf '::error::Could not verify %s on %s (git ls-remote exited %s). The tag push ' "$TAG" "$REMOTE" "$_PROBE"
  printf 'reported success but the verification query itself failed; re-run to re-probe.\n'
  exit 1
fi

# ── 3. The GitHub Release ───────────────────────────────────────────────────────────
if [ "$RELEASE_MODE" = "never" ]; then
  printf '::notice::--release never — tag %s created, no GitHub Release published.\n' "$TAG"
  exit 0
fi

[ -n "$REPO" ] || die "--repo (or GITHUB_REPOSITORY) is required to publish a Release"

# REST via `gh api`, never `gh release create`: the porcelain resolves the repository
# through org-scoped GraphQL and fails silently under a repo-scoped installation token.
if "$DEVFLOW_GH" api "repos/$REPO/releases/tags/$TAG" >/dev/null 2>&1; then
  printf '::notice::A GitHub Release for %s already exists — leaving it alone.\n' "$TAG"
  exit 0
fi

set -- api --method POST "repos/$REPO/releases" \
  -f "tag_name=$TAG" -f "name=$TAG" \
  -F draft=false -F prerelease=false -f make_latest=true
# Both fallback causes publish the same pointer body — but they are NOT the same event and
# must not read as one. "No --notes-file was passed" is a caller CHOICE (a `--release`-only
# invocation, a hand re-run) and is unremarkable. "A --notes-file was named but is absent or
# empty" is an UPSTREAM ANOMALY: the consolidator's `--emit-entry-to` side channel produced
# nothing, which means the CHANGELOG entry assembly it shares with the bump misbehaved —
# smoothing that into the same normal-looking fallback hides a real defect behind a warning
# that reads like routine configuration.
if [ -z "$NOTES_FILE" ]; then
  printf '::notice::No --notes-file passed for %s; publishing with a CHANGELOG pointer.\n' "$TAG"
  set -- "$@" -f "body=See CHANGELOG.md for the [$VERSION] entry."
elif [ ! -s "$NOTES_FILE" ]; then
  printf '::warning::Release notes file %s is absent or empty, but was requested for %s — ' "$NOTES_FILE" "$TAG"
  printf 'the consolidator emitted no CHANGELOG entry body. Publishing with a CHANGELOG '
  printf 'pointer; investigate the --emit-entry-to side channel.\n'
  set -- "$@" -f "body=See CHANGELOG.md for the [$VERSION] entry."
else
  set -- "$@" -F "body=@$NOTES_FILE"
fi

if "$DEVFLOW_GH" "$@" >/dev/null; then
  printf '::notice::Published GitHub Release %s (marked latest).\n' "$TAG"
else
  printf '::error::Tag %s is pushed, but publishing its GitHub Release failed. ' "$TAG"
  printf 'The releases/latest link the install docs cite is now stale.\n'
  exit 1
fi
