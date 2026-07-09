# DevFlow workflow trigger surface

How the DevFlow GitHub workflows decide *when* to run, *which* one runs, and how
duplicate `/devflow:implement` commands are collapsed. The codebase is the
source of truth — this doc records the *why*.

## Which workflow fires on what

| Workflow | Commands | Listens on |
|---|---|---|
| `devflow.yml` (light path) | `/devflow:review`, `/devflow:review-and-fix`, `/devflow:pr-description` | `issue_comment[created]`, `pull_request_review_comment[created]`, `pull_request_review[submitted]` |
| `devflow-implement.yml` (heavy path) | `/devflow:implement` | `issue_comment[created]` |
| `devflow-review.yml` | automated review | PR lifecycle + `check_run[rerequested]` + `workflow_run`/`check_suite` `[completed]` + `status` (CI-completion re-trigger for deferred reviews — `status` covers legacy commit-status-only CI, filtered to a green state; see the preconditions note in `DEVFLOW_SYSTEM_OVERVIEW.md` §14; the `workflow_run` `workflows:` list must name the repo's CI workflows) |

Both command listeners run `claude-code-action` in **agent mode** with a
synthesised prompt, so they need no `@claude` phrase. Every gate `if:` branch
also negates `@claude` and (for the light path) `/devflow:implement`, so a given
comment routes to exactly one listener and never collides with Anthropic's stock
`claude.yml`. This is the *partition invariant*, enforced by tests in
`lib/test/run.sh`.

**The heavy path is issues-only.** Unlike the light path — which is intentionally
PR-aware (`/devflow:review` / `/devflow:pr-description` act on a PR) —
`devflow-implement.yml` listens **only** on `issue_comment[created]` and never on
the PR-only review events. Because a PR comment is *also* an `issue_comment` in
GitHub's API, the gate `if:` additionally requires
`github.event.issue.pull_request == null`, and `scripts/resolve-implement-trigger.sh`
re-checks via an `IS_PULL_REQUEST` signal and declines before authorization — so a
comment on a pull request never starts an implement run, whatever its body text.
This is what stops the weekly retrospective's audit-report comment (which quotes
the literal `/devflow:implement` phrase in prose) from self-triggering on the
state PR.

## Automated review (`devflow-review.yml`): trigger + preconditions policy

