---
name: retrospective-weekly
description: >
  Run the weekly devflow self-improvement loop locally: scan freshly-merged
  watched-author PRs, write per-PR retrospective entries (LLM only for PRs
  that fail the mechanical clean-gate), derive recurring patterns, and file
  one human-reviewed GitHub issue per actionable pattern. Use when running
  the weekly devflow retrospective + audit.
---

# /devflow:retrospective-weekly — Weekly Orchestrator

This skill is the single entry point the maintainer invokes once a week (or
on demand). It is a *conductor*: it runs deterministic bash/jq scripts from
`lib/` at every mechanical step and dispatches LLM subagents only at the two
genuine-judgment points — per-PR retrospective analysis (Stage A) and
per-pattern issue-spec drafting (Stage B). Everything else — fetching,
signal computation, gating, pattern math, and git/issue mechanics — is done by
plain scripts with no LLM tokens. The loop **proposes, it does not dispose**:
each actionable pattern is filed as **one GitHub issue** for the normal
implement → review pipeline, not landed as an autonomous PR.

**`$LIB` notation (textual, not a shell variable).** Throughout this skill, `$LIB` in a command denotes the resolved path `"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../lib` — expand it textually (with the anchor already resolved for this runner) when composing each command you actually run. Never rely on a shell variable named `LIB` persisting from one statement or block to another — each Bash call is a fresh shell, and the *Portable helper anchor* note below explains why even same-command variable reuse is unsafe on some runners.

