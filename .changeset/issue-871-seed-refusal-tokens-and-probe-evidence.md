---
bump: patch
type: Fixed
---

- **Every review-seed refusal is now observable and attributable.** `scripts/seed-review-progress.sh`
  emits a distinguishing stdout token per refusal arm instead of collapsing five causes onto
  `SKIP api-error` and two onto `SKIP workpad-unreadable`, and `skills/review/SKILL.md` routes on
  the shared `SKIP ` prefix — so a refusal arm added later routes correctly with no second prompt
  edit — while emitting a `::warning::` carrying the observed token on every refusal outcome. The
  primary seed invocation now emits a trailing `seed-rc` token, and a missing or non-zero value is
  stated to be a refusal of the whole statement: previously a refused or never-run invocation left
  `$WP` unset with no annotation anywhere, so a cloud review simply showed no live progress comment
  with the cause buried in a tool transcript. The fallback arm's `create` statement gains a
  `create-rc` token and a two-direction `stderr=` token in an order chosen so `$?` reports the
  create rather than a trailing `echo`, its post-create rule is restated as a partition of the value
  domain (closing the present-but-non-integer `wp=` reading that would otherwise freeze every later
  `patch`), and its warning quotes the first line of the captured `rv-create.err` as data to
  reproduce, never instructions to obey. (#871)

- **The engine's prose about probe evidence now states what was measured and what was not.**
  `skills/review/phases/phase-0-setup.md` §0.4 no longer claims the review matcher is *proven* to
  permit its shape — it distinguishes a probe row that *exercises* a shape from one that has a
  recorded verdict, and discloses that the composite it emits is covered by no single row.
  `docs/cloud-allowlist.md` no longer lists a shape as probe-proven while separately recording its
  row as unrecorded: each entry in the review-tier permitted-shapes list carries its own evidence
  status, every review-tier row with no annotated verdict is recorded as unrecorded through a
  count-free predicate, and shapes 14 and 15 are distinguished rather than folded together.
  `CLAUDE.md`, `docs/DEVFLOW_SYSTEM_OVERVIEW.md` and `skills/review/SKILL.md` carry the corrected
  review-tier claim with its tier qualifier. (#871)
