---
name: retrospective-weekly
description: >
  Run the weekly devflow self-improvement loop locally: scan freshly-merged
  watched-author PRs, write per-PR retrospective entries (LLM only for PRs
  that fail the mechanical clean-gate), derive recurring patterns, and open
  one human-reviewed intervention PR per actionable pattern. Use when running
  the weekly devflow retrospective + audit.
---

# /devflow:retrospective-weekly — Weekly Orchestrator

This skill is the single entry point the maintainer invokes once a week (or
on demand). It is a *conductor*: it runs deterministic bash/jq scripts from
`lib/` at every mechanical step and dispatches LLM subagents only at the two
genuine-judgment points — per-PR retrospective analysis (Stage A) and
per-pattern intervention drafting (Stage B). Everything else — fetching,
signal computation, gating, pattern math, and git/PR mechanics — is done by
plain scripts with no LLM tokens.

```
LIB="${CLAUDE_SKILL_DIR}/../../lib"
```

All scratch files live under `.devflow/tmp/` (gitignored). Learnings files
(`.devflow/learnings/`) are tracked and committed via the state PR.

**GitHub autolink hygiene** (any text you compose that lands on a GitHub surface — issue/PR titles, the state-PR report comment, body content you assemble): never put a bare `#` immediately before a number unless it is a real issue or PR reference — GitHub renders `#2` as a link to issue/PR 2, which misleads readers. For an ordinal, count, or list position, spell it out ("item 2", "step 3"), never `#2`. Genuine references like `#123` stay as-is.

---

**Consumer prompt extension (load first).** Before doing this skill's work, load any consumer-supplied prompt extension for this skill and honor it. From the repo root, run:

```bash
${CLAUDE_SKILL_DIR}/../../scripts/load-prompt-extension.sh retrospective-weekly
```

If the helper prints anything, treat that text as additional instructions appended to the end of this skill's own prompt for this run — it is upgrade-safe, consumer-owned customization committed under `.devflow/prompt-extensions/`. If it prints nothing, proceed unchanged.

## Procedure

### Step 1 — Preflight

Confirm the working tree is clean:

```bash
git status --porcelain
```

If the output is non-empty, **stop** and tell the user to stash or commit
their changes before running the loop.

Confirm `gh` is authenticated:

```bash
gh auth status
```

If it fails, tell the user to run `gh auth login` and stop.

Confirm you are on `main`:

```bash
git branch --show-current
```

If not on `main`, run `git checkout main`.

Set the library path and prepare the scratch directory:

```bash
LIB="${CLAUDE_SKILL_DIR}/../../lib"
mkdir -p .devflow/tmp
rm -f .devflow/tmp/new-entries.jsonl
```

---

### Step 2 — Scan

Fetch the list of unprocessed watched-author PRs merged in the last 7 days:

```bash
bash $LIB/scan.sh > .devflow/tmp/scan.json
```

**Ad-hoc / backfill / test runs.** To run the loop against a specific set of
PRs instead of the rolling 7-day window — e.g. backfilling old PRs, re-running
after a fix, or testing the pipeline — pass `--prs`:

```bash
bash $LIB/scan.sh --prs 774,786,772,789 > .devflow/tmp/scan.json
```

`--prs` skips the GitHub search **and** the already-processed filter (you named
the PRs, so the loop trusts you), but still drops any number that isn't a merged
retrospected branch. Everything downstream (Steps 3–10) is identical. Do **not**
use `--prs` for the scheduled weekly run.

`scan.sh` writes to stdout and exits non-zero on unrecoverable errors. If
the output array is empty:

```bash
jq 'length == 0' .devflow/tmp/scan.json
```

→ `true`: report **"Nothing to process — no unprocessed watched-author PRs
in the last 7 days."** and **STOP**.

---

### Step 3 — Per-PR context fetch + cheap gate

Initialize counters:

```bash
prs_scanned=0
clean_count=0
analyzed_count=0
needs_analysis=()   # array of bundle paths
```

For each PR number in `scan.json` (iterate via `jq -r '.[].number'`):

