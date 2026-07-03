---
name: retrospective-weekly
description: >
  Run the weekly devflow self-improvement loop locally: scan freshly-merged
  watched-author PRs, write per-PR retrospective entries (LLM only for PRs
  that fail the mechanical clean-gate), derive recurring patterns, and file
  one human-reviewed GitHub issue per actionable pattern. Use when running
  the weekly devflow retrospective + audit.
---

# /devflow:retrospective-weekly — Weekly Orchestrator

This skill is the single entry point the maintainer invokes once a week (or
on demand). It is a *conductor*: it runs deterministic bash/jq scripts from
`lib/` at every mechanical step and dispatches LLM subagents only at the two
genuine-judgment points — per-PR retrospective analysis (Stage A) and
per-pattern issue-spec drafting (Stage B). Everything else — fetching,
signal computation, gating, pattern math, and git/issue mechanics — is done by
plain scripts with no LLM tokens. The loop **proposes, it does not dispose**:
each actionable pattern is filed as **one GitHub issue** for the normal
implement → review pipeline, not landed as an autonomous PR.

**`$LIB` notation (textual, not a shell variable).** Throughout this skill, `$LIB` in a command denotes the resolved path `"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../lib` — expand it textually (with the anchor already resolved for this runner) when composing each command you actually run. Never rely on a shell variable named `LIB` persisting from one statement or block to another — each Bash call is a fresh shell, and the *Portable helper anchor* note below explains why even same-command variable reuse is unsafe on some runners.

