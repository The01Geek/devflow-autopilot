---
name: create-issue
description: Use when you have a rough user story, bug report, or feature idea that needs to become a well-structured GitHub issue.
argument-hint: <user-story>
---
**Portable helper anchor (single-statement).** This skill invokes helper scripts bundled beside it (`load-prompt-extension.sh` below; `issue-audit-state.py` — the audit-lifecycle state owner — throughout Step 3.6 and Step 4; `resolve-main-root.sh` wherever the canonical draft root is resolved or bound; `ensure-label.sh` / `apply-labels.sh` in Step 4 sub-step 5a). Every call resolves the skill directory **inline at the call site** via `${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}` — the anchor prefers `$CLAUDE_SKILL_DIR` when it is set **and non-empty** (Claude Code; run each command exactly as written, behavior unchanged); otherwise, replace the placeholder with the skill base directory this runner reports in context — e.g. a `Base directory for this skill:` line, observed on Copilot CLI (empty `$CLAUDE_SKILL_DIR` confirmed on Copilot CLI v1.0.67; expected on Cursor, Codex CLI, Gemini CLI, …). The `:-` expansion treats an **empty** `$CLAUDE_SKILL_DIR` exactly like unset because the observed failure on a non-Claude-Code runner is *empty* expansion, not an unset variable. If the reported path is Windows-form (`C:\...`) — which a POSIX shell (WSL bash, Git Bash) cannot use as-is — convert it **before substituting**: run one standalone `wslpath -u '<path>'` (WSL) or `cygpath -u '<path>'` (Git Bash/MSYS2) command and substitute its printed output **only if the command succeeds and prints a non-empty path — otherwise fall through to the drive-letter rules exactly as if the tool were absent**; if neither tool exists, lowercase the drive letter, map `C:\` to `/mnt/c` on WSL or `/c` on MSYS2, and turn backslashes into `/` — and if the environment is neither WSL nor MSYS2, use the path unchanged and report that it could not be normalized (the same rules and fail-closed arm `lib/normalize-path.sh` applies for `.sh`-helper callers — prompt-time paraphrase, not shell code, because the anchor is what *locates* `lib/`, so nothing is sourceable before it resolves). **Never capture the anchor into a shell variable that a later statement reads** — some runners' inline-bash marshaling drops a variable assigned earlier in the same inline command (observed on Copilot CLI), which is why each invocation below expands the anchor in the same single statement that uses it. The recipe names no skill-specific value, so it lifts unchanged into any other skill sharing this pattern; it is best-effort — if neither source yields a usable directory the skill proceeds and the natural underlying "No such file" error surfaces, no worse than before. (This is a deliberate divergence from the other skills' fail-closed stop: an anchor hiccup must never block issue *creation* — so do not "unify" this skill onto the stop-and-report contract. The best-effort anchor stays coherent now that a **pre-creation lifecycle** helper — `issue-audit-state.py`, the Step 3.6 state owner — has joined the roster alongside the post-creation extras whose degradation sub-step 5a reports explicitly: an unresolvable `issue-audit-state.py` invocation produces no contract output, which is precisely the first unavailability class routed to Step 3.6's **`state-owner unavailable` fallback** — a defined fail-safe that still audits once and still asks the user, never a silent skip. So a best-effort anchor degrades this skill's lifecycle onto a named, bounded path rather than past it; that is why it does not need the stop-and-report contract.)

**Consumer prompt extension (load first).** Before doing this skill's work, load any consumer-supplied prompt extension for this skill and honor it. From the repo root, run:

```bash
"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/load-prompt-extension.sh create-issue
```

If the invocation fails because the helper path does not exist (`No such file`, exit 127, or the platform equivalent — e.g. `The system cannot find the path specified` on Windows shells, or a localized message) — an empty `$CLAUDE_SKILL_DIR` whose placeholder was left unsubstituted collapses the anchor to a bogus directory prefix — that is the best-effort **anchor-resolution** failure noted above, not a consumer-extension problem — fix the anchor, don't report a missing extension. Otherwise, if the helper runs but exits non-zero, a consumer extension exists but could not be loaded — surface its stderr message and do not silently proceed as if none existed. If it exits 0 and prints text, treat that text as additional instructions appended to the end of this skill's own prompt for this run — it is upgrade-safe, consumer-owned customization committed under `.devflow/prompt-extensions/`. If it exits 0 and prints nothing, proceed unchanged.

## Prerequisites

If `$ARGUMENTS` is empty, ask the user to describe their user story, bug report, or feature idea before proceeding.

## Core principle

**An issue is the output of resolved decisions — not a place to park unresolved ones.**

Every decision a developer would otherwise have to guess at MUST be resolved by asking the user *before* the issue is written. Whatever the user genuinely will not or cannot resolve goes into one explicit **Blocked** section — never disguised as an "option", a "recommended approach", an "Open Question", a default, or conditional wording scattered through the body.

## Completion checklist (do this first)

This skill is a **pipeline that ends with a created GitHub issue and a *gated* offer to start implementation** — the offer is presented, or a one-line reason is printed for why it was withheld — not with a documentation report. Before doing anything else, set up progress tracking for exactly the seven items below using the task-tracking tool the runner exposes — `TodoWrite` (Claude Code, the canonical example), `TaskCreate`/`TaskUpdate` (newer Claude Code sessions), or `update_plan` (Codex CLI) — and, when the runner exposes no task-tracking tool or the exposed one is disabled or unusable, use the inline checklist fallback defined below:

1. Run `/devflow:docs-verify --report-only` and capture its findings report
2. Clarify the user story until the **Definition of Ready** is met (Step 2)
3. Draft the issue and pass the **no-options gate** (Step 3)
4. Steelman the draft against the code, revise, and re-pass the no-options gate (Step 3.5)
5. Audit the draft in a fresh context, act on the verdict, and re-gate any revision (Step 3.6)
6. Present the rendered issue, get the user's explicit confirmation, then create it (Step 4, sub-steps 1–5)
7. After creation succeeds, run the gated implement-offer step — present the offer, or print the withheld-offer reason (Step 4, sub-step 6)

Mark each item `in_progress` when you start and `completed` only when done — that is the canonical status vocabulary; a task tool whose status fields differ uses its nearest equivalents, and the inline checklist fallback expresses the same transitions with the three status markers that `references/fallback-no-task-tool.md` defines. **The issue is created only after the user explicitly confirms the rendered draft (todo 6) — never before.** A finished `/devflow:docs-verify` report is only todo 1. If the user has not yet confirmed, the pipeline is paused at todo 6, not complete; that is a valid waiting state, not a reason to create the issue anyway. Todo 7 runs only after a successful creation — it is the post-creation hand-off, not a gate on creating the issue.

**When no task-tracking tool is usable**, the inline-checklist fallback in `references/fallback-no-task-tool.md` tracks the same seven items; load it per the routing table below.

## Reference routing

The per-step procedures and the conditional fallback arms live in `references/`, loaded at their trigger. **Load a reference by building its path from this skill's directory per the *Portable helper anchor* rules above** (the runner-reported skill base directory, with prompt-time Windows-path normalization) and **reading it with the runner's file-read tool** — never a new shell invocation. A load is accepted only when the file's **first line is its `start` boundary marker and its last line is the matching `end` marker**, each naming that file's own path, with exactly one of each.

**Every load failure degrades, and no failure arm terminates the run.** On an unreadable or absent file, an empty file, a missing / duplicated / foreign-path marker, or a truncated read, emit an in-chat breadcrumb naming the file and the failure kind, then continue on that row's named degraded behavior below. The four non-degradable invariants stated after this table hold on every degraded arm.

| Load trigger | File | Marker contract | Degraded behavior on a failed load |
| --- | --- | --- | --- |
| Step 2 entry | `references/step-2-clarify.md` | `step=2` | Clarify from the Definition-of-Ready summary in the completion checklist, asking via the runner's user-question tool; record the derivation in chat when it cannot be written to disk, and report the reduced clarification |
| Step 3.5 entry | `references/step-3-5-steelman.md` | `step=3.5` | Verify the draft's load-bearing claims and file references against the code inline, and report the steelman as reduced in chat |
| Any revise-and-re-gate site | `references/revision-delta.md` | `step=revision-delta` | Re-gate the revision under Step 3 and report that the delta walk was unavailable |
| Step 3.6 entry | `references/step-3-6-audit.md` | `step=3.6` | Audit the rendered draft yourself in chat for exactly one round, keep the findings in chat, ask the user once whether to continue, and mark the audit summary line as degraded |
| Step 4 entry | `references/step-4-present-create.md` | `step=4` | Render the full draft in chat, carry the audit summary line, and create only on the user's explicit approval — the invariants below |
| No task-tracking tool is exposed, or the exposed one is disabled or unusable | `references/fallback-no-task-tool.md` | `step=fallback-no-task-tool` | Track the seven checklist items as a re-rendered in-chat block and report that the state-file mirror was unavailable |
| A write or delete under `.devflow/tmp/` fails because the filesystem is read-only | `references/fallback-read-only-sandbox.md` | `step=fallback-read-only-sandbox` | Post the affected artifact as a visible in-chat block in the current turn and distrust any on-disk copy |
| `query-arm` answers a non-file arm, a dispatch retry escalates, or no subagent tool is exposed | `references/fallback-audit-dispatch-arms.md` | `step=fallback-audit-dispatch-arms` | Audit the rendered draft in chat for that round and mark the audit summary line as degraded |
| The state owner produces no contract output, or a mutation fails to establish or persist state | `references/fallback-state-owner-unavailable.md` | `step=fallback-state-owner-unavailable` | Run one in-chat audit round, offer one continue/decline choice, and proceed only on the user's explicit election |

## Non-degradable invariants

These four hold on every path, including every degraded arm above, and are load-independent of any reference:

1. **The issue is created only after the user explicitly approves the full rendered draft in chat.** The full title and body are rendered verbatim in your message first; an earlier "just create it", a complete Step 2, or a paused pipeline is never a substitute for approval of *this* draft.
2. **The no-options gate** (stated under Step 3 below) passes on the body that is shown and on every revision of it.
3. **The audit summary line is mandatory and always renders** — even on a clean `VERDICT: FILE` with zero findings. A skipped or degraded audit is **never silent**; the summary line is the evidence the audit ran and which arm it took.
4. **The reserved `DevFlow` provenance label is applied best-effort after creation, and any degradation is reported explicitly** — a label hiccup never blocks creation, and a `DevFlow` label that could not be applied is named in the final outcome rather than passed over.

## Steps

### Step 1: Assess current state (read-only)
Invoke the `/devflow:docs-verify` skill in report-only mode with the topic extracted from the user story (e.g., `/devflow:docs-verify --report-only survey module`).

This verifies internal docs against the code and **returns a findings report** — current behavior, relevant files, and any doc/code drift — **without editing, committing, or pushing anything.**

`/devflow:docs-verify` is a standalone workflow, so it announces its own completion when it finishes. That signal ends *its* report (todo 1), not this skill — keep going to Step 2. Carry the findings, including any drift noted, forward into Step 3.

**Completion-wait discipline (mandatory, mirroring Step 3.6's synchronous dispatch).** The docs-verify findings report must be **complete and captured before the first Step 2 clarification question** — and, on a run so complete it asks **zero** clarifying questions, **before Step 3 drafting begins**. When a runner executes `/devflow:docs-verify` as a subagent, **that dispatch blocks on the completed result**; a **launch acknowledgment is never treated as the findings report**. Do not open Step 2 clarification (or Step 3 drafting) on the strength of "docs-verify is running" — wait for its findings to land, exactly as Step 3.6 waits for the audit subagent's *completed* return before proceeding. This wait exists because clarification questions that arrive before the code findings that ground them interrogate the user prematurely (observed live: questions arrived before the docs-verify subagent had finished).

### Step 2: Clarify until the Definition of Ready is met

Load `references/step-2-clarify.md` per the routing table above and follow it exactly, on every entry into this step.

### Step 3: Draft the issue and pass the no-options gate

**Precondition — the Step 2 derivation-artifact gate applies here too, unconditionally.** Before drafting, confirm `.devflow/tmp/issue-derivation-<slug>.md` exists and holds *this run's* derivation — **or, in a read-only sandbox, rely solely on the visible inline-in-chat stand-in re-posted in this turn and do not trust any on-disk file (it can only be a stale leftover; the read-only distrust rule from the Step 2 gate applies here too)**. A fully specified story can reach this point having asked **zero** clarifying questions — the very "looks fully baked" case the derivation pass exists to defuse — so the Step 2 gate's first-clarification-question trigger may never have fired. This drafting precondition is the unconditional backstop: drafting happens on every run, clarification does not. If the artifact is missing or you cannot confirm it is this run's, the independent-derivation pass was skipped — **stop and run it now (Step 2) before drafting.** **This precondition equally gates the `## Evidence bundle`:** it must be present and axis-complete against the effective list recomputed here (the second, unconditional site of the *Bundle-coverage gate*), so the zero-question and disengagement paths carry the same bundle coverage the ordinary path does — if it is missing or an axis has no entry, the evidence-bundle sub-pass was skipped, so stop and run it now before drafting.