```bash
number=<the pr number>
CTX=$(bash $LIB/fetch-pr-context.sh "$number")
prs_scanned=$((prs_scanned + 1))
```

`fetch-pr-context.sh` writes the bundle to `.devflow/tmp/pr-<n>.context.json`
and **echoes that file path** to stdout — so `$CTX` is the path, not the
bundle content.

Run the cheap gate against the bundle content:

```bash
GATE=$(jq -c -f $LIB/cheap-gate.jq < "$CTX")
```

Outputs `{"clean": <bool>, "reason": "<string>"}`.

**If `clean == true`:**

Check the kind of the PR:

```bash
KIND=$(jq -r .kind < "$CTX")
```

- If `KIND` is `audit-intervention`: emit a deterministic audit entry —
  `jq -c -f $LIB/audit-entry.jq < "$CTX" >> .devflow/tmp/new-entries.jsonl`
- Otherwise (normal `implementation` PR): emit a clean entry —
  `jq -c -f $LIB/clean-entry.jq < "$CTX" >> .devflow/tmp/new-entries.jsonl`

Increment `clean_count`.

**If `clean == false`:**

Add the bundle path to the analysis list:

```bash
needs_analysis+=("$CTX")
analyzed_count=$((analyzed_count + 1))
```

---

### Step 4 — Stage A: Retrospective subagents (per non-clean PR)

For each bundle path in `needs_analysis`, dispatch a subagent. Issue up to
**3–4 subagents concurrently** in a single message (use the Agent tool for
each). Each subagent prompt:

> Read and follow `${CLAUDE_SKILL_DIR}/../retrospective/SKILL.md`
> exactly.
>
> Your context bundle path is: `<path>`
>
> Print exactly one JSON object (the retrospective entry) and **nothing else**
> on stdout.

(The subagent picks `categories` from the fixed vocabulary in that skill — no
"existing tags" list is passed; the vocabulary *is* the bounded list.)

Wait for all dispatched subagents to finish before continuing.

**Collecting results:** Each subagent's final message is its JSON object.
Subagent output can contain quotes, backticks, newlines, and `$` — never
interpolate it inline into a shell command. **Write each subagent's raw result
to a temp file with the Write tool** (e.g. `.devflow/tmp/result-<n>.json`), then
operate on the file. For each result:

1. Attempt to parse it: `jq -c . < .devflow/tmp/result-<n>.json`
2. If parsing fails or the object has an `"error"` key, **retry the
   subagent once** with the same prompt.
3. If still malformed after one retry, record a blocker:
   `"PR #<n>: retrospective analysis failed"` and skip that PR.
4. If valid, append: `jq -c . < .devflow/tmp/result-<n>.json >> .devflow/tmp/new-entries.jsonl`

---

### Step 5 — Materialize

Merge all new entries into the retrospectives file (idempotent — existing
entries for the same `pr`+`kind` are replaced):

```bash
bash $LIB/materialize-retrospectives.sh \
  .devflow/tmp/new-entries.jsonl \
  .devflow/learnings/retrospectives.jsonl
```

The script prints `"materialized: appended N, replaced M"` to stdout.

---

### Step 6 — Derive actionable patterns

```bash
bash $LIB/actionable-patterns.sh \
  .devflow/learnings/retrospectives.jsonl \
  .devflow/learnings/overrides.json \
  > .devflow/tmp/patterns.json
```

Print a summary line to the console, for example:

```
5 PRs: 3 clean, 2 analyzed; 2 actionable patterns: incomplete-edit (x5), review-gate-bypass (x3)
```

Partition `patterns.json` into two lists:

```bash
to_act=$(jq '[.[] | select(.cooldown_active == false)]' .devflow/tmp/patterns.json)
cooldown_skipped=$(jq '[.[] | select(.cooldown_active == true) | .tag]' .devflow/tmp/patterns.json)
```

Record `cooldown_skipped` tags for the final report.

---

### Step 7 — State PR

**Open the state PR now, before Stage B**, so that the learnings files are
committed onto their own branch. This prevents Stage B's
`git checkout -B <audit-branch> main` (or a discard operation) from carrying
or reverting the unstaged changes that Steps 5–6 wrote to
`.devflow/learnings/`.

