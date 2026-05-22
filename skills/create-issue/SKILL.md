---
name: create-issue
description: Use when you have a rough user story, bug report, or feature idea that needs to become a well-structured GitHub issue.
argument-hint: <user-story>
---
## Prerequisites

If `$ARGUMENTS` is empty, ask the user to describe their user story, bug report, or feature idea before proceeding.

## Core principle

**An issue is the output of resolved decisions — not a place to park unresolved ones.**

Every decision a developer would otherwise have to guess at MUST be resolved by asking the user *before* the issue is written. Whatever the user genuinely will not or cannot resolve goes into one explicit **Blocked** section — never disguised as an "option", a "recommended approach", an "Open Question", a default, or conditional wording scattered through the body. Listing options in the issue body is the failure this skill exists to prevent.

## Completion checklist (do this first)

This skill is a **pipeline that ends with a created GitHub issue** — not with a documentation report. Before doing anything else, create a TodoWrite todo list with exactly these items:

1. Run `/docs-verify --report-only` and capture its findings report
2. Clarify the user story until the **Definition of Ready** is met (Step 2)
3. Draft and create the GitHub issue, passing the **no-options gate** (Step 3)

Mark each todo `in_progress` when you start and `completed` only when done. **The skill is not complete until the issue is created** — a finished `/docs-verify` report is only todo 1.

## Steps

### Step 1: Assess current state (read-only)
Invoke the `/docs-verify` skill in report-only mode with the topic extracted from the user story (e.g., `/docs-verify --report-only survey module`).

This verifies internal docs against the code and **returns a findings report** — current behavior, relevant files, and any doc/code drift — **without editing, committing, or pushing anything.**

`/docs-verify` is a standalone workflow, so it announces its own completion when it finishes. That signal ends *its* report (todo 1), not this skill — keep going to Step 2. Carry the findings, including any drift noted, forward into Step 3.

### Step 2: Clarify until the Definition of Ready is met

**Clarification is the default, not the exception.** Do not assess "is this clear enough to skip" — assess "which Definition-of-Ready facts are still unknown" and ask about those. The only way to skip a question is to already know its answer from the user story or the Step 1 findings.

**Definition of Ready — every item below must have a single, decided answer before you draft:**

- [ ] **Problem & beneficiary** — who hits this pain and why it matters. (Not "users want export" — *which* users, doing *what*, blocked *how*.)
- [ ] **Single coherent scope** — the issue is exactly one feature/fix. If the story bundles two or more ("export results *and* notify when ready"), ask the user whether to split; default to one issue per feature.
- [ ] **One decided behavior per fork** — every place the story could mean different things (format, channel, trigger condition, access model, edge-case handling) has *one* chosen answer. No "or", no "either", no "default for now".
- [ ] **One implementation approach** — where the codebase admits more than one way to build it, the user has picked one. You surface the fork and its trade-offs *in the question*, not in the issue.
- [ ] **Concrete acceptance criteria** — you can state each as a single unconditional, testable assertion. If an AC would need a conditional ("if links are public…"), the underlying fork isn't resolved yet — go ask.

**How to ask:**

- Use the **AskUserQuestion** tool. Batch 2–4 related questions per call rather than one long interrogation.
- For each question, offer concrete multiple-choice options. When the codebase or findings make one choice clearly best, list it **first** and mark it `(Recommended)` with a one-line why.
- After each round of answers, **re-check the Definition of Ready**. If gaps remain, ask another batch. Keep going until the list is fully satisfied — do not draft with items still open.
- Cap at ~3 rounds. If facts are still missing after that, treat the remainder as disengagement (below).

**Push back once before accepting total disengagement.** If the user disengages while the issue is still *unbuildable* — no decided scope, or the single core behavior fork is still open (the ticket would be almost entirely Blocked) — do not silently produce a hollow issue. Say so plainly, once: e.g. *"As-is this issue won't be buildable — every decision is still open. Can you answer just two things: (1) is this one feature or several, and (2) <the single most defining behavior fork>? Otherwise I'll file it with everything flagged as blocked."* Ask those via one AskUserQuestion batch. If the user answers, continue clarifying; if they disengage again, proceed below. This push-back happens **at most once** — do not nag. It does not apply when only peripheral forks remain open (e.g. link expiry) — Blocked those without comment.

**When the user disengages** — says "just create it", goes quiet, or answers "I don't know" / "you decide" to a Definition-of-Ready question:

- Stop asking. Draft the issue from what *is* decided.
- Every still-unresolved Definition-of-Ready item goes into the issue's **`## 🚫 Blocked — resolve before implementation`** section, phrased as a direct question with one line on why it blocks work (see template).
- Do **not** invent a default and bury it in the body. Do **not** rephrase the open decision as an "option" or "recommended approach" elsewhere. The Blocked section is the *only* place an unresolved decision may appear.
- "You decide" is not permission to guess silently — it is an unresolved item that belongs in Blocked, unless the choice is genuinely inconsequential to scope (e.g. a variable name).

### Step 3: Draft and create the GitHub issue

Draft the issue **from the context you already hold** — the documentation findings from Step 1 (relevant files, current behavior, any drift) and the decisions from Step 2 — doing only targeted verification reads where a specific claim needs confirming. Do not re-explore the whole codebase; the findings are your map.

Follow `references/issue-template.md` for the required section structure, the **no-options rule**, the quality checklist, autolink hygiene, and the exact `gh issue create` invocation. Key rules:

- **No-options gate (run before posting):** re-read the rendered body. Outside the `## 🚫 Blocked` section it must contain **no** unresolved-decision language — no "or", "either", "alternatively", "could", "we might", "TBD", "option", "approach A vs B", "(optional)"-for-undecided, "e.g. X or Y" where X and Y are competing choices. Each acceptance criterion is one concrete unconditional assertion. If you find any such language, you skipped a decision: either ask the user now, or move it to the Blocked section. Do not post until the body is clean.
- Create the issue **directly via `gh issue create`** piping the body through stdin — no scratch file, nothing written to the working tree.
- **Do not add labels** — never pass `--label`.
- Report the issue URL that `gh` prints on success.

---

User Story (rough draft): $ARGUMENTS
