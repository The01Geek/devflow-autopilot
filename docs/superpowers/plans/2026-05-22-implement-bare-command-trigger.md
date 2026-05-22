# Trigger `/devflow:implement` on a Bare Command (Decouple from `claude.yml`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `claude-implement.yml` fire on a bare `/devflow:implement <#>` comment/issue (no `@claude`), so an adopter's existing `claude.yml` never needs editing and the two workflows can never double-fire on the normal path.

**Architecture:** `claude-implement.yml` already calls `anthropics/claude-code-action@v1` directly and already synthesises an explicit `prompt:` for the label path. We extend that to *every* path: a new `gate` job authorizes the actor (cost control, since agent mode runs for anyone) and resolves the target issue number via a small, unit-tested shell helper; the `claude` job then runs in agent mode with a normalized `prompt: /devflow:implement <n>`. Because the action only auto-fires in *tag* mode on its `@claude` phrase, a stock `claude.yml` never reacts to a bare `/devflow:implement` comment — so **`claude.yml` is not touched**.

**Tech Stack:** GitHub Actions (composite jobs, `anthropics/claude-code-action@v1`), Bash (POSIX-ish, shellcheck-clean), the repo's `lib/test/run.sh` harness (`assert_eq` + `gh` stubs), `actionlint`.

---

## Why this design (read before starting)

- **The coupling we are removing:** today the implement comment contains `@claude`, so `claude.yml` *and* `claude-implement.yml` both match. That is the only reason `claude.yml` carries its `&& !contains(..., '/devflow:implement')` exclusion clause. Dropping `@claude` from the implement trigger makes the bare command invisible to a tag-mode `claude.yml`, so no exclusion edit is ever required in an adopter's file.
- **The cost of dropping `@claude`:** in tag mode the action only responds to users with write access. In **agent mode (explicit `prompt:`) it runs for ANY actor.** So we MUST add an authorization gate (allowed-bot OR write/admin/maintain collaborator) — the same pattern `devflow-review.yml` uses inline at lines 170–204. We extract it into a tested helper instead of inlining, because (a) the repo's convention is small tested shell helpers (`lib/test/run.sh` + `gh` stubs), and (b) it keeps untested bash out of YAML.
- **We do NOT touch `claude.yml`.** Its exclusion clause stays; it remains correct for the edge case where someone types `@claude /devflow:implement <#>` (tag-mode `claude.yml` skips it; our `gate` still matches on `/devflow:implement`). The canonical, documented trigger becomes the bare command.
- **Prompt normalization:** instead of forwarding raw user text, the gate resolves a single integer and the action always gets `prompt: /devflow:implement <n>`. This is deterministic and avoids passing arbitrary comment text into the run.

## File Structure

- **Create** `scripts/resolve-implement-trigger.sh` — pure-ish resolver: authorize actor + resolve target issue number; prints `should_run=` and `number=` lines. One responsibility: "should this implement trigger run, and on which issue?"
- **Modify** `lib/test/run.sh` — add a unit-test section for the resolver (uses an inline `gh` permission stub, mirroring the existing `DSR_STUB` pattern).
- **Modify** `.github/workflows/claude-implement.yml` — add the `gate` job; rewrite the `claude` job's `needs:`/`if:`/`prompt:`; add `track_progress: true`; rewrite the header comment.
- **Modify** `README.md`, `docs/cloud-setup.md`, `CHANGELOG.md` — document the bare-command trigger.
- **Untouched:** `.github/workflows/claude.yml` (by design).

---

### Task 1: The trigger resolver script (authorize + resolve number)

**Files:**
- Create: `scripts/resolve-implement-trigger.sh`
- Test: `lib/test/run.sh` (append a new section before the python-scripts block, near line 672)

- [ ] **Step 1: Write the failing test**

Append this block to `lib/test/run.sh` immediately AFTER the last shell-helper section and BEFORE the `# python scripts` section (the `PY_OUT="$(python3 ...)"` line, ~line 674). It follows the file's existing `assert_eq` + section-divider style.

