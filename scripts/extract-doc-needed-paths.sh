#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
#
# extract-doc-needed-paths.sh — deterministically extract the file paths named
# in an issue body's **Documentation Needed** bullet, one per line.
#
# Reads the issue body on stdin (or from a file path given as $1) and emits the
# recognizable file paths declared in the `**Documentation Needed**` bullet that
# lives as a sub-bullet of the `## Implementation Notes` section. Both Phase 4.1
# Stage 1 (pre-flight briefing) and Stage 2 (post-hoc diff gate) consume THIS
# output rather than re-deriving paths by LLM prose interpretation — so the two
# passes can never disagree about which paths were named (issue #185 Addendum).
#
# Extraction is intentionally deterministic and scoped:
#   * scope — only the text between the `- **Documentation Needed**` bullet and
#     the next top-level `- **…**` bullet or the next `## ` heading (or EOF). A
#     path mentioned in `## Current Behavior`, `## Technical Context`, or any
#     OTHER bullet is NOT a documentation deliverable and is never emitted.
#   * a token counts as a path only if it contains `/` OR ends in a recognized
#     documentation/source extension. This excludes prose, skill names
#     (`devflow:docs`), and section names — the over-extraction the issue's
#     Counterfactual warns against — by construction, with no LLM judgement.
#
# Output is sorted and de-duplicated; absent section / empty bullet / no
# path-like tokens all yield empty output and exit 0 (a true no-op signal).
set -euo pipefail

body="$(cat "${1:-/dev/stdin}")"

# Stage A — isolate the **Documentation Needed** bullet block (scope-only; no
# token logic here). awk state: 0 = outside Implementation Notes; 1 = inside the
# section but outside the bullet; 2 = inside the Documentation Needed bullet.
block="$(printf '%s\n' "$body" | awk '
  /^## / {
    state = ($0 ~ /^## Implementation Notes[[:space:]]*$/) ? 1 : 0
    next
  }
  # A top-level "- **Bold**" bullet either opens the Documentation Needed scope
  # or (any other bold bullet) closes it. The open-match is ANCHORED to the
  # bullet LABEL (^- **Documentation Needed**) so a different bullet that merely
  # MENTIONS the label in its prose (e.g. the Potential Gotchas bullet in the
  # issue template) closes the scope rather than re-opening it.
  # Sub-bullets ("  - x") do not match and stay within an open scope.
  state >= 1 && /^- \*\*/ {
    state = ($0 ~ /^- \*\*Documentation Needed\*\*/) ? 2 : 1
  }
  state == 2 { print }
')"

[ -n "$block" ] || exit 0

# Stage B — pull path-like tokens out of the scoped block. Split on every
# character that cannot appear in a path token (so backticks, commas, quotes,
# parentheses, and whitespace are delimiters — backticks are stripped for free),
# then keep only tokens that are actually paths. `LC_ALL=C sort` makes the output
# order locale-independent so callers and fixtures see one canonical ordering.
#
# Distinguish the grep exit codes instead of swallowing them all with `|| true`:
# rc 1 is the legitimate "no path-like token in the bullet" no-op (exit 0 below),
# but rc >= 2 is a real grep error (e.g. a read failure) that must NOT be
# laundered into an empty-output no-op — that would silently disable the gate the
# same way an upstream failure on the caller side would. Fail closed: propagate
# the non-zero rc so the caller routes to Blocked rather than "no paths named".
grep_rc=0
tokens="$(printf '%s\n' "$block" | grep -oE '[A-Za-z0-9._/-]+')" || grep_rc=$?
if [ "$grep_rc" -ge 2 ]; then
  printf '%s\n' "extract-doc-needed-paths.sh: token scan failed (grep rc=$grep_rc)" >&2
  exit "$grep_rc"
fi
[ -n "$tokens" ] || exit 0

printf '%s\n' "$tokens" \
  | while IFS= read -r tok; do
      tok="${tok#./}"          # strip a leading ./
      # Strip a trailing run of dots the tokenizer glues on at a sentence
      # boundary (the char class includes `.`, so prose like "update
      # CHANGELOG.md." yields the token `CHANGELOG.md.`). A real filename never
      # ends in `.`, so this only ever recovers the intended basename; without it
      # the extension test below rejects `CHANGELOG.md.` and the deliverable is
      # silently dropped — under-enforcing in the gate's own domain.
      tok="${tok%"${tok##*[!.]}"}"
      case "$tok" in
        */) continue ;;        # trailing slash => directory, not a file
        '' ) continue ;;
      esac
      # A token counts as a deliverable file iff it EITHER ends in a recognized
      # doc/source extension (a real filename) OR names an in-tree file right now
      # (`[ -f ]`, which rescues extensionless real files like Makefile/LICENSE).
      # A bare "contains a slash" test is deliberately NOT enough: it emitted
      # directory tokens (`docs/internal`) and — because the tokenizer splits a
      # skill-invocation reference like `/claude-md-management:revise-claude-md`
      # on the colon — rooted non-file tokens (`/claude-md-management`), neither
      # of which is a documentation deliverable (issue #254). The `.+` before the
      # dot excludes a bare extension token (`.md`, `.sh`) that is a syntax
      # reference, not a filename.
      if printf '%s\n' "$tok" | grep -qE '.+\.(md|markdown|sh|json|py|ya?ml|rst|txt|adoc|mdx|toml|cfg|ini)$' \
         || [ -f "$tok" ]; then
        printf '%s\n' "$tok"
      fi
    done \
  | LC_ALL=C sort -u
