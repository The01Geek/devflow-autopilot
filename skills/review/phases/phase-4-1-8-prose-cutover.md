<!-- devflow:review-ref phase=4.1.8 file=skills/review/phases/phase-4-1-8-prose-cutover.md start -->
### 4.1.8 Prompt-mass and prose-cutover gate (repo-policy-conditioned)

Run this gate only when the reviewed repository's `.devflow/prompt-extensions/implement.md`
contains the literal heading `## Prose cutover`; without that policy source, the gate is
inert. This conditioning is the consumer-safety boundary: the Review engine is vendored, but
the repo-specific census, baseline, and template are not.

Use the cached PR diff and changed-file status already held by the engine. Inspect changes to
`lib/test/prompt-mass-baseline.json` and only `docs/cutovers/*.md` files **added by this diff**.
A pre-existing artifact discharges nothing. A malformed artifact also counts as absent even
when another check did not run: require `schema: 1`, exactly one recognized `kind:`, a
non-empty body, and every heading that schema 1 requires in the extension template. Cross-check
the files named by the added artifacts against every mandatory-class baseline row the diff
moves; an unnamed moved row or a named file that does not match the movement makes the
artifact incomplete and drives REJECT.

**Sole tested owner means all five conditions hold, per consuming path:**

1. Every tier and supported host family that consumed the prose now invokes the helper.
2. Tests drive every helper branch and any selection's arm order.
3. Every tier that invokes the helper grants it, with matcher-probe evidence for a newly
   relied-on command shape.
4. A cutover crossing the `install.sh` / `devflow_version` vendoring boundary ships both
   halves together and documents their upgrade coupling.
5. Helper-behavior tests absorbing removed prose pins carry planted-defect mutation evidence.

Ownership is decided separately for each consuming path. If any path still consumes the
decision-owning prose, that prose is not superseded. Relocating the prose is not removal; its
owner survives at the destination.

FAIL an engine-surface review on any applicable arm below; each arm is discharged only by
the listed artifact kind(s):

- **Incoherent cutover:** a well-formed `kind: cutover` artifact was added, but the diff leaves
  the claimed superseded mandatory prose, branch/enum mirrors, or obsolete pins in place.
- **Unjustified reduction:** at least one mandatory-class row is lowered or removed without
  an added, well-formed `kind: cutover`, `trim`, or `relocate` artifact covering that row.
- **Unjustified growth:** at least one mandatory-class row is raised or added without an
  added, well-formed `kind: growth` artifact covering that row; `kind: cutover` also
  discharges growth when the same diff lowers at least one covered mandatory row.

One carve-out applies to the reduction and growth arms: a removed/added row pair whose
backing file the PR diff itself reports as a rename is a relocation and triggers neither arm.
Never infer a rename from equal byte values or author prose. A rename below git's similarity
threshold appears as delete-plus-add and therefore needs a `kind: relocate` artifact.

The mechanical residual is explicit: adding a helper while leaving the superseded prose
byte-for-byte untouched moves no baseline row, so neither movement arm fires. Judge that
keep-both shape against the same-change cutover rule; it is not mechanically cleared merely
because the census is exact.
<!-- devflow:review-ref phase=4.1.8 file=skills/review/phases/phase-4-1-8-prose-cutover.md end -->
