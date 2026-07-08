---
name: receiving-code-review
description: Use when receiving code review feedback, before implementing suggestions, especially if feedback seems unclear or technically questionable - requires technical rigor and verification, not performative agreement or blind implementation
---

# Code Review Reception

**Portable helper anchor (single-statement).** The bundled-helper commands in this skill resolve the skill directory inline at each call site via `${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}`. When `$CLAUDE_SKILL_DIR` is set and non-empty (Claude Code), run each command exactly as written. On a runner where it is unset or empty, replace the placeholder with the skill base directory the runner reports in context (e.g. a `Base directory for this skill:` line) before running the command; if that reported path is Windows-form (`C:\...`), first convert it to this shell's POSIX form with one standalone `wslpath -u '<path>'` (WSL) or `cygpath -u '<path>'` (Git Bash/MSYS2) command and substitute the printed result **only if the command succeeds and prints a non-empty path — otherwise fall through to the drive-letter rules exactly as if the tool were absent, the same success-and-non-empty acceptance the platform's path-normalization rules apply** (if neither tool exists: lowercase the drive letter, map `C:\` to `/mnt/c` on WSL or `/c` on MSYS2, and turn backslashes into `/`; if the environment is neither WSL nor MSYS2, use the path unchanged and report that it could not be normalized — the same arm the platform's path-normalization rules take). Resolve the anchor inline at every call site — never capture it into a shell variable that a later statement reads, because some runners' inline-bash marshaling drops such variables (observed on Copilot CLI). If neither `$CLAUDE_SKILL_DIR` nor a runner-reported base directory is available, stop and report that the helper anchor could not be resolved rather than running a command with a broken path.

**Consumer prompt extension (load first).** Before doing this skill's work, load any consumer-supplied prompt extension for this skill and honor it. From the repo root, run:

```bash
"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/load-prompt-extension.sh receiving-code-review
```

If the invocation fails because the helper path does not exist (`No such file`, exit 127, or the platform equivalent), that is the **anchor-resolution** failure described in the *Portable helper anchor* note above — fix the anchor, don't report a missing extension. Otherwise, if the helper exits non-zero, a consumer extension exists but could not be loaded — surface its stderr message and do not silently proceed as if none existed. If it exits 0 and prints text, treat that text as additional instructions appended to the end of this skill's own prompt for this run — it is upgrade-safe, consumer-owned customization committed under `.devflow/prompt-extensions/`. If it exits 0 and prints nothing, proceed unchanged.

**DevFlow context.** This skill is vendored verbatim from `superpowers`, where its examples address a "human partner" you converse with and "report to." Inside DevFlow's *autonomous* `/devflow:review-and-fix` fix loop there is no interactive human in the turn: read every "your human partner" / "report to me" framing below as the loop's own escalation channels — the deferrals manifest, the pushback/decision tracking recorded in the workpad, and the PR/issue trail a human reviews later. The technical-rigor principle (verify before implementing, push back when wrong) is identical; only the audience for the pushback differs.

## Overview

Code review requires technical evaluation, not emotional performance.

**Core principle:** Verify before implementing. Ask before assuming. Technical correctness over social comfort.

## The Response Pattern

```
WHEN receiving code review feedback:

0. UPDATE BRANCH: Update the working branch first (see Update the Branch First below)
1. READ: Complete feedback without reacting
2. UNDERSTAND: Restate requirement in own words (or ask)
3. VERIFY: Check against codebase reality
4. EVALUATE: Technically sound for THIS codebase?
5. RESPOND: Technical acknowledgment or reasoned pushback
6. IMPLEMENT: One item at a time, test each — treat each fix as new code (see A Fix Is New Code)
7. RECORD DEFERRALS: For every finding you did NOT fix, write a durable trace (WHAT/WHY/revisit-condition) before claiming done — see Record Every Deferral
8. VERIFY BEFORE DONE: Review diff against addressed findings + run test suite — only then claim completion
```

## Update the Branch First (Step 0)

Start every reception by updating the working branch, so steps 3 (VERIFY) and 8 (VERIFY BEFORE DONE) operate on the code that will actually merge rather than a stale snapshot. Fetch from the remote first; when the branch's remote counterpart has commits the local branch lacks, merge them in; then merge the base branch into the working branch. Check the exit status and resulting working-tree state of each fetch and merge, so a failed fetch or a conflicted merge is detected rather than passed over silently. Any merge conflicts these updates raise are resolved as part of the current work, before any review finding is implemented. When the branch cannot be updated — no remote counterpart, a failed fetch, a detached HEAD, or a read-only environment — record the limitation and proceed on the local state; the step is fail-soft and never blocks feedback work when there is nothing to update from.

## Verification Gate (Step 8)

**Iron Law: NO COMPLETION CLAIMS WITHOUT FRESH VERIFICATION EVIDENCE**

Before declaring the review findings addressed:
1. Review the diff of your changes against the addressed findings. For each fix, verify the fix is correct for *all* inputs and conditions — not only the case the reviewer described. Fixing one problem while introducing a new inaccuracy is a common failure mode the test suite may not catch (e.g. a breadcrumb that fires on `|| VAR=""` emptiness rephrased to say "failed", implying a non-zero exit, missing the asymmetric-empty case).
2. Verify your own diff's claims against HEAD. Treat every documentation, comment, changelog, or PR-body assertion the change adds or relies on as a claim to verify against HEAD before declaring done — especially "X remains unscoped / is still broken / is unhandled" claims, and anything another file in the same change contradicts. A documented falsehood is a correctness defect in the deliverable, not a cosmetic nit: `git log -S` / grep the symbol at HEAD, then fix the prose (or, if the code is the thing that is wrong, fix the code).
3. Run the project's test suite. Attempt the direct/local invocation first; restrict the CI fallback to a genuine sandbox or permission denial — never when the suite runs but fails. When using the CI fallback, actively wait to observe CI go green (submitting a push is not the same as observing green); do not claim completion until CI confirms green. Record the local-skip reason as an auditable note.
4. Only after all three pass, claim completion.

This gate applies in both interactive sessions and the autonomous `/devflow:review-and-fix` fix loop. In the loop, the fix step runs tests and the review engine re-runs each iteration to re-check whether every finding is resolved — no additional step 8 invocation is needed at the APPROVE claim.

## Stop When the Verdict Is Already Non-Blocking

A review engine that re-runs after every edit is *exhaustive*: each pass surfaces a fresh batch of advisory notes. That is the engine working, not a regression — expecting an already-clean run to produce zero new notes is the mistake that puts the loop on an advisory treadmill, where every edit spawns the next batch and nothing ever converges.

Once the verdict is already non-blocking (an APPROVE, or any approve-with-notes verdict), the bar for re-opening the diff changes. **Resolve that bar once** from the project's configured fix threshold, read through the same bundled-helper pattern this skill's prompt-extension loader already uses. The config reader returns the raw value but does not validate it, so validate the enum inline and fall back to a safe default with a stderr breadcrumb naming the key and the fallback value (it never aborts):

```bash
# Discriminate a resolver FAILURE from a bad ENUM value with single-statement branches
# that read no variable carried across statements: an inline-bash runner that strips a
# variable assigned in one statement and read in a later one (Copilot CLI / Cursor / Codex
# CLI / Gemini CLI) would otherwise leave a captured rc empty, misreporting a resolver
# failure as a bad enum value. The `if !` condition reads the config reader's OWN exit
# status directly (its stderr is never suppressed, so a rc≠0 failure surfaces its own
# parse/missing-python3 message too); the value validation is a separate `case` on the
# value alone. Both fall back to the default `critical`, each with its own breadcrumb.
if ! REOPEN_THRESHOLD=$("${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/config-get.sh .receiving_review.fix_severity_threshold critical); then
  echo "receiving-code-review: could not read .receiving_review.fix_severity_threshold (config reader rc≠0); using default 'critical'" >&2
  REOPEN_THRESHOLD=critical
fi
case "$REOPEN_THRESHOLD" in
  critical|important|suggestion) : ;;
  *) echo "receiving-code-review: .receiving_review.fix_severity_threshold value '$REOPEN_THRESHOLD' is not one of critical/important/suggestion; using default 'critical'" >&2
     REOPEN_THRESHOLD=critical ;;
