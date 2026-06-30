# DevFlow repo — operative policy for `/devflow:receiving-code-review`

This repository is the DevFlow plugin itself, and its review findings frequently
concern the engine prose in `skills/` and the helpers in `scripts/`/`lib/`. The base
skill's technical-rigor discipline (verify before implementing, push back when wrong)
stands unchanged; this extension adds one repo-specific VERIFY step that a prior run
got wrong on PR #190.

## Re-read the live issue spec — including any Addendum — before triaging findings

When the feedback concerns a PR that closes a GitHub issue, **re-read the issue body
fresh** (`gh issue view <n> --json body --jq '.body'`) as the FIRST step of VERIFY,
before you evaluate or implement any finding. Do not rely on the issue understanding you
(or an earlier run) started with — an issue can be **amended in place after the PR was
opened**, and a later section can **supersede** an earlier one.

Specifically scan for an `## Addendum`, a "supersedes"/"superseded"/"replaces" marker, or
a dated post-implementation note, and treat the **latest superseding requirement as
authoritative** over both the shipped code and the review findings. The current spec
outranks the findings triage:

- If the issue now mandates a design the PR did not implement (a new file, a deterministic
  helper, a mandated verification strategy), that supersession is the finding to act on —
  implement the mandated design, do not merely harden the superseded one.
- **Never make a superseded approach more robust.** On PR #190 a receiving-review pass
  hardened the issue's *original* LLM-prose extraction with more guards and pins while an
  Addendum had already replaced it with a deterministic helper + fixture tests. Every
  added guard was wasted work on a design the issue had retired, and the standalone cloud
  review (whose Issue Compliance re-reads the issue) was left to catch it as a REJECT.

When the standalone cloud `/devflow:review` verdict is itself the feedback, read its
**Issue Compliance** section as the spec-of-record signal: a checklist FAIL citing a
superseding requirement is not one finding among many — it reframes what "addressing the
review" means for the whole pass.
