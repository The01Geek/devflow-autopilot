---
name: create-issue
description: Use when you have a rough user story, bug report, or feature idea that needs to become a well-structured GitHub issue.
argument-hint: <user-story>
---
**Consumer prompt extension (load first).** Before doing this skill's work, load any consumer-supplied prompt extension for this skill and honor it. From the repo root, run:

```bash
${CLAUDE_SKILL_DIR}/../../scripts/load-prompt-extension.sh create-issue
```

If the helper exits non-zero, a consumer extension exists but could not be loaded — surface its stderr message and do not silently proceed as if none existed. If it exits 0 and prints text, treat that text as additional instructions appended to the end of this skill's own prompt for this run — it is upgrade-safe, consumer-owned customization committed under `.devflow/prompt-extensions/`. If it exits 0 and prints nothing, proceed unchanged.

## Prerequisites

If `$ARGUMENTS` is empty, ask the user to describe their user story, bug report, or feature idea before proceeding.

## Core principle

**An issue is the output of resolved decisions — not a place to park unresolved ones.**

Every decision a developer would otherwise have to guess at MUST be resolved by asking the user *before* the issue is written. Whatever the user genuinely will not or cannot resolve goes into one explicit **Blocked** section — never disguised as an "option", a "recommended approach", an "Open Question", a default, or conditional wording scattered through the body.

## Completion checklist (do this first)

This skill is a **pipeline that ends with a created GitHub issue and an offer to start implementation** — not with a documentation report. Before doing anything else, create a TodoWrite todo list with exactly these items:

1. Run `/devflow:docs-verify --report-only` and capture its findings report
2. Clarify the user story until the **Definition of Ready** is met (Step 2)
3. Draft the issue and pass the **no-options gate** (Step 3)
4. Present the rendered issue, get the user's explicit confirmation, then create it (Step 4, sub-steps 1–5)
5. After creation succeeds, offer to start implementation (Step 4, sub-step 6)

Mark each todo `in_progress` when you start and `completed` only when done. **The issue is created only after the user explicitly confirms the rendered draft (todo 4) — never before.** A finished `/devflow:docs-verify` report is only todo 1. If the user has not yet confirmed, the pipeline is paused at todo 4, not complete; that is a valid waiting state, not a reason to create the issue anyway. Todo 5 runs only after a successful creation — it is the post-creation hand-off, not a gate on creating the issue.

## Steps

### Step 1: Assess current state (read-only)
Invoke the `/devflow:docs-verify` skill in report-only mode with the topic extracted from the user story (e.g., `/devflow:docs-verify --report-only survey module`).

This verifies internal docs against the code and **returns a findings report** — current behavior, relevant files, and any doc/code drift — **without editing, committing, or pushing anything.**

`/devflow:docs-verify` is a standalone workflow, so it announces its own completion when it finishes. That signal ends *its* report (todo 1), not this skill — keep going to Step 2. Carry the findings, including any drift noted, forward into Step 3.

### Step 2: Clarify until the Definition of Ready is met

**Clarification is the default, not the exception.** Do not assess "is this clear enough to skip" — assess "which Definition-of-Ready facts are still unknown" and ask about those. The only way to skip a question is to already know its answer from the user story or the Step 1 findings.

**Definition of Ready — every item below must have a single, decided answer before you draft:**