Every `jq` in this skill is invoked through the execution-verified wrapper
`$LIB/../scripts/run-jq.sh` (`$LIB/../scripts` is the `scripts/` dir beside
`lib/`), never bare `jq` — so a shim-shadowed Windows/WSL host resolves a
runnable jq the same way the `.sh` helper tier does (issue #253, the agent-tier
sibling of #247). `DEVFLOW_JQ` is not exported to agent shells, so the wrapper
must be invoked by path.

All scratch files live under `.devflow/tmp/` (gitignored). Learnings files
(`.devflow/learnings/`) are tracked and committed via the state PR.

**GitHub autolink hygiene** (any text you compose that lands on a GitHub surface — issue/PR titles, the state-PR report comment, body content you assemble): never put a bare `#` immediately before a number unless it is a real issue or PR reference — GitHub renders `#2` as a link to issue/PR 2, which misleads readers. For an ordinal, count, or list position, spell it out ("item 2", "step 3"), never `#2`. Genuine references like `#123` stay as-is.

---

**Portable helper anchor (single-statement).** The bundled-helper commands in this skill resolve the skill directory inline at each call site via `${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}`. When `$CLAUDE_SKILL_DIR` is set and non-empty (Claude Code), run each command exactly as written. On a runner where it is unset or empty, replace the placeholder with the skill base directory the runner reports in context (e.g. a `Base directory for this skill:` line) before running the command; if that reported path is Windows-form (`C:\...`), first convert it to this shell's POSIX form with one standalone `wslpath -u '<path>'` (WSL) or `cygpath -u '<path>'` (Git Bash/MSYS2) command and substitute the printed result (if neither tool exists: lowercase the drive letter, map `C:\` to `/mnt/c` on WSL or `/c` on MSYS2, and turn backslashes into `/`; if the environment is neither WSL nor MSYS2, use the path unchanged and report that it could not be normalized — the same arm `lib/normalize-path.sh` takes). Resolve the anchor inline at every call site — never capture it into a shell variable that a later statement reads, because some runners' inline-bash marshaling drops such variables (observed on Copilot CLI). If neither `$CLAUDE_SKILL_DIR` nor a runner-reported base directory is available, stop and report that the helper anchor could not be resolved rather than running a command with a broken path.

**Consumer prompt extension (load first).** Before doing this skill's work, load any consumer-supplied prompt extension for this skill and honor it. From the repo root, run:

```bash
"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/load-prompt-extension.sh retrospective-weekly
```

If the invocation fails because the helper path does not exist (`No such file`, exit 127, or the platform equivalent), that is the **anchor-resolution** failure described in the *Portable helper anchor* note above — fix the anchor, don't report a missing extension. Otherwise, if the helper exits non-zero, a consumer extension exists but could not be loaded — surface its stderr message and do not silently proceed as if none existed. If it exits 0 and prints text, treat that text as additional instructions appended to the end of this skill's own prompt for this run — it is upgrade-safe, consumer-owned customization committed under `.devflow/prompt-extensions/`. If it exits 0 and prints nothing, proceed unchanged.

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

Prepare the scratch directory (`$LIB` below is the textual notation from the top of this skill — expand it when composing commands, do not assign a shell variable):

```bash
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
$LIB/../scripts/run-jq.sh 'length == 0' .devflow/tmp/scan.json
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

For each PR number in `scan.json` (iterate via `$LIB/../scripts/run-jq.sh -r '.[].number'`):

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
GATE=$($LIB/../scripts/run-jq.sh -c -f $LIB/cheap-gate.jq < "$CTX")
```

Outputs `{"clean": <bool>, "reason": "<string>"}`.

**If `clean == true`:**

Emit a clean entry (every retrospected PR is an `implementation` PR now — the
old audit-kind path is retired along with autonomous intervention PRs):

```bash
$LIB/../scripts/run-jq.sh -c -f $LIB/clean-entry.jq < "$CTX" >> .devflow/tmp/new-entries.jsonl
```

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

> Read and follow `"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../retrospective/SKILL.md`
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

1. Attempt to parse it: `$LIB/../scripts/run-jq.sh -c . < .devflow/tmp/result-<n>.json`
2. If parsing fails or the object has an `"error"` key, **retry the
   subagent once** with the same prompt.
3. If still malformed after one retry, record a blocker:
   `"PR #<n>: retrospective analysis failed"` and skip that PR.
4. If valid, append: `$LIB/../scripts/run-jq.sh -c . < .devflow/tmp/result-<n>.json >> .devflow/tmp/new-entries.jsonl`

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
5 PRs: 3 clean, 2 analyzed; 2 actionable patterns: incomplete-edit (x5), lenient-verdict (x3)
```

Partition `patterns.json` into two lists:

```bash
to_act=$($LIB/../scripts/run-jq.sh '[.[] | select(.cooldown_active == false)]' .devflow/tmp/patterns.json)
cooldown_skipped=$($LIB/../scripts/run-jq.sh '[.[] | select(.cooldown_active == true) | .tag]' .devflow/tmp/patterns.json)
```

Record `cooldown_skipped` tags for the final report.

---

### Step 7 — State PR

**Open the state PR now, before Stage B**, so that the learnings files are
committed onto their own branch. This captures the unstaged changes Steps 5–6
wrote to `.devflow/learnings/` before any issue is filed, so this run's
retrospective data survives even if Stage B or the filing step fails partway.

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
intervention_issues=()   # will hold {tag, url} objects — one per filed pattern
blockers=()              # will hold strings
```

---

### Step 8 — Stage B: File one issue per actionable pattern

For each actionable pattern, a Stage B subagent drafts a `{title, body}` issue
spec and the orchestrator files **exactly one GitHub issue** from it via
`meta-issue.sh`. **No worktrees, no commits, no PRs** — the loop proposes; a
human triages each issue and runs it through the normal `/devflow:implement` →
review pipeline. Your main checkout stays on `main` and is never edited. The
drafting subagents (8b) parallelize; the cheap filing (8c) is done serially.

#### 8a — Gather occurrence bundles

For each `pattern` in `to_act`, make sure every occurrence bundle is on disk
(fetch the ones not already fetched this run):

```bash
for n in $($LIB/../scripts/run-jq.sh -r '.occurrences[].pr' <<< "$pattern"); do
    [ -f ".devflow/tmp/pr-${n}.context.json" ] || bash $LIB/fetch-pr-context.sh "$n" >/dev/null
done
```

Record, per pattern: `SLUG` (`$LIB/../scripts/run-jq.sh -r .slug <<< "$pattern"`), `TAG`
(`$LIB/../scripts/run-jq.sh -r .tag <<< "$pattern"`), the JSON array of absolute bundle paths, and the
`pattern` object.

#### 8b — Dispatch all Stage B subagents concurrently

Issue **one Agent call per pattern, all in a single message** so they run in
parallel. No worktree is created or passed — the subagent makes no edits. Each
subagent's prompt:

> Read and follow
> `"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../retrospective-audit/SKILL.md`
> exactly.
>
> Occurrence-PR context bundle paths (absolute): `<json array of paths>`
>
> Pattern metadata: `<the pattern json object>`
>
> Make **no** edits and **no** worktree. Print exactly one JSON object (the
> `{title, body}` return contract from § 5 of that skill) and **nothing else**
> on stdout.

Wait for **all** subagents to finish. Pair each result JSON with its pattern.

#### 8c — File one issue per pattern (serial)

For each `(pattern, result)` pair, in any order:

Write the subagent's raw result to `.devflow/tmp/result-${SLUG}.json` with the
**Write tool** (it can contain quotes, backticks, newlines, and `$` — never
interpolate it inline into a shell command), then:

```bash
# 1. Parse + validate the {title, body} contract. Malformed → blocker, continue.
if ! $LIB/../scripts/run-jq.sh -e '.title and .body' < ".devflow/tmp/result-${SLUG}.json" >/dev/null 2>&1; then
    # Malformed: record a blocker and file NOTHING. The append below is the
    # load-bearing failure path — it MUST run (the run reports this pattern as a
    # blocker, never as filed), so it is concrete shell, not a comment.
    blockers+=("Pattern ${SLUG}: Stage B subagent returned malformed JSON (missing title/body) — not filed")
else
    # 2. Extract the body to a file (via jq, so backticks/$/newlines never hit
    #    the shell) and the title to a shell var.
    $LIB/../scripts/run-jq.sh -r '.body' < ".devflow/tmp/result-${SLUG}.json" > ".devflow/tmp/issue-body-${SLUG}.md"
    TITLE="$($LIB/../scripts/run-jq.sh -r '.title' < ".devflow/tmp/result-${SLUG}.json")"

    # 3. File exactly one issue. meta-issue.sh stamps DevFlow + Retrospective
    #    (best-effort), records the overrides.json cooldown, is idempotent (an
    #    open issue for this pattern → recurrence comment, not a duplicate), and
    #    fails CLOSED (non-zero exit) on a de-dup-lookup error or a create that
    #    returned no usable issue URL. An overrides-write failure AFTER a
    #    successful create is the one exception: the issue genuinely exists, so it
    #    reports FILED (exit 0 + URL + a loud ::error:: breadcrumb), not blocked —
    #    the next run's de-dupe recovers the missing cooldown.
    if ISSUE_URL="$(bash $LIB/meta-issue.sh \
            --tag "$TAG" \
            --slug "$SLUG" \
            --title "$TITLE" \
            --body-file ".devflow/tmp/issue-body-${SLUG}.md" \
            --overrides .devflow/learnings/overrides.json)"; then
        # Success: record {tag, url} in intervention_issues.
        intervention_issues+=("$($LIB/../scripts/run-jq.sh -nc --arg tag "$TAG" --arg url "$ISSUE_URL" '{tag:$tag,url:$url}')")
    else
        # meta-issue.sh exited non-zero (de-dup lookup / create-returned-no-URL;
        # an overrides-write failure does NOT land here — it reports FILED).
        # Record a blocker and file NOTHING — the pattern stays absent from
        # intervention_issues. Concrete append, same reason as above.
        blockers+=("Pattern ${SLUG}: meta-issue.sh failed to file the issue — not filed")
    fi
fi
```

**Never report a pattern as filed when it was not.** A malformed Stage B result
or a `meta-issue.sh` non-zero exit records a per-pattern blocker and the run
continues to the next pattern; the pattern is absent from `intervention_issues`.

**Do not** post `/devflow:implement` (or any auto-trigger comment) on a filed
issue — filed issues await human triage.

(`meta-issue.sh` mutates `.devflow/learnings/overrides.json` in your `main`
checkout's working tree. That happens **after** the Step 7 state PR was opened,
so the new cooldown lands in next week's state PR — see § Notes for the optional
follow-up commit if you want it in this run's PR.)

---

### Step 9 — Status report

Collect the per-analyzed-PR digest lines (verdict + a one-line summary) and the
full pattern list (acted-on, cooldown-skipped, dismissed, and below-threshold —
the same `patterns.json` from Step 6) so the report shows the whole picture, not
just the PRs that produced an intervention:

```bash
ANALYZED_JSON="$($LIB/../scripts/run-jq.sh -sc '[.[] | select(.verdict == "imperfect" or .verdict == "blocked") | {pr, verdict, summary}]' .devflow/tmp/new-entries.jsonl)"
PATTERNS_JSON="$(cat .devflow/tmp/patterns.json)"
```

Build the summary JSON and assign it to `$SUMMARY_JSON`:

```bash
SUMMARY_JSON="$($LIB/../scripts/run-jq.sh -nc \
  --argjson prs_scanned         "$prs_scanned" \
  --argjson clean_count         "$clean_count" \
  --argjson analyzed_count      "$analyzed_count" \
  --argjson analyzed            "$ANALYZED_JSON" \
  --argjson patterns            "$PATTERNS_JSON" \
  --argjson intervention_issues "$(printf '%s\n' "${intervention_issues[@]:-}" | $LIB/../scripts/run-jq.sh -sc '.')" \
  --argjson cooldown_skipped    "$(printf '%s\n' "${cooldown_skipped[@]:-}"    | $LIB/../scripts/run-jq.sh -sc '.')" \
  --argjson blockers            "$(printf '%s\n' "${blockers[@]:-}"            | $LIB/../scripts/run-jq.sh -sc '.')" \
  --argjson state_pr            "$STATE_PR" \
  '{prs_scanned:$prs_scanned,clean_count:$clean_count,analyzed_count:$analyzed_count,
    analyzed:$analyzed,patterns:$patterns,
    intervention_issues:$intervention_issues,
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
- **Filed issues** (one per actionable pattern, awaiting human triage): list
  each as `<tag>: <url>`

If there are any **blockers**, list them explicitly.

Tell the user:

> Review and merge the state PR once CI passes. Each filed issue awaits human
> triage — pick the ones worth acting on and run them through the normal
> implement → review pipeline; the loop never starts that for you. The loop is
> idempotent — re-running next week will only process new PRs not yet in
> `retrospectives.jsonl` on `main`, and a pattern already filed this cycle is
> not re-filed.

Do **not** run `gh pr merge --auto` on anything, and do **not** auto-start
implementation on a filed issue. The maintainer triages and merges manually
after reviewing.

---

## § Cron / headless variant

`claude -p "/devflow:retrospective-weekly" --permission-mode acceptEdits` handles steps
1–9 unattended. Stage B makes **no** working-tree edits (it only drafts issue
specs) and the orchestrator only files issues and writes `.devflow/learnings/`,
so the loop is well-suited to an unattended run. For a fully unattended run, add
`--dangerously-skip-permissions`.

---

## § Notes

- **Clean working tree required.** The loop modifies `.devflow/learnings/`
  in-place on `main`'s working tree; starting dirty risks mixing pre-existing
  changes into the state PR commit.
- **State PR before Stage B.** Opening the state PR (Step 7) before Stage B is
  intentional: it commits the learnings files onto `devflow/learnings-<date>`
  before any issue is filed, so this run's retrospective data is captured even
  if Stage B or the filing step fails partway. Stage B never touches your `main`
  checkout — it makes no edits at all.
- **Issue-per-pattern.** Stage B dispatches one drafting subagent per actionable
  pattern concurrently (each returns a `{title, body}` spec, no edits), then the
  orchestrator files exactly one GitHub issue per pattern via `meta-issue.sh`.
  No worktrees, no commits, no PRs — the loop proposes; a human implements.
- **Overrides after Stage B.** `meta-issue.sh` records each filed pattern's
  cooldown in `.devflow/learnings/overrides.json` in your `main` working tree
  **after** the Step 7 state PR was opened, so the change lands in next week's
  state PR automatically. If you want it in *this* run's PR, after Step 8 push a
  follow-up commit onto the same `devflow/learnings-<date>` branch:

  ```bash
  if ! git diff --quiet HEAD -- .devflow/learnings/overrides.json 2>/dev/null; then
      LB="devflow/learnings-$(date -u +%F)"
      git fetch origin "$LB"
      git checkout "$LB"
      git add .devflow/learnings/overrides.json
      git commit -m "chore(devflow): add overrides from Stage B filed issues"
      git push --force-with-lease origin "$LB"
      git checkout main
  fi
  ```
- **Idempotent.** Re-running re-processes only PRs whose number is not already
  in `retrospectives.jsonl` on `main`. A pattern already filed this cycle is not
  re-filed: `meta-issue.sh` finds the open issue and adds a recurrence comment
  instead of a duplicate, and the `overrides.json` cooldown excludes the pattern
  on subsequent runs.
- **Never auto-merge, never auto-implement.** The maintainer merges the state PR
  manually after CI, and triages each filed issue manually — the loop never
  starts an implement run for you.
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
  the path) — use `$LIB/../scripts/run-jq.sh -c -f $LIB/cheap-gate.jq < "$CTX"` where `$CTX` is
  the path.