Ensure you are on `main`:

```bash
git checkout main
```

The working tree now has the updated
`.devflow/learnings/retrospectives.jsonl` (and possibly a modified
`.devflow/learnings/overrides.json` from meta-issue dismissals in a previous
run). These changes are in-place on `main`'s working tree and have **never
been committed to `main`** — `open-state-pr.sh` handles committing them onto
a separate branch.

```bash
STATE_PR=$(bash $LIB/open-state-pr.sh)
```

`open-state-pr.sh` (no required args; optional `--branch <name>`,
`--base <ref>` — defaults to `main` —, and `--dry-run`):

- Creates/reuses branch `devflow/learnings-<YYYY-MM-DD>` from `--base`
  (`main` by default), so the PR diff is just the learnings files even if the
  operator was on a feature branch.
- Stages any learnings files that exist (`.devflow/learnings/retrospectives.jsonl`
  and, if present, `.devflow/learnings/overrides.json`).
- Commits and pushes (force-with-lease if the remote branch exists).
- Opens or updates the PR against `main`.
- **Prints the PR number** to stdout.

After it returns, **go back to `main`** so the working tree is clean and
Stage B starts from a known-good HEAD:

```bash
git checkout main
```

Initialize Stage B counters:

```bash
intervention_prs=()   # will hold {number, tag} objects
meta_issues=()        # will hold {tag, url} objects
blockers=()           # will hold strings
```

---

### Step 8 — Stage B: Per-pattern intervention (parallel via worktrees)

Each pattern gets its **own `git worktree`** under `.devflow/tmp/wt-<slug>/`
(gitignored), so the per-pattern subagents run **concurrently** without
fighting over a single working tree. The expensive part (the drafting subagent)
parallelizes; the cheap part (exclusion check → commit → push → PR) is done
serially afterward, one worktree at a time. Your main checkout stays on `main`
and untouched throughout.

> `superpowers:using-git-worktrees` is available if you want its conventions,
> but raw `git worktree` is enough here — these are short-lived, machine-owned
> branches, not your personal workspace.

#### 8a — Create one worktree per pattern + gather occurrence bundles

For each `pattern` in `to_act`:

```bash
SLUG=$(jq -r .slug <<< "$pattern")
SHORT_SHA=$(git rev-parse --short=7 main)
BRANCH="devflow/audit-${SLUG}-$(date -u +%F)-${SHORT_SHA}"
WT=".devflow/tmp/wt-${SLUG}"
git worktree remove --force "$WT" 2>/dev/null || true   # clear any stale worktree from a crashed run

if git ls-remote --exit-code --heads origin "$BRANCH" > /dev/null 2>&1; then
    git fetch origin "$BRANCH"
    git worktree add -B "$BRANCH" "$WT" "origin/$BRANCH"   # idempotent re-run: reuse the remote branch
else
    git worktree add -B "$BRANCH" "$WT" main
fi
```

Then make sure every occurrence bundle is on disk (fetch the ones not already
fetched this run — run `fetch-pr-context.sh` from the **main** checkout, not the
worktree, so all bundles land in the single shared `.devflow/tmp/`):

```bash
for n in $(jq -r '.occurrences[].pr' <<< "$pattern"); do
    [ -f ".devflow/tmp/pr-${n}.context.json" ] || bash $LIB/fetch-pr-context.sh "$n" >/dev/null
done
```

Record, per pattern: `SLUG`, `BRANCH`, `WT` (absolute path —
`"$(pwd)/$WT"`), the JSON array of absolute bundle paths, and the `pattern`
object.

#### 8b — Dispatch all Stage B subagents concurrently

Issue **one Agent call per pattern, all in a single message** so they run in
parallel. Each subagent's prompt:

