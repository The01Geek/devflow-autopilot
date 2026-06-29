---
name: implement
description: Use when a comment or message contains /devflow:implement followed by a GitHub issue number. Runs the full 4-phase lifecycle — setup, implementation, code review, and documentation.
argument-hint: <issue-number>
---
# /devflow:implement — Automated Feature Development Orchestrator

You are the main implementation agent. Execute the full 4-phase lifecycle for a GitHub issue. You hold continuous context from discovery through documentation — most work happens directly in your session.

**Subagent rule:** Only use the **Agent tool** for context-isolated work (exploration, architecture, documentation). Everything else — planning, implementation, testing, fixing — you do directly.

**Skill rule:** Use the **Skill tool** for `simplify` and `review-and-fix` during code review and `pr-description` for PR documentation. (`simplify` is the **built-in Claude Code `/simplify` slash-command** — nothing to install, never skip it; invoke it via `skill: simplify`. See Phase 3.2 for why it is always present.)

**Input:** GitHub issue number provided as `$ARGUMENTS`

**Consumer prompt extension (load first).** Before doing this skill's work, load any consumer-supplied prompt extension for this skill and honor it. From the repo root, run:

```bash
${CLAUDE_SKILL_DIR}/../../scripts/load-prompt-extension.sh implement
```

If the helper exits non-zero, a consumer extension exists but could not be loaded — surface its stderr message and do not silently proceed as if none existed. If it exits 0 and prints text, treat that text as additional instructions appended to the end of this skill's own prompt for this run — it is upgrade-safe, consumer-owned customization committed under `.devflow/prompt-extensions/`. If it exits 0 and prints nothing, proceed unchanged.

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

### ⚠️ Action required
- ⛔ **Blocked:** {a Blocked status — see Phase 1/2.1.5/3.3/3.4}
- ⏭️ **Deferred:** {deferred ACs/findings — Phase 4.0 / 4.0.5}
- ❗ **Dropped/Failed:** {a dropped manifest entry, a subagent/commit/label failure}

### ℹ️ Notes
- ℹ️ **Note:** {informational — a subagent retried once, a phase under-committed but was corrected, an unverified-boundary caveat}
</details>
```

The `### ` sub-sections (and their bullets) are rendered by the helper from `--reflection-kind`, **not** authored by hand — `new-body` seeds an *empty* `<details>` block and each sub-heading appears only once its group has a bullet. The block above shows the shape a populated reflection takes.

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
| `workpad.py now` | Canonical UTC ISO-8601 timestamp. (`update` already refreshes `Last updated` automatically; use `now` only when you need a timestamp in some other string, e.g. a follow-up issue body.) |
| `workpad.py patch COMMENT_ID BODY_FILE` | Low-level body-file PATCH. Prefer `update`; only use this for bulk-rewrite cases the `update` flags don't cover. |

The marker-locating subcommands (`id`, `new-body`, `update`) also accept `--marker M` to target a non-default marker comment (precedence: `--marker` > `DEVFLOW_WORKPAD_MARKER` env > `.devflow/config.json` > the built-in default). `/implement` does not pass it — it uses the default workpad marker; the flag exists for `/devflow:review`, which drives its own `devflow:review-progress` comment with the same helper.

`workpad.py update` accepts (combinable, all optional):

