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
