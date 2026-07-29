# Cloud allowlist & command-shape reference

This is the detailed forensic record for the CLAUDE.md "cloud allowlist" gotchas
(issues #363, #392, #401, #455, #484, #561). The **operative invariants and their enforcing
pins stay in CLAUDE.md** — this doc carries the evidence, the war-stories, the
probe tables, and the reasoning that would otherwise bloat those bullets. When
CLAUDE.md says "see `docs/cloud-allowlist.md`", this is where it points.

Source-of-truth files referenced throughout (bare paths — line numbers rot):

- `lib/capability-profiles.json` — the versioned manifest, single source of truth.
- `lib/generate-capability-profiles.py` — the generator (`--check` gates CI).
- `lib/review-profile.tokens` — the review-tier security-boundary lock.
- `.github/workflows/matcher-probe.yml` — the re-runnable empirical evidence source.
- `.github/workflows/devflow-runner.yml`, `devflow.yml`, `devflow-implement.yml` — the runners whose allowlist literals are generated.
- `lib/test/extract-command-heads.py`, `lib/test/extract-command-shapes.py` — the desk/CI-time guards driven by `lib/test/run.sh`.

---

## The two allowlists (issue #363)

`skills/review/SKILL.md` — the shared review engine — executes under **two
different allowlists**, and a command head that **neither** grants is **silently
denied** (refused before it runs; it does not fail loudly, it burns budget, and a
run can end with **no verdict at all**).

- **Auto-review path**: the `review` profile's `TOOLS='…'` line in
  `.github/workflows/devflow-runner.yml`.
- **Manual `/devflow:review` comment path**: `devflow.yml`'s hoisted `TOOLS='…'`
  (the `Resolve allowed-tools` step, consumed by `claude_args` **and** by the
  injected block alike, so the two cannot drift).

A command the skill invokes but a profile omits is refused. **Evidence: PR #340 —
7 of 14 denials were the engine trying to run the test suite.** The engine ended
runs with no verdict because heads it needed were ungranted on one path.

### The head guard

`lib/test/extract-command-heads.py` (driven by `lib/test/run.sh`) extracts every
head from the skill's ```bash fences and asserts **each** allowlist grants it. The
extractor is:

- quote / comment / heredoc-aware,
- `$(…)`-descending,
- wrapper-stripping,
- **case-arm-position-aware** (issue #392): arm patterns are stripped only where
  an arm may legally begin — after `case … in` and after each `;;` — so a command
  in a case **body** (e.g. a bare subshell `(cmd)`) keeps its head instead of
  being swallowed as a bogus arm.

**Scope boundaries:**

- **Inline-backtick prose is deliberately out of reach** — matching it resurrects
  the `git a` / `git failure` / `git said` false positives. A prose-only command
  like Phase 0.3.6's `git cat-file` is pinned by **direct literal** instead.
- The case-arm tracking is a **flag, not a depth counter**, so a **nested** `case`
  block is an accepted limitation — no fence in `skills/review/SKILL.md` nests a
  `case`.

### Adding a command to a fence

Grant it by adding the token to `lib/capability-profiles.json` (the versioned
manifest) and regenerating with `python3 lib/generate-capability-profiles.py`.
The `--check` mode wired into `lib/test/run.sh` turns any manifest↔literal drift
RED before merge — you **never hand-edit** the `TOOLS='…'` literals. See
[Manifest generation](#manifest-generation-issue-561).

`Bash(cd:*)` is **ungranted on the review profile**: its probe row was
redirect-confounded (unproven), and it is pinned **absent** in `run.sh`. Do not
re-add it without a fresh redirect-free probe row. On the **implement profile** the
grant was **revoked by policy (issue #855), unmeasured** — never recorded as denied
on that tier (a leading `cd` was observed *executing* on the review tier in run
30222310785, so an ungranted `cd` head does not imply a refused statement); the
revocation removes the authoring affordance, and the leading-`cd` ban is enforced
as a desk lint (`IR4`) rather than as a claimed matcher refusal. See
[`docs/working-directory-contract.md`](working-directory-contract.md).

---

## Heads vs shapes (issue #401)

**Heads are not enough.** The matcher denies composite **SHAPES** whose every head
is granted. **Evidence run 29105381021: 22 denials, no verdict.**

Refused shapes in the cloud **review** runner:

- leading `VAR=value` assignments,
- leading `cd`,
- `>` / `2>` redirects targeting `/tmp`,
- `cat`-heredoc writes,
- interpreter heads (`python3`),
- the unexpanded `"${CLAUDE_SKILL_DIR:-…}"` anchor as the **leading** token.

Permitted shapes (review tier) — **each with its own evidence status**, because the
four do not rest on the same evidence and a single "probe-proven" heading over all of
them read as though they did (issue #871):

- the **Write tool** into `.devflow/tmp/**` (granted in the review profile) —
  **PERMITTED, run 29111394360** (probe shape 9). This is the *orchestrator* grant; the two
  `PENDING` **dispatched-subagent** `Write` entries further down this file (issue #858,
  review and implement tiers) are a separate measurement and do not qualify it.
- `… | tee` — probe shape 10; **no per-row verdict is transcribed** in this file.
- `tee <<'EOF'` — probe shape 6; **no per-row verdict is transcribed** in this file.
- repo-relative **vendored-literal** helper paths — the **leading-token** form is
  **unrecorded at the review tier**: the review rows that exercise it in leading-token
  position (shapes 5 and 12) carry no annotated verdict. Two rows are evidence *about*
  the form and neither measures that position: review **shape 18** recorded PERMITTED
  (run 30310938175) for a vendored-literal helper path in **command-substitution
  condition** position — confounding evidence that such a path executes on this tier,
  not a measurement of the leading-token form — and **implement-tier row I2** is
  PERMITTED for the leading-token form on the **other** tier. Cite whichever you mean
  with its tier and its position, never as a bare review-tier "probe-proven".

The skill's "Cloud command-shape discipline" section and the grounding block's
command-shapes section carry the recipe. **Rule of thumb: two denials of a shape →
switch to a permitted alternative, never iterate variants.**

`lib/test/extract-command-shapes.py` (driven by `lib/test/run.sh`) turns a
denied-shape fence RED at the desk.

`.github/workflows/matcher-probe.yml` (repo-internal; **not** shipped by
`install.sh`) is the re-runnable evidence source — **re-run it after a
`claude-code-action` upgrade** before changing shape rules or grants (matcher
semantics are version-dependent).

---

## Probe evidence (review tier)

The review-tier `probe` job in `matcher-probe.yml` composes `--allowed-tools =`
the generated review-profile literal **plus candidate grants under test**, runs a
Haiku `claude-code-action` session that attempts each corpus shape once, and
computes a per-shape PERMITTED / DENIED / UNATTEMPTED verdict **deterministically**
from the action's execution file (`permission_denials` + recorded `tool_use`
calls) and on-disk side-effect files. **The model's own text output is never the
measurement.**

The abstract review-tier rule set is R1–R4 (leading-assignment / leading-`cd` /
`/tmp`-redirect / heredoc-write / interpreter-head families), enforced by
`extract-command-shapes.py`. A fifth rule, **R5** — an `if`/`elif`
command-substitution *condition* (issue #857) — shipped as a **discipline-only**
rule (not probe-backed when it landed, the same posture as the implement-tier IR3)
and was **retired in issue #869**: the review engine's old live-progress-comment
seed branched on `elif WP=$(workpad.py id …); then` inside a `case`/`if`/`elif`
compound, and the cloud review matcher refused that compound outright —
**measured 8/8 refusals across 6 PRs** (issue #857), each with the harness string
`Contains shell syntax (string) that cannot be statically analyzed`. The fix moved
that find-or-create decision into the bundled helper
`scripts/seed-review-progress.sh`, invoked as a leading-token
statement (a form granted on the review profile, though its review-tier permitted-ness
is unrecorded per the review-tier entry above; issue #871 appended a `; echo "seed-rc=$?"` trailer
so a refusal of that statement is observable rather than silent), and R5 guarded against reintroducing the *bare* `if VAR=$(…)` /
`elif VAR=$(…)` condition-substitution spelling as a stop-gap until the shape
could be measured in isolation. Four `matcher-probe.yml` review rows added in
PR #864 (a `;`-joined multi-statement command, a multi-line `if`/`else`/`fi`, an
`if VAR=$(granted-helper …)` condition — **Shape 18** — and a `printf` with a
double-quoted expansion) supplied that measurement. Shape 18 recorded
**PERMITTED** (review `probe` job, run **30310938175**, 2026-07-27): the condition
shape is cloud-permitted, so R5 — the finder, its `REVIEW_RULES` membership, its
planted control, and its `run.sh` assertions — was removed (issue #869). The
retirement does **not** re-permit the shape in `skills/review/**`: the seed no
longer uses it (the helper extraction stands on its own merits), and the removed
rule only ever guarded a stop-gap idiom the engine had already abandoned. Notable
recorded verdicts:

| Candidate | Verdict | Note |
| --- | --- | --- |
| `Bash(cd:*)` | DENIED | Row confounded by an independently-denied `>` redirect — **unproven**, kept for a redirect-free re-probe, pinned absent in `run.sh`. |
| `Write(/tmp/**)` | DENIED | Genuine out-of-workspace denial. |
| `Bash(scripts/*.sh:*)` (trailing-extension glob, issue #412) | DENIED — run **29135163829** (PR #413) | Even with the glob granted, `scripts/config-get.sh …` was refused (same DENIED as the ungranted control) → the trailing-extension glob does **not** match a repo-root leading token; the implement profile keeps the enumerated `*/<basename>.sh` helper globs; **no migration to `scripts/*.sh`**. |
| `Write(.devflow/tmp/**)` | PERMITTED | Landed as a grant from the probe's **first run, 29111394360**. |
| Shape 18 — `if VAR=$(granted-helper …)` condition-substitution (issue #857) | PERMITTED — run **30310938175** (review `probe` job, 2026-07-27) | The `if`/`elif` command-substitution condition shape is cloud-permitted → **retired desk-lint rule R5** (issue #869). Does not re-permit the shape in `skills/review/**` (the seed is already helper-extracted). |

Positive-control note (issue #477): the review verdict counts a
`permission_denials` match as DENIED **ahead of** `tool_use`, so an unrelated
`/etc/hosts` read (attempted by the model with a `Bash(grep:*)` grant) can make the
row-11 control read DENIED. The sibling probe jobs score their controls
differently and are unaffected.

### `load-prompt-extension.sh` grant surfaces and the Phase-3 dispatch (issue #802)

`load-prompt-extension.sh` is granted **directory-agnostically** — as
`Bash(*/load-prompt-extension.sh:*)` — on the `review` and `command` profiles, and
**by vendored literal only** — `Bash(.devflow/vendor/devflow/scripts/load-prompt-extension.sh:*)` —
on the `implement` profile (the `implement` profile carries no `*/` wildcard for it).
The Phase-3 final-pass reviewer dispatch (`skills/review/phases/phase-3-agents.md`)
**supplies the reviewer the vendored literal** as an already-resolved leading-token
command, so the dispatched path runs a granted shape on every tier and needs **no**
wildcard on any tier — the change adds **zero** grants.

**The grant's risk framing changed with issue #874 — it is no longer only "the
extension fails to load".** On the review tier the loader's bytes previously came
from the PR-head checkout, so the directory-agnostic grant also admitted a command
whose *output became the merge-gating reviewer's own appended prompt*. That channel
is now closed at the environment rather than at the grant: the review job exports
`DEVFLOW_PROMPT_EXTENSION_ROOT` pointing at a `$RUNNER_TEMP` closure populated from
the trusted base ref, and truncates the workspace copies unconditionally. The grant
itself is **unchanged** — the variable arrives through the step's `env:` rather than
a command prefix (a leading `VAR=value` is a denied matcher shape), and the new
`scripts/materialize-trusted-prompt-extensions.sh` runs as a workflow step rather
than an agent command — so `lib/review-profile.tokens` is byte-identical and
`lib/generate-capability-profiles.py --check` stays green.

### Step-level `env:` propagation — PENDING a maintainer-dispatched run (issue #874)

`.github/workflows/matcher-probe.yml` carries an **`env-propagation-probe`** job that
measures whether a step-level `env:` entry on a `claude-code-action` step is visible
to a command the **agent** runs — at two depths, because the two protected extension
loads sit at different ones: the `review` load runs in the orchestrator's own shell
(hop one) and the `requesting-code-review` load runs inside a dispatched
`general-purpose` Task (hop two). Every other `env:` entry on that step is consumed by
the CLI process itself, so no existing evidence covers a value an agent-run command
must read back — and this repository's own comment beside
`CLAUDE_CODE_DISABLE_BACKGROUND_TASKS` records that even the CLI-level effect was
measured rather than assumed.

The job sets the sentinel `DEVFLOW_ENVPROBE_SENTINEL_874`, has the session echo what
each hop read through its own Bash calls, and derives a four-way verdict
(`BOTH_HOPS` / `ORCHESTRATOR_ONLY` / `NEITHER_HOP` / `INCONCLUSIVE`, plus a suspect
`DISPATCHED_TASK_ONLY` inversion) with `scripts/env-propagation-probe-verdict.py`,
whose five verdict arms and four degraded arms `lib/test/run.sh` drives.

**This measurement is PENDING.** The implementing run added the job and the
documentation entry and deliberately did **not** dispatch the probe, so no verdict is
recorded here yet. Until one is, the claim that a consumer's committed base-ref
extension keeps working is an **expectation, not a guarantee**. The failure direction
is safe either way — an unpropagated variable makes the loader resolve the repo-root
path, find the workflow's truncated file, and print nothing — so a propagation failure
costs the feature, never the boundary; the loader's resolved-root breadcrumb, surfaced
at hop two through the `EXTENSION-STATUS: … resolved-root=…` field, is what makes such
a failure observable rather than silent. Dispatch the job from the Actions tab and
record the run id and verdict here.

The probe job's **helper-invocation-form rows** exercise a vendored helper as the
leading token in five path/grant forms (the review job uses `config-get.sh` as that
exemplar helper, not `load-prompt-extension.sh`). Three of them — the control row
(shape 11), the repo-relative vendored-literal row (shape 12) and the absolute-path
row (shape 13) — are **unrecorded**: no PERMITTED/DENIED verdict for them appears in
this table or in `run.sh`'s pin block. The remaining two are **not** unrecorded and
are deliberately not folded into that statement, because the source states different
things about them (issue #871):

- **Shape 15** (the repo-root `scripts/…` row under the `Bash(scripts/*.sh:*)` glob)
  is **measured DENIED — run 29135163829, PR #413**, per the `Resolve allowed-tools`
  step comment in `.github/workflows/matcher-probe.yml` and the glob row in the table
  above.
- **Shape 14** (the repo-root `scripts/…` row without that glob) is DENIED **only per
  that note's comparative clause** — it reads "the same DENIED as shape 14's ungranted
  control" — and carries **no independently recorded row verdict of its own**.
  Labelling both with one run id would state more than the source does.

**Every review-tier probe row for which no verdict is recorded ANYWHERE in
`.github/workflows/matcher-probe.yml` — neither annotated on the row itself nor stated
in that workflow's `Resolve allowed-tools` step comment — is likewise unrecorded**, and
takes the same remedy. Both locations count, because verdicts are recorded in both places:
shape 18's PERMITTED is annotated on its own row, while shape 15's DENIED and shape 9's
`Write(.devflow/tmp/**)` PERMITTED live in the step comment. A predicate keyed on the
row annotation alone would classify those latter two as unrecorded and contradict this
file's own evidence table. It is written as a predicate over the rows rather than a transcription of
today's row numbers, precisely so it cannot go stale when a row is added or a dispatch
records a verdict — read the current answer off the workflow itself, checking both
locations. Establish any of them with a post-merge
`workflow_dispatch` run of `.github/workflows/matcher-probe.yml` (its only pre-merge
trigger is a `pull_request` scoped to its own path, and `gh workflow run` is granted
on no profile, so the run is not an acceptance criterion of the change that added
this note). Until then, a refusal of the dispatched vendored-literal command is
handled by the Phase-3 fail-closed refusal path, never assumed impossible.

### Dispatched-subagent `Write` into `.devflow/tmp/**` — review tier — PENDING the first PR-triggered run (issue #858)

`.github/workflows/matcher-probe.yml` carries a **`subagent-write-review-probe`** job
that measures whether a **dispatched subagent's** `Write` into `.devflow/tmp/**`
succeeds under the review tier's **generated baseline joined with the `probe` job's own
standing candidate extras** — not the shipped review profile alone, which is why the
record reproduces the resolved literal verbatim rather than describing it. `Write(.devflow/tmp/**)` is granted for
the **orchestrator** (the `Write(.devflow/tmp/**)` grant row in the review-tier evidence table above, PERMITTED from run `29111394360`; the probe exercises it as shape 9), but a grant proven
for the dispatcher is `unestablished` for the **dispatchee** — CLAUDE.md's "Unknown is
not zero". The job is **dedicated** (not a shape row in the `probe` job, whose session
already writes to `.devflow/tmp/probe-09.txt`): its prompt instructs **no orchestrator
write at all**, so a `Write` record in its execution file has exactly one *expected*
author. That single-authorship is a **prompt-level** guarantee, not a technical
restriction — the composed allowlist grants `Write(.devflow/tmp/**)` to the whole
session, so the orchestrator retains the capability and simply is not asked to use it.
The helper does not rest on the guarantee alone: where the execution file records parent
chains at all, a parent-less (orchestrator-issued) `Write` naming the same file is
detected and routes the run to `unestablished` rather than to a `DENIED` whose
attribution that record would falsify.

The job **consumes** the resolved review literal from the `probe` job via `needs:`
(never a second `REVIEW=` assignment) and appends **`Task,Agent`** in its own
hand-written `--allowed-tools` — both dispatch heads granted so the allowlist can never
be what prevents the dispatch, keeping a null result attributable to the harness. `Task`
is in no generated region or manifest; this grant enters no shipped profile. The
dispatched `subagent_type` is the built-in `general-purpose` (no `--agents` block). The
subagent makes a granted-head control call **before** the write and one **after** it, and
`scripts/subagent-write-probe-verdict.py` derives a three-outcome verdict
(**PERMITTED / DENIED / `unestablished`**) from the execution file's `permission_denials`,
recorded `tool_use` inputs, and each call's `parent_tool_use_id`, corroborated by the
on-disk side-effect file. It reports the two control facts **independently** —
*recorded-at-all* and *chain-attributable* — never conjoined; the model's prose is never
read. A state outside the measurable pair reports `unestablished` rather than `DENIED`,
with one disclosed residual: a denial entry recording no `tool_name` at all and naming
the side-effect filename is read as the write denial, because the per-entry denial shape
is not yet recorded and no narrower attribution channel exists for it.

Both signals are attributed **per recorded entry**, never over the concatenation of the
run's entries: the write is the `Write` tool's own call naming the tier's side-effect
filename — the payload marker alone is not enough, since a write of that payload to another
path is not the write the probe asked about (a
different tool merely *naming* that path is not the write, and a different tool's refusal
quoting it is not the write's denial), and a parent-less marker call is the orchestrator's
wherever the execution file records parent chains at all. The **denial** side carries the
same filename requirement as its twin: a refused `Write` carrying only the payload and not
the tier's side-effect filename was a write to some *other* path, so it routes to its own
named `unestablished` reason rather than publishing a `DENIED` about a target whose
permission was never attempted — and so does a refused `Write` naming **neither** the
side-effect filename nor the payload, the entry shape the helper records as not yet
observed: its text establishes nothing about what was refused, so the run says exactly that
instead of falling through to a claim that no write was attempted. A multi-entry denial list holding both a dispatch refusal
and a genuine `Write` denial still reports `DENIED` **provided a dispatch is also recorded
in the file** — that conjunct is what the verdict requires, and with no recorded dispatch
there is no dispatchee to attribute the denial to, so such a list reports `unestablished`.

**This measurement is PENDING.** The implementing run added the job and this entry and
deliberately did **not** dispatch the probe (its only pre-merge trigger is a same-repo
`pull_request` scoped to the workflow's own path — so pushing this change to the
implementing PR *does* fire it — and `gh workflow run` is granted on no profile). Record
the verdict here from the **final pre-merge head commit** (a later push re-fires the
workflow and invalidates a recorded head — the `paths:` filter does NOT narrow this: on a
`pull_request` event GitHub evaluates `paths:` against the three-dot base…head diff, i.e.
the files changed in the whole PR, and this PR changes `matcher-probe.yml`, so every
subsequent push re-fires both paid probe jobs — including the commit that records this very
verdict), naming the **ref** (the implementing branch —
the job does not exist on the default branch until this merges), the **run id**, the
**job id**, the **head commit**, and the **resolved `--allowed-tools` literal verbatim**
alongside `--permission-mode acceptEdits`, model `claude-haiku-4-5-20251001`, and
`--effort low`. A `PERMITTED` cites, by their two ids, the
`tool_use`/`parent_tool_use_id` pair tying the `Write` to the job's dispatch, so a reader
can re-verify the chain against the execution file; a `DENIED`'s attribution rests on the no-orchestrator-write prompt
(the `permission_denials` per-entry shape is not yet recorded), and the run's **observed
denial-entry shape** is recorded alongside — the read that upgrades the denial side from
by-construction to measured. Commit the job's machine output beside
`docs/execution-file-shape.observed.txt`, as that record establishes.

This verdict is version-dependent and establishes nothing for a differently-defined
subagent type or a later `claude-code-action` version: **re-probe** after any upgrade.
**Scope caveat, carried in the emitted record itself:** the run uses
`--permission-mode acceptEdits`, so a `PERMITTED` answers *"did the dispatched subagent's
`Write` land under that permission mode?"* — it does not isolate the allowlist from the
permission mode as the sole reason the write was allowed.

| Tier | Verdict | Run id | Job id | Head commit | Ref |
| --- | --- | --- | --- | --- | --- |
| review | _pending first PR-triggered run_ | — | — | — | — |

---

## Probe evidence (implement tier) (issue #455)

The read-write `devflow-implement` profile is a **separate allowlist** with its
**own** probed denied shapes — **a shape proven on the review tier is unproven
here** — so the `implement-probe` job in `matcher-probe.yml` covers it
independently. Its abstract rule set is IR1 / IR2 / IR3 / IR4 / IR5 (distinct from
review's R1–R4; IR4 is a leading-`cd` authoring lint (issue #855) and IR5 mirrors
R3's `/tmp` redirect arm (issue #915)), enforced by
`lib/test/extract-command-shapes.py --profile implement`
against `skills/implement/SKILL.md`, `skills/implement/phases/*.md`, and
`skills/implement/references/*.md`.

### Leading `cd` and the working-directory contract (issue #855)

A **repo-relative vendored-literal helper path resolves against the `actions/checkout`
workspace root** — the run begins there and the Bash tool's working directory
persists across calls, so a leading `cd` moves every later helper's resolution base
out from under it. The canonical statement of that contract, tier-scoped, is
[`docs/working-directory-contract.md`](working-directory-contract.md).

`Bash(cd:*)`'s status on the implement tier is **revoked by policy (issue #855),
unmeasured** — **never denied**. The revocation removes an authoring affordance; it
is **not** claimed to produce a matcher refusal, because a leading `cd` was observed
*executing* on the review tier (run 30222310785) where the grant is already absent.
The leading-`cd` ban is enforced instead as the desk lint **`IR4`**
(`find_implement_violations` emits it for a fenced statement whose head is `cd`), so
a `cd` authored into a scanned prompt surface fails at the desk.

`IR1` / `IR2` (label-helper loops) are the only implement-tier rules with a probe
measurement (rows I4/I5). `IR3` is discipline-only (the capture carve-out rests on
an inference, not a measurement — see rows 8/9 below). **`R1`, `R3` and `R4` are not
enforced on the implement profile at all, because their status there is
unmeasured** — the recorded implement rows carry no entry for a leading assignment,
a `/tmp` redirect, or an interpreter head. The contrary evidence that *does* exist
is not a permission: the PR #694 run reported a **blocked stdout redirect even into
the working-directory `.devflow/tmp`**, and the interpreter head is denied per issue
#789. Neither of those forms is stated as permitted on the implement tier; they are
simply not carried as an enforced desk rule there.

### The recorded implement-tier table (rows I1–I6)

The original attribution-split run (issues #450/#455) proved:

| Row | Shape | Verdict |
| --- | --- | --- |
| **I1** | unexpanded `${CLAUDE_SKILL_DIR:-…}` anchor as the leading token | DENIED |
| **I2** | explicit **vendored-literal** grant form, measured on `apply-labels.sh` | **PERMITTED** (real recorded `tool_use`) |
| **I3** | config `*/basename` glob against a vendored-literal leading token, measured on `ensure-label.sh` | DENIED (the glob did not match) |
| **I4** | `for …; do …; done` wrapping a label helper | DENIED |
| **I5** | piped `while read` loop wrapping a label helper | DENIED |
| **I6** | `VAR="$(…)"` capture of a label helper (confounds label-helper + capture + inner `2>&1`) | DENIED |

**I3 is the whole reason the explicit grants had to ship.** Read it as "the glob
form was refused", **not** as "`ensure-label.sh` is unreachable". Stage B (#455)
then shipped both halves — the explicit vendored-literal grants in
`devflow-implement.yml` **and** the call-site rework — so the split is retired and
the job now measures the **real shipped profile end-to-end**.

### The issue #571 re-measurement (rows 1–16)

Observed 2026-07-18 UTC (issue #571): user-directed `workflow_dispatch` run
**29623046995**, `implement-probe` job **88021801138** (completed success before
the workflow's intentional cancel-probe cancellation), at commit
`f2162d7683bc7a352fce4efce3f092e864aab8b9`. **An autonomous implement run cannot
discharge this evidence gate without explicit human direction.** The execution-file
verdict table:

```
 1 DENIED      2 PERMITTED   3 PERMITTED   4 DENIED
 5 DENIED      6 DENIED      7 PERMITTED   8 PERMITTED
 9 DENIED     10 DENIED     11 PERMITTED  12 PERMITTED
13 PERMITTED  14 DENIED     15 DENIED     16 DENIED
```

Every row recorded `tool_use=yes`; rows with a shape discriminator recorded
`shape=ok` — so none of the #571 rows was REFORMULATED or UNATTEMPTED. In this
re-measurement rows 2/3 are PERMITTED because the shipped profile now carries
**both** the explicit grant and the glob for each label helper, so a PERMITTED
there proves the leading-token call **runs** but attributes to **neither form**
(I3's recorded glob denial remains the standing evidence that the glob does not
match a vendored-literal leading token).

### Rows 8/9 — the non-label-capture disambiguators

The `VAR=$(…)` capture carve-out (the phase-4 fences read `deferred.labels` that
way) is exempted on the **reasoning** that the matcher descends into the
substitution — **but this is an INFERENCE, not a measurement.** The only measured
capture row (I6) came back DENIED while confounding three properties (label
helper + capture + inner `2>&1`).

- **Row 8** — `VAR=$(…)` capture of a **non-label** granted helper, bare spelling
  (the disambiguator for descent). A PERMITTED means the matcher descends into a
  non-label substitution and I6's denial is label- or redirect-attributable.
  (Note: the fences actually emit the capture inside an `if !` compound, which
  remains unmeasured — a PERMITTED settles the descent question, not the fences'
  exact statement shape.)
- **Row 9** — redirect-free `VAR="$(…)"` capture of a **label** helper (identical
  to I6 but without the inner `2>&1`). Read with rows 6 and 8, it separates "the
  capture shape is denied" from "the inner redirect is denied" from "a label
  helper inside a substitution is denied".

**Until a dispatch records rows 8/9, do NOT cite the carve-out as probe-proven,
and keep every phase that depends on such a capture fail-closed** — *no output at
all* is a possible denial, never an empty value.

### Re-deriving the I2/I3 per-form attribution

The shipped profile now carries **both** the explicit grant and the `*/basename`
glob for each label helper. If an upgrade ever needs the per-form verdicts
re-measured, **re-split TEMPORARILY in a scratch branch** — grant `apply-labels.sh`
only explicitly and `ensure-label.sh` only via the glob, as the original run did —
dispatch, record, and **revert**. Do not leave the split in: it makes the job
measure a profile the repo does not ship.

Multi-operation statements (`A; B`, `A && B`) are deliberately excluded from the
probe: shipped implement phase fences already exercise them successfully, so
another row would be redundant rather than new evidence.

### Row 17 — an executable `.py` as a direct leading token (issue #789)

Observed on the **implement** tier in run **30129638403** (branch
`worktree-issue-789`), shape row **17** of `matcher-probe.yml`:

| Row | Shape | Verdict |
| --- | --- | --- |
| **17** | an **executable** `.py` file invoked as a direct leading token (`lib/test/coverage_map_guard.py --iprobe17direct`) | **PERMITTED** (`denial=no; tool_use=yes; shape=ok`) |

This is the `run.sh` / `run-module.sh` pattern applied to a Python helper: the file
carries a `#!/usr/bin/env python3` shebang **plus the exec bit**, is granted as
`Bash(lib/test/coverage_map_guard.py:*)`, and is invoked **by path**. The
contrasting fact is the one already recorded under *Heads vs shapes* — `python3
<script>`, the **interpreter-head shape**, is **denied even though `python3` is a
granted head** (#401). So the exec bit plus a direct-token grant is what makes a
Python helper cloud-invocable; adding `python3` in front of it un-does that.

The row deliberately measures only whether the harness **let the command run**, not
what it returned: `--iprobe17direct` is consumed as a repo-root path that does not
exist, so the command exits 1 with an `[input-error] git ls-files failed`
breadcrumb in a fraction of a second.

**Consumer of this evidence.** Issue #789's focused-verification tiers depend on
this shape: a `scripts/*.py` / `lib/*.py` change iterates on the covering
`lib/test/test_*.py` named by its coverage-map `focused_test` field, invoked as a
direct leading token so the *same* command works on the local and cloud tiers. Had
the probe come back DENIED, the cloud tier would have kept the full-suite default
and those tiers would have stayed local-only.

### Dispatched-subagent `Write` into `.devflow/tmp/**` — implement tier — PENDING the first PR-triggered run (issue #858)

`matcher-probe.yml` also carries a **`subagent-write-implement-probe`** job that measures
the same dispatched-subagent `Write` fact on the **implement** tier — because a shape
proven on the review tier is unproven here (the two are separately-probed allowlists). It
is the structural twin of the review-tier job above: it **consumes** the resolved
implement literal from the `implement-probe` job via `needs:` (never a second `IMPLEMENT=`
assignment), appends `Task,Agent` in its own hand-written `--allowed-tools`, dispatches one
built-in `general-purpose` subagent that writes `.devflow/tmp/subwrite-implement.txt`
(the orchestrator writes nothing), and derives the three-outcome verdict with the same
`scripts/subagent-write-probe-verdict.py --tier implement`.

Note the two tiers' row numberings are independent — both contain rows numbered 8 and 9 —
so the verdict record names its tier as data, and the helper carries a machine-consumed
`tier` field for the same reason.

**This measurement is PENDING**, on the same terms as the review-tier entry above: added
but not dispatched, recorded from the final pre-merge head, version-dependent, re-probe
after any `claude-code-action` upgrade.

| Tier | Verdict | Run id | Job id | Head commit | Ref |
| --- | --- | --- | --- | --- | --- |
| implement | _pending first PR-triggered run_ | — | — | — | — |

---

## Grants are per-HEAD across the whole pipeline (the `paste` war-story)

A repo rule from #363/#401 (**not** an implement-probe row): **grants are
per-HEAD across the whole pipeline, not just the leading token.** One ungranted
head in a tail refuses the entire statement, and it produces **no output**.

**War-story:** `paste` is granted nowhere. An in-PR draft of the reworked fences
ended the label **normalizer** in `| paste -sd, -`, which would have refused that
normalizer statement outright — leaving the resolved labels non-empty but the
**normalized list empty**, so the applies silently did nothing (caught at the
desk). Use the granted `tr` / `sed` / `grep` instead.

Consequence for the label call sites: `devflow-implement.yml`'s baked literal
grants `apply-labels.sh` / `ensure-label.sh` explicitly, and **all four label call
sites** — Phase 3.1's `DevFlow` provenance apply, Phase 4.0/4.0.5's
`deferred.labels` applies, and Phase 4.1's `Documented` apply — are reworked to
**agent-level single-leading-token calls that read their inputs from printed tool
output** (a shell variable does not survive into a later separate command).

Row I1 (the unexpanded anchor) is **not lint-pinnable on either tier** — every
legitimate helper call keeps the portable `${CLAUDE_SKILL_DIR:-…}` anchor in
source (#275) and resolves it at runtime — so it stays **prose-discipline**.

---

## Implement-profile head guard + inline-engine surface (issue #484)

Phase 3 of `/devflow:implement` runs the review engine **inline** under
`devflow-implement.yml`'s baked `--allowed-tools` (**not** the review profile), so
**every helper the normal inline flow can reach needs an implement-profile
grant** — the review engine is shared.

`lib/test/run.sh`'s #484 head guard deliberately **over-approximates** that runtime
surface. It drives `extract-command-heads.py` in an **`implement-block` parse
mode** that reads **ONLY** the baked `--allowed-tools` block — never the whole file
or `.devflow/config.json`, so a `Bash(...)` cited in a YAML comment is **not** a
grant; it fails **closed** on an absent/malformed block. It runs over all fenced
source in:

- `skills/implement/**`,
- `skills/review*/**`,
- the dispatched `skills/requesting-code-review/**` final pass,
- including standalone-only review **Phase 4.4**.

It fails when an audited fenced head is neither granted nor in the exact withheld
list (`gh pr checkout`, `git rev-list`, `mktemp`). A separate suppression list
covers shell builtins + parse artifacts, and a **removal-proof contract** requires
inline `workpad.py` shorthand to **expand to the portable granted helper path**
before emission.

---

## Manifest generation (issue #561)

The five runner/probe allowlist literals are **GENERATED from one versioned
manifest — never hand-edit them.**

### The manifest

`lib/capability-profiles.json`:

- integer `manifest_version`,
- named token `groups`,
- a `readme`,
- exactly the `review` / `implement` / `command` profiles, each composing group
  refs (`@core_review`, `@unix_text_common`, …) + inline tokens into flat ordered
  lists.

Groups are shared across profiles **only where the contiguous token runs are
genuinely identical**; most runs are per-profile.

### The five generated regions

`python3 lib/generate-capability-profiles.py` compiles the manifest into exactly
**five** regions:

1. `devflow-runner.yml`'s **review** `TOOLS='…'`,
2. `devflow.yml`'s **command** `TOOLS='…'`,
3. `devflow-implement.yml`'s `--allowed-tools` **base list** — up to the
   `${{ needs.config.outputs.allowed_tools_extra }}"` splice, which is preserved
   **verbatim** (consumer-facing surface),
4. `matcher-probe.yml`'s `REVIEW='…'` baseline,
5. `matcher-probe.yml`'s `IMPLEMENT='…'` baseline.

Each region carries a **banner comment** with `manifest_version` + the **sha256**
of that region's resolved token list. The banner is placed where it is
syntactically inert and **never contains the byte sequence `TOOLS='`**.

The generator is **python3 stdlib-only** (no `yaml`), reads **no git history**, and
has **no runtime footprint** (a `run.sh` assertion greps the six workflows for zero
non-comment references to it — desk/CI-time only, mirroring
`extract-command-heads.py`). Every defect (malformed manifest, missing/duplicated
anchor, unreadable/unwritable target, a review list that drifts from the lock)
exits **non-zero with a stderr breadcrumb** and leaves every target byte-unchanged
(fail-closed).

### `--check` gates CI

`python3 lib/generate-capability-profiles.py --check` (wired into
`lib/test/run.sh`, so the required **`lib + python tests`** CI job gates it)
byte-compares every region and turns any drift RED with a token-level
**directional** diff — a hand-added workflow token is named as **workflow-side**
with "add it to the manifest and regenerate" (blind regeneration would silently
revert the grant). It exits 0 with empty stdout when every region matches.

### The review-profile security boundary + the lock

**The review profile is a security boundary:** the generated review literal **IS**
the read-only reviewer allowlist (the deny floor filters only appended consumer
extras, **never the base**). So `lib/review-profile.tokens` **locks its exact
resolved token list** — the generator **never writes** it, and **any** manifest
edit (including to a shared group) that changes the resolved review list **fails
closed** until you update that lock **in the same PR**. Widening the reviewer
therefore always needs a **visible diff**.

An **implement-only** grant leaves the review boundary untouched, so
`lib/review-profile.tokens` and the review-region checksums stay byte-identical and
only `manifest_version` moves.

### The `manifest_version` bump rule

**Increment `manifest_version` exactly once in any PR that changes the manifest.**
This is a **review convention, not machine-enforced** (the generator reads no git
history); the **per-region checksums are the machine truth**.

### What stays hand-maintained

Empirical territory is **NOT** generated — the manifest states **policy**, never
**measurement**. The probe's candidate rows, verdict tables, command-shape
verdicts, and the `EXTRAS` config-mirror row in `matcher-probe.yml` stay
hand-maintained.

**Adding a grant** = edit the manifest (+ the lock if it widens review) →
regenerate → the same `--check` gate covers what the retired #450 token-sync pin
used to, plus the review-tier equality that never had a pin.

---

## Grant flows

### Review / command tier

Add the token to the relevant profile in `lib/capability-profiles.json`,
regenerate, update `lib/review-profile.tokens` in the same PR **if** the resolved
review list changes, bump `manifest_version`. Never hand-edit the workflow
literals.

### Implement-tier bundled-helper grant flow (issue #555)

A bundled helper that a `/devflow:implement` fence invokes — the §4.0.5-class
case, e.g. `scripts/discover-deferral-manifests.py` — is granted by adding its
vendored-literal token
`Bash(.devflow/vendor/devflow/scripts/<helper>:*)` (the **row-I2-proven** explicit
leading-token form) to the `implement` profile in `lib/capability-profiles.json`
and regenerating. That **one edit** rewrites:

- `devflow-implement.yml`'s baked `--allowed-tools` baseline, **and**
- `matcher-probe.yml`'s `IMPLEMENT` baseline

in lockstep — so the probe's baseline can never drift from the tier it is probing —
and the generator's `--check` (driven by
`lib/test/modules/capability-profiles.sh`) enforces it. **Never hand-edit either
workflow literal** to add such a grant.

### Implement-tier repo-internal test grants (issue #789)

The same one-edit flow covers a **repo-internal** helper the implement tier must
run in-env — no vendored literal, because `lib/test/**` is not shipped to consumers
by `install.sh`. Issue #789 added seven such direct-leading-token tokens to the
`implement` profile only:

```
Bash(lib/test/test_python_scripts.py:*)
Bash(lib/test/test_module_harness.py:*)
Bash(lib/test/test_workflow_flight_recorder.py:*)
Bash(lib/test/test_workflow_analyzer.py:*)
Bash(lib/test/test_verification_baseline.py:*)
Bash(lib/test/test_create_issue_context_eval.py:*)
Bash(lib/test/coverage_map_guard.py:*)
```

`manifest_version` went 8 → 9 and the literals were regenerated with `python3
lib/generate-capability-profiles.py`. Two invariants make this an **implement-only**
widening, both asserted by the suite: `lib/review-profile.tokens` is
**byte-unchanged**, and the generated `review` and `command` literals gained **no**
token — only `devflow-implement.yml`'s baked `--allowed-tools` and
`matcher-probe.yml`'s `IMPLEMENT` baseline moved. Each granted file must also carry
the **exec bit in the git index**, or the direct-token form the grant describes
cannot run; `lib/test/coverage_map_guard.py`'s arm 10 checks exactly that for every
`focused_test` a coverage-map entry records, and reports an unestablished mode set
or an unreadable manifest **as unestablished** rather than collapsing it onto a
verdict.

Grant timing is the usual one (#593): these are baked workflow literals rather than
config keys, but the workflow the run executes is the default branch's, so a grant
a PR ships is **inert for that PR's own implementing run** and live for subsequent
cloud runs.

### The install.sh-vs-vendor-fetch skew warning

The **workflow grants** ship to consumers via `install.sh` **file-copy**, while the
**skill rework** ships via the `devflow_version` **vendor fetch**. These are **two
independently-updated artifacts** whose skew silently **re-denies the applies**, so
**the two halves must be upgraded together** (docs: `docs/install.md`,
`docs/DEVFLOW_SYSTEM_OVERVIEW.md`).

## PreToolUse shape guard (issue #805)

`lib/test/extract-command-shapes.py` turns a denied-shape review fence RED **at the
desk**; a runtime consumer makes that desk lint *incomplete* — it does not stop the
engine re-emitting a denied shape live. `scripts/pretooluse-shape-guard.py` is that
runtime consumer: a `PreToolUse` hook for the review tier that **denies** a Bash command
whose any statement matches a probe-proven denied **arm** and returns a
`permissionDecisionReason` naming the permitted alternative, at the moment of the
offending call. It resolves through `extract-command-shapes.py`'s arm-level
`classify_arms()` because the deny set is defined over **arms**, not rule ids
(`classify()` collapses R3's two arms onto one token).

**The review-tier `settings`-input registration is now wired (issue #908); the committed
`.claude/settings.json` channel remains a maintainer prerequisite.** What ships is the
guard body, its unit coverage, its hardening from the trusted base ref via the `#458`
`HOOK_TARGETS` closure (its path is in both `HOOK_ENTRY_TARGETS` and `HOOK_TARGETS`), and
— added by issue #908 — the `settings` input on `devflow-runner.yml`'s review-tier action
step that makes the guard effective in a cloud review run, paired with an unconditional
harden step that always materializes a trusted base copy of the guard closure (or stubs it
inline, fail-closed) so registering through `settings` never executes PR-editable guard
code in the secrets-bearing job. `devflow-implement.yml` registers no guard. What remains a
**maintainer prerequisite** — deliberately outside issue #908's scope, because the harness
denies agent writes under `.claude/` — is the `PreToolUse` key in the committed
`.claude/settings.json`: the local/interactive registration channel, and what arms the
`#458` relevance gate (`--wired-check` matches `HOOK_ENTRY_TARGETS` against the *trusted
base* settings). Until that committed key lands the local/interactive channel is inert;
the cloud review-tier channel is live as of this change, so the runtime behavior described
below is observed there while remaining the guard's implemented contract locally.

### The deny set and each arm's permitted alternative (authoritative)

This table is the **authoritative** record of each denied arm's permitted alternative;
`scripts/pretooluse-shape-guard.py`'s `REMEDIATION` table is its **mirror**, and a
`lib/test/run.sh` assertion pairs each arm's row here with the guard's row for the same
arm, so a change on one side reconciles the other in the same commit (the same
coupled-mirror discipline the closure literals carry, applied to a `scripts/`-to-`docs/`
pair). Both sides are extracted **by arm id** — this document's table row for the arm, and
the guard's `REMEDIATION` entry for the arm — never by a whole-file substring test, which
could not distinguish the row it claims to pin from any other mention of the same literal
and would be inert.

**The join literal differs by arm, and is deliberately not re-quoted in this paragraph**
(a second copy outside the row would defeat the row-scoped extraction). `R1` and `R3-tmp`
each join on a whitespace-free fragment of their own permitted-alternative cell, so
editing either alternative cell alone turns the suite RED. `R4` joins on its
**denied-shape** cell instead, because its alternative is a whitespace-bearing English
phrase that the issue-810 boundary classifies as markdown prose and so may not be pinned;
editing the `R4` **alternative** cell alone does **not** turn the suite RED — reconcile
that one by hand.

| Arm | Denied shape | Permitted alternative (the join key is the arm id) |
| --- | --- | --- |
| `R1` | a leading `VAR=value` assignment or env-prefix (`M=x cmd`) | capture a command's output with `VAR=$(cmd)`, or pass the value as an argument |
| `R3-tmp` | a `>`/`>>` redirect targeting `/tmp` | author the file with the Write tool under `.devflow/tmp/`, or stream through a pipe into `tee` |
| `R4` | an interpreter head (`python3/python/node`) | invoke the helper directly by its granted path as the command's **leading token** |

**Excluded arms (a runtime deny is terminal, so denying a permitted shape costs the
engine a working shape):** `R2` (a leading `cd`, DROPPED as unproven/confounded — probe
row 3) and `R3-heredoc` (an in-workspace `cat`-headed heredoc write, banned as authoring
discipline, not a probe result). The guard **defers** these.

### PreToolUse probe evidence (Part 1)

**The probe arm is authored (issue #908); its dispatch and evidence are recorded
post-merge (issue #919).** `.github/workflows/matcher-probe.yml` now carries a
`pretooluse-probe` arm that registers a `PreToolUse`/`Bash` hook via the `settings` input,
writes `.devflow/tmp/pretooluse-probe-fired`, and reports `FIRED`/`NOT-FIRED` (absent =
established negative) and `REASON-DELIVERED`/`REASON-ABSENT`. It establishes, by
observation, whether a `PreToolUse` hook fires under `claude-code-action` and whether its
`permissionDecisionReason` reaches the engine transcript. The guard's own firing behavior is
resolved from the workflow definition and is **not** observable inside the implementing
pull request's own run, so the probe is dispatched **after merge** and its run id +
three-way result, plus one review run's per-arm denial counts against the
run-30138268273 baseline of five `/tmp`-redirect denials, are recorded here then (issue
#919 owns that dispatch and fills the row below):

| Probe run id | Firing verdict | Reason-delivery verdict | Per-arm denial counts (review run) |
| --- | --- | --- | --- |
| _(pending post-merge dispatch)_ | — | — | — |
