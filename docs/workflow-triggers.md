# DevFlow workflow trigger surface

How the DevFlow GitHub workflows decide *when* to run, *which* one runs, and how
duplicate `/devflow:implement` commands are collapsed. The codebase is the
source of truth — this doc records the *why*.

## Which workflow fires on what

| Workflow | Commands | Listens on |
|---|---|---|
| `devflow.yml` (light path) | `/devflow:review`, `/devflow:review-and-fix`, `/devflow:pr-description` | `issue_comment[created]`, `pull_request_review_comment[created]`, `pull_request_review[submitted]` |
| `devflow-implement.yml` (heavy path) | `/devflow:implement` | `issue_comment[created]`, `pull_request_review_comment[created]`, `pull_request_review[submitted]` |
| `devflow-review.yml` | automated review | PR lifecycle + `check_run[rerequested]` |

Both command listeners run `claude-code-action` in **agent mode** with a
synthesised prompt, so they need no `@claude` phrase. Every gate `if:` branch
also negates `@claude` and (for the light path) `/devflow:implement`, so a given
comment routes to exactly one listener and never collides with Anthropic's stock
`claude.yml`. This is the *partition invariant*, enforced by tests in
`lib/test/run.sh`.

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
  keeps `track_progress` as-is — those flows have no workpad.)
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