- [ ] **Independent derivation before anchoring (run the pass below FIRST, on every run).** You have re-derived the full Definition of Ready from the problem and the Step 1 findings *before* weighing the user's supplied criteria — challenging supplied acceptance criteria on both **completeness** and **correctness** — **written that derivation to its observable artifact (`.devflow/tmp/issue-derivation-<slug>.md`) before any clarification round**, and you drive clarification from the **delta plus conflicts**. Re-checking this item (below) confirms the file exists, so a skipped pass is surfaced rather than assumed. See the independent-derivation pass below; it mirrors "Solution-space expansion before convergence," generalized from the implementation-approach fork to the problem, behavior, edge-case, and acceptance-criteria forks.
- [ ] **Problem & beneficiary** — who hits this pain and why it matters. (Not "users want export" — *which* users, doing *what*, blocked *how*.)
- [ ] **Single coherent scope** — the issue is exactly one feature/fix. If the story bundles two or more ("export results *and* notify when ready"), ask the user whether to split; default to one issue per feature.
- [ ] **One decided behavior per fork** — every place the story could mean different things (format, channel, trigger condition, access model, edge-case handling) has *one* chosen answer. No "or", no "either", no "default for now".
- [ ] **Solution-space expansion before convergence (do this BEFORE the implementation-approach fork below).** The user's proposed mechanism is an *input*, not the menu. Before asking the user to pick an approach, independently generate the full space of mechanisms that could solve the stated problem — and in particular ask: *is there a categorically STRONGER class of mechanism than what the user proposed?* Mechanisms differ in **strength of guarantee**, not just shape. A useful ladder, weakest→strongest: (a) documentation/wording that asks a human or agent to remember; (b) an in-process self-check that *warns* when the thing was skipped; (c) a *deterministic* mechanism that runs regardless of the actor's choices (a harness/hook/wrapper that fires after-the-fact, an enforced gate, an idempotent backstop that re-does the work). If the user proposed only (a) and/or (b), you MUST generate at least one (c)-class candidate and put it on the menu. Name the strongest viable mechanism even if the user did not think of it — surfacing it is your job, not theirs. If after genuine effort no stronger class exists (or the stronger classes don't apply to this problem — e.g. a harness fires at the wrong point), say so explicitly in the question rationale rather than silently omitting it.
- [ ] **One implementation approach** — present the expanded mechanism menu (including the strongest class found above), and the user has picked one. You surface each option's **guarantee-strength** and trade-offs *in the question*, not in the issue.
- [ ] **Concrete acceptance criteria** — you can state each as a single unconditional, testable assertion. If an AC would need a conditional ("if links are public…"), the underlying fork isn't resolved yet — go ask.

**Independent-derivation pass (mandatory, before any clarification round — runs on every run regardless of how complete the story looks).**

A story that *looks* fully baked — structured sections, its own acceptance-criteria list — is the trap this pass defuses: when criteria arrive pre-written, the temptation is to treat them as answers "already known from the user story" and skip derivation, so the supplied list silently anchors the whole issue. A terse one-line story produces a *better* issue precisely because there is nothing to anchor on. This pass removes the anchor by **ordering**, not by isolation:

1. **Derive first, read the supplied answers second — and write the derivation to an observable artifact.** Before reading the user's acceptance criteria (and any other pre-supplied decisions) *as answers*, independently re-derive the full Definition of Ready above — problem/beneficiary framing, every behavioral fork, edge/error cases, and the acceptance criteria — from the stated problem and the Step 1 codebase findings. **Write that derivation to `.devflow/tmp/issue-derivation-<slug>.md` before any clarification round begins** — run `mkdir -p .devflow/tmp` first, then **pick the kebab-case `<slug>` once (from the user story's topic) and reuse that exact path for the rest of this run**, so the gate and per-round re-checks below look for the same file and a later re-derivation can't make them false-fire. This reuses Step 4's gitignored `.devflow/tmp/` convenience-copy convention (Step 4 writes `issue-draft-<slug>.md` under the same pick-the-slug-once rule); reuse the same `<slug>` for both so one issue keeps a single stem. If the write genuinely fails (e.g. a read-only sandbox), say so in chat and record the derivation inline in your message instead, so it is still observable — never silently skip writing it down. The artifact is the observable proof of the ordering: you commit your own list to a file before the user's list can frame your thinking. This is a forced self-check **with an observable artifact**, not an isolation guarantee — you still see the supplied criteria; you simply derive, and record the derivation, *before* weighing them. (A blind-subagent variant that never sees the supplied list was rejected, to keep this skill's no-subagent, all-inline model and avoid the added latency; the artifact adds no new script, dependency, or subagent — only the `mkdir -p` + file write Step 4 already performs.)
2. **Treat supplied acceptance criteria as suspect on two axes.** *Completeness* — which behavioral forks, edge cases, and factors does your independent list have that theirs omits? *Correctness* — is each supplied criterion atomic, testable, and a genuinely resolved decision, or a buried unresolved fork wearing the costume of a decided one? A polished, comprehensive-looking list earns the **same** scrutiny a terse story gets, since it has more to challenge.
3. **Drive the clarification rounds from the delta.** Diff your independently-derived list against the story and clarify from the **delta plus any conflicts** — the forks, edge cases, and factors you derived that the story left unresolved; the supplied criteria that fail the correctness test; and anywhere the two lists disagree. The supplied criteria are one of the two inputs to that diff, never a shortcut past it.

This pass **feeds** the clarification rounds; the no-options gate (Step 3) still governs the final body. Its output is a working derivation to clarify against — never a place to park options in the issue itself.

**How to ask:**