> Read and follow
> `${CLAUDE_SKILL_DIR}/../retrospective-audit/SKILL.md`
> exactly.
>
> **Your worktree is `<absolute WT path>`** — branch `<BRANCH>` is already
> checked out there. `cd` into it first; every file you read, every `git`
> command you run, and every edit you make happens inside that directory.
>
> Occurrence-PR context bundle paths (absolute): `<json array of paths>`
>
> Pattern metadata: `<the pattern json object>`
>
> Make your edits in the worktree and print exactly one JSON object (the return
> contract from § 6 of that skill) and **nothing else** on stdout.

Wait for **all** subagents to finish. Pair each result JSON with its pattern.

#### 8c — Process results, one worktree at a time (serial)

For each `(pattern, result)` pair, in any order:

**Worktree teardown helper.** When you finish with a pattern — success, skip,
or failure — remove its worktree (`--force` covers an uncommitted/dirty tree):

```bash
git worktree remove --force "$WT"
```

A targeted in-worktree discard (`git -C "$WT" checkout -- <path>` /
`git -C "$WT" clean -fd -- <path>`) is rarely needed now — `git worktree
remove --force` discards the whole disposable tree at once, and it cannot touch
files outside `.devflow/tmp/wt-<slug>/`, so there is no risk to user files.

---

Parse `result` as JSON. On parse failure → record a blocker
(`"Pattern <SLUG>: Stage B subagent returned malformed JSON"`), tear down the
worktree, continue.

**If `result.excluded == true`** (the fix targets an exclusion-list path):

Write the subagent's `result.proposed_change` to `.devflow/tmp/meta-body-${SLUG}.md` with the **Write tool** (it may contain quotes, backticks, or newlines — never inline it into the shell), then:

```bash
ISSUE_URL=$(bash $LIB/meta-issue.sh \
  --tag "<pattern.tag>" \
  --slug "$SLUG" \
  --title "<result.title>" \
  --body-file .devflow/tmp/meta-body-${SLUG}.md \
  --overrides .devflow/learnings/overrides.json)
```

Record `{tag: "<pattern.tag>", url: "$ISSUE_URL"}` in `meta_issues`, tear down
the worktree, continue.

