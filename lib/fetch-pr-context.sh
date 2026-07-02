#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# fetch-pr-context.sh <pr-number>
# Fetches all primary GitHub sources for one PR and writes a context bundle.
# Output path is echoed to stdout; everything else goes to stderr.
# Exit 2 if the PR branch is not a retrospected branch (kind == "skip").
set -euo pipefail

# jq binary: resolved once via the shared execution-verified resolver
# (lib/resolve-bin.sh, issue #247); an explicit DEVFLOW_JQ still wins, so test
# stubs and the Windows escape hatch are honored.
# Best-effort: when the resolver is not beside this script (a copied/vendored
# deployment), fall back to bare `jq` with a breadcrumb rather than aborting
# under the caller's set -e.
_DEVFLOW_RESOLVE_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve-bin.sh"
if [ -f "$_DEVFLOW_RESOLVE_BIN" ]; then
  # shellcheck source=resolve-bin.sh
  . "$_DEVFLOW_RESOLVE_BIN"
  : "${DEVFLOW_JQ:=$(devflow_resolve_bin jq)}"
else
  echo "devflow: lib/resolve-bin.sh not found beside ${BASH_SOURCE[0]} — using bare 'jq' (set DEVFLOW_JQ to override)" >&2
  : "${DEVFLOW_JQ:=jq}"
fi

PR="${1:?Usage: fetch-pr-context.sh <pr-number>}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# gh binary: resolved once via the single-source resolver (execution-verified);
# an explicit DEVFLOW_GH still wins, so test stubs are untouched.
# shellcheck source=resolve-gh.sh
. "$HERE/resolve-gh.sh"
: "${DEVFLOW_GH:=$(devflow_resolve_gh)}"

# shellcheck source=./config-source.sh
. "$HERE/config-source.sh"

REPO="$("$DEVFLOW_GH" repo view --json nameWithOwner -q .nameWithOwner)" \
  || { echo "::error::fetch-pr-context: failed to resolve repo name" >&2; exit 1; }

# ── 1. PR metadata ──────────────────────────────────────────────────────────
PR_JSON="$("$DEVFLOW_GH" pr view "$PR" --json number,headRefName,baseRefName,headRefOid,mergeCommit,mergedAt,createdAt,author,title,body,additions,deletions,files,labels,closingIssuesReferences)" \
  || { echo "::error::fetch-pr-context: failed to fetch PR metadata for PR ${PR}" >&2; exit 1; }

BRANCH="$(echo "$PR_JSON" | "$DEVFLOW_JQ" -r .headRefName)"
BASE_REF="$(echo "$PR_JSON" | "$DEVFLOW_JQ" -r .baseRefName)"
HEAD_SHA="$(echo "$PR_JSON" | "$DEVFLOW_JQ" -r .headRefOid)"
MERGE_COMMIT_SHA="$(echo "$PR_JSON" | "$DEVFLOW_JQ" -r '.mergeCommit.oid // ""')"
MERGED_AT="$(echo "$PR_JSON" | "$DEVFLOW_JQ" -r .mergedAt)"
CREATED_AT="$(echo "$PR_JSON" | "$DEVFLOW_JQ" -r .createdAt)"
AUTHOR_RAW="$(echo "$PR_JSON" | "$DEVFLOW_JQ" -r '.author.login')"
AUTHOR="${AUTHOR_RAW%\[bot\]}"
TITLE="$(echo "$PR_JSON" | "$DEVFLOW_JQ" -r .title)"
BODY="$(echo "$PR_JSON" | "$DEVFLOW_JQ" -r .body)"
ADDITIONS="$(echo "$PR_JSON" | "$DEVFLOW_JQ" -r .additions)"
DELETIONS="$(echo "$PR_JSON" | "$DEVFLOW_JQ" -r .deletions)"
CHANGED_FILES="$(echo "$PR_JSON" | "$DEVFLOW_JQ" '[.files[].path]')"

