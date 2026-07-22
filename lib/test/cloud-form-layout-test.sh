#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
#
# cloud-form-layout-test.sh — AC7 of issue #702.
#
# Executes the cloud helper-invocation form (the anchor
# ${CLAUDE_SKILL_DIR:-<base>}/../../scripts/<helper> resolving to the
# denial-proof repo-relative vendored literal) against two layouts materialized
# from lib/test/fixtures/cloud-form-layouts/:
#
#   * source-repo — the source-repository workflow layout (skill at
#     skills/implement/, helper at the repo-root scripts/);
#   * consumer    — a freshly installed consumer layout (both vendored under
#     .devflow/vendor/devflow/).
#
# Each layout is exercised in TWO runtime states — a checkout path containing a
# space, and a shallow detached checkout — so both properties are represented
# in both fixtures (the spaces-normal variant covers spaces; the
# shallow-detached variant covers spaces AND a shallow detached checkout).
#
# Scope of what each state buys, stated plainly: the cloud form under test is a
# filesystem path join, and this driver's helper-execution assertion does not
# call git, so its outcome is not sensitive to the checkout's git state — the
# spaces and shallow-detached variants are expected to agree on it. The
# shallow-detached variant's distinct value is in the git-state-sensitive
# assertions: the shallow/detached self-checks, the truncated-history check, and
# that `git rev-parse --show-toplevel` (the #295 repo-root anchoring) still
# resolves to the checkout root in that state.
#
# Self-contained (invoked from lib/test/run.sh). Prints one FAIL line per
# failure to stderr and exits non-zero; exits 0 silently when every layout ×
# state resolves and runs the helper. Depends only on a POSIX bash, git
# (a hard preflight prerequisite), and standard coreutils (mktemp/cp/mkdir/rm).

set -u

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED_ROOT="$_SCRIPT_DIR/fixtures/cloud-form-layouts"

FAILS=0
_fail() { printf 'FAIL: %s\n' "$1" >&2; FAILS=$((FAILS + 1)); }

command -v git >/dev/null 2>&1 || { _fail "git not on PATH (hard preflight prerequisite)"; exit 1; }
[ -d "$SEED_ROOT" ] || { _fail "seed corpus not found at $SEED_ROOT"; exit 1; }

_git() { git -c user.email=devflow@example.invalid -c user.name=devflow -c commit.gpgsign=false -c init.defaultBranch=main "$@"; }

# Copy a seed layout into $dest and make it a committed git repo.
_seed_repo() {  # seed_name dest
  local seed="$SEED_ROOT/$1" dest="$2"
  mkdir -p "$dest" || return 1
  # Copy contents (including dotfiles) into dest — check it so a failed/partial
  # copy is attributed here, not at a confusing later commit/exec step.
  cp -R "$seed/." "$dest/" || return 1
  _git -C "$dest" init -q || return 1
  _git -C "$dest" add -A || return 1
  _git -C "$dest" commit -q -m "seed $1" || return 1
  return 0
}