| Flag | Effect |
| --- | --- |
| `--status STATUS` | Replace the Status line. Pass a **bare** status word — the helper prepends the canonical glyph (🚀/🎉/👎) and strips any glyph you pass, so re-applying is idempotent. |
| `--branch BRANCH` | Replace the Branch line. |
| `--run-link VALUE` | Set the `Run` front-matter line to VALUE (markdown ok). Inserted after `Branch` if the line is absent (legacy-workpad resume). |
| `--pr-link VALUE` | Set the `PR` front-matter line to VALUE (markdown ok). Inserted after `Branch` if absent. Used in Phase 3.1 once the draft PR exists. |
| `--tick-progress TEXT` | Tick one unticked `## Progress` checkbox whose text contains TEXT (substring). **Repeatable.** A zero/multiple-match miss is a *volatile* failure (reported, the call exits non-zero, but its other mutations still apply — see the failure-isolation contract below), **not** an abort. Progress has no index form. |
| `--tick-plan TEXT` | Tick one unticked Plan checkbox whose text contains TEXT (substring). **Repeatable.** A zero/multiple-match miss is *volatile* (see below). |
| `--tick-plan-n N` | Tick the Nth Plan checkbox — **1-based, counting every `[ ]` and `[x]` row within the `## Plan` section** in document order (the index is section-scoped, not whole-document). **Repeatable**, and combinable with `--tick-plan` and every other flag in one call. An out-of-range or already-ticked N is a *volatile* failure (see below). |
| `--tick-ac TEXT` | Tick one unticked Acceptance Criteria checkbox whose text contains TEXT (substring). **Repeatable.** A zero/multiple-match miss is *volatile* (see below). |
| `--tick-ac-n N` | Tick the Nth Acceptance Criteria checkbox — **1-based, counting every `[ ]` and `[x]` row within the `## Acceptance Criteria` section** in document order (the index is section-scoped, not whole-document — don't count Progress/Plan rows). **Repeatable**, combinable with `--tick-ac` and every other flag. An out-of-range or already-ticked N is a *volatile* failure (see below). The Phase 3.4 gate ticks ACs by index with this flag, so it no longer hand-picks unique prose substrings. |
| `--rewrite-ac OLD NEW` | Phase 2.2.6: find an AC by OLD substring, replace its full text with NEW, keep the box state. |
| `--note TEXT` | Append a note bullet, prefixed with a time-only `HH:MM:SS` UTC timestamp and nested under the current `Status`'s phase inside `## Progress` (Setup/Discovering/…/Complete map to the matching top-level phase row; Blocked nests under the most recent completed phase). **Repeatable** — multiple notes in one call share the same timestamp and are appended in argument order. |
| `--reflection TEXT` | Append a bullet to Devflow Reflection (no timestamp), grouped by kind (see `--reflection-kind`) into the `### ⚠️ Action required` / `### ℹ️ Notes` sub-sections. **Repeatable.** |
| `--reflection-kind {blocked\|deferred\|dropped-failed\|note}` | Kind for this call's `--reflection` bullet(s). `blocked`/`deferred`/`dropped-failed` render under `### ⚠️ Action required`; `note` (the default when omitted) under `### ℹ️ Notes`. Each bullet renders with its kind's glyph + bold label (`⛔ **Blocked:**`, `⏭️ **Deferred:**`, `❗ **Dropped/Failed:**`, `ℹ️ **Note:**`). A single kind applies to every `--reflection` in the call — emit different kinds in separate `update` calls. |
| `--replace-plan-file FILE` | Replace the Plan section content with FILE. |
| `--replace-acs-file FILE` | Phase 2.2.5: replace Acceptance Criteria content with FILE. |
| `--set-reproduction-file FILE` | Phase 2.1.5: set the Reproduction section to FILE; inserts the section after Acceptance Criteria if it doesn't yet exist. |

`update` always re-fetches the live body before mutating (this narrows but does not eliminate the clobber window for concurrent edits; acceptable because the orchestrator is the single writer in practice), always refreshes `Last updated`, and PATCHes once per call. Mutations are **all-or-nothing for structural changes** — a structural failure (a missing target section, a missing `Status`/`Last updated` line, an unreadable `--*-file`) aborts the whole call before any PATCH. The **one** exception is a *volatile* per-row tick miss (see the failure-isolation contract below), which is isolated rather than aborting: the call PATCHes its other mutations and exits non-zero naming the miss. The patched body is printed to stdout so callers can verify the change actually landed — but **for a tick, the printed body alone is no longer a sufficient success signal**: a volatile miss PATCHes the body (and prints it) while leaving its target row `- [ ]`, so a caller must gate on the **exit code** as well (see the failure-isolation contract's "check the exit code" rule below).

Helper invariants baked into the script (orchestrator doesn't need to enforce them):
- Notes are append-only — `--note` only appends, never rewrites; each bullet nests under its lifecycle phase inside `## Progress` and carries a time-only `HH:MM:SS` prefix.
- `--reflection` is **`<details>`-aware**: because `## Devflow Reflection` is wrapped in a `<details>` block, the new bullet is inserted *inside* the block (before `</details>`), never after — so the collapsible region stays intact and the marker-first / AC-parseable invariants hold. (`--note` writes plain bullets into the un-wrapped `## Progress` section, so this doesn't apply to it.)
- **Reflections are grouped by kind, helper-owned.** The helper (the single chokepoint every reflection flows through) owns the glyph, bold label, and sub-section placement: `--reflection-kind` selects one of two `### ` sub-sections — the three actionable kinds (`blocked`/`deferred`/`dropped-failed`) under `### ⚠️ Action required`, `note` under `### ℹ️ Notes` — so a human scanning the run sees actionable items separated from informational notes regardless of how the orchestrator phrases the text. Sub-headings are `### ` (level-3), **never** `## `, so `lib/fetch-pr-context.sh` (which terminates the reflection parse at the first `## `) is not truncated; a sub-heading is emitted only when its group has ≥1 bullet, and a second bullet of an existing kind nests under the existing heading without duplicating it.
- The `Status` glyph is owned by the helper — `--status` derives and prepends it, and a note's phase is resolved from the bare (glyph-stripped) Status word.
- Devflow Reflection accumulates bullets — `--reflection` only appends.
- `--tick-*` flags edit only the box character and preserve the rest of the line.
- `--rewrite-ac` preserves the original checkbox state (don't tick during a 2.2.6 rewrite — the gate ticks later via `--tick-ac-n`).
- Heredoc / shell-interpolation hazards are eliminated — body content never traverses bash quoting; everything goes through files.

The helper reads `devflow.workpad_marker` from `.devflow/config.json`, falling back to the built-in default `<!-- devflow:workpad -->` when the config file or key is absent (so it works with no config).

**Failure-isolation contract (volatile vs. structural).** The helper distinguishes two failure classes:

- **Structural failures abort the whole call with no PATCH** (exit 1, clear stderr message): `gh` can't resolve the repo, the underlying API call fails, a target section (`## Progress`/`## Plan`/`## Acceptance Criteria`) is absent, the `Status`/`Last updated` line is missing, a `--rewrite-ac` substring matches zero or multiple rows, or a `--replace-*-file`/`--set-reproduction-file` is unreadable.
- **Volatile per-row tick misses are isolated, not aborted.** A `--tick-*`/`--tick-*-n` flag that doesn't resolve to exactly one tickable row *inside a present section* — a substring matching zero or multiple unticked rows, or an `-n` index that is out of range or lands on an already-ticked row — does **not** discard the call. Every other mutation (`--status`, `--note`, `--reflection`, and every tick that *did* resolve) is applied and PATCHed, and the call then **exits non-zero** with a stderr report naming each tick that did not land. So a single bad tick in a batch no longer silently loses the accompanying status/notes — the orchestrator sees exactly which tick(s) failed and the rest of the update still persists.

**Callers MUST check the exit code of any tick call — never advance on the stdout body alone.** Because a volatile miss still PATCHes the body and prints it to stdout while leaving its target row `- [ ]`, the printed body is **not** a sufficient success signal for a tick. Treat a **non-zero exit** from any `update` call that carried a `--tick-*`/`--tick-*-n` as "at least one tick did not land": read the stderr report naming each unresolved tick, then re-resolve the target (a section's checkbox positions can shift after a Phase 2.2.5 `--replace-acs-file`, which can add/remove/reorder rows — `--rewrite-ac` itself only rewrites a row's text in place and preserves order/count) and re-tick it, or — if it genuinely cannot be resolved — route to the relevant **Blocked path** (the Phase 3.4 gate's step 4, or the Phase 4.3 finalize's clean-tree/publish handling). The gate's pass condition is therefore evidence-based: the targeted row is `- [x]` **and** the tick call exited 0. This applies to every tick site — the Phase 3.4 AC gate, the Phase 4.3 `--tick-progress "PR marked ready"` finalize, and the per-phase `--tick-progress` boundaries alike.

`--tick-plan`/`--tick-ac` substring matching considers only unticked (`[ ]`) rows (so a duplicate tick in a batch surfaces as a volatile "no unticked checkbox matched" miss rather than silently no-op'ing); `--tick-plan-n`/`--tick-ac-n` address by 1-based position counting **every** `[ ]` and `[x]` row in document order.

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

Decide whether you are **already on the branch to use** or must **create one**. Two independent signals mean "already on it — skip creation":

1. **A linked git worktree** — the local harness pre-creates a worktree and checks out a branch for you (e.g. `worktree-issue-165`), whatever its name. This is the deterministic, **naming-independent** signal: a linked worktree's `--git-common-dir` (the main repo's `.git`) differs from its `--git-dir` (`.git/worktrees/<name>`); in the main working tree they are equal. The two are compared in **absolute form** (`--path-format=absolute`) so the test reflects directory identity rather than path representation.
2. **A recognized feature-branch name** — `claude/issue-*` / `issue-*`, the cloud-tier GitHub Action path (the Action checks out such a branch; it is not a worktree).

Otherwise, create a fresh feature branch off the base.

The base branch is **read from config** (`base_branch` in `.devflow/config.json`, default `main`) — never hard-code `main`, so the run branches off whatever trunk the consumer repo actually uses (`master`, `develop`, …). Resolve it **first**, because the worktree check needs it (it must never reuse the base branch itself — never build directly on trunk, even inside a worktree):

```bash
# config-get.sh itself falls back to the supplied `main` default — printing it,
# exit 0 — on the ordinary SOFT paths: a missing config file or an absent/empty
# key. It does NOT apply the default on a HARD failure — a malformed/unreadable
# .devflow/config.json, or a missing `node` (the resolver runtime) — which exits
# non-zero with empty stdout. So this guard exists only for those two hard paths:
# catch the empty read and supply `main` here (config-get already handled the
# soft paths). It trusts config-get's contract that it prints a fully-resolved
# value or nothing, never a partial/garbage string.
BASE=$(${CLAUDE_SKILL_DIR}/../../scripts/config-get.sh .base_branch main) || BASE=""
[ -n "$BASE" ] || { echo "devflow: base_branch read failed (malformed config or missing node); falling back to 'main'" >&2; BASE=main; }
CUR=$(git branch --show-current 2>/dev/null) || CUR=""
```

Now decide. Set `USE_CURRENT=1` to mean "reuse `$CUR`, skip creation":

```bash
USE_CURRENT=
# Resolve the git-dir layout ONCE, in ABSOLUTE form (`--path-format=absolute`) so the
# worktree comparison is byte-consistent regardless of how the caller's cwd was spelled —
# a harness-injected GIT_DIR / GIT_COMMON_DIR (or a non-root cwd) could otherwise print
# the same directory two different ways and false-positive "linked worktree". Note:
# --path-format=absolute normalizes relative vs. absolute output but does NOT canonicalize
# symlinks, `..`, or trailing slashes. A hard `git rev-parse` failure (corrupt repo,
# broken git, or git < 2.31 which lacks --path-format) yields an empty string: that fails
# CLOSED to the create path below with an attributable breadcrumb.
COMMON_DIR=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || COMMON_DIR=""
GIT_DIR_PATH=$(git rev-parse --path-format=absolute --git-dir 2>/dev/null) || GIT_DIR_PATH=""
[ -n "$COMMON_DIR" ] && [ -n "$GIT_DIR_PATH" ] || echo "devflow: one or both git-dir path values are empty (git < 2.31 lacking --path-format, repo corrupt, or injected GIT_DIR/GIT_COMMON_DIR env override) — linked-worktree detection (Signal 1) disabled; if this is actually a worktree, check git version, repo integrity, and env" >&2
# Reuse $CUR ONLY when it is a real branch (non-empty — not a detached HEAD) and NOT the
# base branch (never build directly on trunk, even in a worktree). These two guards
# apply to BOTH reuse signals, so they sit out here once — a base branch that happens to
# be named like a feature branch (`base_branch` = `issue-next`) must still create, not
# reuse, via Signal 2.
if [ -n "$CUR" ] && [ "$CUR" != "$BASE" ]; then
  # Signal 1 — linked worktree (naming-independent): the worktree's --git-common-dir
  # differs from its --git-dir; in the main working tree they are equal. This fires
  # whatever the harness named the worktree branch, fixing the case where a
  # `worktree-issue-<N>` branch (matching neither name pattern below) used to fall
  # through and create a SECOND branch.
  if [ -n "$COMMON_DIR" ] && [ -n "$GIT_DIR_PATH" ] && [ "$COMMON_DIR" != "$GIT_DIR_PATH" ]; then
    echo "devflow: in a linked worktree on '$CUR' (≠ base '$BASE') — using it as the feature branch, skipping creation" >&2
    USE_CURRENT=1
  fi
  # Signal 2 — cloud-tier recognized name (kept as a second skip condition).
  case "$CUR" in
    claude/issue-*|issue-*) USE_CURRENT=1 ;;
  esac
fi
```

**If `USE_CURRENT` is set, skip branch creation entirely** — `$CUR` is the feature branch; jump straight to filling the workpad `Branch` line below.

Otherwise, create a new branch. The canonical branch name is computed by the helper (handles slugification, unicode, length truncation, and collision suffixing deterministically):

Write the issue title (from the `gh issue view` above) to a temp file with the **Write tool** — `/tmp/devflow-issue-$ARGUMENTS-title.txt` — then derive the branch from it. Using `--title-file` instead of passing the title as a positional shell argument avoids breakage when the title contains quotes, backticks, or `$`.

```bash
if [ -z "$USE_CURRENT" ]; then
  # Fetch the base explicitly with a DevFlow breadcrumb so a bad/offline base is
  # attributable here, not a bare git error downstream — most importantly when the
  # fallback 'main' isn't the consumer's real trunk (a master/develop repo).
  git fetch origin "$BASE" || { echo "devflow: could not fetch base branch 'origin/$BASE' — if the base is correct, check network/auth; otherwise set base_branch in .devflow/config.json to the repo's real trunk (master/develop/…)" >&2; exit 1; }
  BRANCH=$(${CLAUDE_SKILL_DIR}/../../scripts/branch-for-issue.py $ARGUMENTS --title-file /tmp/devflow-issue-$ARGUMENTS-title.txt) || { echo "devflow: branch-for-issue.py failed — could not derive a branch name for issue #$ARGUMENTS; check that the issue title file exists and the issue number is valid" >&2; exit 1; }
  [ -n "$BRANCH" ] || { echo "devflow: branch-for-issue.py returned an empty branch name for issue #$ARGUMENTS — cannot create a branch" >&2; exit 1; }
  git checkout -b "$BRANCH" "origin/$BASE"
fi
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

Use the **Agent tool** with `subagent_type: devflow:code-explorer` to explore the codebase and understand the system as it relates to the issue.

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

**Phase 2.2 cannot start until the workpad's `Reproduction` section is populated.** If you cannot reproduce the bug: `workpad.py update $ISSUE_NUMBER --status Blocked --reflection-kind blocked --reflection "cannot reproduce: {obstacle}"`, then emit the 👎 outcome reaction (see *Outcome reaction* in the Workpad Reference) and stop the run — do not invent a fix.

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

Use the **Agent tool** with `subagent_type: devflow:code-architect` to design the implementation.

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
`--rewrite-ac` preserves the box state (don't tick during the rewrite — Phase 3.4 will tick via `--tick-ac-n` later). This is **not** scope adjustment — the rewritten AC is still gated in 3.4.

If the rewrite would relax the AC (drop a guarantee, weaken a check, remove a verification surface), STOP — apply 2.2.5 (defer the AC to a follow-up issue) or revert the structural change instead.

### 2.3 Implement

`workpad.py update $ISSUE_NUMBER --status Implementing`.

Now implement the feature yourself. You have full context:
- The explorer's system understanding
- The architect's blueprint (if complex) or your own inline plan (if simple)
- The original issue requirements

**Test-first gate (mandatory when the change is testable).** Before you write implementation code, decide whether the change adds or alters behavior an automated test (unit or integration) can exercise — a function's return value, an API or CLI contract, an exit code, a parser's handling of an input shape, a state transition, a raised error, or an end-to-end path an integration test drives. If it does, write the test **first**, run it, and confirm it **fails for the right reason** (the behavior doesn't exist yet), then implement until it passes. This is the 2.1.5 reproduce-first gate generalized from bugs to features — but mind what 2.1.5 actually captured: its reproduction signal is **any one of** a failing test, a quoted error log, *or* a recorded shell command. Only when that signal **was a failing test** does it already satisfy this gate (don't write a second one). If 2.1.5 reproduced the bug with a non-test signal (a log or a shell command), there is no failing test yet, so this gate **still applies**: write the failing test now, before implementing the fix. A test added *after* the code, never seen to fail, encodes whatever the code happens to do rather than what the issue requires — write it first.

**When the test you write IS a guard** (a drift/sync assertion, a coverage check, a regression test that pins a literal or contract), a green suite is necessary but **not sufficient** — a *vacuous* guard passes too. **Mutation-check any test guard you add here:** temporarily break what it pins (delete the line/block it asserts, flip the condition) and confirm the guard goes **RED**, then restore. This is the same discipline as the mutation-check rule in `skills/review-and-fix/SKILL.md` (Step 3), re-scoped to **any added or edited test guard in the diff** — so a guard authored as primary implementation work is covered here, not only a fix-loop deliverable.

**When no automated test applies**, there is nothing to assert against: a change whose deliverable is prose, templates, config, or an embedded DSL (jq or shell inside Markdown, a `SKILL.md` procedure), or one with no observable behavior boundary. A change whose behavior emerges only from an end-to-end round trip is **not** this case — an integration test can drive it, so it takes the gate above. Skip the test and rely on the Phase 2.4 adversarial input-shape dry-trace instead — do **not** invent a parallel mechanism.

Record the call either way: `workpad.py update $ISSUE_NUMBER --note "test-first: {test path, fails→passes} | {no automated test: <reason>; dry-trace at 2.4}"`. Like the 2.3 sweep-selection note, this is an auditable commitment — a "no automated test" note on a change that plainly added a pure function, a new exit code, or a drivable end-to-end path is a visible error a reviewer or the weekly retrospective can catch, where a silent skip is not.

Write the code. Follow the patterns and conventions described in `CLAUDE.md`. As plan steps complete, tick them off: `workpad.py update $ISSUE_NUMBER --tick-plan "{substring of completed step}"`.

**Sweep selection (run first).** The 2.3.x sweeps below are **not a flat checklist** — classify the diff and run the sweeps its shape warrants (**when in doubt, run them all**). Each sweep's heading states its own authoritative trigger; this list only tells you which to *consider*:

- **Deletes** code (a call site, branch, method, file, route, page, or asset) → run **2.3.1**, and **2.3.2** if it deletes a method/file/route/page.
- **Changes a contract** (a signature, a renamed/moved symbol, a tightened validator, or a routing/branch predicate) → run **2.3.0**.
- **Adds a rule that has peers** (a clause, guard, validator, or invariant that must hold at two or more co-equal sites for the rule to actually hold) → run **2.3.0a**.
- **Adds a value to an enumerated set** (a new enum/string-union member, status, kind, or verdict value) → run **2.3.0b**.
- **Always**, whatever the diff's shape → run **2.3.3** (convention), **2.3.4** (boundary-assumption), **2.3.4a** (self-authored-claim reconciliation), **2.3.5** (simplification & efficiency), **2.3.6** (error-handling & silent-failure).

This narrows *ceremony*, never *coverage*, and is **fail-safe**: each sweep's heading is authoritative, so if its trigger fires you run it even when this list didn't call it out — if the index ever drifts from a heading, the heading wins (drift can only add a sweep, never skip a warranted one). **The trigger shapes above are substrate-agnostic** — a contract, a peer-replicated rule, or an enumerated-set membership can live in prose / `SKILL.md` / doc / config just as much as in code (this repo's own coupled-invariant rule spans code mirror sites — a constant, a config-key name, a `SKILL.md` contract pin a `run.sh` grep asserts — as well as prose ones), so **classify by what the change replicates across sites, not by whether it is code**. An add-only diff that replicates nothing across sites typically runs just the five always-on sweeps — **but** an add-only prose/doc/config diff that adds a peer-replicated rule, a value to an enumerated set, or a contract literal mirrored elsewhere still trips the contract-completeness sweeps (**2.3.0** / **2.3.0a** / **2.3.0b**), not just the five. **Record the diff shape you classified and the sweeps you are running in a workpad `--note`** — the selection is then an auditable commitment a reviewer or the weekly retrospective can check, not a silent skip; a note reading "add-only" on a diff that in fact deleted a file is a visible error, where an unrecorded mental skip is not.

**Run each selected sweep after implementing and before running tests (Phase 2.4)** — that timing is the same for every sweep.

For the grep-based sweeps (**2.3.0**, **2.3.0a**, **2.3.0b**, **2.3.2**), don't merely attest you grepped: run the actual `git grep -n` / `grep -rnE` the sweep describes and record a **concise** result via `--note` (the match count plus "all intended", or the specific offending sites) — evidence, not a claim.

#### 2.3.0 Changed-contract sweep (mandatory whenever the change modifies a signature, renames/moves a symbol, tightens a validator, or changes a routing/branch predicate)

2.3.1–2.3.3 below all trigger on *deletion* or *addition*. Modifying a contract is just as blast-radius-prone, but it slips past `git diff` review because every dependent site still compiles — the call resolves, the fixture parses, the assertion runs — and is only *semantically* stale. After any change that modifies a signature, renames or moves a symbol, tightens a validator, or alters a predicate that classifies input, before running tests, grep the whole repo for every dependent site and bring each into line:

1. **All variants of a changed predicate.** If you changed a predicate that classifies input (e.g. a check for one specific status, type, or keyword), enumerate every value the predicate must now accept or reject and confirm every runner/branch routes them identically. A predicate fixed at one site but not its siblings is a defect in *this* PR, not a follow-up.
2. **Sibling call sites of a shared dependency.** If you wrapped or extended a shared object (e.g. added a per-request guard or a new error branch), grep for every caller that consumes that object and confirm each one plumbs the new inputs and handles the new branch — not just the site that motivated the change.
3. **Fixtures and assertions matching the old contract.** If you tightened a validator or moved output between streams (e.g. stdout↔stderr), grep tests for every fixture value and assertion that encoded the old contract — both in the files you touched *and* in shared `conftest.py` / helper modules — and update them. A fixture under a newly-stricter validator, or an assertion on a stream you rerouted, is a CI failure waiting for the next merge.

A modify / rename / reroute is not done until grepping for the old symbol, predicate value, stream, or contract returns only the intended sites.

**Re-run this sweep after any merge or rebase of the base branch** (the configured `base_branch`, not a hard-coded `main`)**.** A clean *textual* merge is not a clean *semantic* merge: the base branch may have added a fixture, call site, or assertion (often from a concurrently-merged PR) that your new contract now rejects, and git merges it cleanly without ever surfacing the conflict. After any `git merge` / `git pull --rebase` of the base branch the run performs (including the Error Handling conflict-recovery path), re-run steps 1–3 against the newly-arrived sites and treat any new site that violates the change's contract as a defect in *this* PR. See [`docs/implement-skill.md`](../../docs/implement-skill.md) for why each Phase 2.3 sweep exists.

#### 2.3.0a Peer-checkpoint completeness sweep (mandatory whenever the change adds a rule/clause/guard/invariant that has co-equal peer sites)

2.3.0 catches a *modified* contract leaving its *dependent* sites (callers, fixtures) stale. This sweep catches the additive twin: you **add** a rule — a guard, a validator clause, a read-only precondition, a classification tripwire, a fallback — and state it at only *some* of the co-equal sites that must all carry it for the rule to actually hold. Each site reads correct in `git diff`, the happy path works, and the PR's own prose/CHANGELOG describes the rule as if it held everywhere — so the asymmetry ships clean and surfaces only as a `/devflow:review` REJECT or a human/post-bot patch. This is *not* caller→callee propagation (that is 2.3.0's job); a **peer set** is two or more sites that must each enforce the *same* rule independently (the four gate checkpoints of a skill step, the object/scalar/array branches of a config-leaf handler, the selection predicate *and* the parallel derivation that must agree on the same fallback). After adding any such rule, before running tests:

1. **Enumerate the peer set by grep, not from memory.** Pick the shared marker the peers have in common (the clause's keyword, the guarded variable, the predicate name, the step heading) and `git grep -n` it across the repo to list every site the rule must hold at. Working from memory is exactly how a peer gets missed.
2. **Apply the rule at every member — or record the exemption.** Add the clause/guard/branch at each enumerated site. If a peer is *deliberately* exempt, that is allowed, but the asymmetry must be recorded with a `--note` (which peer, why) — a *silent* one-sided rule is the defect; a *documented* one is a decision.
3. **Reconcile prose that overclaims the rule's breadth.** Grep the diff's own prose, CHANGELOG, and docs for any statement that describes the rule as universal ("every checkpoint", "all branches", "always"). Either make it true at every peer or narrow the prose to match reality — an overclaiming sentence on a half-applied rule is itself a defect.

The rule is not done until grepping the shared marker returns the rule present at every peer in the set (or an explicit `--note` for each exemption).

#### 2.3.0b Enum-enumeration reconciliation sweep (mandatory whenever the change adds a value to an enumerated value set)

2.3.0a catches a rule added at only *some* of its co-equal peer sites. This sweep catches the sibling defect for a different shape of addition: you **add a value to an enumerated value set** — a new enum/string-union member, a status, a kind, a verdict, a `fix_decision` — update the code call-sites that branch on it, and leave a *doc/comment enumeration* of the value set, or a *fall-through consumer* (an `else` / `default` / `// null` arm that silently absorbs the new value), stale. The runtime can even be *correct* — the new value rides an intended fall-through — while a prose enumeration of the set and a `case`-less consumer go quietly out of date, surfacing only as a shadow-review finding or a human patch. "Consistent behavior" is not "reconciled enumeration." The 2.3.0 (changed-contract) and 2.3.0a (peer-checkpoint) sweeps grep *code* call-sites; this one explicitly adds the **doc/comment enumerations and fall-through consumers** they miss. After adding any value to an enumerated set, before running tests:

1. **Enumerate every site that names a member of the set, by grep — not from memory.** Grep the repo for the *existing* member literals of the value set (not just the new one): `git grep -n` each known value across code call-sites, jq/py/sh consumers, **doc/comment enumerations** (a prose list of the values, a docstring taxonomy, an inline `// one of: …` comment), **and fall-through consumers** (an `else` / `default` / `// null` arm whose behavior now depends on whether the new value should reach it). Working from the new value alone misses exactly the sites that enumerate the *old* set.
2. **Reconcile each site, or record an explicit exemption.** Add the new value to every enumeration meant to be exhaustive, and confirm every fall-through consumer treats the new value the way the design intends — verify the *intended* arm; do not assume the `else` is correct just because the suite is green. A site deliberately left out (a fall-through that *should* absorb the value) is allowed, but the exemption must be recorded with a `--note` (which site, why) — a *silent* stale enumeration is the defect; a *documented* one is a decision.
3. **Record the grep result as evidence.** Per the "Sweep selection" grep-evidence rule, record the match count plus "all reconciled" (or the specific stale sites you fixed) via `--note` — evidence, not a claim.

The addition is not done until grepping each member literal of the value set returns every enumerating site reconciled (or an explicit `--note` for each exemption).

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

Do this sweep:

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

Do this sweep:

1. From `git diff --staged -U0` (or `git diff -U0`), list every claim the diff depends on that falls into one of the four kinds above. The diff is the *trigger* for finding which boundaries the change now relies on — a boundary's definition site (an unchanged import, a producer module, a version pin) usually sits in context `-U0` doesn't print, so follow each claim to its actual source. Purely-internal claims (a local you just wrote, a function defined in the same diff) are **out of scope** — this sweep is only about boundaries you don't own.
2. For each claim, verify it against the **actual source of truth** — the pinned version's installed source/changelog, the producer module, the documented supported-runtime range across *all* of it, the real host — never from memory.
3. **A test assertion about a boundary is itself an unverified claim.** A test that asserts a wrong boundary value still passes — it encodes the bug rather than catching it — so a green run at 2.4 is not confirmation. When the diff adds or changes a test that asserts a boundary value, verify that value against the same source of truth here.
4. If the code is wrong, fix it. If a boundary genuinely **cannot** be verified in-environment, do **not** assert it as true: always record the gap with `workpad.py update $ISSUE_NUMBER --reflection-kind note --reflection "unverified boundary: {claim} — needs {live env} to confirm"` so it is visible to review and the merger. If — and only if — a specific acceptance criterion's verification depends on that boundary, additionally retag that criterion `(post-merge)` (per Phase 1.2, via the Phase 3.4 `--rewrite-ac` retag pattern) so the 3.4 gate doesn't block on a live-only check. An unverifiable external *boundary* is exactly the genuinely-live runtime-environment case the Phase 3.4 gate permits a `(post-merge)` tag for; it is **not** the runnable-but-blocked tooling gap nor the self-claim confirmation that gate refuses (see §3.4). `(post-merge)` covers code that ships correct but can only be *verified* live — it is never a way to wave through a boundary you suspect is wrong (that is a blocker).

Treat an unverified boundary assumption as a defect in **this** PR, not a review-engine problem to be caught downstream — if the diff depends on it, verify it here or route it to `(post-merge)` with a reflection note.

#### 2.3.4a Self-authored-claim reconciliation sweep (mandatory)

2.3.4 verifies the claims your diff *depends on* about boundaries it doesn't own (its inputs and preconditions). This sweep is its twin on the output side: it verifies the claims your diff *authors* — the behavioral assertions you wrote in prose — against what the shipped code actually does. The trigger is deliberately different, and that difference is the whole point: 2.3.4 starts from *the boundaries your code reads*; this sweep starts from *the prose your diff wrote*. 2.3.4 explicitly carves out claims about code defined in your own diff ("a function defined in the same diff is **out of scope**") — those are exactly the claims this sweep owns. A sentence in a doc you edited, or a comment you added, that contradicts the code path it describes ships clean: the prose reads plausibly, the code compiles, and your tests assert the prose's *intent* rather than the code's *actual behavior*, so the contradiction only surfaces as a `/devflow:review` finding or a post-merge patch. The cheapest place to catch it is here, before you commit.

A **self-authored claim** is any behavioral assertion the diff introduces about what the shipped code does. The surfaces, all in scope here:

- **Internal docs the diff adds or edits** (`docs/internal/…` and the like) — a described behavior, flow, "it does X then Y", or guarantee.
- **External docs the diff adds or edits** — the same, in customer-facing prose.
- **Code comments the diff adds or changes** — an inline claim about what the adjacent or called code does (e.g. "returns the deduped set", "never retries", "matches the reference query exactly").

(The **PR-body** claims are reconciled separately in **Phase 4.2**, where the body is authored — the body does not exist at commit time. This sweep covers every claim that *does* exist before commit.)

Do this sweep:

1. From `git diff --staged -U0` (or `git diff -U0`), list every behavioral claim the diff **adds or changes** in the three surfaces above. A claim is any sentence or clause asserting what the code *does* — not a TODO, a rationale, or a statement of intent that makes no factual behavioral assertion.
2. For each claim, trace the **actual shipped code path** it describes and confirm the code does what the prose says — **following dispatch into pre-existing code the diff calls but did not modify** (the claim's truth often resolves only downstream, in a helper your diff doesn't own). Unlike 2.3.4, a claim about code *defined in your own diff* is **in scope** here, not carved out — that blind spot is precisely what this sweep closes.
3. On any prose↔code divergence, **the code is the fact.** Resolve it one of two ways and never commit the unreconciled pair: either **fix the code** so the claim becomes true, or **rewrite the claim** so it states what the code actually does. Choosing one is mandatory — "note it and move on" is not an option for a contradiction you authored.
4. If fixing the *code* is genuinely out of scope for this PR (it would balloon the diff into an unrelated refactor), then **rewrite the claim** to the truth now — never leave false prose standing for `/devflow:review` to catch.

Scope and discipline mirror the other 2.3.x sweeps: only the claims your diff added or changed are in scope — never a repo-wide doc/comment audit. Treat a self-authored claim that contradicts the shipped code as a defect in **this** PR, not a `doc-accuracy` finding to be caught downstream.

**When this run changed direction, the sweep extends past the diff.** If you **reverted, narrowed scope, removed a marker, or renamed a contract** after you or the issue already described the original intent, two surfaces hold a now-false description that the reverting commit's own `git diff` doesn't contain — so steps 1–2 above can't reach them. On a change of direction only, also reconcile:

- **The issue workpad** — a ticked AC or Plan step whose wording still describes the reverted approach. Rewrite it to the shipped reality via `workpad.py update` (`--rewrite-ac` / `--replace-plan-file` / re-tick).
- **Earlier-authored prose naming the changed contract** — comments, docstrings, and docs that asserted the old behavior with a contract word ("always", "never retries", "fail-closed", a removed/renamed key) in an earlier commit. Grep the touched files **and their callers** for those words; fix the ones that now misdescribe the code.

Record the reconciled surfaces — or an intentional verbatim carve-out, with the reason — in a `## Devflow Reflection` bullet.

#### 2.3.5 Simplification & Efficiency sweep (mandatory)

2.3.0–2.3.4a keep the diff correct, dead-line-free, convention-clean, and consistent with the claims it makes; the 2.2.4 gate already settled reuse and altitude at plan time. This sweep handles the two remaining cleanup lenses that only become visible once the code is *assembled*.

After implementing, before running tests, re-read every function your diff added or changed lines in (from `git diff --staged -U0` or `git diff -U0`) and apply both lenses:

1. **Simplification.** Flag and remove unnecessary complexity the diff *adds*: redundant or derivable state (a field that's always recomputable from another), copy-paste with slight variation (collapse to one parameterized form), needless deep nesting (flatten with early returns), and dead code the diff leaves behind. For each, write the simpler form that does the same job.
2. **Efficiency.** Flag and fix wasted work the diff *introduces*: redundant computation or repeated I/O inside a loop or hot path that could be hoisted or cached, independent operations run sequentially that could run together, and blocking work added to startup or a hot path. Reach for the cheaper alternative — but don't trade clarity for a micro-optimization that doesn't sit on a hot path.

Scope and discipline mirror the other 2.3.x sweeps: only touch functions/files the diff already added or changed lines in — never a repo-wide refactor. If a simplification is real but cleanly fixing it is genuinely out of scope (it would balloon the diff into an unrelated refactor), say so explicitly in the workpad notes (`--note`) with the reason rather than leaving it silent. Reuse and altitude are **not** re-litigated here — they were decided in 2.2.4; this sweep is only simplification and efficiency.

Treat avoidable added complexity or wasted work in touched code as a defect in **this** PR, not a `/simplify` problem to be caught downstream.

#### 2.3.6 Error-handling & silent-failure sweep (mandatory)

2.3.0–2.3.5 keep the diff correct, propagated, dead-line-free, and clean. This sweep targets the defect class the Phase 3.3 `silent-failure-hunter` review agent keeps surfacing: an error the code *handles* in a way that hides it — swallowed, over-broadly caught, masked by an unexplained fallback, or reported too vaguely to act on. These ship clean because the happy path works and the suite is green (the failure only fires on an input the tests don't exercise), so they survive `git diff` review and only surface as a Phase 3.3 finding or a production incident. The cheapest place to catch them is here, alongside the other always-on sweeps.

A **silent failure** is any error the code can hit that doesn't leave the caller, the user, or a log a true, actionable account of what went wrong. The recurring kinds, in this repo's idiom:

- **Swallowed error.** A `try/except` that catches and continues, a bash `... || true` / `cmd 2>/dev/null` / `|| echo ""` / unchecked `$?`, or a `jq`/parse step whose failure is discarded — leaving no breadcrumb, or (worse) printing/returning *success* for work that may not have happened. An empty `except:` / `catch {}` is the absolute form and is never acceptable.
- **Over-broad catch.** `except Exception:` / `except:` (or a bash trap) around more than the one operation whose specific failure you meant to handle, so an *unrelated* error — a typo'd name, a missing dependency, a `KeyboardInterrupt` — hides under the same handler. Catch the narrowest type around the smallest scope.
- **Unjustified or wrong-direction fallback.** Falling back to a default, the built-in config default, an alternate path, or empty output on failure without recording *that* it fell back and *why* — the reader can't tell a real empty result from a masked failure. A fallback that defaults an *error* to a success-shaped value (an API error read as "passing", a parse error read as "no criteria") is worse: it fails *open*. A fallback is allowed only as documented, intended behavior, it fails toward the safe side, and it still leaves a breadcrumb.
- **Misdirected or generic breadcrumb.** A best-effort path that *does* emit a message, but a generic one ("error", "failed") that points at the wrong cause — the silent-fail trap CLAUDE.md already calls out for `config-get.sh` / the jq consumers. The breadcrumb must name the *specific* shape that detonated.
- **Mock/stub leaking past tests.** Production code falling back to a fake/stub/hard-coded value when the real source is unavailable, outside test scaffolding.

Do this sweep:

1. From `git diff --staged -U0` (or `git diff -U0`), list every error-handling site the diff **added or changed**: each `try/except` / `catch`, each `|| true` / `|| echo` / `2>/dev/null` / `set +e`, each `$?` check or swallowed exit code, each fallback/default-on-failure, each `jq`/parse step that can fail, each optional-chaining / `// default` that can skip a failing op. If the diff added none, the sweep is a no-op — record that and move on.
2. For each site, confirm it does **not** silently fail: the failure is either propagated, or handled with (a) a breadcrumb naming the *specific* cause and (b) — for anything user- or caller-facing — an actionable account of what went wrong. A best-effort exit-0 path still leaves the **specific** breadcrumb, never a generic or misdirected one, and never prints success for work that didn't happen.
3. Narrow every broad catch to the specific type around the smallest scope. For each catch you keep, enumerate what unexpected errors it could swallow — if that list isn't empty, tighten it.
4. Justify every fallback: it must be documented/intended behavior, it must fail toward the safe side (never default an error to a success-shaped value), and it must leave a breadcrumb distinguishing a masked failure from a real empty result. Remove any production fallback to a mock/stub.
5. Fix any silent failure in touched code. If a handler is *genuinely* a best-effort absorber, make that intent explicit in a comment **and** keep its breadcrumb — don't leave it reading as an accidental swallow. If a fix is truly out of scope, say so in a `--note` with the reason rather than leaving it silent for `/devflow:review` to catch.

Scope and discipline mirror the other 2.3.x sweeps: only touch error-handling sites the diff already added or changed — never a repo-wide error-handling audit. Treat a silent failure in touched code as a defect in **this** PR, not a `silent-failure-hunter` finding to be caught downstream.

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

Then stamp the reserved `DevFlow` **provenance** label on the PR (best-effort). `DevFlow` is a hardcoded provenance constant (no config key controls it) — it is the branch-naming-independent signal the weekly retrospective uses to detect DevFlow-authored PRs. Apply it via `--add-label` after creation (mirroring the Phase 4.1 docs-label idiom) so a label hiccup can never block the run:
```bash
${CLAUDE_SKILL_DIR}/../../scripts/ensure-label.sh DevFlow
gh pr edit "$PR_NUM" --add-label DevFlow \
  || echo "devflow: could not apply the DevFlow label to PR #$PR_NUM (best-effort, continuing)" >&2
```
`ensure-label.sh` always exits 0 (it logs whether it created the label, found it present, or hit a `gh` error), and a failed `--add-label` is logged and ignored — continue regardless of the label outcome.

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
2. **Existing review agents** — runs the first-party review agents (code-reviewer, silent-failure-hunter, comment-analyzer, type-design-analyzer, pr-test-analyzer) and the first-party `devflow:requesting-code-review` final-pass reviewer in parallel
3. **Automatic fix loop** — fixes findings using `devflow:receiving-code-review` principles, re-runs the engine, loops until APPROVE or the configured iteration cap (`devflow_review_and_fix.max_iterations`, default 5)

Follow the skill's instructions. It handles evaluation, fixing, testing, and re-review internally.

After the skill completes with a clean approve-family verdict (`APPROVE`, `APPROVE WITH CAVEAT`, or `APPROVE WITH ADVISORY NOTES` — **not** `APPROVE WITH UNRESOLVED SHADOW FINDINGS`, which is handled separately below), flush any residual fixes. A run that does **not** return one of those three recognizable verdicts — it errors, can't run, or emits nothing parseable as a verdict — is **not** a clean completion: route it to the **Blocked path** below rather than letting an empty/garbled exit fall through to the flush. With `--push-each-iteration` the loop has already committed and pushed every iteration, so this is normally a no-op — guard the commit so an empty staging area doesn't error:
```bash
git add -A
git diff --cached --quiet || git commit -m "fix: address code review feedback for issue #$ARGUMENTS"
git push
```

Then tick the `review-and-fix` gate: `workpad.py update $ISSUE_NUMBER --tick-progress "review-and-fix"`. Before ticking, record the run's shadow-coverage status — `shadow agreed, full coverage` vs `shadow agreement not verified` — via `--note`. Read these from the run's **verdict headline**: those exact literals are the `{shadow status}` parenthetical that review-and-fix renders on its APPROVE-family chat line (its Loop Exit "Verdict → chat output"), **not** from the report's `## Coverage` → `### Shadow agreement` section, which paraphrases the same fact in different prose (`Shadow ran with full reviewer coverage …` / `Shadow agreement NOT verified — {reason}`). Matching the headline token is exact; grepping the report body for the literal would miss. (Bucket the run by the loop's **verdict** first — this clean-completion path versus the AWUSF / REJECT / Blocked branches below — reading it from review-and-fix's **chat-output verdict line** (its Loop Exit "Verdict → chat output"). That line is the only surface carrying the *loop-level* verdicts: `APPROVE WITH UNRESOLVED SHADOW FINDINGS` is rendered there and **never** on the engine's report `## Verdict:` line, whose enum stops at the per-iteration engine verdicts (`APPROVE` / `APPROVE with notes` / `APPROVE WITH CAVEAT` / `APPROVE WITH ADVISORY NOTES` / `REJECT`) — so bucketing off `## Verdict:` would silently read an AWUSF run as a clean approve and ship it unreviewed. Only **after** the verdict has bucketed as clean approve-family, harvest the `{shadow status}` token from that same headline, so the AWUSF lost-write headline's own `… not verified …` prose can never be mis-harvested onto a clean run.) This is so a clean approve-family verdict that rode on a *not-verified* shadow (Step 2.6 outcome 3, which the loop intentionally proceeds on) is visible in the workpad rather than silently consumed as if it had been fully audited. This surfaces the gap without blocking — the loop already chose to proceed on its tentative verdict; contrast the bounded re-review below, which *does* require full coverage because it exists specifically to give an orchestrator hand-fix the independent pass it would otherwise never get.

**If the skill returns `APPROVE WITH UNRESOLVED SHADOW FINDINGS`** (the iteration-cap shadow pass surfaced new Important — never Critical — findings the loop could not address; see that skill's Step 2.6 outcome 2): this is **not** a clean approve. The findings came from a *full-coverage* shadow pass and are real, but they reach you only in chat + the report's `## Unresolved Shadow Findings` section (they do **not** flow through the Step-3 deferrals manifest, so Phase 4.0.5 will not file them). You may **not** silently hand-fix them and ship — any fix you apply to resolve them is itself unreviewed spec/code that no independent pass has seen, and shipping it is the unreviewed-final-edit gap the skill's caller contract forbids. Pick one:
1. **Fix + re-review (bounded once).** Apply fixes for the unresolved findings, commit (`fix:` prefix), then **re-invoke `review-and-fix` exactly one more time** (Skill tool, same `args: "--push-each-iteration"`) so the fix delta gets an independent shadow/review pass. **A clean approve-family verdict (`APPROVE` / `APPROVE WITH CAVEAT` / `APPROVE WITH ADVISORY NOTES`) whose verdict headline reads `shadow agreed, full coverage` (the `{shadow status}` token — same surface as the gate note above) clears the re-review** — treat it exactly as a clean completion above (flush residual fixes **and** tick the `review-and-fix` gate), then continue. A clean verdict whose shadow was `not verified` does **not** clear it: the re-review exists precisely to give the hand-fix delta an *independent, full-coverage* pass. **Any other outcome routes through the severity-aware exit below — it does NOT automatically Block** (e.g. `APPROVE WITH UNRESOLVED SHADOW FINDINGS` again, `REJECT`, or a not-verified re-review). Do **not** loop a third time: trigger at most **one** orchestrator-initiated re-review, and that bound is what keeps this terminating. (The bounded re-review is an ordinary `review-and-fix` run, so if *it* defers a finding through the Step-3 deferrals manifest, that is the normal Phase 4.0.5 follow-up-issue channel and proceeds as usual — the "AWUSF findings do not flow through the deferrals manifest" rule above is about the *first* run's unresolved shadow findings, not the re-review's own deferrals.)
2. **Do not fix — route directly through the severity-aware exit below** (treat the unresolved findings as "unresolved after the cap").

**Severity-aware exit (do not fully block on diminishing-returns).** Reached when the bounded re-review did not return a clean **and** full-coverage verdict, or when you chose option 2. Two consecutive non-clean review passes (the capped first run + the bounded re-review) is **not**, by itself, grounds to abort the whole implement lifecycle — hard-blocking there discards the completed work and the review-ready PR over findings that are often advisory or over-graded. Instead, **classify the residual unresolved findings by severity** and route. **First ensure over-grade calibration has actually run on the residual:** the loop's **over-grade calibration gate** (`/devflow:review-and-fix` Step 2.6) — which *flags* a promote-path over-grade and *requires a recorded `severity-calibrated` technical evaluation*, never auto-demoting — ran on the residual **only if a bounded re-review actually ran** (option 1). On **option 2** (you chose not to re-review) and on a **first-run REJECT** (which may never have reached the shadow-promotion decision where the gate fires), the gate has *not* run — do **not** assume a finding was already calibrated; apply the same flag-and-evaluate calibration yourself before classifying, and grade conservatively (default to Critical-treatment on doubt). Then route:

- **A genuine unresolved Critical** — a real Critical (a data-loss/exploit/correctness break citing a concrete failing input), or an Important the orchestrator judges it cannot responsibly defer → **Blocked path** below (the human gate genuinely applies). The same applies to a re-review that errors / returns no parseable verdict at all (no findings to classify → fail closed), **and to any residual whose severity is missing, ambiguous, or cannot be confidently graded** — an ungradeable residual fails **closed** to the Blocked path, it does **not** fall through to soft-proceed.
- **Otherwise** — the residual is only advisory / Suggestion / `severity-calibrated`-down / a deferrable Important, *and every residual was confidently gradeable as non-Critical* → **Soft-proceed path**: do **NOT** block. The PR is review-ready, not auto-merged; the residual findings ride into the human's merge decision rather than aborting the run.

**Soft-proceed path.** Surface the residual findings durably and continue the lifecycle:
- Record each residual finding in the workpad: `workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "unresolved after bounded re-review (non-Critical, surfaced for human review): {finding}"` so it lands under `### ⚠️ Action required` (a non-empty reflection set keeps the run honest about what shipped unverified).
- Tick the `review-and-fix` gate and record `workpad.py update $ISSUE_NUMBER --tick-progress "review-and-fix" --note "review-and-fix did not reach a clean+full-coverage verdict; soft-proceeded on non-Critical residual findings (surfaced above) — PR is review-ready, not auto-merged"`.
- Continue to Phase 3.4 and Phase 4. The PR ships per the configured `implement_pr_state` with the residual findings documented in the workpad and (where the re-review wrote a deferrals manifest) carried into the PR body by Phase 4.0.5 / `/pr-description`. The human merger decides. Do **not** silently hand-fix the residual findings after this point — that is still the unreviewed-final-edit gap; they are *surfaced*, not *resolved*.

**Blocked path (genuine unresolved Critical only).** Reached from the severity-aware exit when a genuine unresolved Critical remains (or a verdict cannot be parsed at all — fail closed): `workpad.py update $ISSUE_NUMBER --status Blocked --reflection-kind blocked --reflection "review-and-fix unresolved Critical (or unparseable verdict): {summary}"`, then emit the 👎 outcome reaction (see *Outcome reaction* in the Workpad Reference) and stop. A non-Critical residual is **not** a Blocked exit — it soft-proceeds per the path above.

**If the skill returns `REJECT`** (it could not converge — whether at the iteration cap or via a pre-cap convergence exit per that skill's Step 4.5, whose verdict is still REJECT): route through the **severity-aware exit** above — a REJECT whose unresolved triggers are all non-Critical/deferrable soft-proceeds (review-ready, surfaced), while a REJECT with a genuine unresolved Critical takes the Blocked path. Like AWUSF, a REJECT must **not** be silently hand-fixed and shipped as resolved; soft-proceed surfaces it for the human rather than resolving it.

### 3.4 Acceptance Criteria Gate

Before advancing to Phase 4, verify every **non-post-merge** checkbox in the workpad's `## Acceptance Criteria` section is ticked (`- [x]`). For each criterion, the verification is one of:

- a passing test in the diff that demonstrates the criterion,
- a documented manual check (recorded in the workpad notes via `--note` with the result), or
- a code reference (file:line) that satisfies the criterion.

**A verification-command criterion you could not locally observe passing is NOT satisfied by CI deferral alone — tick it only on an *observed* green CI result for the current HEAD, route a *red* result to the Blocked path, and a *not-yet-reported* one to `(post-merge)`.** The scope is determinable, not a phrase to pattern-match: this rule fires for **any** acceptance criterion whose verification is *running a test/lint/build command* (`bash lib/test/run.sh` passes, `shellcheck`/`ruff` pass, a `pytest`/build invocation, …) for which you could **not** produce a locally-observed green run. The trigger is "you did not observe it green locally," never your judgment that a criterion is "equivalent" to the examples — if you couldn't watch it pass, the rule applies. First work the tiers in CLAUDE.md's *"Running the suite when the `bash <path>` wrapper above is denied — the tier matters"* section: retry the **direct leading-token** form (`lib/test/run.sh`, not `bash lib/test/run.sh`) and the `python3 <path>` / `jq` fallbacks. Only on a genuine permission/sandbox **denial** of the direct form do you fall back to CI — **never** when the command *ran and failed* (that is a real failure to fix or block on, not a deferral). Falling back to CI, you do **not** tick on the *promise* of CI; you read the actual result of the **`lib + python tests`** job **for the current `git rev-parse HEAD`** (`gh pr checks` / `gh run list --json headSha,status,conclusion` — match the run whose `headSha` equals local HEAD) and split on what you observe:

- **Observed green for HEAD** — a run whose `headSha` equals local `git rev-parse HEAD` reports success. Tick on that observed result (by its 1-based AC position), interpolating the **gh-resolved** HEAD SHA (not a hand-written one) into the provenance recorded on the same call: `workpad.py update $ISSUE_NUMBER --tick-ac-n {N} --note "verified via CI: direct-form '{cmd}' denied locally (tier {N} — the tier the denial occurred on); 'lib + python tests' observed GREEN on $(git rev-parse HEAD)" --reflection-kind note --reflection "suite/lint AC ticked on observed CI green for HEAD, not a local run: {tier + what was denied}"`. The `[x]` then asserts a result you *saw* for *this* code. A green whose `headSha` is an *older* commit than HEAD is not an observation of this diff — treat it as not-yet-reported (third bullet).
- **Observed red for HEAD** — the job *ran and failed*. That is a real failure, **not** a deferral (the same rule that bars deferring a local command that ran and failed): do **not** tick and do **not** `(post-merge)` it. Take the gate's Blocked path — `workpad.py update $ISSUE_NUMBER --status Blocked --reflection-kind blocked --reflection "AC unmet: 'lib + python tests' observed RED on $(git rev-parse HEAD): {failing jobs}"`, emit the 👎 outcome reaction, and stop. A red CI laundered into a post-merge deferral is the exact silent-failure this gate exists to prevent.
- **Not yet reported (still running, or no run for HEAD yet) or status unreadable (`gh` denied/errored)** — there is no observed result, so do **NOT** tick on one that does not exist. Retag the criterion `(post-merge)` via the 3.4 retag pattern below — `--rewrite-ac "{AC text}" "{AC text} (post-merge)" --note "deferred to CI: direct-form '{cmd}' denied locally (tier {N} — the tier the denial occurred on); 'lib + python tests' <not yet reported for HEAD | status unreadable (gh denied)> — confirm green before merge"` (name *which* of the two in the note). That leaves the box unticked, exempts it from the blocking gate, and surfaces it in the PR body's `## Post-Merge Verification` checklist for the human merger, instead of asserting satisfaction the run never observed. (This reuses the `(post-merge)` channel for a *gate-time CI deferral* — the same mechanism as a Phase 1.2 intrinsically-live criterion, though the cause differs: here verification *could* run locally on a tier where the direct form resolves, it just didn't this run.)

A bare direct **grep** of a few SKILL-contract pins is **not** a substitute for the suite — it confirms specific pins, not "the suite passes," so it can never by itself satisfy such a criterion.

Tick each criterion as you confirm it, **by its 1-based position** in the workpad's `## Acceptance Criteria` section (the list mirrors the issue's AC order): `workpad.py update $ISSUE_NUMBER --tick-ac-n {N}`. `--tick-ac-n` is repeatable and combinable, so the whole gate can tick every confirmed AC in one call (`--tick-ac-n 1 --tick-ac-n 2 …`) without hand-picking unique prose substrings — and a single bad index no longer discards the rest of the batch (it is reported as a volatile miss while the other ticks land). Cite the verification (a test, a file:line, or a prior note) in a `--note` on the same call where helpful.

**Consume the tick call's exit code — do not advance on the stdout body alone** (per the failure-isolation contract in the Workpad Reference). Because a volatile index miss still PATCHes the body and leaves the target AC `- [ ]`, an unchecked non-zero exit would let the gate pass with an in-scope AC still unticked — the exact silent failure the index contract elsewhere prevents. So after the tick call: if it exited **0**, the named AC rows are now `- [x]` and the gate proceeds; if it exited **non-zero**, read the stderr report naming each unresolved `--tick-ac-n`, re-resolve the position (a Phase 2.2.5 `--replace-acs-file` may have reordered/added/removed AC rows, so the criterion's section-scoped index can have drifted out of range or onto an already-ticked row — `--rewrite-ac` alone preserves order and count) and re-tick, and only when a criterion's tick genuinely cannot be resolved take the gate's Blocked path (step 4 below). The gate passes only when every non-post-merge AC row reads `- [x]` **and** the ticks that set it exited 0.

**Post-merge criteria are exempt from the gate.** A criterion whose checkbox line ends in `(post-merge)` (tagged during Phase 1.2) does not block. The orchestrator's responsibility for a post-merge criterion ends at "the code reaches the state where the live verification *becomes possible* to run." Leave the checkbox unticked — the merger will tick it after deploy via the `## Post-Merge Verification` section that `/pr-description` adds to the PR body in Phase 4.2. Do **not** invent evidence to tick a post-merge box during /devflow:implement; the live signal is what counts.

**A `(post-merge)` tag is permitted only when the criterion genuinely requires a runtime environment that does not exist during the implement run** — a live deploy target, a real third-party endpoint, a production data path, or similar. That is the *only* qualifying condition, and it is the observable test the gate applies: *would running this verification require an environment the orchestrator host can never be, no matter which tools were installed?* If yes, it is genuinely-live and `(post-merge)` is correct. If the verification could run on the orchestrator host given the right tools, it is **not** post-merge — even if those tools happen to be unavailable right now. Two cases therefore **never** qualify, and the gate must refuse the tag (or retag) for them:

- **Runnable-but-blocked (local tooling/environment gap).** A criterion you *could* verify on this host but can't right now because a command was denied, a build tool is missing, a helper won't spawn, or a restore errored. A tooling gap is not a runtime-environment gap — route it to the **Blocked path** (step 4 below: `--status Blocked`), which escalates to a human; never launder it into `(post-merge)`. (A genuine permission/sandbox denial of the *test suite itself* still follows the `CLAUDE.md` tier rule — an auditable, workpad-recorded skip to the CI `lib + python tests` gate. That is a different mechanism from a `(post-merge)` retag: it does **not** tick the AC and does **not** pretend the check ran, so it is not the launder this rule forbids.)
- **Confirmation of a self-authored claim.** A criterion whose purpose is to confirm a behavioral claim the PR already asserts as already-true (in its description, its docs, or its code). It is runnable pre-merge **by construction** — the claim is *about the shipped diff* — so deferring it would defer the one check that could falsify the claim. Refuse the tag regardless of the stated reason: verify it now, or, if it genuinely cannot be satisfied, take the Blocked path.

**Red flags that you are about to launder a runnable check into `(post-merge)`** — STOP and take the Blocked path (step 4) instead:
- "The suite/lint/helper won't run *here*, so I'll mark it post-merge and let CI catch it." → tooling gap: Blocked path, or the auditable CI-skip per `CLAUDE.md` (which does not tick the AC) — **never** a retag.
- "This criterion just confirms what the PR already says, so it's safe to defer." → confirmation-AC: **never** post-merge.
- "It's *basically* a live check." → if it could run on this host with the right tools, it is **not** live.

If the workpad's Acceptance Criteria section reads `_(none provided in issue body)_`, the gate passes trivially.

The gate applies only to criteria currently in the workpad's `## Acceptance Criteria` section. If you scoped down via the 2.2.5 rule, deferred criteria live in the workpad notes and are **not** gated here — they will be carried into a follow-up issue in Phase 4.0.

If non-post-merge criteria remain unchecked after Phase 3.3:

1. If a criterion is satisfiable with a small follow-up edit, do it now (still inside Phase 3) — write the code, run tests, commit (using the `fix:` prefix), tick the box, and continue.
2. If a criterion's *literal text* is now stale because /simplify or /devflow:review-and-fix refactored the structure (e.g. renamed jobs, merged files), but the *underlying behavior* the criterion verifies is preserved in the diff, apply **2.2.6** now: rewrite the AC text in the workpad with a `--note` paper trail, then tick the box.
3. If a criterion is genuinely outside this PR's scope and you missed it during 2.2.5, **go back to 2.2.5 now**: move the item to the workpad notes (`--note`) as deferred, rewrite the Acceptance Criteria section, PATCH, and re-run this gate against the narrowed set. Then continue to Phase 4.
4. Otherwise — i.e. the criterion is in-scope but you cannot satisfy it AND it is not tagged `(post-merge)` — `workpad.py update $ISSUE_NUMBER --status Blocked --reflection-kind blocked --reflection "AC unmet (in-scope, not post-merge): {AC text}"`, then emit the 👎 outcome reaction (see *Outcome reaction* in the Workpad Reference) and stop the run with a clear report to the user. Do **not** advance to Phase 4 with unmet in-scope, non-post-merge criteria.

Once the gate passes (every non-post-merge AC ticked), tick the gate **and its parent phase** in the workpad: `workpad.py update $ISSUE_NUMBER --tick-progress "acceptance-criteria gate" --tick-progress "**Review**"`.

(A criterion the orchestrator can't satisfy may be retroactively tagged `(post-merge)` **only if it is genuinely-live by the rule above** — it requires a runtime environment absent during the run, it is *not* a runnable-but-blocked tooling gap, and it is *not* the confirmation of a self-authored claim. When it qualifies, retag with `workpad.py update $ISSUE_NUMBER --rewrite-ac "{old text}" "{old text} (post-merge)" --note "retro-tagged as post-merge (genuinely-live): {the runtime env it requires}"`, then let it pass the gate. If it fails that rule — runnable on this host, blocked only by local tooling, or a self-claim confirmation — do **not** retag; take the Blocked path (step 4 above) instead.)

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
- **GitHub autolink hygiene.** Applies to the follow-up issue body too — see *GitHub autolink hygiene* in the Workpad Reference.
- **Posting rules.** Pass the body via a quoted-heredoc on stdin (`--body "$(cat <<'EOF' … EOF)"`) so backticks and `$` in the markdown are not expanded, and add **no** `--label` on the `gh issue create` call itself — the configured `deferred.labels` are applied best-effort *after* creation (see *Apply the deferred-issue labels* below), mirroring the post-creation `--add-label` idiom Phase 3.1 uses for the `DevFlow` provenance label and Phase 4.1 uses for `docs.labels`. Do **not** switch to `--body-file`. (This posting command is a deliberate, small departure from the template's own *example*, which pipes the body through `--body-file -`; only the body's section structure and writing discipline follow the template, not its exact posting command — the quoted-heredoc form keeps the no-expansion guarantee either way.)

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

**Apply the deferred-issue labels.** As you create each follow-up issue above, **capture its number** from the `gh issue create` output (the command prints the new issue URL; the trailing path segment is the number) into `DEFERRED_ISSUE_NUMBERS` — a space-separated list you assemble from the issues you actually filed (e.g. `DEFERRED_ISSUE_NUMBERS="201 202"`). Then apply the configured `deferred.labels` to every filed issue. The labels are read from config (default `DevFlow,Deferred`) and normalized with the **same** split/trim/drop-empties idiom Phase 4.1 uses for `docs.labels`, so an empty or whitespace-only value applies no labels. Ensure each label exists first (best-effort), then apply them in a single `gh issue edit --add-label` per filed issue — best-effort and post-creation, so a label hiccup can never block or unwind the filing:

```bash
# Assemble this from the issue numbers you captured above (the gh issue create
# outputs). It is NOT auto-populated — set it explicitly, e.g.:
#   DEFERRED_ISSUE_NUMBERS="201 202"
DEFERRED_ISSUE_NUMBERS="${DEFERRED_ISSUE_NUMBERS:-}"
# Capture config-get's rc so a real read failure (corrupt config.json / missing node →
# exit 2 with empty stdout) is NOT silently indistinguishable from a deliberately-empty
# value: both yield an empty CLEAN below, but only the failure leaves a breadcrumb. The
# default arg covers the soft paths (missing file / unset key); rc≠0 is the hard path.
# The assignment runs as an `if` condition so the rc capture survives even if these
# blocks are ever executed under `set -e` (a bare `VAR=$(cmd); RC=$?` would abort at the
# assignment before the capture; an `if`-condition assignment is exempt from `set -e`).
if DEFERRED_LABELS=$(${CLAUDE_SKILL_DIR}/../../scripts/config-get.sh .deferred.labels DevFlow,Deferred); then DEFERRED_LABELS_RC=0; else DEFERRED_LABELS_RC=$?; fi
[ "$DEFERRED_LABELS_RC" -eq 0 ] || workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.0 could not read deferred.labels (config-get rc=$DEFERRED_LABELS_RC — corrupt config.json or node missing); deferred follow-up issues filed WITHOUT labels."
CLEAN_DEFERRED_LABELS=$(echo "$DEFERRED_LABELS" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | paste -sd, -)
if [ -z "$DEFERRED_ISSUE_NUMBERS" ]; then
  # We only reach this block because deferred work WAS filed above, so an empty list
  # means the issue-number capture was missed — a real gap, not a benign no-op. Route it
  # to the workpad (durable, retrospective-visible) like the rc-failure breadcrumb, not
  # just stderr (ephemeral in an autonomous cloud run).
  echo "devflow: Phase 4.0 captured no deferred-issue numbers — deferred.labels applied to nothing (check the gh issue create captures)" >&2
  workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.0 filed deferred follow-up issues but captured no issue numbers — the configured deferred labels were applied to NONE of them; the filed issues carry none of the configured deferred labels."
elif [ -n "$CLEAN_DEFERRED_LABELS" ]; then
  # Ensure each configured label exists (best-effort; ensure-label.sh always exits 0, so
  # this loop never aborts on a label that can't be created). `|| continue` just skips a
  # blank entry; CLEAN already drops blanks, so it is belt-and-suspenders kept symmetric
  # with the apply loop below. (These blocks run as ordinary Bash-tool invocations, not
  # under `set -e` — the best-effort idiom matches the pre-existing docs.labels block.)
  echo "$CLEAN_DEFERRED_LABELS" | tr ',' '\n' | while IFS= read -r lbl; do
    [ -n "$lbl" ] || continue
    ${CLAUDE_SKILL_DIR}/../../scripts/ensure-label.sh "$lbl"
  done
  # Apply to every issue filed above (the numbers captured into DEFERRED_ISSUE_NUMBERS).
  # A failed --add-label is the feature's most likely real-world failure, so route it to
  # the durable workpad (retrospective-visible) as well as stderr — matching the breadcrumb
  # discipline the rc-failure and empty-numbers paths above already use. stderr is ephemeral
  # in an autonomous cloud run, so a stderr-only breadcrumb would leave an unlabeled issue
  # with no durable trace of why.
  for n in $DEFERRED_ISSUE_NUMBERS; do
    gh issue edit "$n" --add-label "$CLEAN_DEFERRED_LABELS" \
      || { echo "devflow: could not apply deferred labels to issue #$n (best-effort, continuing)" >&2; \
           workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.0 could not apply the configured deferred labels ($CLEAN_DEFERRED_LABELS) to issue #$n (best-effort; the issue was filed but carries none of the configured deferred labels)."; }
  done
fi
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
        workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.0.5 deferrals merge (jq) failed over: ${MANIFESTS}; deferrals NOT filed this run — inspect the run-scoped manifests."
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
            workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "file-deferrals.py filed partially (rc=0): $(cat /tmp/devflow-fd.err); dropped groups will NOT appear in the PR's Scope-Acknowledged Findings block."
    elif grep -q 'already has follow_up' /tmp/devflow-fd.err; then
        workpad.py update $ISSUE_NUMBER --note "Deferrals already filed on a prior run (idempotent re-run) — nothing new to file; the hydrated aggregate stands."
    elif grep -q 'no deferrals' /tmp/devflow-fd.err; then
        workpad.py update $ISSUE_NUMBER --note "Aggregate held no deferrals to file — nothing to do."
    else
        workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "file-deferrals.py failed (rc=${FD_RC}): $(cat /tmp/devflow-fd.err); no follow-up issues filed this run."
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
    # Apply the configured deferred.labels to each filed issue — same resolve/normalize/
    # ensure/apply idiom as Phase 4.0 (default DevFlow,Deferred; empty/whitespace → none).
    # `file-deferrals.py` itself stays out of config-reading (config is Node-resolver
    # territory); the skill owns labeling. Best-effort and post-filing, so a label hiccup
    # never unwinds an already-filed issue.
    # Capture config-get's rc (same as Phase 4.0): a hard read failure (corrupt
    # config.json / missing node → exit 2, empty stdout) yields an empty CLEAN that is
    # otherwise indistinguishable from a deliberately-empty value — leave a breadcrumb so
    # the unlabeled outcome is attributable, not silent. The default arg covers the soft
    # paths (missing file / unset key); rc≠0 is the hard path. The `if`-condition form
    # keeps the rc capture alive even under `set -e` (a bare `VAR=$(cmd); RC=$?` aborts at
    # the assignment; an `if`-condition assignment is exempt).
    if DEFERRED_LABELS=$(${CLAUDE_SKILL_DIR}/../../scripts/config-get.sh .deferred.labels DevFlow,Deferred); then DEFERRED_LABELS_RC=0; else DEFERRED_LABELS_RC=$?; fi
    [ "$DEFERRED_LABELS_RC" -eq 0 ] || workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.0.5 could not read deferred.labels (config-get rc=$DEFERRED_LABELS_RC — corrupt config.json or node missing); deferred review-finding issues filed WITHOUT labels."
    CLEAN_DEFERRED_LABELS=$(echo "$DEFERRED_LABELS" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | paste -sd, -)
    if [ -n "$CLEAN_DEFERRED_LABELS" ]; then
        # `|| continue` just skips a blank entry (CLEAN already drops blanks — symmetric
        # with Phase 4.0); ensure-label.sh always exits 0, so the loop never aborts.
        echo "$CLEAN_DEFERRED_LABELS" | tr ',' '\n' | while IFS= read -r lbl; do
            [ -n "$lbl" ] || continue
            ${CLAUDE_SKILL_DIR}/../../scripts/ensure-label.sh "$lbl"
        done
        # A failed --add-label is routed to the durable workpad as well as stderr (same as
        # Phase 4.0): the unlabeled outcome is the feature's most likely failure and stderr
        # is ephemeral in an autonomous cloud run, so a stderr-only breadcrumb would leave
        # no retrospective-visible trace. `|| continue` skips a blank line (this piped-`while`
        # reads blank lines that Phase 4.0's `for` would word-split away); the per-issue
        # failure is caught best-effort so the loop completes.
        echo "$FILED_NUMBERS" | while IFS= read -r n; do
            [ -n "$n" ] || continue
            gh issue edit "$n" --add-label "$CLEAN_DEFERRED_LABELS" \
                || { echo "devflow: could not apply deferred labels to issue #$n (best-effort, continuing)" >&2; \
                     workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.0.5 could not apply the configured deferred labels ($CLEAN_DEFERRED_LABELS) to issue #$n (best-effort; the issue was filed but carries none of the configured deferred labels)."; }
        done
    fi
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

Then add the configured post-docs labels to mark that the docs pass ran. The labels signal "the docs pass ran and was reviewed", so apply them when the docs subagent actually ran — either it produced changes (and you committed them above), or it returned cleanly with no changes needed. Skip the labels and add a `--reflection-kind dropped-failed --reflection "…"` bullet to the workpad instead (a docs-subagent failure is actionable) when the docs subagent failed, returned no useful output, or was unable to run. (Downstream docs automation, if the adopter runs any, can key off these labels to avoid double-processing the PR.)

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

**Reconcile the PR body's behavioral claims (mandatory, before finalizing).** `/pr-description` authored the body just now, so this is the Phase 4.2 counterpart of the §2.3.4a self-authored-claim sweep — applied to the one surface that did not exist at commit time. Re-read the PR body and, for **every** behavioral claim it makes about what the shipped code does (a "this PR adds X that does Y", a described flow, a stated guarantee, or a `## Post-Merge Verification` item that on inspection actually describes *already-shipped* behavior rather than a genuinely live-only check — the same confirmation-of-self-claim case the Phase 3.4 gate refuses a `(post-merge)` tag for), trace the **actual shipped code path** — following dispatch into pre-existing code the diff calls — and confirm the code does what the body says. **The code is the fact**, under the same fix-or-rewrite rule as 2.3.4a:

- If the body **overclaims** (asserts a behavior the diff doesn't deliver), correct the body to the truth via `gh pr edit --body-file <file>` — the common case, since the body was just auto-generated and can overstate.
- If reconciliation reveals the **code** is actually wrong (the body states the intended behavior but the diff doesn't meet it), that is a real defect that escaped review: fix the code, commit with `fix:`, and push. On the default `ready_for_review` publish path that fix rides into the cloud `/devflow:review` that re-runs when Phase 4.3 publishes the PR; **but when `implement_pr_state=draft` the PR is left a draft and the cloud review does not auto-fire until a human publishes** (see §4.3), so the fix ships *unreviewed* until then. Either way, record in `Devflow Reflection` that a post-review code fix landed here so it is not mistaken for a reviewed change — and flag it more loudly on the draft path, where no automatic re-review will catch it.

Never finalize a PR whose description asserts a behavior the diff does not deliver. Record the reconciliation in a workpad `--note` (claims checked; any divergence and how it was resolved).


### 4.3 Finalize the PR (publish or leave draft) and Finalize Workpad

**Clean-tree backstop (always, before the publish decision).** Assert nothing uncommitted survives the run — this runs **unconditionally**, independent of whether the PR will be published or left a draft:

```bash
git status --porcelain
```

If it is non-empty, **do not** finalize yet. The run began from a clean base-branch checkout (`origin/` + the configured `base_branch`), so anything dirty here is this run's own work an earlier phase failed to commit. Commit the part that belongs to this PR with the right prefix (`feat:`/`fix:`/`docs:`/`chore:`) and push, and record which phase under-committed via `--reflection-kind note --reflection "…"` (a corrected under-commit is informational, not a standing failure) — surface the gap, don't paper over it. Surface (do not blindly `git add`) any unexpected untracked file. When the tree is already clean this is a no-op — create no empty commit.

**Publish decision — `implement_pr_state`.** Whether the run publishes the PR or leaves it the draft created in Phase 3.1 is a per-consumer config choice. Read it (default `ready_for_review`), then publish **only** when it is not the exact literal `draft` — default-to-publish is the safe direction, so a missing key, empty string, or any unrecognized value publishes, and a hard read failure (malformed config) falls back to publishing. **Capture whether `gh pr ready` actually succeeded** so the finalize wording reflects the *real* end state — a bare `gh pr ready` whose failure (the `else` arm catches *any* non-zero exit — e.g. auth scope, GitHub 5xx, rate limit, a race that already merged/closed the PR) fell through would otherwise leave the workpad falsely claiming the PR was published when it is still a draft:

```bash
PR_STATE=$(${CLAUDE_SKILL_DIR}/../../scripts/config-get.sh .devflow_implement.implement_pr_state ready_for_review) || PR_STATE=ready_for_review
PR_OUTCOME=draft   # one of: draft | published | publish_failed (overwritten below unless PR_STATE=draft)
if [ "$PR_STATE" = "draft" ]; then
    echo "devflow: implement_pr_state=draft — leaving PR as a draft (skipping gh pr ready)" >&2
elif gh pr ready; then
    PR_OUTCOME=published
elif [ "$(gh pr view --json isDraft --jq '.isDraft' 2>/dev/null)" = "false" ]; then
    # `gh pr ready` exited non-zero but the PR is NOT a draft — `gh pr ready` returns
    # non-zero on any non-draft PR, so this is the already-ready case (a Phase 4.3 re-run
    # after context recovery, or a PR a human/race already published). Treat as published,
    # not a failure, so a re-run doesn't emit a spurious "publish failed" reflection
    # contradicting reality. The check fails SAFE: if `gh pr view` itself errors (auth,
    # 5xx, PR deleted by a race), the substitution is empty, `!= "false"`, so it falls to
    # the else arm → publish_failed, the conservative direction.
    PR_OUTCOME=published
    echo "devflow: gh pr ready returned non-zero but PR is already non-draft — treating as published (idempotent re-run)" >&2
else
    PR_OUTCOME=publish_failed
    echo "devflow: gh pr ready FAILED — PR is still a draft, or its state could not be confirmed (implement_pr_state=$PR_STATE); do NOT finalize the workpad as 'marked ready'" >&2
fi
```

When `PR_STATE` is `draft` the PR is **left as the draft** from Phase 3.1: no `gh pr ready`, and **no additional comment** is posted to the PR thread. The downstream consequence is documented in [`docs/implement-skill.md`](../../docs/implement-skill.md) — the cloud review (`devflow-review.yml`'s `ready_for_review` event) and CI's `ready_for_review` listener do not auto-fire until a human publishes the PR.

Then finalize the workpad — tick the final `## Progress` item and flip `Status` to `Complete` (the helper swaps the glyph to 🎉) in **every** case; only the `--note` wording differs, and on a publish failure a `dropped-failed` reflection is added (in its own `update` call, see below), so the workpad never falsely claims a PR was published. Pick the `--note` by `PR_OUTCOME`:

- **`PR_OUTCOME=draft`** → `--note "/devflow:implement run finished, PR left as draft per implement_pr_state=draft: <PR_URL>"`
- **`PR_OUTCOME=published`** → `--note "/devflow:implement run finished, PR published (gh pr ready): <PR_URL>"`
- **`PR_OUTCOME=publish_failed`** → `--note "/devflow:implement run finished, but gh pr ready FAILED — PR is still a draft, or its state could not be confirmed: <PR_URL>"` **and** emit a separate `workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "gh pr ready failed at Phase 4.3 — PR left unpublished despite implement_pr_state=$PR_STATE; publish it manually (gh pr ready) so the cloud review and CI ready_for_review listener fire"` call (the durable note mirrors the stderr breadcrumb's wording — it must not assert "still a draft" as fact on the unconfirmed-state path where the `isDraft` re-check itself errored). It is a **`dropped-failed`** reflection (a publish failure needing human action), so it goes in its own `update` call — separate from the `note`-kind finalize below — because one `--reflection-kind` applies to the whole call.

```bash
# Substitute the PR_OUTCOME-specific --note above. The general --reflection events
# are `note`-kind (informational troubleshooting log); the publish_failed
# `dropped-failed` reflection above is a SEPARATE update call (different kind).
# `--tick-progress "PR marked ready"` MUST match the `## Progress` row label verbatim — that
# label is owned by scripts/workpad.py (cmd_new_body template + _PROGRESS_PHASES +
# _STATUS_TO_PROGRESS_PHASE); do NOT rename it here without renaming it there (and in the
# python tests). If it no longer matches a row, the tick is a *volatile* miss (the
# `## Progress` section is still present), so this call still flips Status to Complete
# and writes the note but exits NON-ZERO — it does NOT abort. Per the failure-isolation
# contract, consume that exit code: a non-zero finalize means the "PR marked ready" box
# is still `- [ ]`, so re-resolve and re-tick it (or take the publish/clean-tree Blocked
# handling) rather than treating the run as cleanly Complete.
workpad.py update $ISSUE_NUMBER \
    --status Complete \
    --tick-progress "PR marked ready" \
    --note "{PR_OUTCOME-specific note above}" \
    [--reflection-kind note --reflection "{noteworthy event}" ...repeat --reflection per event]
# Check the exit code of the finalize update above (per the failure-isolation
# contract): exit 0 means the "PR marked ready" box is now `- [x]` and the run is
# Complete; a non-zero exit means the tick missed (label drift / already ticked on a
# resumed run) — re-resolve and re-tick the row before treating the run as done.
```

Add one `--reflection` flag per noteworthy event a human should know for troubleshooting: a failed step that was skipped, a subagent that returned no useful output, a permission denial, a test you couldn't run, an ambiguity you resolved with an assumption, or any deviation from the planned flow. These are the *informational* `note` kind (`--reflection-kind note`); genuinely actionable failures (a dropped manifest entry, a publish failure) are emitted at the point they occur with `--reflection-kind dropped-failed` so they land under `### ⚠️ Action required`. `--reflection` is repeatable so all the note-kind events land in a single atomic update. (No separate "Notes from /devflow:implement run" comment is posted — the workpad replaces it.)

Finally, emit the 🎉 outcome reaction on the triggering comment (`REACTION=hooray`; see *Outcome reaction* in the Workpad Reference) — the implement lifecycle completed regardless of the publish decision (`draft`, `published`, or `publish_failed`; the publish failure is surfaced via the `--reflection` above, not by suppressing the reaction) — then output the PR URL and a one- or two-line summary of what was accomplished (state whether the PR was published, left a draft, or whether `gh pr ready` failed).

---

## Completion Checklist

Before reporting completion, verify ALL phases executed:

- Phase 1: issue fetched; workpad created before the branch with run link, `## Progress` checklist, and Acceptance Criteria mirrored; branch exists and the workpad `Branch` line filled; Setup ticked
- Phase 2: reproduction signal recorded for `bug`-labelled issues; if the issue spans multiple PRs, the 2.2.5 scope-adjustment was applied and the Acceptance Criteria section holds only in-scope items; the 2.3.0 changed-contract, 2.3.4 boundary-assumption, and 2.3.4a self-authored-claim sweeps all ran over the diff — each cross-boundary claim verified or routed to `(post-merge)`, and each behavioral claim the diff authored in docs/comments reconciled against the shipped code; code committed and pushed
- Phase 3: draft PR created; `/simplify` ran; `/devflow:review-and-fix` ran; acceptance-criteria gate passed (PR still draft)
- Phase 4: follow-up issue(s) filed in 4.0 for any 2.2.5-deferred criteria; follow-up issue(s) filed in 4.0.5 and the manifest hydrated if /devflow:review-and-fix emitted a deferrals manifest; docs updated and the `Documented` label applied; PR description generated via `/pr-description`; working tree asserted clean (4.3 backstop, runs in both publish and draft cases) and any remainder committed; PR published via `gh pr ready` **unless** `devflow_implement.implement_pr_state` is `draft` (then left as the Phase 3.1 draft, with no extra PR-thread comment); every applicable `## Progress` item ticked; workpad finalized with `Status: Complete` (🎉) — draft-aware `--note` wording — and the 🎉 outcome reaction emitted on the triggering comment

Verify each `Status` PATCH actually landed at the time it was issued (see the Update protocol's "Always verify a PATCH that changes `Status` actually landed" rule). If a phase was skipped or a `Status` PATCH didn't land, go back and complete it now. In particular:

- **Do not stop after the PR is created or after review approves** — the PR stays a draft until Phase 4.3, which then publishes it (or, when `implement_pr_state` is `draft`, deliberately leaves it a draft after still finalizing the workpad and reaction).
- **Do not stop because acceptance criteria are unchecked when the issue itself is multi-PR** — apply the 2.2.5 scope-adjustment rule first, then re-run the gate. The "Status: Blocked, stop the run" path in Phase 3.4 is only for genuinely-failing in-scope criteria, never for scope mismatches.

---

## Error Handling

- **Empty steps**: If any phase produces no file changes, skip the commit and continue. Do not create empty commits.
- **Git conflicts**: If a push fails due to conflicts, run `git pull --rebase origin {branch}` and retry once. If it fails again, stop and report the error. After any successful rebase here, re-run the Phase 2.3.0 changed-contract sweep against the newly-arrived sites — a clean textual rebase can still surface a fixture, call site, or assertion from the base branch that the change's contract now rejects.
- **Subagent failures**: If a subagent fails or produces no useful output, record the failure in the workpad's `Devflow Reflection` via `--reflection-kind dropped-failed --reflection "…"` (a subagent failure is actionable) and continue to the next step. Do not retry the same subagent more than once.
- **Permission denials**: If a Bash command is denied, note it in the workpad and continue to the next step. Never skip an entire phase because of a single denied command.
- **Commit prefixes**: Use `docs:` for documentation, `feat:` for implementation, `fix:` for review fixes and test fixes.
- **Context recovery**: If context was compressed and you lose track of variables, recover from `git log`, `git branch --show-current`, `gh pr list --head {branch}`, and the workpad — `${CLAUDE_SKILL_DIR}/../../scripts/workpad.py body $(${CLAUDE_SKILL_DIR}/../../scripts/workpad.py id $ISSUE_NUMBER)`. The workpad is the source of truth for plan state and every later mutation goes through `workpad.py update $ISSUE_NUMBER`, so the only variable to recover is `$ISSUE_NUMBER` itself (and it's already in `$ARGUMENTS`).
- **Surfacing failures**: Anything you "note the failure and continue" on above goes into the workpad's `Devflow Reflection` section (via `--reflection` with the matching `--reflection-kind` — actionable failures as `dropped-failed`, blockers as `blocked`, informational deviations as `note`) so a human can pick it up later. Track these as you go — by the time Phase 4.3 runs, they should already be in the workpad, and no separate end-of-run issue comment is needed.