```bash
# ────────────────────────────────────────────────────────────────────────────
echo "resolve-implement-trigger.sh"
# ────────────────────────────────────────────────────────────────────────────
# The implement trigger runs the action in AGENT mode (explicit prompt), which
# executes for ANY actor — so this resolver is the cost/authorization gate AND
# the issue-number resolver. Tests stub `gh` for the collaborator-permission
# call; the allowed-bot path never reaches `gh`.
RIT="$LIB/../scripts/resolve-implement-trigger.sh"

# Inline gh stub: returns whatever STUB_PERM says for a collaborator-permission
# query (the script passes --jq '.permission'; like gh-stub.sh we ignore --jq
# and emit the already-extracted value), empty otherwise.
RIT_STUB_DIR="$(mktemp -d)"
cat > "$RIT_STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"collaborators/"*"/permission"*) echo "${STUB_PERM:-none}" ;;
  *) echo "" ;;
esac
STUB
chmod +x "$RIT_STUB_DIR/gh"

# 1. Allowed bot + label event → run on the labelled issue. `foo[bot]` actor
#    must match the bare `foo` in allowed_bots. No gh call on this path.
OUT="$(ACTOR='foo[bot]' ALLOWED_BOTS='foo,bar' REPO='acme/x' \
  IS_LABEL_EVENT='true' TRIGGER_TEXT='' CONTEXT_NUMBER='42' \
  PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: allowed bot, label event → should_run" \
  "should_run=true" "$(echo "$OUT" | grep '^should_run=')"
assert_eq "rit: allowed bot, label event → number" \
  "number=42" "$(echo "$OUT" | grep '^number=')"

# 2. Write collaborator + explicit number in comment → run on that number.
OUT="$(ACTOR='alice' ALLOWED_BOTS='' REPO='acme/x' IS_LABEL_EVENT='false' \
  TRIGGER_TEXT='/devflow:implement 7' CONTEXT_NUMBER='99' \
  STUB_PERM='write' PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: write collaborator, explicit number → should_run" \
  "should_run=true" "$(echo "$OUT" | grep '^should_run=')"
assert_eq "rit: explicit number beats context" \
  "number=7" "$(echo "$OUT" | grep '^number=')"

# 3. Non-collaborator (gh → 'none') → blocked, no number.
OUT="$(ACTOR='stranger' ALLOWED_BOTS='' REPO='acme/x' IS_LABEL_EVENT='false' \
  TRIGGER_TEXT='/devflow:implement 7' CONTEXT_NUMBER='99' \
  STUB_PERM='none' PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: non-collaborator → should_run=false" \
  "should_run=false" "$(echo "$OUT" | grep '^should_run=')"
assert_eq "rit: non-collaborator → empty number" \
  "number=" "$(echo "$OUT" | grep '^number=')"

# 4. Authorized but NO number anywhere → blocked (can't implement nothing).
OUT="$(ACTOR='alice' ALLOWED_BOTS='' REPO='acme/x' IS_LABEL_EVENT='false' \
  TRIGGER_TEXT='/devflow:implement please' CONTEXT_NUMBER='' \
  STUB_PERM='admin' PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: no resolvable number → should_run=false" \
  "should_run=false" "$(echo "$OUT" | grep '^should_run=')"

# 5. Authorized, no explicit number but a context issue → fall back to context.
OUT="$(ACTOR='alice' ALLOWED_BOTS='' REPO='acme/x' IS_LABEL_EVENT='false' \
  TRIGGER_TEXT='/devflow:implement' CONTEXT_NUMBER='5' \
  STUB_PERM='maintain' PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: fallback to context number" \
  "number=5" "$(echo "$OUT" | grep '^number=')"

rm -rf "$RIT_STUB_DIR"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash lib/test/run.sh 2>&1 | grep -i 'rit:'`
Expected: FAIL lines for the `rit:` assertions (script does not exist yet → `bash: .../resolve-implement-trigger.sh: No such file or directory`, assertions mismatch).

- [ ] **Step 3: Write the resolver script**

Create `scripts/resolve-implement-trigger.sh` with exactly:

```bash
#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Resolve whether a /devflow:implement trigger should run, and on which issue.
#
# claude-implement.yml runs claude-code-action in AGENT mode with an explicit,
# synthesised `/devflow:implement <n>` prompt. Agent mode does NOT need the
# `@claude` phrase, so a stock claude.yml (tag mode, keyed on `@claude`) never
# double-fires on a bare `/devflow:implement <n>` comment. The trade-off: agent
# mode runs for ANY actor, so this script is the cost/authorization gate.
#
# Inputs (env):
#   ACTOR           triggering login (github.event.sender.login); a trailing
#                   `[bot]` suffix is tolerated.
#   ALLOWED_BOTS    comma-separated bare bot logins from config.
#   REPO            owner/repo, for the collaborator-permission API call.
#   IS_LABEL_EVENT  "true" when the trigger is the implement label being added
#                   (no command text — use CONTEXT_NUMBER).
#   TRIGGER_TEXT    the comment / review / issue title+body that fired (empty
#                   on the label path).
#   CONTEXT_NUMBER  the issue/PR number the event is attached to: the fallback
#                   target when TRIGGER_TEXT has no explicit number, and the
#                   sole target on the label path.
#   GH_TOKEN        token for `gh api` (collaborator check), set by the caller.
#
# Output: two `key=value` lines on stdout (the caller appends them to
# $GITHUB_OUTPUT; tests assert them directly):
#   should_run=true|false
#   number=<n>|""
#
# should_run is true ONLY when the actor is authorized AND a number resolves.
# Fails CLOSED on any ambiguity. Diagnostics go to stderr as ::warning:: lines.

set -euo pipefail

emit() { printf '%s=%s\n' "$1" "$2"; }

actor="${ACTOR:-}"
allowed_bots="${ALLOWED_BOTS:-}"
repo="${REPO:-}"
is_label="${IS_LABEL_EVENT:-false}"
text="${TRIGGER_TEXT:-}"
context_number="${CONTEXT_NUMBER:-}"

# --- Authorization (cost control: agent mode runs for any actor) ------------
authorized=false
actor_bare="${actor%\[bot\]}"
IFS=',' read -ra bots <<< "$allowed_bots"
for b in "${bots[@]}"; do
  bt="$(echo "$b" | xargs)"            # trim surrounding whitespace
  if [ -n "$bt" ] && { [ "$bt" = "$actor" ] || [ "$bt" = "$actor_bare" ]; }; then
    authorized=true
  fi
done
if [ "$authorized" != "true" ] && [ -n "$actor" ] && [ -n "$repo" ]; then
  perm="$(gh api "repos/$repo/collaborators/$actor/permission" \
            --jq '.permission' 2>/dev/null || echo "none")"
  case "$perm" in admin|write|maintain) authorized=true ;; esac
fi
if [ "$authorized" != "true" ]; then
  echo "::warning::/devflow:implement requested by '$actor' who is not an allowed bot or write/admin collaborator; skipping (cost control)." >&2
  emit should_run false
  emit number ""
  exit 0
fi

# --- Target number resolution -----------------------------------------------
number=""
if [ "$is_label" = "true" ]; then
  number="$context_number"
else
  # First explicit `/devflow:implement <n>` (optional leading #) wins.
  match="$(printf '%s' "$text" \
    | grep -oiE '/devflow:implement[[:space:]]+#?[0-9]+' | head -n1 || true)"
  number="$(printf '%s' "$match" | grep -oE '[0-9]+' | head -n1 || true)"
  # Otherwise fall back to the issue/PR the event is attached to.
  [ -z "$number" ] && number="$context_number"
fi

if ! [[ "$number" =~ ^[0-9]+$ ]]; then
  echo "::warning::Could not resolve an issue number for /devflow:implement; skipping." >&2
  emit should_run false
  emit number ""
  exit 0
fi

emit should_run true
emit number "$number"
```

- [ ] **Step 4: Make it executable**