(`meta-issue.sh` mutates `.devflow/learnings/overrides.json` in your main
checkout's working tree. That happens **after** the Step 7 state PR was opened,
so it lands in next week's state PR — see § Notes for the optional follow-up
commit if you want it in this run's PR.)

**If `result.excluded == false`** (edits are safe to commit):

Safety-net exclusion check on the returned targets:

```bash
printf '%s\n' <each path in result.targets[]> | bash $LIB/check-excluded-path.sh
EXIT=$?   # 0 = something excluded slipped through; 1 = all clear
```

If `EXIT == 0`, treat exactly as `excluded == true` above (file a meta-issue,
tear down, continue).

Otherwise stage exactly the returned targets **in the worktree** and assert
nothing else is dirty there:

```bash
for t in <result.targets[]>; do git -C "$WT" add -- "$t"; done
git -C "$WT" status --porcelain    # must show only the staged targets
```

If extra paths are dirty → record a blocker
(`"Pattern <SLUG>: unexpected dirty files in worktree after Stage B edits"`),
tear down the worktree, continue.

Commit, push (force-with-lease when the remote branch already exists), and open
or update the PR — all against the worktree's checkout:

First write the subagent's `result.title` and `result.body` to temp files with
the **Write tool** — `.devflow/tmp/pr-title-${SLUG}.txt` and
`.devflow/tmp/pr-body-${SLUG}.md` — so titles/bodies containing quotes,
backticks, newlines, or `$` never traverse shell quoting. Then:

```bash
TITLE=$(cat .devflow/tmp/pr-title-${SLUG}.txt)
git -C "$WT" commit -F - <<EOF
$TITLE

Fixes pattern: $SLUG
EOF

if git ls-remote --exit-code --heads origin "$BRANCH" > /dev/null 2>&1; then
    git -C "$WT" push --force-with-lease origin "$BRANCH"
else
    git -C "$WT" push -u origin "$BRANCH"
fi

EXISTING_PR=$(gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number // empty')
if [ -n "$EXISTING_PR" ]; then
    gh pr edit "$EXISTING_PR" --title "$TITLE" --body-file .devflow/tmp/pr-body-${SLUG}.md
    PR_NUMBER="$EXISTING_PR"
else
    gh pr create --base main --head "$BRANCH" --title "$TITLE" --body-file .devflow/tmp/pr-body-${SLUG}.md
    PR_NUMBER=$(gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number // empty')
fi
```

Record `{number: $PR_NUMBER, tag: "<pattern.tag>"}` in `intervention_prs`, then
tear down the worktree.

#### 8d — Final cleanup

After all patterns are processed:

```bash
git worktree prune
git worktree list   # confirm no devflow/audit-* worktrees remain
```

Your main checkout is still on `main` (you never left it). If `meta-issue.sh`
ran and you want this run's state PR to include the new overrides, see § Notes.

---

### Step 9 — Status report

Collect the per-analyzed-PR digest lines (verdict + a one-line summary) and the
full pattern list (acted-on, cooldown-skipped, dismissed, and below-threshold —
the same `patterns.json` from Step 6) so the report shows the whole picture, not
just the PRs that produced an intervention:

```bash
ANALYZED_JSON="$(jq -sc '[.[] | select(.verdict == "imperfect" or .verdict == "blocked") | {pr, verdict, summary}]' .devflow/tmp/new-entries.jsonl)"
PATTERNS_JSON="$(cat .devflow/tmp/patterns.json)"
```

Build the summary JSON and assign it to `$SUMMARY_JSON`:

```bash
SUMMARY_JSON="$(jq -nc \
  --argjson prs_scanned      "$prs_scanned" \
  --argjson clean_count      "$clean_count" \
  --argjson analyzed_count   "$analyzed_count" \
  --argjson analyzed         "$ANALYZED_JSON" \
  --argjson patterns         "$PATTERNS_JSON" \
  --argjson intervention_prs "$(printf '%s\n' "${intervention_prs[@]:-}" | jq -sc '.')" \
  --argjson meta_issues      "$(printf '%s\n' "${meta_issues[@]:-}"      | jq -sc '.')" \
  --argjson cooldown_skipped "$(printf '%s\n' "${cooldown_skipped[@]:-}" | jq -sc '.')" \
  --argjson blockers         "$(printf '%s\n' "${blockers[@]:-}"         | jq -sc '.')" \
  --argjson state_pr         "$STATE_PR" \
  '{prs_scanned:$prs_scanned,clean_count:$clean_count,analyzed_count:$analyzed_count,
    analyzed:$analyzed,patterns:$patterns,
    intervention_prs:$intervention_prs,meta_issues:$meta_issues,
    cooldown_skipped:$cooldown_skipped,blockers:$blockers,state_pr:$state_pr}')"
```

(The `"${array[@]:-}"` form handles an empty bash array safely under `set -u`.
`render-report.sh` renders the `analyzed` and `patterns` sections only when
those keys are non-empty, so an older caller that omits them still works.)

Render the report markdown and post it as a comment on the state PR:

```bash
source $LIB/render-report.sh
devflow_render_report "$SUMMARY_JSON" > .devflow/tmp/report.md
bash $LIB/post-status.sh --pr "$STATE_PR" --report-file .devflow/tmp/report.md
```

---

### Step 10 — Report to the user

Print the rendered report (`cat .devflow/tmp/report.md`) to the console.

Then list each item that needs human action:

- **State PR** (contains the updated retrospectives): `https://github.com/<repo>/pull/<state_pr>`
- **Intervention PRs** (one per actionable pattern, ready for review and merge):
  list each as `PR #<n> — <tag>: <url>`
- **Meta-issues** (patterns that touch exclusion-list paths, need design
  review before any automated change): list each as `<tag>: <url>`

If there are any **blockers**, list them explicitly.

Tell the user:

> Review and merge the state PR once CI passes, then merge the intervention
> PRs in any order. The loop is idempotent — re-running next week will only
> process new PRs not yet in `retrospectives.jsonl` on `main`.

Do **not** run `gh pr merge --auto` on anything. The maintainer merges
manually after reviewing.

---

## § Cron / headless variant

`claude -p "/devflow:retrospective-weekly" --permission-mode acceptEdits` handles steps
1–9 unattended, except that Stage B edits to `.claude/**` paths (made inside
the per-pattern worktrees under `.devflow/tmp/wt-<slug>/`) will trigger
permission prompts. For fully unattended runs, add
`--dangerously-skip-permissions`. The recommended mode is the interactive
run where you approve edits as they appear.

---

## § Notes

- **Clean working tree required.** The loop modifies `.devflow/learnings/`
  in-place on `main`'s working tree; starting dirty risks mixing pre-existing
  changes into the state PR commit. (The Stage B worktrees live under
  `.devflow/tmp/wt-<slug>/`, which is gitignored, so they never show up as
  changes to `main`.)
- **State PR before Stage B.** Opening the state PR (Step 7) before Stage B is
  intentional: it commits the learnings files onto `devflow/learnings-<date>`
  before any Stage B worktree exists, so a torn-down worktree can never revert
  or clobber that run's retrospective data — and your `main` checkout is never
  touched by Stage B at all.
- **Worktree-per-pattern.** Stage B creates one `git worktree` per actionable
  pattern under `.devflow/tmp/wt-<slug>/`, dispatches all drafting subagents
  concurrently, then serially commits/pushes/PRs each one and tears its
  worktree down. To abandon a pattern, `git worktree remove --force` the whole
  disposable tree — it physically cannot touch anything outside its own
  directory, so there is no `git clean -fd` foot-gun and no need for targeted
  reverts. End the step with `git worktree prune`.
- **Overrides after Stage B.** `meta-issue.sh` (called on the excluded path)
  modifies `.devflow/learnings/overrides.json` in your `main` working tree
  **after** the Step 7 state PR was opened, so the change lands in next week's
  state PR automatically. If you want it in *this* run's PR, after Step 8 push
  a follow-up commit onto the same `devflow/learnings-<date>` branch — without
  leaving `main`, using a throwaway worktree:

  ```bash
  if ! git diff --quiet HEAD -- .devflow/learnings/overrides.json 2>/dev/null; then
      LB="devflow/learnings-$(date -u +%F)"
      git fetch origin "$LB"
      git worktree add ".devflow/tmp/wt-learnings" "$LB"
      cp .devflow/learnings/overrides.json ".devflow/tmp/wt-learnings/.devflow/learnings/overrides.json"
      git -C ".devflow/tmp/wt-learnings" add .devflow/learnings/overrides.json
      git -C ".devflow/tmp/wt-learnings" commit -m "chore(devflow): add overrides from Stage B meta-issues"
      git -C ".devflow/tmp/wt-learnings" push --force-with-lease origin "$LB"
      git worktree remove --force ".devflow/tmp/wt-learnings"
  fi
  ```
- **Idempotent.** Re-running re-processes only PRs whose number is not
  already in `retrospectives.jsonl` on `main`. Stage B reuses existing
  `devflow/audit-*` branches (the worktree is created with `git worktree add
  -B "$BRANCH" "$WT" "origin/$BRANCH"` and pushed `--force-with-lease`) so
  intervention PRs are updated rather than duplicated.
- **Never auto-merge.** The maintainer merges the state PR and every
  intervention PR manually after CI passes and after human review.
- **`materialize-retrospectives.sh` signature:** takes two explicit positional
  args — `<new-entries-file>` and `<jsonl-path>`. Always pass both.
- **`actionable-patterns.sh` signature:** takes two explicit positional args
  — `<retrospectives.jsonl>` and `<overrides.json>`. Always pass both.
- **`open-state-pr.sh` signature:** no required args; optional `--branch`,
  `--base` (defaults to `main`), `--dry-run`; prints the PR number
  to stdout.
- **`fetch-pr-context.sh` return value:** echoes the bundle *file path* to
  stdout; the bundle content is on disk at `.devflow/tmp/pr-<n>.context.json`.
- **`cheap-gate.jq` invocation:** reads from stdin (the bundle content, not
  the path) — use `jq -c -f $LIB/cheap-gate.jq < "$CTX"` where `$CTX` is
  the path.