esac
```

Severity ordering: `critical` > `important` > `suggestion`; "at or above `$REOPEN_THRESHOLD`" reads down that ladder. At the default `critical`, only a Critical/blocking finding re-opens the diff (the historical bar); a lower configured threshold re-opens for findings at or above it. **Scope:** this threshold governs a **direct** invocation of this skill. When these principles run inside an autonomous fix loop that drives its own severity routing, that loop's routing governs re-opening and this key is not consulted.

- **Re-open only for** a finding whose severity is at or above `$REOPEN_THRESHOLD`, or a demonstrable correctness defect (one that cites a concrete failing input). These still get fixed immediately.
- **The demonstrable-correctness-defect / documented-falsehood carve-out re-opens the diff at every threshold value** — it is a correctness principle, not a severity grade, so it applies even when `$REOPEN_THRESHOLD` is `critical`. **A finding that a claim is stale, contradicts HEAD, or contradicts another part of this change is blocking** — never advisory. A documented falsehood is *itself* a demonstrable correctness defect, so it re-opens the diff even on an otherwise already-passing verdict. **This includes a code path that violates a contract the deliverable itself publishes** — a header promise ("safe to source under `set -e`"), a docstring guarantee, a comment stating an invariant: code that contradicts its own stated contract is a documented falsehood no matter how minor the reviewer graded it. **Triage such a note by running the published claim against the code, not by its severity chip** — a Suggestion-labelled note that the code breaks its own contract still re-opens the diff at every threshold. Verify it against HEAD (`git log -S` / grep the symbol), then fix the code (or the contract), or correct the reviewer.
- **Everything else is recorded or deferred** (see Record Every Deferral below), not implemented. A note whose severity is *below* `$REOPEN_THRESHOLD` on an already-passing verdict does not, by itself, re-open the diff.
- **Bound any advisory re-open to a concrete, pre-agreed set.** If advisory notes *are* worth one more pass, name the specific bounded set of them before you start — never "address all the notes," which guarantees the next run produces a new batch and the loop never settles.

## Forbidden Responses

**NEVER:**
- "You're absolutely right!" (explicit instruction-file violation)
- "Great point!" / "Excellent feedback!" (performative)
- "Let me implement that now" (before verification)
- Claiming done / expressing satisfaction before step 8 (VERIFY BEFORE DONE) is complete (see Verification Gate above for the loop pipeline)

**INSTEAD:**
- Restate the technical requirement
- Ask clarifying questions
- Push back with technical reasoning if wrong
- Just start working (actions > words)

## Handling Unclear Feedback

```
IF any item is unclear:
  STOP - do not implement anything yet
  ASK for clarification on unclear items