# ── 2. Classify retrospection kind ───────────────────────────────────────────
# Mirror lib/scan.sh's union predicate (label / closes-issue / prefix) so
# a PR scan selected on the label or closes-issue path — e.g. DevFlow's own
# issue-<N>-<slug> branches that match no prefix — is not then dropped here.
IMPL_PREFIX="$(devflow_conf '.devflow_retrospective.implementation_branch_prefix' 'claude/')"
LABELS_JSON="$(echo "$PR_JSON" | "$DEVFLOW_JQ" -c '.labels // []')"
CLOSING_JSON="$(echo "$PR_JSON" | "$DEVFLOW_JQ" -c '.closingIssuesReferences // []')"
KIND="$("$DEVFLOW_JQ" -rn --arg branch "$BRANCH" --argjson watched true --arg impl_prefix "$IMPL_PREFIX" \
    --argjson labels "$LABELS_JSON" --argjson closing "$CLOSING_JSON" -f "$HERE/classify-pr-kind.jq")"
if [ "$KIND" = "skip" ]; then
    echo "fetch-pr-context: branch $BRANCH is not a retrospected branch" >&2
    exit 2
fi

# ── 3. Issue number ──────────────────────────────────────────────────────────
ISSUE_NUMBER="null"
# Try branch name first: claude/issue-<N>-...
ISSUE_FROM_BRANCH="$(sed -nE 's|^claude/issue-([0-9]+)-.*$|\1|p' <<<"$BRANCH" || true)"
if [ -n "$ISSUE_FROM_BRANCH" ]; then
    ISSUE_NUMBER="$ISSUE_FROM_BRANCH"
else
    # Fallback: grep body for Closes/Fixes/Resolves #<N>
    ISSUE_FROM_BODY="$(echo "$BODY" | grep -oiE '(Closes|Fixes|Resolves)[[:space:]]+#[0-9]+' | grep -oE '[0-9]+' | head -1 || true)"
    if [ -n "$ISSUE_FROM_BODY" ]; then
        ISSUE_NUMBER="$ISSUE_FROM_BODY"
    else
        # Final fallback: GitHub's own issue linkage (closingIssuesReferences).
        # DevFlow's own `issue-<N>-<slug>` branches never match the `claude/issue-`
        # pattern above, and a PR linked only via the UI carries no Closes/Fixes
        # keyword in its body — yet such PRs are selected by the union predicate.
        # Without this they source an EMPTY workpad (a milder form of the bug this
        # change fixes). Use the first linked issue's number.
        ISSUE_FROM_CLOSING="$(echo "$CLOSING_JSON" | "$DEVFLOW_JQ" -r '.[0].number // empty' 2>/dev/null || true)"
        if [ -n "$ISSUE_FROM_CLOSING" ]; then
            ISSUE_NUMBER="$ISSUE_FROM_CLOSING"
        fi
    fi
fi

# ── 5. Issue details ─────────────────────────────────────────────────────────
ISSUE_JSON="null"
# The workpad lives on the ISSUE (header `# DevFlow Workpad — Issue #<N>`,
# marker `<!-- devflow:workpad -->`), authored by github-actions — NOT on the PR
# conversation thread. Default to an empty array so the workpad/reflection parse
# below is safe even when no linked issue was found.
ISSUE_COMMENTS_RAW='[]'
if [ "$ISSUE_NUMBER" != "null" ]; then
    ISSUE_RAW="$("$DEVFLOW_GH" api "repos/${REPO}/issues/${ISSUE_NUMBER}" --paginate)" \
      || { echo "::error::fetch-pr-context: failed to fetch issue ${ISSUE_NUMBER} for PR ${PR}" >&2; exit 1; }
    _ISSUE_COMMENTS_RAW="$("$DEVFLOW_GH" api "repos/${REPO}/issues/${ISSUE_NUMBER}/comments" --paginate)" \
      || { echo "::error::fetch-pr-context: failed to fetch issue comments for issue ${ISSUE_NUMBER}" >&2; exit 1; }
    ISSUE_COMMENTS_RAW="$(printf '%s' "$_ISSUE_COMMENTS_RAW" | "$DEVFLOW_JQ" -s 'add // []')"
    # Normalize issue comments to {author, body, createdAt}
    ISSUE_COMMENTS_NORM="$(echo "$ISSUE_COMMENTS_RAW" | "$DEVFLOW_JQ" '[.[] | {author: (.user.login // ""), body: (.body // ""), createdAt: (.created_at // "")}]')"
    ISSUE_JSON="$(echo "$ISSUE_RAW" | "$DEVFLOW_JQ" \
        --slurpfile comments <(printf '%s' "$ISSUE_COMMENTS_NORM") \
        '{title: (.title // ""), body: (.body // ""), labels: ([.labels[]?.name] // []), comments: $comments[0]}')"
