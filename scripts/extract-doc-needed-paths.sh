#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
#
# extract-doc-needed-paths.sh — deterministically extract the file paths named
# in an issue body's **Documentation Needed** bullet, one per line.
#
# Reads the issue body on stdin (or from a file path given as $1) and emits the
# recognizable file paths declared in the `**Documentation Needed**` bullet of
# the `## Implementation Notes` section — a `- **…**` list item or a bare bold
# paragraph, per the scope note below (issue #309). Both Phase 4.1
# Stage 1 (pre-flight briefing) and Stage 2 (post-hoc diff gate) consume THIS
# output rather than re-deriving paths by LLM prose interpretation — so the two
# passes can never disagree about which paths were named (issue #185 Addendum).
#
# Extraction is intentionally deterministic and scoped:
#   * scope — only the text between the `**Documentation Needed**` bullet (either
#     a `- **…**` list item OR a bare blank-line-preceded `**…**` bold paragraph,
#     the shape an LLM-drafted `## Implementation Notes` section — and the real
#     issue #304 body — uses; issue #309) and the next top-level bold bullet of
#     the same two shapes, or the next `## ` heading (or EOF). A bold-emphasis
#     span that only begins a wrapped CONTINUATION line inside the bullet (no
#     `- `, not blank-preceded) does NOT close the scope, so paths on wrapped
#     lines are still captured. A path mentioned in `## Current Behavior`,
#     `## Technical Context`, or any OTHER bullet is NOT a documentation
#     deliverable and is never emitted.
#   * a token counts as a path only if it ends in a recognized documentation/
#     source extension OR names an in-tree tracked regular file (the two-part
#     `[ -f ]` + `git ls-files` rescue for extensionless real files like
#     Makefile/LICENSE — both halves are required; see the inline comment). A bare
#     "contains `/`" test is deliberately NOT sufficient: it wrongly emitted
#     directory tokens (`docs/internal`) and rooted skill-invocation refs
#     (`/claude-md-management`, from colon-splitting) — see issue #254. Rooted
#     (`/…`) tokens are dropped outright, since an in-tree deliverable is always
#     repo-relative. This excludes prose, skill names (`devflow:docs`), and
#     section names — the over-extraction the issue's Counterfactual warns
#     against — by construction, with no LLM judgement.
#   * out-of-tree escapes are dropped before the path test even runs: a rooted
#     (`/…`) token and a parent-dir-escaping (`../…`) token can never name an
#     in-tree deliverable, so both are dropped outright — this also stops a token
#     that carries a recognized extension (`../notes.md`) from reaching the
#     extension branch, which emits on the extension alone (issue #254).
#
# Output is sorted and de-duplicated; absent section / empty bullet / no
# path-like tokens all yield empty output and exit 0 (a true no-op signal).
set -euo pipefail

body="$(cat "${1:-/dev/stdin}")"

# Stage A — isolate the **Documentation Needed** bullet block (scope-only; no
# token logic here). awk state: 0 = outside Implementation Notes; 1 = inside the
# section but outside the bullet; 2 = inside the Documentation Needed bullet.
block="$(printf '%s\n' "$body" | awk '
  BEGIN { prev_blank = 1 }   # start-of-file is a paragraph boundary
  /^## / {
    state = ($0 ~ /^## Implementation Notes[[:space:]]*$/) ? 1 : 0
    prev_blank = 1           # a heading is a block boundary: the next line begins a new paragraph
    next
  }
  # A bold BULLET opens the Documentation Needed scope (when its label is
  # "Documentation Needed") or, for any other bold bullet, closes it. What counts
  # as a top-level bold bullet is either a "- **" list-marker line OR a bare "**"
  # bold paragraph AT A PARAGRAPH BOUNDARY (preceded by a blank line or the
  # section heading) — the two shapes real issue bodies use. The canonical issue
  # template writes the list form ("- **Documentation Needed** — …"); an
  # LLM-drafted `## Implementation Notes` section commonly renders the same items
  # as bare blank-separated bold PARAGRAPHS ("**Documentation Needed** — …", no
  # "- " prefix — the real issue #304 body is exactly this, and matched NOTHING
  # under the old "- "-required anchor, silently skipping the gate; issue #309,
  # sibling of the #289 class).
  # The `prev_blank` guard is load-bearing, not decoration: a bold-emphasis span
  # that merely BEGINS a wrapped continuation line *inside* an open bullet (no
  # "- ", not blank-preceded — e.g. "**Note.** also update `x.md`") is NOT a
  # bullet. Closing the scope on it would silently drop `x.md` and every path on
  # later wrapped lines — a fail-OPEN that under-enforces the very gate this
  # helper feeds, the recurrence the #309 fix must not introduce. It also keeps
  # the dashed list form (consecutive, blank-separator-free "- **…**" bullets, as
  # in the template) closing correctly via the "- **" arm, which needs no blank
  # line. ACCEPTED tradeoff (#309 review): a blank-line-PRECEDED bold paragraph
  # that the author meant as a continuation of the bullet ("**Also.** update
  # `b.md`" after a blank line) is structurally indistinguishable from a peer
  # bullet ("**Potential Gotchas.** …"), so it closes the scope and its paths
  # are dropped. Closing is the deliberate choice: treating it as continuation
  # would leak every following peer bullet into the gate output (the
  # false-positive direction the issue Gotchas forbid). Pinned by a run.sh
  # fixture so the drop is a documented contract, not a silent surprise.
  # The open-match is still ANCHORED to the bullet LABEL
  # (^(- )?**Documentation Needed**) so a different bullet that merely MENTIONS
  # the label in its prose (e.g. the Potential Gotchas bullet) closes the scope
  # rather than re-opening it. Sub-bullets ("  - x") and non-bold continuation
  # prose do not match and stay within an open scope.
  state >= 1 && ( /^- \*\*/ || ( /^\*\*/ && prev_blank ) ) {
    state = ($0 ~ /^(- )?\*\*Documentation Needed\*\*/) ? 2 : 1
  }
  state == 2 { print }
  { prev_blank = ($0 ~ /^[[:space:]]*$/) }
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

