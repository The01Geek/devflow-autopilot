---
name: implement
description: Use when a comment or message contains /devflow:implement followed by a GitHub issue number. Runs the full 4-phase lifecycle — setup, implementation, code review, and documentation.
argument-hint: <issue-number>
---
# /devflow:implement — Automated Feature Development Orchestrator

You are the main implementation agent. Execute the full 4-phase lifecycle for a GitHub issue. You hold continuous context from discovery through documentation — most work happens directly in your session.

**Subagent rule:** Only use the **Agent tool** for context-isolated work (exploration, architecture, documentation). Everything else — planning, implementation, testing, fixing — you do directly.

**Skill rule (exhaustive and exclusionary).** The **only** skills this orchestrator may invoke via the **Skill tool** are `simplify` and `review-and-fix` (during code review) and `pr-description` (for PR documentation). (`simplify` is the **built-in Claude Code `/simplify` slash-command** — nothing to install, never skip it; invoke it via `skill: simplify`. See Phase 3.2 for why it is always present.) Any **approval-gated or interactive** skill — one whose procedure terminates in an "ask the user" / "apply with approval" step — **must never be invoked from inside an autonomous phase**; `claude-md-management:revise-claude-md` and the `superpowers` `brainstorming` skill are examples that must never be invoked from inside an autonomous phase, because a nested `Skill` runs as a tail call and its interactive terminal step becomes the *run's* terminal step, stalling the run mid-phase with the workpad frozen at an in-progress `Status`. This exclusion generalizes the in-repo precedent in `phase-4-documentation.md` (the autonomous run does **not** invoke the full interactive `/devflow:create-issue` pipeline, because no user is present). **Division of labor between the two guards:** this exclusionary rule is what prevents the *observed* incident — an interactive skill stops the run *mid*-procedure awaiting approval, a point no completion-anchored re-anchor can ever reach — while the **Nested-skill completion re-anchor** below closes the *latent* variant, where a non-interactive nested skill completes but the phase continuation has been evicted or forgotten. Neither guard alone covers both.

**`CLAUDE.md` edit carve-out (Skill-rule exception).** `CLAUDE.md`'s own Conventions section mandates `revise-claude-md` / `claude-md-improver` for `CLAUDE.md` edits, but that would reproduce the very stall the exclusionary rule prevents. So any `CLAUDE.md` edit an **autonomous DevFlow run is required to make** — whether by a Phase-3 review finding **or by the issue's own acceptance criteria** — is made **directly by the orchestrator**, citing the carve-out and recording it in the workpad; interactive/human sessions still use `revise-claude-md` / `claude-md-improver`. `CLAUDE.md`'s Conventions section carries a matching bullet recording this carve-out so the two documents agree.

**Nested-skill completion re-anchor (always-loaded trigger).** **After completing any nested skill's procedure** — its final step, anchored on completion of the nested *procedure*, **not** on the `Skill` tool call's immediate return (whose result is merely the loaded skill body the orchestrator then executes over subsequent turns, so a return-anchored trigger would fire before the nested work starts and guard nothing) — and before taking any other action, re-`Read` the current phase file and **resume the interrupted step, never re-invoking the nested skill** (the same "do not re-dispatch" idempotency clause the Phase 4.1 re-anchor carries). This trigger lives in the always-resident orchestrator — for the same eviction-resistance reason the Phase 4.1 re-anchor cites — so a long nested return cannot evict it.

**Interactive skills are dispatched into a subagent, never invoked mid-phase.** A Skill-tool invocation is a *tail call*, not a subroutine call: the nested skill's body arrives as a new instruction gradient, so when that skill's own procedure ends in a user-facing report or approval step, **your run ends with it** — the workpad freezes at an in-progress `Status`, no terminal reaction fires, and nothing announces the death. So when a mid-run edit is one that this project's conventions route through an **interactive skill** — any skill whose procedure ends in a user approval step — do not run that procedure in your own context: **dispatch that skill inside a context-isolated **Agent-tool subagent** whose prompt pre-grants the approval**, and never invoke it through the Skill tool mid-phase. The subagent absorbs the nested instruction gradient and hands control back to you. The three skills named above are the only ones invoked directly, because none of them ends in a user approval step.

