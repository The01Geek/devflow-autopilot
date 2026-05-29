---
name: implement
description: Use when a comment or message contains /devflow:implement followed by a GitHub issue number. Runs the full 4-phase lifecycle — setup, implementation, code review, and documentation.
argument-hint: <issue-number>
---
# /devflow:implement — Automated Feature Development Orchestrator

You are the main implementation agent. Execute the full 4-phase lifecycle for a GitHub issue. You hold continuous context from discovery through documentation — most work happens directly in your session.

**Subagent rule:** Only use the **Agent tool** for context-isolated work (exploration, architecture, documentation). Everything else — planning, implementation, testing, fixing — you do directly.

**Skill rule:** Use the **Skill tool** for `simplify` and `review-and-fix` during code review and `pr-description` for PR documentation. (`simplify` is the **built-in Claude Code `/simplify` slash-command** — always available, not a DevFlow plugin skill and not in any plugin list; invoke it via `skill: simplify` and never skip the step thinking it's missing.)

**Input:** GitHub issue number provided as `$ARGUMENTS`

## MANDATORY: All Four Phases Must Execute

```
Phase 1: Setup → Phase 2: Implement → Phase 3: Review → Phase 4: Documentation
```

**Every phase is mandatory regardless of issue complexity or size.** A one-line fix still needs review (Phase 3) and a proper PR description (Phase 4). Committing code is the HALFWAY point, not the finish line. The PR stays a *draft* until Phase 4.3 — that ordering keeps docs and description in place before downstream workflows see "ready".

Output the phase header at the start of each phase so progress is trackable.

---

## Workpad Reference

Throughout the run you maintain exactly **one** marker-tagged comment on the GitHub issue — the *workpad*. It is the run's **single GitHub comment** and durable progress surface, the immediate "job started" acknowledgment, and the thing re-runs and follow-up runs resume from. In cloud runs the `gate` job creates a lean workpad *before* the heavy `claude` job boots (so the acknowledgment lands as early as possible); Phase 1.3 then **detects and resumes** it, filling in the Plan and Acceptance Criteria — it never posts a second comment. In a local-tier run (no `gate` job) Phase 1.3 creates the workpad itself as the first GitHub write. Either way it is the source of truth for the acceptance-criteria gate in Phase 3, and claude-code-action's own progress comment is disabled (`track_progress: false` in `devflow-implement.yml`), so the workpad is the *only* comment a run posts.

**Status glyph (canonical, reaction-compatible).** The `Status` line always begins with a glyph that `workpad.py` derives from the status word — you pass a bare status (`--status Setup`, `--status Complete`, `--status Blocked`) and the helper prepends it: 🚀 for any in-progress phase (Setup/Discovering/Reproducing/Planning/Implementing/Reviewing/Documenting), 🎉 for `Complete`, 👎 for `Blocked`. The same vocabulary drives the triggering-comment reaction (🚀 `rocket` on pickup → 🎉 `hooray` on Complete → 👎 `-1` on Blocked), so the comment glyph and the reaction always match. (✅/❌ are *not* valid GitHub reactions, which is why 👎 is the Blocked glyph.)

**Outcome reaction on the triggering comment.** The `gate` job already added 🚀 `rocket` on pickup. At every **terminal** Status transition you must add the matching reaction to the *triggering* comment so the outcome is visible without opening the workpad: 🎉 `hooray` when you set `Status: Complete` (Phase 4.3), and 👎 `-1` at **any** `Status: Blocked` finalizer (the reaction is driven by the final workpad `Status`, not the job exit code — a run can exit 0 while `Blocked`). Reuse `react-to-trigger.sh` (same script the gate uses) rather than a bespoke `gh api` call; it is best-effort (always exits 0), so a reaction hiccup never blocks the run:

```bash
# REACTION=hooray for Complete, REACTION=-1 for Blocked.
# Resolve the triggering comment (best-effort): the newest issue comment that
# quotes /devflow:implement but is NOT the workpad (no marker). $GITHUB_EVENT_PATH
# also carries .comment.id when the event was a comment — prefer it when present.
TRIGGER_COMMENT_ID=$(jq -r '.comment.id // empty' "$GITHUB_EVENT_PATH" 2>/dev/null || true)
if [ -z "$TRIGGER_COMMENT_ID" ]; then
  TRIGGER_COMMENT_ID=$(gh api "repos/$GITHUB_REPOSITORY/issues/$ISSUE_NUMBER/comments?per_page=100" \
    --jq 'map(select((.body | contains("/devflow:implement")) and (.body | contains("devflow:workpad") | not))) | last | .id' 2>/dev/null || true)
fi
if [ -n "$TRIGGER_COMMENT_ID" ]; then
  REPO="$GITHUB_REPOSITORY" EVENT_NAME=issue_comment COMMENT_ID="$TRIGGER_COMMENT_ID" REACTION="$REACTION" \
    bash ${CLAUDE_SKILL_DIR}/../../scripts/react-to-trigger.sh || true
fi
```

If the triggering comment can't be resolved (a review-body trigger has no reactions API; the id lookup fails), skip the reaction silently — the workpad `Status` glyph remains the authoritative signal.

**GitHub autolink hygiene** (every GitHub surface you write — workpad comment, PR body, follow-up issue bodies, completion summary): never put a bare `#` immediately before a number unless it is a real issue or PR reference — GitHub renders `#2` as a link to issue/PR 2, which misleads readers. For an ordinal, count, or list position, spell it out ("item 2", "step 3"), never `#2`. Genuine references like `#123` stay as-is.

### Workpad section template

The workpad comment body MUST start with the marker line on its own line, followed by these sections (omit `Reproduction` when the issue is not labelled `bug`):

The always-visible region (marker line, header, `Status`, links, `## Progress`, `## Plan`, `## Acceptance Criteria`) stays uncollapsed so the comment is scannable at a glance. Append-only notes (`--note`) nest under their lifecycle phase *inside* `## Progress` — there is no separate Decisions / Notes section. Only `## Devflow Reflection` is wrapped in a `<details>` block so its accumulating bullets don't push the rest of the comment out of view. **Keep `## Acceptance Criteria` outside any `<details>`** — the Phase 3.4 gate reads it.

```markdown
<!-- devflow:workpad -->
# DevFlow Workpad — Issue #{number}

**Status:** 🚀 Setup
**Branch:** `{branch}`
**Run:** [View run]({run_url})
**PR:** _not yet created_
**Last updated:** {friendly UTC, auto-refreshed by `update`, e.g. 2026-05-05 17:42 UTC}

## Progress
- [ ] **Setup** — branch & workpad
  - {HH:MM:SS} — {append-only note, nested under the phase it was logged in}
- [ ] **Implement**
  - [ ] reproduction captured (bug issues only)
  - [ ] code + sweeps
- [ ] **Review**
  - [ ] `/simplify`
  - [ ] `review-and-fix`
  - [ ] acceptance-criteria gate
- [ ] **Documentation**
- [ ] **PR marked ready**

## Plan
- [ ] {step}

## Acceptance Criteria
- [ ] {criterion mirrored from issue body}

## Reproduction
{captured signal — failing test, error log, or repro command. Section only present for `bug`-labelled issues.}

## Devflow Reflection
<details>
<summary>Devflow Reflection (click to expand)</summary>

- {only when something was unclear, blocked, or deferred during execution}
</details>
```

`{run_url}` is `$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID` (standard runner env vars; no workflow change needed). When those env vars are absent (a local-tier run outside Actions), use a plain `_(local run)_` placeholder for the `Run` line. For `bug`-labelled issues the `reproduction captured (bug issues only)` sub-item is rendered; for non-bug issues pass `--no-reproduction` to `new-body` (1.3) so it isn't. (The cloud `gate` and the resume path create the skeleton label-agnostically, so this trimming applies to the local fresh-issue path.)

### Workpad helper CLI

Every workpad operation goes through the bundled `workpad.py` helper at `${CLAUDE_SKILL_DIR}/../../scripts/workpad.py`. The helper is stateless — each subcommand re-derives `REPO_FULL` and the marker on every invocation, so it works across Claude Code's per-call fresh-shell model without any env var or shell function needing to survive between Bash tool calls.

Subcommand reference:

| Command | Purpose |
| --- | --- |
| `workpad.py id ISSUE [--marker M]` | Print the workpad comment ID, or empty stdout with exit 2 if none exists (exit 1 on a gh-api/parse error). |
| `workpad.py body COMMENT_ID` | Print the full body of an existing workpad. |
| `workpad.py create ISSUE BODY_FILE` | Create the workpad on a fresh issue from a body file and print the new comment ID. Use at most once per issue (the cloud `gate` job already does this; the local fresh-issue path does it in 1.3). |
| `workpad.py new-body ISSUE [--run-link V] [--branch V] [--marker M]` | Print the lean initial workpad skeleton to stdout (Status/links/timestamp + empty `## Progress`, placeholder Plan/AC). Pipe to a temp file, then `create`. |
| `workpad.py update ISSUE [mutations...] [--marker M]` | Apply atomic mutations and PATCH. **This is the mutation entry point used at every phase boundary after creation.** See the flags below. |

The marker-locating subcommands (`id`, `new-body`, `update`) also accept `--marker M` to target a non-default marker comment (precedence: `--marker` > `DEVFLOW_WORKPAD_MARKER` env > `.devflow/config.json` > the built-in default). `/implement` does not pass it — it uses the default workpad marker; the flag exists for `/devflow:review`, which drives its own `devflow:review-progress` comment with the same helper.
| `workpad.py now` | Canonical UTC ISO-8601 timestamp. (`update` already refreshes `Last updated` automatically; use `now` only when you need a timestamp in some other string, e.g. a follow-up issue body.) |
| `workpad.py patch COMMENT_ID BODY_FILE` | Low-level body-file PATCH. Prefer `update`; only use this for bulk-rewrite cases the `update` flags don't cover. |

`workpad.py update` accepts (combinable, all optional):

| Flag | Effect |
| --- | --- |
| `--status STATUS` | Replace the Status line. Pass a **bare** status word — the helper prepends the canonical glyph (🚀/🎉/👎) and strips any glyph you pass, so re-applying is idempotent. |
| `--branch BRANCH` | Replace the Branch line. |
| `--run-link VALUE` | Set the `Run` front-matter line to VALUE (markdown ok). Inserted after `Branch` if the line is absent (legacy-workpad resume). |
| `--pr-link VALUE` | Set the `PR` front-matter line to VALUE (markdown ok). Inserted after `Branch` if absent. Used in Phase 3.1 once the draft PR exists. |
| `--tick-progress TEXT` | Tick one unticked `## Progress` checkbox whose text contains TEXT (substring), same zero/multi-match failure behavior as `--tick-plan`. **Repeatable.** |
| `--tick-plan TEXT` | Tick one unticked Plan checkbox whose text contains TEXT (substring). Fails if TEXT matches zero unticked checkboxes or multiple. **Repeatable** — pass multiple times to tick several boxes in one atomic update. |
| `--tick-ac TEXT` | Same, for Acceptance Criteria. **Repeatable.** |
| `--rewrite-ac OLD NEW` | Phase 2.2.6: find an AC by OLD substring, replace its full text with NEW, keep the box state. |
| `--note TEXT` | Append a note bullet, prefixed with a time-only `HH:MM:SS` UTC timestamp and nested under the current `Status`'s phase inside `## Progress` (Setup/Discovering/…/Complete map to the matching top-level phase row; Blocked nests under the most recent completed phase). **Repeatable** — multiple notes in one call share the same timestamp and are appended in argument order. |
| `--reflection TEXT` | Append a bullet to Devflow Reflection (no timestamp). **Repeatable.** |
| `--replace-plan-file FILE` | Replace the Plan section content with FILE. |
| `--replace-acs-file FILE` | Phase 2.2.5: replace Acceptance Criteria content with FILE. |
| `--set-reproduction-file FILE` | Phase 2.1.5: set the Reproduction section to FILE; inserts the section after Acceptance Criteria if it doesn't yet exist. |

`update` always re-fetches the live body before mutating (this narrows but does not eliminate the clobber window for concurrent edits; acceptable because the orchestrator is the single writer in practice), always refreshes `Last updated`, and PATCHes atomically — within a single `update` call, all of its mutations apply or none do. The patched body is printed to stdout so callers can verify the change actually landed.

Helper invariants baked into the script (orchestrator doesn't need to enforce them):
- Notes are append-only — `--note` only appends, never rewrites; each bullet nests under its lifecycle phase inside `## Progress` and carries a time-only `HH:MM:SS` prefix.
- `--reflection` is **`<details>`-aware**: because `## Devflow Reflection` is wrapped in a `<details>` block, the new bullet is inserted *inside* the block (before `</details>`), never after — so the collapsible region stays intact and the marker-first / AC-parseable invariants hold. (`--note` writes plain bullets into the un-wrapped `## Progress` section, so this doesn't apply to it.)
- The `Status` glyph is owned by the helper — `--status` derives and prepends it, and a note's phase is resolved from the bare (glyph-stripped) Status word.
- Devflow Reflection accumulates bullets — `--reflection` only appends.
- `--tick-*` flags edit only the box character and preserve the rest of the line.
- `--rewrite-ac` preserves the original checkbox state (don't tick during a 2.2.6 rewrite — the gate ticks later via `--tick-ac`).
- Heredoc / shell-interpolation hazards are eliminated — body content never traverses bash quoting; everything goes through files.

The helper reads `devflow.workpad_marker` from `.devflow/config.json`, falling back to the built-in default `<!-- devflow:workpad -->` when the config file or key is absent (so it works with no config). It fails fast (exit 1 with a clear stderr message) when `gh` can't resolve the repo, when the underlying API call fails, or when a `--tick-*` / `--rewrite-ac` flag's substring matches zero or multiple checkboxes. `--tick-plan` / `--tick-ac` only consider unticked (`[ ]`) rows, so a duplicate tick in a single batched call surfaces as "no unticked checkbox matched" rather than silently no-op'ing.

**Never create a second workpad on the same issue.** Phase 1.2 creates exactly one; every subsequent mutation goes through `update`. If you lose `$ISSUE_NUMBER` mid-run (context compaction), recover from `git log`, `git branch --show-current`, and `gh pr list --head $(git branch --show-current)` — then resume with `workpad.py update $ISSUE_NUMBER ...`.

When a workpad already exists at the start of a re-run, treat its `## Progress` notes and `Devflow Reflection` as load-bearing context — read them via `workpad.py body $(workpad.py id $ISSUE_NUMBER)` before deciding what to do next. (A `gate`-pre-created workpad on a fresh issue carries only the run-started note, so there is nothing prior to reconcile.) If `Status` is `Blocked`, surface `Devflow Reflection` to the user and pause for confirmation before proceeding past Phase 1 — otherwise an automated re-run will blow through the gate that originally stopped the previous run.

**Always verify a Status PATCH actually landed.** `update` prints the new body on stdout — confirm the new `Status:` line is present before advancing to the next phase. (`gh api -X PATCH` can return success while the comment body is unchanged: transient API errors, oversized bodies, throttling.) If the response shows a stale `Status`, re-issue the `update` before continuing. Plan/Notes-only updates don't need this check.

---

## Phase 1: Setup

Output: `Phase 1/4: Setup — creating the workpad and branch...`

**Ordering matters in Phase 1.** The workpad is the run's *only* GitHub comment and its "job started" acknowledgment. In a cloud run the `gate` job has already created a lean workpad before this skill starts, so 1.3 **resumes** it; in a local-tier run 1.3 creates it as the **first GitHub write** — either way before the branch (1.4). Fetch the issue (1.1) and parse its acceptance criteria (1.2) first because the workpad body mirrors them; then initialize-or-load the workpad and populate its Acceptance Criteria; then create the branch and immediately fill the workpad's `Branch` line.

### 1.1 Fetch the GitHub Issue

Run:
```bash
gh issue view $ARGUMENTS --json title,body,labels,number
```

If this fails, stop immediately and report: "Error: Could not fetch GitHub issue #$ARGUMENTS. Verify the issue number exists."

Save the issue title, body, labels, and number — you will use these throughout the workflow. Note whether the labels include `bug` — Phase 2.1.5 depends on it.

### 1.2 Parse Acceptance Criteria from the issue body

Run the bundled parser to extract `## Acceptance Criteria` and (optional) `## Test Plan` sections from the issue, pre-classifying each criterion as either code-verifiable or *post-merge*:

```bash
${CLAUDE_SKILL_DIR}/../../scripts/parse-acs.py --issue $ARGUMENTS > /tmp/acs-${ARGUMENTS}.md
```

The output is checkbox lines ready to splice into the workpad's `## Acceptance Criteria` section, with ` (post-merge)` appended to any criterion whose text matches the bundled trigger phrases (see `parse-acs.py`'s `POST_MERGE_TRIGGERS` list for what's matched). When no AC section exists, the helper prints `_(none provided in issue body)_` and Phase 3.4 passes trivially.

A post-merge criterion is **not** deferred work (that's the 2.2.5 rule) — the code is in-scope and ships in this PR; only the *verification* happens after merge. The Phase 3.4 gate ignores `(post-merge)`-tagged items for blocking; /pr-description in Phase 4.2 surfaces them as a `## Post-Merge Verification` checklist in the PR body.

**Orchestrator override authority.** The trigger-phrase classifier is a heuristic, not exhaustive. After running the helper, eyeball each criterion and override if needed:
- *Demote to code-verifiable* — when a matching phrase appears inside quoted/example text within the criterion rather than describing the verification step itself (e.g. the criterion quotes a function name that happens to contain "click"). Strip the ` (post-merge)` suffix in the file before mirroring.
- *Promote to post-merge* — when no trigger phrase matched but the criterion's intent clearly requires a live PR/deploy/CI environment. Append ` (post-merge)`.

Either kind of override goes into the workpad notes (`--note`) with a one-line reason.

A criterion that is partially live (mixed code + live concerns) is tagged post-merge — verify the code-part during /devflow:implement, leave the live-part for after-merge.

### 1.3 Initialize or Load the Workpad

The workpad is created before the branch exists so the requester sees an acknowledgment immediately. In a cloud run the `gate` job already posted a lean workpad; in a local run you create it here. Set `ISSUE_NUMBER=$ARGUMENTS`, derive the run link, and check whether a workpad already exists:

```bash
ISSUE_NUMBER=$ARGUMENTS
RUN_URL="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"   # "/actions/runs/" segment is literal; empty env (local run) → use a "_(local run)_" placeholder
WORKPAD_ID=$(${CLAUDE_SKILL_DIR}/../../scripts/workpad.py id "$ISSUE_NUMBER" || true)
```

- **`WORKPAD_ID` empty (fresh issue — local-tier run with no `gate` job)** → Build the lean skeleton with the helper and create it, then mirror the issue's Acceptance Criteria into it:
  ```bash
  BODY=$(mktemp)
  # Add --no-reproduction for non-bug issues (labels from 1.1) so the bug-only
  # "reproduction captured" sub-item isn't rendered; omit the flag for bug issues.
  workpad.py new-body $ISSUE_NUMBER --run-link "[View run]($RUN_URL)" > "$BODY"   # + --no-reproduction unless the issue is bug-labelled; omit --run-link for a local run
  workpad.py create $ISSUE_NUMBER "$BODY"
  workpad.py update $ISSUE_NUMBER --replace-acs-file /tmp/acs-${ARGUMENTS}.md
  ```
  `new-body` seeds `**Status:** 🚀 Setup`, the `**Branch:** _(creating…)_` placeholder (filled in 1.4 the instant the branch exists), the friendly `Last updated`, the `## Progress` checklist (the bug-only `reproduction captured` sub-item is rendered only when `--no-reproduction` is omitted) with the `/devflow:implement run started` note nested under Setup, a placeholder `## Plan` (filled in 2.2), a placeholder `## Acceptance Criteria` (you replace it above), and an empty `## Devflow Reflection` `<details>` block. The `## Reproduction` section is added later in 2.1.5 if applicable.
- **`WORKPAD_ID` non-empty (resume — the normal cloud path, since `gate` pre-created it; or a re-run)** → Read the live body with `workpad.py body $WORKPAD_ID`. Treat its `## Progress` notes and `Devflow Reflection` as load-bearing context (see Workpad Reference). Reset for this run **and populate the Acceptance Criteria** (a `gate`-created workpad carries only a placeholder AC section, so always replace it):
  ```bash
  workpad.py update $ISSUE_NUMBER \
      --status Setup \
      --run-link "[View run]($RUN_URL)" \
      --replace-acs-file /tmp/acs-${ARGUMENTS}.md \
      --note "/devflow:implement run resumed"
  ```
  **Legacy-workpad migration (required):** a workpad created before run/PR links and the `## Progress` checklist existed won't have those lines. `--run-link`/`--pr-link` insert the missing header lines on their own, but `--tick-progress`/`--note` (used at every later phase boundary) will **abort the run** with `section '## Progress' not found` if the section is absent. So when resuming such a workpad you MUST seed a `## Progress` section before Phase 1.5 — `workpad.py body` the live comment, splice the `## Progress` checklist from the template above into the body (right after the front-matter, before `## Plan`), and `workpad.py patch $WORKPAD_ID <file>`. Do not leave it to chance: skip this and the first `--tick-progress`/`--note` call fails closed.

After this step, every later phase boundary touches the workpad via `workpad.py update $ISSUE_NUMBER ...` — no `WORKPAD_ID` variable to track across calls.

### 1.4 Create or Detect Feature Branch

Check if you're already on a feature branch (the GitHub Action creates one automatically):
```bash
git branch --show-current
```

If the current branch matches `claude/issue-*` or `issue-*`, use it — skip branch creation.

Otherwise, create a new branch. The canonical branch name is computed by the helper (handles slugification, unicode, length truncation, and collision suffixing deterministically):

Write the issue title (from the `gh issue view` above) to a temp file with the **Write tool** — `/tmp/devflow-issue-$ARGUMENTS-title.txt` — then derive the branch from it. Using `--title-file` instead of passing the title as a positional shell argument avoids breakage when the title contains quotes, backticks, or `$`.

```bash
git fetch origin main
BRANCH=$(${CLAUDE_SKILL_DIR}/../../scripts/branch-for-issue.py $ARGUMENTS --title-file /tmp/devflow-issue-$ARGUMENTS-title.txt)
git checkout -b "$BRANCH" origin/main
```

**Immediately fill the workpad's `Branch` line** (so the placeholder from 1.3 is never left on a completed run):
```bash
workpad.py update $ISSUE_NUMBER --branch "$(git branch --show-current)"
```

### 1.5 Push Branch

```bash
git push -u origin HEAD
```

Then tick the Setup phase in the workpad's `## Progress` checklist:
```bash
workpad.py update $ISSUE_NUMBER --tick-progress "branch & workpad"
```

---

## Phase 2: Discover, Plan & Implement

Output: `Phase 2/4: Discover, Plan & Implement...`

Update the workpad: `workpad.py update $ISSUE_NUMBER --status Discovering --note "entered Phase 2"`.

### 2.1 Discovery

Use the **Agent tool** with `subagent_type: feature-dev:code-explorer` to explore the codebase and understand the system as it relates to the issue.

**The issue body is a starting point, not the source of truth.** Treat its problem framing, any stated root cause, and its Technical Context as a strong lead to *verify* — never fact to implement on faith. The explorer (and the architect in Path B) confirm the issue's claims against the actual code; where they diverge, **the code wins**: surface the divergence in the workpad and plan from what the code shows, rather than implementing a claim the code contradicts.

**Pick the exploration map first.** Default is `.docs.internal`. Override it when the issue scope sits outside app code — scan the issue body for path mentions (`.github/workflows/`, `.claude/`, `scripts/`, `cron/`, `tools/`, etc.) or a section headed "Technical Context", "Relevant files", "Files to touch", "Files to change", or "Implementation files"; collect those paths as `PRIMARY_PATHS` and instruct the explorer to read them first, falling back to `.docs.internal` only for gaps. Otherwise `PRIMARY_PATHS` stays empty and the default applies.

Pass the following prompt:
- The GitHub issue title, body, and labels
- **Explicit instruction:** "Start by reading {PRIMARY_PATHS if non-empty, otherwise the internal documentation path from `.devflow/config.json` via `${CLAUDE_SKILL_DIR}/../../scripts/config-get.sh .docs.internal docs/internal/`} and read relevant files under that path to understand the system architecture and identify which modules and files are relevant to this issue. Use the documentation as a map to guide your code exploration. Then explore the actual code guided by those findings. Return a distilled summary of: relevant files, current behavior, patterns used, dependencies, and anything the implementer needs to know."

Documentation updates are handled in Phase 4 by the `devflow:docs` subagent — it has the full picture (the shipped code, not just the plan) and the right mandate. Do not edit `.docs.internal` here; if the explorer surfaced outdated or missing docs, that signal carries forward in your context to Phase 4.1 where the subagent will act on it.

### 2.1.5 Reproduce-First Gate (only for `bug`-labelled issues)

If the issue's labels (saved in 1.1) **do not** include `bug`, skip this step entirely and continue to 2.2.

If the labels **do** include `bug`, you must capture a *reproduction signal* before planning a fix. A reproduction signal is any one of:

- a new failing test in the diff that exercises the bug,
- a quoted error log / stack trace from a real run, or
- a recorded shell command (with output) that demonstrates the failure.

Write the evidence to a temp file, then: `workpad.py update $ISSUE_NUMBER --status Reproducing --set-reproduction-file /tmp/repro-${ISSUE_NUMBER}.md --tick-progress "reproduction captured" --note "captured reproduction signal"`. (The helper inserts `## Reproduction` after `## Acceptance Criteria` if it doesn't yet exist.)

**Temporary proof edits are allowed** when they raise confidence in the reproduction (e.g. inserting a `console.log`, hardcoding a request payload, tweaking a build input). Every temporary proof edit MUST be reverted before the implementation commit in 2.5, and the fact that you made one must be recorded in the workpad's `Reproduction` section so reviewers can follow the evidence.

**Phase 2.2 cannot start until the workpad's `Reproduction` section is populated.** If you cannot reproduce the bug: `workpad.py update $ISSUE_NUMBER --status Blocked --reflection "cannot reproduce: {obstacle}"`, then emit the 👎 outcome reaction (see *Outcome reaction* in the Workpad Reference) and stop the run — do not invent a fix.

### 2.2 Assess Complexity & Plan

`workpad.py update $ISSUE_NUMBER --status Planning`.

Using the explorer's findings (and the reproduction signal, for bugs), evaluate the issue complexity:

**Simple issues** (implement directly — skip architect):
- Single-module changes (e.g., add a field, fix a bug, update a config)
- Clear solution described in the issue body
- No architectural decisions needed
- Touches ≤ 5 files

**Complex issues** (use architect subagent):
- Cross-module changes affecting multiple subsystems
- New features requiring design decisions
- Changes to interfaces, data models, or system architecture
- Ambiguous requirements needing breakdown into tasks

#### Path A: Simple issue

Output: `Skipping architect — issue is straightforward. Implementing directly.`

Plan the implementation inline using the explorer's findings. Identify which files to create/modify and what changes to make.

#### Path B: Complex issue

Use the **Agent tool** with `subagent_type: feature-dev:code-architect` to design the implementation.

Pass it:
- The full GitHub issue content (title, body, labels)
- The explorer's distilled findings as inline context, prefixed with: "The code-explorer analyzed the current codebase and produced the following findings:"

The architect returns a focused blueprint (files to create/modify, component designs, data flows, build sequence). Hold this blueprint in your context — do NOT commit it (it is a temporary working artifact).

#### 2.2.4 Reuse & Altitude gate (mandatory, before the plan is written)

Two of the cleanup lenses that the Phase 3.2 `/simplify` pass would otherwise flag — **reuse** and **altitude** — are *design* decisions, far cheaper to make now than to refactor out of a finished diff. Apply both to the plan (from either path) before you write it to the workpad:

1. **Reuse.** For every piece of new code the plan proposes (a helper, a parser, a validator, a state shape, an API client), grep the shared/utility modules and the files adjacent to the change for something that already does the job. If it exists, the plan reuses the existing helper by `file:line` rather than re-implementing it. New code is justified only when no existing implementation fits — don't propose new code when a suitable one already exists.
2. **Altitude.** Check that each planned change sits at the right depth, not as a fragile bandaid. A pile of special cases layered on shared infrastructure is the signal that the fix isn't deep enough — prefer generalizing the underlying mechanism over stacking special cases. If the plan is reaching for a special-case patch, ask whether the shared mechanism should change instead, and re-aim the plan there.

Fold the result into the plan: name the helpers to reuse (with `file:line`) in the relevant plan steps, and pick the altitude before writing the steps. This is a planning gate, not a code edit — it changes *what you will write*, so it must precede the plan write below.

After planning (either path), write the plan steps as `- [ ]` checkboxes to a temp file, then `workpad.py update $ISSUE_NUMBER --replace-plan-file /tmp/plan-${ISSUE_NUMBER}.md`.

#### 2.2.5 Scope-Adjustment Rule (multi-PR issues)

If discovery and planning revealed that the issue's deliverables span more than fits in a single PR (e.g., a phased cleanup, a multi-stage migration, or any issue whose acceptance criteria explicitly enumerate work for several future PRs), **you must narrow the workpad's `## Acceptance Criteria` to only the items this PR will deliver** before continuing to 2.3. Otherwise the Phase 3.4 gate will reject your run for criteria that are out-of-scope by design, and the run will stop without ever reaching Phase 4.

Steps when scoping down:

1. Write the narrowed AC list (only in-scope checkboxes, verbatim) to a temp file, e.g. `/tmp/narrowed-acs-${ISSUE_NUMBER}.md`.
2. Apply the change atomically:
   ```bash
   workpad.py update $ISSUE_NUMBER \
       --replace-acs-file /tmp/narrowed-acs-${ISSUE_NUMBER}.md \
       --note "scope decision: {which subset this PR delivers}. Deferred (verbatim): {list}. Will be tracked in follow-up issue(s) filed in Phase 4.0."
   ```

This is not "inventing" criteria (forbidden by 1.4) — the deferred items are preserved verbatim in the workpad notes (`--note`) and carried forward by Phase 4.0.

If you are unsure whether to scope down, prefer a single fully-in-scope PR. Only re-scope when the issue body itself describes phased work or the diff would otherwise exceed reasonable PR size.

#### 2.2.6 AC-Plan reconciliation (rewrite surface details, never relax intent)

Some ACs name specific identifiers (job names, file paths, function names, command names). If the plan you settled on — or a later refactor in /simplify (3.2) or /devflow:review-and-fix (3.3) — uses different identifiers for the *same underlying behavior*, the literal AC text becomes stale and Phase 3.4 will reject a strictly-correct refactor. You may rewrite the affected AC in the workpad **only if** the rewritten text verifies the same observable outcome with the new identifiers; never relax what's verified.

Reconciliation steps:
```bash
workpad.py update $ISSUE_NUMBER \
    --rewrite-ac "{OLD AC substring}" "{NEW AC text}" \
    --note "AC rewrite: {old verbatim} → {new}. Motivated by: {structural change}"
```
`--rewrite-ac` preserves the box state (don't tick during the rewrite — Phase 3.4 will tick via `--tick-ac` later). This is **not** scope adjustment — the rewritten AC is still gated in 3.4.

If the rewrite would relax the AC (drop a guarantee, weaken a check, remove a verification surface), STOP — apply 2.2.5 (defer the AC to a follow-up issue) or revert the structural change instead.

### 2.3 Implement

`workpad.py update $ISSUE_NUMBER --status Implementing`.

Now implement the feature yourself. You have full context:
- The explorer's system understanding
- The architect's blueprint (if complex) or your own inline plan (if simple)
- The original issue requirements

Write the code. Follow the patterns and conventions described in `CLAUDE.md`. As plan steps complete, tick them off: `workpad.py update $ISSUE_NUMBER --tick-plan "{substring of completed step}"`.

**Sweep selection (run first).** The 2.3.x sweeps below are **not a flat checklist** — classify the diff and run the sweeps its shape warrants (**when in doubt, run them all**). Each sweep's heading states its own authoritative trigger; this list only tells you which to *consider*:

- **Deletes** code (a call site, branch, method, file, route, page, or asset) → run **2.3.1**, and **2.3.2** if it deletes a method/file/route/page.
- **Changes a contract** (a signature, a renamed/moved symbol, a tightened validator, or a routing/branch predicate) → run **2.3.0**.
- **Always**, whatever the diff's shape → run **2.3.3** (convention), **2.3.4** (boundary-assumption), **2.3.5** (simplification & efficiency).

This narrows *ceremony*, never *coverage*, and is **fail-safe**: each sweep's heading is authoritative, so if its trigger fires you run it even when this list didn't call it out — if the index ever drifts from a heading, the heading wins (drift can only add a sweep, never skip a warranted one). An add-only diff typically runs just the three always-on sweeps.

For the grep-based sweeps (**2.3.0**, **2.3.2**), don't merely attest you grepped: run the actual `git grep -n` / `grep -rnE` the sweep describes and record a **concise** result via `--note` (the match count plus "all intended", or the specific offending sites) — evidence, not a claim.

#### 2.3.0 Changed-contract sweep (mandatory whenever the change modifies a signature, renames/moves a symbol, tightens a validator, or changes a routing/branch predicate)

2.3.1–2.3.3 below all trigger on *deletion* or *addition*. Modifying a contract is just as blast-radius-prone, but it slips past `git diff` review because every dependent site still compiles — the call resolves, the fixture parses, the assertion runs — and is only *semantically* stale. After any change that modifies a signature, renames or moves a symbol, tightens a validator, or alters a predicate that classifies input, before running tests, grep the whole repo for every dependent site and bring each into line:

1. **All variants of a changed predicate.** If you changed a predicate that classifies input (e.g. a check for one specific status, type, or keyword), enumerate every value the predicate must now accept or reject and confirm every runner/branch routes them identically. A predicate fixed at one site but not its siblings is a defect in *this* PR, not a follow-up.
2. **Sibling call sites of a shared dependency.** If you wrapped or extended a shared object (e.g. added a per-request guard or a new error branch), grep for every caller that consumes that object and confirm each one plumbs the new inputs and handles the new branch — not just the site that motivated the change.
3. **Fixtures and assertions matching the old contract.** If you tightened a validator or moved output between streams (e.g. stdout↔stderr), grep tests for every fixture value and assertion that encoded the old contract — both in the files you touched *and* in shared `conftest.py` / helper modules — and update them. A fixture under a newly-stricter validator, or an assertion on a stream you rerouted, is a CI failure waiting for the next merge.

A modify / rename / reroute is not done until grepping for the old symbol, predicate value, stream, or contract returns only the intended sites.

**Re-run this sweep after any merge or rebase of `main`.** A clean *textual* merge is not a clean *semantic* merge: `main` may have added a fixture, call site, or assertion (often from a concurrently-merged PR) that your new contract now rejects, and git merges it cleanly without ever surfacing the conflict. After any `git merge main` / `git pull --rebase` the run performs (including the Error Handling conflict-recovery path), re-run steps 1–3 against the newly-arrived sites and treat any new site that violates the change's contract as a defect in *this* PR. See [`docs/implement-skill.md`](../../docs/implement-skill.md) for why each Phase 2.3 sweep exists.

#### 2.3.1 Orphaned-setup sweep (mandatory whenever the change deletes code)

Removing a call site, a UI block, a branch, or a whole function almost always strands the *setup lines* that fed it — a service-locator/dependency fetch, a query or record lookup, a computed local, an import or `use` clause — whose only consumer was the code you just deleted. These survive `git diff` review because nothing is *syntactically* broken; the line is simply dead. Reviewers keep flagging them as "optional cleanup", which means the PR shipped imperfect.

After every deletion, before running tests, do this sweep:

1. List the functions/methods/templates your diff removed lines from (`git diff --staged -U0` or `git diff -U0`).
2. For each one, re-read the **whole** surrounding function in its post-edit state.
3. Delete any local that is now assigned but never read, and any import / `use` clause / dependency declaration that lost its only consumer.
4. If something is *still* used elsewhere in the function, leave it; this sweep removes only genuinely-orphaned lines, never live ones — and never touch functions the diff didn't already modify.

Treat a leftover orphaned setup line as a defect in **this** PR, not a pre-existing-dead-code excuse — if the diff touched the function, the function leaves clean.

#### 2.3.2 Stranded-dependents sweep (mandatory whenever the change deletes a method, file, route, or page)

2.3.1 prunes dead lines *inside* the functions you touched. This sweep handles the inverse blast radius — the things *outside* your diff that the deletion stranded. When a removal/cleanup PR deletes its primary target, it routinely leaves dangling artifacts the deletion stripped of purpose: now-callerless public methods, leftover asset files, dead arguments still being passed to a callee that stopped reading them, and — worst — *surviving* pages, links, menu entries, or route references that still point at the code you just deleted (a guaranteed 404 / fatal for users).

After deleting any public method, class, file, page, route, endpoint, asset, or template, before running tests, do this sweep:

1. **Now-orphaned public surfaces.** For every public method or function you removed the *callers* of (not the function itself), and for every file/asset the just-deleted code was the sole consumer of: grep the whole repo for remaining references. Zero references → it is part of *this* removal; delete it too. (E.g. a public method left as a zombie with zero callers after its only caller was removed; an image/template asset left after its sole consumer was deleted.)
2. **Dead arguments to changed callees.** For every callee whose signature or body you changed so it stops reading some inputs: re-check each call site and stop passing the now-ignored arguments/keys. (E.g. a caller still passing several now-dead keys into a helper after the receiver stopped reading them.)
3. **Surviving inbound links and route refs.** For every page, route, endpoint, or file path you deleted: grep the repo for that path/URL/route name (links in templates, menu/nav configs, `href`s, redirects, route tables, sitemap entries). Every surviving reference is a regression — remove the link, or restore the target if it was deleted in error. (E.g. a navigation page still linking to a sub-page after that sub-page's source file was deleted → users hit a 404.)
4. **In-scope subtree completeness.** If the issue scopes a directory/feature subtree for removal, walk the *whole* subtree — do not stop at the files the obvious entry points reference. An untraversed leaf page that still calls the deleted integration is in scope by definition. (E.g. an orphan leaf file left in place still calling the deleted integration, linked from a surviving index page, despite sitting inside the in-scope subtree.)

Treat any stranded dependent as a defect in **this** PR. A deletion PR is not done until grepping for the deleted symbols/paths returns nothing but the deletion itself.

**Scope boundary with Phase 4.1 (*Update Documentation*).** This sweep covers references in *code, config, and routing tables* — i.e. things that break behavior at runtime if left dangling. Prose references to the deleted symbols/paths inside `docs/internal/` (descriptions, walkthroughs, "to install X, do Y") are **not** in scope here; they are handled by the Phase 4.1 documentation pass (`devflow:docs` subagent). If your grep turns up only docs hits, note them and move on — do not edit `docs/internal/` from this phase.

#### 2.3.3 Convention-compliance sweep on touched code (mandatory)

Same principle as 2.3.1, applied to `CLAUDE.md` conventions instead of dead code: **any function, method, query, or new file your diff added or modified lines in must conform to the conventions in `CLAUDE.md` when you leave it** — even if the violation was already there before you touched it, and even if "everything around it does it the same way." Recurring offenders that reviewers keep flagging as *Important* and that then ship anyway:

- A function signature left non-conforming after you edited it (e.g. argument shape, parameter style, return type) — whatever the project's CLAUDE.md mandates for function definitions in that language.
- A raw query/literal string in code you touched that violates the project's style rules (quoting, casing, identifier escaping) — whatever the project's CLAUDE.md mandates for embedded queries or literals.
- A new variable, method, file, or identifier you introduced that copies a legacy misspelling or non-conforming name from a sibling file — whatever the project's CLAUDE.md mandates for naming. "It matches the established convention across the existing code" is **not** a valid reason to propagate a misspelled or non-conforming name into new code; name the new thing correctly.

After implementing, before running tests, do this sweep:

1. From `git diff --staged -U0` (or `git diff -U0`), list every function/method/query/new file your diff added or changed lines in.
2. Re-read each one in its post-edit state and check it against the rules in `CLAUDE.md` that apply to the languages and surfaces your diff touched.
3. Fix any violation in code the diff already touches. If fixing it cleanly is genuinely out of scope (it would balloon the diff into an unrelated refactor), say so explicitly in the workpad notes (`--note`) with the reason — do not leave it silent for `/devflow:review` to catch.
4. Do not reformat or rename code the diff didn't otherwise touch — this sweep covers only lines/functions/files your change already modified or introduced, never a repo-wide cleanup.

Treat a known convention violation in touched code as a defect in **this** PR, not a pre-existing-style excuse — if the diff touched it, it leaves `CLAUDE.md`-compliant.

#### 2.3.4 Boundary-assumption verification sweep (mandatory)

2.3.0–2.3.3 keep the diff internally consistent (contract changes propagated, no dead lines, no stranded dependents, no convention drift). This sweep targets a different defect class: a claim your diff *depends on* about something **outside the lines you wrote** that you asserted from memory instead of verifying against the source of truth. These ship clean — the code reads fine in `git diff` review, and they pass your own tests (because the tests encode the same wrong assumption) — so they only surface as a `/devflow:review` REJECT or a human post-merge patch. The cheapest place to catch them is here, before you commit.

A **boundary assumption** is any factual claim the diff relies on about something the diff does not own. The recurring kinds:

- **Dependency-version behavior** — a symbol, export, signature, or runtime behavior of a third-party package. Verify it against the **pinned range's** actual installed source/changelog, not the latest docs (e.g. importing a symbol that is only public in a version newer than your dependency pin permits, so an in-constraint install breaks at import).
- **Supported-runtime behavior** — a behavior of the language, standard library, or interpreter. Verify it holds across the project's **entire** documented supported-runtime range, not just the version in your hands.
- **Sibling-producer output** — the shape or content of data produced by another module your code consumes. Verify it by reading the **production producer**, not by assuming a field is populated (e.g. consuming a field that the producer hard-codes empty).
- **Real host/runtime environment** — a path, base URL, network namespace, or sandbox constraint of where the code actually runs. Verify against the **real host**, not the local dev shell (e.g. relative asset paths that resolve locally but 404 under the deployed base URL).

After implementing, before running tests, do this sweep:

1. From `git diff --staged -U0` (or `git diff -U0`), list every claim the diff depends on that falls into one of the four kinds above. The diff is the *trigger* for finding which boundaries the change now relies on — a boundary's definition site (an unchanged import, a producer module, a version pin) usually sits in context `-U0` doesn't print, so follow each claim to its actual source. Purely-internal claims (a local you just wrote, a function defined in the same diff) are **out of scope** — this sweep is only about boundaries you don't own.
2. For each claim, verify it against the **actual source of truth** — the pinned version's installed source/changelog, the producer module, the documented supported-runtime range across *all* of it, the real host — never from memory.
3. **A test assertion about a boundary is itself an unverified claim.** A test that asserts a wrong boundary value still passes — it encodes the bug rather than catching it — so a green run at 2.4 is not confirmation. When the diff adds or changes a test that asserts a boundary value, verify that value against the same source of truth here.
4. If the code is wrong, fix it. If a boundary genuinely **cannot** be verified in-environment, do **not** assert it as true: always record the gap with `workpad.py update $ISSUE_NUMBER --reflection "unverified boundary: {claim} — needs {live env} to confirm"` so it is visible to review and the merger. If — and only if — a specific acceptance criterion's verification depends on that boundary, additionally retag that criterion `(post-merge)` (per Phase 1.2, via the Phase 3.4 `--rewrite-ac` retag pattern) so the 3.4 gate doesn't block on a live-only check. `(post-merge)` covers code that ships correct but can only be *verified* live — it is never a way to wave through a boundary you suspect is wrong (that is a blocker).

Treat an unverified boundary assumption as a defect in **this** PR, not a review-engine problem to be caught downstream — if the diff depends on it, verify it here or route it to `(post-merge)` with a reflection note.

#### 2.3.5 Simplification & Efficiency sweep (mandatory)

2.3.0–2.3.4 keep the diff correct, dead-line-free, and convention-clean; the 2.2.4 gate already settled reuse and altitude at plan time. This sweep handles the two remaining cleanup lenses that only become visible once the code is *assembled*.

After implementing, before running tests, re-read every function your diff added or changed lines in (from `git diff --staged -U0` or `git diff -U0`) and apply both lenses:

1. **Simplification.** Flag and remove unnecessary complexity the diff *adds*: redundant or derivable state (a field that's always recomputable from another), copy-paste with slight variation (collapse to one parameterized form), needless deep nesting (flatten with early returns), and dead code the diff leaves behind. For each, write the simpler form that does the same job.
2. **Efficiency.** Flag and fix wasted work the diff *introduces*: redundant computation or repeated I/O inside a loop or hot path that could be hoisted or cached, independent operations run sequentially that could run together, and blocking work added to startup or a hot path. Reach for the cheaper alternative — but don't trade clarity for a micro-optimization that doesn't sit on a hot path.

Scope and discipline mirror the other 2.3.x sweeps: only touch functions/files the diff already added or changed lines in — never a repo-wide refactor. If a simplification is real but cleanly fixing it is genuinely out of scope (it would balloon the diff into an unrelated refactor), say so explicitly in the workpad notes (`--note`) with the reason rather than leaving it silent. Reuse and altitude are **not** re-litigated here — they were decided in 2.2.4; this sweep is only simplification and efficiency.

Treat avoidable added complexity or wasted work in touched code as a defect in **this** PR, not a `/simplify` problem to be caught downstream.

### 2.4 Test

Run the project's test and lint commands (check `CLAUDE.md` or `README`). Issue both Bash calls in a single assistant turn so they run in parallel.

- If **both pass** → proceed to committing.
- If **either fails** → fix the failing tests/lint errors yourself (you wrote the code, you have full context). Re-run the failing command(s) to verify.

**When the deliverable can't be exercised by a test, a green suite is not enough.** A change whose deliverable is prose, templates, config, or an embedded DSL (jq or shell inside Markdown, a SKILL.md procedure) is invisible to the test suite — passing tests say nothing about it. Match the verification to the deliverable: for a **logic-bearing** artifact (config, template, jq/shell-in-prose), enumerate an **adversarial input-shape matrix** — the corrupt, empty, scalar-where-object-expected, and edge shapes — and statically dry-trace the logic against each; for **pure prose** (e.g. a reworded procedure), trace it against representative scenarios. Record the traces concisely in a workpad `--note`. (This is the same lesson the review engine's shape-sweep learned the expensive way — run it as your *opening* move on parser/best-effort code, not after three review iterations.)

### 2.5 Commit Implementation

For `bug`-labelled issues: confirm any temporary proof edits made in 2.1.5 have been reverted. Verify with `git diff HEAD` and `git diff --staged`. The working tree about to be committed must NOT include any stray `console.log`s, hardcoded payloads, or other proof-only edits.

Stage and commit all implementation changes:

```bash
git add -A
git commit -m "feat: implement issue #$ARGUMENTS — {short description from issue title}"
git push
```

If the commit includes test fixes, use a single commit combining implementation and fixes.

Then tick the implementation gate **and its parent phase** in the workpad: `workpad.py update $ISSUE_NUMBER --tick-progress "code + sweeps" --tick-progress "**Implement**"`.

### 2.6 Version & changelog decision

If the repository documents a versioning / changelog convention (look in `CLAUDE.md` and contributor docs — for DevFlow itself, the "bump `plugin.json` + matching `CHANGELOG.md`" gotcha), decide **now**, while the committed diff is concrete, whether this change warrants a version bump and at what increment, and **record the decision in the workpad** so it survives context compaction:

```bash
workpad.py update $ISSUE_NUMBER --note "version decision: {bump to X.Y.Z | no bump} — {one-line reason, e.g. 'consumer-facing fix' / 'internal-only: tests/CI/docs'}"
```

This step owns only the *decision*; the bump is **applied in Phase 3.1.5** (after the PR exists, so the `CHANGELOG` entry can cite the PR number). Use the repo's stated increment rule — for DevFlow, the smallest correct SemVer step (patch = fix, minor = backward-compatible feature, major = breaking). If the repo documents **no** versioning convention, this is a no-op: record nothing and continue.

**⚠ You are NOT done. Code is committed but not reviewed or documented. Proceed to Phase 3.**

---

## Phase 3: Review & Fix

Output: `Phase 3/4: Review & Fix — creating PR and running review...`

`workpad.py update $ISSUE_NUMBER --status Reviewing`.

### 3.1 Create Draft PR

```bash
gh pr create --draft --title "{issue title}" --body "$(cat <<'EOF'
Work in progress — automated review pending.

Resolves #{issue_number}

Generated via `/devflow:implement $ARGUMENTS`
EOF
)"
```

Then populate the workpad's `PR` link from the freshly-created draft PR:
```bash
PR_URL=$(gh pr view --json url --jq '.url')
PR_NUM=$(gh pr view --json number --jq '.number')
workpad.py update $ISSUE_NUMBER --pr-link "[#$PR_NUM]($PR_URL)"
```

### 3.1.5 Apply the version bump + CHANGELOG (if 2.6 decided to bump)

If the Phase 2.6 decision (read it back from the workpad note; re-derive from the committed diff if the note was lost) was **no bump** — or the repo documents no versioning convention — skip this step. Otherwise apply the bump **now**, *before* `/simplify` (3.2) and `/devflow:review-and-fix` (3.3), so the version + `CHANGELOG` land inside the diff those steps review (and the review gate that fails on a version↔`CHANGELOG` mismatch sees them consistent):

1. Bump the repo's version file by the decided increment — for DevFlow, `.claude-plugin/plugin.json`'s `version`.
2. Add the matching `CHANGELOG.md` entry in the repo's changelog format, now citing the just-created PR number (`#$PR_NUM`).
3. Commit and push so the review pass covers it:
   ```bash
   git add .claude-plugin/plugin.json CHANGELOG.md   # the repo's version + changelog files
   git commit -m "chore: bump version and changelog for issue #$ARGUMENTS (#$PR_NUM)"
   git push
   ```

The Phase 4.3 clean-tree backstop is the final guard that this never ends up uncommitted.

### 3.2 Self-Review with /simplify

Invoke the **Skill tool** with `skill: simplify` — this runs the **built-in Claude Code `/simplify` slash-command**, not a DevFlow plugin skill (so there's no `devflow:` prefix and nothing to install). It ships with Claude Code and is always present; do not treat it as a missing skill or skip this phase.

`/simplify` is equivalent to `/code-review --fix`: it runs the code-review engine over the current diff — correctness angles plus the **reuse / simplification / efficiency / altitude** cleanup angles — and applies the fixes directly instead of stopping at a report (skipping any whose fix would change intended behavior). It is a fast self-review that catches the kinds of issues the heavier `review-and-fix` engine in 3.3 would otherwise spend turns on, keeping 3.3 focused on correctness, contracts, and verification rather than quality nits.

After the skill completes, commit any fixes and push:
```bash
git add -A
git commit -m "refactor: address /simplify findings for issue #$ARGUMENTS"
git push
```

If `/simplify` reported the code was already clean and made no changes, skip the commit and continue.

Then tick the `/simplify` gate: `workpad.py update $ISSUE_NUMBER --tick-progress "/simplify"`.

### 3.3 Review & Fix

Invoke the **Skill tool** with `skill: review-and-fix` and `args: "--push-each-iteration"`. The flag is load-bearing here: this phase operates on the live draft PR created in 3.1, and `--push-each-iteration` propagates each fix iteration to the remote branch so its CI validates the converging state and progress survives a mid-loop crash. (Direct users of `/devflow:review-and-fix` omit the flag and the loop stays local — see that skill's Input section for the flag's semantics.)

This runs the four-phase review engine in your context:
1. **Verification checklist** — generates and verifies every dependency interaction, test-mock alignment, data format assumption, and API contract claim against actual source code
2. **Existing review agents** — runs pr-review-toolkit (code-reviewer, silent-failure-hunter, comment-analyzer, pr-test-analyzer) and superpowers code-reviewer in parallel
3. **Automatic fix loop** — fixes findings using receiving-code-review principles, re-runs the engine, loops until APPROVE or the configured iteration cap (`devflow_review_and_fix.max_iterations`, default 5)

Follow the skill's instructions. It handles evaluation, fixing, testing, and re-review internally.

After the skill completes with a clean approve-family verdict (`APPROVE`, `APPROVE WITH CAVEAT`, or `APPROVE WITH ADVISORY NOTES` — **not** `APPROVE WITH UNRESOLVED SHADOW FINDINGS`, which is handled separately below), flush any residual fixes. A run that does **not** return one of those three recognizable verdicts — it errors, can't run, or emits nothing parseable as a verdict — is **not** a clean completion: route it to the **Blocked path** below rather than letting an empty/garbled exit fall through to the flush. With `--push-each-iteration` the loop has already committed and pushed every iteration, so this is normally a no-op — guard the commit so an empty staging area doesn't error:
```bash
git add -A
git diff --cached --quiet || git commit -m "fix: address code review feedback for issue #$ARGUMENTS"
git push
```

Then tick the `review-and-fix` gate: `workpad.py update $ISSUE_NUMBER --tick-progress "review-and-fix"`. Before ticking, record the run's shadow-coverage status — `shadow agreed, full coverage` vs `shadow agreement not verified` — via `--note`. Read these from the run's **verdict headline**: those exact literals are the `{shadow status}` parenthetical that review-and-fix renders on its APPROVE-family chat line (its Loop Exit "Verdict → chat output"), **not** from the report's `## Coverage` → `### Shadow agreement` section, which paraphrases the same fact in different prose (`Shadow ran with full reviewer coverage …` / `Shadow agreement NOT verified — {reason}`). Matching the headline token is exact; grepping the report body for the literal would miss. (Bucket the run by the loop's **verdict** first — this clean-completion path versus the AWUSF / REJECT / Blocked branches below — reading it from review-and-fix's **chat-output verdict line** (its Loop Exit "Verdict → chat output"). That line is the only surface carrying the *loop-level* verdicts: `APPROVE WITH UNRESOLVED SHADOW FINDINGS` is rendered there and **never** on the engine's report `## Verdict:` line, whose enum stops at the per-iteration engine verdicts (`APPROVE` / `APPROVE with notes` / `APPROVE WITH CAVEAT` / `APPROVE WITH ADVISORY NOTES` / `REJECT`) — so bucketing off `## Verdict:` would silently read an AWUSF run as a clean approve and ship it unreviewed. Only **after** the verdict has bucketed as clean approve-family, harvest the `{shadow status}` token from that same headline, so the AWUSF lost-write headline's own `… not verified …` prose can never be mis-harvested onto a clean run.) This is so a clean approve-family verdict that rode on a *not-verified* shadow (Step 2.6 outcome 3, which the loop intentionally proceeds on) is visible in the workpad rather than silently consumed as if it had been fully audited. This surfaces the gap without blocking — the loop already chose to proceed on its tentative verdict; contrast the bounded re-review below, which *does* require full coverage because it exists specifically to give an orchestrator hand-fix the independent pass it would otherwise never get.

**If the skill returns `APPROVE WITH UNRESOLVED SHADOW FINDINGS`** (the iteration-cap shadow pass surfaced new Important — never Critical — findings the loop could not address; see that skill's Step 2.6 outcome 2): this is **not** a clean approve. The findings came from a *full-coverage* shadow pass and are real, but they reach you only in chat + the report's `## Unresolved Shadow Findings` section (they do **not** flow through the Step-3 deferrals manifest, so Phase 4.0.5 will not file them). You may **not** silently hand-fix them and ship — any fix you apply to resolve them is itself unreviewed spec/code that no independent pass has seen, and shipping it is the unreviewed-final-edit gap the skill's caller contract forbids. Pick one:
1. **Fix + re-review (bounded once).** Apply fixes for the unresolved findings, commit (`fix:` prefix), then **re-invoke `review-and-fix` exactly one more time** (Skill tool, same `args: "--push-each-iteration"`) so the fix delta gets an independent shadow/review pass. **Only a clean approve-family verdict (`APPROVE` / `APPROVE WITH CAVEAT` / `APPROVE WITH ADVISORY NOTES`) whose verdict headline reads `shadow agreed, full coverage` (the `{shadow status}` token — same surface as the gate note above, not the report's Coverage prose) clears the re-review** — treat it exactly as a clean completion above (flush residual fixes **and** tick the `review-and-fix` gate), then continue. A clean verdict whose shadow was `not verified` does **not** clear it: the re-review exists precisely to give the hand-fix delta an *independent, full-coverage* pass, so accepting a not-verified re-review would re-open the unreviewed-final-edit gap this branch is closing — fall closed to the Blocked path instead. **Every other outcome falls closed to the Blocked path below** (e.g. `APPROVE WITH UNRESOLVED SHADOW FINDINGS` again, `REJECT`, or any re-review that errors, can't run, or returns no recognizable verdict — the hand-fix is already committed, so an unhandled outcome must never be allowed to ship unreviewed). Do **not** loop a third time: trigger at most **one** orchestrator-initiated re-review, and the bound is what keeps this terminating. (The bounded re-review is an ordinary `review-and-fix` run, so if *it* defers a finding through the Step-3 deferrals manifest, that is the normal Phase 4.0.5 follow-up-issue channel and proceeds as usual — the "AWUSF findings do not flow through the deferrals manifest" rule above is about the *first* run's unresolved shadow findings, not the re-review's own deferrals.)
2. **Do not fix — fall to the Blocked path below** (treat the unresolved findings as "unresolved after the cap").

**If the skill returns `REJECT`** (it could not converge — whether at the iteration cap or via a pre-cap convergence exit per that skill's Step 4.5, whose verdict is still REJECT): route straight to the Blocked path below. Like AWUSF, a REJECT must **not** be silently hand-fixed and shipped; the human gate applies.

**Blocked path (any unresolved exit).** Reached when the skill exits without a clean approve-family verdict — a first-run `REJECT` (cap-hit or pre-cap convergence exit), or an `APPROVE WITH UNRESOLVED SHADOW FINDINGS` you did not resolve via the bounded re-review above: `workpad.py update $ISSUE_NUMBER --status Blocked --reflection "review-and-fix unresolved: {summary}"`, then emit the 👎 outcome reaction (see *Outcome reaction* in the Workpad Reference) and stop.

### 3.4 Acceptance Criteria Gate

Before advancing to Phase 4, verify every **non-post-merge** checkbox in the workpad's `## Acceptance Criteria` section is ticked (`- [x]`). For each criterion, the verification is one of:

- a passing test in the diff that demonstrates the criterion,
- a documented manual check (recorded in the workpad notes via `--note` with the result), or
- a code reference (file:line) that satisfies the criterion.

Tick each criterion as you confirm it: `workpad.py update $ISSUE_NUMBER --tick-ac "{substring of AC text}"`. Cite the verification (a test, a file:line, or a prior note) in a `--note` on the same call where helpful.

**Post-merge criteria are exempt from the gate.** A criterion whose checkbox line ends in `(post-merge)` (tagged during Phase 1.2) does not block. The orchestrator's responsibility for a post-merge criterion ends at "the code reaches the state where the live verification *becomes possible* to run." Leave the checkbox unticked — the merger will tick it after deploy via the `## Post-Merge Verification` section that `/pr-description` adds to the PR body in Phase 4.2. Do **not** invent evidence to tick a post-merge box during /devflow:implement; the live signal is what counts.

If the workpad's Acceptance Criteria section reads `_(none provided in issue body)_`, the gate passes trivially.

The gate applies only to criteria currently in the workpad's `## Acceptance Criteria` section. If you scoped down via the 2.2.5 rule, deferred criteria live in the workpad notes and are **not** gated here — they will be carried into a follow-up issue in Phase 4.0.

If non-post-merge criteria remain unchecked after Phase 3.3:

1. If a criterion is satisfiable with a small follow-up edit, do it now (still inside Phase 3) — write the code, run tests, commit (using the `fix:` prefix), tick the box, and continue.
2. If a criterion's *literal text* is now stale because /simplify or /devflow:review-and-fix refactored the structure (e.g. renamed jobs, merged files), but the *underlying behavior* the criterion verifies is preserved in the diff, apply **2.2.6** now: rewrite the AC text in the workpad with a `--note` paper trail, then tick the box.
3. If a criterion is genuinely outside this PR's scope and you missed it during 2.2.5, **go back to 2.2.5 now**: move the item to the workpad notes (`--note`) as deferred, rewrite the Acceptance Criteria section, PATCH, and re-run this gate against the narrowed set. Then continue to Phase 4.
4. Otherwise — i.e. the criterion is in-scope but you cannot satisfy it AND it is not tagged `(post-merge)` — `workpad.py update $ISSUE_NUMBER --status Blocked --reflection "AC unmet (in-scope, not post-merge): {AC text}"`, then emit the 👎 outcome reaction (see *Outcome reaction* in the Workpad Reference) and stop the run with a clear report to the user. Do **not** advance to Phase 4 with unmet in-scope, non-post-merge criteria.

Once the gate passes (every non-post-merge AC ticked), tick the gate **and its parent phase** in the workpad: `workpad.py update $ISSUE_NUMBER --tick-progress "acceptance-criteria gate" --tick-progress "**Review**"`.

(A criterion that the orchestrator can't satisfy AND that's clearly post-merge-only should have been tagged `(post-merge)` in Phase 1.2 — if it wasn't, retroactively retag with `workpad.py update $ISSUE_NUMBER --rewrite-ac "{old text}" "{old text} (post-merge)" --note "retro-tagged as post-merge: {reason}"`, then let it pass the gate.)

**⚠ You are NOT done. PR is still a draft and needs documentation and a proper description. Proceed to Phase 4.**

---

## Phase 4: Documentation

Output: `Phase 4/4: Documentation — updating docs and finalizing PR...`

`workpad.py update $ISSUE_NUMBER --status Documenting`.

### 4.0 File Follow-Up Issues for Deferred Work

If Phase 2.2.5's scope-adjustment rule deferred any acceptance criteria, file a follow-up GitHub issue capturing them now. Skip this step if no criteria were deferred.

For each logical chunk of deferred work (typically: one issue per remaining "phase" in a phased cleanup), create a GitHub issue. If multiple follow-up issues are needed, issue all `gh issue create` calls in a single assistant turn so they run in parallel, and append a single combined note (`--note`) afterward (do not PATCH the workpad between each `gh issue create`).

**Body format — follow the create-issue template.** Build each follow-up issue body to the section structure and writing discipline of `skills/create-issue/references/issue-template.md` (the same format authority `/devflow:create-issue` uses), so an implement-generated follow-up reads like every other devflow-authored issue rather than a two-section stub. Specifically:

- **Sections, in this order:** `## Problem Statement`, `## Current Behavior`, `## Desired Behavior`, `## User Impact`, `## Technical Context`, `## Acceptance Criteria`, `## Implementation Notes`. (The template groups the first four — Problem Statement / Current Behavior / Desired Behavior / User Impact — as bullets under a single Description heading; flatten them to top-level `##` sections here, matching how parent issues are written.) Populate them from the parent issue and the workpad's 2.2.5 scope-decision note: the scope decision and the parent's framing → Problem Statement / Current Behavior / Desired Behavior / User Impact; the parent's relevant classes/files, architecture alignment, and cross-layer impact → Technical Context; the verbatim deferred criteria → Acceptance Criteria; the parent issue cross-reference threads through Problem Statement and Technical Context. (Technical Context and Implementation Notes carry a deliberate subset of the template's sub-bullets — the ones an implement-generated follow-up needs — rather than the full set; the template's Dependencies, Data/Schema Considerations, Testing Strategy, and Documentation Needed bullets are intentionally omitted.)
- **Acceptance Criteria are carried verbatim.** The deferred criteria were already-decided acceptance criteria on the parent issue — reproduce them exactly under `## Acceptance Criteria` as `- [ ]` checkboxes, preserving the 2.2.5 verbatim-preservation guarantee. Do not reword, split, or merge them.
- **No-options rule applies.** Observe the template's no-options discipline — no choice / hedge / deferral language (no "or", "could", "consider", "TBD", "for now", "(optional)") anywhere in the body. The deferred criteria are resolved decisions, so the gate is satisfied by construction; do not reintroduce hedging when describing the deferred scope.
- **Autonomous-run adaptation.** Phase 4.0 runs inside an autonomous /devflow:implement execution with no user present, so the template's *interactive* elements do not apply: there is **no clarification round** and **no `## 🚫 Blocked` section** — the deferred criteria are already-decided acceptance criteria, so nothing is unresolved. Build the body inline here; do **not** invoke the full interactive `/devflow:create-issue` pipeline.
- **GitHub autolink hygiene.** Never put a bare `#` before a number unless it is a real issue/PR reference; spell out ordinals and counts ("item 2", "phase 3").
- **Posting rules.** Pass the body via a quoted-heredoc on stdin (`--body "$(cat <<'EOF' … EOF)"`) so backticks and `$` in the markdown are not expanded, and add **no** `--label` (labeling is handled separately by maintainers). Do **not** switch to `--body-file`. (This posting command is a deliberate, small departure from the template's own *example*, which pipes the body through `--body-file -`; only the body's section structure and writing discipline follow the template, not its exact posting command — the quoted-heredoc form keeps the no-expansion guarantee either way.)

```bash
gh issue create \
  --title "<short descriptive title — e.g. 'Phase N of <parent topic>'>" \
  --body "$(cat <<'EOF'
## Problem Statement
Follow-up to #$ARGUMENTS. <Why this remaining work is needed and who hits the pain — drawn from the parent issue's framing and the 2.2.5 scope-decision note.>

## Current Behavior
<What exists today / what's missing — the state the parent PR left, scoped to this chunk.>

## Desired Behavior
<The single decided behavior after this follow-up ships, stated declaratively.>

## User Impact
<Who benefits and how.>

## Technical Context
- **Relevant Classes/Files** — <files from the parent issue's Technical Context relevant to this chunk.>
- **Architecture Alignment** — <how this fits existing patterns; carried from the parent.>
- **Cross-layer Impact** — <layers affected.>
- Parent issue #$ARGUMENTS was scoped to a single PR by its /devflow:implement run; see the workpad on #$ARGUMENTS for the full scope decision.

## Acceptance Criteria
- [ ] {deferred criterion verbatim}
- [ ] {deferred criterion verbatim}
…

## Implementation Notes
- **Approach** — <the decided design for this chunk, drawn from the parent's plan.>
- **Code Patterns** — <patterns in this codebase to mirror.>
- **Potential Gotchas** — <constraints or pitfalls carried from the parent issue.>
EOF
)"
```

Record the new issue numbers in the workpad: `workpad.py update $ISSUE_NUMBER --note "Filed follow-up issues for deferred work: #N (phase 2), #N+1 (phase 3), …"` before continuing to 4.0.5.

### 4.0.5 File Follow-Up Issues for Deferred Review Findings

If Phase 3.3's /devflow:review-and-fix run emitted a deferrals manifest, file follow-up GitHub issues for those findings now and update the manifest in place with the assigned issue numbers + deterministic deferral IDs. Phase 4.2's /pr-description run will then surface them in the PR body as a Scope-Acknowledged Findings block that /devflow:review's verdict matcher honors.

**Manifests are run-scoped** (`.devflow/tmp/review/<slug>/<run-id>/deferrals.json` — see that skill's "Pre-mapping: Widens-surface guard + deferrals manifest" section for what's in it). A single /devflow:implement run can produce **two** of them: Phase 3.3's first /devflow:review-and-fix run and its bounded re-review both run on the same PR with distinct run-ids. Reading one fixed path would miss the other run's deferrals (issue #68 F1, acceptance criterion 3). So **merge every run-scoped manifest into one slug-level aggregate** before filing, then file from the aggregate. The aggregate is the single path /pr-description reads in Phase 4.2.

Skip this step if no run-scoped manifest exists or all are empty.

```bash
PR_NUMBER=$(gh pr view --json number --jq '.number')
SLUG_DIR=".devflow/tmp/review/pr-${PR_NUMBER}"
AGG="${SLUG_DIR}/deferrals.json"   # slug-level aggregate the consumers read; distinct from the per-run files
# run-id and slug are path-safe (alphanumeric/hyphen/dot), so the unquoted find-output
# word-split below is safe. -size +0c skips empty manifests.
MANIFESTS=$(find "$SLUG_DIR" -mindepth 2 -maxdepth 2 -name deferrals.json -size +0c 2>/dev/null | sort)
if [ -n "$MANIFESTS" ]; then
    # Merge the deferrals[] arrays across runs. The dedup key mirrors file-deferrals.py's
    # _compute_id payload — (file|symbol|kind|summary.strip()), every field defaulted to ""
    # — so a finding deferred in both runs collapses to one row, is filed once, and a null
    # field never errors the string concat. Header fields come from the first input.
    # Idempotent re-runs: feed any prior hydrated aggregate FIRST so its `follow_up` entries
    # win the dedup (unique_by keeps the first occurrence); otherwise a re-run rebuilds $AGG
    # from the raw run-scoped manifests (which never carry follow_up), wiping the prior
    # hydration so file-deferrals.py re-files duplicates. Write via temp so reading $AGG is safe.
    # (file-deferrals.py refuses any manifest where *some* entry is already hydrated, so on a
    # re-run this prevents duplicate filing but does not incrementally file newly-added
    # deferrals — that all-or-nothing is the helper's existing guard, handled benignly below.)
    PRIOR=""; [ -s "$AGG" ] && PRIOR="$AGG"
    if jq -s '.[0] as $f | {schema_version:$f.schema_version, pr_branch:$f.pr_branch, base_branch:$f.base_branch, generated_at:$f.generated_at,
        deferrals: ([.[].deferrals[]] | unique_by((.file // "") + "|" + (.symbol // "") + "|" + (.kind // "") + "|" + ((.summary // "") | gsub("^\\s+|\\s+$";"")))) }' \
        $PRIOR $MANIFESTS > "${AGG}.tmp"; then
        mv "${AGG}.tmp" "$AGG"
    else
        # jq failed (malformed manifest, schema drift): keep any prior hydrated $AGG
        # intact, do NOT file from a half-merged temp, and surface the gap rather than
        # silently falling through to the filing guard with a stale aggregate.
        rm -f "${AGG}.tmp"
        workpad.py update $ISSUE_NUMBER --reflection "Phase 4.0.5 deferrals merge (jq) failed over: ${MANIFESTS}; deferrals NOT filed this run — inspect the run-scoped manifests."
        AGG=""   # make the filing guard below unambiguously false
    fi
fi
if [ -n "$AGG" ] && [ -s "$AGG" ]; then
    # Capture rc so file-deferrals.py's exit codes aren't discarded: 0 = filed; exit 2
    # with "already has follow_up" is the benign idempotent-re-run case (the prior
    # aggregate is still hydrated and /pr-description reads it fine) — not a failure.
    FILED_OUT=$(${CLAUDE_SKILL_DIR}/../../scripts/file-deferrals.py \
        --source-issue $ARGUMENTS \
        --pr "$PR_NUMBER" \
        --manifest "$AGG" 2>/tmp/devflow-fd.err); FD_RC=$?
    if [ "$FD_RC" -eq 0 ]; then
        FILED_NUMBERS="$FILED_OUT"
        # file-deferrals.py exits 0 even on PARTIAL success: a per-file group whose
        # `gh issue create` failed is dropped from the manifest, yet the helper still
        # exits 0. Surface that so the dropped findings (which won't reach the PR's
        # Scope-Acknowledged block) leave a breadcrumb instead of vanishing silently.
        grep -q 'were dropped from manifest' /tmp/devflow-fd.err && \
            workpad.py update $ISSUE_NUMBER --reflection "file-deferrals.py filed partially (rc=0): $(cat /tmp/devflow-fd.err); dropped groups will NOT appear in the PR's Scope-Acknowledged Findings block."
    elif grep -q 'already has follow_up' /tmp/devflow-fd.err; then
        workpad.py update $ISSUE_NUMBER --note "Deferrals already filed on a prior run (idempotent re-run) — nothing new to file; the hydrated aggregate stands."
    elif grep -q 'no deferrals' /tmp/devflow-fd.err; then
        workpad.py update $ISSUE_NUMBER --note "Aggregate held no deferrals to file — nothing to do."
    else
        workpad.py update $ISSUE_NUMBER --reflection "file-deferrals.py failed (rc=${FD_RC}): $(cat /tmp/devflow-fd.err); no follow-up issues filed this run."
    fi
fi
```

The helper groups manifest entries by `file` (one issue per source file), files each issue with a repo-agnostic title/body template (`<area>: deferred review findings in <file> (carried from #<source_issue>)` and a body containing the verbatim findings plus the `PR #<pr_number>` substring that the verdict matcher's mutual-cross-link guard validates against), then rewrites the manifest in place with `id: dfr-<6-hex>` (deterministic hash of `file + symbol + kind + summary`) and `follow_up: {issue, url, filed_at, filed_by}` populated per entry. Filed issue numbers are printed to stdout, one per line.

Failure mode: if `gh issue create` fails for a particular file-group, that group's entries are dropped from the manifest entirely — no fake deferral can downgrade a future review. The helper exits 0 as long as at least one group succeeded. Capture stderr in your `Devflow Reflection` notes if anything was dropped.

Record the filed issue numbers in the workpad:

```bash
if [ -n "${FILED_NUMBERS:-}" ]; then
    NUMBERS_CSV=$(echo "$FILED_NUMBERS" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, #/g')
    workpad.py update $ISSUE_NUMBER --note "Filed follow-up issues for deferred review findings: #${NUMBERS_CSV}"
fi
```

The rc handling above distinguishes three cases: a clean filing (rc 0), the benign idempotent-re-run (`exit 2` with "already has follow_up" — the prior aggregate is still hydrated, `/pr-description` reads it fine, recorded as a plain note), and a genuine failure (any other non-zero — every `gh issue create` group failed, or an unusable/corrupt manifest), which lands a `Devflow Reflection` breadcrumb. On a genuine failure continue to 4.1 anyway — the PR can still ship; it just won't carry the Scope-Acknowledged Findings block, so `/devflow:review` will treat any deferred findings as new.

### 4.1 Update Documentation

Spawn a **subagent** (using the Agent tool) and instruct it to invoke the `devflow:docs` skill. Pass it:
- The GitHub issue title, body, and number
- Instruction: "Invoke the `devflow:docs` skill to update all documentation (internal docs, external docs, release notes). The issue context is provided for release notes generation."

After the subagent completes, commit any documentation changes. Read the docs paths from `.devflow/config.json`:

```bash
DOCS_INTERNAL=$(${CLAUDE_SKILL_DIR}/../../scripts/config-get.sh .docs.internal docs/internal/)
DOCS_EXTERNAL=$(${CLAUDE_SKILL_DIR}/../../scripts/config-get.sh .docs.external docs/external/)
git status -- "$DOCS_INTERNAL" "$DOCS_EXTERNAL"
```

If there are changes:
```bash
git add "$DOCS_INTERNAL" "$DOCS_EXTERNAL"
git commit -m "docs: update documentation for issue #$ARGUMENTS"
git push
```

Then add the configured post-docs labels to mark that the docs pass ran. The labels signal "the docs pass ran and was reviewed", so apply them when the docs subagent actually ran — either it produced changes (and you committed them above), or it returned cleanly with no changes needed. Skip the labels and add a `--reflection` note to the workpad instead when the docs subagent failed, returned no useful output, or was unable to run. (Downstream docs automation, if the adopter runs any, can key off these labels to avoid double-processing the PR.)

`docs.labels` is a comma-separated list (default `Documented`). Normalize it before applying — split on commas, trim each entry, drop empties — then pass the cleaned list to a single `gh pr edit --add-label` call so every configured label is applied:

```bash
DOCS_LABELS=$(${CLAUDE_SKILL_DIR}/../../scripts/config-get.sh .docs.labels Documented)
CLEAN_LABELS=$(echo "$DOCS_LABELS" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | paste -sd, -)
[ -n "$CLEAN_LABELS" ] && gh pr edit --add-label "$CLEAN_LABELS"
```

Then tick the Documentation phase in the workpad: `workpad.py update $ISSUE_NUMBER --tick-progress "Documentation"`.

### 4.2 Generate PR Description

Invoke the **Skill tool** with `skill: "pr-description"` and `args: "$ARGUMENTS"` (the issue number). The skill detects the existing PR and updates its body directly.

Verify the PR Description update landed before moving to the next step.

```bash
gh pr view --json body --jq '.body' | grep -q "Work in progress — automated review pending" && echo "STILL PLACEHOLDER" || echo "OK"
```


### 4.3 Mark PR as Ready and Finalize Workpad

**Clean-tree backstop (before marking ready).** Assert nothing uncommitted reaches `gh pr ready`:

```bash
git status --porcelain
```

If it is non-empty, **do not** mark the PR ready yet. The run began from a clean `origin/main` checkout, so anything dirty here is this run's own work an earlier phase failed to commit (most often the Phase 3.1.5 version bump / `CHANGELOG`). Commit the part that belongs to this PR with the right prefix (`feat:`/`fix:`/`docs:`/`chore:`) and push, and record in `Devflow Reflection` which phase under-committed — surface the gap, don't paper over it. Surface (do not blindly `git add`) any unexpected untracked file. When the tree is already clean this is a no-op — create no empty commit. Only then:

```bash
gh pr ready
```

Then finalize the workpad in one call — tick the final `## Progress` item and flip `Status` to `Complete` (the helper swaps the glyph to 🎉):

```bash
workpad.py update $ISSUE_NUMBER \
    --status Complete \
    --tick-progress "PR marked ready" \
    --note "/devflow:implement run finished, PR marked ready: <PR_URL>" \
    [--reflection "{noteworthy event}" ...repeat per event]
```

Add one `--reflection` flag per noteworthy event a human should know for troubleshooting: a failed step that was skipped, a subagent that returned no useful output, a permission denial, a test you couldn't run, an ambiguity you resolved with an assumption, or any deviation from the planned flow. `--reflection` is repeatable so all events land in a single atomic update. (No separate "Notes from /devflow:implement run" comment is posted — the workpad replaces it.)

Finally, emit the 🎉 outcome reaction on the triggering comment (`REACTION=hooray`; see *Outcome reaction* in the Workpad Reference), then output the PR URL and a one- or two-line summary of what was accomplished.

---

## Completion Checklist

Before reporting completion, verify ALL phases executed:

- Phase 1: Issue fetched; workpad created as the **first GitHub write** (before the branch) with run link, `## Progress` checklist, and Acceptance Criteria mirrored; branch exists and the workpad `Branch` line is filled; Setup ticked in `## Progress`
- Phase 2: For `bug`-labelled issues, reproduction signal recorded; if the issue spans multiple PRs, the 2.2.5 scope-adjustment rule was applied and the workpad's Acceptance Criteria section now contains only in-scope items; the 2.3.0 changed-contract sweep (re-run after any merge/rebase) and the 2.3.4 boundary-assumption sweep both ran over the diff — each cross-boundary claim verified against its source of truth, or routed to `(post-merge)` with a reflection note; code committed and pushed
- Phase 3: Draft PR created; the Phase 2.6 version decision applied in 3.1.5 if it called for a bump (`plugin.json` + matching `CHANGELOG.md`, committed before the review pass); `/simplify` ran (fixes committed if any); `/devflow:review-and-fix` ran; acceptance criteria gate passed (PR still draft)
- Phase 4: If any criteria were deferred in 2.2.5, follow-up issue(s) filed in 4.0; if /devflow:review-and-fix emitted a deferrals manifest, follow-up issue(s) filed in 4.0.5 and the manifest hydrated; docs updated and "Documented" label applied; PR description generated via `/pr-description`; **working tree asserted clean (4.3 backstop), any remainder committed**; PR marked ready; every *applicable* `## Progress` item ticked (the `reproduction captured` sub-item is bug-only); workpad finalized with `Status: Complete` (🎉) and the 🎉 outcome reaction emitted on the triggering comment

Verify each `Status` PATCH actually landed at the time it was issued (see the Update protocol's "Always verify a PATCH that changes `Status` actually landed" rule). If a phase was skipped or a `Status` PATCH didn't land, go back and complete it now. In particular:

- **Do not stop after the PR is created or after review approves** — the PR stays a draft until Phase 4.3.
- **Do not stop because acceptance criteria are unchecked when the issue itself is multi-PR** — apply the 2.2.5 scope-adjustment rule first, then re-run the gate. The "Status: Blocked, stop the run" path in Phase 3.4 is only for genuinely-failing in-scope criteria, never for scope mismatches.

---

## Error Handling

- **Empty steps**: If any phase produces no file changes, skip the commit and continue. Do not create empty commits.
- **Git conflicts**: If a push fails due to conflicts, run `git pull --rebase origin {branch}` and retry once. If it fails again, stop and report the error. After any successful rebase here, re-run the Phase 2.3.0 changed-contract sweep against the newly-arrived sites — a clean textual rebase can still surface a fixture, call site, or assertion from `main` that the change's contract now rejects.
- **Subagent failures**: If a subagent fails or produces no useful output, note the failure in the workpad's `Devflow Reflection` and continue to the next step. Do not retry the same subagent more than once.
- **Permission denials**: If a Bash command is denied, note it in the workpad and continue to the next step. Never skip an entire phase because of a single denied command.
- **Commit prefixes**: Use `docs:` for documentation, `feat:` for implementation, `fix:` for review fixes and test fixes.
- **Context recovery**: If context was compressed and you lose track of variables, recover from `git log`, `git branch --show-current`, `gh pr list --head {branch}`, and the workpad — `${CLAUDE_SKILL_DIR}/../../scripts/workpad.py body $(${CLAUDE_SKILL_DIR}/../../scripts/workpad.py id $ISSUE_NUMBER)`. The workpad is the source of truth for plan state and every later mutation goes through `workpad.py update $ISSUE_NUMBER`, so the only variable to recover is `$ISSUE_NUMBER` itself (and it's already in `$ARGUMENTS`).
- **Surfacing failures**: Anything you "note the failure and continue" on above goes into the workpad's `Devflow Reflection` section so a human can pick it up later. Track these as you go — by the time Phase 4.3 runs, they should already be in the workpad, and no separate end-of-run issue comment is needed.
