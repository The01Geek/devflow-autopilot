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
trigger globs: `skills/*/SKILL.md`, `skills/implement/phases/*.md`, `.devflow/prompt-extensions/*.md`.
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

When **no** checked surface contains the marker, the review reports a **FAIL** finding naming
this rule (fail **closed** — an absent, malformed, or misspelled marker all read as absent).
