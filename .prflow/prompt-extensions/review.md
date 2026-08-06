# DevFlow repo — operative policy for `/prflow:review`

This repository is the DevFlow plugin itself. The base `/prflow:review` engine gates stand
unchanged — this extension **adds** one repo-specific review-gate criterion (the prompt-surface
edit routing evidence gate) that the standalone review must enforce. It is the byte-identical
twin of the same criterion in `.prflow/prompt-extensions/review-and-fix.md`; each skill loads
only its own extension name, so the criterion ships as two pinned-identical copies rather than
one shared file. Edit both copies in the same change.

## Wording-only pin review policy

A wording-only pin is a test whose protected literal can change without changing executable
behavior and without breaking a machine-consumed contract. Flag every newly added wording-only,
secondary-prose, documentation-presence, advisory-heading, or comment-presence pin as an
**Important** finding, whether it uses a pin helper or a raw text-presence assertion. A
`# structural-pin-ok:` comment does not make prose executable.

An operative prompt regression instead uses an ordinary executable test over the
rendered or consumed prompt and demonstrates that test going RED when the behavior
breaks. A new static presence pin is valid only with
the exact declaration `# structural-pin-ok: <category> -- <rationale>`, a nonempty rationale,
and one category from this closed set: `helper-contract`, `schema-config-vocabulary`,
`security-credential-boundary`, `machine-sentinel-provenance`,
`routing-dispatch-contract`, `lifecycle-state-transition`,
`generated-artifact-identity`, `cross-file-phase-contract`.

## This repository's declaration markers (limb-one input)

When applying the review engine's Phase 4.1.5 behavior-inertness limb one, this repository's
own tool-read declaration markers are `# structural-pin-ok:`, `# raw-guard-ok:`,
`# tree-walk-ok:`, `# argjson-ok:`, and `# pruned-path-ok:`. Each is parsed by a lint under
`lib/test/` to decide whether that check passes, so prose carrying one is **not** inert.
Keep this list here rather than in the shared engine: the engine states the governing
property, and each repository states its own marker set in its own review prompt extension.

## `$PR_BASE_BRANCH` naming (this repository's reason)

Phase 0.2 tells the engine to keep the exact `$PR_BASE_BRANCH` name because "a project's own
desk-time check may forbid" the bare `BASE_REF` spelling. In this repository that check is the
`#424` `grep -c` pin in `lib/test/run.sh`, mirroring `lib/fetch-pr-context.sh`; renaming the
variable to `$BASE_REF` turns the suite RED.

## Prompt-surface edit routing evidence gate

DevFlow-repo policy: a reviewed diff that touches a **prompt-surface** file must carry evidence
that its edit went through the `superpowers:writing-skills` RED/GREEN discipline (see
`.prflow/prompt-extensions/implement.md`'s "Prompt-surface edit routing" rule). This gate is
the review-time backstop for that routing — flag a missing discharge as at least **Important**.

**Trigger.** This gate applies only when the reviewed diff touches a path matching one of the
trigger globs: `skills/*/SKILL.md`, `skills/implement/phases/*.md`, `skills/implement/references/*.md`, `skills/review/phases/*.md`, `skills/review-and-fix/references/*.md`, `.prflow/prompt-extensions/*.md`.
A diff touching none of them draws no finding.

**Enforcement surfaces.** The gate is enforced on: an implement run's **Phase 3** (which holds
its own issue number), a **`/prflow:review-and-fix` run given a PR**, and **PR-mode standalone
`/prflow:review`**. A no-PR, no-issue **current-branch** run — standalone review's branch mode
and review-and-fix's current-branch mode alike — is **outside the gate's scope** (there is no
issue workpad or PR body to read), so the gate is a no-op there.

**Discharge arms, checked in order** when the reviewed diff touches any trigger glob:

1. The **linked issue** — in an in-run enforcement (implement Phase 3) that is the run's own
   issue; in PR-mode that is the PR's `closingIssuesReferences` — carries a
   `<!-- prflow:workpad -->` comment — or one carrying the superseded `<!-- devflow:workpad -->`
   spelling, since issue #1003 renamed the marker namespace and rewrote no existing body — whose
   body **contains** the marker literal
   `Writing-skills evidence:`. Fetch the issue's comments through the granted `gh` read path (the
   workpad lives on the linked issue, not the PR thread — the established `lib/fetch-pr-context.sh`
   contract; resolve `closingIssuesReferences` first, then fetch that issue's comments).
2. Otherwise, the **PR description** **contains** the marker literal `Writing-skills evidence:` —
   the discharge surface for interactive/human PRs and for a linked issue that has no workpad.

A discharge-surface read that **fails or cannot be resolved** — a `gh` comment-fetch error
(network/auth/rate-limit), or an unresolvable/empty `closingIssuesReferences` — reads as
*marker-absent on that surface*, **never** as *checked-and-clean*; the gate fails toward the
FAIL finding, matching `implement.md`'s repair-arm read-failure handling. When **no** checked
surface can be confirmed to contain the marker — whether because it was genuinely absent or
because the read could not be established — the review reports a **FAIL** finding naming this
rule (fail **closed** — an absent, malformed, or misspelled marker, and an unestablished read,
all read as absent).

