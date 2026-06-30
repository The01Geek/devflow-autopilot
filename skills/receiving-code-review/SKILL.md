---
name: receiving-code-review
description: Use when receiving code review feedback, before implementing suggestions, especially if feedback seems unclear or technically questionable - requires technical rigor and verification, not performative agreement or blind implementation
---

# Code Review Reception

**Consumer prompt extension (load first).** Before doing this skill's work, load any consumer-supplied prompt extension for this skill and honor it. From the repo root, run:

```bash
${CLAUDE_SKILL_DIR}/../../scripts/load-prompt-extension.sh receiving-code-review
```

If the helper exits non-zero, a consumer extension exists but could not be loaded — surface its stderr message and do not silently proceed as if none existed. If it exits 0 and prints text, treat that text as additional instructions appended to the end of this skill's own prompt for this run — it is upgrade-safe, consumer-owned customization committed under `.devflow/prompt-extensions/`. If it exits 0 and prints nothing, proceed unchanged.

**DevFlow context.** This skill is vendored verbatim from `superpowers`, where its examples address a "human partner" you converse with and "report to." Inside DevFlow's *autonomous* `/devflow:review-and-fix` fix loop there is no interactive human in the turn: read every "your human partner" / "report to me" framing below as the loop's own escalation channels — the deferrals manifest, the pushback/decision tracking recorded in the workpad, and the PR/issue trail a human reviews later. The technical-rigor principle (verify before implementing, push back when wrong) is identical; only the audience for the pushback differs.

## Overview

Code review requires technical evaluation, not emotional performance.

**Core principle:** Verify before implementing. Ask before assuming. Technical correctness over social comfort.

## The Response Pattern

```
WHEN receiving code review feedback:

1. READ: Complete feedback without reacting
2. UNDERSTAND: Restate requirement in own words (or ask)
3. VERIFY: Check against codebase reality
4. EVALUATE: Technically sound for THIS codebase?
5. RESPOND: Technical acknowledgment or reasoned pushback
6. IMPLEMENT: One item at a time, test each
7. RECORD DEFERRALS: For every finding you did NOT fix, write a durable trace (WHAT/WHY/revisit-condition) before claiming done — see Record Every Deferral
8. VERIFY BEFORE DONE: Review diff against addressed findings + run test suite — only then claim completion
```

## Verification Gate (Step 8)

**Iron Law: NO COMPLETION CLAIMS WITHOUT FRESH VERIFICATION EVIDENCE**

Before declaring the review findings addressed:
1. Review the diff of your changes against the addressed findings. For each fix, verify the fix is correct for *all* inputs and conditions — not only the case the reviewer described. Fixing one problem while introducing a new inaccuracy is a common failure mode the test suite may not catch (e.g. a breadcrumb that fires on `|| VAR=""` emptiness rephrased to say "failed", implying a non-zero exit, missing the asymmetric-empty case).
2. Run the project's test suite. Attempt the direct/local invocation first; restrict the CI fallback to a genuine sandbox or permission denial — never when the suite runs but fails. When using the CI fallback, actively wait to observe CI go green (submitting a push is not the same as observing green); do not claim completion until CI confirms green. Record the local-skip reason as an auditable note.
3. Only after both pass, claim completion.

This gate applies in both interactive sessions and the autonomous `/devflow:review-and-fix` fix loop. In the loop, the fix step runs tests and the review engine re-runs each iteration to re-check whether every finding is resolved — no additional step 8 invocation is needed at the APPROVE claim.

## Stop When the Verdict Is Already Non-Blocking

A review engine that re-runs after every edit is *exhaustive*: each pass surfaces a fresh batch of advisory notes. That is the engine working, not a regression — expecting an already-clean run to produce zero new notes is the mistake that puts the loop on an advisory treadmill, where every edit spawns the next batch and nothing ever converges.

Once the verdict is already non-blocking (an APPROVE, or any approve-with-notes verdict), the bar for re-opening the diff changes:

- **Re-open only for** a Critical / blocking finding, or a demonstrable correctness defect (one that cites a concrete failing input). These still get fixed immediately.
- **Everything else is recorded or deferred** (see Record Every Deferral below), not implemented. A Suggestion- or advisory-level note on an already-passing verdict does not, by itself, re-open the diff.
- **Bound any advisory re-open to a concrete, pre-agreed set.** If advisory notes *are* worth one more pass, name the specific bounded set of them before you start — never "address all the notes," which guarantees the next run produces a new batch and the loop never settles.

Expect the next review to produce new advisory notes after your edit. Treat that as the engine working as designed, not a signal to keep re-opening the diff.

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

IF suggestion seems wrong:
  Push back with technical reasoning

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

## Share the Contract: Parse, Don't Validate

When a fix adds a guard or validator protecting a **downstream consumer** (a parser, a `strptime`, a JSON decode, a type-narrowing op), **prefer using that consumer as the guard itself** rather than writing a separate validator that *approximates* the consumer's contract.

```
IF a fix needs to guard input before a downstream operation:
  prefer:  try <the_consumer_operation> catch  → reject on failure
  avoid:   a separate regex / shape check that RE-DERIVES the consumer's contract
```

**Why:** a separate validator's accepted-input set is almost never an exact match for the consumer's — it is usually a **superset**, so inputs the validator waves through still break the consumer. This is the `unverified-assumption` / #62/#98 bug class (see CLAUDE.md, *"Adding a guard, predicate, or coverage-invariant…"*): a guard whose comparand can be absent, or whose accepted set is wider than its consumer's contract, **fails open exactly where it claims to fail closed**.

**Worked example (PR #153):** a fix guarding a `strptime` call shipped first a `type == "string"` check, then a date-shape regex — each a *superset* of `strptime`'s real contract, each surviving its own self-review. The guard that worked was `try strptime catch`: it shares the consumer's contract by construction, so the accepted-input sets are identical and cannot drift.

When you apply a reviewer's "add a guard here" feedback, reach for the consumer's own operation first. `/devflow:review-and-fix`'s Step 3.5 fix-delta gate verifies exactly this (the guard's accepted-input set must be a subset of its consumer's contract), so a re-derived validator will be caught there — write it right the first time.

## The Bottom Line

**External feedback = suggestions to evaluate, not orders to follow.**

Verify. Question. Then implement.

No performative agreement. Technical rigor always.