Run: `chmod +x scripts/resolve-implement-trigger.sh`

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash lib/test/run.sh 2>&1 | grep -i 'rit:'`
Expected: every `rit:` line shows `PASS`.

- [ ] **Step 6: Shellcheck the new script**

Run: `shellcheck --severity=warning -e SC1091 scripts/resolve-implement-trigger.sh`
Expected: no output (clean). This is exactly what CI's lint job runs.

- [ ] **Step 7: Commit**

```bash
git add scripts/resolve-implement-trigger.sh lib/test/run.sh
git commit -m "feat(implement): add trigger resolver (authorize actor + resolve issue number)"
```

---

### Task 2: Wire the `gate` job and switch the `claude` job to agent mode

**Files:**
- Modify: `.github/workflows/claude-implement.yml` (add `gate` job after the `config` job ~line 86; edit the `claude` job header ~lines 88–104 and `prompt:` ~line 145)

- [ ] **Step 1: Add the `gate` job**

Insert this job immediately after the `config` job (after line 86, before `claude:`):

```yaml
  # Authorization + target-number gate. The action runs in AGENT mode below
  # (explicit prompt), which executes for ANY actor, so this job is the cost
  # control: it runs the resolver, which authorizes the sender (allowed bot OR
  # write/admin/maintain collaborator) and resolves the issue number. The
  # `claude` job runs ONLY when should_run=true. Coarse event matching stays in
  # this job's `if:` so irrelevant events never spin a runner.
  gate:
    needs: config
    if: |
      needs.config.outputs.enabled == 'true' &&
      (
        (github.event_name == 'issue_comment' && contains(github.event.comment.body, '/devflow:implement')) ||
        (github.event_name == 'pull_request_review_comment' && contains(github.event.comment.body, '/devflow:implement')) ||
        (github.event_name == 'pull_request_review' && contains(github.event.review.body, '/devflow:implement')) ||
        (github.event_name == 'issues' && github.event.action == 'opened' && (contains(github.event.issue.body, '/devflow:implement') || contains(github.event.issue.title, '/devflow:implement'))) ||
        (github.event_name == 'issues' && github.event.action == 'labeled' && github.event.label.name == needs.config.outputs.trigger_label)
      )
    runs-on: ubuntu-latest
    permissions:
      contents: read   # checkout the resolver script; collaborator check uses GITHUB_TOKEN
    outputs:
      should_run: ${{ steps.resolve.outputs.should_run }}
      number: ${{ steps.resolve.outputs.number }}
    steps:
      - uses: actions/checkout@v6
      - id: resolve
        env:
          GH_TOKEN: ${{ github.token }}
          REPO: ${{ github.repository }}
          # `sender` is present on every event here and equals the actor:
          # commenter / reviewer / issue opener / labeller respectively.
          ACTOR: ${{ github.event.sender.login }}
          ALLOWED_BOTS: ${{ needs.config.outputs.allowed_bots }}
          IS_LABEL_EVENT: ${{ github.event_name == 'issues' && github.event.action == 'labeled' && github.event.label.name == needs.config.outputs.trigger_label }}
          # issue.number for issues + issue_comment (PRs are issues); falls back
          # to pull_request.number for the review events.
          CONTEXT_NUMBER: ${{ github.event.issue.number || github.event.pull_request.number }}
          # Only the populated field contributes; passed as an env var (not
          # interpolated into bash), so arbitrary body text cannot inject.
          TRIGGER_TEXT: ${{ github.event.comment.body || github.event.review.body || format('{0} {1}', github.event.issue.title, github.event.issue.body) }}
        run: |
          set -euo pipefail
          bash scripts/resolve-implement-trigger.sh >> "$GITHUB_OUTPUT"
```

- [ ] **Step 2: Repoint the `claude` job at the gate**

In the `claude` job, change `needs: config` (line ~89) to:

```yaml
    needs: [config, gate]
```

Then replace the entire `@claude`-based `if:` block (the current lines ~95–103, from `if: |` through the closing `)`) with:

```yaml
    if: needs.gate.outputs.should_run == 'true'
```

- [ ] **Step 3: Always synthesise the prompt (agent mode on every path)**

Replace the `prompt:` input (current line ~145, the `(github.event_name == 'issues' ...) || ''` ternary) with:

```yaml
          # Always agent mode: the gate resolved a single issue number, so the
          # action never depends on `@claude` or on reading the raw body. A
          # stock claude.yml (tag mode) therefore never double-fires on a bare
          # `/devflow:implement <n>` comment.
          prompt: ${{ format('/devflow:implement {0}', needs.gate.outputs.number) }}
```

- [ ] **Step 4: Add progress visibility**

Agent mode posts no tracking comment by default. Directly after the `prompt:` block, add:

```yaml
          # Agent mode is silent by default; surface a progress comment so the
          # requester sees the run was picked up (applies to all paths now).
          track_progress: true
```

- [ ] **Step 5: Validate workflow syntax**

Run: `actionlint .github/workflows/claude-implement.yml`
Expected: no output (clean). If `actionlint` is not installed locally, note it and rely on the CI `lint` job; do not skip silently.

- [ ] **Step 6: Confirm `claude.yml` is untouched**

Run: `git status --porcelain .github/workflows/claude.yml`
Expected: empty output (no changes to `claude.yml` — the whole point of this change).

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/claude-implement.yml
git commit -m "feat(implement): trigger on bare /devflow:implement (agent mode + auth gate), no @claude"
```

---

### Task 3: Rewrite the workflow header comment

