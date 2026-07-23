# DevFlow repo — operative policy for `/devflow:review`

This repository is the DevFlow plugin itself. The base `/devflow:review` engine gates stand
unchanged — this extension **adds** one repo-specific review-gate criterion (the prompt-surface
edit routing evidence gate) that the standalone review must enforce. It is the byte-identical
twin of the same criterion in `.devflow/prompt-extensions/review-and-fix.md`; each skill loads
only its own extension name, so the criterion ships as two pinned-identical copies rather than
one shared file. Edit both copies in the same change.

## Prompt-surface edit routing evidence gate

DevFlow-repo policy: a reviewed diff that touches a **prompt-surface** file must carry evidence
that its edit went through the `superpowers:writing-skills` RED/GREEN discipline (see
`.devflow/prompt-extensions/implement.md`'s "Prompt-surface edit routing" rule). This gate is
the review-time backstop for that routing — flag a missing discharge as at least **Important**.

**Trigger.** This gate applies only when the reviewed diff touches a path matching one of the
trigger globs: `skills/*/SKILL.md`, `skills/implement/phases/*.md`, `skills/review/phases/*.md`, `skills/review-and-fix/references/*.md`, `.devflow/prompt-extensions/*.md`.
A diff touching none of them draws no finding.

**Enforcement surfaces.** The gate is enforced on: an implement run's **Phase 3** (which holds
its own issue number), a **`/devflow:review-and-fix` run given a PR**, and **PR-mode standalone
`/devflow:review`**. A no-PR, no-issue **current-branch** run — standalone review's branch mode
and review-and-fix's current-branch mode alike — is **outside the gate's scope** (there is no
issue workpad or PR body to read), so the gate is a no-op there.

**Discharge arms, checked in order** when the reviewed diff touches any trigger glob:

1. The **linked issue** — in an in-run enforcement (implement Phase 3) that is the run's own
   issue; in PR-mode that is the PR's `closingIssuesReferences` — carries a
   `<!-- devflow:workpad -->` comment whose body **contains** the marker literal
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

## Verification-evidence marker advisory (tier-scoped, non-blocking)

DevFlow-repo policy: a second marker gate on the **same shared review-engine surface** as the `Writing-skills evidence:` gate above — the gate that already reads the linked issue's workpad and the PR description. It adds a **tier-scoped advisory** for the `Verification evidence:` marker that local/interactive `/devflow:implement`, `/devflow:review-and-fix`, and direct-reception passes record (per `.devflow/prompt-extensions/implement.md`, `review-and-fix.md`, and `receiving-code-review.md`). Unlike the `Writing-skills evidence:` gate, this clause is **advisory (non-blocking)**: it never raises the review verdict to a FAIL/REJECT on its own — it only informs the reader that a completion/PR-ready claim was made with no captured verification run.

**Input population (stated explicitly).** The clause reads the two durable per-PR surfaces the `Verification evidence:` marker is recorded on — the **linked issue's workpad** and the **PR description** — the same surfaces the `Writing-skills evidence:` gate already fetches (the workpad via `lib/fetch-pr-context.sh` from the linked issue thread; no new fetch channel is required). The marker is recorded on the **local/interactive tier only** (cloud runs verify in-env under issue #405 and carry no capture obligation), so the clause must classify each PR by tier and act only on local/interactive ones — otherwise it is a guard that reads as armed and can never fire.

**Tier discriminator (per PR).** Classify from the workpad `## Progress` section: a workpad carrying any `<!-- devflow:checkpoint gha:… -->` row is a **cloud** run (those checkpoints are stamped cloud-only — `skills/implement/phases/phase-1-setup.md`, `skills/implement/SKILL.md`); a workpad with no such row is a **local/interactive** run. The advisory clause acts only on the local/interactive classification.

**Behavior, by classification:**

1. On a cloud-classified PR (a workpad carrying `gha:` checkpoints) the clause is silent and emits no finding.
2. On a local/interactive-classified PR that carries a completion/PR-ready claim, the clause checks the workpad and the PR description for the `Verification evidence:` marker literal. When the marker is present on either surface the clause is silent. When the marker is absent from both surfaces the review emits one advisory (non-blocking) finding naming the missing `Verification evidence:` marker and the local/interactive tier classification that selected the check. The advisory never raises the verdict to a FAIL/REJECT by itself.

**Covered population.** A local implement **Phase-3 inline review**, a local/interactive **`/devflow:review-and-fix` run given a PR**, and a **direct-reception** marker recorded in the **PR description**. A local **current-branch** run with no PR and no linked issue is **out of scope** — it leaves no durable surface (workpad or PR body) for the gate to read, the same case the `Writing-skills evidence:` gate scopes out.

**Accepted residual.** The `gha:` checkpoint is best-effort and fires only when the workpad carries a canonical `## Progress` section, so a cloud run on a legacy workpad lacking that section writes no checkpoint and is therefore classified local/interactive, yielding a false advisory. Because the finding is non-blocking, this misclassification is low-cost and is accepted rather than guarded.