Every `jq` in this skill is invoked through the execution-verified wrapper
`$LIB/../scripts/run-jq.sh` (`$LIB/../scripts` is the `scripts/` dir beside
`lib/`), never bare `jq` — so a shim-shadowed Windows/WSL host resolves a
runnable jq the same way the `.sh` helper tier does (issue #253, the agent-tier
sibling of #247). `DEVFLOW_JQ` is not exported to agent shells, so the wrapper
must be invoked by path.

All scratch files live under `.devflow/tmp/` (gitignored). Learnings files
(`.devflow/learnings/`) are tracked and committed via the state PR.

**GitHub autolink hygiene** (any text you compose that lands on a GitHub surface — issue/PR titles, the state-PR report comment, body content you assemble): never put a bare `#` immediately before a number unless it is a real issue or PR reference — GitHub renders `#2` as a link to issue/PR 2, which misleads readers. For an ordinal, count, or list position, spell it out ("item 2", "step 3"), never `#2`. Genuine references like `#123` stay as-is.

---

**Portable helper anchor (single-statement).** The bundled-helper commands in this skill resolve the skill directory inline at each call site via `${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}`. When `$CLAUDE_SKILL_DIR` is set and non-empty (Claude Code), run each command exactly as written. On a runner where it is unset or empty, replace the placeholder with the skill base directory the runner reports in context (e.g. a `Base directory for this skill:` line) before running the command; if that reported path is Windows-form (`C:\...`), first convert it to this shell's POSIX form with one standalone `wslpath -u '<path>'` (WSL) or `cygpath -u '<path>'` (Git Bash/MSYS2) command and substitute the printed result **only if the command succeeds and prints a non-empty path — otherwise fall through to the drive-letter rules exactly as if the tool were absent, the same success-and-non-empty acceptance the platform's path-normalization rules apply** (if neither tool exists: lowercase the drive letter, map `C:\` to `/mnt/c` on WSL or `/c` on MSYS2, and turn backslashes into `/`; if the environment is neither WSL nor MSYS2, use the path unchanged and report that it could not be normalized — the same arm the platform's path-normalization rules take). Resolve the anchor inline at every call site — never capture it into a shell variable that a later statement reads, because some runners' inline-bash marshaling drops such variables (observed on Copilot CLI). If neither `$CLAUDE_SKILL_DIR` nor a runner-reported base directory is available, stop and report that the helper anchor could not be resolved rather than running a command with a broken path.

**Consumer prompt extension (load first).** Before doing this skill's work, load any consumer-supplied prompt extension for this skill and honor it. From the repo root, run:

```bash
"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/load-prompt-extension.sh retrospective-weekly
```

If the invocation fails because the helper path does not exist (`No such file`, exit 127, or the platform equivalent), that is the **anchor-resolution** failure described in the *Portable helper anchor* note above — fix the anchor, don't report a missing extension. Otherwise, if the helper exits non-zero, a consumer extension exists but could not be loaded — surface its stderr message and do not silently proceed as if none existed. If it exits 0 and prints text, treat that text as additional instructions appended to the end of this skill's own prompt for this run — it is upgrade-safe, consumer-owned customization committed under `.devflow/prompt-extensions/`. If it exits 0 and prints nothing, proceed unchanged.

## Procedure

### Step 1 — Preflight

Confirm the working tree is clean:

```bash
git status --porcelain
```

If the output is non-empty, **stop** and tell the user to stash or commit
their changes before running the loop.

Confirm `gh` is authenticated:

```bash
gh auth status
```

If it fails, tell the user to run `gh auth login` and stop.

Confirm you are on `main`:

```bash
git branch --show-current
```

If not on `main`, run `git checkout main`.

Prepare the scratch directory (`$LIB` below is the textual notation from the top of this skill — expand it when composing commands, do not assign a shell variable). This also removes prior-run scratch (`result-*.json`, `pr-*.context.json`, `overrides-prefiling.json`) so a run starts clean and can never read another run's stale bundle, output, or overrides snapshot:

```bash
mkdir -p .devflow/tmp
rm -f .devflow/tmp/new-entries.jsonl
# Remove prior-run scratch. `find … -delete` (not a bare `rm -f <glob>`)
# is shell- and OS-agnostic: it is a safe no-op when no pattern or only some
# patterns match, whereas under zsh an unmatched glob is a fatal `no matches found`
# that would abort the whole rm (leaving EVERY pattern uncleaned). Step 1 runs before
# any fetch, so it never touches the current run's own freshly-written files.
# Every file a later step reads back BY PATH is named here, for a distinct reason
# from the per-PR scratch above: those readers guard their input by readability
# alone, so a surviving copy from an earlier run is READABLE — the missing/unreadable
# warning never fires and the report renders confidently from the previous run's
# state. That covers the overrides snapshot Step 9 reads for the won't-fix re-raise
# section, and the pattern files plus the liveness capture Step 8c and Step 9 read.
# Relying instead on Step 6's truncating redirects to overwrite them makes the
# guarantee a property of one call site rather than of this cleanup, so a moved or
# short-circuited write silently reintroduces stale state.
find .devflow/tmp -maxdepth 1 -type f \( -name 'result-*.json' -o -name 'pr-*.context.json' -o -name 'overrides-prefiling.json' -o -name 'patterns.json' -o -name 'patterns-full.json' -o -name 'patterns.stderr' \) -delete 2>/dev/null
```

---

### Step 2 — Scan

Fetch the list of unprocessed watched-author PRs merged in the last 7 days:

```bash
bash $LIB/scan.sh > .devflow/tmp/scan.json
```

**Ad-hoc / backfill / test runs.** To run the loop against a specific set of
PRs instead of the rolling 7-day window — e.g. backfilling old PRs, re-running
after a fix, or testing the pipeline — pass `--prs`:

```bash
bash $LIB/scan.sh --prs 774,786,772,789 > .devflow/tmp/scan.json
```

`--prs` skips the GitHub search **and** the already-processed filter (you named
the PRs, so the loop trusts you), but still drops any number that isn't a merged
retrospected branch. Everything downstream (Steps 3–10) is identical. Do **not**
use `--prs` for the scheduled weekly run.

`scan.sh` writes to stdout and exits non-zero on unrecoverable errors. If
the output array is empty:

```bash
$LIB/../scripts/run-jq.sh 'length == 0' .devflow/tmp/scan.json
```

→ `true`: report **"Nothing to process — no unprocessed watched-author PRs
in the last 7 days."** and **STOP**.

---

### Step 3 — Per-PR context fetch + cheap gate

Initialize counters:

```bash
prs_scanned=0
clean_count=0
analyzed_count=0
skipped_count=0     # issue #626: mechanically- and Stage-A-skipped PRs
skip_records=()     # one-line report records, one per skip (never silent)
needs_analysis=()   # array of bundle paths
```

For each PR number in `scan.json` (iterate via `$LIB/../scripts/run-jq.sh -r '.[].number'`):

```bash
number=<the pr number>
CTX=$(bash $LIB/fetch-pr-context.sh "$number")
prs_scanned=$((prs_scanned + 1))
```

`fetch-pr-context.sh` writes the bundle to `.devflow/tmp/pr-<n>.context.json`
and **echoes that file path** to stdout — so `$CTX` is the path, not the
bundle content.

Run the cheap gate against the bundle content:

```bash
GATE=$($LIB/../scripts/run-jq.sh -c -f $LIB/cheap-gate.jq < "$CTX")
```

Outputs `{"clean": <bool>, "reason": "<string>"}`.

**If `clean == true`:**

Emit a clean entry (every retrospected PR is an `implementation` PR now — the
old audit-kind path is retired along with autonomous intervention PRs):

```bash
$LIB/../scripts/run-jq.sh -c -f $LIB/clean-entry.jq < "$CTX" >> .devflow/tmp/new-entries.jsonl
```

Increment `clean_count`.

**If `clean == false`:**

First run the **mechanical pre-dispatch disposition** (issue #626). This decides —
with **no LLM dispatch** — whether the non-clean bundle warrants Stage A analysis
or is a mechanical skip (a foreign, non-DevFlow PR whose only non-clean signal is a
missing workpad audit trail — `Absent` means the linked issue *did* resolve but
carried no workpad comment, so this is not restricted to issueless PRs). It is a suite-driven helper, never inline prose:

```bash
DISP=$($LIB/../scripts/run-jq.sh -c --argjson gate "$GATE" -f $LIB/dispatch-disposition.jq < "$CTX")  # argjson-ok: gate -- one PR's cheap-gate result (bounded)
```

`DISP` is `{"disposition": "skip"|"dispatch", "reason": "<string>"}`. It returns
`skip` **exactly** when the gate reason is a workpad reason, the status is a
sentinel (`Absent`/`NoIssue`), and `pr_devflow_provenance` is `false` — otherwise
`dispatch`. So a bundle non-clean on **any** non-workpad signal (outstanding
REJECT, CI failures, post-bot commits, review comments) is always dispatched,
exactly the analysis it receives today.

**If `disposition == "skip"` (the mechanical no-provenance skip):** this is a
**permanently-terminal** skip. Append a marker entry to the store and write a
one-line run-report record — costing **zero** LLM dispatches. Do **not** add it to
`needs_analysis`.

```bash
# $number is this PR (the loop variable); DISP's .reason is the skip reason line.
SKIP_REASON=$(printf '%s' "$DISP" | $LIB/../scripts/run-jq.sh -r '.reason')
# argjson-ok: pr -- scalar PR number.
$LIB/../scripts/run-jq.sh -cn --argjson pr "$number" --arg reason "$SKIP_REASON" \
  '{kind:"skip", pr:$pr, reason:$reason}' >> .devflow/tmp/new-entries.jsonl
skip_records+=("PR #$number skipped (mechanical, no DevFlow provenance): $SKIP_REASON")
skipped_count=$((skipped_count + 1))
```

Record the skip in the run report (see Step 9) with its reason line and increment
`skipped_count`. The marker entry makes the processed-PRs filter treat this PR as
handled on subsequent runs.

**If `disposition == "dispatch"`:** add the bundle path to the analysis list:

```bash
needs_analysis+=("$CTX")
analyzed_count=$((analyzed_count + 1))
```

---

### Step 4 — Stage A: Retrospective subagents (per non-clean PR)

For each bundle path in `needs_analysis`, dispatch a subagent. Issue up to
**3–4 subagents concurrently** in a single message (use the Agent tool for
each). Each subagent prompt:

> Read and follow `"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../retrospective/SKILL.md`
> exactly.
>
> Your context bundle path is: `<path>`
>
> Consumer prompt-extension handoff: your extension file for this skill is at the
> absolute path `<REPO_ROOT>/.devflow/prompt-extensions/retrospective.md`. Read it
> with your file-read tool and honor any content as instructions appended to the
> retrospective skill's own prompt. If the file is absent or empty, treat it as a
> no-op and report nothing about it; if it is present but you cannot read it, report
> that via the optional `extension_unreadable` key in your returned JSON object.
>
> Print exactly one JSON object (the retrospective entry) and **nothing else**
> on stdout.

**Resolve `<REPO_ROOT>` before dispatch (by-path handoff, issue #834).** A
subagent receives neither `$CLAUDE_SKILL_DIR` nor a `Base directory for this skill:`
context line, so it cannot resolve its own anchor to reach the extension. You
(the orchestrator) run as a skill, so *you* resolve the repository root
(`git rev-parse --show-toplevel`) and substitute it for `<REPO_ROOT>` in the
handoff sentence above, giving the child an absolute path its own working directory
cannot change. Append the sentence **unconditionally** — it is inert when no
extension exists (a child that reads an absent file finds nothing to honor). Run
**no** probe and read **no** extension file yourself: no extension content enters
this orchestrator's context on any path. The child performs a **file read**, never
a command invocation, so this handoff needs no allowlist entry and no permission
grant on any tier.

(The subagent picks `categories` from the fixed vocabulary in that skill — no
"existing tags" list is passed; the vocabulary *is* the bounded list.)

Wait for all dispatched subagents to finish before continuing.

**Collecting results:** Each subagent's final message is its JSON object.
Subagent output can contain quotes, backticks, newlines, and `$` — never
interpolate it inline into a shell command. **Write each subagent's raw result
to a temp file with the Write tool** (e.g. `.devflow/tmp/result-<n>.json`), then
operate on the file. For each result:

1. Attempt to parse it: `$LIB/../scripts/run-jq.sh -c . < .devflow/tmp/result-<n>.json`
2. **A Stage A defined skip (issue #626) is recognized by the presence of a
   top-level `"skip"` key ONLY** — never by matching substrings of any error text
   (agent-authored free text is data, never a discriminator). A `"skip"`-keyed
   return is **terminal: no retry, no blocker.** Whether it leaves a marker depends
   on the bundle's `workpad_final_status` (a mechanical field, not the skip text):
   - **`Cancelled`** → a **permanently-terminal** skip → append a marker entry so
     the PR is seen as handled next run:
     `$LIB/../scripts/run-jq.sh -cn --argjson pr <n> --arg reason "<the skip .reason>" '{kind:"skip", pr:$pr, reason:$reason}' >> .devflow/tmp/new-entries.jsonl` # argjson-ok: pr -- scalar PR number
   - an **interim** state (`Setup`/`Discovering`/…/`Documenting`) → a **transient**
     skip → append **no** marker, so the PR stays unprocessed and is re-scanned
     while it remains inside the 7-day merge lookback.

   Either way, record the skip explicitly — append the report record AND increment
   the counter, in the same two statements the mechanical branch above uses, so
   `skipped_count` and the rendered `skips[]` can never diverge:

   ```bash
   skip_records+=("PR #<n> skipped (Stage A, <Cancelled|interim>): <the skip .reason>")
   skipped_count=$((skipped_count + 1))
   ```

   That record is what Step 9 renders. **Every** skip — the mechanical
   pre-dispatch skip above, the `Cancelled` skip, and the interim skip — writes a
   one-line report record, so no skip is ever silent.
3. Otherwise, if parsing fails or the object has an `"error"` key (a genuine
   failure), **retry the subagent once** with the same prompt.
4. If still malformed (or still `"error"`-keyed) after one retry, record a blocker:
   `"PR #<n>: retrospective analysis failed"` and skip that PR.
5. If valid (a real retrospective entry, no `"skip"`/`"error"` key), append:
   `$LIB/../scripts/run-jq.sh -c . < .devflow/tmp/result-<n>.json >> .devflow/tmp/new-entries.jsonl`
6. **Relay a child-reported unreadable extension (issue #834).** If the parsed
   object carries an `extension_unreadable` key (the by-path handoff found the
   consumer extension present but unreadable), surface it in the run report by
   appending a one-line record naming the child skill and the reported value —
   `skip_records+=("Stage A PR #<n>: consumer prompt extension for retrospective present but unreadable: $($LIB/../scripts/run-jq.sh -r '.extension_unreadable' < .devflow/tmp/result-<n>.json)")` — so the operator sees the extension could not be honored. This never fails the PR's analysis: the entry (extra key and all) is still appended in step 5.

---

### Step 5 — Materialize

Merge all new entries into the retrospectives file (idempotent — existing
entries for the same `pr`+`kind` are replaced):

```bash
bash $LIB/materialize-retrospectives.sh \
  .devflow/tmp/new-entries.jsonl \
  .devflow/learnings/retrospectives.jsonl
```

The script prints `"materialized: appended N, replaced M"` to stdout.

---

### Step 6 — Reconcile lifecycle, then derive actionable patterns

First reconcile every pattern's lifecycle record against the live state of its
filed meta-issue (issue #788): `pattern-state.sh run` migrates the overrides file
to schema v3 in place (on first read — issue #891 stamps each record's `category`
field) and refreshes each `filed`/`fixed`/`declined`
state, so the pattern view derived below already reflects this run's reconciliation.
It runs **before** `actionable-patterns.sh`; a wholesale reconcile failure exits
non-zero and aborts the derivation (fail-closed — deriving patterns from
unreconciled state is what broke the loop).

```bash
# The abort is EXECUTABLE, not prose: `pattern-state.sh` returns non-zero on a
# wholesale prefetch failure, a malformed overrides file, a failed jq transform,
# and a failed atomic write — but nothing observes that status unless this
# invocation is guarded, and an unguarded call would let the derivations below
# run on stale, unreconciled state. That is the #788 defect itself (patterns stay
# `filed` forever after their issue closed, and the loop files nothing), so the
# guard is what makes the fail-closed claim above true.
bash $LIB/pattern-state.sh run .devflow/learnings/overrides.json || {
  echo "::error::retrospective Step 6: the lifecycle reconcile failed — aborting BEFORE pattern derivation (deriving from unreconciled state is the #788 defect this step exists to prevent)" >&2
  exit 1
}
# stderr is CAPTURED, not discarded: actionable-patterns.sh writes its
# `liveness:` line there (issue #788), and the report's liveness line is
# rendered from that capture. `2>` a file rather than a pipe so the exit
# status stays the script's own. The capture is also echoed to the console
# so the ::warning:: still reaches the CI log.
bash $LIB/actionable-patterns.sh \
  .devflow/learnings/retrospectives.jsonl \
  .devflow/learnings/overrides.json \
  > .devflow/tmp/patterns.json 2> .devflow/tmp/patterns.stderr || {
  # Guarded for the same reason the reconcile above is: `>` truncates before the
  # script runs, so an unguarded non-zero exit leaves an EMPTY patterns.json and
  # Step 8 proceeds to file nothing — failing open toward "quiet week".
  echo "::error::retrospective Step 6: actionable-pattern derivation failed — aborting rather than proceeding with an empty pattern set (which would report a quiet week)" >&2
  cat .devflow/tmp/patterns.stderr >&2 || true
  exit 1
}
cat .devflow/tmp/patterns.stderr >&2 || true
# Snapshot the post-reconcile, PRE-FILING overrides file for Step 9's won't-fix
# re-raise read. It lives here, not in Step 8c, because Step 8 is skipped
# wholesale when nothing is actionable — and Step 9 reads this path
# unconditionally, so taking it there would make every quiet run warn that the
# overrides file is unreadable when it is intact. It must be taken AFTER the
# reconcile (which writes the `state_reason` the read keys off) and BEFORE any
# filing (which would make a re-raised pattern look freshly `filed`).
# The destination is removed first and the copy is GUARDED, because a failed `cp`
# does not leave Step 9 with nothing to read: `devflow_declined_refiled` tests only
# whether the snapshot is unreadable, so any surviving file — a stale one from an
# earlier run — silently satisfies that test and the won't-fix re-raise section is
# rendered from state this run never took.
rm -f .devflow/tmp/overrides-prefiling.json
cp .devflow/learnings/overrides.json .devflow/tmp/overrides-prefiling.json || {
  echo "::error::retrospective Step 6: could not snapshot the pre-filing overrides file — aborting rather than letting Step 9 render its won't-fix re-raise section from a stale or absent snapshot" >&2
  exit 1
}
# The UNFILTERED whole-pattern view (every lifecycle state, below-threshold and
# suppressed included) for the run report; --full drops the actionable filters.
bash $LIB/actionable-patterns.sh \
  .devflow/learnings/retrospectives.jsonl \
  .devflow/learnings/overrides.json \
  --full \
  > .devflow/tmp/patterns-full.json || {
  echo "::error::retrospective Step 6: the unfiltered (--full) pattern derivation failed — aborting; the report's pattern section is rendered from this file" >&2
  exit 1
}
```

Print a summary line to the console, for example:

```
5 PRs: 3 clean, 2 analyzed; 2 actionable patterns: incomplete-edit (x5), lenient-verdict (x3)
```

Partition `patterns.json` into two lists:

```bash
to_act=$($LIB/../scripts/run-jq.sh '[.[] | select(.cooldown_active == false)]' .devflow/tmp/patterns.json)
cooldown_skipped=$($LIB/../scripts/run-jq.sh '[.[] | select(.cooldown_active == true) | .tag]' .devflow/tmp/patterns.json)
```

Record `cooldown_skipped` tags for the final report.

---

### Step 6.5 — Build experiment records (best-effort)

After Step 5 materialized this week's retrospective entries (and before the Step 7
state PR commits the learnings files), assemble the unified experiment record —
joining each merged PR's per-run cost to its review outcome (verdict, Important-finding
count, denial count, config fingerprint). Anchored **here** so this week's PRs join
against this week's freshly-materialized retrospective entries.

This is a **best-effort** step and **never blocks** the retrospective: a non-zero exit is
logged as a breadcrumb and the run continues. Carry that breadcrumb into the Step 9 status
report as a blocker note so the failure is visible, then proceed.

A non-zero exit means **some** PRs did not make it into the store — not necessarily that
*nothing* was written. The assembler exits 2 when any candidate failed to assemble **or**
had an **unestablished** merge state (a `gh` outage, an unresolvable repo), and it still
writes the records that *did* assemble, so a partial failure leaves a partially-updated
store. Report it as "N PRs missing from the experiment store," not as "the store was not
updated." **An unestablished PR does not backfill by itself** — it never enters the store,
and only stored or retrospective-listed PRs are re-selected as candidates — so name the
PRs from the breadcrumb and re-run with `--prs` once the cause is resolved.

Before the reader runs, **fetch the telemetry branch** (issue #441) into its local ref so
`build-experiment-records.py` can union each run's durable record off that branch with any
legacy tracked `.devflow/logs/`. Best-effort: on a fresh repo the branch does not exist yet
(nothing has persisted to it) and the fetch is a harmless no-op — the reader then reads the
legacy archive alone; the retrospective is never blocked by a missing telemetry branch.

```bash
# Fetch the telemetry branch into its local ref — deliberately NO force `+` refspec: the
# local ref can be AHEAD of the remote (offline-accumulated `--persist` commits not yet
# reconciled by a writer's union re-parent), and a forced fetch would rewind it and
# permanently orphan those records. A plain fetch fast-forwards the common case and rejects
# exactly the local-ahead/diverged case, leaving the local ref — and its records — intact
# for the reader; reconciling with the remote belongs to the next writing run's
# fetch → re-parent → push loop, never to this read-side fetch.
# The reader (`_index_efficiency`) reads it by its local branch name.
#
# Resolve the branch through the SAME resolver the writer uses — never a third, independent
# re-derivation. `devflow_telemetry_branch` (lib/telemetry-branch.sh) owns the full contract:
# the `.telemetry.branch` read, config-get.sh's coercion, and the `git check-ref-format`
# fallback to the default. A bare `config-get.sh` read here applies NEITHER guard, and both
# gaps end the same way — this fetch targets a branch nobody wrote to, the local ref is never
# populated, and on a fresh clone or a cloud checkout the reader then finds nothing and every
# cost row silently goes missing:
#   * a schema-valid but git-invalid name ("my branch", "a..b") → the writer persisted to
#     `devflow-telemetry`, but this would try to fetch `my branch`;
#   * a malformed config → config-get.sh prints NOTHING and exits 2, so TELEMETRY_BRANCH is
#     empty and the command degrades to `git fetch origin ":"`, while the writer and reader
#     both fell back to `devflow-telemetry`.
# Source the lib and ask it. The `||` keeps this best-effort: if the lib cannot be sourced, fall
# back to the same default the resolver would have returned.
#
# Do NOT redirect the resolver's stderr to /dev/null. Its breadcrumb is the whole reason for
# routing through it: on a git-invalid `telemetry.branch` it is the one place that names the
# config key to fix. Silencing it would leave an operator with a broken config reading a
# perfectly healthy-looking retrospective that quietly contains no telemetry-branch rows.
# Only stdout is captured; stderr flows to the run log.
#
# Note the lib sources `config-source.sh`, which sets `set -euo pipefail` in THIS shell. Every
# command below is `||`-guarded, so that is harmless today — but keep new commands in this fence
# guarded, or errexit will abort the step.
. "$LIB/telemetry-branch.sh" || true
TELEMETRY_BRANCH=$(devflow_telemetry_branch) || TELEMETRY_BRANCH=""
[ -n "$TELEMETRY_BRANCH" ] || TELEMETRY_BRANCH=devflow-telemetry
git fetch origin "${TELEMETRY_BRANCH}:${TELEMETRY_BRANCH}" 2>/dev/null || \
  echo "retrospective-weekly: could not fetch telemetry branch '${TELEMETRY_BRANCH}' (absent on a fresh repo, offline, or the local ref has commits the remote lacks) — the experiment-record reader unions whatever local '${TELEMETRY_BRANCH}' ref exists (if any) with any legacy tracked .devflow/logs/" >&2
python3 $LIB/../scripts/build-experiment-records.py || \
  echo "retrospective-weekly: build-experiment-records.py exited non-zero (rc=$?) — one or more PRs are MISSING from the experiment store (see its stderr for which, and whether they failed to assemble or had an unestablished merge state); records that did assemble were still written" >&2
```

The assembler is idempotent (one line per merged PR, keyed by PR number) and incremental
(it processes merged PRs absent from `.devflow/learnings/experiment-records.jsonl` plus
any passed via `--prs`, never a full-history sweep), so re-running is safe and cheap. It
runs on the **local/interactive retrospective tier only** — it is never invoked from a
workflow. See `docs/efficiency-trace.md` for the store schema and the abandoned-run bias.

---

### Step 7 — State PR

**Open the state PR now, before Stage B**, so that the learnings files are
committed onto their own branch. This captures the unstaged changes Steps 5–6
wrote to `.devflow/learnings/` before any issue is filed, so this run's
retrospective data survives even if Stage B or the filing step fails partway.

Ensure you are on `main`:

```bash
git checkout main
```

The working tree now has the updated
`.devflow/learnings/retrospectives.jsonl` and, normally, a modified
`.devflow/learnings/overrides.json`. That overrides diff is **this** run's output,
not carry-over: Step 6's reconcile rewrites the file unconditionally, so an
unexpected-looking diff there is the reconcile normalizing entries (schema
migration, refreshed `state_reason` and lifecycle states) — and it may additionally
carry meta-issue lifecycle records written by earlier runs that were never
committed. Review it as fresh reconcile output; do not discard it as stale. These
changes are in-place on `main`'s working tree and have **never
been committed to `main`** — `open-state-pr.sh` handles committing them onto
a separate branch.

```bash
STATE_PR=$(bash $LIB/open-state-pr.sh)
```

`open-state-pr.sh` (no required args; optional `--branch <name>`,
`--base <ref>` — defaults to `main` —, and `--dry-run`):

- Creates/reuses branch `devflow/learnings-<YYYY-MM-DD>` from `--base`
  (`main` by default), so the PR diff is just the learnings files even if the
  operator was on a feature branch.
- Stages any learnings files that exist (`.devflow/learnings/retrospectives.jsonl`
  and, if present, `.devflow/learnings/overrides.json`).
- Commits and pushes (force-with-lease if the remote branch exists).
- Opens or updates the PR against `main`.
- **Prints the PR number** to stdout.

After it returns, **go back to `main`** so the working tree is clean and
Stage B starts from a known-good HEAD:

```bash
git checkout main
```

Initialize Stage B counters:

```bash
intervention_issues=()   # will hold {key, category, url} objects — one per filed finding (issue #893)
blockers=()              # will hold strings
# Step 9 slurps both of these. Declaring them here rather than relying on the
# first append means a run where nothing is filed and nothing is withheld still
# has an array to slurp, instead of a name Step 9 discovers is unset.
filed_slugs=()           # will hold COARSE pattern tags — one per pattern that filed at
                         # least one issue. Coarse, not composed: Step 9's
                         # devflow_annotate_patterns keys on the pattern's own
                         # `.tag // .slug`, and a `<category>-<subslug>` key never
                         # matches it. Per-issue detail lives in intervention_issues.
withheld=()              # will hold {tag, cap} objects — one per pattern a cap held back
truncations=()           # will hold {tag, delivered, total, selected} objects — one per pattern the audit_bundle_cap (or a fetch failure) truncated (issue #894)
```

---

### Step 8 — Stage B: File one issue per selected finding

For each actionable pattern, a Stage B subagent returns a ranked `findings` array
(one to three sub-patterns), and the orchestrator files **one GitHub issue per
selected finding** via `meta-issue.sh` — under an opaque `<category>-<subslug>`
filing key composed by the #891 composer. Which findings become filings is decided
by `lib/select-findings.sh` (issue #893), the owner of that decision **on the
findings-array path** — the legacy `{title, body}` shape never reaches it and derives
its own cap verdict in 8c: it composes and legality-checks each key, collapses subslug
churn onto an existing lifecycle record by a token-set alias, ranks tight clusters
ahead of grab-bags (descending evidence-PR count) and truncates to the top three, and
asks the shipped `devflow_filing_cap_verdict` for each of that path's cap decisions. **No worktrees, no commits, no
PRs** — the loop proposes; a human triages each issue and runs it through the normal
`/devflow:implement` → review pipeline. Your main checkout stays on `main` and is
never edited. The drafting subagents (8b) parallelize; the cheap filing (8c) is done
serially.

#### 8a — Gather occurrence bundles (bounded by `audit_bundle_cap`, issue #894)

The enriched pattern object now carries every occurrence's
`summary`/`descriptors`/`suggested_interventions` (issue #893), and the largest
category has ~199 occurrences, so — beyond the single scalar read that names its own
file (`SLUG`, below) — it must **not** travel through a herestring, and never
through an inline prompt interpolation.

**`SLUG` names the file every later step reads, so it is derived — and that file
written — before any other field is read off the pattern object:**

1. **`SLUG`** — `$LIB/../scripts/run-jq.sh -r .slug <<< "$pattern"`. The **one**
   sanctioned herestring over the enriched object. It is not the only place `SLUG`
   exists on disk — `.devflow/tmp/patterns.json`, written back in Step 6, carries
   `.slug` on every record — but selecting *this* iteration's record out of that file
   needs the very key we are deriving, and `$pattern` is the element already in hand.
   The exception is scoped to this one scalar and licenses no second read.
2. **Write** that pattern's object to `.devflow/tmp/pattern-${SLUG}.json` with the
   **Write tool**.
3. **`TAG`** (`$LIB/../scripts/run-jq.sh -r .tag ".devflow/tmp/pattern-${SLUG}.json"`)
   and **`CATEGORY`**
   (`$LIB/../scripts/run-jq.sh -r .category ".devflow/tmp/pattern-${SLUG}.json"` — the
   attribution category the opaque filing key belongs to, issue #891). Now that the
   file exists these come **from it**: a second and third herestring over the whole
   enriched object is exactly what the rule above forbids.
4. Record also the **absolute path** `.devflow/tmp/pattern-${SLUG}.json` (Step 8b
   hands that path to the subagent, matching the bundle-path handoff).

Stage B no longer fetches a bundle for *every* occurrence PR of a pattern — an
unbounded cost that scaled with each pattern's cumulative occurrence history.
Instead it fetches at most `audit_bundle_cap` occurrence bundles per pattern,
**most-recent-first**. Resolve and validate the cap **once, before the per-pattern
loop begins**, so no pattern is fetched before an unusable cap is detected. The
config read stays in this fence (via `config-get.sh`, default `10`); the validation
and selection live in the sourced `lib/audit-bundle-selection.sh`, which the suite
drives directly:

```bash
# Source the helper with a fail-closed arm — the same arm every
# `source $LIB/filing-decisions.sh` site in this file carries. Without it an
# unsourceable helper leaves devflow_validate_audit_bundle_cap /
# devflow_select_audit_bundles / devflow_audit_dispatch_ok undefined, their empty
# stdout reads as a valid cap and an empty selection, and the run proceeds on
# unvalidated values — the fail-open shape the validate-before-the-loop rule prevents.
source $LIB/audit-bundle-selection.sh || {
  echo "::error::retrospective Step 8a: lib/audit-bundle-selection.sh could not be sourced — the audit-bundle cap has no validator/selector; aborting rather than fetching every occurrence on an unvalidated cap" >&2
  exit 1
}
# config-get.sh resolves an absent file / absent key / null / empty string / empty
# array to the default 10. devflow_validate_audit_bundle_cap rejects a 0/negative
# cap, a coerced object/boolean/multi-array, a non-numeric string, 3.5, and an
# EMPTY resolver output (a read failure) — printing an `::error::` and exiting
# non-zero, which the `|| exit 1` propagates so no pattern is judged on a bad cap.
AUDIT_BUNDLE_CAP_RAW="$(bash $LIB/../scripts/config-get.sh '.devflow_retrospective.audit_bundle_cap' 10)"
AUDIT_BUNDLE_CAP="$(devflow_validate_audit_bundle_cap "$AUDIT_BUNDLE_CAP_RAW")" || exit 1
# REPO_ROOT is loop-INVARIANT, so resolve it once here rather than re-forking `git`
# per pattern. `|| pwd` is the repo's #295 fallback: unguarded, a git-absent or
# not-a-work-tree host leaves it EMPTY and every bundle path below becomes the
# absolute `/.devflow/tmp/pr-N.context.json` — a phantom path handed to Stage B.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
```

Then, for each `pattern` in `to_act` — with `SLUG`/`TAG`/`CATEGORY` and the
`.devflow/tmp/pattern-${SLUG}.json` file already derived and written above —
select the most-recent-N occurrence PRs and fetch only their bundles, tracking **three distinct
quantities** — *selected* (the post-cap set size), *delivered* (the bundles Stage B
actually receives, after excluding any that failed to fetch), and *total*
(`occurrence_count`):

```bash
# TOTAL is occurrence_count (compute-patterns.jq sets it to the occurrences[]
# length; read it directly, falling back to the array length if the field is
# absent). SELECTED_PRS are the most-recent AUDIT_BUNDLE_CAP occurrence PRs in
# DESCENDING ts order (the helper reverses the ascending occurrences[] tail — the
# emitted order is fact the dispatch prompt states).
# `dispatch` is the CARRIER of the no-dispatch floor: 8b dispatches, and 8c files,
# only patterns whose `dispatch` is still 1 when this fence ends. Start optimistic
# and clear it on any arm that leaves the pattern without evidence.
dispatch=1
# TOTAL is occurrence_count. The jq program's `// 0` protects a null FIELD, not a
# failed invocation: on an unresolvable/aborting run-jq.sh, TOTAL is EMPTY and the
# truncation comparison below would be `[ 0 -lt "" ]` → `integer expression
# expected`, rc 2 — aborting the run mid-loop under `set -e`. Unknown is not zero,
# so an unestablished TOTAL is recorded and the truncation entry is skipped rather
# than fabricated from a laundered 0.
TOTAL="$($LIB/../scripts/run-jq.sh -r '(.occurrence_count // (.occurrences // [] | length)) // 0' ".devflow/tmp/pattern-${SLUG}.json" 2>/dev/null || true)"
case "$TOTAL" in
    ''|*[!0-9]*)
        blockers+=("Pattern ${SLUG}: the occurrence total could not be established (got '${TOTAL}') — truncation reporting skipped for this pattern")
        TOTAL="" ;;
esac
# Fail CLOSED on a selector failure. Without this arm a non-object pattern, a
# present-but-non-array `occurrences`, or an unresolvable jq all yield empty stdout,
# the loop below never runs, and the run records the blocker "all 0 selected
# occurrence bundle(s) failed to fetch" — asserting a FALSE cause (`gh`) for a
# config-/corpus-shape defect. The helper's non-zero return exists precisely to
# prevent that, and it only prevents it if the sole call site checks it. The
# `::error::` the helper already wrote to stderr carries the real cause.
SELECTED_PRS="$(devflow_select_audit_bundles "$AUDIT_BUNDLE_CAP" "$pattern")" || {
    blockers+=("Pattern ${SLUG}: occurrence selection failed — see the audit-bundle-selection ::error:: above for the cause; not dispatched to Stage B and not filed")
    SELECTED_PRS=""
    dispatch=0
}
selected=0; delivered=0; bundle_paths=()
for n in $SELECTED_PRS; do
    selected=$((selected + 1))
    BUNDLE="$REPO_ROOT/.devflow/tmp/pr-${n}.context.json"
    # fetch-pr-context.sh runs under `set -euo pipefail` and exits non-zero WITHOUT
    # writing a bundle when a gh call fails (auth, rate limit, a deleted PR). The
    # pre-existing `[ -s … ] ||` short-circuit means an already-present bundle is
    # DELIVERED without a fetch — so *delivered* is never a count of network fetches.
    # `-s`, not `-f`: fetch-pr-context.sh's terminal `> "$OUT_FILE"` TRUNCATES before
    # its composing jq runs, so an interrupted/OOM/full-disk run leaves a zero-byte
    # bundle that `-f` would both short-circuit on and count as evidence.
    # Test and deliver the SAME string — the absolute one — so a REPO_ROOT that
    # resolved oddly cannot make the guard pass on one path while a different one is
    # handed to Stage B.
    FETCH_ERR=""
    if [ ! -s "$BUNDLE" ]; then
        # Capture fetch-pr-context.sh's own diagnostics instead of discarding them:
        # an expired token, a deleted PR, an absent `gh` and a jq shape error are
        # fixed differently, and this is the path the cap makes most reachable.
        FETCH_ERR="$(bash $LIB/fetch-pr-context.sh "$n" 2>&1 >/dev/null || true)"
    fi
    if [ -s "$BUNDLE" ]; then
        delivered=$((delivered + 1))
        bundle_paths+=("$BUNDLE")
    else
        # A selected occurrence whose bundle is ABSENT (or zero-byte) after the fetch
        # attempt is excluded from the path array handed to Stage B and named in the
        # blockers — never handed to Stage B as a phantom path, and never counted as
        # evidence. The blocker quotes the fetcher's own diagnostic rather than
        # guessing the cause; when it wrote nothing, that absence is stated as such.
        blockers+=("Pattern ${SLUG}: occurrence PR #${n} bundle could not be fetched — ${FETCH_ERR:-fetch-pr-context.sh produced no diagnostic} — excluded from Stage B evidence")
    fi
done
# delivered == 0 (every selected bundle failed to fetch — the ordinary shape of a
# mid-run gh auth expiry once the cap made the selected set small): DO NOT dispatch
# this pattern to Stage B, record a blocker, and file NOTHING for it. Dispatching an
# empty bundle set would have Stage B re-derive a root cause from metadata alone and
# file an evidence-free issue that outlives the run. The decision is owned by
# devflow_audit_dispatch_ok (which also fails closed on an unestablished count), and
# `dispatch` is what 8b/8c read — the floor is a mechanism, not a comment.
if ! devflow_audit_dispatch_ok "$delivered"; then
    blockers+=("Pattern ${SLUG}: no occurrence bundle was delivered out of ${selected} selected — not dispatched to Stage B and not filed")
    dispatch=0
fi
# Truncation entry when Stage B was delivered fewer bundles than the pattern has
# occurrences. Carry `selected` too, so the renderer can name the fetch-failure gap
# (delivered < selected) distinctly from the cap-dropped gap. Built with jq so the
# element is valid JSON for the Step 9 slurp.
#
# Gated on `dispatch` as well: a pattern that was never dispatched contributed NO
# Stage B evidence at all, so rendering it under "Stage B read fewer occurrence
# bundles than the pattern has occurrences" would tell a reader a weakly-evidenced
# issue exists for it when none does — the same evidence overstatement this change
# removes, inverted. Its blocker above already covers it. Gated on a non-empty TOTAL
# too, since an unestablished total cannot establish a shortfall.
if [ "$dispatch" -eq 1 ] && [ -n "$TOTAL" ] && [ "$delivered" -lt "$TOTAL" ]; then
    # argjson-ok: delivered,total,selected -- bounded per-pattern counts (small integers capped by audit_bundle_cap / occurrence_count), never corpus-sized operands, so they carry no E2BIG risk (issue #894)
    TRUNC_ENTRY="$($LIB/../scripts/run-jq.sh -nc --arg tag "$TAG" \
        --argjson delivered "$delivered" --argjson total "$TOTAL" --argjson selected "$selected" \
        '{tag:$tag,delivered:$delivered,total:$total,selected:$selected}' 2>/dev/null || true)"
    # A failed build would otherwise append an EMPTY element that Step 9's
    # `map(select(. != null))` slurps away silently — the pattern's truncation record
    # vanishing with no diagnostic, which is exactly the silent evidence loss this
    # change exists to remove. Record it as a blocker instead.
    if [ -n "$TRUNC_ENTRY" ]; then
        truncations+=("$TRUNC_ENTRY")
    else
        blockers+=("Pattern ${SLUG}: the truncation record could not be built (delivered=${delivered}, total=${TOTAL}, selected=${selected}) — this pattern is absent from the run report's truncation section")
    fi
fi
```

The per-pattern `bundle_paths` array (absolute paths, *delivered* only) is what 8b
dispatches. **A pattern whose `dispatch` is `0` — a selector failure, or no bundle
delivered — is excluded from the 8b dispatch set and from the 8c filing set alike;
its blocker is what the run report carries for it.**

#### 8b — Dispatch all Stage B subagents concurrently

Issue **one Agent call per pattern whose `dispatch` is `1`, all in a single
message** so they run in parallel. A pattern whose 8a fence cleared `dispatch` gets
no Agent call at all — it has no delivered bundle, and dispatching it would have
Stage B re-derive a root cause from metadata alone. No worktree is created or passed
— the subagent makes no edits. Each dispatched subagent's prompt:

> Read and follow
> `"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../retrospective-audit/SKILL.md`
> exactly.
>
> Occurrence-PR context bundle paths (absolute): `<json array of DELIVERED paths>`
>
> Your bundle-path array is a **capped, most-recent-first subset** bounded by
> `audit_bundle_cap`: it holds `<delivered>` bundle(s) out of the pattern's
> `<total>` total occurrences. The pattern metadata's `occurrences[]` below remains
> the **authoritative full list** of occurrence PRs.
>
> Pattern metadata is on disk at the absolute path `<REPO_ROOT>/.devflow/tmp/pattern-<slug>.json` — read it with your file-read tool. It is handed to you by path, not inlined, because the enriched object carries every occurrence's free text (issue #893).
>
> Consumer prompt-extension handoff: your extension file for this skill is at the
> absolute path `<REPO_ROOT>/.devflow/prompt-extensions/retrospective-audit.md`.
> Read it with your file-read tool and honor any content as instructions appended
> to the retrospective-audit skill's own prompt. If the file is absent or empty,
> treat it as a no-op and report nothing about it; if it is present but you cannot
> read it, report that via the optional `extension_unreadable` key in your returned
> JSON object.
>
> Make **no** edits and **no** worktree. Print exactly one JSON object (the
> `findings`-array return contract from § 5 of that skill) and **nothing else**
> on stdout.

**Resolve `<REPO_ROOT>` before dispatch (by-path handoff, issue #834).** As in
Step 4, a subagent resolves no anchor of its own, so you (the orchestrator) resolve
the repository root (`git rev-parse --show-toplevel`) and substitute it for
`<REPO_ROOT>` in the handoff sentences above (both the pattern-metadata path and the
prompt-extension path). Append the sentence
**unconditionally** (it is inert when no extension exists), run **no** probe, and
read **no** extension file yourself — no extension content enters this
orchestrator's context. The child performs a file read, never a command
invocation, so no allowlist entry or permission grant is needed on any tier.

Wait for **all** subagents to finish. Pair each result JSON with its pattern.

#### 8c — File one issue per selected finding (serial, under the filing back-pressure caps)

The filing set is the patterns 8b dispatched — those whose `dispatch` is `1`. A
pattern excluded by the 8a floor never reaches a cap decision, is never counted
against `max_issues_per_run` or `max_open_issues`, and appears in the run report
through its 8a blocker rather than under a filing-cap heading.

Before filing, read the three back-pressure caps, and source the helper that owns
both the open-issue counts and the cap decision (issue #788). The counts are derived
from the
`overrides.json` lifecycle records — the meta-issue entries whose reconciled state
is `filed` — never from the `Retrospective` label query or a title parse, so a
human-applied label cannot consume the loop's budget and a loop-filed issue whose
best-effort label failed still counts:

```bash
MAX_PER_RUN="$(bash $LIB/../scripts/config-get.sh '.devflow_retrospective.max_issues_per_run' 3)"
MAX_OPEN="$(bash $LIB/../scripts/config-get.sh '.devflow_retrospective.max_open_issues' 10)"
MAX_PER_CAT="$(bash $LIB/../scripts/config-get.sh '.devflow_retrospective.max_open_per_category' 2)"
# Validate the caps HERE, once, before any pattern is judged. config-get.sh coerces
# whatever JSON the key holds into a string — an object arrives as `[object Object]`,
# `false` as `false` — so a single config typo makes devflow_filing_cap_verdict return
# `invalid-operand` for EVERY pattern, and the disposition prose records that as
# `{tag, cap: "invalid-operand"}` in `withheld`, which the report renders under
# "Patterns withheld by a filing cap" — indistinguishable from legitimate
# back-pressure. Aborting and naming the offending key is preferable to a broken
# config reading as a deliberately throttled week.
case "$MAX_PER_RUN" in
  ''|*[!0-9]*) echo "::error::retrospective Step 8c: .devflow_retrospective.max_issues_per_run is not a count (got '$MAX_PER_RUN') — aborting rather than withholding every pattern behind an invalid-operand verdict that would read as back-pressure" >&2
     exit 1 ;;
esac
case "$MAX_OPEN" in
  ''|*[!0-9]*) echo "::error::retrospective Step 8c: .devflow_retrospective.max_open_issues is not a count (got '$MAX_OPEN') — aborting rather than withholding every pattern behind an invalid-operand verdict that would read as back-pressure" >&2
     exit 1 ;;
esac
case "$MAX_PER_CAT" in
  ''|*[!0-9]*) echo "::error::retrospective Step 8c: .devflow_retrospective.max_open_per_category is not a count (got '$MAX_PER_CAT') — aborting rather than withholding every pattern behind an invalid-operand verdict that would read as back-pressure" >&2
     exit 1 ;;
esac
# Both cap comparands come from `lib/filing-decisions.sh`, which the suite drives
# over its arms — never from inline jq here. It is sourced at top level so its
# functions persist in this shell, which is safe because the helper deliberately
# sets NO shell options: an earlier `set -euo pipefail` in it leaked into this
# orchestrator, where a later benign non-zero would have aborted the run. If you
# ever add options to that helper, source it in a subshell instead.
source $LIB/filing-decisions.sh || {
  echo "::error::retrospective: lib/filing-decisions.sh could not be sourced — the filing decisions have no owner; aborting rather than silently withholding every pattern" >&2
  exit 1
}
# Initialize the per-run counter EXPLICITLY. Left unset it expands empty, which
# devflow_filing_cap_verdict correctly rejects as `invalid-operand` — withholding
# every pattern for the whole run. "Starts at 0" in prose is not a binding.
filed_this_run=0
```

`filed_this_run` is the only counter this orchestrator carries across patterns; you
increment it yourself after each successful filing. The two `filed`-count comparands
— the whole-file total and the per-category count for the slug — are **re-derived
from the overrides file inside the per-pattern block below**, not tracked here:
`meta-issue.sh` writes each pattern's lifecycle record as it files, so a fresh read
reflects the filings this run has done, and a re-derivation cannot drift the way a
hand-maintained running total can. The one filing a fresh read misses is
`meta-issue.sh`'s recovery path — a create that succeeded but whose lifecycle write
failed, which reports the issue as filed (exit 0 + URL + a loud `::error::`) with no
record on disk. That stays safe here because `filed_this_run` counts it regardless,
so the per-run cap still bounds the run; only the overrides-derived caps read one
filing low, and the next run's de-dupe restores the missing record.

Both count helpers fail **closed** by printing nothing — never `0` — when the
overrides file is missing, unreadable, or malformed. Do not default an empty
count to `0`: `devflow_filing_cap_verdict` reads the empty operand as
`invalid-operand` and withholds, whereas a laundered `0` would report an empty
backlog and file straight past both caps.

The pre-filing overrides snapshot Step 9 reads (`.devflow/tmp/overrides-prefiling.json`)
is taken in **Step 6**, not here. It must exist on *every* run: Step 8 is skipped
wholesale when nothing is actionable, so taking it here would leave Step 9 reading
an absent file on exactly the quiet runs this loop exists to make diagnosable —
and `devflow_declined_refiled` would then warn that the overrides file is
unreadable when it is perfectly intact.

For each `(pattern, result)` pair, bind `$STATUS` once — the operand both
`select-findings.sh` and the legacy cap check key the `regressed` bypass off. An
unbound `$STATUS` expands empty (never `"regressed"`), so the bypass would be dead at
runtime; an empty `$STATUS` is a WIRING failure, not a non-regressed pattern:

```bash
STATUS="$($LIB/../scripts/run-jq.sh -r --arg t "$TAG" '.[] | select((.tag // .slug) == $t) | .status' .devflow/tmp/patterns.json)"
case "$STATUS" in
  dismissed|regressed|declined|filed|fixed|open) : ;;
  *) echo "::error::retrospective Step 8c: could not bind a lifecycle status for pattern '$TAG' (got '$STATUS') — refusing to file on an unestablished status, which would silently disable the regressed bypass" >&2
     exit 1 ;;
esac
```

**Dispatch on the Stage B result's SHAPE (issue #893).** Write the subagent's raw
result to `.devflow/tmp/result-${SLUG}.json` with the **Write tool** first (it can
contain quotes, backticks, newlines, and `$` — never interpolate it inline into a
shell command). Then:

- A result carrying a `findings` array → the normal path. `lib/select-findings.sh`
  is the **owner of the selection on this path** (the legacy shape below is the other
  one, and never calls it): it composes and
  legality-checks each `<category>-<subslug>` key through the #891 composer, aliases a
  churned subslug onto an existing lifecycle record of the same category (equal token
  set), ranks by **descending** evidence-PR count and truncates to the top three, and
  asks `devflow_filing_cap_verdict` for **each finding's** cap decision (passing the running
  `filed_this_run`, so the per-run and open caps grow as issues are filed). You do
  **not** re-derive the per-category or open-total comparands here — the helper owns
  them. An **empty** `findings` array files nothing and records a per-pattern report
  line, distinct from the malformed blocker.
- A result carrying a top-level `title` and `body` and **no** `findings` array → the
  deployed-subagent coexistence path: treat it as one finding with an absent subslug
  and file under the **bare category key** (`--tag`/`--slug` = `$SLUG`), cap-checked
  exactly as at HEAD.
- A result carrying **neither** a `findings` array nor a `title`/`body` pair → the
  existing malformed blocker; file nothing.

You increment `filed_this_run` once per **issue filed** (not per pattern), and append
each filed finding's composed key to `filed_slugs` for Step 9's annotation.

```bash
# The wrapper precheck is a SEPARATE single-statement branch (no rc variable carried
# across statements — the inline-bash marshaling constraint the anchor note documents),
# so an unexpanded $LIB or missing/non-executable run-jq.sh is reported as the anchor
# failure it is, never misdiagnosed as a malformed subagent result. `[ ! -x ]` (not
# `[ ! -e ]`) so a PRESENT-but-non-executable wrapper (lost its +x bit → exit 126) is
# caught here rather than mis-read downstream.
if [ ! -x "$LIB/../scripts/run-jq.sh" ]; then
    blockers+=("Pattern ${SLUG}: run-jq.sh wrapper not found or not executable (unexpanded \$LIB notation, missing wrapper, or lost +x bit; fix the anchor) — not filed")

# Relay a child-reported unreadable consumer extension (issue #834) — informational,
# never blocks filing, and read on every non-anchor shape.
elif $LIB/../scripts/run-jq.sh -e '(.findings | type) == "array"' < ".devflow/tmp/result-${SLUG}.json" >/dev/null 2>&1; then
    # ── Findings-array path (issue #893): select-findings owns the selection ──
    EXT_UNREADABLE="$($LIB/../scripts/run-jq.sh -r '.extension_unreadable // empty' < ".devflow/tmp/result-${SLUG}.json")"
    [ -n "$EXT_UNREADABLE" ] && echo "::warning::retrospective Stage B (pattern ${SLUG}): consumer prompt extension for retrospective-audit present but unreadable: ${EXT_UNREADABLE}" >&2
    if [ "$($LIB/../scripts/run-jq.sh -r '.findings | length' < ".devflow/tmp/result-${SLUG}.json")" -eq 0 ]; then
        # Empty findings array: file nothing, record a per-pattern report LINE —
        # distinct from the malformed blocker (this pattern was well-formed; Stage B
        # simply found no distinct sub-pattern worth its own issue).
        skip_records+=("Pattern ${SLUG}: Stage B returned an empty findings array — nothing to file for this pattern")
    else
        # Ask select-findings which findings become filings. It sources the cap owner,
        # composes/legality-checks/aliases/ranks/truncates, and returns the to-file
        # array on stdout. A NON-ZERO exit is a withhold-everything condition (cap
        # owner unsourceable, or overrides absent/unreadable/unmigrated) — it prints
        # nothing and names the cause on its own ::error:: channel.
        $LIB/../scripts/run-jq.sh -c '.findings' < ".devflow/tmp/result-${SLUG}.json" > ".devflow/tmp/findings-${SLUG}.json"
        # GUARD the source. An unsourceable select-findings.sh leaves
        # devflow_select_findings undefined, and the `else` arm below would then
        # misattribute that to the helper's own withhold-everything condition — a cause
        # it is not. Report it as the missing-owner failure it is.
        # --withheld-file: select-findings writes a JSON array of {tag, cap} for every
        # finding a cap held back, so the report names them (issue #788) — not only its
        # own stderr breadcrumb. Read it back into `withheld` below.
        # --dropped-file: likewise for the top-three truncation — its notice is
        # stderr-only and we capture stdout, so without this channel the "N dropped"
        # count can never reach the run report.
        if ! source $LIB/select-findings.sh; then
            blockers+=("Pattern ${SLUG}: could not source lib/select-findings.sh (missing, unreadable, or a syntax error) — nothing filed for this pattern")
        elif TO_FILE="$(devflow_select_findings \
                --category "$CATEGORY" \
                --findings-file ".devflow/tmp/findings-${SLUG}.json" \
                --overrides .devflow/learnings/overrides.json \
                --status "$STATUS" \
                --filed-this-run "$filed_this_run" \
                --max-per-run "$MAX_PER_RUN" \
                --max-per-cat "$MAX_PER_CAT" \
                --max-open "$MAX_OPEN" \
                --withheld-file ".devflow/tmp/withheld-${SLUG}.json" \
                --dropped-file ".devflow/tmp/dropped-${SLUG}.json")"; then
            # Fold each cap-withheld finding into `withheld` so Step 9 reports it under
            # "withheld by a filing cap", exactly as the legacy path does.
            if [ -s ".devflow/tmp/withheld-${SLUG}.json" ]; then
                while IFS= read -r _wh; do
                    [ -n "$_wh" ] && withheld+=("$_wh")
                done < <($LIB/../scripts/run-jq.sh -c '.[]' < ".devflow/tmp/withheld-${SLUG}.json")
            fi
            # Fold a truncation record into `skip_records` — the same report channel the
            # empty-findings case uses — so the run names the pattern and the count that
            # Stage B returned but this selection dropped. The file holds an empty array
            # when nothing was dropped, so this emits nothing on the ordinary path.
            if [ -s ".devflow/tmp/dropped-${SLUG}.json" ]; then
                while IFS= read -r _dr; do
                    [ -n "$_dr" ] && skip_records+=("Pattern ${SLUG}: Stage B returned $($LIB/../scripts/run-jq.sh -r '.total' <<< "$_dr") findings — kept the top 3 by evidence-PR count, dropped $($LIB/../scripts/run-jq.sh -r '.dropped' <<< "$_dr")")
                done < <($LIB/../scripts/run-jq.sh -c '.[]' < ".devflow/tmp/dropped-${SLUG}.json")
            fi
            FINDINGS_N="$(printf '%s' "$TO_FILE" | $LIB/../scripts/run-jq.sh 'length')"
            _fi=0
            _pattern_filed=0   # reset PER PATTERN — a stale 1 from the previous pattern
                               # would annotate this one as filed on a run that filed nothing
            while [ "$_fi" -lt "$FINDINGS_N" ]; do
                # $KEY is the composed (or aliased) opaque filing key; it passes as
                # BOTH --tag and --slug (they share the [A-Za-z0-9_-]+ grammar the key
                # already satisfies), with the attribution --category alongside.
                KEY="$(printf '%s' "$TO_FILE" | $LIB/../scripts/run-jq.sh -r ".[$_fi].key")"
                printf '%s' "$TO_FILE" | $LIB/../scripts/run-jq.sh -r ".[$_fi].body"  > ".devflow/tmp/issue-body-${KEY}.md"
                F_TITLE="$(printf '%s' "$TO_FILE" | $LIB/../scripts/run-jq.sh -r ".[$_fi].title")"
                if ISSUE_URL="$(bash $LIB/meta-issue.sh --tag "$KEY" --slug "$KEY" --category "$CATEGORY" --title "$F_TITLE" --body-file ".devflow/tmp/issue-body-${KEY}.md" --overrides .devflow/learnings/overrides.json)"; then
                    intervention_issues+=("$($LIB/../scripts/run-jq.sh -nc --arg key "$KEY" --arg cat "$CATEGORY" --arg url "$ISSUE_URL" '{key:$key,category:$cat,url:$url}')")
                    filed_this_run=$((filed_this_run + 1))
                    _pattern_filed=1
                else
                    blockers+=("Finding ${KEY} (category ${CATEGORY}): meta-issue.sh failed to file the issue — not filed")
                fi
                _fi=$((_fi + 1))
            done
            # `filed_slugs` feeds Step 9's `devflow_annotate_patterns`, whose jq keys on
            # the PATTERN's coarse `.tag // .slug` — the attribution category. A composed
            # `<category>-<subslug>` key can never equal that, so pushing composed keys
            # here would annotate every pattern this path filed as "not filed". Push the
            # coarse $SLUG once per pattern instead; the composed keys are already the
            # report's per-issue surface via `intervention_issues`.
            [ "${_pattern_filed:-0}" -eq 1 ] && filed_slugs+=("$SLUG")
            # Same domain mismatch on the withheld side: the per-finding {tag, cap}
            # entries folded above carry composed keys and render correctly in the
            # "withheld by a filing cap" section, but `$wmap` is looked up by the coarse
            # tag. When a cap held back EVERY finding of this pattern, add one
            # coarse-tag entry so the pattern row still renders `withheld_by`, exactly
            # as the legacy path's single per-pattern entry does.
            if [ "${_pattern_filed:-0}" -ne 1 ] && [ -s ".devflow/tmp/withheld-${SLUG}.json" ]; then
                _FIRST_CAP="$($LIB/../scripts/run-jq.sh -r '.[0].cap // empty' < ".devflow/tmp/withheld-${SLUG}.json")"
                [ -n "$_FIRST_CAP" ] && withheld+=("$($LIB/../scripts/run-jq.sh -nc --arg tag "$SLUG" --arg cap "$_FIRST_CAP" '{tag:$tag,cap:$cap}')")
            fi
        else
            blockers+=("Pattern ${SLUG}: select-findings.sh withheld every finding (cap owner unsourceable, or overrides unreadable/unmigrated — see its ::error:: breadcrumb) — nothing filed")
        fi
    fi

elif $LIB/../scripts/run-jq.sh -e '.title and .body' < ".devflow/tmp/result-${SLUG}.json" >/dev/null 2>&1; then
    # ── Legacy title/body coexistence path: bare category key, cap-checked ────
    EXT_UNREADABLE="$($LIB/../scripts/run-jq.sh -r '.extension_unreadable // empty' < ".devflow/tmp/result-${SLUG}.json")"
    [ -n "$EXT_UNREADABLE" ] && echo "::warning::retrospective Stage B (pattern ${SLUG}): consumer prompt extension for retrospective-audit present but unreadable: ${EXT_UNREADABLE}" >&2
    source $LIB/filing-decisions.sh || {
      echo "::error::retrospective: lib/filing-decisions.sh could not be sourced — the filing decisions have no owner; aborting rather than silently withholding" >&2
      exit 1
    }
    PER_CAT="$(devflow_open_filed_for_category .devflow/learnings/overrides.json "$CATEGORY")"
    case "$PER_CAT" in
      ''|*[!0-9]*) echo "::error::retrospective Step 8c: could not derive the per-category filed count for category '$CATEGORY' (got '$PER_CAT') — the overrides file is missing, unreadable, or malformed; aborting rather than withholding every pattern behind an invalid-operand verdict that would read as back-pressure" >&2
           exit 1 ;;
    esac
    OPEN_TOTAL="$(devflow_open_filed_total .devflow/learnings/overrides.json)"
    case "$OPEN_TOTAL" in
      ''|*[!0-9]*) echo "::error::retrospective Step 8c: could not derive the total filed count (got '$OPEN_TOTAL') — the overrides file is missing, unreadable, or malformed; aborting rather than withholding every pattern behind an invalid-operand verdict that would read as back-pressure" >&2
           exit 1 ;;
    esac
    VERDICT="$(devflow_filing_cap_verdict "$STATUS" "$filed_this_run" "$MAX_PER_RUN" "$PER_CAT" "$MAX_PER_CAT" "$OPEN_TOTAL" "$MAX_OPEN")"
    if [ "$VERDICT" = file ]; then
        $LIB/../scripts/run-jq.sh -r '.body' < ".devflow/tmp/result-${SLUG}.json" > ".devflow/tmp/issue-body-${SLUG}.md"
        TITLE="$($LIB/../scripts/run-jq.sh -r '.title' < ".devflow/tmp/result-${SLUG}.json")"
        if ISSUE_URL="$(bash $LIB/meta-issue.sh --tag "$SLUG" --slug "$SLUG" --category "$CATEGORY" --title "$TITLE" --body-file ".devflow/tmp/issue-body-${SLUG}.md" --overrides .devflow/learnings/overrides.json)"; then
            intervention_issues+=("$($LIB/../scripts/run-jq.sh -nc --arg key "$SLUG" --arg cat "$CATEGORY" --arg url "$ISSUE_URL" '{key:$key,category:$cat,url:$url}')")
            filed_this_run=$((filed_this_run + 1)); filed_slugs+=("$SLUG")
        else
            blockers+=("Pattern ${SLUG}: meta-issue.sh failed to file the issue — not filed")
        fi
    else
        # Build the element with jq so what lands in `withheld` is valid JSON (Step 9
        # slurps it with `run-jq.sh -sc`).
        withheld+=("$($LIB/../scripts/run-jq.sh -nc --arg tag "$SLUG" --arg cap "$VERDICT" '{tag:$tag,cap:$cap}')")
    fi

else
    # Neither shape: record a blocker and file NOTHING (load-bearing failure path).
    blockers+=("Pattern ${SLUG}: Stage B subagent returned malformed JSON (neither a findings array nor a title/body pair) — not filed")
fi
```

**Never report a pattern as filed when it was not.** A malformed Stage B result
or a `meta-issue.sh` non-zero exit records a per-pattern blocker and the run
continues to the next pattern; the pattern is absent from `intervention_issues`.

**Do not** post `/devflow:implement` (or any auto-trigger comment) on a filed
issue — filed issues await human triage.

(`meta-issue.sh` mutates `.devflow/learnings/overrides.json` in your `main`
checkout's working tree. That happens **after** the Step 7 state PR was opened,
so the new lifecycle record lands in next week's state PR — see § Notes for the optional
follow-up commit if you want it in this run's PR.)

---

### Step 9 — Status report

Collect the per-analyzed-PR digest lines (verdict + a one-line summary) and the
**unfiltered** whole-pattern view produced by `actionable-patterns.sh --full` in
Step 6 (`patterns-full.json`) — every pattern with its lifecycle status
(`filed`/`fixed`/`declined`/`regressed`/`open`/`dismissed`), including the
suppressed and below-threshold ones — so `render-report.sh` shows the whole
picture, not just the actionable subset that produced an intervention:

```bash
ANALYZED_JSON="$($LIB/../scripts/run-jq.sh -sc '[.[] | select(.verdict == "imperfect" or .verdict == "blocked") | {pr, verdict, summary}]' .devflow/tmp/new-entries.jsonl)"
# The report's `.patterns` is the UNFILTERED whole-pattern view (patterns-full.json),
# not the filtered actionable list, so the report surfaces suppressed/below-threshold
# patterns instead of reading like a quiet week (issue #788).
# Annotate that view with each pattern's filing outcome for this run and, where a
# cap withheld it, that cap — the two per-pattern fields render-report.sh reads
# (issue #788). The `--full` view carries neither, so without this join both reads
# render nothing on every pattern.
source $LIB/filing-decisions.sh || {
  echo "::error::retrospective: lib/filing-decisions.sh could not be sourced — the filing decisions have no owner; aborting rather than silently withholding every pattern" >&2
  exit 1
}
FILED_SLUGS_JSON="$(printf '%s\n' "${filed_slugs[@]:-}" | $LIB/../scripts/run-jq.sh -sRc 'split("\n") | map(select(. != ""))')"
WITHHELD_JSON="$(printf '%s\n' "${withheld[@]:-}" | $LIB/../scripts/run-jq.sh -sc 'map(select(. != null))')"
PATTERNS_JSON="$(devflow_annotate_patterns .devflow/tmp/patterns-full.json "$FILED_SLUGS_JSON" "$WITHHELD_JSON")"
RECURRING_TARGETS_JSON="$(bash $LIB/recurring-targets.sh .devflow/learnings/retrospectives.jsonl)"

# The liveness line actionable-patterns.sh wrote to stderr in Step 6, and the
# won't-fix patterns this run re-raised — the two remaining report sections
# (issue #788). Both come from the same tested helper; both are empty on a run
# that produced neither, and render-report.sh then omits their sections.
LIVENESS_WARNING="$(devflow_liveness_warning .devflow/tmp/patterns.stderr)"
DECLINED_REFILED_JSON="$(devflow_declined_refiled .devflow/tmp/overrides-prefiling.json "$FILED_SLUGS_JSON")"

# Truncation entries (issue #894): the {tag, delivered, total, selected} objects
# Step 8a appended for every pattern the audit_bundle_cap (or a fetch failure)
# truncated. Assembled from the pre-declared `truncations` bash array into a shell
# variable guarded by :? and passed with --slurpfile — the same carrier shape the
# `withheld` array uses. `[]` at minimum on a run that truncated nothing.
TRUNCATIONS_JSON="$(printf '%s\n' "${truncations[@]:-}" | $LIB/../scripts/run-jq.sh -sc 'map(select(. != null))')"

# Filing-queue aggregate operands (issue #894), derived HERE in Step 9 reusing NO
# Step 8 binding: the line reports the LIVE post-filing queue, while Step 8c's
# OPEN_TOTAL/MAX_OPEN were a per-iteration PRE-filing snapshot that was already
# stale by the time the report renders. N = open filed meta-issue entries via
# devflow_open_filed_total (never recomputed inline); M = resolved max_open_issues.
# Both are passed as --arg STRINGS (below), so an UNESTABLISHED value is the empty
# string — rendered `unavailable`, never laundered to 0. devflow_open_filed_total
# prints NOTHING (not 0) when unestablished, which is exactly that empty string;
# neither operand is :?-guarded, because empty is a valid "unavailable" state here.
FILING_QUEUE_OPEN="$(devflow_open_filed_total .devflow/learnings/overrides.json)"
FILING_QUEUE_MAX="$(bash $LIB/../scripts/config-get.sh '.devflow_retrospective.max_open_issues' 10)"
```

`recurring-targets.sh` groups every accumulated entry's
`suggested_interventions[].candidate_targets[]` by exact target path and emits
only the targets named in ≥2 distinct PRs (report-only; `[]` when nothing
recurs, which `render-report.sh` then omits).

Build the summary JSON and assign it to `$SUMMARY_JSON`:

```bash
# Route the corpus-sized operands (the --slurpfile flags below) through files rather
# than --argjson argv slots: they grow with the corpus and, as argv slots, overflow the
# kernel arg limit at scale (jq: "Argument list too long", issue #783). --slurpfile wraps
# each file in a one-element array, so the jq program dereferences [0].
_SUMMARY_TMP="$(mktemp -d)"
trap 'rm -rf "$_SUMMARY_TMP"' EXIT
# Preserve --argjson's fail-loud-on-empty semantics after the #783 --slurpfile switch:
# an empty operand slurps to []→[0]=null (silent) where --argjson aborted loud. These
# three are upstream producer output, valid JSON ([] at minimum) on success — an empty
# string means that producer failed, so fail loud rather than emit analyzed/patterns:null.
: "${ANALYZED_JSON:?devflow retrospective Step 9: ANALYZED_JSON is empty — upstream Stage-A analysis failed}"
: "${PATTERNS_JSON:?devflow retrospective Step 9: PATTERNS_JSON is empty — devflow_annotate_patterns printed nothing over .devflow/tmp/patterns-full.json (missing, empty, or unreadable)}"
: "${RECURRING_TARGETS_JSON:?devflow retrospective Step 9: RECURRING_TARGETS_JSON is empty — recurring-targets.sh failed}"
# Same fail-loud property for the two #788 operands: both helpers print at
# minimum `[]` on success, so an empty string is producer failure, not "nothing
# to report". (LIVENESS_WARNING is deliberately NOT guarded — an empty string is
# its normal no-warning value, and it is passed as --arg, never slurped.)
: "${WITHHELD_JSON:?devflow retrospective Step 9: WITHHELD_JSON is empty — the Step 8c withheld producer failed}"
: "${DECLINED_REFILED_JSON:?devflow retrospective Step 9: DECLINED_REFILED_JSON is empty — devflow_declined_refiled failed}"
: "${TRUNCATIONS_JSON:?devflow retrospective Step 9: TRUNCATIONS_JSON is empty — the Step 8a truncation producer failed}"
printf '%s\n' "${skip_records[@]:-}"        | $LIB/../scripts/run-jq.sh -sRc 'split("\n") | map(select(. != ""))' > "$_SUMMARY_TMP/skips.json"
printf '%s' "$ANALYZED_JSON"                > "$_SUMMARY_TMP/analyzed.json"
printf '%s' "$PATTERNS_JSON"                > "$_SUMMARY_TMP/patterns.json"
printf '%s' "$RECURRING_TARGETS_JSON"       > "$_SUMMARY_TMP/recurring_targets.json"
printf '%s\n' "${intervention_issues[@]:-}" | $LIB/../scripts/run-jq.sh -sc '.' > "$_SUMMARY_TMP/intervention_issues.json"
printf '%s\n' "${cooldown_skipped[@]:-}"    | $LIB/../scripts/run-jq.sh -sc '.' > "$_SUMMARY_TMP/cooldown_skipped.json"
# blockers carry RAW PROSE (every `blockers+=(…)` append is a plain string), so
# they are slurped with the raw `-sRc split` shape `skips` uses — NOT the JSON
# `-sc '.'` slurp, under which a non-empty prose element is a jq parse error that
# leaves blockers.json empty and trips the Step 9 empty-file guard, aborting the
# run and losing every blocker (issue #894: Step 8a now adds frequently-reached
# blocker paths, making this pre-existing latent defect reachable on ordinary runs).
printf '%s\n' "${blockers[@]:-}"            | $LIB/../scripts/run-jq.sh -sRc 'split("\n") | map(select(. != ""))' > "$_SUMMARY_TMP/blockers.json"
# withheld_patterns (issue #788): each {tag, cap} the Step-8 caps held back, and
# declined_refiled: the slugs whose meta-issue was previously closed NOT_PLANNED.
# Both are `[]` on a run that produced neither, which render-report omits.
printf '%s' "$WITHHELD_JSON"                > "$_SUMMARY_TMP/withheld_patterns.json"
printf '%s' "$DECLINED_REFILED_JSON"        > "$_SUMMARY_TMP/declined_refiled.json"
printf '%s' "$TRUNCATIONS_JSON"             > "$_SUMMARY_TMP/truncations.json"
# Same fail-loud property for the four INLINE producers above. Their `> file` redirect
# truncates the file before the pipeline runs, so a failing jq leaves the file EMPTY.
# The reachable causes differ by slurp shape: an unresolvable jq binary fails all four,
# while a malformed element is a parse error only under the JSON `-sc '.'` shape
# (intervention_issues, cooldown_skipped) — the raw `-sRc split` shape (skips,
# blockers) takes its elements as text and cannot parse-error on them. An empty --slurpfile
# operand is []→[0]=null, silently emitting skips/blockers:null where --argjson aborted
# loud. On success each writes at minimum `[]` (non-empty), so an empty file is
# unambiguously producer failure. Guard by file, not by variable, because these operands
# never pass through a shell variable.
for _op in skips intervention_issues cooldown_skipped blockers; do
  [ -s "$_SUMMARY_TMP/$_op.json" ] || {
    echo "devflow retrospective Step 9: $_op.json is empty — its inline jq producer failed" >&2
    rm -rf "$_SUMMARY_TMP"; exit 1
  }
done
# argjson-ok: prs_scanned, clean_count, analyzed_count, skipped_count, state_pr --
# bounded scalars (counts and one PR number) — safe as argv.
SUMMARY_JSON="$($LIB/../scripts/run-jq.sh -nc \
  --argjson prs_scanned           "$prs_scanned" \
  --argjson clean_count           "$clean_count" \
  --argjson analyzed_count        "$analyzed_count" \
  --argjson skipped_count         "$skipped_count" \
  --slurpfile skips               "$_SUMMARY_TMP/skips.json" \
  --slurpfile analyzed            "$_SUMMARY_TMP/analyzed.json" \
  --slurpfile patterns            "$_SUMMARY_TMP/patterns.json" \
  --slurpfile recurring_targets   "$_SUMMARY_TMP/recurring_targets.json" \
  --slurpfile intervention_issues "$_SUMMARY_TMP/intervention_issues.json" \
  --slurpfile cooldown_skipped    "$_SUMMARY_TMP/cooldown_skipped.json" \
  --slurpfile blockers            "$_SUMMARY_TMP/blockers.json" \
  --slurpfile withheld_patterns   "$_SUMMARY_TMP/withheld_patterns.json" \
  --slurpfile declined_refiled    "$_SUMMARY_TMP/declined_refiled.json" \
  --slurpfile truncations         "$_SUMMARY_TMP/truncations.json" \
  --arg       liveness_warning    "$LIVENESS_WARNING" \
  --arg       filing_queue_open   "$FILING_QUEUE_OPEN" \
  --arg       filing_queue_max    "$FILING_QUEUE_MAX" \
  --argjson state_pr              "$STATE_PR" \
  '{prs_scanned:$prs_scanned,clean_count:$clean_count,analyzed_count:$analyzed_count,
    skipped_count:$skipped_count,skips:$skips[0],
    analyzed:$analyzed[0],patterns:$patterns[0],recurring_targets:$recurring_targets[0],
    intervention_issues:$intervention_issues[0],
    cooldown_skipped:$cooldown_skipped[0],blockers:$blockers[0],
    withheld_patterns:$withheld_patterns[0],declined_refiled:$declined_refiled[0],
    truncations:$truncations[0],
    liveness_warning:$liveness_warning,
    filing_queue_open:$filing_queue_open,filing_queue_max:$filing_queue_max,
    state_pr:$state_pr}')"
rm -rf "$_SUMMARY_TMP"
```

(The `"${array[@]:-}"` form handles an empty bash array safely under `set -u`.
`render-report.sh` renders the `analyzed` and `patterns` sections only when
those keys are non-empty, so an older caller that omits them still works.)

Render the report markdown and post it as a comment on the state PR:

```bash
source $LIB/render-report.sh
devflow_render_report "$SUMMARY_JSON" > .devflow/tmp/report.md
bash $LIB/post-status.sh --pr "$STATE_PR" --report-file .devflow/tmp/report.md
```

---

### Step 10 — Report to the user

Print the rendered report (`cat .devflow/tmp/report.md`) to the console.

Then list each item that needs human action:

- **State PR** (contains the updated retrospectives): `https://github.com/<repo>/pull/<state_pr>`
- **Filed issues** (one per actionable pattern, awaiting human triage): list
  each as `<tag>: <url>`

If there are any **blockers**, list them explicitly.

Tell the user:

> Review and merge the state PR once CI passes. Each filed issue awaits human
> triage — pick the ones worth acting on and run them through the normal
> implement → review pipeline; the loop never starts that for you. The loop is
> idempotent — re-running next week will only process new PRs not yet in
> `retrospectives.jsonl` on `main`, and a pattern already filed this cycle is
> not re-filed.

Do **not** run `gh pr merge --auto` on anything, and do **not** auto-start
implementation on a filed issue. The maintainer triages and merges manually
after reviewing.

---

## § Notes

- **Clean working tree required.** The loop modifies `.devflow/learnings/`
  in-place on `main`'s working tree; starting dirty risks mixing pre-existing
  changes into the state PR commit.
- **State PR before Stage B.** Opening the state PR (Step 7) before Stage B is
  intentional: it commits the learnings files onto `devflow/learnings-<date>`
  before any issue is filed, so this run's retrospective data is captured even
  if Stage B or the filing step fails partway. Stage B never touches your `main`
  checkout — it makes no edits at all.
- **Issue-per-finding.** Stage B dispatches one drafting subagent per actionable
  pattern concurrently (each returns a ranked `findings` array of one to three
  sub-patterns, no edits), then `lib/select-findings.sh` decides which findings
  become filings and the orchestrator files one GitHub issue per selected finding via
  `meta-issue.sh` under an opaque `<category>-<subslug>` key. No worktrees, no
  commits, no PRs — the loop proposes; a human implements.
- **Overrides after Stage B.** `meta-issue.sh` records each filed pattern's
  lifecycle entry in `.devflow/learnings/overrides.json` in your `main` working tree
  **after** the Step 7 state PR was opened, so the change lands in next week's
  state PR automatically. If you want it in *this* run's PR, after Step 8 push a
  follow-up commit onto the same `devflow/learnings-<date>` branch:

  ```bash
  if ! git diff --quiet HEAD -- .devflow/learnings/overrides.json 2>/dev/null; then
      LB="devflow/learnings-$(date -u +%F)"
      git fetch origin "$LB"
      git checkout "$LB"
      git add .devflow/learnings/overrides.json
      git commit -m "chore(devflow): add overrides from Stage B filed issues"
      git push --force-with-lease origin "$LB"
      git checkout main
  fi
  ```
- **Idempotent.** Re-running re-processes only PRs whose number is not already
  in `retrospectives.jsonl` on `main`. A pattern already filed this cycle is not
  re-filed: `meta-issue.sh` finds the open issue and adds a recurrence comment
  instead of a duplicate, and the pattern's `filed` lifecycle record in
  `overrides.json` excludes it on subsequent runs.
- **Never auto-merge, never auto-implement.** The maintainer merges the state PR
  manually after CI, and triages each filed issue manually — the loop never
  starts an implement run for you.
- **`materialize-retrospectives.sh` signature:** takes two explicit positional
  args — `<new-entries-file>` and `<jsonl-path>`. Always pass both.
- **`actionable-patterns.sh` signature:** takes two required positional args
  — `<retrospectives.jsonl>` and `<overrides.json>` — plus an optional third,
  `--full`, which emits the unfiltered whole-pattern view the run report
  renders (issue #788). Always pass both required args; pass `--full` only for
  the report view. An unrecognized third argument is rejected with rc 2.
- **`open-state-pr.sh` signature:** no required args; optional `--branch`,
  `--base` (defaults to `main`), `--dry-run`; prints the PR number
  to stdout.
- **`fetch-pr-context.sh` return value:** echoes the bundle *file path* to
  stdout; the bundle content is on disk at `.devflow/tmp/pr-<n>.context.json`.
- **`cheap-gate.jq` invocation:** reads from stdin (the bundle content, not
  the path) — use `$LIB/../scripts/run-jq.sh -c -f $LIB/cheap-gate.jq < "$CTX"` where `$CTX` is
  the path.