WHY: Items may be related. Partial understanding = wrong implementation.
```

**Example:**
```
your human partner: "Fix 1-6"
You understand 1,2,3,6. Unclear on 4,5.

❌ WRONG: Implement 1,2,3,6 now, ask about 4,5 later
✅ RIGHT: "I understand items 1,2,3,6. Need clarification on 4 and 5 before proceeding."
```

## Source-Specific Handling

### From your human partner
- **Trusted** - implement after understanding
- **Still ask** if scope unclear
- **No performative agreement**
- **Skip to action** or technical acknowledgment

### From External Reviewers
```
BEFORE implementing:
  1. Check: Technically correct for THIS codebase?
  2. Check: Breaks existing functionality?
  3. Check: Reason for current implementation?
  4. Check: Works on all platforms/versions?
  5. Check: Does reviewer understand full context?
  6. Check: Does the note appeal to a "convention" / "standard" / "canonical pattern"?
           grep the repo to confirm that convention actually exists before reshaping code to match it.

IF suggestion seems wrong:
  Push back with technical reasoning

IF a cited convention / canonical pattern does not actually exist in the repo:
  Push back, citing the file's real, uniform pattern as evidence.
  Do not reshape code to match an aspirational or non-existent standard — that makes the code LESS consistent, not more.

IF can't easily verify:
  Say so: "I can't verify this without [X]. Should I [investigate/ask/proceed]?"

IF conflicts with your human partner's prior decisions:
  Stop and discuss with your human partner first
```

**your human partner's rule:** "External feedback - be skeptical, but check carefully"

## YAGNI Check for "Professional" Features

```
IF reviewer suggests "implementing properly":
  grep codebase for actual usage

  IF unused: "This endpoint isn't called. Remove it (YAGNI)?"
  IF used: Then implement properly
```

**your human partner's rule:** "You and reviewer both report to me. If we don't need this feature, don't add it."

## Implementation Order

```
FOR multi-item feedback:
  1. Clarify anything unclear FIRST
  2. Then implement in this order:
     - Blocking issues (breaks, security)
     - Simple fixes (typos, imports)
     - Complex fixes (refactoring, logic)
  3. Test each fix individually
  4. Verify no regressions
