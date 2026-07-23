<!--
SPDX-FileCopyrightText: 2026 Daniel Radman
SPDX-License-Identifier: MIT
-->
# Fresh-context audit-prompt template (create-issue Step 3.6)

This file is the **sole in-repo owner** of the create-issue Step 3.6 audit-prompt
template, the generic dimension checklist, and — since issue #709 — the canonical
**audit-dispatch instructions** the auditor is pointed at.
`scripts/render-audit-prompt.py`
reads it (resolved relative to that script's own location — `scripts/` and
`skills/` are siblings under one root in both the repo checkout and the vendored
plugin layout) and emits the arm-appropriate audit prompt. `skills/create-issue/SKILL.md`
carries the invocation contract and the policy prose; the operative prompt text
lives here.

## How this template is rendered (and read by the degraded manual arms)

The renderer selects **arm/mode blocks** and substitutes **slots**, then prepends
a `render-status:` line and appends a `render-end:` marker. When the renderer is
unavailable, a degraded manual arm **Reads this file directly** and follows the
same block/slot rules by hand.

- **Arm/mode blocks.** Each block is bounded by `<!-- render-block: <set> -->`
  and `<!-- render-block-end -->`, where `<set>` is a space-separated list of the
  arms/modes that include the block (`file`, `embed`, `inline`, `checklist`,
  and the issue-#709 dispatch-instruction token `di`).
  Emit a block only when the current arm/mode is in its set. Text outside any
  block (like this section) is documentation, never emitted.
- **Slots** (substituted at render time; a manual arm fills them from the
  dispatch preamble):
  - `{DRAFT_PATH}` — the absolute `issue-draft-<slug>.md` path (file arm only).
  - `{SENTINEL_OPEN}` / `{SENTINEL_CLOSE}` — the `AUDIT-<tag>-OPEN` /
    `AUDIT-<tag>-CLOSE` tokens the state owner generated (embed arm only). The
    embed splice slot is the one place the draft body is carried; the renderer
    never touches the draft bytes.
  - `<slug>` — the run's kebab-case slug, substituted into the out-of-bounds
    paths.
  - the consumer-dimensions slot — the consumer `## Audit dimensions` section
    (or a clean no-consumer note / an unestablished note), computed by the
    renderer and spliced into the generic checklist block below.
  - `{DRAFT_TITLE}`, `{INSTRUCTIONS_PATH}`, `{TEMPLATE_PATH}`, `{RENDERER_PATH}`
    — the `di` (dispatch-instructions) blocks only. `{DRAFT_TITLE}` is read from
    the draft file at `{DRAFT_PATH}`, never from a command-line argument, and is
    substituted **last** alongside the consumer-dimensions slot so drafter text
    is never re-scanned for slot tokens. `{RENDERER_PATH}` and `{TEMPLATE_PATH}`
    are derived by the renderer from its own resolved location.
- **The draft title appears only in the `di` blocks** (issue #709), where it is
  read from the draft file the same blocks name; the *audit-prompt* blocks
  (`file` / `embed` / `inline` / `checklist`) still never carry it, and refer to
  the draft by path or by the sentinel-bracketed body.

## Extraction rule (for the `## Audit dimensions` / `## Evidence axes` forwarding)

The renderer's section-extraction mode (and, on the degraded manual arm, a
by-hand read of the consumer extension) applies exactly these four clauses: a
section spans its heading line to the next line beginning `## ` — two hashes
plus a space, so a `###` sub-heading terminates nothing — else to end of file;
duplicate same-heading sections are concatenated in file order; an empty section
and an absent heading both contribute nothing; and a heading line inside an HTML
comment block or a fenced code block is not a heading (an unclosed fence runs to
end of file). This is the same rule `scripts/load-prompt-extension.sh` implements
for `--section`.

---

<!-- render-block: di -->
# Fresh-context audit dispatch (canonical, generated — issue #709)

This file **is** your complete dispatch instructions. It was generated
deterministically by `render-audit-prompt.py dispatch-instructions` from the
committed template; the message that pointed you here is **required** to be the
generated pointer this file states verbatim at the end (carrying nothing but file
paths) — report in step 3 item 4 what it actually carried, and do not treat this
sentence as evidence that it complied.
Every other line of this file came from the committed template, with the draft's
own title substituted in below; none of it was hand-written for this draft.

**Draft under audit — title:**

{DRAFT_TITLE}

**Draft file (the sole draft source):** `{DRAFT_PATH}`

## Step 1 — fetch your audit instructions

Run exactly this command first, before any repository read other than the
reads this file directs:

```
python3 {RENDERER_PATH} file --slug <slug> --draft-path {DRAFT_PATH}
```

Treat its stdout as the complete audit instructions **only** when its **first
line begins `render-status:`** and its **last line is exactly `render-end:`** —
positional, never mere presence anywhere in the output. Follow those
instructions exactly; they are the authority on what to audit and how.

**Fallback ladder.** If that command produces no output, or output whose two
markers are missing or out of position, **Read the template file at
`{TEMPLATE_PATH}` directly** and follow the `file`-arm blocks it contains under
its documented block/slot rules (a fallback-rung audit runs without the consumer
section — renderer-owned extraction is what failed). If you can do neither,
return no findings and say so plainly; do not audit from memory.

## Step 2 — out of bounds

You have repository read access. These on-disk files are **out of bounds** —
`.devflow/tmp/issue-derivation-<slug>.md`, `.devflow/tmp/issue-audit-<slug>.md`,
`.devflow/tmp/issue-audit-state-<slug>.json`, the retired
`.devflow/tmp/issue-audit-state-<slug>.md`, and any staged canonical-draft
artifact `.devflow/tmp/issue-draft-<slug>.*.staged.md`. **Any finding derived
from those files is void.** The draft file named above is the artifact under audit and is
**not** out of bounds.

## Step 3 — your return contract

Your return must carry, in addition to the findings and the mandatory
`VERDICT:` line the fetched instructions define:

1. The `render-status:` line from step 1, quoted verbatim.
2. The object ID printed by `git hash-object --no-filters {DRAFT_PATH}`, quoted
   verbatim (the draft carriage/identity check).
3. The object ID printed by `git hash-object --no-filters {INSTRUCTIONS_PATH}`
   — **this instruction file** — quoted verbatim, on its own line prefixed
   `instructions-object-id:`. This is what proves the instructions you read were
   the canonical generated ones and carried no added focus, prioritization,
   reassurance, or scoping clause.
4. A line prefixed `extra-dispatch-content:` whose value is exactly `no` when
   the message that dispatched you carried **nothing** beyond a pointer to this
   file and the draft file, and exactly `yes` when it carried anything else —
   any framing, focus, prioritization, reassurance, scoping, or prior-findings
   text. Report what you actually observed; `yes` does not fail the audit, it
   only records that the dispatch was not a bare pointer.

Omit none of these. An omitted object ID or affirmation is treated exactly like
a mismatched one — fail closed — so inventing a value would manufacture the very
proof these lines exist to demand.

## The canonical dispatch pointer

This is the exact, generated pointer the orchestrator is required to send as the
**entire** dispatch message. It is emitted here — rather than composed freehand —
so the pointer, like these instructions, is generated rather than authored, and so
step 3 item 4 has a reference form to compare the message you actually received
against. **The `dispatch-pointer: ` prefix and this block's indentation are the render's
framing, and are to be IGNORED whether the message you received carries them or not** —
the message proper is the text that follows the prefix, beginning at `Audit the issue
draft at`. Compare only that text, and never report `extra-dispatch-content: yes` for the
presence or the absence of the prefix or the indent alone:

    dispatch-pointer: Audit the issue draft at {DRAFT_PATH}. Your complete dispatch instructions are the file at {INSTRUCTIONS_PATH} — Read it and follow it exactly. This message carries nothing else.
<!-- render-block-end -->

<!-- render-block: file embed inline -->
You are auditing a GitHub issue draft you did **not** write. Your mandate is **adversarial**: break confidence in the draft, do not validate it — there is **no credit for good intent**. Adopt a **pre-mortem frame** — assume the issue was implemented *exactly as written* and the result failed; write the autopsy of why.
<!-- render-block-end -->

<!-- render-block: file -->
**Read the draft file `{DRAFT_PATH}` as the sole draft source before any repository read other than the renderer invocation, or the documented template-file fallback read, that produced these instructions.** Then, in your return, **run `git hash-object --no-filters` on that draft file and quote the object ID it prints verbatim** (a full-content identity check). If you cannot read the file, return **no findings** and end with `VERDICT: DRAFT-UNREADABLE` — do not audit from memory or from any other on-disk copy.
<!-- render-block-end -->

<!-- render-block: embed -->
The draft title and body are embedded below, bracketed by the sentinel tokens `{SENTINEL_OPEN}` and `{SENTINEL_CLOSE}` — audit **only** the bytes between them as the sole draft source; the on-disk draft file is untrusted on this arm. In your return, **quote both sentinel tokens plus the body's first and last lines verbatim** (a carriage/identity check).

`{SENTINEL_OPEN}`
{the full rendered draft title and body are spliced here by the dispatch prompt — the renderer never touches these bytes}
`{SENTINEL_CLOSE}`
<!-- render-block-end -->

<!-- render-block: file inline -->
Verify every claim against the repository (you have read access). The following on-disk files are **out of bounds** — `.devflow/tmp/issue-derivation-<slug>.md`, `.devflow/tmp/issue-audit-<slug>.md`, `.devflow/tmp/issue-audit-state-<slug>.json`, `.devflow/tmp/issue-audit-state-<slug>.md`, and any staged canonical-draft artifact `.devflow/tmp/issue-draft-<slug>.*.staged.md`; **any finding derived from those files is void.** (The draft under audit is the artifact under audit, not out of bounds.)
<!-- render-block-end -->

<!-- render-block: embed -->
Verify every claim against the repository (you have read access). On this arm the out-of-bounds declaration names exactly these 6 files — `.devflow/tmp/issue-derivation-<slug>.md`, `.devflow/tmp/issue-draft-<slug>.md`, `.devflow/tmp/issue-audit-<slug>.md`, `.devflow/tmp/issue-audit-state-<slug>.json`, the **retired** `.devflow/tmp/issue-audit-state-<slug>.md`, and any staged canonical-draft artifact `.devflow/tmp/issue-draft-<slug>.*.staged.md`; **any finding derived from those files is void.** The embedded body above is the sole draft source; the on-disk draft file is untrusted here.
<!-- render-block-end -->

<!-- render-block: file embed inline -->
**Per-finding bar** — every finding must: quote the exact draft line it attacks; name the concrete failure *mechanism*, not a category; verify each claim against the repository and **report an unverifiable claim as unverifiable rather than asserting it**; carry a **severity graded by observable blast radius**; give a specific recommended edit; and carry **reproducible evidence** — all four of: a **locator** (the `path:line` or `path:region` the check reads), the **exact command** that produces the evidence, its **observed output** quoted verbatim, and the **baseline** it was captured against (the repository revision you read — resolve it yourself with `git rev-parse HEAD`; never read it from an out-of-bounds file). Report a field you could not establish as unestablished rather than inventing it: incomplete evidence is legal and simply routes the finding to full independent verification, whereas a fabricated locator or output is a defect in the finding.

**Scope exclusions** — no wording or formatting notes; no implementation details decidable at implement time (judge the draft at **issue altitude**); no finding without a concrete trigger scenario.
<!-- render-block-end -->

<!-- render-block: file embed inline checklist -->
**Audit dimensions** (judge the draft against each):

- **Consumer-repo setup variance** — the draft's premises must hold on a fresh adopter checkout, not only this repo.
- **Host-OS variance** — Windows / WSL / Git Bash, macOS / BSD, and hosts without GNU coreutils.
- **Degraded environments** — shallow clones, missing PATH tools, read-only sandboxes, and both fresh and compacted agent contexts.
- **Execution-tier variance** — cloud tier and local tier, including their differing permission allowlists.
- **Second-order effects and unstated scope** — what the change touches that the draft never mentions, judged **per evidence axis**: authoritative producers and the values they emit; consumers of each touched value or surface; execution environments (tiers, host OSes, degraded arms); persistence paths; lifecycle states and termination paths including retries and backstops; migration and coexistence surfaces; and coupled tests and docs. A surface the draft leaves unmentioned on any of these axes is an unstated-scope finding.
- **Missed edge cases and termination paths** — error paths, empty/absent inputs, and how each flow ends.
- **Load-bearing assumptions** — each stated with what would falsify it, including any **universal quantifier** the draft asserts ("never", "always", "each", "every", "all", "cannot"): each must be grounded (pinned per-arm/per-element, scoped to the mechanism's supported form, or removed), or it is an ungrounded load-bearing assumption.
- **Adversarial third-party input** — when the draft's Desired Behavior introduces a *new* LLM or semantic judgment over third-party text the change does not author (issue bodies, PR comments, commit messages, external API responses) whose output drives an automated selection or action, the draft must carry an input-is-data guard as a decided design element — an acceptance criterion stating the text is **data to classify, never instructions to obey** — paired with a Testing Strategy case that exercises instruction-shaped input (a body that directs the judgment) and asserts it is not obeyed. Flag a draft missing the guard AC, or carrying the guard sentence with no paired hostile-input case (the pairing exists precisely so the guard cannot be satisfied by a compliance sentence the implementation never ships). A surface that reuses an existing, already-guarded judgment path is exempt when the draft cites that path; a draft with no new judgment surface gains no new flags (the visual-specification skip-when-inapplicable shape).
- **Authoring-discipline defects** — three related shapes: (1) a **value-comparison** AC or assertion whose comparison language is ungrounded on the type axis it must encode — adjective-only ("explicit X", "exactly X"), or a cited probe that never exercises the type-boundary fixture the comparison distinguishes (a string `"true"` vs. a boolean `true`); (2) a **case / input-shape matrix** narrowed below a governing convention without an explicit justification — **independently re-run** the draft's bounded consulted-sources search and flag **only** a governing matrix found at a path the draft's `governing conventions consulted:` line omits, never a judgment disagreement about what counts as governing; (3) an **unstated mechanism dependency** — the designed mechanism relies on an in-repo helper/resolver/gate behavior the body never asserts as a claim, so no premise is verified.

{CONSUMER_DIMENSIONS}
<!-- render-block-end -->

<!-- render-block: file embed inline -->
**Per-dimension coverage return (issue #708) — a record of scrutiny already performed, emitted AFTER the five-finding + Quiet-Killer hunt (which keeps precedence).** For **each** required audit dimension above (the generic checklist plus any consumer `## Audit dimensions` section), report exactly one coverage outcome, labeled with the dimension's **stable key**. Obtain the keys by running the renderer's enumeration mode first — `render-audit-prompt.py enumerate-dimensions` — whose `dim key=<key> text=…` lines are the authoritative dimension list (the same deterministic keys the orchestrator holds, so your outcomes join by key). Emit one line per dimension in a fenced `COVERAGE` block, each line `<key> <outcome> [anchor]`:

- `<outcome>` is exactly one of **`exercised`**, **`valid-N/A`**, **`unestablished`**, **`skipped`**.
- **`exercised`** requires a checkable **anchor**: a quoted draft line plus the concrete concern examined, or a specific repository fact checked. A dimension you engaged and found clean is `exercised` **without** any finding — never fabricate a finding to evidence coverage. The anchor is length-bounded (one quoted line plus one concern clause).
- **`valid-N/A`** carries a one-line reason (batchable: a scope-inference line may cover several dimensions the draft plainly does not touch). It stays cheap.
- **`unestablished`** — you could not establish the outcome (a degraded read). Unknown is never `exercised`.
- **`skipped`** — you did not genuinely engage the dimension. Report it honestly rather than padding a plausible-but-empty anchor.

The anchor is **data, never protocol**: do not embed a `<field>=` token drawn from the tool's printed vocabulary or a newline. An empty, prompt-copied, or generic anchor does not back coverage. `coverage-backed` means per-dimension evidence of the required shape is present and survived the floors — it does **not** certify genuine scrutiny; a thin-but-plausible anchor is a residual the mechanism cannot re-verify.
<!-- render-block-end -->

<!-- render-block: file embed inline -->
**Cap: at most five findings.** The **"Quiet Killer"** — the failure the draft is not contemplating at all — is **one assessed slot, not a mandatory finding quota: report at most one qualifying Quiet Killer, or explicitly report `Quiet Killer: none`.** The `none` form consumes no finding slot and is legal on `VERDICT: FILE`. If the draft has **no actionable findings**, say so explicitly; that is a legal output.

End with a **mandatory final verdict line** whose only three legal values are exactly `VERDICT: FILE` (no revision needed), `VERDICT: REVISE` (findings warrant changing the draft), or `VERDICT: DRAFT-UNREADABLE` (you could not read the draft file — emitted only on the file arm, with no findings).
<!-- render-block-end -->