**Mid-phase re-anchor after a Skill-tool return (always-loaded trigger).** A nested skill's body displaces this orchestrator's procedure and the current phase file from your working set, which is how a run silently resumes the *wrong* step — or no step at all. So after **every** Skill-tool return mid-phase — `simplify`, `review-and-fix`, `pr-description`, or any other — re-`Read` the current phase file `<skill-dir>/phases/phase-N-<name>.md` and resume at the step immediately following the invocation, never re-dispatching the skill that just returned. This trigger lives here, in the always-resident orchestrator, precisely because the eviction it guards against cannot reach it here.

**Non-interactive self-answer rule.** When the run is non-interactive — `GITHUB_ACTIONS` is set (the cloud tier) — there is no user present, so a nested skill's user-facing question strands the run rather than pausing it. When a nested skill's procedure directs a question at the user, answer that question yourself on behalf of the user, using the issue description as the primary guide (the workpad `## Plan` and `## Acceptance Criteria` are secondary), instead of invoking the runner's user-question tool; record each self-answered question and the answer you chose in the workpad via `--note`, then continue the nested procedure. In an interactive local run the question still goes to the user. This rule reaches **only** questions a nested skill's procedure directs at the user. It never authorizes you to answer the issue's own open questions, and it never resumes a run past a blocker of your own: a workpad `Blocked` pause stays a pause.

**Input:** GitHub issue number provided as `$ARGUMENTS`