```

## Union Findings Across Review Iterations

When review output spans more than one run, do not act only on the latest batch. **Union the findings across iterations.** A genuine finding can surface as Important in one run, fade to a footnote in the next, and escalate again in a third; acting only on the most prominent current list lets a real defect slip away between batches.

Treat a finding **raised in a prior run and never resolved, still true** as *escalating* priority — it does not retire just because a later run happened to rank it lower. (This presupposes prior-iteration findings are handed to you. When they are, fold them into the current set. If your project's review engine does not surface them, union across the findings you are actually given and note the gap rather than assuming the prior set was complete.)

## When To Push Back

Push back when:
- Suggestion breaks existing functionality
- Reviewer lacks full context
- Violates YAGNI (unused feature)
- Technically incorrect for this stack
- Legacy/compatibility reasons exist
- Conflicts with your human partner's architectural decisions

**How to push back:**
- Use technical reasoning, not defensiveness
- Ask specific questions
- Reference working tests/code
- Involve your human partner if architectural
- Record the pushback as a deferral (see Record Every Deferral) — an un-recorded pushback is re-raised identically next run

**If you're uncomfortable pushing back out loud:** Name that tension, then tell your partner about the issue you've seen. They'll appreciate your honesty.

## Symmetric Severity Calibration

Pushing back on a *wrong* finding is only half of technical reception. The other half is that a finding can be **correct and still over-graded** — a genuine defect labelled `Critical`/`Important` whose observable fail-direction and impact are milder than the label claims. Evaluating severity is not just "is this real?"; it is "what does the code *observably do* on the bad input, and does that match the grade?"

Severity must be **calibrated against the observable fail-direction and impact in both directions**, not only pushed back when a finding is wrong on correctness. Calibrate against what the code observably does, not the reviewer's stated label:

- A defect that **fails closed** (aborts, refuses, or returns the safe value on the bad input) or whose failure mode the **test suite already catches** has a loud, bounded blast radius — a visible stop, not a silent corruption. Real and worth fixing, but rarely the top severity.
- A **diagnostic-or-cosmetic-only** finding — the wording of a message, log line, breadcrumb, or comment, with no wrong output, no corrupted state, and no skipped guard — has no behavioral fail-direction. Real and worth fixing, but not a high-severity blast radius.
- A defect that **fails open** (admits a wrong value, corrupts state, or skips a guard silently) is the one whose observable impact actually supports a high severity.

The discipline is **symmetric**: do not silently inflate a mild finding into a blocker, and do not silently *deflate* a severe one to dodge work. When you calibrate a severity — in either direction — record the observable evidence for the new grade (which fail-direction the code takes, what the suite catches, what the real blast radius is). A severity you change but cannot evidence is just a different guess; a severity you can evidence is a calibration. Never down-calibrate to avoid the fix — calibrate only to the impact you can demonstrate, and when in doubt about a genuine defect, keep the higher grade.

## Record Every Deferral

Every finding you do **not** fix must leave a durable, traceable record the next review pass can see — naming WHAT was deferred, WHY, and the condition that would make it worth revisiting. Without that record the next run rediscovers the finding from scratch and re-raises it at full severity; with it, the next run can downgrade it ("already deferred with justification — not blocking") instead of re-litigating it every pass.

Write the deferral, in order of preference, to the first channel available:

1. the loop's deferral / decision record (the durable findings-tracking your project's review engine carries across runs),
2. a code comment at the finding's site,
3. a reply on the PR review thread, or
4. a linked follow-up issue.

**A successful pushback is itself a deferral** — record it the same way, with the technical reason you declined. To the next run, an un-recorded "the reviewer was wrong" is indistinguishable from "nobody ever looked at it," so it comes back identically every pass. Writing down WHY you declined is what makes the decision stick.

## Acknowledging Correct Feedback

When feedback IS correct:
```
✅ "Fixed. [Brief description of what changed]"
✅ "Good catch - [specific issue]. Fixed in [location]."
✅ [Just fix it and show in the code]

❌ "You're absolutely right!"
❌ "Great point!"
❌ "Thanks for catching that!"
❌ "Thanks for [anything]"
❌ ANY gratitude expression
```

**Why no thanks:** Actions speak. Just fix it. The code itself shows you heard the feedback.

**If you catch yourself about to write "Thanks":** DELETE IT. State the fix instead.

## Gracefully Correcting Your Pushback

If you pushed back and were wrong:
```
✅ "You were right - I checked [X] and it does [Y]. Implementing now."
✅ "Verified this and you're correct. My initial understanding was wrong because [reason]. Fixing."