# Probe once whether the `git ls-files` half of the extensionless rescue can run
# at all: git absent from PATH, or cwd outside a work tree, both disable it. When
# disabled, an extensionless deliverable that IS a real on-disk file (so `[ -f ]`
# passes) is silently dropped by the rescue below — the same guard-class-2
# tr-dependence failure mode this repo's own review-extension flags. Emit ONE
# stderr breadcrumb naming `git` the first time a token actually hits the
# degraded rescue (not per-token, and not when no extensionless real file is
# affected), so the drop is observable rather than silent.
git_rescue_ok=1
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || git_rescue_ok=0

printf '%s\n' "$tokens" \
  | { git_warned=0; while IFS= read -r tok; do
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
        /*) continue ;;        # rooted token: an in-tree deliverable is always
                               # repo-relative, never absolute. Dropping it here
                               # keeps a rooted skill-ref (`/claude-md-management`)
                               # or out-of-tree path (`/etc/hostname`) from ever
                               # reaching the predicate below (issue #254 AC).
        ../*|*/../*) continue ;; # parent-dir escape: an in-tree deliverable never
                               # traverses out of the tree. Drop it here so a token
                               # WITH a recognized extension (`../notes.md`) cannot
                               # reach the extension branch below — that branch emits
                               # on the extension alone and never runs the `[ -f ]` +
                               # git in-tree check, so without this arm an out-of-tree
                               # `../x.md` would be emitted, the very out-of-tree
                               # fail-open the extensionless rescue was hardened against.
        '' ) continue ;;
      esac
      # A token counts as a deliverable file iff it EITHER ends in a recognized
      # doc/source extension (a real filename) OR names an in-tree TRACKED regular
      # file — the rescue for extensionless real files like Makefile/LICENSE. The
      # rescue needs BOTH checks: `[ -f "$tok" ]` rejects directory tokens (a bare
      # `docs`/`docs/internal`, which `-f` reports false for), and
      # `git ls-files --error-unmatch` constrains it to the git work tree. Neither
      # alone suffices: `[ -f ]` tests the whole host filesystem, so a real-on-disk
      # but UNTRACKED relative token (an ad-hoc `notes` file in cwd that is not a
      # repo deliverable) would fail OPEN and be emitted though `git ls-files`
      # rejects it; and `git ls-files` on a bare directory token (`docs`) succeeds
      # by matching the tracked files INSIDE it, so alone it would wrongly emit the
      # directory that `[ -f ]` rejects. Together they keep only in-tree regular
      # files. NOTE: the out-of-tree escapes are NOT this predicate's job —
      # rooted `/…` and parent-escaping `../…` tokens are already dropped by the
      # `case` above, BEFORE the predicate runs, so they never reach here; do not
      # delete those case arms on the assumption this predicate would re-catch them
      # (it would not — the extension branch below emits on the extension alone).
      # The `.+` before the dot excludes a bare extension token (`.md`, `.sh`)
      # that is a syntax reference, not a filename.
      if printf '%s\n' "$tok" | grep -qE '.+\.(md|markdown|sh|json|py|ya?ml|rst|txt|adoc|mdx|toml|cfg|ini)$'; then
        printf '%s\n' "$tok"
      elif [ -f "$tok" ]; then
        # Extensionless token naming a real on-disk regular file → rescue via git.
        if git ls-files --error-unmatch -- "$tok" >/dev/null 2>&1; then
          printf '%s\n' "$tok"
        elif [ "$git_rescue_ok" -eq 0 ] && [ "$git_warned" -eq 0 ]; then
          # git is unavailable, so this real file was dropped for a tool-absence
          # reason, not because it is untracked — surface it once, per the repo's
          # guard-class-2 (tr-dependence) standard, instead of dropping silently.
          printf '%s\n' "extract-doc-needed-paths.sh: git unavailable (absent from PATH or cwd outside a work tree); the in-tree rescue for extensionless deliverables is degraded — such tokens may be dropped" >&2
          git_warned=1
        fi
      fi
    done; } \
  | LC_ALL=C sort -u