**Portable helper anchor (single-statement).** The bundled-helper commands in this skill resolve the skill directory inline at each call site via `${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}`. When `$CLAUDE_SKILL_DIR` is set and non-empty (Claude Code), run each command exactly as written. On a runner where it is unset or empty, replace the placeholder with the skill base directory the runner reports in context (e.g. a `Base directory for this skill:` line) before running the command; if that reported path is Windows-form (`C:\...`), first convert it to this shell's POSIX form with one standalone `wslpath -u '<path>'` (WSL) or `cygpath -u '<path>'` (Git Bash/MSYS2) command and substitute the printed result **only if the command succeeds and prints a non-empty path — otherwise fall through to the drive-letter rules exactly as if the tool were absent, the same success-and-non-empty acceptance the platform's path-normalization rules apply** (if neither tool exists: lowercase the drive letter, map `C:\` to `/mnt/c` on WSL or `/c` on MSYS2, and turn backslashes into `/`; if the environment is neither WSL nor MSYS2, use the path unchanged and report that it could not be normalized — the same arm the platform's path-normalization rules take). Resolve the anchor inline at every call site — never capture it into a shell variable that a later statement reads, because some runners' inline-bash marshaling drops such variables (observed on Copilot CLI). If neither `$CLAUDE_SKILL_DIR` nor a runner-reported base directory is available, stop and report that the helper anchor could not be resolved rather than running a command with a broken path.

**Cloud helper-invocation form (denial-proof — load-bearing on the cloud tier, and the form a resumed run must use).** On the cloud tier the permission allowlist grants each bundled helper **only** as the repo-relative vendored literal with that path as the command's **leading token** — `.devflow/vendor/devflow/scripts/…` (and `.devflow/vendor/devflow/lib/…`). Invoke every bundled helper that way: **never** an absolute path (`/home/runner/.../scripts/workpad.py`), **never** the repo-root `scripts/…` form, and never behind a `VAR=value` prefix or a `bash <path>` wrapper — each of those makes the command no longer *begin with* the granted literal, so it is silently denied (the issue #363 silent-denial class), burning budget with no signal. When `$CLAUDE_SKILL_DIR` is empty on the cloud runner, the `${CLAUDE_SKILL_DIR:-…}/../../scripts/…` anchor resolves to exactly this vendored literal, so following the anchor rule above already produces the granted form. **After two denials of a given command shape, do not iterate variants of it** — switch to a listed legal form (the repo-relative vendored literal for a bundled helper; for anything else, a plainly-granted head) rather than trying a third spelling. This form is what makes a stall-backstop auto-resume run viable: a resumed run that reaches for the absolute or repo-root form is denied on its very first `workpad.py` call and dies without resuming.

**Consumer prompt extension (load first).** Before doing this skill's work, load any consumer-supplied prompt extension for this skill and honor it. From the repo root, run:

```bash
"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/load-prompt-extension.sh implement
```

If the invocation fails because the helper path does not exist (`No such file`, exit 127, or the platform equivalent), that is the **anchor-resolution** failure described in the *Portable helper anchor* note above — fix the anchor, don't report a missing extension. Otherwise, if the helper exits non-zero, a consumer extension exists but could not be loaded — surface its stderr message and do not silently proceed as if none existed. If it exits 0 and prints text, treat that text as additional instructions appended to the end of this skill's own prompt for this run — it is upgrade-safe, consumer-owned customization committed under `.devflow/prompt-extensions/`. If it exits 0 and prints nothing, proceed unchanged.

**Phase reference files (resolve once, read each phase at its entry).** This orchestrator holds the cross-phase material (above and below) and, for each phase, a short stub plus a hard **entry-gate**. The detailed, authoritative procedure for each phase lives in its own reference file under `phases/`. Resolve the skill directory once now — the same anchor the prompt-extension load uses — and reuse the **printed path textually** (as `<skill-dir>` in the `Read` calls below) at every phase entry; this is prompt-level reuse of the tool output, never a shell variable (shell commands still resolve the anchor inline per the *Portable helper anchor* note above):

```bash
echo "${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"
```

Treat the printed path as `<skill-dir>`. On a runner where `$CLAUDE_SKILL_DIR` is unset or empty, replace the `<absolute skill base directory this runner reports in context>` placeholder with the skill base directory this runner reports (e.g. a `Base directory for this skill:` context line) before running the command — converting a Windows-form path (`C:\…`) to POSIX form first with one standalone `wslpath -u '<path>'` / `cygpath -u '<path>'` command (no such tool: lowercase the drive letter, map `C:\` → `/mnt/c` on WSL or `/c` on MSYS2, backslashes → `/`). **Fail closed:** if it prints empty **or prints the unsubstituted `<absolute skill base directory this runner reports in context>` placeholder** — neither `$CLAUDE_SKILL_DIR` nor a runner-reported base directory is available — **stop** and report that the skill-directory anchor did not resolve, so the phase files cannot be located — do **not** run any phase from its stub alone (the stubs are deliberately non-actionable). At the start of **every** phase, before taking any action in it, `Read` `<skill-dir>/phases/phase-N-<name>.md` and follow it exactly; if that `Read` fails, halt that phase with an attributable breadcrumb rather than improvising from the stub. This read is required **on every entry** — including a resumed or re-entrant run that picks up at a later phase — never relying on a read from an earlier phase or session. (`${CLAUDE_PLUGIN_ROOT}` is **not** substituted inside `SKILL.md` bodies; the `$CLAUDE_SKILL_DIR`-preferred, runner-reported-fallback anchor above is the only one that resolves under both the local checkout and the vendored cloud path.)

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
TRIGGER_COMMENT_ID=$("${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/run-jq.sh -r '.comment.id // empty' "$GITHUB_EVENT_PATH" 2>/dev/null || true)
if [ -z "$TRIGGER_COMMENT_ID" ]; then
  TRIGGER_COMMENT_ID=$(gh api "repos/$GITHUB_REPOSITORY/issues/$ISSUE_NUMBER/comments?per_page=100" \
    --jq 'map(select((.body | contains("/devflow:implement")) and (.body | contains("devflow:workpad") | not))) | last | .id' 2>/dev/null || true)
fi
if [ -n "$TRIGGER_COMMENT_ID" ]; then
  REPO="$GITHUB_REPOSITORY" EVENT_NAME=issue_comment COMMENT_ID="$TRIGGER_COMMENT_ID" REACTION="$REACTION" \
    "${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/react-to-trigger.sh || true
fi
```

If the triggering comment can't be resolved (a review-body trigger has no reactions API; the id lookup fails), skip the reaction silently — the workpad `Status` glyph remains the authoritative signal.

**Run-marker removal (same terminal transitions).** This block already binds *every* terminal `Status` transition, so it is also where the run's local-tier marker file is retired: at each such transition — 🎉 `Complete` and **any** 👎 `Blocked` finalizer alike — also remove the Phase 1.3 run-marker written for this issue. It is best-effort like the reaction; a failure to remove it never blocks the run, because the local Stop-hook guard self-heals a stale marker the next time it reads a terminal workpad.

```bash
rm -f "$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.devflow/tmp/implement-active-$ISSUE_NUMBER" 2>/dev/null || true
```

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

Every workpad operation goes through the bundled `workpad.py` helper at `"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/workpad.py`. The helper is stateless — each subcommand re-derives `REPO_FULL` and the marker on every invocation, so it works across Claude Code's per-call fresh-shell model without any env var or shell function needing to survive between Bash tool calls.

Subcommand reference:

| Command | Purpose |
| --- | --- |
| `workpad.py id ISSUE [--marker M]` | Print the workpad comment ID, or empty stdout with exit 2 if none exists (exit 1 on a gh-api/parse error). |
| `workpad.py body COMMENT_ID` | Print the full body of an existing workpad. |
| `workpad.py create ISSUE BODY_FILE` | Create the workpad on a fresh issue from a body file and print the new comment ID. Use at most once per issue (the cloud `gate` job already does this; the local fresh-issue path does it in 1.3). |
| `workpad.py new-body ISSUE [--run-link V] [--branch V] [--marker M]` | Print the lean initial workpad skeleton to stdout (Status/links/timestamp + empty `## Progress`, placeholder Plan/AC). Pipe to a temp file, then `create`. |
| `workpad.py update ISSUE [mutations...] [--marker M]` | Apply mutations and PATCH (structural failures are all-or-nothing; a volatile tick miss isolates — see the failure-isolation contract). **This is the mutation entry point used at every phase boundary after creation.** See the flags below. |
| `workpad.py now` | Canonical UTC ISO-8601 timestamp. (`update` already refreshes `Last updated` automatically; use `now` only when you need a timestamp in some other string, e.g. a follow-up issue body.) |
| `workpad.py patch COMMENT_ID BODY_FILE` | Low-level body-file PATCH. Prefer `update`; only use this for bulk-rewrite cases the `update` flags don't cover. |

The marker-locating subcommands (`id`, `new-body`, `update`) also accept `--marker M` to target a non-default marker comment (precedence: `--marker` > `DEVFLOW_WORKPAD_MARKER` env > `.devflow/config.json` > the built-in default). `/implement` does not pass it — it uses the default workpad marker; the flag exists for `/devflow:review`, which drives its own `devflow:review-progress` comment with the same helper.

`workpad.py update` accepts (combinable, all optional):

| Flag | Effect |
| --- | --- |
| `--status STATUS` | Replace the Status line. Pass a **bare** status word — the helper prepends the canonical glyph (🚀/🎉/👎/💥) and strips any glyph you pass, so re-applying is idempotent. You only ever pass `Complete`/`Blocked` or an in-progress word — `Failed` (💥) is written solely by the cloud stall backstop's dead-run flip. |
| `--branch BRANCH` | Replace the Branch line. |
| `--run-link VALUE` | Set the `Run` front-matter line to VALUE (markdown ok). Inserted after `Branch` if the line is absent (legacy-workpad resume). |
| `--pr-link VALUE` | Set the `PR` front-matter line to VALUE (markdown ok). Inserted after `Branch` if absent. Used in Phase 3.1 once the draft PR exists. |
| `--tick-progress TEXT` | Tick one unticked `## Progress` checkbox whose text contains TEXT (substring). **Repeatable.** A zero/multiple-match miss is a *volatile* failure (reported, the call exits non-zero, but its other mutations still apply — see the failure-isolation contract below), **not** an abort. Progress has no index form. |
| `--tick-plan TEXT` | Tick one unticked Plan checkbox whose text contains TEXT (substring). **Repeatable.** A zero/multiple-match miss is *volatile* (see below). |
| `--tick-plan-n N` | Tick the Nth Plan checkbox — **1-based, counting every `[ ]` and `[x]` row within the `## Plan` section** in document order (the index is section-scoped, not whole-document). **Repeatable**, and combinable with `--tick-plan` and every other flag in one call. An out-of-range or already-ticked N is a *volatile* failure (see below). |
| `--tick-ac TEXT` | Tick one unticked Acceptance Criteria checkbox whose text contains TEXT (substring). **Repeatable.** A zero/multiple-match miss is *volatile* (see below). |
| `--tick-ac-n N` | Tick the Nth Acceptance Criteria checkbox — **1-based, counting every `[ ]` and `[x]` row within the `## Acceptance Criteria` section** in document order (the index is section-scoped, not whole-document — don't count Progress/Plan rows). **Repeatable**, combinable with `--tick-ac` and every other flag. An out-of-range or already-ticked N is a *volatile* failure (see below). The Phase 3.4 gate ticks ACs by index with this flag, so it no longer hand-picks unique prose substrings. |
| `--rewrite-ac OLD NEW` | Phase 2.2.6: find an AC by OLD substring, replace its full text with NEW, keep the box state. **Repeatable** — multiple `--rewrite-ac` pairs in one call apply in argument order (against the progressively-rewritten section); any pair matching zero or multiple rows is a *structural* abort (no PATCH), preserving all-or-nothing. A pair that **appends the `(post-merge)` tag** (NEW ends with it; neither OLD nor the row it targets already does — all compared after a trailing-whitespace strip) is a mid-run retag and **requires a non-empty `--note` rationale** (issue #338); without one the call aborts structurally before any PATCH, so every such `--rewrite-ac` retag is a recorded, auditable claim (a crafted multi-pair sequence that net-adds a `(post-merge)` row is caught by the same rule). A pair that targets a row **already ending with the tag** (a text tweak on an already-deferred criterion, whether or not OLD itself spans the tag), or that removes the tag, needs no note. Only `--note` satisfies the rationale — a `--reflection` does not. |
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

- **Structural failures abort the whole call with no PATCH** (exit 1, clear stderr message): `gh` can't resolve the repo, the underlying API call fails, a target section (`## Progress`/`## Plan`/`## Acceptance Criteria`) is absent, the `Last updated` line is missing (or the `Status` line when `--status` is supplied — the `Status` check only fires for a `--status` mutation), a `--rewrite-ac` substring matches zero or multiple rows, a `--rewrite-ac` pair appends the `(post-merge)` tag (NEW ends with it; neither OLD nor the row it targets already does) without a non-empty `--note` rationale (issue #338), or a `--replace-*-file`/`--set-reproduction-file` is unreadable. (A failure of the `gh` PATCH call itself is likewise no-PATCH; its stderr also echoes any volatile tick misses collected before it, so they aren't lost on the API-failure path.)
- **Volatile per-row tick misses are isolated, not aborted.** A `--tick-*`/`--tick-*-n` flag that doesn't resolve to exactly one tickable row *inside a present section* — a substring matching zero or multiple unticked rows, or an `-n` index that is out of range or lands on an already-ticked row — does **not** discard the call. Every other mutation (`--status`, `--note`, `--reflection`, and every tick that *did* resolve) is applied and PATCHed, and the call then **exits non-zero** with a stderr report naming each tick that did not land. So a single bad tick in a batch no longer silently loses the accompanying status/notes — the orchestrator sees exactly which tick(s) failed and the rest of the update still persists.

**Callers MUST check the exit code of any tick call — never advance on the stdout body alone.** Because a volatile miss still PATCHes the body and prints it to stdout while leaving its target row `- [ ]`, the printed body is **not** a sufficient success signal for a tick. Treat a **non-zero exit** from any `update` call that carried a `--tick-*`/`--tick-*-n` as "at least one tick did not land": read the stderr report naming each unresolved tick, then re-resolve the target (a section's checkbox positions can shift after a Phase 2.2.5 `--replace-acs-file`, which can add/remove/reorder rows — `--rewrite-ac` itself only rewrites a row's text in place and preserves order/count) and re-tick it, or — if it genuinely cannot be resolved — route to the relevant **Blocked path** (the Phase 3.4 gate's step 4, or the Phase 4.3 finalize's clean-tree/publish handling). The gate's pass condition is therefore evidence-based: the targeted row is `- [x]` **and** the tick call exited 0. This applies to every tick site — the Phase 3.4 AC gate, the Phase 4.3 `--tick-progress "PR marked ready"` finalize, and the per-phase `--tick-progress` boundaries alike.

  **On a non-zero tick exit, re-tick ONLY the unresolved row(s) — do not blindly re-send the whole call.** The stderr breadcrumb states whether a PATCH was persisted, and the two cases need different recovery: a **volatile** miss already PATCHed the call's `--status`/`--note`/`--reflection` (the breadcrumb says *"PATCHed, but … re-tick only these row(s), do not re-send the call"*), so re-sending the *whole* call would double-write the append-only notes — re-issue just the failed `--tick-*-n`; a **structural** abort or a **PATCH-call failure** persisted nothing (the breadcrumb says *"no PATCH was made"* / *"NO workpad change was persisted"*), so the whole call is safe to re-send after fixing the cause.

`--tick-plan`/`--tick-ac` substring matching considers only unticked (`[ ]`) rows (so a duplicate tick in a batch surfaces as a volatile "no unticked checkbox matched" miss rather than silently no-op'ing); `--tick-plan-n`/`--tick-ac-n` address by 1-based position counting **every** `[ ]` and `[x]` row in document order.

**Never create a second workpad on the same issue.** Phase 1.2 creates exactly one; every subsequent mutation goes through `update`. If you lose `$ISSUE_NUMBER` mid-run (context compaction), recover from `git log`, `git branch --show-current`, and `gh pr list --head $(git branch --show-current)` — then resume with `workpad.py update $ISSUE_NUMBER ...`.

When a workpad already exists at the start of a re-run, treat its `## Progress` notes and `Devflow Reflection` as load-bearing context — read them via `workpad.py body $(workpad.py id $ISSUE_NUMBER)` before deciding what to do next. (A `gate`-pre-created workpad on a fresh issue carries only the run-started note, so there is nothing prior to reconcile.) If `Status` is `Blocked`, surface `Devflow Reflection` to the user and pause for confirmation before proceeding past Phase 1 — otherwise an automated re-run will blow through the gate that originally stopped the previous run.

**Always verify a Status PATCH actually landed.** `update` prints the new body on stdout — confirm the new `Status:` line is present before advancing to the next phase. (`gh api -X PATCH` can return success while the comment body is unchanged: transient API errors, oversized bodies, throttling.) If the response shows a stale `Status`, re-issue the `update` before continuing. Plan/Notes-only updates don't need this check.

---

## Phase 1: Setup

**Entry-gate (mandatory, on every entry):** before any Phase 1 action, `Read` `<skill-dir>/phases/phase-1-setup.md` and follow it exactly; re-read it each time you (re-)enter this phase, never relying on an earlier read. If `<skill-dir>` is empty or an unsubstituted placeholder (neither `$CLAUDE_SKILL_DIR` nor a runner-reported base directory resolves) or the read fails, halt Phase 1 with an attributable breadcrumb — do not improvise this phase from the stub.

Orientation only (the phase file is authoritative): fetch the issue and parse its acceptance criteria; create-or-resume the single workpad comment and mirror the ACs into it; create or detect the feature branch and fill in the workpad Branch line; push the branch; then run the issue-claim audit.

---

## Phase 2: Discover, Plan & Implement

**Entry-gate (mandatory, on every entry):** before any Phase 2 action, `Read` `<skill-dir>/phases/phase-2-implement.md` and follow it exactly; re-read it each time you (re-)enter this phase, never relying on an earlier read. If `<skill-dir>` is empty or an unsubstituted placeholder (neither `$CLAUDE_SKILL_DIR` nor a runner-reported base directory resolves) or the read fails, halt Phase 2 with an attributable breadcrumb — do not improvise this phase from the stub.

Orientation only (the phase file is authoritative): explore the codebase; reproduce first for `bug`-labelled issues; assess complexity and write the plan (using the architect for complex work); implement against the plan while running the mandatory code sweeps; test; and commit.

---

## Phase 3: Review & Fix

**Entry-gate (mandatory, on every entry):** before any Phase 3 action, `Read` `<skill-dir>/phases/phase-3-review.md` and follow it exactly; re-read it each time you (re-)enter this phase, never relying on an earlier read. If `<skill-dir>` is empty or an unsubstituted placeholder (neither `$CLAUDE_SKILL_DIR` nor a runner-reported base directory resolves) or the read fails, halt Phase 3 with an attributable breadcrumb — do not improvise this phase from the stub.

Orientation only (the phase file is authoritative): open the draft PR; run the self-review and the review-and-fix loop; then enforce the acceptance-criteria gate before advancing.

---

## Phase 4: Documentation

**Entry-gate (mandatory, on every entry):** before any Phase 4 action, `Read` `<skill-dir>/phases/phase-4-documentation.md` and follow it exactly; re-read it each time you (re-)enter this phase, never relying on an earlier read. If `<skill-dir>` is empty or an unsubstituted placeholder (neither `$CLAUDE_SKILL_DIR` nor a runner-reported base directory resolves) or the read fails, halt Phase 4 with an attributable breadcrumb — do not improvise this phase from the stub.

Orientation only (the phase file is authoritative): file follow-up issues for any deferred work; update the documentation; generate the PR description; then finalize the PR (publish or leave a draft per config) and the workpad.

**Mid-phase re-anchor (always-loaded trigger).** After the Phase 4.1 `devflow:docs` subagent returns and its docs are committed, re-`Read` the phase file before continuing to §4.2 (resume from §4.2; do not re-dispatch the §4.1 docs subagent). The phase file carries this same instruction, but a long context-isolated subagent return can evict it along with the §4.2/§4.3 procedure — so the *trigger* is repeated here in the always-resident orchestrator, where the eviction cannot reach it. (This re-anchor is scoped to **subagent** returns, not the Phase 2/3 subagent returns, whose phases carry their own entry-gate reads — here the Phase 4.1 docs subagent is the trigger. A **Skill-tool** return is covered by the separate generalized mid-phase re-anchor in the cross-phase rules above.)

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

### Terminal-status self-check (before your run-final message)

**Do not emit your run-final message while the workpad `Status` is an in-progress value.** Before you conclude the run, read the workpad `Status` line and confirm it is a **terminal** value — `Complete` (🎉) or `Blocked` (👎). If it is still any in-progress value (`Setup`/`Discovering`/`Reproducing`/`Planning`/`Implementing`/`Reviewing`/`Documenting`, glyph 🚀), the run is not finished — return to the phase that owns the remaining work and drive the `Status` to a terminal value before ending. This guard binds **every** way the run can end, not only a deliberate wrap-up: if you are about to stop for **any** reason — including believing the work is already complete — and the workpad `Status` is still in-progress, treat that as the violation and resume, because the failure this catches is precisely a run that halts *without* recognizing it never finalized. The commonest way to trip it is stopping at "documentation done": Phase 4.1 commits its docs but the run then must still reach Phase 4.2 (`/pr-description`) and Phase 4.3 (finalize → `Status: Complete` 🎉 + outcome reaction). This self-check is a **backstop**: the primary prevention is the Phase 4.1 re-anchor (in the Phase 4 section above), which keeps the §4.2/§4.3 procedure resident so the run is less likely to stop unaware in the first place — the check catches the residual case where it stops anyway.

This self-check keys on the workpad `Status`, not on PR draft state — a run that deliberately finishes with a draft PR (`implement_pr_state=draft`) still reaches `Status: Complete`, so it is never a false positive; conversely a published PR whose workpad is still `Documenting` does trip it. (Same discipline as the "Always verify a Status PATCH actually landed" rule in the Workpad Reference: the `Status` line is the source of truth for whether the run finished, so read it before asserting completion.)

**Make the self-check checkable, not merely stated: read the workpad `Status` line immediately before emitting any run-final message** — not from memory of where you think the run got to, but from the live comment — and only conclude the run when that line reads a terminal value. This local/interactive prose guard is load-bearing because the tiers do not back each other up: on the **cloud tier** the `devflow-implement.yml` **Stall backstop** (issues #268/#287/#356) detects an interim `Status` post-run and **re-dispatches (bounded auto-resume, honest-red on cap exhaustion) and, on a fail-loud exit, flips the workpad to the terminal `Failed` (💥) status — it never drives a run to `Complete`** (only the run itself can finalize), whereas the **local/interactive tier has no such backstop**, so nothing but this self-check catches a run that stalls there.

---

## Error Handling

- **Empty steps**: If any phase produces no file changes, skip the commit and continue. Do not create empty commits.
- **Git conflicts**: If a push fails due to conflicts, run `git pull --rebase origin {branch}` and retry once. If it fails again, stop and report the error. After any successful rebase here, re-run the Phase 2.3.0 changed-contract sweep against the newly-arrived sites — a clean textual rebase can still surface a fixture, call site, or assertion from the base branch that the change's contract now rejects.
- **Subagent failures**: If a subagent fails or produces no useful output, record the failure in the workpad's `Devflow Reflection` via `--reflection-kind dropped-failed --reflection "…"` (a subagent failure is actionable) and continue to the next step. Do not retry the same subagent more than once.
- **Permission denials**: If a Bash command is denied, note it in the workpad and continue to the next step. Never skip an entire phase because of a single denied command.
- **Commit prefixes**: Use `docs:` for documentation, `feat:` for implementation, `fix:` for review fixes and test fixes.
- **Context recovery**: If context was compressed and you lose track of variables, recover from `git log`, `git branch --show-current`, `gh pr list --head {branch}`, and the workpad — `"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/workpad.py body $("${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/workpad.py id $ISSUE_NUMBER)`. The workpad is the source of truth for plan state and every later mutation goes through `workpad.py update $ISSUE_NUMBER`, so the only variable to recover is `$ISSUE_NUMBER` itself (and it's already in `$ARGUMENTS`).
- **Surfacing failures**: Anything you "note the failure and continue" on above goes into the workpad's `Devflow Reflection` section (via `--reflection` with the matching `--reflection-kind` — actionable failures as `dropped-failed`, blockers as `blocked`, informational deviations as `note`) so a human can pick it up later. Track these as you go — by the time Phase 4.3 runs, they should already be in the workpad, and no separate end-of-run issue comment is needed.
