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

## Config-derivation fixes sweep the full six-shape adversarial matrix, not just the reviewer-cited row

When a finding you are fixing touches **how a config value is read, derived, or defaulted** — a
`config-get.sh` read, an inline `jq` extraction over `.devflow/config.json`, an `// default` /
`// true`-style fallback, an enum validation, or any other code that turns a raw config value into a
decision — the **same fix** sweeps the full CLAUDE.md six-shape adversarial matrix over that value:
`{object, array, scalar, valid-falsy (explicit false / 0 / empty string), missing, wrong-type}`.
Each shape is **tested in `lib/test/run.sh` in the same change** (exit-0 + a specific, not generic,
breadcrumb per shape; the **valid-falsy** row is load-bearing — a real `false` / `0` / `""` an
`// true` / `// default` extraction silently coerces to its truthy default is the documented
off-switch-that-never-worked defect, #312/#304). A shape that genuinely does not apply is recorded with a
**written reason** instead of a test — never silently skipped. Fixing **only** the reviewer-cited shape
row is **incomplete by policy**: the sibling rows are exactly the next run's predictable test-gap
findings (PR #451's third round existed almost solely to add the untested sibling arm of a
config-read fix), so sweeping the whole matrix in one fix is what stops the per-fix extra review
iteration. This is DevFlow-repo policy; the governing convention is CLAUDE.md's best-effort-parser
adversarial-matrix gotcha, and this section is its coupled mirror in
`.devflow/prompt-extensions/review-and-fix.md` — edit both in the same change. (#466)