The automated reviewer runs `/devflow:review` as a **required** status check on a
PR. Its trigger policy (issue #304):

- **First review — exactly once per PR.** The first review auto-triggers on
  whichever of `{opened non-draft, reopened non-draft, ready_for_review}` fires
  first, gated to exactly-once by a check-existence query (`precheck` skips when a
  `Devflow Review` check that actually ran already exists on the head or any
  commit). A `synchronize` (new commit on an open PR) re-reviews the new HEAD when
  it carries no already-passing check, so the required context is never missing.
- **Preconditions (both default-on, config-gated).** Before a review fires,
  `scripts/derive-review-preconditions.sh` evaluates two gates: `require_up_to_date`
  (the PR branch must not be **behind its base**) and `require_ci_green` (every
  *other* CI signal on the head must have completed without failing). For the
  Actions-runs signal, the non-self runs are first **collapsed to the latest run
  (highest `run_number`) per `(workflow_id, event)` group**, so a superseded run —
  an approval-gated re-dispatch, a double-fire, a cancelled sibling — never gates
  the review once a newer run of the same workflow+event exists (a run missing a
  numeric `workflow_id`/`run_number` or a string `event` fails closed as
  *unverifiable*). When a gate
  is unmet the review is **deferred**, not run: a neutral "waiting" `Devflow Review`
  check is posted so the required context is present but non-blocking (a neutral
  required check does not block merge — pair it with branch protection's "require
  branches up to date" if staleness must hard-block). A surviving run awaiting
  manual approval (conclusion `action_required`) defers with the distinct reason
  `ci-approval-required`, and `devflow-review.yml`'s `create_check` title arm maps
  it to the plain-language neutral check **"Devflow review waiting: CI approval
  required"** rather than the opaque "other CI not green".
- **CI-completion re-trigger.** A review deferred behind `require_ci_green` (or
  `require_up_to_date`) auto-re-fires once the PR becomes reviewable — via the
  `workflow_run` (Actions CI) and `check_suite` (external CI) `completed` events,
  or a `status` event (legacy commit-status-only CI — classic Jenkins, legacy
  CircleCI — reporting via the commit-status API, which emits neither of the
  other two; filtered to a green `state == 'success'` before a runner spins, and
  resolving the PR from the status head SHA since its payload carries no PR ref) —
  with no manual Re-run. Note the `status` trigger is **unconditional**: GitHub
  offers no context/branch scoping for it, so it fires for *any* commit status
  from *any* app (Codecov, Vercel, external bots), not only legacy CI — an
  Actions-CI repo that also has a status-posting app therefore spins a precheck
  runner per green status. Once a review already exists for the head each
  redundant spin no-ops after a couple of read calls (PR resolution + the
  exactly-once gate, which short-circuits before the expensive precondition and
  review work). A status arriving *before* sibling CI has completed instead
  re-enters the preconditions — several `gh api` reads that fail closed to
  *defer* on a rate-limited token — so a heavy status burst in that pre-review
  window could spuriously defer an otherwise-reviewable PR (bounded to the
  pre-review window; the exactly-once gate ends it once a review lands). This is
  the accepted cost of an unconditional trigger. `workflow_run` **requires an
  explicit workflow-name list**
  (a GitHub platform constraint — no wildcards): it ships as `workflows: [CI]`, so
  **a consumer repo whose CI workflow is named anything other than `CI` must add
  that name to the `workflow_run:` list in `.github/workflows/devflow-review.yml`
  when installing**, or the CI-completion re-trigger silently never fires for a
  deferred review (the installer prints a reminder to this effect; see also
  `docs/cloud-setup.md`). The precondition *evaluation* itself stays fully generic
  (no job names).

### Known limitation: a behind-base deferral is not re-evaluated when the base advances

A `require_up_to_date` (behind-base) deferral clears only when the review is
re-evaluated, and the re-evaluation triggers are all **head-scoped**: a new commit
pushed to the PR branch (`synchronize`), a CI workflow completing for the head
(`workflow_run` / `check_suite`), a legacy commit-status transition for the head
(`status`), or a manual **Re-run**. There is **no
push-to-base listener** — advancing the *base* branch (which is what actually
makes a behind-base PR fall further behind, or, after the PR rebases elsewhere,
could clear it) does **not** by itself re-evaluate the deferral. So a PR deferred
as "branch behind base" whose base moves but whose head is untouched stays in the
neutral "waiting" state until its branch is updated or its check is Re-run. This
is accepted: a behind-base neutral check does not block merge, updating the branch
(the action that actually resolves being behind) fires `synchronize` and clears
it, and the Re-run button is always available. Once the workflow-hardening
follow-up ships the summary pointer, the waiting check's deferral summary will
point operators here.

## Triggers fire on real comments only — never on descriptions

A `/devflow:*` phrase placed in an **issue or PR description (body or title)**
must never start a run — only a genuine comment or review can. This is why
neither command workflow listens on the `issues` event, and why each gate's
`TRIGGER_TEXT` is sourced solely from `github.event.comment.body` /
`github.event.review.body` (never `issue.body` / `issue.title`). Quoting a
command while *describing* a bug or feature is therefore safe.

Note: opening a PR does not trigger anything either — neither workflow listens
on `pull_request[opened]`, so a PR description is never a trigger source.

The partition tests assert all of this: no `issues:` event, no
`contains(github.event.issue.body|title, …)` in any gate, and no `issue.body` in
`TRIGGER_TEXT`.

## DevFlow's own workpad comment can't self-trigger `/devflow:implement`

The `/devflow:implement` orchestrator maintains one marker-tagged **workpad**
comment per issue (see `scripts/workpad.py`), and that comment quotes the literal
phrase `/devflow:implement` (e.g. its seeded `/devflow:implement run started`
note). Because the comment is posted by an allowed bot, it would otherwise re-enter
the gate as a fresh `issue_comment[created]` event and fire a duplicate run on its
own thread.

`scripts/resolve-implement-trigger.sh` closes this with a **self-trigger guard**
that runs *before* authorization and number resolution: it declines any
`TRIGGER_TEXT` that *contains* the effective workpad marker. The check reads:

- The marker comes from the `SELF_COMMENT_MARKER` env var, defaulting to
  `<!-- devflow:workpad -->` when unset/empty — the same fallback `workpad.py`
  uses, so the guard protects a repo with no config exactly the same.
- It is a literal **substring** match (`case "$text" in *"$marker"*`), not a
  regex, so a marker customized with regex-special characters still matches
  literally, and a marker quoted/embedded anywhere in the body is still caught.
  This is deliberately broader than `workpad.py`'s own marker check, which only
  matches with `startswith`.
- On a match the gate emits `should_run=false` (with an empty `number`) and logs a
  `::warning::`, regardless of actor or which command phrase the body quotes.

> **Workflow wiring.** Passing `SELF_COMMENT_MARKER` into the resolver's
> environment (and exposing a `workpad_marker` config output) lives in
> `.github/workflows/devflow-implement.yml`, and is **applied as shipped** — the
> config job extracts `devflow.workpad_marker` (defaulting to the built-in
> `<!-- devflow:workpad -->`) and the gate passes it to the resolver. So both the
> **default** marker and any repo-customized `devflow.workpad_marker` are protected
> out of the box, with no manual edit required.

## A light `/devflow:*` command fires only when *issued*, never when *quoted*

The light command path (`/devflow:review`, `/devflow:review-and-fix`,
`/devflow:pr-description`) is intentionally **PR-aware** — a PR comment is also an
`issue_comment` in GitHub's API, and these commands act on a PR — so unlike the
issues-only heavy path it *retains* PR-comment and PR-review triggering by design.
Removing that surface would break the primary use case. The bug it must avoid is
different: a command **quoted in prose** (a human review that says "as
`/devflow:review` flagged…", DevFlow's own review narrative, an un-markered report
body) must not be mistaken for the command being *issued*. A quoted
`/devflow:review` inside a PR **review** body was the reported self-trigger vector.

Two mechanisms close this, both living in `scripts/resolve-command-trigger.sh`
(the authoritative gate; the workflow `gate` `if:` stays a coarse `contains()`
pre-filter):

1. **Anchoring (the core fix).** A light command is a trigger **only** when it is
   the sole content of its own line — it begins the line with at most three
   leading spaces (never a tab, never four-plus, so an *indented* code block never
   qualifies), it is **not** inside a fenced (triple-backtick / `~~~`) code block,
   and the remainder of the line is at most an optional `#`-prefixed number plus
   trailing whitespace. So `/devflow:review`, `/devflow:review 42`, and
   `/devflow:review #42` fire (alone on their line, even inside a longer body);
   `please run /devflow:review`, a `> /devflow:review` blockquote, an indented or
   fenced `/devflow:review`, and `I ran /devflow:review earlier` do **not**. The
   scan is a small **markdown-aware line scanner** (`scripts/detect-standalone-command.sh`,
   POSIX `awk`, ERE only) that tracks fenced-block state, skips indented-code
   lines, and applies the anchored own-line match most-specific-first
   (`/devflow:review-and-fix` outranks `/devflow:review`). It is deliberately
   **fail-closed on an unbalanced fence**: after an unclosed opening fence every
   following line reads as code and fires nothing — matching how GitHub itself
   renders an unbalanced fence, and the safe direction for a self-trigger fix. It
   approximates GitHub-flavored markdown (not a full CommonMark parser): it does
   not model list-relative indentation, so a command deeply indented inside a list
   item is treated as code and does not fire — an over-exclusion that still errs
   toward not-triggering.

2. **Self-marker guard (defense-in-depth).** Mirrored from
   `resolve-implement-trigger.sh`, the resolver additionally declines — *before*
   authorization — any body that carries a DevFlow self-comment marker: the
   run-keyed review-progress marker **prefix** `<!-- devflow:review-progress` (the
   review engine's live progress comment, whose narrative naturally quotes
   `/devflow:review` — see `scripts/derive-review-verdict.sh`) or the workpad
   marker `<!-- devflow:workpad -->`. Each is a literal **substring** match, and
   the effective markers **default to those built-in values internally**, so the
   guard protects a repo with no extra workflow wiring. Note this guard alone was
   insufficient for the reported vector — the PR-review body carried no marker —
   which is why anchoring is the necessary core and the marker guard is retained
   only for DevFlow's own progress comment.

Because anchoring operates on the resolver's `TRIGGER_TEXT` input, it is
**surface-agnostic**: the workflow's existing
`TRIGGER_TEXT: ${{ github.event.comment.body || github.event.review.body }}`
wiring already routes the PR-review body in, so no new surface wiring is added.

> **Landed (issue #321):** the `review_dedupe` job in `devflow.yml` now routes
> through the **same** `detect-standalone-command.sh` detector (not its own
> `case` substring), so a quoted/documented `/devflow:review` mention neither
> dedupes nor posts a "manual review suppressed" notice and the two matchers are
> a single source of truth that cannot drift. Because that change edits a file
> under `.github/workflows/`, it needed a `workflows`-scoped push the DevFlow
> bot's installation token lacks, so it landed via a human/PAT in the #321
> follow-up rather than in the bot-authored PR that shipped the resolver
> anchoring here.

> **Out of scope (decided):** a light command posted on a plain **non-PR issue**
> comment still resolves a number and runs; narrowing that surface is deferred to
> a separate issue. This section covers only the markdown-aware anchoring and the
> self-marker guard.

## A `/devflow:implement` run posts exactly one comment — the workpad

A run maintains a **single** GitHub comment, the marker-tagged *workpad*
(`scripts/workpad.py`). It is both the immediate "job started" acknowledgment
and the durable progress surface — Status, the `## Progress` phase checklist
(with append-only timestamped notes nested under each phase), run/branch/PR
links, Plan, Acceptance Criteria, and (collapsed in `<details>`) the Devflow
Reflection. There is no separate Decisions / Notes section — notes live inside
`## Progress`. The `Last updated` line is friendly UTC (`2026-05-05 17:42 UTC`),
not raw ISO-8601.

- **`track_progress: false`** on the `claude-code-action` step in
  `.github/workflows/devflow-implement.yml` disables the action's *own*
  progress comment, so the workpad is the only comment a run posts. (The
  light `/devflow:review` · `/devflow:pr-description` listener in `devflow.yml`
  keeps `track_progress` as-is. `/devflow:pr-description` has no workpad;
  `/devflow:review` in PR mode now authors its own live progress comment —
  see below.)
- The workpad is created **as early as possible**, before the requester waits
  on any runtime. In a cloud run the **`gate` job** creates a lean workpad
  (`workpad.py new-body` → `create`) right after authorization + dedupe — *before*
  the heavy `claude` job boots and runs `setup-project-env` (Python/Node/services/
  deps), which the acknowledgment does not need. The `claude` job's Phase 1.3
  detects that workpad via `workpad.py id` and **resumes** it (filling in the Plan
  and the real Acceptance Criteria), never posting a second comment. A local-tier
  run (no `gate` job) creates the workpad itself in Phase 1.3 as the first GitHub
  write. Either way it is created *before* the branch. The `Run` link is built
  from `$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID`
  (standard env vars — no workflow wiring needed); the `Branch` line is filled the
  instant the branch exists, and the `PR` link once the draft PR is created in
  Phase 3.1.

### Status-glyph / reaction vocabulary

The workpad `Status` line begins with a canonical glyph that `workpad.py`
derives from the status word, and the same glyph is mirrored as a reaction on
the **triggering** comment so the two never disagree. The vocabulary is
constrained to GitHub's fixed reaction set (`+1 -1 laugh confused heart hooray
rocket eyes` — ✅/❌ are *not* reactions):

| State | Glyph | Reaction |
|---|---|---|
| Running (any in-progress phase) | 🚀 | `rocket` (added on pickup by the `gate` job) |
| Complete | 🎉 | `hooray` (added in Phase 4.3) |
| Blocked | 👎 | `-1` (added at any Blocked finalizer) |

The completion/blocked reaction is emitted via `scripts/react-to-trigger.sh`
(the same script the gate uses for the pickup 🚀) and is driven by the run's
**final workpad `Status`**, not the job's exit code — a run can exit 0 while
`Blocked`. The reaction is best-effort: a failure never blocks the run, and the
workpad `Status` glyph remains the authoritative signal.

## A PR-mode `/devflow:review` posts one live progress comment

Standalone `/devflow:review` (the light listener in `devflow.yml`, and the
automated `devflow-review.yml` reviewer) is the review-side analogue of the
implement workpad. In **PR mode**, and when
`devflow_review.live_progress_comment_enabled` is `true` (the default), the
review engine maintains a **single per-run** marker-tagged comment — keyed by a
run-keyed marker (`<!-- devflow:review-progress run=<id>-<attempt> -->`; the bare
`devflow:review-progress` is its prefix) — and rewrites it **in place** as it works:
a blueprint of the phases up front, then per-phase results (diff classification,
checklist counts, each Phase-3 agent's findings appended *as that agent
returns*, the verdict), finalizing with the full Phase 4.1 report plus a
run-telemetry summary and effectiveness trace. `skills/review/SKILL.md` owns
this end-to-end (Phase 0.3.5 seeds it; the update protocol rewrites it at each
phase boundary; Phase 4.5 finalizes it).

- It reuses the **same helper** as the implement workpad — `scripts/workpad.py`
  — pointed at the review marker via the helper's `--marker` flag (a plain
  argument on each call; precedence: `--marker` > the `DEVFLOW_WORKPAD_MARKER`
  env var > `devflow.workpad_marker` config > the built-in default). The flag is
  used rather than the env var because a leading `VAR=value` env-assignment
  makes the command un-matchable against the cloud allow-list rule
  `Bash(.../workpad.py:*)` — the command would no longer *start with* the helper
  path — so those calls would be silently denied on the read-only `review`
  profile and the live comment would never appear.
- The engine **owns the comment end-to-end**, so `devflow-review.yml` no longer
  seeds, templates, or PATCHes a competing progress comment — its prompt just
  runs the skill against the PR. The earlier per-phase PATCH choreography that
  lived in the workflow now lives in the skill. Exactly one such comment exists
  **per review run**: each run seeds its own, keyed by a run-keyed marker
  (`<!-- devflow:review-progress run=<id>-<attempt> -->`) and carrying a link to
  that job, so `workpad.py id --marker …` resolves only the current run's comment
  — earlier runs' comments are never overwritten and stay on the PR as review
  history.
- Phase 4.4's `gh pr review` stays the authoritative merge signal (a short
  verdict stub); the live comment is the human-readable narrative pointing at it.
  The final comment state reflects the actual verdict — never a green check above
  a REJECT.
- It works under the **read-only cloud `review` profile**: the comment is
  created/edited via `gh` (a comment edit, not a tree write), and the runner's
  `review` tool profile additionally allow-lists `workpad.py`, `config-get.sh`,
  and `efficiency-trace.sh` for this. The effectiveness-trace **record file**
  under `.devflow/logs/efficiency/` is gated to writable (local/IDE) runs only —
  see [`efficiency-trace.md`](efficiency-trace.md).
- Gating: `devflow_review.live_progress_comment_enabled = false` skips the live
  comment (the report is produced once at the end, as before); in non-PR /
  current-branch mode there is no comment surface and the narrative goes to chat.
  This flag is independent of
  `devflow_review_and_fix.efficiency_telemetry_enabled`, which separately gates
  the embedded telemetry/trace. Comment writes are best-effort — a failure is
  logged and the review continues to its verdict.

## Duplicate `/devflow:implement` runs are ignored per thread

A second `/devflow:implement` for an issue/PR while a run for it is already in
flight is **ignored** — the new command does not start a second `claude` job,
and the in-progress run is left untouched. A command for a *different* issue
runs in parallel as normal.

GitHub Actions has no native "skip if already running": `cancel-in-progress: true`
cancels the in-flight run (the wrong one), and `cancel-in-progress: false` queues
the duplicate so it eventually runs (not ignored). So the gate detects duplicates
itself, in `scripts/dedupe-implement-run.sh`:

- `devflow-implement.yml` sets a `run-name` embedding the issue/PR number the
  command was posted on. The dedupe step lists this workflow's active runs and
  matches that number out of each run's display title.
- A run defers **only** to an active run with a *smaller* `databaseId` (an older
  run). Run ids increase monotonically, so among overlapping runs for one thread
  the oldest — having no older peer — proceeds and the rest ignore. The common
  case (duplicate commands seconds apart) thus collapses to one run. Because
  `gh run list` is eventually consistent, two commands fired in the same
  sub-second window can each query before the other's run appears and both
  proceed — a residual race that is accepted (it fails toward running, never
  toward swallowing a request).
- The check **fails open**: any query error yields `duplicate=false` and the run
  proceeds, because silently swallowing a legitimate single request is worse than
  a rare redundant run.

When a duplicate is ignored, the gate posts a brief notice on the thread.
**Critical:** that notice contains no DevFlow trigger phrase (no `/devflow:…`,
no `@claude`) — the bot's own comment is itself an `issue_comment[created]`
event, and a trigger phrase in it would re-enter the gate and could loop.

### Boundary

Dedupe keys on the issue/PR *thread the command was posted on* (the run-name
number), not on an explicit `/devflow:implement <n>` cross-posted to a different
thread. The dominant duplicate case — the same command repeated on one thread —
is fully covered.