fi

# ── 6. Review comments (inline diff comments) ────────────────────────────────
_REVIEW_COMMENTS_RAW="$("$DEVFLOW_GH" api "repos/${REPO}/pulls/${PR}/comments" --paginate)" \
  || { echo "::error::fetch-pr-context: failed to fetch review comments for PR ${PR}" >&2; exit 1; }
REVIEW_COMMENTS_RAW="$(printf '%s' "$_REVIEW_COMMENTS_RAW" | "$DEVFLOW_JQ" -s 'add // []')"
REVIEW_COMMENTS="$(echo "$REVIEW_COMMENTS_RAW" | "$DEVFLOW_JQ" '[.[] | {author: (.user.login // ""), body: (.body // ""), path: (.path // ""), line: (.line // null), createdAt: (.created_at // "")}]')"

# ── 7. PR conversation comments ───────────────────────────────────────────────
_PR_COMMENTS_RAW="$("$DEVFLOW_GH" api "repos/${REPO}/issues/${PR}/comments" --paginate)" \
  || { echo "::error::fetch-pr-context: failed to fetch PR conversation comments for PR ${PR}" >&2; exit 1; }
PR_COMMENTS_RAW="$(printf '%s' "$_PR_COMMENTS_RAW" | "$DEVFLOW_JQ" -s 'add // []')"
PR_COMMENTS="$(echo "$PR_COMMENTS_RAW" | "$DEVFLOW_JQ" '[.[] | {author: (.user.login // ""), body: (.body // ""), createdAt: (.created_at // "")}]')"

# ── 8. PR reviews ─────────────────────────────────────────────────────────────
_PR_REVIEWS_RAW="$("$DEVFLOW_GH" api "repos/${REPO}/pulls/${PR}/reviews" --paginate)" \
  || { echo "::error::fetch-pr-context: failed to fetch PR reviews for PR ${PR}" >&2; exit 1; }
PR_REVIEWS_RAW="$(printf '%s' "$_PR_REVIEWS_RAW" | "$DEVFLOW_JQ" -s 'add // []')"
PR_REVIEWS="$(echo "$PR_REVIEWS_RAW" | "$DEVFLOW_JQ" '[.[] | {author: (.user.login // ""), state: (.state // ""), body: (.body // ""), submittedAt: (.submitted_at // "")}]')"

# ── 9. Commits ────────────────────────────────────────────────────────────────
_COMMITS_RAW="$("$DEVFLOW_GH" api "repos/${REPO}/pulls/${PR}/commits" --paginate)" \
  || { echo "::error::fetch-pr-context: failed to fetch commits for PR ${PR}" >&2; exit 1; }
COMMITS_RAW="$(printf '%s' "$_COMMITS_RAW" | "$DEVFLOW_JQ" -s 'add // []')"
COMMITS="$(echo "$COMMITS_RAW" | "$DEVFLOW_JQ" '[.[] | {sha: .sha, author_login: (.author.login // ""), committer_login: (.committer.login // ""), committed_at: (.commit.committer.date // ""), message: (.commit.message // ""), parents_count: ((.parents // []) | length)}]')"

# ── 10. Diff ──────────────────────────────────────────────────────────────────
DIFF_BYTE_CAP="$(devflow_conf '.devflow_retrospective.diff_byte_cap' 204800)"
# `gh pr diff` fails outright on very large PRs (HTTP 406 — "diff exceeded the
# maximum number of files (300)") and on transient API errors. That must NOT
# abort the whole context fetch: a PR whose diff we cannot retrieve is the same
# situation as one whose diff is over diff_byte_cap — emit `diff: null`,
# `diff_truncated: true`, and let the analyst work from changed_files,
# human_postbot_diff, the reviews, and the issue. Only a *missing* PR (handled
# earlier) is fatal.
set +e
DIFF_RAW="$("$DEVFLOW_GH" pr diff "$PR" 2>/dev/null)"
DIFF_FETCH_OK=$?
set -e
if [ "$DIFF_FETCH_OK" -ne 0 ]; then
    echo "::warning::fetch-pr-context: could not fetch diff for PR ${PR} (too large or API error); emitting diff: null" >&2
    DIFF_RAW=""
fi