**Files:**
- Modify: `.github/workflows/claude-implement.yml:1-34` (the header comment block)

- [ ] **Step 1: Replace the header comment**

Replace the existing header comment (lines 1–34, everything from `name:` description down to the blank line before `on:`) with one that describes the new model. Use exactly:

```yaml
name: Claude Code (implement)

# Heavy listener for /devflow:implement. Fires on a BARE `/devflow:implement
# <#>` comment, review, or issue body/title — and on the
# `claude_implement.trigger_label` being added to an issue. It does NOT require
# `@claude`.
#
# Why no `@claude`: this workflow runs claude-code-action in AGENT mode with an
# explicit, synthesised `/devflow:implement <n>` prompt (the `gate` job resolves
# the number). Agent mode needs no trigger phrase. A stock claude.yml only
# fires in TAG mode on its `@claude` phrase, so it never reacts to a bare
# `/devflow:implement <n>` comment — the two workflows cannot double-fire on the
# canonical path, and claude.yml needs NO edit when this plugin is installed.
#
# Cost control: agent mode runs for ANY actor, so the `gate` job authorizes the
# sender (an allowed bot OR a write/admin/maintain collaborator) before the
# heavy `claude` job runs. See scripts/resolve-implement-trigger.sh.
#
# This workflow reads `claude_implement.effort` (e.g. "high") so the planning +
# write-the-tests phases get more reasoning budget than the light @claude flows
# in claude.yml, without inflating every mention's cost.
#
# Keep the plugin_marketplaces, plugins, and claude_args sections in sync with
# claude.yml and claude-runner.yml so the skill surface is identical across
# listeners.
```

- [ ] **Step 2: Re-validate**

Run: `actionlint .github/workflows/claude-implement.yml`
Expected: no output (clean).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/claude-implement.yml
git commit -m "docs(implement): rewrite workflow header for the bare-command trigger"
```

---

### Task 4: Update user-facing docs

**Files:**
- Modify: `README.md:137-138`, `README.md:149`
- Modify: `docs/cloud-setup.md:65-72`
- Modify: `CHANGELOG.md` (add an entry under the top "Unreleased"/latest section)

- [ ] **Step 1: README — fix the comment-trigger line**

