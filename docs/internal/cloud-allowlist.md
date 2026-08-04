# Cloud allowlist & command-shape reference

This is the detailed forensic record for the CLAUDE.md "cloud allowlist" gotchas
(issues #363, #392, #401, #455, #484, #561). The **operative invariants and their enforcing
pins stay in CLAUDE.md** — this doc carries the evidence, the war-stories, the
probe tables, and the reasoning that would otherwise bloat those bullets. When
CLAUDE.md says "see `docs/internal/cloud-allowlist.md`", this is where it points.

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
- **Manual `/prflow:review` comment path**: `devflow.yml`'s hoisted `TOOLS='…'`
  (the `Resolve allowed-tools` step, consumed by `claude_args` **and** by the
  injected block alike, so the two cannot drift).

A command the skill invokes but a profile omits is refused. **Evidence: PR #340 —
7 of 14 denials were the engine trying to run the test suite.** The engine ended
runs with no verdict because heads it needed were ungranted on one path.

### The injected allowed-command list — every tier, including implement (issue #1170)

**Standing rule (the maintainer's):** when a command is refused by the cloud
harness, the agent should be able to see that the permission was denied and be
pointed at alternatives — either similar permitted commands, or a resource listing
the complete set of allowed commands so it can pick a permitted one and retry.

The refusal itself happens inside `claude-code-action`'s tool matcher, *before the
command runs*, and **the grounding block does not change the matcher's response** — it
is a prompt-side remedy, not a change to the harness. Whether *anything* can reach the
agent at the moment of refusal is a separate question, and it is **unestablished rather
than settled** — see the limits paragraph below, which scopes it. What this remedy
**does** achieve — and is the maintainer's stated fallback — is to put the complete
allowed-command list in front of the agent **up front**, so a refused shape is a lookup
against a list it already has rather than a guess.

`scripts/render-grounding-block.sh` injects the **exact resolved `--allowed-tools`
string** (section 2 of the review-tier block) plus the command-shape rules (section 3)
and the headless-run discipline (section 4). Those three section numbers are the
review-tier numbering; the implement tier omits two sections and renumbers the survivors
1/2/3, as the `MODE=implement` bullet below records. It is rendered **once**, by that one
helper, and prepended to the prompt on **every** tier:

- **`/prflow:review`** — `devflow.yml`'s `Compose review grounding block` step.
- **Auto-review** — `devflow-runner.yml`'s `Compose review prompt` step.
- **`/prflow:implement`** — `devflow-implement.yml`'s `Compose implement grounding
  block` step, in `MODE=implement`, which renders the tier-agnostic sections only
  (the review-only CI-results and trusted-source-displacement sections are omitted,
  and the survivors renumber 1/2/3).

Every tier consumes the **same** hoisted `TOOLS='…'` step output for both
`claude_args`'s `--allowed-tools` **and** the injected block, so the block quotes the
exact string the run resolved by construction — there is **no second, hand-copied
copy** of the allowed-tools text (the coupled-mirror hazard the block was built to
avoid; `lib/test/run.sh` pins all three workflows to carry no second copy).

**The limits, stated plainly.** This does **not** make a denial visible at the moment
it happens, and it does **not** change the matcher's response — a refused command
still produces no output and burns budget. It only gives the agent the list to check
against, up front.

Read that as a limit of **this** remedy, not as a repository-wide impossibility. The
in-the-moment channel is **unestablished, not ruled out**: `scripts/pretooluse-shape-guard.py`
is an in-tree `PreToolUse` hook built for exactly that purpose — it returns a `deny`
whose `permissionDecisionReason` names the permitted alternative for the denied shape —
and #919 records, on repeated same-repo probe runs, that a hook registered through the
action's `settings:` input **does fire** under `claude-code-action`. What is genuinely
open is narrower: whether `permissionDecisionReason` survives to the engine transcript on
the **`deny`** path is unmeasured (every recorded observation is on the probe's own
`allow` path, for which the reason is specified to be ignored), and the guard is wired to
no runnable tier. Both are tracked — see #1047 (residual item 2) and #919, and the
*PreToolUse probe evidence* section further down for the recorded verdicts. Making
denials visible *after* a run is a third, separate concern — issue #1064 (durable denial
forensics). The three are complementary and none substitutes for the others.

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
[`docs/internal/working-directory-contract.md`](working-directory-contract.md).

---

## Heads vs shapes (issue #401)

**Heads are not enough.** The matcher denies composite **SHAPES** whose every head
is granted. **Evidence run 29105381021: 22 denials, no verdict.**

Refused shapes in the cloud **review** runner:

- leading `VAR=value` assignments,
- leading `cd`,
- `git -C <path> <subcommand>` (a working-directory-flag shape; see the run-30832631347 note below),
- `>` / `2>` redirects targeting `/tmp`,
- `cat`-heredoc writes,
- interpreter heads (`python3`),
- the unexpanded `"${CLAUDE_SKILL_DIR:-…}"` anchor as the **leading** token.
- the unexpanded `${CLAUDE_SKILL_DIR:-…}` anchor **in argument position under a separately-granted head** — see the dedicated subsection below (issue #1124).

### The `${CLAUDE_SKILL_DIR:-…}` anchor — leading-token AND argument-position denials (issue #1124)

The portable source anchor `"${CLAUDE_SKILL_DIR:-…}"/../../scripts/<helper>` (issues #241/#275) is denied by the cloud matcher in **two** distinct positions:

- **Leading-token position** (long recorded, above and in `CLAUDE.md`): the anchor as a command's leading token is refused. The remedy is the #1256/#1124 **conditional form** — emit the granted vendored literal `.prflow/vendor/prflow/scripts/<helper>` as the leading token first, and keep the anchor line as the fallback arm for the local/editor and non-Claude-Code tiers where `.prflow/vendor/` does not exist (portability preserved). The three review-engine consumer-prompt-extension loads now emit this form; `lib/test/lint-anchor-fallback-arm.py` is the desk-time gate that fails when an **enrolled** cloud-reachable call site emits the anchor leading token with no vendored fallback arm.

- **Argument-position denial — newly recorded.** In run **`30695072336`** (the `command` job of `devflow.yml`, `/prflow:review 1058`, 2026-08-01) the execution-diagnostics denial list contains verbatim:

  ```
  - `Bash`: {"command":"echo \"${CLAUDE_SKILL_DIR:-/home/runner/work/prflow/prflow/skills/review}\"","description":"Resolve review skill dir"}
  ```

  `Bash(echo:*)` was present in that run's resolved allowlist — **the head was granted and the command was still denied.** The distinguishing feature is the unexpanded `${VAR:-default}` expansion in the **argument**. That run recorded 21 denials in total and still completed, so the denial is individually invisible, not individually fatal.

  **Scope of the argument-position denial — three measurement rows now exist (issue #1152), verdict DISPATCHED-PENDING.** Whether the matcher refuses all unexpanded parameter expansions in argument position, only the defaulted `${VAR:-default}` form, or only this variable, was previously **unestablished** — `matcher-probe.yml` carried no argument-position corpus row. Issue #1152 adopted issue #1124's orphaned rows and added them to the new **`command-probe`** job (rows 8–10), which measures the same `command` tier the denial was recorded on:

  | # | Argument-position shape | Verdict |
  |---|-------------------------|---------|
  | 8 | defaulted anchor expansion `echo "${CLAUDE_SKILL_DIR:-…}" …` (reproduces run `30695072336`) | **dispatched-pending** |
  | 9 | bare anchor expansion `echo "${CLAUDE_SKILL_DIR}" …` | **dispatched-pending** |
  | 10 | bare expansion of a **non-anchor** variable `echo "${GITHUB_ACTIONS}" …` (control — distinguishes "this variable" from "this expansion form") | **dispatched-pending** |

  The rows and their generated baseline ship with this change; the verdicts land on a later `workflow_dispatch` of `matcher-probe.yml`. **A verdict is never written from inference** — matcher semantics are provable only in a real probe run. Read against each other once dispatched: if 9 is DENIED and 10 PERMITTED, the denial is specific to `CLAUDE_SKILL_DIR`; if both are denied, argument-position bare expansion is refused generally; if 8 is denied but 9 permitted, only the defaulted form is refused. Until then this remains out of scope for the leading-token remedy (issue #1124 / PR #1272), whose conditional call form addresses only the leading-token position.

**Anchor invocation call-site census (issue #1124 AC2).** Re-derived at the issue's HEAD (index-sourced per issue #711): **118** anchor leading-token helper invocations across **34** `skills/*` files. Disposition:

- The **3 review-engine consumer-prompt-extension loads** — `skills/review/SKILL.md` (`review`) and both loads in `skills/review-and-fix/SKILL.md` (`review-and-fix`, `receiving-code-review`) — were the evidenced denial class on the merge-gating cloud review tier; they are **converted here** to the conditional form and enrolled in `lint-anchor-fallback-arm.py`.
- The remaining **~15** `load-prompt-extension.sh` loads (one per other `skills/*/SKILL.md`, plus the Phase-3 dispatch) and the **~100** other helper invocations (`workpad.py`, `config-get.sh`, `issue-audit-state.py`, …) are the sanctioned **#275/#701 anchor-source form**: `lib/test/extract-command-heads.py`'s `_normalize()` rewrites the anchor into the granted vendored literal before classifying, so these are the single-source form the head guard already accepts. They are **not** the "anchor with no fallback arm" denial class and are left unchanged; each follows the same conditional shape **as it becomes cloud-reachable** (ruling consequence 1), at which point it is enrolled in the lint. This is deliberately not a blanket sweep of the anchor (ruling consequence 2 / #1152/#1153).

Permitted shapes (review tier) — **each with its own evidence status**, because the
four do not rest on the same evidence and a single "probe-proven" heading over all of
them read as though they did (issue #871):

- the **Write tool** into `.prflow/tmp/**` (granted in the review profile) —
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
| `Write(.prflow/tmp/**)` | PERMITTED | Landed as a grant from the probe's **first run, 29111394360**. |
| Shape 18 — `if VAR=$(granted-helper …)` condition-substitution (issue #857) | PERMITTED — run **30310938175** (review `probe` job, 2026-07-27) | The `if`/`elif` command-substitution condition shape is cloud-permitted → **retired desk-lint rule R5** (issue #869). Does not re-permit the shape in `skills/review/**` (the seed is already helper-extracted). |

Positive-control note (issue #477): the review verdict counts a
`permission_denials` match as DENIED **ahead of** `tool_use`, so an unrelated
`/etc/hosts` read (attempted by the model with a `Bash(grep:*)` grant) can make the
row-11 control read DENIED. The sibling probe jobs score their controls
differently and are unaffected.

### `load-prompt-extension.sh` grant surfaces and the Phase-3 dispatch (issue #802)

`load-prompt-extension.sh` is granted **directory-agnostically** — as
`Bash(*/load-prompt-extension.sh:*)` — on the `review` and `command` profiles, and
**by vendored literal only** — `Bash(.prflow/vendor/prflow/scripts/load-prompt-extension.sh:*)` —
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
`Write(.prflow/tmp/**)` PERMITTED live in the step comment. A predicate keyed on the
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

### Dispatched-subagent `Write` into `.prflow/tmp/**` — review tier — PENDING the first PR-triggered run (issue #858)

`.github/workflows/matcher-probe.yml` carries a **`subagent-write-review-probe`** job
that measures whether a **dispatched subagent's** `Write` into `.prflow/tmp/**`
succeeds under the review tier's **generated baseline joined with the `probe` job's own
standing candidate extras** — not the shipped review profile alone, which is why the
record reproduces the resolved literal verbatim rather than describing it. `Write(.prflow/tmp/**)` is granted for
the **orchestrator** (the `Write(.prflow/tmp/**)` grant row in the review-tier evidence table above, PERMITTED from run `29111394360`; the probe exercises it as shape 9), but a grant proven
for the dispatcher is `unestablished` for the **dispatchee** — CLAUDE.md's "Unknown is
not zero". The job is **dedicated** (not a shape row in the `probe` job, whose session
already writes to `.prflow/tmp/probe-09.txt`): its prompt instructs **no orchestrator
write at all**, so a `Write` record in its execution file has exactly one *expected*
author. That single-authorship is a **prompt-level** guarantee, not a technical
restriction — the composed allowlist grants `Write(.prflow/tmp/**)` to the whole
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
`lib/test/fixtures/execution-file-shape.observed.txt`, as that record establishes.

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
[`docs/internal/working-directory-contract.md`](working-directory-contract.md).

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
the working-directory `.prflow/tmp`**, and the interpreter head is denied per issue
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

### Dispatched-subagent `Write` into `.prflow/tmp/**` — implement tier — PENDING the first PR-triggered run (issue #858)

`matcher-probe.yml` also carries a **`subagent-write-implement-probe`** job that measures
the same dispatched-subagent `Write` fact on the **implement** tier — because a shape
proven on the review tier is unproven here (the two are separately-probed allowlists). It
is the structural twin of the review-tier job above: it **consumes** the resolved
implement literal from the `implement-probe` job via `needs:` (never a second `IMPLEMENT=`
assignment), appends `Task,Agent` in its own hand-written `--allowed-tools`, dispatches one
built-in `general-purpose` subagent that writes `.prflow/tmp/subwrite-implement.txt`
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

## Probe evidence (command tier) (issue #1152)

The `devflow.yml` **command** tier — the manual `/prflow:review-and-fix` /
`/prflow:pr-description` PR-comment path — is a **third** cloud allowlist alongside the
read-only `review` tier and the read-write `implement` tier. Before issue #1152 its
HEADS were scanned (run.sh's whole-bundle head scan against `devflow.yml`'s `TOOLS`) but
its SHAPES were not: `lib/test/run.sh` linted the `review-and-fix` bundle under the
`implement` profile as the closest **inferred** proxy, and `matcher-probe.yml` carried no
command-tier job. On run `29854795625` (PR #684) a `prflow:review-and-fix` comment run
took six Phase-0 permission denials, produced no verdict / commits / comment, and still
exited `is_error=false` — every denial a *shape* refusal on the unmeasured tier.

Issue #1152 closes both gaps:

- **Desk lint.** `lib/test/extract-command-shapes.py --profile command` (rule set
  `COMMAND_RULES` = `CR1`–`CR5`) applies the read-write `implement` tier's denied shapes
  remapped to `CR*` ids (`command`-tier denied shapes ⊆ `implement`-tier denied shapes,
  the assumption the old proxy already rested on; the `command-probe` job converts it from
  inference to measurement). `lib/test/run.sh` drives it over the whole `review-and-fix`
  bundle (root + every `references/*.md`) plus the shared review-engine files it executes
  inline, and goes RED when any teaches a command-profile-denied shape. The unexpanded
  `${CLAUDE_SKILL_DIR:-…}` anchor is deliberately **not** a rule (issue #275 / #1124 — its
  argument-position denial is measured by the probe rows below, not modelled statically).
- **Probe job.** `matcher-probe.yml`'s `command-probe` job measures the tier that ships:
  its `--allowed-tools` baseline is a **generated region** (`region=probe-command`)
  compiled from the `command` profile, banner-stamped with its sha256 exactly as the
  `probe-review` / `probe-implement` baselines are, so it can never drift from the deployed
  allowlist.

**This measurement is DISPATCHED-PENDING** — the rows and their generated baseline ship
with issue #1152; the verdicts land on a later `workflow_dispatch` (a verdict is never
written from inference). Version-dependent: re-probe after any `claude-code-action`
upgrade.

| # | Shape | Verdict |
|---|-------|---------|
| 1 | granted vendored-literal helper path as a leading token (`config-get.sh`) | dispatched-pending |
| 2 | resolved (expanded) skill-dir-anchored helper path as a leading token | dispatched-pending |
| 3 | `>` redirect from a granted head into `.prflow/tmp/**` | dispatched-pending |
| 4 | `.prflow/tmp/**` file authored with the **Write** tool | dispatched-pending |
| 5 | `if VAR=$(granted-helper …)` command-substitution condition | dispatched-pending |
| 6 | `;`-joined multi-statement sequence | dispatched-pending |
| 7 | plainly granted single command (positive control) | dispatched-pending |
| 8 | argument-position defaulted anchor expansion `${VAR:-default}` (reproduces run `30695072336`) | dispatched-pending |
| 9 | argument-position bare anchor expansion `${VAR}` | dispatched-pending |
| 10 | argument-position bare expansion of a non-anchor variable (control) | dispatched-pending |

Rows 8–10 are the argument-position rows adopted from issue #1124's closure; their
cross-reading is described in *The `${CLAUDE_SKILL_DIR:-…}` anchor* subsection above.

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

Consequence for the label call sites: `devflow-implement.yml`'s generated
`implement` literal grants `apply-labels.sh` / `ensure-label.sh` explicitly, and
**all four label call sites** — Phase 3.1's `PRFlow` provenance apply, Phase 4.0/4.0.5's
`deferred.labels` applies, and Phase 4.1's `Documented` apply — are reworked to
**agent-level single-leading-token calls that read their inputs from printed tool
output** (a shell variable does not survive into a later separate command).

Row I1 (the unexpanded anchor) is **not lint-pinnable on either tier** — every
legitimate helper call keeps the portable `${CLAUDE_SKILL_DIR:-…}` anchor in
source (#275) and resolves it at runtime — so it stays **prose-discipline**.

---

## Implement-profile head guard + inline-engine surface (issue #484)

Phase 3 of `/prflow:implement` runs the review engine **inline** under
`devflow-implement.yml`'s resolved `--allowed-tools` — the `Resolve allowed-tools`
step's hoisted `TOOLS='…'` output (**not** the review profile) — so
**every helper the normal inline flow can reach needs an implement-profile
grant** — the review engine is shared.

`lib/test/run.sh`'s #484 head guard deliberately **over-approximates** that runtime
surface. It drives `extract-command-heads.py` in the **`tools-line` parse
mode** that reads **ONLY** the workflow's resolved `TOOLS='...'` allowlist line —
never the whole file or `.prflow/config.json`, so a `Bash(...)` cited in a YAML
comment is **not** a grant; it fails **closed** on an absent/duplicated line. (Since
issue #1170 the implement region is hoisted into a `Resolve allowed-tools` step, so
`devflow-implement.yml` carries its allowlist on a `TOOLS='...'` line exactly like
`devflow.yml`/`devflow-runner.yml` — the former bespoke `implement-block` mode is
retired.) It runs over all fenced source in:

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

### The six generated regions

`python3 lib/generate-capability-profiles.py` compiles the manifest into exactly
**six** regions:

1. `devflow-runner.yml`'s **review** `TOOLS='…'`,
2. `devflow.yml`'s **command** `TOOLS='…'`,
3. `devflow-implement.yml`'s `--allowed-tools` **base list** — up to the
   `${{ needs.config.outputs.allowed_tools_extra }}"` splice, which is preserved
   **verbatim** (consumer-facing surface),
4. `matcher-probe.yml`'s `REVIEW='…'` baseline,
5. `matcher-probe.yml`'s `IMPLEMENT='…'` baseline,
6. `matcher-probe.yml`'s `COMMAND='…'` baseline (the `command-probe` job, issue #1152).

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

A bundled helper that a `/prflow:implement` fence invokes — the §4.0.5-class
case, e.g. `scripts/discover-deferral-manifests.py` — is granted by adding its
vendored-literal token
`Bash(.prflow/vendor/prflow/scripts/<helper>:*)` (the **row-I2-proven** explicit
leading-token form) to the `implement` profile in `lib/capability-profiles.json`
and regenerating. That **one edit** rewrites:

- `devflow-implement.yml`'s generated `implement` region — the `Resolve
  allowed-tools` step's `TOOLS='…'` baseline, which `claude_args`'s
  `--allowed-tools` consumes — **and**
- `matcher-probe.yml`'s `IMPLEMENT` baseline

in lockstep — so the probe's baseline can never drift from the tier it is probing —
and the generator's `--check` (driven by
`lib/test/modules/capability-profiles.sh`) enforces it. **Never hand-edit either
workflow literal** to add such a grant.

### Implement-tier repo-internal test grants (issue #789)

**Superseded by issue #1078 (this describes the #789-era state).** These seven tokens
no longer ship in the `implement` profile: they delivered zero benefit in a consumer
(the `vendor-plugin` slice prunes `lib/test`, so none can ever match a PRFlow file
there) while pre-authorizing any consumer file that collided with a PRFlow-chosen
path. Six moved to `.prflow/config.json`'s `prflow_implement.allowed_tools` — the
self-repo-only grant channel (`config.example.json` ships it empty, so no consumer
inherits it): the five `focused_test` targets, plus `coverage_map_guard.py` (still
invoked as a direct leading token by `matcher-probe.yml`'s executable-`.py`-as-direct-leading-token probe row — the `coverage_map_guard.py --iprobe17direct` shape). `test_module_harness.py`
was **dropped** — it is not a `focused_test` target and `lib/test/run.sh` invokes it
only via the `python3 <path>` interpreter head. The paragraphs below are the #789
record, kept for provenance.

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

### Config-supplied helper grants and the repository rename (issue #928, deferred half)

`prflow_implement.allowed_tools` is not a generated literal — the `config` job
extracts it as `allowed_tools_extra` with `jq`, and `devflow-implement.yml`'s
`Resolve allowed-tools` step appends it verbatim to the generated `implement`
region (`${TOOLS}${EXTRA}`), so the one resolved string both `--allowed-tools` and
the grounding block quote carries it. Two path shapes reach it, both **measured
emissions** rather than design choices: cloud implement run **30183387509**
(issue #802) recorded 43
permission denials in which the engine invoked bundled helpers as
`/home/runner/work/<repo>/<repo>/scripts/<helper>` (workspace-absolute) and as
`scripts/<helper>` (repo-root-relative), because `.claude-plugin/marketplace.json`
declares `"source": "./"`, so `$CLAUDE_SKILL_DIR` resolves to `<workspace>/skills/<name>`
and the portable anchor's `/../../scripts/` lands at the repository root, never in the
granted `.prflow/vendor/prflow/scripts/` subtree. Both shapes were granted in
response, for each of the 25 helpers.

**Issue #1049 closed this resolution fidelity gap for the implement tier.** The
observation above — this repo's cloud implement run resolving `$CLAUDE_SKILL_DIR` to
`<workspace>/skills/<name>` while every consumer resolves the same shipped bytes from
`.prflow/vendor/prflow` — meant the shipped `.prflow/vendor/prflow/scripts/` helper-path
shape had **no coverage in this repo** (the #824 fidelity gap): a denial a consumer
would hit was invisible here. `devflow-implement.yml`'s `claude` job now runs an
implement-tier-only `vendor_marketplace` step (`scripts/compose-vendor-marketplace.sh`)
that composes a **job-local** marketplace rooted at `./.prflow/vendor` (plugin `prflow`
sourced at `./prflow`) and swaps the repo-root `./` entry in the composed marketplace
list for it, so this repo's implement run now resolves `$CLAUDE_SKILL_DIR` to
`<workspace>/.prflow/vendor/prflow/skills/<name>` — the **same subtree a consumer
resolves**, so the shipped helper-path shape finally has coverage here and a denial in
this repo is a denial there. The composition is best-effort (always exits 0) and
degrades on an absent/partial vendored tree with a `::warning::` naming `prflow_version`.
The tracked `.claude-plugin/marketplace.json`, the baked marketplace baseline literal,
and the **review/manual tiers** are untouched — those still resolve from the repo-root
`./` and continue to exercise the workspace-absolute / repo-root-relative shapes above.
Per the usual grant timing (#593), the workflow change is **inert for its own PR's
implementing run** and live for subsequent cloud runs (verified post-merge).

**The `./` prefix on the emitted marketplace entry is load-bearing, and it is the one
thing no gate in this repo can check.** `claude-code-action` validates every
`plugin_marketplaces` entry it is handed (`base-action/src/install-plugins.ts`): an entry
is treated as a local path only when it begins with `./`, `../`, `/`, or a Windows drive
prefix, and anything else must match its `^https://….git$` marketplace-URL regex. The
first shipped version of this step emitted the bare relative `.prflow/vendor`, which
matched neither arm, so the action aborted **every** cloud implement run in this
repository with `Invalid marketplace URL format: .prflow/vendor` (PR #1137, reverted
by #1144 forty-six minutes later). That validator executes only inside a real cloud run:
the desk suite, the CI shards, and the review engine all pass a change that breaks it —
#1137 was reviewed clean across four rounds and CI-green with zero skips. This belongs in
the same class as the matcher semantics documented elsewhere on this page: **a runtime
contract with an external action, provable only by a real dispatch.** A change that alters
the inputs handed to `claude-code-action` wants a canary run at merge time. The
normalization now lives in `compose-vendor-marketplace.sh` at the single point that emits
the entry, and `lib/test/run.sh` asserts the emitted value satisfies the action's
local-path predicate — which narrows the gap without closing it, since it re-states the
validator rather than executing it.

**The workspace-absolute literal embeds the repository name twice.** A rename moves
`$GITHUB_WORKSPACE`, every such token stops matching, and — per this tier's defining
property — an ungranted head is **silently denied**. The failure mode is a run that
quietly does less, with no error to read.

The `config` job therefore **re-anchors** that prefix onto the live
`$GITHUB_WORKSPACE` before splicing, the same transform `matcher-probe.yml` applies
to its own baseline. The transform is a **no-op today** (the workspace already equals
the literal the tokens carry), rewrites only GitHub's hosted-workspace shape (a
deliberate `Bash(/usr/local/bin/foo:*)` grant is untouched), and selects an identity
branch on an empty workspace rather than emitting a root-anchored token that would
match nothing. `lib/test/run.sh` drives the jq program **extracted from the workflow
itself**, so the assertions cannot drift from the shipped expression.

**Evidence status of the two shapes — neither grant form is probe-proven.** Read this
before citing them:

| Grant form | Probe status |
| --- | --- |
| `Bash(.prflow/vendor/prflow/scripts/<helper>:*)` — vendored literal | **PERMITTED**, implement-tier **row I2**, leading-token position |
| `Bash(<workspace-absolute>/scripts/<helper>:*)` | **Unmeasured.** No implement-tier row exercises it. The review tier's absolute-path row (shape 13) is **unrecorded**. |
| `Bash(scripts/<helper>:*)` — repo-root-relative, explicit exact path | **Unmeasured.** No row at either tier grants the exact path and exercises it. Review shape 15 measured the *glob* `Bash(scripts/*.sh:*)` as DENIED (run 29135163829); review shape 14 is the *ungranted* control. Neither measures an explicit exact-path repo-root grant. |

Row I2 is about the **vendored-literal** form and must not be cited as evidence for
either of the other two. The two config-supplied families are a hedge placed in
response to a measured denial, not a measured grant — the re-anchoring above keeps
the absolute family alive across a rename precisely because the relative family
cannot be relied on to cover for it. Closing the gap needs two `implement-probe`
rows (an explicit exact-path repo-root grant, and a workspace-absolute grant), each
exercised as a leading token; until such a dispatch is recorded, treat both as
`unestablished`.

### The install.sh-vs-vendor-fetch skew warning

The **workflow grants** ship to consumers via `install.sh` **file-copy**, while the
**skill rework** ships via the `prflow_version` **vendor fetch**. These are **two
independently-updated artifacts** whose skew silently **re-denies the applies**, so
**the two halves must be upgraded together** (docs: `docs/internal/install.md`,
`docs/internal/DEVFLOW_SYSTEM_OVERVIEW.md`).

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

**Registration shipped (#908), but the guard is inert because its delivery tier lost its
caller (#936).** What is shipped is the guard body, its unit coverage, its hardening from
the trusted base ref, and — under #908 — the review-tier registration itself:
`devflow-runner.yml`'s "Run Claude Code" step carries a `settings:` input that registers a
`PreToolUse` / `Bash` hook resolving `pretooluse-shape-guard.py` at the vendored path
(with a repo-root fallback) and failing open — exit 0 — when neither copy exists. That
registration is made safe by the **unconditional** `Harden PreToolUse guard closure`
step (`harden_guard`), which materializes a trusted-base copy of the guard so no PR-head
copy of it can execute in the secrets-bearing review job; membership of the guard's path
in the `#458` `HOOK_TARGETS` closure alone is **not** that mechanism, because
`harden_hooks` can skip entirely.

The **second** registration channel — a `PreToolUse` key in the committed
`.claude/settings.json` — is deliberately still absent, and by design rather than
oversight: the harness denies agent writes under `.claude/`, so #908 records it under
"Maintainer prerequisite (NOT an acceptance criterion)" and instructs an implementing run
to neither attempt it nor report Blocked on it. So it is **not** the case that the two
channels must land together; the shipped state is exactly one of them, intentionally.

The guard is nevertheless inert on `main` — but the reason is the delivery tier, not the
registration. `devflow-runner.yml` declares `workflow_call:` as its sole trigger, and its
only caller, `devflow-review.yml`, was deleted under #936 (which withheld the automatic
pull-request-triggered review tier), so no workflow in the tree invokes it; the `settings:`
registration rides on a reusable workflow that nothing calls. Whether to wire the guard
onto a live tier (`devflow.yml` / `devflow-implement.yml`) or to accept it as
retained-but-inert alongside the withheld tier is a separate open decision (#919) that is
not settled here. Because the tier cannot run, every runtime behavior described below is
the guard's implemented contract, not observed behavior.

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
| `R3-tmp` | a `>`/`>>` redirect targeting `/tmp` | author the file with the Write tool under `.prflow/tmp/`, or stream through a pipe into `tee` |
| `R4` | an interpreter head (`python3/python/node`) | invoke the helper directly by its granted path as the command's **leading token** |

**Excluded arms (a runtime deny is terminal, so denying a permitted shape costs the
engine a working shape):** `R2` (a leading `cd`, DROPPED as unproven/confounded — probe
row 3) and `R3-heredoc` (an in-workspace `cat`-headed heredoc write, banned as authoring
discipline, not a probe result). The guard **defers** these.

### PreToolUse probe evidence (Part 1)

**The probe arm shipped under #908.** `.github/workflows/matcher-probe.yml` carries a
`pretooluse-probe` job that registers its own ad-hoc `PreToolUse` / `Bash` hook via a
`settings:` input and writes a `pretooluse-probe-fired` marker. It is designed to
establish, by observation, whether a `PreToolUse` hook fires under `claude-code-action`
(`FIRED`/`NOT-FIRED`) and whether its `permissionDecisionReason` reaches the engine
transcript (`REASON-DELIVERED`/`REASON-ABSENT`).

Filling the table below is **#919's** job, not this section's, and that issue — not
this page — holds the current record. Two things a reader should take from it rather
than from the row's placeholder. First, the arm is **not** awaiting a dispatch to
produce a first result: #919 records it as having already returned the same verdict
pair on repeated same-repo `pull_request` runs, together with the scope note that keeps
the pair from misleading (the probe's own hook emits `permissionDecision: "allow"`, for
which `permissionDecisionReason` is specified to be ignored, so the guard's `deny`-path
reason delivery remains unmeasured). Second, #919 has **dropped** the once-planned
per-arm review-run denial count against the run-30138268273 baseline as no longer
achievable — no live tier can produce a review run carrying the guard — retaining that
baseline run id only as historical reference. The row is left as found until #919 lands.

| Probe run id | Firing verdict | Reason-delivery verdict | Per-arm denial counts (review run) |
| --- | --- | --- | --- |
| _(pending post-merge dispatch)_ | — | — | — |

## Denial-population audit — the 2026-08-02 implement runs (issue #1135)

**This section is a past-time observation of two specific runs, not a re-derivable
figure.** The counts and command entries below were read once, on 2026-08-02, from the
`claude`-job execution-diagnostics detail blocks of two cloud implement-tier runs. They
are **not** machine-rendered and must not be "corrected" or re-measured later — a run's
diagnostics block is immutable history, and a different run would show a different
population. That immutability covers the **observations** (the counts, the entries, and the
entry indices), not the **classification**: the cause and disposition assigned to an entry
are ordinary claims, correctable on evidence like any other. Probe-based *shape* conclusions
are not made here; they belong to
`matcher-probe.yml` — and where a refusal is shape-level but no already-documented shape
rule covers it, the property is left **unestablished** rather than inferred. This audit
reads the denials, names each entry's cause, and records one disposition per cause.

Source runs (both cloud implement tier, 2026-08-02):

- **Run 30738761826** (issue #1073) — block opened `51 permission denial(s) with detail:`;
  the run recorded `"num_turns": 228` and ended Blocked. The work in flight was a
  `scripts/provision-local-settings.sh` change, and most denials are the agent's
  ad-hoc verification probes of that script (running it in temp dirs, diffing its output).
- **Run 30738987528** (issue #1085) — block opened `9 permission denial(s) with detail:`;
  the run ended with a green pull request.

**How every grant-state claim below was established.** Each "granted" / "not granted"
statement in this section was read from the *run's own* resolved allowlist — the
`--allowed-tools` string in that run's `claude` job log, which is the list the matcher
actually applied (both runs resolved 210 tokens). That is deliberately not a citation of a
commit or of the tree as it stands now: the grant channel is trigger-time-resolved from the
default branch, so today's tree is not what a past run had, and a SHA decorating a grant
rots.

Grant-state context that keeps the dispositions honest: run 30738761826's own resolved
allowlist already carried `Bash(bash:*)` and `Bash(mktemp:*)`, yet `bash -c`- and
`mktemp`-bearing commands still appear in its denial block. That is the load-bearing
observation of this audit: **the population is dominated by deliberately-denied composite
*shapes* (a leading `cd`, a heredoc write, a leading assignment, a `/tmp`/file redirect, an
interpreter head, a background launch), which the matcher refuses regardless of whether
every head in them is granted.** Granting more heads would not have prevented them.

**A granted head is not a permitted command, and the two are separate findings.** The
diagnostics block names the refused command and nothing else — it carries no per-denial
reason string. So an entry is recorded as an **ungranted head** only when a head or leading
literal in it was absent from that run's resolved allowlist. When *every* head and literal
in an entry was present, it is recorded as a **shape refusal**; and when no already-
documented denied shape covers it, the specific property the matcher refused is recorded as
**unestablished** rather than replaced with a plausible guess.

### Named causes and dispositions

Every disposition is drawn from the issue's closed set of three — a prompt-surface
correction, a manifest grant, or a recorded "no change" carrying its reason. **The audit
reaches no new grant and no prompt-surface correction: every cause is dispositioned "no
change."** One of those "no change" rows records that the grant its entries called for
landed independently (issue #1132) — not that the head should stay ungranted. The reasons
follow.

In the *entry indices* column, **A** is run 30738761826 and **B** is run 30738987528, and
each number is the 1-based position of that entry within the run's detail block. The
indices partition every entry of both runs (A: 1–51, B: 1–9); each row groups the entries
by the construct the agent typed, and the two rows where that grouping does not coincide
with the refusal cause say so and split their entries explicitly.

| Cause | Runs / entry indices | Disposition |
| --- | --- | --- |
| **Heredoc write** (`cat > <file> <<'…'`) | A: 1,2,3,4,20,21 | **No change.** A heredoc redirect write is a deliberately-denied shape (#401); the authorized alternative — the Write tool — is already documented. No prompt surface authors a **`cat`-headed heredoc write** — the `R3-heredoc` shape above, which is the one these six entries are. The qualifier is load-bearing: surfaces *do* author heredocs, but they feed command substitution or stdin rather than a file redirect (`BODY=$(cat <<EOF … EOF)` in `skills/implement/phases/phase-3-review.md`; the `--body-file -` and `--ledger-stdin` heredocs in `skills/create-issue/references/`), and the one file-authoring heredoc they sanction is the `tee <file> <<'EOF'` form (`skills/review/SKILL.md` Phase 0.3.5), a different shape from the `cat`-headed redirect these six entries are — note this page transcribes **no** per-row probe verdict for it (shape 6), so it is cited here as the form the surfaces author, not as a measured permission. Granting the `cat`-headed form would defeat the shape ban. |
| **Leading `cd`** | A: 5,6,7,22,23,24,25,26,27 | **No change.** The working-directory contract already bans a leading `cd` (desk lint `IR4`, issue #855); the persistent cwd makes it unnecessary. Agent-improvised; no surface authors it. |
| **Leading `VAR=` assignment / env prefix** | A: 11,12,13,14,15 · B: 3 | **No change.** A leading assignment is the R1/PreToolUse-guard denied arm; the documented alternative is `VAR=$(cmd)` or passing the value as an argument. Agent-improvised. |
| **`bash <path>` / `bash -c` wrapper** | A: 10,17,18 | **No change.** The `bash <path>` wrapper is deny-floored by policy and documented; helpers are invoked as leading tokens. `Bash(bash:*)` was in the run's own resolved allowlist yet these still denied — confirming the refusal is the wrapping shape, not the head. |
| **`nohup … &` background launch** | A: 36,37,38,39 | **No change.** These carry both defects: `nohup` is absent from the run's resolved allowlist (an ungranted head) *and* a background launch is a denied shape. The coordinator `lib/test/run-parallel.sh` is documented to run as a bare leading token "with nothing around it"; backgrounding it is agent improvisation, and the extension already states the correct form. |
| **Interpreter head** (`python3 …`, `python3 -c`) | A: 8,34,35,42,43,44 | **No change — and no grant was missing.** `Bash(python3:*)` *was* in the run's own resolved allowlist, so none of these six is an ungranted head; each additionally carries a caller-side redirect (A: 8 also writes under `/tmp`). They are therefore the cleanest evidence in this population for the head-versus-shape distinction above: the `python3 <path>` interpreter head is refused by shape (#789/#401) with the head granted. The authored form is the executable `.py` as a direct leading token — `scripts/workpad.py`, itself granted in this same run. |
| **stdout/file redirect** (`> <file>`, `> /tmp/…`) | A: 9,46 | **No change.** A caller-side redirect is denied even into `.prflow/tmp` (PR #694); the Write tool is the authorized path and is documented. Agent-improvised. |
| **Ungranted at run time, granted since — `lib/test/run-shard.sh`** | A: 33,50,51 | **No change by this audit — the grant these entries called for has already landed.** The head was absent from run 30738761826's own resolved allowlist, so these three were genuine ungranted-head refusals *at run time*. It does not follow that the absence was correct: `.prflow/prompt-extensions/implement.md` in that run's own checkout already named `lib/test/run-shard.sh --list-shards`, so there was an authored caller and no grant — precisely the grant-timing case that extension itself describes. Issue #1132 subsequently granted `Bash(lib/test/run-shard.sh:*)` in both `prflow_implement.allowed_tools` and `prflow.allowed_tools`, and `CLAUDE.md`'s cloud-implement tier section names its durable caller: decomposing the partition through the shard dispatcher when the tier's per-command execution ceiling terminates the coordinator. So this audit adds no grant because the right grant already exists — not because the head should stay ungranted. |
| **Ungranted head — `git write-tree`** | A: 31,32,41 | **No change.** Absent from the run's own resolved allowlist, so a genuine ungranted head. A one-off introspection of the git tree with no authored caller; the run needs no tree hash. |
| **Granted head, shape refusal — `git diff <sha> <sha> -- …`** | A: 30 | **No change — and not an ungranted head.** `Bash(git diff:*)` was in the run's own resolved allowlist. The fence carried a caller-side `>` redirect into `.prflow/tmp`, a `\|\| true`, and a `\| wc -l` tail — a denied redirect shape inside a compound, so no grant would have permitted it. It is still an ad-hoc historical diff no surface authors. |
| **Granted head, shape refusal — `awk`** | A: 16 | **No change — and not an ungranted head.** `Bash(awk:*)`, `Bash(grep:*)` and `Bash(head:*)` were all in the run's own resolved allowlist. The entry is a `;`-joined compound of a pipeline; which property the matcher refused is **unestablished** (no per-denial reason is recorded). No grant would have changed the outcome, and a granted alternative for a one-off source scan was already available in a permitted shape (the `Grep` tool, or `grep` on its own). |
| **Ungranted head — `gh auth status`** | B: 5,6,9 | **No change.** `gh auth` is absent from run 30738987528's own resolved allowlist. A credential-state debugging probe; no prompt surface calls it, and granting an auth-introspection subcommand serves no durable caller. |
| **Mixed diagnostic probes — two ungranted heads, two shape refusals** (`cat`/`ls` of `/tmp`, `git remote`/`git status` via `echo`/`printf`, `export`) | A: 19,28,29,40 | **No change**, but the entries do not share a cause. A: 28 reaches `git remote` and A: 29 leads with `export`; neither is in the run's resolved allowlist, so those two are ungranted heads. A: 19 and A: 40 use only granted heads (`cat`, `ls`, `head`, `printf`, `git status`), so those two are shape refusals whose **specific** refused property is **unestablished** — both are `;`-joined compounds of pipelines, and A: 19 additionally *reads* under `/tmp`, but the recorded `/tmp` rule (`R3-tmp`) is about a redirect *target*, so applying it to a read would be an inference. Environment/state introspection the agent improvised either way; the authorized diagnostic surfaces (`preflight.py`, `config-get.sh`) already exist and were granted. |
| **Bare `scripts/…` leading path — one ungranted literal, two shape refusals** | A: 47,48,49 | **No change**, but these three do not share a cause either. A: 47 names `scripts/efficiency-trace.sh`, which is neither a granted literal **nor a file** — the helper lives at `lib/efficiency-trace.sh`, which *was* granted in this run; because grants are per-head across the whole pipeline, the fence's own `\|\| lib/efficiency-trace.sh --persist` fallback could not rescue the statement. A: 48 (`scripts/react-to-trigger.sh`) and A: 49 (`scripts/workpad.py`) name literals that **were** in the run's resolved allowlist as bare `scripts/<name>` forms, so neither is an ungranted head: A: 49 carries a `> /tmp/…` redirect, a documented denied shape, and A: 48's refused property is **unestablished** (every head in its `\| tail -2 \|\| echo …` tail was granted too). No grant is warranted — the one non-granted literal names a path that does not exist. |
| **`./scripts/…` dot-slash prefix** | B: 1,2,8 | **No change.** The `./` prefix makes the path a different literal than the granted form — `Bash(scripts/apply-labels.sh:*)` *was* in that run's resolved allowlist, so this is a spelling difference, not a missing grant. The surfaces author no `./` prefix; agent-improvised. |
| **`for … do … done` loop** | B: 4 | **No change — and not an ungranted head.** Every head in the loop body (`echo`, `grep`) was in that run's resolved allowlist, so this is a shape refusal. The **specific** refused property is **unestablished**: the recorded denied-loop evidence (probe rows I4/I5, desk rules `IR1`/`IR2`) is scoped to a loop whose body invokes a *label helper* by name, which this loop does not, so citing it here would be an inference, not a measurement. Dispositioned "no change" regardless: agent-level iteration is the authored alternative and no surface authors this loop. |
| **Multiline `--body` argument** (`gh pr create --body "…\n…"`) | B: 7 | **No change — and not an ungranted head.** `Bash(gh pr create:*)` was in that run's resolved allowlist, so the refusal is the argument shape: a body string spanning lines reads to the matcher as multiple statements and denies. The shipped Phase 3.1 CREATE fence does **not** author that shape, and not by using `--body-file` either — no `--body-file` appears on the PR-create path anywhere in `skills/implement/`. It composes the body into a variable with an unquoted `cat <<EOF` heredoc and passes `--body "$BODY"` (`skills/implement/phases/phase-3-review.md`), which is a single-line `gh pr create` at author time and so is not the denied inline-multiline-literal shape. The agent improvised both the inline multiline literal and the omission of the fence's `--base "$BASE"`, and the run then created the PR successfully. Nothing to correct on the surface: the authored form was already a permitted one. |
| **Surface-authored best-effort `rm` cleanup** (run-marker/cache removal, command-substitution path) | A: 45 | **No change — and not an ungranted head.** Every head in it (`rm`, `git rev-parse`, `echo`) was in the run's own resolved allowlist, so no grant was missing and this is a shape refusal. The **specific** refused property is **unestablished** — the fence carries `$(...)` command substitution in argument position and a `;`-joined tail, and neither is a shape this page records as denied (shape 18 in fact records command substitution PERMITTED in *condition* position at the review tier), so naming one would be an inference. This one *is* authored by `SKILL.md` (the Outcome-reaction run-marker/issue-body-cache removal) and is explicitly best-effort (`2>/dev/null \|\| true`), so its denial is absorbed by design — the local Stop-hook guard self-heals a stale marker and a leftover cache file is inert (reads are hand-off-only). Nothing to grant and nothing to correct. |

**Per-cause coverage is complete by construction:** the entry indices above partition all
51 entries of run 30738761826 and all 9 of run 30738987528 (60 total). Rows are grouped by
the construct the agent typed; two of them are explicitly **mixed** (the diagnostic probes
and the bare `scripts/…` paths) and name which entries fall to which cause, because
grouping by typed construct and grouping by refusal cause do not coincide there. Where an
entry carried more than one denied property (e.g. an interpreter head *and* a redirect),
it is filed under its leading authored construct, which is the property a prompt surface
would be responsible for; the co-occurring property is noted in the cause's reason where it
matters.

### Why the audit ships no new grant and no surface correction

The two runs differ starkly — 51 denials versus 9 — but the difference is *volume of
agent-improvised verification*, not a missing grant. Run 30738761826 spent 228 turns
iterating verification probes on a shell script under classifier friction (the exact
situation the implement extension's "Verification under classifier friction" section
addresses with the authorized `python3 -c "subprocess.run(...)"` wrapper and the Write
tool). Exactly one of the 60 entries was **typed in a form a prompt surface authors** —
A: 45's best-effort `rm` cleanup — and it is authored *correctly*: the fence is explicitly
tolerant of its own failure, so its refusal changes nothing and calls for no edit. The
criterion is the **typed command**, not the helper it names, and four further entries sit
close enough to be worth naming: A: 47, A: 48, A: 49 and B: 7 each reach for a helper or
subcommand some surface does author, yet each was typed in a form no surface authors — a
bare `scripts/…` leading path where the surface anchors the helper path, a `| tail` or
`> /tmp` tail the surface has no equivalent for, or, at B: 7, an inline multiline `--body`
literal in place of the fence's heredoc-composed `--body "$BODY"`. In every one of them the
refused property is the agent-introduced part, so no surface has a shape to correct.
**Exactly one cause was a head with a durable authored caller** — the shard
dispatcher — and that grant has already landed independently through issue #1132, so this
audit has none left to add. Every other ungranted head is one-off introspection
(`git write-tree`, `git remote`, `gh auth status`, `export`) or a path that does not exist
(`scripts/efficiency-trace.sh`); granting those, or defeating the deliberately-denied shape
family, would widen the profile against its own discipline. The correct, principled
disposition for this population is the recorded "no change," which this section is.

## `git -C <path> <subcommand>` is a refused form — run 30832631347 (issue #1221)

**This subsection is a past-time observation of one run, not a re-derivable figure.** The
counts below were read once from the `permission_denials` array of the
`claude-execution-transcript-30832631347-1` artifact published by cloud implement-tier run
`30832631347` (issue #1196). That array carried **42** refusals across the run's `194`
turns. It is immutable history: a different run would show a different population, so these
figures are never "corrected" or re-measured.

`git -C <path> <subcommand>` was the single largest cause in that population — **15 of 42**
refusals, **13** of them emitted by dispatched review subagents rather than the top-level
run. It is refused as a *shape*, like a leading `cd` before it (the working-directory
contract bans a leading `cd` as an authoring rule — see *Leading `cd` and the working-directory
contract* — while `git -C` is matcher-refused): the run begins at the
repository root and the Bash tool's working directory persists across calls, so the path
argument is never needed.

**Why it cannot be granted.** Every git grant in `lib/capability-profiles.json` names a
subcommand — `Bash(git rev-parse:*)`, `Bash(git show:*)`, and so on. In
`git -C /path rev-parse …` the token after `git` is `-C`, so no subcommand token matches;
the only token that would is `Bash(git -C:*)`, which matches **every** git subcommand behind
a `-C`, including the write subcommands the read-only review profile's lock
(`lib/review-profile.tokens`) exists to exclude. So the correct disposition is
documentation, not a grant — consistent with the #1135 audit's model, and with the fact that
no prompt surface authors the `git -C` form (it was agent improvisation).

**The permitted alternative.** Because the cloud tiers begin at the repository root and the
Bash working directory persists across calls, the bare `git <subcommand>` form (`git diff`,
`git show <ref>:<path>`, `git log`) is the one to emit — run from where you already are, with
no `-C` path argument and no leading `cd`. This is the same alternative the grounding block's
denied-shape list (`scripts/render-grounding-block.sh`) and the review-agent definitions
(`agents/*.md`) now name, so an agent told not to `cd` no longer reaches for `git -C` and
lands on an undocumented refusal.