**What the gate checks — shape, not mere presence.** A marker found on either surface discharges
the gate only when it carries all four slots the `implement.md` evidence contract names —
`skill-loaded`, `guidance-applied`, `pressure-scenario`, `micro-tests` — each with an explicit
`=yes` or `=no`. Read the four dispositions and report them in the review.

**A slot whose disposition is absent is undischarged, never compliant.** Silence about a slot is
an unestablished measurement, not a `no`; this repo's *unknown is not zero* rule forbids
collapsing it onto either value. When a slot is missing, or carries a value outside `yes`/`no`,
raise the same **FAIL** finding this rule already carries and list the slots at issue. The remedy
is to restate the marker with those dispositions, **not** to perform the step — a restatement
recording `pressure-scenario=no` with its reason discharges the gate in full.

**A `no` never draws a finding on its own.** A marker whose four dispositions are all recorded is
discharged whatever they say. The gate reads them so a reader can weigh whether a step suited the
edit; it never requires the subagent pressure-scenario cycle, whose expected disposition on a
small factual correction to prose is `no`.

## Verification-evidence marker advisory (non-blocking)

DevFlow-repo policy: a second marker gate on the **same shared review-engine surface** as the `Writing-skills evidence:` gate above — the gate that already reads the linked issue's workpad and the PR description. It adds a **non-blocking advisory** for the `Verification evidence:` marker that **every tier maintaining a workpad** records — `/prflow:implement` (cloud and local/interactive, since issue #1249 extended the obligation to the cloud tier), `/prflow:review-and-fix`, and direct-reception passes (per `.prflow/prompt-extensions/implement.md`, `review-and-fix.md`, and `receiving-code-review.md`). Unlike the `Writing-skills evidence:` gate, this clause is **advisory (non-blocking)**: it never raises the review verdict to a FAIL/REJECT on its own — it only informs the reader that a completion/PR-ready claim was made with no captured verification run.

**Input population (stated explicitly).** The clause reads the two durable per-PR surfaces the `Verification evidence:` marker is recorded on — the **linked issue's workpad** and the **PR description** — the same surfaces the `Writing-skills evidence:` gate already fetches (the workpad via `lib/fetch-pr-context.sh` from the linked issue thread; no new fetch channel is required). The marker is recorded on **every tier that maintains a workpad** (issue #1249 extended it from local/interactive to cloud `/prflow:implement`, whose in-env verification under issue #405 now records it too), so the clause checks **every** PR carrying a completion/PR-ready claim rather than only local/interactive ones. Because per-launch completeness is not machine-checkable — no consumer can know how many launches a run performed — the clause can only observe that **at least one** record is present, never that every launch was recorded.

**Tier discriminator (per PR).** Classify from the workpad `## Progress` section: a workpad carrying any `<!-- prflow:checkpoint gha:… -->` row — or the superseded `<!-- devflow:checkpoint gha:… -->` spelling, which a pre-rename run stamped — is a **cloud** run (those checkpoints are stamped cloud-only — `skills/implement/phases/phase-1-setup.md`, `skills/implement/SKILL.md`); a workpad with no such row is a **local/interactive** run. Since issue #1249 the clause acts on **both** classifications; it records the classification in the finding it emits so a reader knows which tier was expected to record the marker, but no longer uses it to gate whether it acts.

**Behavior:**

1. On **any** PR carrying a completion/PR-ready claim — cloud-classified or local/interactive alike — the clause checks the workpad and the PR description for the `Verification evidence:` marker literal.
2. When the marker is present on either surface the clause is silent. When it is absent from both surfaces the review emits one advisory (non-blocking) finding naming the missing `Verification evidence:` marker and the tier classification the checkpoint discriminator assigned. The advisory never raises the verdict to a FAIL/REJECT by itself.

**Covered population.** A **cloud or local** implement run's workpad, a **`/prflow:review-and-fix` run given a PR**, and a **direct-reception** marker recorded in the **PR description**. A local **current-branch** run with no PR and no linked issue is **out of scope** — it leaves no durable surface (workpad or PR body) for the gate to read, the same case the `Writing-skills evidence:` gate scopes out.

**Accepted residual.** The `gha:` checkpoint is best-effort and fires only when the workpad carries a canonical `## Progress` section, so a cloud run on a non-canonical workpad writes no checkpoint and is classified local/interactive. Issue #1347 narrowed that population: an **absent** `## Progress` is now repaired by `--checkpoint` itself, so such a run does write its checkpoint and classifies correctly; the residual survives only for a **duplicate** `## Progress` or an empty body, which still fail closed. Since the clause now acts on both classifications (issue #1249), that only mislabels the tier named in the finding — it no longer changes whether the advisory fires. Because the finding is non-blocking, this is accepted rather than guarded.