- **Gate — confirm the derivation artifact exists before the first clarification round.** Before the first `AskUserQuestion` call, verify `.devflow/tmp/issue-derivation-<slug>.md` is present (the artifact written by the pass above). If it is missing, the independent-derivation pass was skipped — **stop, run the pass and write the artifact now, and only then ask anything.** Do not begin clarification without it; surface its absence rather than silently continuing. (If the write itself failed in a read-only sandbox, the inline derivation recorded in chat per the pass above stands in for the file — but a *missing* derivation, neither on disk nor in chat, means the pass did not run.)
- Use the **AskUserQuestion** tool. Source the batches from the independent-derivation **delta plus conflicts** (the pass above), and batch 2–4 related questions per call rather than one long interrogation.
- For each question, offer concrete multiple-choice options. When the codebase or findings make one choice clearly best, list it **first** and mark it `(Recommended)` with a one-line why.
- After each round of answers, **re-check the Definition of Ready** — including that the derivation artifact still exists. If gaps remain, ask another batch. Keep going until the list is fully satisfied — do not draft with items still open.
- Cap at ~6 rounds. If facts are still missing after that, treat the remainder as disengagement (below).

**Push back once before accepting total disengagement.** If the user disengages while the issue is still *unbuildable* — no decided scope, or the single core behavior fork is still open (the ticket would be almost entirely Blocked) — do not silently produce a hollow issue. Say so plainly, once: e.g. *"As-is this issue won't be buildable — every decision is still open. Can you answer just two things: (1) is this one feature or several, and (2) <the single most defining behavior fork>? Otherwise I'll file it with everything flagged as blocked."* Ask those via one AskUserQuestion batch. If the user answers, continue clarifying; if they disengage again, proceed below. This push-back happens **at most once** — do not nag. It does not apply when only peripheral forks remain open (e.g. link expiry) — Block those without comment.

**When the user disengages** — says "just create it", goes quiet, or answers "I don't know" / "you decide" to a Definition-of-Ready question:

- Stop asking. Draft the issue from what *is* decided.
- Every still-unresolved Definition-of-Ready item goes into the issue's **`## 🚫 Blocked — resolve before implementation`** section, phrased as a direct question with one line on why it blocks work (see template).
- Do **not** invent a default and bury it in the body. Do **not** rephrase the open decision as an "option" or "recommended approach" elsewhere. The Blocked section is the *only* place an unresolved decision may appear.
- "You decide" is not permission to guess silently — it is an unresolved item that belongs in Blocked, unless the choice is genuinely inconsequential to scope (e.g. a variable name).

### Step 3: Draft the issue and pass the no-options gate

Draft the issue **from the context you already hold** — the documentation findings from Step 1 (relevant files, current behavior, any drift) and the decisions from Step 2 — doing only targeted verification reads where a specific claim needs confirming. Do not re-explore the whole codebase; the findings are your map.

Follow `references/issue-template.md` for the required section structure, the **no-options rule**, the quality checklist, and autolink hygiene. Key rules:

- **No-options gate (run before showing the draft):** re-read the rendered body. Outside the `## 🚫 Blocked` section it must contain **no** unresolved-decision language — no "or", "either", "alternatively", "could", "we might", "TBD", "option", "approach A vs B", "(optional)"-for-undecided, "e.g. X or Y" where X and Y are competing choices. Each acceptance criterion is one concrete unconditional assertion. If you find any such language, you skipped a decision: either ask the user now, or move it to the Blocked section. Do not proceed to Step 4 until the body is clean.

Drafting produces a candidate issue **in your message only** — nothing is posted to GitHub in this step. Posting happens in Step 4, and only after the user confirms.

### Step 4: Review with the user, then create

**The issue is never created until the user has seen the full rendered draft and explicitly approved it.** The user story they gave you was a rough input; this is their one chance to read the assembled ticket as a whole and correct it before it becomes a real, notification-sending GitHub issue. This gate is **unconditional** — it applies no matter how thoroughly Step 2 resolved every decision, and no matter what the user said earlier.