In `README.md`, replace the blockquote at lines 137–138 that reads `... or comment` / `@claude /devflow:implement 42` on the issue. ...` so the comment path no longer shows `@claude`:

```markdown
> `/devflow:implement 42` directly in Claude Code, or comment
> `/devflow:implement 42` on the issue (no `@claude` needed). The label is the zero-typing path;
```

Then in the table row at line 149, change the trailing `via `@claude /devflow:implement <n>` (cloud tier)` to:

```markdown
| `/devflow:implement <issue#>` | Full lifecycle: fetch issue → branch + workpad → discover/plan → implement → test → draft PR → `/simplify` → `/devflow:review-and-fix` → acceptance gate → file follow-up issues for deferred findings → docs → ready PR | interactively, or by commenting `/devflow:implement <n>` on an issue (cloud tier) |
```

- [ ] **Step 2: cloud-setup — fix the trigger description**

In `docs/cloud-setup.md`, replace the bullet at line 69 (`a comment or new issue contains `@claude /devflow:implement <#>`, **or**`) with:

```markdown
- a comment, review, or new issue contains `/devflow:implement <#>` (no `@claude` required), **or**
```

And update the prose at line 105 that begins `The `@claude` and `/devflow:implement` workflows prepare the runner ...` to drop the `@claude`-couples-implement implication:

```markdown
The `@claude` (claude.yml) and `/devflow:implement` (claude-implement.yml) workflows prepare the runner **before**
```

- [ ] **Step 3: CHANGELOG — add an entry**

Add this bullet under the latest unreleased "Changed" group in `CHANGELOG.md` (create the group/heading if the latest section lacks one, matching the file's existing style):

```markdown
- **`/devflow:implement` now triggers on a bare `/devflow:implement <#>`** — comment, review, or issue body/title — with **no `@claude` required**. `claude-implement.yml` runs claude-code-action in agent mode with a synthesised prompt and gates on a new authorization step (`scripts/resolve-implement-trigger.sh`: allowed bot or write/admin/maintain collaborator). Because a stock `claude.yml` only fires in tag mode on `@claude`, the two workflows can no longer double-fire on the bare command — and **installing the plugin no longer requires editing an adopter's `claude.yml`**. The `devflow:implement` label path is unchanged. `@claude /devflow:implement <#>` still works.
```

- [ ] **Step 4: Sanity-check no stale `@claude /devflow:implement` guidance remains**

Run: `grep -rn "@claude /devflow:implement\|@claude.*devflow:implement" README.md docs/`
Expected: no hits in instructional text (a single "still works" mention in CHANGELOG is fine and intentional).

- [ ] **Step 5: Commit**

```bash
git add README.md docs/cloud-setup.md CHANGELOG.md
git commit -m "docs: document bare /devflow:implement trigger (no @claude needed)"
```

---

### Task 5: Full local verification gate

**Files:** none (verification only)

- [ ] **Step 1: Run the whole test suite**

Run: `bash lib/test/run.sh`
Expected: ends with `N passed, 0 failed` — including the new `rit:` assertions.

- [ ] **Step 2: Run the lint gate exactly as CI does**

Run:
```bash
git ls-files '*.sh' | grep -v '^lib/test/' | xargs -r shellcheck --severity=warning -e SC1091
actionlint
```
Expected: both produce no output (clean). (`actionlint` with no args lints every workflow, catching cross-file issues.)

- [ ] **Step 3: Confirm the decoupling invariant holds in the YAML**

Run: `grep -c "@claude" .github/workflows/claude-implement.yml`
Expected: `0` (the implement workflow no longer references `@claude` anywhere).

Run: `git diff --stat main -- .github/workflows/claude.yml`
Expected: empty (claude.yml unchanged on this branch).

---

### Task 6: End-to-end verification on a live repo (manual)

**Files:** none (runtime verification — GitHub Actions logic can only be fully proven by triggering it)

> This task requires a repo with `claude-implement.yml` deployed and `CLAUDE_CODE_OAUTH_TOKEN` configured. Use the dogfood repo (see project memory: Radman-LLC/guidoo) or a throwaway test repo. Do NOT mark Task 6 complete from local checks alone.

- [ ] **Step 1: Authorized bare-command comment**

As a write/admin collaborator, comment `/devflow:implement <#>` (NO `@claude`) on an open issue.
Expected: the **Claude Code (implement)** workflow runs; the `gate` job's `resolve` step outputs `should_run=true` and the correct `number`; the `claude` job starts and posts a progress comment.

- [ ] **Step 2: Confirm `claude.yml` did NOT also run**

Check the Actions tab for the same comment event.
Expected: the light **Claude Code** (claude.yml) workflow did **not** trigger (no `@claude` present → tag mode no-op). This is the core decoupling proof.

- [ ] **Step 3: Authorization denial (cost control)**

From a non-collaborator account (or ask an outside collaborator with no write access), comment `/devflow:implement <#>`.
Expected: the `gate` job runs, the resolver emits the `::warning::... cost control` line, `should_run=false`, and the `claude` job is **skipped** — no billed Claude run.

- [ ] **Step 4: Label path still works**

Add the `devflow:implement` label to an issue.
Expected: workflow runs, `gate` resolves `number` = that issue's number via the label path, `claude` job runs. (Regression check that Task 2 didn't break the existing label trigger.)

- [ ] **Step 5: Record the outcome**

Note the run URLs for Steps 1–4 in the PR description as verification evidence.

---

## Self-Review notes (completed by plan author)

- **Spec coverage:** bare-command trigger (Task 2), no `claude.yml` edit (Task 2 Step 6, Task 5 Step 3), authorization gate to replace the lost tag-mode permission check (Task 1 + Task 2), docs (Task 4), and live proof of no-double-fire (Task 6). All covered.
- **Type/name consistency:** the resolver emits `should_run` + `number`; the `gate` job exposes outputs of the same names; the `claude` job reads `needs.gate.outputs.should_run` / `.number`. Env var names (`ACTOR`, `ALLOWED_BOTS`, `REPO`, `IS_LABEL_EVENT`, `TRIGGER_TEXT`, `CONTEXT_NUMBER`, `GH_TOKEN`) match between the workflow `env:` block and the script's documented inputs.
- **No placeholders:** every code/edit step contains the literal content.
- **Open decision for the implementer to confirm with the user:** whether to *also* remove `claude.yml`'s now-rarely-exercised exclusion clause. This plan deliberately leaves it (keeps `@claude /devflow:implement` safe and honours "don't touch claude.yml"). Removing it is out of scope.