# Elide the *bodies* of generated / vendored files from the embedded diff:
# lockfiles, minified bundles, source maps, and anything under
# node_modules/ vendor/ dist/ build/. These are never the story and routinely
# dominate the byte count, which pushes the whole diff over diff_byte_cap and
# nulls it out — losing the parts that DO matter. The file *list*
# (changed_files) keeps every path; only the hunk text is replaced with a
# one-line marker so the analyst still knows the file changed.
DIFF_RAW="$(printf '%s' "$DIFF_RAW" | python3 -c '
import sys, re
diff = sys.stdin.read()
noise = re.compile(
    r"(^|/)(package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml"
    r"|composer\.lock|Gemfile\.lock|poetry\.lock|Cargo\.lock|go\.sum)$"
    r"|\.min\.(js|css|mjs)$|\.map$|(^|/)(node_modules|vendor|dist|build)/"
)
out, elide = [], False
for line in diff.split("\n"):
    if line.startswith("diff --git "):
        parts = line.split(" ", 3)
        path = parts[2][2:] if len(parts) > 2 and parts[2].startswith("a/") else ""
        elide = bool(path and noise.search(path))
        if elide:
            out.append(line)
            out.append("[devflow: diff body elided — generated/vendored file: %s]" % path)
            continue
    if not elide:
        out.append(line)
sys.stdout.write("\n".join(out))
' 2>/dev/null || printf '%s' "$DIFF_RAW")"
DIFF_LEN="${#DIFF_RAW}"
if [ "$DIFF_FETCH_OK" -ne 0 ] || [ "$DIFF_LEN" -gt "$DIFF_BYTE_CAP" ]; then
    DIFF_JSON="null"
    DIFF_TRUNCATED="true"
else
    DIFF_JSON="$(printf '%s' "$DIFF_RAW" | "$DEVFLOW_JQ" -Rs '.')"
    DIFF_TRUNCATED="false"
fi

# diffstat: simple "<n> files changed, +A -D" summary
NUM_FILES="$(echo "$CHANGED_FILES" | "$DEVFLOW_JQ" 'length')"
DIFFSTAT="${NUM_FILES} files changed, +${ADDITIONS} -${DELETIONS}"

# ── 11. Signals ───────────────────────────────────────────────────────────────

# review_comments_count
REVIEW_COMMENTS_COUNT="$(echo "$REVIEW_COMMENTS" | "$DEVFLOW_JQ" 'length')"