1. **Show the complete rendered issue in chat.** Post the exact title and the full body — every section, verbatim, as Markdown — directly in your message. Do not summarize it, abridge it, or describe it; the user reviews the literal text that would be filed. Do not use AskUserQuestion to stand in for showing the body (it truncates); render the body first, then you may use it for the confirm/edit prompt if you wish.
2. **Also write the draft to a file for easy review.** Reuse the kebab-case `<slug>` you picked for the Step 2 derivation artifact (so one issue keeps a single stem); if there is none, derive a short kebab-case slug from the issue title (e.g. "Add CSV export for survey results" → `add-csv-export-for-survey-results`). Write the rendered title + body to `.devflow/tmp/issue-draft-<slug>.md` (run `mkdir -p .devflow/tmp` first — that path is gitignored, so it never lands in a commit), with the title as a top `# ` heading above the body. **Pick the slug once, when you first write the file, and reuse that exact path for this issue from then on** — so revisions overwrite the one file (next sub-step) and a second or third issue you draft later gets its *own* distinct file instead of clobbering this one. This is a **convenience copy** so the user can open the draft in their editor; it never replaces showing the body in chat (todo above), and it is **not** the source the issue is created from. If the write fails (e.g. read-only sandbox), note it briefly and continue — the chat render is what matters.
3. **Ask for explicit confirmation or feedback.** Plainly invite the user to either approve creation or request changes. **The draft-save-location note (`.devflow/tmp/issue-draft-<slug>.md`) always renders *below* the rendered issue preview — never above it**, so every confirmation message has the same layout: the full rendered body (sub-step 1) first, then the draft-path note, then the confirm/edit question. Separate the note from the preview rather than embedding it inline ahead of the body — e.g. after the rendered body, add a line such as *"Draft also saved to `.devflow/tmp/issue-draft-<slug>.md` for review."* and then ask *"Want me to create it as-is, or change anything first?"*
4. **Iterate on feedback.** If the user requests any change, revise the draft, re-run the no-options gate (Step 3), **show the full rendered issue again, and overwrite the same `.devflow/tmp/issue-draft-<slug>.md` file you chose in sub-step 2** (keep the original filename even if the title changes, so you don't leave orphaned drafts behind). Repeat until the user approves. Each revision is re-presented in full — never apply edits and create in the same turn without showing the updated draft.
5. **Create only on explicit approval.** Once the user clearly says to create it (e.g. "yes", "create it", "looks good, file it"), create the issue **directly via `gh issue create`**, piping the body through stdin — not from the draft file. The `.devflow/tmp/issue-draft-<slug>.md` copy is a gitignored preview, never the `--body-file` source and never committed; the issue body still goes through the stdin heredoc. **Do not add labels** — never pass `--label`. Report the issue URL that `gh` prints on success, and capture the new issue's number from the trailing path segment of that URL (e.g. `…/issues/42` → `42`) — sub-step 6 needs it. See `references/issue-template.md` for the exact invocation.
6. **Offer to start implementation.** This sub-step runs **only after `gh issue create` succeeds** (it exits zero and prints an issue URL) and the URL has been reported. If creation failed (non-zero exit, or no URL printed), stop here and surface `gh`'s error output verbatim — do **not** show this prompt. After a successful creation, **always** present a yes/no prompt via the **AskUserQuestion** tool (as used in Step 2) asking whether to start implementation now by commenting `/devflow:implement <issue_number>` on the newly created issue.
   - **On "yes":** post the comment yourself with `gh issue comment <issue_number> --body "/devflow:implement <issue_number>"`, using the issue number captured in sub-step 5. Use the bare `/devflow:implement <n>` form with **no** `@claude` mention, so the comment routes to the repo's `devflow-implement.yml` listener rather than the stock Anthropic listener. If `gh issue comment` succeeds, report that the comment was posted, and that it fires the implement run **only when** the repo's devflow workflows are enabled and the commenter is authorized — both enforced by the `gate` job in `.github/workflows/devflow-implement.yml` (authorization via `scripts/resolve-implement-trigger.sh`). Surface that caveat in the reported outcome; it does **not** gate whether the prompt is shown. If `gh issue comment` fails, surface its error output and report that the issue was created but the implement comment could not be posted — do not claim the comment was posted.
   - **On "no":** finish without posting any comment.

**This gate has no exceptions:**
- "The user already answered every clarifying question in Step 2" — answering decision forks is **not** the same as reviewing the assembled ticket. Show it and wait.
- "The user said 'just create it' / 'you decide' earlier" — that was said about a story they had **not yet seen written up**. It is not approval of *this* drafted issue. Render the draft and get explicit go-ahead on it.
- "The user disengaged, so I'll file it with a Blocked section and move on" — drafting from what's decided is correct (Step 2), but you still present the rendered draft and wait for confirmation before creating. If the user never returns to confirm, leave the pipeline paused at todo 4 — do **not** create the issue to "finish".
- "Showing the full body is verbose; a summary is enough" — no. Render the literal title and body that will be filed.

**Red flags — STOP, you are about to skip the gate:**
- You are constructing the `gh issue create` command in the same turn you drafted the body, with no user message approving it in between.
- You are about to create the issue because Step 2 was "complete" or the user "already decided everything".
- You are treating an earlier "just create it" as approval of a draft the user has not seen.

All of these mean: show the full rendered issue, ask, and wait for an explicit yes.

---

User Story (rough draft): $ARGUMENTS