# Run one layout in one runtime state and assert the cloud form resolves + runs.
#   layout    — source-repo | consumer
#   skill_rel — the skill base dir relative to the checkout root
#   cloud_rel — the repo-relative vendored-literal helper path
#   state     — spaces | shallow-detached
_exercise() {
  local layout="$1" skill_rel="$2" cloud_rel="$3" state="$4"
  local tmp checkout label
  tmp="$(mktemp -d)"
  label="$layout/$state"

  # A space in EVERY checkout path — both states carry it (AC7: "spaces in the
  # checkout path ... represented in both fixtures").
  checkout="$tmp/co with space"

  if [ "$state" = shallow-detached ]; then
    local origin="$tmp/origin"
    _seed_repo "$layout" "$origin" || { _fail "$label: could not seed origin repo"; rm -rf "$tmp"; return; }
    # Give the origin more than one commit, so --depth 1 actually truncates
    # history and the one-reachable-commit check below can distinguish a shallow
    # clone from a full one.
    _git -C "$origin" commit -q --allow-empty -m "second commit" || { _fail "$label: could not add second origin commit"; rm -rf "$tmp"; return; }
    if ! _git clone --depth 1 -q "file://$origin" "$checkout" 2>/dev/null; then
      _fail "$label: shallow clone (--depth 1) failed"; rm -rf "$tmp"; return
    fi
    # Detach HEAD onto the checked-out commit.
    _git -C "$checkout" checkout -q --detach HEAD 2>/dev/null || { _fail "$label: could not detach HEAD"; rm -rf "$tmp"; return; }
    # Represent the property faithfully: it must be shallow and detached.
    if [ "$(_git -C "$checkout" rev-parse --is-shallow-repository 2>/dev/null)" != "true" ]; then
      _fail "$label: checkout is not shallow"
    fi
    if [ "$(_git -C "$checkout" rev-parse --abbrev-ref HEAD 2>/dev/null)" != "HEAD" ]; then
      _fail "$label: HEAD is not detached"
    fi
    # State-sensitive and specific to this variant: a --depth 1 clone has a
    # truncated history, so exactly one commit is reachable from HEAD. The
    # spaces variant (a full seeded repo) does not carry this property.
    if [ "$(_git -C "$checkout" rev-list --count HEAD 2>/dev/null)" != "1" ]; then
      _fail "$label: shallow checkout does not have exactly one reachable commit"
    fi
  else
    _seed_repo "$layout" "$checkout" || { _fail "$label: could not seed checkout"; rm -rf "$tmp"; return; }
  fi

  # The repo-root anchoring the cloud form depends on (#295) must still resolve —
  # and resolve to THIS checkout's root, not merely to something non-empty.
  # Compare against the physical path, since --show-toplevel reports one and
  # mktemp -d can hand back a symlinked prefix.
  local toplevel expected_top
  toplevel="$(_git -C "$checkout" rev-parse --show-toplevel 2>/dev/null)"
  expected_top="$(cd "$checkout" && pwd -P)"
  if [ -z "$toplevel" ]; then
    _fail "$label: git rev-parse --show-toplevel did not resolve"
    rm -rf "$tmp"; return
  fi
  if [ "$toplevel" != "$expected_top" ]; then
    _fail "$label: --show-toplevel resolved to '$toplevel' (expected '$expected_top')"
  fi

  # The cloud form: the anchor base joined with /../../scripts/<helper>. Its
  # resolution must land on the layout's vendored-literal helper path.
  local anchored="$checkout/$skill_rel/../../scripts/echo-anchor.sh"
  local literal="$checkout/$cloud_rel"
  if [ ! -f "$literal" ]; then
    _fail "$label: vendored-literal helper missing at $cloud_rel"
    rm -rf "$tmp"; return
  fi

  # Execute the helper THROUGH the anchor-join cloud form and assert the
  # sentinel + exit 0. Quote the whole path so the embedded space is safe.
  local out rc
  out="$(bash "$anchored" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    _fail "$label: cloud-form helper exited $rc (expected 0)"
  elif [ "$out" != "ANCHOR-OK" ]; then
    _fail "$label: cloud-form helper printed '$out' (expected 'ANCHOR-OK')"
  fi

  rm -rf "$tmp"
}

# source-repo: skill at skills/implement, helper at repo-root scripts/.
_exercise source-repo "skills/implement" "scripts/echo-anchor.sh" spaces
_exercise source-repo "skills/implement" "scripts/echo-anchor.sh" shallow-detached

# consumer: both vendored under .devflow/vendor/devflow/.
_exercise consumer ".devflow/vendor/devflow/skills/implement" ".devflow/vendor/devflow/scripts/echo-anchor.sh" spaces
_exercise consumer ".devflow/vendor/devflow/skills/implement" ".devflow/vendor/devflow/scripts/echo-anchor.sh" shallow-detached

[ "$FAILS" -eq 0 ] || exit 1
exit 0