# post_bot_commits: count *substantive* commits AFTER the last bot/PR-author
# commit. A commit is "bot-authored" if author_login or committer_login ends
# with [bot] OR equals the AUTHOR (the [bot]-stripped PR author). Pure merge
# commits (parents_count > 1 — `git merge main` into the PR branch) are NOT
# counted: a human merging in main is branch hygiene, not a fixup of the bot's
# work, and counting it created a flood of false "imperfect" verdicts that
# nothing actionable came out of. (Trivial *non-merge* fixups — a one-line
# typo/lint commit — ARE still counted: a small human correction is a real,
# if minor, "the bot shipped something slightly off" signal.)
POST_BOT_COMMITS="$(echo "$COMMITS" | "$DEVFLOW_JQ" --arg author "$AUTHOR" '
    to_entries
    | [.[] | select(
        (.value.author_login | endswith("[bot]"))
        or (.value.committer_login | endswith("[bot]"))
        or (.value.author_login == $author)
        or (.value.committer_login == $author)
      ) | .key
    ] as $bot_indices
    | if ($bot_indices | length) == 0 then 0
      else ([.[($bot_indices | last) + 1:][] | select((.value.parents_count // 1) <= 1)] | length)
      end
')"

# ci_failures_during_pr + ci_status_unknown
# The CI check-runs call is intentionally fail-safe: a PR whose CI status
# could not be read must NOT be considered clean.  ci_status_unknown=true
# propagates into cheap-gate.jq and blocks the clean path explicitly.
CI_STATUS_UNKNOWN="false"
CI_FAILURES="1"
set +e
_CI_RUNS_JSON="$("$DEVFLOW_GH" api "repos/${REPO}/commits/${HEAD_SHA}/check-runs" 2>&1)"
_CI_EXIT=$?
set -e
if [ $_CI_EXIT -ne 0 ] || [ -z "$_CI_RUNS_JSON" ]; then
    CI_STATUS_UNKNOWN="true"
    CI_FAILURES="1"
else
    _CI_COUNT="$(echo "$_CI_RUNS_JSON" | "$DEVFLOW_JQ" '[.check_runs[] | select(.conclusion != null and .conclusion != "success" and .conclusion != "neutral" and .conclusion != "skipped")] | length' 2>/dev/null || true)"
    if [ -z "$_CI_COUNT" ] || ! [[ "$_CI_COUNT" =~ ^[0-9]+$ ]]; then
        CI_STATUS_UNKNOWN="true"
        CI_FAILURES="1"
    else
        CI_FAILURES="$_CI_COUNT"
    fi
fi

# workpad_body, workpad_final_status, reflections
# The workpad lives on the ISSUE thread (ISSUE_COMMENTS_RAW), not the PR
# conversation thread — reading it from the PR thread (the old bug) left it
# ~always empty, so the workpad signal in cheap-gate.jq was inert.
WORKPAD_BODY="$(echo "$ISSUE_COMMENTS_RAW" | "$DEVFLOW_JQ" -r '[.[] | select((.body // "") | test("<!-- devflow:workpad -->"; "i"))] | first | .body // ""')"
WORKPAD_FINAL_STATUS=""
REFLECTIONS="[]"
if [ -n "$WORKPAD_BODY" ]; then
    # Extract the value after "**Status:** <glyph> <word>" / "Status: <word>".
    # workpad.py prepends a canonical glyph (🚀/🎉/👎) to the status word, so the
    # captured value is e.g. "🎉 Complete". Strip that glyph by the known glyph SET
    # the workpad owns (a leading 🚀/🎉/👎 plus surrounding whitespace), NOT by
    # taking the last whitespace token: the old `awk '{print $NF}'` silently
    # coupled the strip to a single-word status vocabulary and would mis-gate a
    # future multi-word status (e.g. "In Progress" → "Progress"). The glyphs are
    # matched as literal byte sequences, so the strip is locale-independent.
    # The glyph SET below must stay in sync with workpad.py's `_STATUS_GLYPHS`
    # (the single source of truth that *writes* the glyph); enumerating the exact
    # set — rather than a broad "strip any leading symbol" — is deliberate, so a
    # corrupt/hand-edited status with an UNKNOWN leading symbol is preserved (not
    # silently normalised to a clean-looking word) and gates not-clean below.
    # `tr -d '\r'` first guards against CRLF bodies leaving a trailing carriage
    # return on the value. Trailing `|| true`: under `set -euo pipefail`, `head -1`
    # closing the pipe early can hand an upstream stage a SIGPIPE (141) and abort
    # the script; guard it.
    WORKPAD_FINAL_STATUS="$(printf '%s' "$WORKPAD_BODY" | tr -d '\r' | sed -nE 's/^\*{0,2}[[:space:]]*[Ss]tatus[[:space:]]*:?\*{0,2}[[:space:]]*(.+)/\1/p' | head -1 | sed -E 's/^[[:space:]]*(🚀|🎉|👎)?[[:space:]]*//; s/[[:space:]]+$//' || true)"
    # Fail toward analysis, not toward "clean": a workpad is present but its
    # Status line did not parse (corrupt/hand-edited — workpad.py always writes
    # `**Status:** <glyph> <word>`). cheap-gate.jq treats "" as clean, so an
    # empty status here on a *present* workpad would silently pass a possibly-bad
    # run. Substitute a non-empty sentinel (any non-Complete value gates not-clean).
    if [ -z "$WORKPAD_FINAL_STATUS" ]; then
        echo "::warning::fetch-pr-context: workpad present for PR ${PR} but Status line did not parse; not treating as Complete" >&2
        WORKPAD_FINAL_STATUS="Unparsed"
    fi
    # reflections[]: the bullet lines inside the workpad's `## Devflow Reflection`
    # <details> block (excluding the <summary> scaffold). Parsed in python3 (a
    # hard dependency) over the env-passed body — no shell quoting traverses the
    # markdown, and metacharacters (backticks, $) in a bullet survive intact.
    REFLECTIONS="$(DEVFLOW_WORKPAD_BODY="$WORKPAD_BODY" python3 - <<'PYEOF'
import os, re, json
body = os.environ.get('DEVFLOW_WORKPAD_BODY', '')
out, in_section = [], False
for raw in body.split('\n'):
    line = raw.rstrip('\r')
    if re.match(r'^##\s+Devflow Reflection\s*$', line):
        in_section = True
        continue
    if not in_section:
        continue
    # End of the reflection region: the closing </details>, or the next
    # `## ` heading (degrade gracefully when </details> is missing — malformed
    # block must not detonate the parse or swallow the rest of the comment).
    if '</details>' in line:
        break
    if re.match(r'^##\s+\S', line):
        break
    # Skip the <details>/<summary> scaffold lines.
    if '<details' in line or '<summary' in line or '</summary>' in line:
        continue
    m = re.match(r'^\s*[-*]\s+(.*\S)\s*$', line)
    if m:
        out.append(m.group(1))
print(json.dumps(out))
PYEOF
)"
    # Guard against a python hiccup leaving an empty/invalid value that would
    # break the later `--slurpfile reflections`.
    if ! printf '%s' "$REFLECTIONS" | "$DEVFLOW_JQ" -e . >/dev/null 2>&1; then
        echo "::warning::fetch-pr-context: reflection parse produced no valid JSON for PR ${PR}; defaulting to []" >&2
        REFLECTIONS="[]"
    fi
fi

# ttm_hours: (merged_at - created_at) in decimal hours
# The inner except already handles parse failures gracefully; the shell-level
# fallback is redundant and dropped to avoid masking a missing python3 binary.
# Timestamps are passed via the environment, not interpolated into the source,
# so a stray quote in the value can't break out of the Python string literal.
TTM_HOURS="$(DEVFLOW_MERGED_AT="$MERGED_AT" DEVFLOW_CREATED_AT="$CREATED_AT" python3 - <<'PYEOF'
import os
from datetime import datetime, timezone
fmt = '%Y-%m-%dT%H:%M:%SZ'
try:
    merged = datetime.strptime(os.environ['DEVFLOW_MERGED_AT'], fmt).replace(tzinfo=timezone.utc)
    created = datetime.strptime(os.environ['DEVFLOW_CREATED_AT'], fmt).replace(tzinfo=timezone.utc)
    diff = (merged - created).total_seconds() / 3600.0
    print(round(diff, 4))
except Exception:
    print(0.0)
PYEOF
)"
# Guard against an empty result poisoning the later `jq --argjson ttm_hours`.
[ -n "$TTM_HOURS" ] || TTM_HOURS=0.0

# review_verdicts: scan pr_comments for the /review report's verdict heading.
# Two formats occur in the wild and both must be recognized:
#   1. standalone `/review` skill output —  `## Verdict: APPROVE (summary)`
#   2. CI `@claude run /review` wrapper   —  `### /review — Verdict: **REJECT**`
# So: a heading line (1-6 `#`), an optional `/review —`/`/review –`/`/review -`
# prefix, the literal `Verdict:`, an optional `**` bold marker, then the first
# APPROVE|REJECT token. `APPROVE WITH CAVEAT` / `APPROVE with notes` are recorded
# as APPROVE (they are not a REJECT, which is all review_reject_outstanding cares
# about). Case-insensitive; trailing `\r` from CRLF bodies is stripped first.
REVIEW_VERDICTS="$(echo "$PR_COMMENTS_RAW" | "$DEVFLOW_JQ" '
    [
        .[] |
        . as $c |
        ($c.body // "") |
        split("\n")[] |
        rtrimstr("\r") |
        select(test("^#{1,6}[ \t]*(/review[ \t]*[—–-]+[ \t]*)?Verdict:[ \t]*\\**[ \t]*(APPROVE|REJECT)"; "i")) |
        capture("Verdict:[ \t]*\\**[ \t]*(?<verdict>APPROVE|REJECT)"; "i") |
        {verdict: (.verdict | ascii_upcase), createdAt: $c.created_at}
    ] | sort_by(.createdAt)
')"

# review_reject_outstanding: last verdict is REJECT?
REVIEW_REJECT_OUTSTANDING="$(echo "$REVIEW_VERDICTS" | "$DEVFLOW_JQ" 'if length == 0 then false else (last.verdict == "REJECT") end')"

# workpad_body as JSON string (null if empty)
if [ -n "$WORKPAD_BODY" ]; then
    WORKPAD_BODY_JSON="$("$DEVFLOW_JQ" -Rs '.' <<<"$WORKPAD_BODY")"
else
    WORKPAD_BODY_JSON="null"
fi

# implement_summary_comment: best-effort
IMPLEMENT_SUMMARY="$(echo "$PR_COMMENTS_RAW" | "$DEVFLOW_JQ" -r '[.[] | select(.body | test("Claude finished|/implement #"; "i"))] | first | .body // ""')"
if [ -n "$IMPLEMENT_SUMMARY" ]; then
    IMPLEMENT_SUMMARY_JSON="$("$DEVFLOW_JQ" -Rs '.' <<<"$IMPLEMENT_SUMMARY")"
else
    IMPLEMENT_SUMMARY_JSON="null"
fi

# ── 12. human_postbot_diff ────────────────────────────────────────────────────
# Get SHA list of post-bot commits (excluding pure merge commits — same rule as
# post_bot_commits above; a merge commit's API patch is the messy combined diff,
# which is noise, not the human's actual fixup) and fetch their patches.
HUMAN_POSTBOT_DIFF="null"
if [ "$POST_BOT_COMMITS" -gt 0 ]; then
    POSTBOT_SHAS="$(echo "$COMMITS" | "$DEVFLOW_JQ" --arg author "$AUTHOR" '
        to_entries
        | [.[] | select(
            (.value.author_login | endswith("[bot]"))
            or (.value.committer_login | endswith("[bot]"))
            or (.value.author_login == $author)
            or (.value.committer_login == $author)
          ) | .key
        ] as $bot_indices
        | if ($bot_indices | length) == 0 then []
          else [.[($bot_indices | last)+1:][] | select((.value.parents_count // 1) <= 1) | .value.sha]
          end
    ')"
    PATCHES=""
    while IFS= read -r SHA; do
        set +e
        _PATCH_JSON="$("$DEVFLOW_GH" api "repos/${REPO}/commits/${SHA}")"
        _PATCH_EXIT=$?
        set -e
        if [ $_PATCH_EXIT -ne 0 ]; then
            echo "::warning::fetch-pr-context: failed to fetch commit patch for ${SHA} on PR ${PR}" >&2
            continue
        fi
        # .files[].patch is legitimately absent for binary or empty files — skip those per-file
        PATCH="$(echo "$_PATCH_JSON" | "$DEVFLOW_JQ" -r '[.files[] | select(has("patch")) | .patch] | join("\n")')"
        if [ -n "$PATCH" ]; then
            PATCHES="${PATCHES}${PATCH}"$'\n'
        fi
    done < <(echo "$POSTBOT_SHAS" | "$DEVFLOW_JQ" -r '.[]')
    if [ -n "$PATCHES" ]; then
        HUMAN_POSTBOT_DIFF="$("$DEVFLOW_JQ" -Rs '.' <<<"$PATCHES")"
    fi
fi

# ── 13. Write output ──────────────────────────────────────────────────────────
REPO_ROOT="$(devflow_repo_root)"
OUT_DIR="${REPO_ROOT}/.devflow/tmp"
mkdir -p "$OUT_DIR"
OUT_FILE="${OUT_DIR}/pr-${PR}.context.json"

# Large values are written to temp files and passed via --rawfile / --slurpfile
# to avoid exceeding ARG_MAX when assembling the final jq bundle.
# Small scalars (numbers, short strings, booleans) remain as --arg / --argjson.
_JQ_TMP="$(mktemp -d)"
trap 'rm -rf "$_JQ_TMP"' EXIT

# --- raw strings (written as bare text; jq --rawfile reads them as JSON strings) ---
printf '%s' "$TITLE"          > "$_JQ_TMP/title.txt"
printf '%s' "$BODY"           > "$_JQ_TMP/body.txt"
printf '%s' "$DIFFSTAT"       > "$_JQ_TMP/diffstat.txt"

# --- JSON values (written as JSON; jq --slurpfile wraps in array → use $name[0]) ---
# diff: already a JSON string or the literal "null"
printf '%s' "$DIFF_JSON"                 > "$_JQ_TMP/diff.json"
printf '%s' "$HUMAN_POSTBOT_DIFF"        > "$_JQ_TMP/human_postbot_diff.json"
printf '%s' "$ISSUE_JSON"               > "$_JQ_TMP/issue.json"
printf '%s' "$REVIEW_COMMENTS"          > "$_JQ_TMP/review_comments.json"
printf '%s' "$PR_COMMENTS"              > "$_JQ_TMP/pr_comments.json"
printf '%s' "$PR_REVIEWS"               > "$_JQ_TMP/pr_reviews.json"
printf '%s' "$COMMITS"                  > "$_JQ_TMP/commits.json"
printf '%s' "$CHANGED_FILES"            > "$_JQ_TMP/changed_files.json"
printf '%s' "$REVIEW_VERDICTS"          > "$_JQ_TMP/review_verdicts.json"
printf '%s' "$WORKPAD_BODY_JSON"        > "$_JQ_TMP/workpad_body.json"
printf '%s' "$REFLECTIONS"              > "$_JQ_TMP/reflections.json"
printf '%s' "$IMPLEMENT_SUMMARY_JSON"   > "$_JQ_TMP/implement_summary_comment.json"

"$DEVFLOW_JQ" -n \
    --argjson pr "$PR" \
    --arg kind "$KIND" \
    --arg branch "$BRANCH" \
    --arg base_ref "$BASE_REF" \
    --arg head_sha "$HEAD_SHA" \
    --arg merge_commit_sha "$MERGE_COMMIT_SHA" \
    --arg merged_at "$MERGED_AT" \
    --arg created_at "$CREATED_AT" \
    --arg author "$AUTHOR" \
    --rawfile title "$_JQ_TMP/title.txt" \
    --rawfile body "$_JQ_TMP/body.txt" \
    --argjson additions "$ADDITIONS" \
    --argjson deletions "$DELETIONS" \
    --slurpfile changed_files "$_JQ_TMP/changed_files.json" \
    --rawfile diffstat "$_JQ_TMP/diffstat.txt" \
    --slurpfile diff "$_JQ_TMP/diff.json" \
    --argjson diff_truncated "$DIFF_TRUNCATED" \
    --slurpfile human_postbot_diff "$_JQ_TMP/human_postbot_diff.json" \
    --argjson issue_number "${ISSUE_NUMBER}" \
    --slurpfile issue "$_JQ_TMP/issue.json" \
    --slurpfile review_comments "$_JQ_TMP/review_comments.json" \
    --slurpfile pr_comments "$_JQ_TMP/pr_comments.json" \
    --slurpfile pr_reviews "$_JQ_TMP/pr_reviews.json" \
    --slurpfile commits "$_JQ_TMP/commits.json" \
    --slurpfile workpad_body "$_JQ_TMP/workpad_body.json" \
    --slurpfile reflections "$_JQ_TMP/reflections.json" \
    --slurpfile review_verdicts "$_JQ_TMP/review_verdicts.json" \
    --argjson review_reject_outstanding "$REVIEW_REJECT_OUTSTANDING" \
    --slurpfile implement_summary_comment "$_JQ_TMP/implement_summary_comment.json" \
    --argjson review_comments_count "$REVIEW_COMMENTS_COUNT" \
    --argjson post_bot_commits "$POST_BOT_COMMITS" \
    --argjson ci_failures_during_pr "$CI_FAILURES" \
    --argjson ci_status_unknown "$CI_STATUS_UNKNOWN" \
    --arg workpad_final_status "$WORKPAD_FINAL_STATUS" \
    --argjson ttm_hours "$TTM_HOURS" \
    '{
        pr: $pr,
        kind: $kind,
        branch: $branch,
        base_ref: $base_ref,
        head_sha: $head_sha,
        merge_commit_sha: $merge_commit_sha,
        merged_at: $merged_at,
        created_at: $created_at,
        author: $author,
        title: $title,
        body: $body,
        additions: $additions,
        deletions: $deletions,
        changed_files: $changed_files[0],
        diffstat: $diffstat,
        diff: $diff[0],
        diff_truncated: $diff_truncated,
        human_postbot_diff: $human_postbot_diff[0],
        issue_number: $issue_number,
        issue: $issue[0],
        review_comments: $review_comments[0],
        pr_comments: $pr_comments[0],
        pr_reviews: $pr_reviews[0],
        commits: $commits[0],
        workpad_body: $workpad_body[0],
        reflections: $reflections[0],
        review_verdicts: $review_verdicts[0],
        implement_summary_comment: $implement_summary_comment[0],
        signals: {
            review_comments_count: $review_comments_count,
            post_bot_commits: $post_bot_commits,
            ci_failures_during_pr: $ci_failures_during_pr,
            ci_status_unknown: $ci_status_unknown,
            workpad_final_status: $workpad_final_status,
            ttm_hours: $ttm_hours,
            review_reject_outstanding: $review_reject_outstanding
        }
    }' > "$OUT_FILE"

echo "$OUT_FILE"