Draft the issue **from the context you already hold** — the documentation findings from Step 1 (relevant files, current behavior, any drift) and the decisions from Step 2 — doing only targeted verification reads where a specific claim needs confirming. Do not re-explore the whole codebase; the findings are your map.

Follow `references/issue-template.md` for the required section structure, the **no-options rule**, the quality checklist, and autolink hygiene. This read is deliberately ungated (the file carries no boundary markers), so it has its own failure arm: if it cannot be read, say so in chat, draft against the section list in the completion checklist above, re-gate the body inline per Step 3's rule, and — because that file also carries the exact `gh issue create` recipe — do **not** improvise the invocation: pass the body through a non-empty-guarded `--body-file`, never a pipe. Filing is not blocked; the degradation is reported. Key rules:

- **No-options gate (run before showing the draft):** re-read the rendered body. Outside the `## 🚫 Blocked` section it must contain **no** unresolved-decision language — no "or", "either", "alternatively", "could", "we might", "TBD", "option", "approach A vs B", "(optional)"-for-undecided, "e.g. X or Y" where X and Y are competing choices. Each acceptance criterion is one concrete unconditional assertion. If you find any such language, you skipped a decision: either ask the user now, or move it to the Blocked section. Do not proceed to Step 4 until the body is clean.

Drafting produces a candidate issue **in your message only** — nothing is posted to GitHub in this step. Posting happens in Step 4, and only after the user confirms — but first the draft must survive Step 3.5.


### Step 3.5: Steelman the draft against the code (mandatory, before the user sees it)

Load `references/step-3-5-steelman.md` per the routing table above and follow it exactly, on every entry into this step.

### Step 3.6: Fresh-context audit (mandatory, before the user sees it)

Load `references/step-3-6-audit.md` per the routing table above and follow it exactly, on every entry into this step.

### Step 4: Review with the user, then create

Load `references/step-4-present-create.md` per the routing table above and follow it exactly, on every entry into this step.

---

User Story (rough draft): $ARGUMENTS