❌ Long apology
❌ Defending why you pushed back
❌ Over-explaining
```

State the correction factually and move on.

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Performative agreement | State requirement or just act |
| Blind implementation | Verify against codebase first |
| Batch without testing | One at a time, test each |
| Assuming reviewer is right | Check if breaks things |
| Avoiding pushback | Technical correctness > comfort |
| Partial implementation | Clarify all items first |
| Can't verify, proceed anyway | State limitation, ask for direction |

## Real Examples

**Performative Agreement (Bad):**
```
Reviewer: "Remove legacy code"
❌ "You're absolutely right! Let me remove that..."
```

**Technical Verification (Good):**
```
Reviewer: "Remove legacy code"
✅ "Checking... build target is 10.15+, this API needs 13+. Need legacy for backward compat. Current impl has wrong bundle ID - fix it or drop pre-13 support?"
```

**YAGNI (Good):**
```
Reviewer: "Implement proper metrics tracking with database, date filters, CSV export"
✅ "Grepped codebase - nothing calls this endpoint. Remove it (YAGNI)? Or is there usage I'm missing?"
```

**Unclear Item (Good):**
```
your human partner: "Fix items 1-6"
You understand 1,2,3,6. Unclear on 4,5.
✅ "Understand 1,2,3,6. Need clarification on 4 and 5 before implementing."
```

## GitHub Thread Replies

When replying to inline review comments on GitHub, reply in the comment thread (`gh api repos/{owner}/{repo}/pulls/{pr}/comments/{id}/replies`), not as a top-level PR comment.

## A Fix Is New Code

A fix is not a lower-stakes edit than the code it corrects — it is fresh code, written under time pressure by the one context least able to see its own blind spot. That is exactly how a fix closes the reported defect while quietly introducing a new one. Before the verification gate, give the fix delta the same scrutiny you would give any new code you wrote, matched to what the fix actually did:

- **A deletion** strands what fed the removed code — a now-unused local, import, or lookup — and can leave callers, links, or references pointing at something that is gone. Re-read the whole surrounding unit and grep for references to anything you removed.
- **A contract change** (a renamed symbol, an altered signature, a tightened validator, a moved output stream) is only half-done at the line you edited: it ripples to every dependent caller, fixture, and assertion. Grep for the old shape — a dependent that still compiles can still be semantically stale.
- **A new error path or fallback** can swallow the very failure it was added to surface. Confirm it leaves a specific, actionable account and never defaults an error into a success-shaped value.
- **A new guard** must accept no more than its downstream consumer — see *Share the Contract* below.
- **A fix to the *cited* instance is only half the fix when the same defect class recurs elsewhere.** A finding names one site, but the shape you just fixed — an unguarded assignment, an untested selection/branch arm, a missing null-check, a stale comment, a re-derived validator — usually repeats across sibling arms in the same function, coupled mirror sites, and parallel call sites. Before claiming done, grep the file (and every mirror/coupled site) for the pattern you just corrected and fix **every** instance in the same change. Fixing only the line the reviewer happened to cite while an identical sibling sits two arms away ships the same defect straight back for the next pass to re-raise — and the next reviewer, staring at the exact region, is the one most likely to miss it too. Treat the cited instance as a *sample of a class*, not the whole of it.

The reason to do this *now*, before claiming done, is cost: a defect you catch in your own fix delta costs nothing, one that reaches the next review pass costs a whole iteration, and one that slips the pass ships. Don't lean on a later review — or on an automated fix-delta gate, if your loop has one — to find a defect your fix introduced. Write it right the first time.

## Share the Contract: Parse, Don't Validate

When a fix adds a guard or validator protecting a **downstream consumer** (a parser, a `strptime`, a JSON decode, a type-narrowing op), **prefer using that consumer as the guard itself** rather than writing a separate validator that *approximates* the consumer's contract.

```
IF a fix needs to guard input before a downstream operation:
  prefer:  try <the_consumer_operation> catch  → reject on failure
  avoid:   a separate regex / shape check that RE-DERIVES the consumer's contract
```

**Why:** a separate validator's accepted-input set is almost never an exact match for the consumer's — it is usually a **superset**, so inputs the validator waves through still break the consumer. This is the `unverified-assumption` / #62/#98 bug class (see CLAUDE.md, *"Adding a guard, predicate, or coverage-invariant…"*): a guard whose comparand can be absent, or whose accepted set is wider than its consumer's contract, **fails open exactly where it claims to fail closed**.

**Worked example (PR #153):** a fix guarding a `strptime` call shipped first a `type == "string"` check, then a date-shape regex — each a *superset* of `strptime`'s real contract, each surviving its own self-review. The guard that worked was `try strptime catch`: it shares the consumer's contract by construction, so the accepted-input sets are identical and cannot drift.

When you apply a reviewer's "add a guard here" feedback, reach for the consumer's own operation first. If your review loop runs a fix-delta check, it verifies exactly this — the guard's accepted-input set must be a subset of its consumer's contract — so a re-derived validator gets caught there; write it right the first time anyway.

## The Bottom Line

**External feedback = suggestions to evaluate, not orders to follow.**

Verify. Question. Then implement.

No performative agreement. Technical rigor always.
