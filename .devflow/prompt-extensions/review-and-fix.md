# DevFlow repo — operative policy for `/devflow:review-and-fix`

This repository is the DevFlow plugin itself: its findings frequently concern the
engine prose in `skills/` and the best-effort shell/`jq`/Python helpers in
`scripts/`/`lib/`. The base skill's gates stand unchanged — this extension **sharpens**
(never supplants) the **fix-delta gate** (Step 0.9) and the **Step 2.6 shadow reviewer
prompts** with four repo-specific verification-discipline shapes — two fail-open guard
classes the issue-#247 dogfooding run reproduced at runtime (shapes 1–2), and two
vacuous-verification classes the PR #340 fix loop reproduced (shapes 3–4) — plus an
interpreter-faithful-probe rule (PR #340's R7). Flag an instance of any shape as at least
**Important** (a silent selection/output change, a vacuous test, or a re-derived guard
contract is a correctness defect), and require the fix to verify the *outcome*, not the
precondition.

> **Maintainer note (budget):** the shapes below retain principle/flag/fix, but their detailed
> `#247`/`PR #340` reproduction walkthroughs were trimmed for prompt budget (issue #530) to at
> most a one-line summary (some carry none). Full context: issue #247 / PR #340 history.

Template: [Prose cutover](implement.md#prose-cutover).

## Focused test modules accelerate fix iteration only

Before choosing a test, use finding context, test plan, or coverage map
(`lib/test/modules/coverage-map.json`) to identify a candidate module, then confirm its ID
in `scripts/workflow-flight-recorder-registry.json`. Explicitly record the selected ID and
use `bash lib/test/run-module.sh <module-id>` for the RED/GREEN loop. Selection is explicit:
consulting the coverage map counts (record the entry, confirm the ID).
Do not infer or automate changed-file-to-module routing. For **local review-and-fix contract iteration only**,
run exactly `bash lib/test/run-module.sh review-and-fix-contract`; if the `bash` wrapper is denied, use the runner path as leading token instead. When no module covers the fix, use
the full suite during iteration. Cloud-tier runs use `lib/test/run-module.sh <module-id>` (direct leading-token form) when the tier grants it and a registered module covers the fix; otherwise they use the already-permitted complete suite without requesting new permissions.

A focused result never discharges a review/fix gate. Before a commit, phase completion, push,
or completion claim, run `bash lib/test/run.sh` plus every lint gate required by `CLAUDE.md`
(using its documented classifier fallback when necessary). A nonempty skip tally is not clean.

## Guard-class shape 1 — existence-vs-sourceability (verify the outcome, not the precondition)

A guard that tests a file's **existence** and then treats a later **consumption** of that
file as guaranteed is fail-open: the file can exist yet be unreadable, corrupt, or fail to
parse/source, so the precondition passes while the outcome it stands in for never happens.

- **Flag:** any `[ -f <file> ] && . <file>` (or `[ -f x ] && source x`, `[ -e x ]` gating a
  later read/parse) where the guard's *intent* is "the thing the file provides is now
  available." `[ -f ]` proves the path exists — it proves nothing about whether sourcing
  succeeded or the symbol/function it defines is now callable.
- **Fix (verify the outcome):** assert the *consumed result* directly. For a sourced helper,
  check the function is defined after sourcing — `. <file> 2>/dev/null; type <fn> >/dev/null 2>&1 || { breadcrumb; fail-closed; }` — not that the file exists. For a parsed value, check the
  parse produced a usable value. Fail **closed** with a specific breadcrumb when the outcome
  check fails, never silently continue as if the sibling loaded.

## Guard-class shape 2 — tr-dependence (an external PATH tool whose absence silently changes output)

A value (a slug, a branch name, a path segment, a normalized identifier) derived by piping
through an external tool consulted on `PATH` — `tr`, `sed`, `awk`, `paste`, `jq` — degrades
**silently** on a host where that tool is missing or behaves differently: the pipeline still
runs, the value comes out wrong (empty, unnormalized, or truncated), and the wrong value then
selects the wrong directory / writes the wrong file / no-ops a gate, with no error.

- **Flag:** any selection- or output-determining value derived through such a tool where a
  failure of the tool (absent on `PATH`, a BSD/GNU behavioral difference, a locale effect)
  would silently change *which* thing is selected or *what* is emitted, rather than surfacing
  an error. Especially where the derived value keys a filesystem path or a comparison.
- **Fix:** either prove the tool is a hard, preflight-guaranteed prerequisite (and cite it), or
  make the failure observable — check the derived value is non-empty/well-formed before it is
  used to select or emit, and fail closed with a breadcrumb naming the tool if it is not. A
  value that is *only* correct when an un-guaranteed tool is present is an unverified boundary.
- **#247 reproduction:** a derived slug degrades on a `PATH` without `tr` and selects the wrong directory.

## Guard-class shape 3 — vacuous negative test (attribute the rejection, carry a positive control)

A negative test — one asserting that a bad input is *rejected* — passes while proving nothing when
the rejection comes from somewhere other than the guard it names. Two sub-shapes: the fixture trips
an **unrelated precondition** and the call fails before reaching the guard under test; or a **different
guard** rejects the input first (more than one guard can reject it), so an exit-code-and-no-output
assertion stays green even against a mutant that disables the very guard the test exists to kill.

- **Flag:** a negative test whose only assertions are the exit code and the absence of output/PATCH,
  on an input that more than one guard could reject — and no positive control on the same fixture
  proving the fixture is otherwise valid. The test names one guard but pins no signal that distinguishes
  it from a precondition or a sibling guard firing first.
- **Fix (attribute + control the outcome):** pin the **rejecting guard's own distinct signal** (its
  specific message/breadcrumb, e.g. `net-adds` absent with the offending pair named), not merely that
  the call failed — so the assertion fails if any *other* guard did the rejecting. And add a **positive
  control on the same fixture**: a companion assertion that the fixture is otherwise valid and the call
  would succeed but for the one property under test, so an unrelated precondition rejecting the fixture
  cannot masquerade as the rejection under test.
- **PR #340 cost this would have eliminated:** two vacuous tests and their follow-up findings.

## Guard-class shape 4 — re-derived consumer contract (write the guard as the operation it protects)

A guard written as a *separate predicate approximating* a downstream consumer's contract — instead of
using that consumer's own operation as the guard — accepts a **superset** of what the consumer accepts,
so inputs the guard waves through still break the consumer: it fails open exactly where it claims to
fail closed. The tell is a guard that inspects a *proxy* for the protected value (an argument string, a
subset of separators) rather than the value the consumer actually operates on.

- **Flag:** a new guard/predicate over a string or shape that hand-derives what a nearby parser,
  splitter, or narrowing op already decides — a regex/`in`-check/type-check standing in for a
  `strptime`, a `splitlines()`, a `_find_checkbox_row`, a JSON decode — especially when the correct
  idiom already exists elsewhere in the same file. Naming the protected operation *after* the predicate
  is written is itself the smell.
- **Fix (write the guard as the operation):** name the downstream operation the guard protects, in the
  code, before writing the predicate; then write the guard **as** that operation (share its contract by
  construction, so the accepted sets are identical and cannot drift). Before writing any new predicate
  over a string or shape, grep the file for an existing idiom doing the same job and reuse it.
- **PR #340 cost this would have eliminated:** the original guard defect and an extra review iteration.

## Probe rule — run interpreter- and environment-dependent probes under the real interpreter

When a fix or a review probes behavior that depends on the **interpreter or environment** the artifact
actually runs under, run interpreter- and environment-dependent probes under the interpreter the artifact
actually runs under, and prefer mutation evidence over a hand probe when the two disagree. A probe run
under the *wrong* interpreter reports a false vacuity — an assertion that is live under the artifact's
real shell looks dead under the shell you happened to type into — and chasing it costs real effort across
every reviewer who repeats the mistake, finding zero defects.

- **#340 reproduction (local instance):** a test loop drives eight separators through `printf '%b'`.
  Three of them are multibyte octal escapes. Bash expands them; that session's zsh does not. The
  orchestrator and two independent reviewers each probed under zsh, saw literal backslash text, and
  briefly concluded three assertions were vacuous. They were not — the suite's shebang is bash, and the
  mutation evidence was decisive. Cost: real effort, three times over; defects found: zero. **PR #340
  cost this would have eliminated:** the three false vacuity alarms — duplicated investigative effort
  across the orchestrator and two reviewers with zero defects found.

## Count-locked prose — a `count-locked` row on an unpinned claim triggers the pin-or-don't-write policy

The shared engine's Phase 0.6 `stale-prose-lint.py` ships **detection only**: it tags an exact-count
claim in diff-added prose as `count-locked` in its TSV output. The **policy** for what to do about a
`count-locked` claim lives here, in this repo's layer, not in the engine. When the fix loop's Step 3
stale-prose pre-check (or the engine's Phase 0.6) reports a `count-locked` row whose claim is **not**
already bound to a test assertion that would fail if the count drifts (the `assert_pin_unique` /
`assert_pin_red_under` / `pin_count` corpus), apply the repo's **pin-or-don't-write** policy: either
bind the counted claim to a suite pin in the same change so a later drift turns the desk RED, or reword
it drift-proof (a lower bound instead of an exact count, a pointer to the defining symbol instead of a
copied enumeration) so there is no frozen count to go stale. Do not ship an unpinned exact-count claim
in engine prose — an unpinned `count-locked` header is the very defect class (#328/#336) Phase 0.6
exists to catch, so authoring a fresh one is a self-inflicted Important finding. The engine detects; this
extension decides. (#423)

## Config-derivation fixes sweep the full six-shape adversarial matrix, not just the reviewer-cited row

When a fix touches **how a config value is read, derived, or defaulted** — a `config-get.sh` read, an
inline `jq` extraction over `.devflow/config.json`, an `// default` / `// true`-style fallback, an enum
validation, or any other code that turns a raw config value into a decision — the **same fix** sweeps the
full CLAUDE.md six-shape adversarial matrix over that value: `{object, array, scalar, valid-falsy (explicit false / 0 / empty string), missing, wrong-type}`.
Each shape is **tested in `lib/test/run.sh` in the same change** (exit-0 + a specific, not generic,
breadcrumb per shape; the **valid-falsy** row is load-bearing — a real `false` / `0` / `""` an
`// true` / `// default` extraction silently coerces to its truthy default is the documented
off-switch-that-never-worked defect, #312/#304). A shape that genuinely does not apply to this value is
recorded with a **written reason** instead of a test — never silently skipped. A fix that covers **only**
the reviewer-cited shape row is **incomplete by policy**: the sibling rows are exactly the next run's
predictable test-gap findings (PR #451 round 2 fixed and tested one config-read arm; round 3 existed
almost solely to add the untested sibling arm), so shipping the whole matrix at once is what stops the
per-fix extra review iteration. This is DevFlow-repo policy; the governing convention is CLAUDE.md's
best-effort-parser adversarial-matrix gotcha, and this section is its coupled mirror in
`.devflow/prompt-extensions/receiving-code-review.md` — edit both in the same change. (#466)

## Batched artifact regeneration

After applying edits and before each full-suite re-verify run, run `python3 lib/test/regenerate-artifacts.py` once. A fix loop's edits drift the checked-in generated records, and rediscovering each one a full suite run later is an iteration's dominant cost. The helper is the sole enumeration point; no inventory is listed here.

Act on its report first: commit a changed manifest with its causing edits, and resolve every exit-1-forcing judgment item under the policy it names. Informational lines need reading, not action.

**Any outcome but exit 0 or a fully-reported exit 1** — exit 2, a traceback, an empty or truncated report, an unattributable exit code — means an artifact went unchecked: unknown, not clean. Judge residually, never by hunting a named token. Never record `run`; record `batched-regeneration: skipped` naming what you saw, and fall back to serial discovery.

If the matcher refuses the invocation **twice**, stop — record the refusal and proceed to the suite run rather than iterating variants (the issue-401 two-denials discipline). On a run that maintains a workpad, record one line before each full-suite run — `batched-regeneration: run|refused|skipped`.

## Review-bundle ceiling self-apply (issue #618)

The `#618 AC3` gate holds the **shipped-default per-pass path ≤ 32,399 words** — an **interim** ceiling of the live `_rb_words` measurement plus **60 words**. Two assertions arm the valve, and a RED in **either** direction is ceiling drift, not a code defect: the path *grew* past the ceiling, or a prose *reduction* widened the gap past the margin (any trim of a shipped-default member does this). On either, the maintainer's recorded #618 decision authorizes a fix loop to **self-apply the escape valve** instead of stalling: re-measure with `_rb_words`, set measured **+60**, and reconcile every mirror — `lib/test/run.sh` (**both** the `RB_SHIPPED_CEIL` constant and the spelled-out `assert_pin_unique` ceiling literal), `docs/review-bundle-budget.md`, `CLAUDE.md`'s `≤`-prefixed ceiling phrase, and **this section's own ceiling phrase above** — editing `CLAUDE.md` **directly** (#366 carve-out; `skills/implement/SKILL.md` untouched), else the pin traps the fix loop. Record old/measured/new in the workpad and PR. Full procedure and scope (ceiling drift only — never lower the *target* toward at most 30,100, touch `#529 AC2`, or change the margin): [`docs/review-bundle-budget.md`](../../docs/review-bundle-budget.md)'s decision record.

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
