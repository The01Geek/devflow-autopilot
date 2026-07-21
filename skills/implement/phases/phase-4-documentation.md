## Phase 4: Documentation

Output: `Phase 4/4: Documentation — updating docs and finalizing PR...`

`workpad.py update $ISSUE_NUMBER --status Documenting`.

### 4.0 File Follow-Up Issues for Deferred Work

If Phase 2.2.5's scope-adjustment rule deferred any acceptance criteria, file a follow-up GitHub issue capturing them now. Skip this step if no criteria were deferred.

For each logical chunk of deferred work (typically: one issue per remaining "phase" in a phased cleanup), create a GitHub issue. If multiple follow-up issues are needed, issue all `gh issue create` calls in a single assistant turn so they run in parallel, and append a single combined note (`--note`) afterward (do not PATCH the workpad between each `gh issue create`).

**Body format — follow the create-issue template.** Build each follow-up issue body to the section structure and writing discipline of `skills/create-issue/references/issue-template.md` (the same format authority `/devflow:create-issue` uses), so an implement-generated follow-up reads like every other devflow-authored issue rather than a two-section stub. Specifically:

- **Sections, in this order:** `## Dependencies`, `## Problem Statement`, `## Current Behavior`, `## Desired Behavior`, `## User Impact`, `## Technical Context`, `## Acceptance Criteria`, `## Implementation Notes`. (The template renders those four — Problem Statement / Current Behavior / Desired Behavior / User Impact — as sibling `###` subsections; keep them as top-level `##` sections here, matching how parent issues are written.) Populate them from the parent issue and the workpad's 2.2.5 scope-decision note: the parent-ordering fact → `## Dependencies` (see the bullet below); the scope decision and the parent's framing → Problem Statement / Current Behavior / Desired Behavior / User Impact; the parent's relevant classes/files, architecture alignment, and cross-layer impact → Technical Context; the verbatim deferred criteria → Acceptance Criteria; the parent issue cross-reference threads through Dependencies, Problem Statement, and Technical Context. (Technical Context and Implementation Notes carry a deliberate subset of the template's sub-bullets — the ones an implement-generated follow-up needs — rather than the full set; the template's **Technical Context `Dependencies` bullet** (service/module/library — distinct from the top-level `## Dependencies` section, which *is* rendered), Data/Schema Considerations, Testing Strategy, and Documentation Needed bullets are intentionally omitted.)
- **`## Dependencies` (rendered above `## Problem Statement`).** Render this as the follow-up body's first section with a single line naming the parent issue: `Blocked by #$ARGUMENTS — <one-line reason: the parent's /devflow:implement run must land before this deferred chunk can start>`. This is a **deliberate, documented human-visible redundancy** alongside the mandated `Follow-up to #$ARGUMENTS.` opener in `## Problem Statement` — it uses the exact `## Dependencies` heading and `Blocked by #N` phrasing the early Phase 1 dependency preflight recognizes, making the same parent-ordering fact scannable as its own section rather than living only in the opener sentence. (Phase 4.0.5's Python-rendered review-finding bodies — `scripts/file-deferrals.py::_render_issue_body` — are a separate coupled contract, render no `## Dependencies` section, and are **out of scope / unchanged**.)
- **Acceptance Criteria are carried verbatim — with one bounded exception for composed sibling-PR annotations.** The deferred criteria were already-decided acceptance criteria on the parent issue, so the **parent's decided criteria are the unreworded semantic source**: reproduce them exactly under `## Acceptance Criteria` as `- [ ]` checkboxes, preserving the 2.2.5 verbatim-preservation guarantee — do not reword, split, or merge their substance. The 2.2.5 note phrases this as "preserved verbatim," and that is the semantic guarantee to honour; the one **stated, bounded exception** is a *composed* annotation, below.
- **Sibling-PR annotation rule (split-AC composition).** When split-AC composition writes an **already-shipped annotation** onto a criterion (an "already shipped in PR #N" / "landed in PR #N" clause — bot-composed, because the parent issue often predates the sibling PR, as with the #322 criterion that named PR #319 which did not yet exist when parent issue #311 was authored), the annotation MUST name the sibling PR **and its merge state at filing time** — e.g. "shipped in PR #N (unmerged at filing)" or "shipped in PR #N (merged)". This is what lets a later run's verification check PR #N's live merge state and ancestry (the Phase 1.6 / Phase 2.1 cross-pass coherence rule) instead of grepping whatever tree it happens to hold — a bare "already shipped in PR #N" with no merge-state stamp is exactly the fiction the #322→#325 stale-checkout false refutation crossed. This is the bounded exception to the verbatim rule above: the annotation is *composed*, not carried verbatim, but it never reworks the parent's decided semantic criterion — it only stamps the sibling-PR boundary the parent could not state.
- **No-options rule applies.** Observe the template's no-options discipline — no choice / hedge / deferral language (no "or", "could", "consider", "TBD", "for now", "(optional)") anywhere in the body. The deferred criteria are resolved decisions, so the gate is satisfied by construction; do not reintroduce hedging when describing the deferred scope.
- **Autonomous-run adaptation.** Phase 4.0 runs inside an autonomous /devflow:implement execution with no user present, so the template's *interactive* elements do not apply: there is **no clarification round** and **no `## 🚫 Blocked` section** — the deferred criteria are already-decided acceptance criteria, so nothing is unresolved. Build the body inline here; do **not** invoke the full interactive `/devflow:create-issue` pipeline.
- **Capability-deferred ACs state the credential boundary.** When the 2.2.5 scope decision deferred these criteria because they are *capability-blocked* (Phase 1.6 Pass 5 — they require editing the repo's own `.github/workflows/`, which this run's `GITHUB_TOKEN`-fallback credential — a cloud run with `DEVFLOW_APP_ID` empty, no workflow-capable App token — cannot push), the follow-up body MUST state explicitly that **landing it requires a workflows-capable push (a human/PAT push carrying the `workflows` scope, or a cloud run with the DevFlow App configured — `DEVFLOW_APP_ID` set)** — otherwise re-dispatching the follow-up to another cloud-tier bot run *without* that App configured hits the same wall. Source the statement from the workpad's 2.2.5 scope-decision note, place it as a bullet in `## Technical Context`, and carry the constraint into `## Implementation Notes` → Potential Gotchas. This obligation applies **only** to capability-blocked deferrals; an ordinary size/phased deferral omits it.
- **GitHub autolink hygiene.** Applies to the follow-up issue body too — see *GitHub autolink hygiene* in the Workpad Reference.
- **Posting rules.** Pass the body via a quoted-heredoc on stdin (`--body "$(cat <<'EOF' … EOF)"`) so backticks and `$` in the markdown are not expanded, and add **no** `--label` on the `gh issue create` call itself — the configured `deferred.labels` are applied best-effort *after* creation (see *Apply the deferred-issue labels* below), mirroring the post-creation label-apply idiom Phase 3.1 uses for the `DevFlow` provenance label and Phase 4.1 uses for `docs.labels`. Do **not** switch to `--body-file`. (This posting command is a deliberate, small departure from the template's own *example*, which pipes the body through `--body-file -`; only the body's section structure and writing discipline follow the template, not its exact posting command — the quoted-heredoc form keeps the no-expansion guarantee either way.)

```bash
CREATE_STATE=""
gh issue create \
  --title "<short descriptive title — e.g. 'Phase N of <parent topic>'>" \
  --body "$(cat <<'EOF'
## Dependencies
Blocked by #$ARGUMENTS — the parent issue's /devflow:implement run must land before this deferred chunk can start.

## Problem Statement
Follow-up to #$ARGUMENTS. <Why this remaining work is needed and who hits the pain — drawn from the parent issue's framing and the 2.2.5 scope-decision note.>

## Current Behavior
<What exists today / what's missing — the state the parent PR left, scoped to this chunk.>

## Desired Behavior
<The single decided behavior after this follow-up ships, stated declaratively.>

## User Impact
<Who benefits and how.>

## Technical Context
- **Relevant Classes/Files** — <files from the parent issue's Technical Context relevant to this chunk.>
- **Architecture Alignment** — <how this fits existing patterns; carried from the parent.>
- **Cross-layer Impact** — <layers affected.>
- Parent issue #$ARGUMENTS was scoped to a single PR by its /devflow:implement run; see the workpad on #$ARGUMENTS for the full scope decision.
- <ONLY for a capability-blocked deferral (Phase 1.6 Pass 5): **Landing this requires a human/PAT push carrying the `workflows` scope** (or a cloud run with the DevFlow App configured — `DEVFLOW_APP_ID` set). A cloud run whose `DEVFLOW_APP_ID` is empty falls back to the built-in `GITHUB_TOKEN`, which cannot push `.github/workflows/`, so re-dispatching this follow-up to such a run will hit the same credential boundary. Omit this bullet for an ordinary size/phased deferral.>

## Acceptance Criteria
- [ ] {deferred criterion verbatim}
- [ ] {deferred criterion verbatim}
…

## Implementation Notes
- **Approach** — <the decided design for this chunk, drawn from the parent's plan.>
- **Code Patterns** — <patterns in this codebase to mirror.>
- **Potential Gotchas** — <constraints or pitfalls carried from the parent issue.>
EOF
)" && CREATE_STATE=ok || CREATE_STATE=failed
echo "phase 4.0 create fence ran; create=[${CREATE_STATE}]"
```

The trailing `echo` is an **unconditional sentinel**, and it is load-bearing for the same reason Phase 4.0.5's is (the #480 review): `gh issue create` prints the new issue's URL on success and **nothing** when the harness refuses the command, so without it "the create was refused" and "there was nothing to create" reach you as the same empty tool result — and the capture guard below would then be asked to detect a condition you were given no way to observe. It carries `create=` for the same reason 4.0.5 carries `filing=`: a create that **ran and failed** (rate limit, auth, a malformed body) also yields no issue number, and without the state you would read that as the *capture gap* below and record a reflection asserting issues were filed that do not exist. **This fence runs once per follow-up issue, so route each sentinel independently** — with two deferred chunks you get two sentinels, and an `ok` followed by a `failed` means one issue exists and one does not; never let the `failed` arm's wording ("no issue exists") be read run-globally over a run that filed another. Three states, three routes:

- **No `phase 4.0 create fence ran` line at all, or the line reads `create=[]`** ⇒ the create did not run. `CREATE_STATE` is initialized empty *before* the create statement, so it is produced on every path the fence can take: an empty value means the `gh issue create` statement itself never executed (a harness refusal of that statement), and no line at all means the whole fence was refused. **Both mean no issue exists**, and both take this exit — so the routing does not depend on a denial granularity no probe row establishes (the same answer-independence §4.0.5 carries). File nothing, label nothing, and record it — `workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.0's follow-up-issue create fence produced no output at all, or reported create=[] (likely a harness denial); no deferred-AC follow-up issue was filed or labelled this run."`
- **`create=[failed]`** ⇒ the create ran and the API rejected it. **No issue exists** — do not claim one was filed: `workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.0's gh issue create failed; no deferred-AC follow-up issue was filed this run, so none was labelled."`
- **`create=[ok]`** ⇒ an issue exists; read its URL for the number and continue to the label applies below.

**Apply the deferred-issue labels.** As you create each follow-up issue above, **capture its number** from the `gh issue create` output (the command prints the new issue URL; the trailing path segment is the number) and keep the numbers **in your own working notes** — an agent-level list, not a shell variable. Do **not** write it as a shell assignment: a shell variable does not survive into the separate command that applies the labels below (a `VAR=value` **prefix on the helper invocation** — `FOO=1 apply-labels.sh …` — is separately denied, because it makes the granted helper path no longer the command's leading token; an ordinary in-fence assignment like the `config-get` capture below is *not* that shape). Then apply the configured `deferred.labels` to every filed issue. The labels are read from config (default `DevFlow,Deferred`) and normalized with the **same** split/trim/drop-empties idiom Phase 4.1 uses for `docs.labels`, so an empty or whitespace-only value applies no labels. Ensure each label exists first (best-effort), then apply them through the shared REST `apply-labels.sh` helper (`POST .../issues/{n}/labels` — repo-scope only, unlike `gh issue edit --add-label`'s org-scoped GraphQL resolution) per filed issue — best-effort and post-creation, so a label hiccup can never block or unwind the filing.

**Cloud-emission discipline (label helpers): iterate at the agent level, never in a shell loop or a capture — see the *Cloud command-shape discipline* section in `skills/implement/SKILL.md`.** The cloud implement matcher **denies** a `for`/piped-`while read` loop wrapping a label helper (`ensure-label.sh` / `apply-labels.sh`) and a `VAR="$(label-helper …)"` output capture — the implement-tier probe rows I4/I5/I6 (`.github/workflows/matcher-probe.yml`, evidence of record on issues #450/#455). So do **not** wrap the label helpers in a shell loop or capture their output into a variable: emit **one single-statement, leading-token call per label and per issue**, iterating over the labels/numbers yourself.

**What the probe did and did not prove (do not over-read it).** The `config-get` capture below is used on the *inference* that the matcher descends into `$(…)` for a **non-label** helper — that is carried over from the review tier and is **not** measured on the implement tier (rows 8/9 exist to settle it; until a dispatch records them, treat it as an inference). Phase 4.1's docs-label channel rests on the same unproven captures (`config-get.sh`, and a `gh pr view` read for the PR number). Neither is known-denied; both are simply **unproven**, so every fence below fails **closed** on a read that produces no output rather than treating a possible denial as "no labels configured".

First resolve and **print** the clean label list — a `config-get` capture is permitted, and printing it lets you read the resolved value for the per-issue calls below (a shell variable set here does not survive into a later separate command on the cloud runner):

```bash
# The default arg covers the SOFT paths (missing file / unset key → config-get prints it,
# exit 0); only the HARD path (rc≠0 — corrupt config.json / missing python3) enters the
# `if !` branch, where DEFERRED_LABELS stays empty (no labels applied) AND a breadcrumb is
# left. The `if !` reads config-get's OWN exit status inline (never a captured rc read in a
# later statement, which a cross-statement-variable-stripping inline-bash runner would
# leave empty) and is exempt from `set -e`.
if ! DEFERRED_LABELS=$("${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/config-get.sh .deferred.labels DevFlow,Deferred); then
  DEFERRED_LABELS=""
  "${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.0 could not read deferred.labels (config-get rc≠0 — corrupt config.json or python3 missing); deferred follow-up issues filed WITHOUT labels."
fi
# Normalize with GRANTED heads only. `paste` is granted in NO allowlist (baked TOOLS,
# config.json, config.example.json), so a `| paste -sd, -` tail makes the WHOLE pipeline
# refused — the capture then produces no output, and a reader who treats that as "no
# labels" ships exactly the silent-denial defect this rework exists to end. `tr`/`sed`/
# `grep`/`echo` are all granted; the trailing-comma strip replaces what paste did.
CLEAN_DEFERRED_LABELS=$(echo "$DEFERRED_LABELS" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
# Print BOTH: the RAW config value and the normalized list. Printing only the normalized
# one makes an emptied normalizer indistinguishable from an empty config — and the
# normalizer runs on PATH tools the preflight does not guarantee (CLAUDE.md guard-class 2:
# a missing tool yields an empty value and the wrong thing is silently selected).
echo "deferred.labels raw: [$DEFERRED_LABELS]"
echo "deferred labels to apply: [$CLEAN_DEFERRED_LABELS]"
```

The capture gap is the **`create=[ok]` but no number** case, and only that one — the other two empty-handed outcomes are routed above and must not be collapsed into it, because only this one means an issue exists that went unlabelled:

- **`create=[ok]` and you captured no issue URL/number** — the issue was created and you cannot read its number. That is a real capture gap (not a benign no-op) — record it durably and apply nothing: `workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.0 filed deferred follow-up issues but captured no issue numbers — the configured deferred labels were applied to NONE of them; the filed issues carry none of the configured deferred labels."`
- **`create=[failed]`, or no sentinel line at all** — no issue was created. Take the matching exit above; do **not** record the capture-gap reflection, which would assert issues exist that do not.

**Read the two printed lines together — three outcomes, and only one is a benign no-op:**

- **Neither line printed at all.** The command was refused by the harness, so it produced no output. Do **not** read that as "no labels": the capture shape is unproven on this tier (above), and treating a denial as an empty config is exactly the silent-denial defect this rework exists to end. Record it and apply nothing: `workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.0 could not resolve deferred.labels — the config-get command produced no output at all (likely a harness denial, not an empty config); deferred follow-up issues were filed WITHOUT labels."`
- **`raw` is NON-empty but `to apply` is empty.** The config *did* resolve labels and the normalizer dropped them — a missing `tr`/`sed`/`grep` on this host, or a refused pipeline. That is a broken derivation, **not** an empty config: record it and apply nothing: `workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.0 resolved deferred.labels to a non-empty value but the normalizer produced an empty list (a missing/denied tr|sed|grep in the pipeline); deferred follow-up issues were filed WITHOUT labels."`
- **`raw` is empty (and printed), and no rc≠0 breadcrumb was recorded above.** The config genuinely resolved to no labels: apply nothing — the clean no-op. (If the `if !` hard-read-failure branch fired, `raw` is empty because the read *failed*, not because there are no labels; that path already recorded its own `dropped-failed` reflection and is not a no-op.)

Otherwise, read the printed `CLEAN_DEFERRED_LABELS` value and apply the labels with **single granted-literal leading-token calls**, iterating at the agent level:

- For **each** label in the printed comma-list (skip blanks), ensure it exists with one call — the helper path is the command's leading token, and `ensure-label.sh` is best-effort (always exits 0). `ensure-label.sh` always breadcrumbs to stderr (`created` / `already exists` / `warning: …`), so **no output at all means the command was refused by the harness** — record it (`--reflection-kind dropped-failed`) and continue to the apply, which reports separately whether the label landed.
  ```bash
  "${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/ensure-label.sh "<label>"
  ```
- For **each** filed issue number in your working notes (**not** a live `$DEFERRED_ISSUE_NUMBERS` shell variable — it does not survive into this separate command), apply the whole comma-list with one call — the helper path is the leading token, the issue number and the resolved label list substituted as literals:
  ```bash
  "${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/apply-labels.sh <filed-issue-number> "<deferred-labels>"
  ```
  `apply-labels.sh` is best-effort (always exits 0) and **always** prints a breadcrumb to **stderr** on **every path it can take** — a harness refusal is its ONLY silent outcome. **Read that stderr from the tool result and route on it — all four outcomes, not just the failure one:** a `devflow: applied label(s) '…' to #N` line means the labels landed; a `devflow: warning: could not apply …` line is an **API failure** (POST `.../issues/{n}/labels` — repo-scope only; never `gh issue edit --add-label`'s org-scoped GraphQL); a `devflow: warning: apply-labels.sh got no label content …` or `… got a non-numeric issue/PR number …` line is a **caller arg-slip** — the breadcrumb says outright that it is *not* a harness denial — meaning the label list you substituted was empty/whitespace-only, or the number did not survive into this command, so re-emit the call once with the printed literal values before recording anything; and **no output at all means the command was refused by the harness** (a denied command prints nothing, which is exactly why the helper breadcrumbs on every other path — otherwise "applied", "denied" and "the caller passed no label content" would look identical and the guard below would have no comparand in the case it exists to catch). Record any surviving non-success durably (stderr is ephemeral in an autonomous cloud run), naming which outcome it was: `workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.0 could not apply the configured deferred labels (<deferred-labels>) to issue #<filed-issue-number> — the apply reported an API failure or a caller arg-slip, or produced no output at all (a harness denial); the issue was filed but carries none of the configured deferred labels."`

Record the new issue numbers in the workpad: `workpad.py update $ISSUE_NUMBER --note "Filed follow-up issues for deferred work: #N (phase 2), #N+1 (phase 3), …"` before continuing to 4.0.5.

### 4.0.5 File Follow-Up Issues for Deferred Review Findings

If Phase 3.3's /devflow:review-and-fix run emitted a deferrals manifest, file follow-up GitHub issues for those findings now and update the manifest in place with the assigned issue numbers + deterministic deferral IDs. Phase 4.2's /pr-description run will then surface them in the PR body as a Scope-Acknowledged Findings block that /devflow:review's verdict matcher honors.

**Manifests are run-scoped** (`.devflow/tmp/review/<slug>/<run-id>/deferrals.json` — see that skill's "Pre-mapping: Widens-surface guard + deferrals manifest" section for what's in it). A single /devflow:implement run can produce **two** of them: Phase 3.3's first /devflow:review-and-fix run and its bounded re-review both run on the same PR with distinct run-ids. Reading one fixed path would miss the other run's deferrals (issue #68 F1, acceptance criterion 3). So **merge every run-scoped manifest into one slug-level aggregate** before filing, then file from the aggregate. The aggregate is the single path /pr-description reads in Phase 4.2.

Skip this step if no run-scoped manifest exists or all are empty.

```bash
PR_NUMBER=$(gh pr view --json number --jq '.number')
SLUG_DIR=".devflow/tmp/review/pr-${PR_NUMBER}"
AGG="${SLUG_DIR}/deferrals.json"   # slug-level aggregate the consumers read; distinct from the per-run files
# A PR-mode /devflow:review-and-fix run writes its run-scoped manifest under `pr-<N>/`,
# but a CURRENT-BRANCH-mode run writes it under the sanitized current branch slug instead
# (`<slug>` = the branch name with `/`→`-`, lowercased, non-`[a-z0-9._-]` dropped — the same
# convention /devflow:review uses). Searching only `pr-<N>/` silently misses a branch-mode
# run's deferrals (issue #254), so discover run-scoped manifests under BOTH candidate slug
# directories. The aggregate is always written at `pr-<N>/deferrals.json` — the single path
# /pr-description reads in Phase 4.2, unchanged.
# Read the current branch name ONCE and reuse it for both the slug derivation and the
# empty-slug breadcrumb guard below — a single `git branch --show-current` subprocess, and no
# chance the two reads disagree if HEAD moves mid-block.
CUR_BRANCH=$(git branch --show-current)
BRANCH_SLUG=$(printf '%s' "$CUR_BRANCH" | tr '/' '-' | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9._-')
# tr-dependence guard (this repo's review-and-fix guard-class 2): BRANCH_SLUG keys a
# filesystem search dir and is derived through `tr` on PATH. A non-empty current branch that
# yields an EMPTY slug has two possible causes, both of which fall back to pr-<N>-only search
# correctly: (a) `tr` is missing/degraded on PATH (the guard-class-2 degradation), or (b) a
# working `tr` dropped every character because the branch name is composed entirely of
# characters outside `[a-z0-9._-]` (e.g. all-non-ASCII). The breadcrumb names the observable
# fact plus both candidate causes rather than blaming `tr` alone, so an operator on cause (b)
# is not sent to debug a `tr`/PATH problem that does not exist. (An EMPTY branch name is
# instead the benign detached-HEAD case — e.g. a PR merge-ref checkout — where pr-<N>-only is
# correct and no breadcrumb fires.) Make the degraded case observable rather than silent.
# Best-effort breadcrumb; never blocks.
[ -z "$BRANCH_SLUG" ] && [ -n "$CUR_BRANCH" ] && echo "devflow: current branch produced an empty slug (either 'tr' is missing/degraded on PATH, or the branch name is composed entirely of characters dropped by the [a-z0-9._-] filter); falling back to pr-<N>-only deferral discovery (a current-branch-mode run's manifest may be missed)" >&2
BRANCH_DIR=".devflow/tmp/review/${BRANCH_SLUG}"
# Only add the branch-slug dir when it is non-empty AND distinct from pr-<N> (a branch
# literally named `pr-<N>` would otherwise be searched twice — harmless but pointless).
SEARCH_DIRS="$SLUG_DIR"
[ -n "$BRANCH_SLUG" ] && [ "$BRANCH_DIR" != "$SLUG_DIR" ] && SEARCH_DIRS="$SLUG_DIR $BRANCH_DIR"
# run-id and slug are path-safe ([a-z0-9._-]), so the unquoted $SEARCH_DIRS
# word-split into the helper's argv is safe. Discovery is delegated to a stdlib-only Python
# helper that searches EACH root independently and classifies each outcome (issue #555): the
# old `find $SEARCH_DIRS … | sort` collapsed a FAILED search and a clean no-match onto the same
# empty output, so a degraded search read as the clean no-op and stranded acknowledged deferrals.
# The helper preserves discovery status through its EXIT CODE (output production and internal
# sorting cannot alter it), so a failed search is observable instead of masked. Discriminate its
# exit with the SAME if/elif stderr-marker idiom the file-deferrals.py call below uses.
# DISCOVERY_STATE is initialized empty BEFORE the statement (the #480 sentinel-operand rule) and
# no arm sets it to a non-empty default; a matcher refusal of the capture (the non-label-capture
# shape is unproven on the implement tier — treat NO OUTPUT AT ALL as a possible denial, never as
# an empty value) leaves it empty, which the sentinel prints as discovery=[] and the reader routes
# fail-closed. On exit 0 the helper printed the found paths (possibly none) and every root was
# ok/absent; on the partial marker at least one root failed traversal but the captured paths from
# the clean roots are still usable; the else arm is failed-or-refused.
# Remove any prior run's marker file FIRST, as its own statement: only the `if` statement's
# redirect writes/truncates it, so if that statement is refused (or the redirect fails) an
# unwritten file must be unambiguously ABSENT rather than inheriting a previous run's
# 'discovery partial:' marker — otherwise `grep -q` below would route a discovery that never
# ran to the PARTIAL arm and file from a stale persisted aggregate. Absent ⇒ grep non-zero ⇒
# the else/failed arm ⇒ fail-closed.
rm -f /tmp/devflow-dm.err
DISCOVERY_STATE=""
if MANIFESTS=$("${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/discover-deferral-manifests.py $SEARCH_DIRS 2>/tmp/devflow-dm.err); then
    DISCOVERY_STATE=ok
elif grep -q 'devflow: discovery partial:' /tmp/devflow-dm.err; then
    # PARTIAL: at least one root failed traversal, at least one did not fail (`ok` or `absent`). Keep the
    # captured paths (bash assigns a $(…) capture even when the command exits non-zero) and file
    # from the clean roots, but record the failed root AND the honest limitation: once this run's
    # filing hydrates the aggregate, the failed root's still-undiscovered deferrals can no longer
    # be auto-filed by a later re-run (file-deferrals.py refuses a mixed hydrated/raw manifest
    # all-or-nothing), so recovering them means filing from that root's run-scoped manifest manually.
    DISCOVERY_STATE=partial
    "${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.0.5 deferral discovery was PARTIAL — at least one candidate root failed traversal: $(cat /tmp/devflow-dm.err); filing proceeds from the roots that did not fail (\`ok\`/\`absent\`; an \`absent\` root contributes nothing). The failed root's deferrals are NOT filed this run, and once this run hydrates ${AGG} they cannot be auto-filed by a later re-run (file-deferrals.py refuses a mixed hydrated/raw manifest) — recover them by filing from that root's run-scoped manifest manually."
else
    # FAILED or REFUSED: every root failed traversal, OR the capture produced NO OUTPUT AT ALL (a
    # likely matcher denial of this unproven capture shape). Blank MANIFESTS so the merge guard is
    # unambiguously false, and record the failure naming the PERSISTED aggregate path so an operator
    # can re-trigger Phase 4.0.5 deliberately (a stranded prior aggregate under .devflow/tmp is
    # re-fed only by the next healthy run's PRIOR-first merge if one runs while the scratch persists).
    DISCOVERY_STATE=failed
    MANIFESTS=""
    "${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.0.5 deferral discovery FAILED (every candidate root failed traversal, or the discovery command produced no output at all — a likely harness denial): $(cat /tmp/devflow-dm.err 2>/dev/null). No deferrals were filed this run; any persisted aggregate at ${AGG} was left intact — re-trigger Phase 4.0.5 deliberately to recover its deferrals."
fi
# Surface the helper's roots-echo line into the tool result on EVERY path (including the clean
# one), so an absent-classified root is observable rather than silent (issue #555). "Every path"
# assumes what this fence guarantees — a non-empty $SEARCH_DIRS: the helper's zero-argument usage
# error (exit 2) returns BEFORE it emits any roots-echo. Best-effort — a missing line never blocks
# the fence.
grep 'devflow: discovery roots:' /tmp/devflow-dm.err || true
if [ -n "$MANIFESTS" ]; then
    # Merge the deferrals[] arrays across runs. The dedup key mirrors file-deferrals.py's
    # _compute_id payload — (file|symbol|kind|summary.strip()), every field defaulted to ""
    # — so a finding deferred in both runs collapses to one row, is filed once, and a null
    # field never errors the string concat. Header fields come from the first input.
    # The merge preserves every per-entry field verbatim (`.[].deferrals[]` passes whole
    # objects through unique_by), so a `settled-by-disclosure` entry's flat `category` and
    # its top-level `disclosure: {path, phrase}` object survive into the aggregate unchanged
    # (dedup key untouched) — no jq change is needed for foreclosure passthrough (issue #621).
    # Idempotent re-runs: feed any prior hydrated aggregate FIRST so its `follow_up` entries
    # win the dedup (unique_by keeps the first occurrence); otherwise a re-run rebuilds $AGG
    # from the raw run-scoped manifests (which never carry follow_up), wiping the prior
    # hydration so file-deferrals.py re-files duplicates. Write via temp so reading $AGG is safe.
    # (file-deferrals.py refuses any manifest where *some* entry is already hydrated, so on a
    # re-run this prevents duplicate filing but does not incrementally file newly-added
    # deferrals — that all-or-nothing is the helper's existing guard, handled benignly below.)
    PRIOR=""; [ -s "$AGG" ] && PRIOR="$AGG"
    if "${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/run-jq.sh -s '.[0] as $f | {schema_version:$f.schema_version, pr_branch:$f.pr_branch, base_branch:$f.base_branch, generated_at:$f.generated_at,
        deferrals: ([.[].deferrals[]] | unique_by((.file // "") + "|" + (.symbol // "") + "|" + (.kind // "") + "|" + ((.summary // "") | gsub("^\\s+|\\s+$";"")))) }' \
        $PRIOR $MANIFESTS > "${AGG}.tmp"; then
        mv "${AGG}.tmp" "$AGG"
    else
        # jq failed (malformed manifest, schema drift): keep any prior hydrated $AGG
        # intact, do NOT file from a half-merged temp, and surface the gap rather than
        # silently falling through to the filing guard with a stale aggregate.
        rm -f "${AGG}.tmp"
        "${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.0.5 deferrals merge (jq) failed over: ${MANIFESTS}; deferrals NOT filed this run — inspect the run-scoped manifests."
        AGG=""   # make the filing guard below unambiguously false
    fi
fi
# Initialize the sentinel's operands OUTSIDE the aggregate guard, because the sentinel that
# reads them is outside it too. Every field the sentinel prints must be produced on EVERY path
# the fence can take — including the clean no-op (no hydrated aggregate), which is the common
# one and which never enters the guard below. `${FILED_NUMBERS//$'\n'/ }` cannot carry a `:-`
# default (bash forbids it in a substitution expansion), so an UNSET `FILED_NUMBERS` aborts the
# whole `echo` under `set -u` on bash 5 — the sentinel then does not print, and the reader's
# rule ("no sentinel ⇒ refused") fabricates a harness-denial reflection on a run where nothing
# went wrong. Initializing here is what makes the sentinel's "unconditional" claim true.
FILED_STATE=""
FILED_NUMBERS=""
if { [ "$DISCOVERY_STATE" = ok ] || [ "$DISCOVERY_STATE" = partial ]; } && [ -n "$AGG" ] && [ -s "$AGG" ]; then
    # Discriminate file-deferrals.py's exit codes without a captured rc read in a later
    # statement (a cross-statement-variable-stripping inline-bash runner would leave it
    # empty): the single-statement `if` reads the helper's OWN status (rc 0 = filed), and
    # the non-zero cases are told apart below by grepping the helper's own stderr markers —
    # "already has follow_up" (the benign idempotent-re-run: the prior aggregate is still
    # hydrated and /pr-description reads it fine, not a failure) vs. a genuine failure.
    # FILED_STATE names WHICH of the four arms ran. Without it the sentinel below reports
    # only `filed …=[]`, which is what THREE benign arms (idempotent re-run, no-deferrals,
    # genuine failure — none of which sets FILED_NUMBERS) print as well as the one real
    # capture gap, so the reader's "hydrated manifest + no numbers ⇒ a capture gap" rule
    # fires on all four and fabricates a durable reflection asserting issues were filed and
    # their numbers lost — on runs where nothing was filed at all (the #480 review).
    FILED_STATE=failed
    FILED_NUMBERS=""
    if FILED_OUT=$("${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/file-deferrals.py \
        --source-issue $ARGUMENTS \
        --pr "$PR_NUMBER" \
        --manifest "$AGG" 2>/tmp/devflow-fd.err); then
        FILED_NUMBERS="$FILED_OUT"
        FILED_STATE=filed
        # file-deferrals.py exits 0 even on PARTIAL success: a per-file group whose
        # `gh issue create` failed is dropped from the manifest, yet the helper still
        # exits 0. Surface that so the dropped findings (which won't reach the PR's
        # Scope-Acknowledged block) leave a breadcrumb instead of vanishing silently.
        grep -q 'were dropped from manifest' /tmp/devflow-fd.err && \
            "${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "file-deferrals.py filed partially (rc=0): $(cat /tmp/devflow-fd.err); dropped groups will NOT appear in the PR's Scope-Acknowledged Findings block."
    elif grep -q 'already has follow_up' /tmp/devflow-fd.err; then
        FILED_STATE=idempotent
        "${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/workpad.py update $ISSUE_NUMBER --note "Deferrals already filed on a prior run (idempotent re-run) — nothing new to file; the hydrated aggregate stands."
    elif grep -q 'no deferrals' /tmp/devflow-fd.err; then
        FILED_STATE=none
        "${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/workpad.py update $ISSUE_NUMBER --note "Aggregate held no deferrals to file — nothing to do."
    else
        "${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "file-deferrals.py failed (rc≠0): $(cat /tmp/devflow-fd.err); no follow-up issues filed this run."
    fi
    # Record the filed numbers AND print them — IN THIS FENCE, because this is the only
    # place `FILED_NUMBERS` exists. A shell variable does not survive into a later separate
    # command on the cloud runner (the rule this phase states below), so a `[ -n "$FILED_NUMBERS" ]`
    # read in a LATER fence always sees it empty, prints `[]`, and the agent then reads `[]`
    # as "nothing was filed — a clean no-op" and labels NOTHING. Printing here is the only
    # channel that carries the numbers to the agent-level label calls further down.
    if [ -n "${FILED_NUMBERS:-}" ]; then
        NUMBERS_CSV=$(echo "$FILED_NUMBERS" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, #/g')
        "${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/workpad.py update $ISSUE_NUMBER --note "Filed follow-up issues for deferred review findings: #${NUMBERS_CSV}"
    fi
fi
# UNCONDITIONAL sentinel — OUTSIDE the aggregate guard, so it prints on every path this fence
# can take. Inside the guard, "there was no aggregate to file" and "the fence was refused by
# the harness" would BOTH reach you as no line at all — and this phase teaches you to read
# "no output" as a denial. The sentinel makes the three states distinct: no line => refused;
# manifest=[] => nothing to file (the clean no-op); manifest=[…] with an empty filed list =>
# the real capture gap.
# Derive the manifest state from the SAME predicate the filing guard used ([ -s "$AGG" ]).
# `AGG` is a PATH, assigned unconditionally — printing it raw would make the ordinary
# no-deferrals run (no manifest file) look identical to a hydrated one, routing a clean
# no-op to the "capture gap" exit and fabricating a dropped-failed reflection; and a real
# jq-merge failure (which blanks AGG) would read as the clean no-op. Print the STATE, not
# the path. Print the numbers RAW too — NUMBERS_CSV is display-formatted for the workpad
# note (`201, #202`), so it is not what you want to substitute into the per-issue calls.
#
# `pr=` carries the PR_NUMBER capture's own outcome (the #480 review). It is the input SLUG_DIR/AGG
# are built from: if `gh pr view` returns nothing, SLUG_DIR degrades to `.devflow/tmp/review/pr-`,
# no manifest is found, AGG never hydrates, and the sentinel would otherwise print `manifest=[]`
# — the CLEAN NO-OP state — on a run that had deferrals to file. Printing the value makes that
# read observable instead of inferred. (A matcher DENIAL of the capture lands in one of these two
# states — either no sentinel at all, or `pr=[]` — and it does NOT matter which: BOTH route to the
# same fail-closed exit (record `dropped-failed`, apply nothing). The repo's documented rule is that
# an ungranted head refuses the entire STATEMENT; whether the harness then refuses the rest of the
# Bash call is not established by any probe row, so this fence does not depend on the answer.)
#
# The `\n`→space fold is a BASH BUILTIN, not `tr`: this field is an emitted result the reader
# ROUTES on, and CLAUDE.md's guard-class 2 forbids deriving such a value through a non-preflight
# PATH tool — a host without `tr` would print `filed …=[]` on a run that filed issues, and every
# filed issue would go unlabelled while a reflection blamed a capture gap that never happened.
MANIFEST_STATE=""; [ -n "${AGG:-}" ] && [ -s "${AGG:-}" ] && MANIFEST_STATE=hydrated
echo "phase 4.0.5 filing fence ran; pr=[${PR_NUMBER:-}] discovery=[${DISCOVERY_STATE:-}] manifest=[${MANIFEST_STATE}] filing=[${FILED_STATE:-}] filed deferred-finding issues=[${FILED_NUMBERS//$'\n'/ }]"
```

The helper groups manifest entries by `file` (one issue per source file), files each issue with a repo-agnostic title/body template (`<area>: deferred review findings in <file> (carried from #<source_issue>)` and a body containing the verbatim findings plus the `PR #<pr_number>` substring that the verdict matcher's mutual-cross-link guard validates against), then rewrites the manifest in place with `id: dfr-<6-hex>` (deterministic hash of `file + symbol + kind + summary`) and `follow_up: {issue, url, filed_at, filed_by}` populated per entry. Filed issue numbers are printed to stdout, one per line.

Failure mode: if `gh issue create` fails for a particular file-group, that group's entries are dropped from the manifest entirely — no fake deferral can downgrade a future review. The helper exits 0 as long as at least one group succeeded. Capture stderr in your `Devflow Reflection` notes if anything was dropped.

**Foreclosure passthrough (issue #621).** A `settled-by-disclosure` entry files **no** follow-up issue — the shipped disclosure is its deliverable — yet still survives into the rewritten aggregate unchanged (with a `dfr-` id assigned, no `follow_up`, its `category` and `disclosure` object preserved) so `/pr-description` can render it and `/devflow:review` can honor it. Consequently a manifest whose entries are **all** foreclosures files zero issues and **still exits 0** (printing no issue numbers), rewriting the aggregate; the `FILED_STATE=filed` arm handles it benignly (empty `FILED_NUMBERS`). This is the all-foreclosed exit-0 arm — do not treat an exit-0 with no printed issue numbers as a failure.

The fence above recorded the filed issue numbers in the workpad **and printed them** (`filed deferred-finding issues=[...]`) — that print is load-bearing, not decoration, and it deliberately lives **inside** the filing fence: `FILED_NUMBERS` is a shell variable, and a shell variable **does not survive into a later separate command** on the cloud runner (the same rule that forces the label list to be printed). Reading it from a *later* fence would always see it empty, print `[]`, and lead you to conclude "nothing was filed" on a run that filed issues — labelling none of them. Read the printed list from that tool result; it is the only channel that carries the numbers to the agent-level label calls below.

Then apply the configured `deferred.labels` to each filed issue — the **same** resolve/normalize idiom as Phase 4.0 (default `DevFlow,Deferred`; empty/whitespace → none). `file-deferrals.py` itself stays out of config-reading (config is resolver territory — read through `config-get.sh`, not re-parsed ad hoc); the skill owns labeling, best-effort and post-filing, so a label hiccup never unwinds an already-filed issue.

**Cloud-emission discipline (label helpers): iterate at the agent level, never in a shell loop or a capture — identical to Phase 4.0, see the *Cloud command-shape discipline* section in `skills/implement/SKILL.md`.** The cloud implement matcher denies a `for`/piped-`while read` loop wrapping a label helper and a `VAR="$(label-helper …)"` capture (implement-tier probe rows I4/I5/I6). The `config-get` capture below rests on the same **inference** Phase 4.0 records (the matcher descends into a non-label `$(…)`) — unproven on this tier, which is why the read below fails **closed** on no output. First resolve and **print** the clean label list (printing lets you read the value for the per-issue calls, since a shell variable does not survive into a later separate command on the cloud runner):

```bash
# The `if !` reads config-get's OWN exit status inline (never a captured rc in a later
# statement) and is exempt from set -e; the default arg covers the SOFT paths (missing
# file / unset key → exit 0), only the HARD path (rc≠0 — corrupt config.json / missing
# python3) leaves DEFERRED_LABELS empty AND a breadcrumb.
if ! DEFERRED_LABELS=$("${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/config-get.sh .deferred.labels DevFlow,Deferred); then
    DEFERRED_LABELS=""
    "${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.0.5 could not read deferred.labels (config-get rc≠0 — corrupt config.json or python3 missing); deferred review-finding issues filed WITHOUT labels."
fi
# GRANTED heads only — `paste` is granted in no allowlist, so a `| paste -sd, -` tail makes
# the whole pipeline refused and the capture silently empty (see Phase 4.0's note).
CLEAN_DEFERRED_LABELS=$(echo "$DEFERRED_LABELS" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
# Print BOTH, for the same reason Phase 4.0 does: an emptied normalizer must not be
# indistinguishable from an empty config (CLAUDE.md guard-class 2).
echo "deferred.labels raw: [$DEFERRED_LABELS]"
echo "deferred labels to apply: [$CLEAN_DEFERRED_LABELS]"
```

**A non-empty `raw` with an empty `to apply`** is a broken normalizer (a missing/denied `tr`/`sed`/`grep`), **not** an empty config — record it and apply nothing: `workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.0.5 resolved deferred.labels to a non-empty value but the normalizer produced an empty list (a missing/denied tr|sed|grep in the pipeline); deferred review-finding issues were filed WITHOUT labels."`

Six further exits before any label is applied — the same fail-closed set Phase 4.0 carries (a rework must not lose them). The **first five** are read off the **sentinel** the filing fence prints unconditionally; the **sixth** is read off the separate `deferred labels to apply:` line the config fence prints below it (the sentinel neither prints nor can print that state). **Count the exits, not the bullets:** two bullets below are *qualifiers*, not exits, and are deliberately excluded from the six — the **`discovery=[partial]`** one (it applies nothing on its own and routes onward to the arms below) and the **Cwd-drift suspicion** one (a suspicion heuristic qualifying the clean-no-op arm). Any other exit count is a lost exit:

- **No `phase 4.0.5 filing fence ran` sentinel at all, OR the sentinel present with `discovery=[]`.** The fence was refused, not answered — do **not** read it as "nothing was filed". A refusal or non-execution of the discovery statement lands as `discovery=[]` on the sentinel or as no sentinel at all — and it does not matter which; both take this exit. Record it and apply nothing: `workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.0.5's filing fence produced no sentinel at all, or a sentinel carrying discovery=[] (the discovery statement was refused or never ran) — likely a harness denial, not an empty aggregate; no deferred review-finding issues were filed or labelled this run."`
- **Sentinel present, `pr=[]`** — the `gh pr view` read ran and yielded no number, so every path built on it (`SLUG_DIR`, the manifest discovery, `AGG`) resolved against a truncated slug and found nothing. **Do not read the `manifest=[]` that follows it as the clean no-op**: no manifest was even looked for at the right path, so this run's deferrals (if any) were neither filed nor labelled. Record it and apply nothing: `workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.0.5 could not resolve the PR number — the gh pr view read yielded no value; no deferrals manifest could be located, so no deferred review-finding issues were filed or labelled this run."` (A matcher *denial* of that capture lands in this state or in the no-sentinel exit above — and it does not matter which: both record `dropped-failed` and apply nothing, so this routing does not depend on a denial granularity no probe row establishes.)
- **Sentinel present with `discovery=[failed]`** — every candidate root failed traversal, or the discovery command produced no output at all (the fence's else arm). The fence already blanked `MANIFESTS`, so `manifest=[]` and nothing was filed. Do **not** read that `manifest=[]` as the clean no-op: no manifest could be discovered. The fence already recorded a `dropped-failed` discovery-failure reflection naming the persisted aggregate path — apply nothing further this run.
- **Sentinel present with `discovery=[partial]` — a qualifier on the arms below, not one of the six exits:** at least one candidate root failed traversal and the failed root was **already recorded in-fence** (a `dropped-failed` reflection). Whether any deferrals were filed is read off `manifest=` and `filing=` exactly as the arms below require — a partial run with `manifest=[]` or an empty `filing=` filed nothing; partial does not by itself imply any manifest was found. Apply labels only if `filing=[filed]` with a non-empty filed list, per the arms below.
- **Sentinel present with `discovery=[ok]`, `pr=[<n>]` and `manifest=[]`** — no hydrated aggregate (either there were no deferrals this run, or the merge produced nothing), so nothing was filed and there is nothing to label: apply nothing. This is the clean no-op (the `discovery=[ok]` requirement is what distinguishes this genuine clean no-op from a failed/partial discovery that also printed `manifest=[]`). (A jq-merge *failure* already recorded its own `dropped-failed` reflection inside the fence, so it is not silently swallowed here.)
- **Cwd-drift suspicion (issue #555 known limitation) — a heuristic qualifying the clean-no-op arm above, not one of the six exits:** when Phase 3.3's run reported emitting a deferrals manifest but every root classifies `absent` in the surfaced `devflow: discovery roots:` line, treat the run as suspect and compare the roots-echo's absolute paths against where Phase 3.3 executed, rather than accepting the clean no-op.
- **Sentinel present with `manifest=[hydrated]` and `filing=[filed]`, but `filed deferred-finding issues=[]`** — the aggregate held deferrals, the filing arm *ran and succeeded*, yet you can read no filed issue numbers. That is a real capture gap, not a benign no-op: record it durably and apply nothing — `workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.0.5 filed deferred review-finding issues but could not read their numbers — the configured deferred labels were applied to NONE of them; the filed issues carry none of the configured deferred labels."`
  **Read `filing=` before concluding a capture gap.** Three other arms also print an empty number list, and none of them is a capture gap — asserting one would fabricate a durable reflection claiming issues were filed on a run that filed none: `filing=[idempotent]` (a prior run already filed them; the hydrated aggregate stands — nothing to label this run), `filing=[none]` (the aggregate held no deferrals), and `filing=[failed]` (the filing itself failed and **already recorded its own accurate reflection inside the fence** — do not add a second, contradicting one). Only `filing=[filed]` with an empty list is the gap.
- **The config read produced no output at all** — you received no `deferred labels to apply: [...]` line whatsoever. The command was refused, not answered: do **not** read that as "no labels configured" (the capture shape is unproven on this tier — see the discipline note above). Record it and apply nothing — `workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.0.5 could not resolve deferred.labels — the config-get command produced no output at all (likely a harness denial, not an empty config); deferred review-finding issues were filed WITHOUT labels."`

If the printed `CLEAN_DEFERRED_LABELS` is present but empty (config resolved to no labels), apply nothing. Otherwise, read it and apply the labels with **single granted-literal leading-token calls, iterating at the agent level** (the label helpers must never be wrapped in a shell loop or an output capture):

- For **each** label in the printed comma-list (skip blanks), ensure it exists with one call — the helper path is the leading token, and `ensure-label.sh` is best-effort (always exits 0). `ensure-label.sh` always breadcrumbs to stderr (`created` / `already exists` / `warning: …`), so **no output at all means the command was refused by the harness** — record it (`--reflection-kind dropped-failed`) and continue to the apply, which reports separately whether the label landed.
  ```bash
  "${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/ensure-label.sh "<label>"
  ```
- For **each** filed issue number in the printed `filed deferred-finding issues=[…]` list (the numbers `file-deferrals.py` filed, echoed back to you above — **not** a live `$FILED_NUMBERS` shell variable, which does not survive into this separate command), apply the whole comma-list with one call — the helper path is the leading token, the issue number and resolved label list substituted as literals:
  ```bash
  "${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/apply-labels.sh <filed-issue-number> "<deferred-labels>"
  ```
  `apply-labels.sh` is best-effort (always exits 0) and **always** prints a breadcrumb to **stderr** on **every path it can take** — a harness refusal is its ONLY silent outcome. **Read that stderr from the tool result and route on it — all four outcomes, not just the failure one:** a `devflow: applied label(s) '…' to #N` line means the labels landed; a `devflow: warning: could not apply …` line is an **API failure** (POST `.../issues/{n}/labels` — repo-scope only; never `gh issue edit --add-label`'s org-scoped GraphQL); a `devflow: warning: apply-labels.sh got no label content …` or `… got a non-numeric issue/PR number …` line is a **caller arg-slip** — the breadcrumb says outright that it is *not* a harness denial — meaning the label list you substituted was empty/whitespace-only, or the number did not survive into this command, so re-emit the call once with the printed literal values before recording anything; and **no output at all means the command was refused by the harness** (a denied command prints nothing, which is exactly why the helper breadcrumbs on every other path — otherwise "applied", "denied" and "the caller passed no label content" would look identical and the guard below would have no comparand in the case it exists to catch). Record any surviving non-success durably (stderr is ephemeral in an autonomous cloud run), naming which outcome it was: `workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.0.5 could not apply the configured deferred labels (<deferred-labels>) to issue #<filed-issue-number> — the apply reported an API failure or a caller arg-slip, or produced no output at all (a harness denial); the issue was filed but carries none of the configured deferred labels."`

The rc handling above distinguishes three cases: a clean filing (rc 0), the benign idempotent-re-run (`exit 2` with "already has follow_up" — the prior aggregate is still hydrated, `/pr-description` reads it fine, recorded as a plain note), and a genuine failure (any other non-zero — every `gh issue create` group failed, or an unusable/corrupt manifest), which lands a `Devflow Reflection` breadcrumb. On a genuine failure continue to 4.1 anyway — the PR can still ship; it just won't carry the Scope-Acknowledged Findings block, so `/devflow:review` will treat any deferred findings as new.

### 4.1 Update Documentation

**The routine doc pass always runs — narrative never suppresses it.** A narrative claim that documentation is unnecessary — including an **absent, empty, or contradictory** `**Documentation Needed**` bullet — **never** suppresses the routine documentation pass: the `devflow:docs` subagent still runs and updates the documentation warranted by the shipped behavior change. The `**Documentation Needed**` bullet is an **additive floor** of mandatory deliverables (it can only *add* required files), **never a ceiling that authorizes skipping otherwise-warranted documentation**. This mirrors the §2.1 authority hierarchy — the Implementation Notes narrative, `Documentation Needed` included, is a non-authoritative starting point, so it can never narrow or suppress the doc work the shipped diff warrants. The deterministic two-stage gate below is **unchanged in behavior**: it enforces the floor (every named deliverable must ship); it does not decide whether the doc pass runs.

**Stage 1 — Pre-flight briefing (before dispatch).** Extract the issue's required documentation deliverables **deterministically — do not interpret the prose yourself.** Run the bundled helper, which scopes to the `**Documentation Needed**` bullet under `## Implementation Notes` and emits the recognizable file paths one per line:

```bash
# Read the issue body to a FIXED temp FILE (statement 1), then extract from that file
# (statement 2). The intermediary is a literal file PATH on disk — NOT a variable and NOT a
# shell option — so NOTHING marshaled (a reused value, a `set -o pipefail` option) has to
# survive between the two statements: an inline-bash runner that strips such cross-statement
# state (Copilot CLI / Cursor / Codex CLI / Gemini CLI) cannot wave this gate open the way it
# would a reused ISSUE_BODY value or a `pipefail` that didn't take effect on the pipeline.
# Each statement's `if ! A && ! B` reads its OWN command's exit status inline (gh's, then the
# extractor's); a command failure never reads as a no-op — read AND retry both failing → fail
# CLOSED to the Blocked path. An rc-0 EMPTY extraction (gh ok, no Documentation Needed paths)
# legitimately leaves DOC_NEEDED_PATHS empty for the no-op handled below. ($ISSUE_NUMBER is
# substituted inline in the path exactly as in the gh command — no new cross-statement value.)
if ! gh issue view $ISSUE_NUMBER --json body --jq '.body' > /tmp/devflow-docgate-body-$ISSUE_NUMBER.txt 2>/tmp/devflow-docgate-gh.err \
   && ! gh issue view $ISSUE_NUMBER --json body --jq '.body' > /tmp/devflow-docgate-body-$ISSUE_NUMBER.txt 2>/tmp/devflow-docgate-gh.err; then
  "${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/workpad.py update $ISSUE_NUMBER --status Blocked --reflection-kind dropped-failed --reflection "Phase 4.1: could not read the issue body to extract Documentation Needed deliverables (gh command failure); the deliverable cross-check could not run — retry when GitHub is reachable"
  # then emit the 👎 outcome reaction (see the Workpad Reference) and STOP the run.
fi
if ! DOC_NEEDED_PATHS=$("${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/extract-doc-needed-paths.sh < /tmp/devflow-docgate-body-$ISSUE_NUMBER.txt) \
   && ! DOC_NEEDED_PATHS=$("${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/extract-doc-needed-paths.sh < /tmp/devflow-docgate-body-$ISSUE_NUMBER.txt); then
  "${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/workpad.py update $ISSUE_NUMBER --status Blocked --reflection-kind dropped-failed --reflection "Phase 4.1: the Documentation Needed extractor failed (token scan error); the deliverable cross-check could not run — retry"
  # then emit the 👎 outcome reaction and STOP the run.
fi
```

**Each `if ! A && ! B` guard discriminates a command failure by that command's own exit status, never stdout emptiness.** A gh failure (auth, network, rate-limit, or a wrong issue number) fails statement 1's guard; an extractor failure (its own token scan failed) fails statement 2's — either is a *command failure* that says nothing about which paths the issue names, so **never treat its empty stdout as a no-op**, the way an empty `DOC_NEEDED_PATHS` would be treated below. That is the exact fail-open this gate exists to close, moved one stage upstream; each statement's retry is folded into its `if ! A && ! B` guard so the fail-closed branch fires only when the read *and* its retry both fail, then routes to the Blocked path shown above, emits the 👎 outcome reaction, and stops. Passing the body through a **fixed temp file** (not a reused `ISSUE_BODY` value, not a `set -o pipefail` option) is what keeps this robust on a runner that strips cross-statement state. Only an rc-0 read with empty `DOC_NEEDED_PATHS` is the legitimate empty signal handled below.

**Span-suppression breadcrumb disclosure (issue #644, once per run).** The extractor now suppresses command/grant literals inside the Documentation Needed block (a `` `bash lib/test/run.sh` `` command span, a `` `Bash(x.sh:*)` `` grant, an un-backticked `Word(...)` call group) so they never become phantom deliverables, emitting a one-time `suppressed a span` breadcrumb on **stderr** when it does. This gate does **not** capture that stderr (no implement-probe row has proven a stderr-capture shape on this tier, so the fail-closed choice is to ship without the capture rather than risk a denied shape reading as an empty extraction), so on the cloud tier the breadcrumb is ephemeral. Record the residual once by Stage 1 so it is disclosed in the run record: `workpad.py update $ISSUE_NUMBER --note "Phase 4.1: extractor span-suppression breadcrumbs are not durably observable on the cloud tier (stderr not captured); a suppressed command/grant literal in the Documentation Needed block leaves no run-record trace"`. This is a plain note, not a reflection — it discloses a known, accepted residual, not a per-run failure.

These paths are the required deliverables. Stage 2 re-runs the **same helper** rather than re-deriving them, so the two passes can never disagree about which files were named. If `DOC_NEEDED_PATHS` is empty (the section is absent, names no file paths, or holds only non-path prose), Stage 1 is a no-op and the subagent is dispatched with its normal instruction unchanged. If the helper emits nothing **but** the issue body still contains a Documentation Needed section **in either accepted form** — the bold-bullet `**Documentation Needed**` form **or** a `### Documentation Needed` heading (`gh issue view $ISSUE_NUMBER --json body --jq '.body' | grep -qE '\*\*Documentation Needed\*\*|^###[[:space:]]+\*{0,2}Documentation Needed'` — the heading alternative carries the same `\*{0,2}` bold-tolerance as the extractor's own opener so the two heading recognizers cannot drift) — record a workpad note (`workpad.py update $ISSUE_NUMBER --note "Phase 4.1: Documentation Needed section present but the extractor found no file paths; the deliverable cross-check is skipped this run"`) so the skipped enforcement is auditable for either form. (The heading form is the third extractor shape added in issue #380; matching only the bold-bullet form here would leave a heading-form issue's empty extraction silently unrecorded — the exact #363 gap.)

Spawn a **subagent** (using the Agent tool) and instruct it to invoke the `devflow:docs` skill. Compose the dispatch instruction: begin with "Invoke the `devflow:docs` skill to update all documentation (internal docs, external docs, release notes). The issue context is provided for release notes generation." If `DOC_NEEDED_PATHS` is non-empty, append: " The issue requires the following files to be updated; treat each as a mandatory deliverable: `<path1>`, `<path2>`, …" Send this composed instruction along with the issue title and number inline (the devflow:docs dispatch, on every arm). **Hand the issue body off by path, not paste (issue #693):** when the §1.1 cache was written, add an `Issue body path: .devflow/tmp/issue-body/issue-<ISSUE_NUMBER>.md` line instructing the `devflow:docs` subagent to Read that file directly, and do **not** paste the body into the prompt. **Only** ship this line when the §1.1 write landed — on the degraded arm where no cache was written, **paste the issue body inline** (the pre-#693 behavior) instead. (The Documentation-Needed gate fences above are deliberately **not** cut over — they read the body live, because a human can amend the deliverable list mid-run.)

After the subagent completes, commit every documentation artifact it changed. Read the configured documentation paths from `.devflow/config.json` — `config-get.sh` **prints** each value, so read the four tool results and substitute non-empty values as literals below. (A `VAR=$(…)` capture does not survive across Bash tool calls on the cloud runner — values expand empty in the later call and `git add ""` fails; #484/#490.)

```bash
"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/config-get.sh .docs.internal docs/internal/
"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/config-get.sh .docs.external docs/external/
"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/config-get.sh .docs.release_notes_file ""
"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/config-get.sh .docs.changelog_file ""
```

Each invocation is a separate observed tool call. For the required internal and external roots, success is rc 0 plus exactly one non-empty printed path. For the optional release-notes and changelog files, rc 0 with empty output means that artifact is disabled; any non-empty output must be exactly one path. A matcher refusal, non-zero exit, multi-line/non-path output, or empty required path is **not** "no documentation changes": retry that read once, then mark the workpad `Blocked` with a `dropped-failed` reflection naming the config key, emit the outcome reaction, and stop. Accept only repo-relative paths that do not begin with `-`.

Inspect unfiltered `git status --short` after the docs subagent returns. Build the explicit staging list from every documentation artifact that dispatch changed: configured internal/external paths, each enabled release-notes/changelog file, every `Documentation Needed` path, and any other doc/release artifact the subagent reports and `git status` confirms (for example `README.md` or a `.changeset/` entry). Do not stage unrelated code or pre-existing dirty paths. If that explicit list contains changes, stage and commit the literal paths:
```bash
git add "<literal-doc-path-1>" "<literal-doc-path-2>" # include every changed doc/release artifact; omit absent optional paths
git commit -m "docs: update documentation for issue #$ARGUMENTS"
git push
```

Only when the subagent returned cleanly and unfiltered status confirms it produced no documentation artifact may this be recorded as a clean no-change pass:
```bash
"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/workpad.py update $ISSUE_NUMBER --note "Phase 4.1: no documentation changes to commit (docs subagent ran clean / made no changes)"
```

Then decide whether the docs pass succeeded: it succeeded if the docs subagent actually ran — either it produced changes (committed above) or it returned cleanly with no changes needed. If instead the docs subagent failed, returned no useful output, or was unable to run, that is actionable: add a `--reflection-kind dropped-failed --reflection "…"` bullet to the workpad and do **not** apply the post-docs labels at all (now or later). The post-docs labels signal "the docs pass ran and was reviewed", but they are **not** applied here — application is deferred to the end of Stage 2 so that a PR which routes to Blocked for an undelivered deliverable never carries them (the label resolution is shown there). (Downstream docs automation, if the adopter runs any, can key off these labels to avoid double-processing the PR.)

**Stage 2 — Post-hoc diff gate (mandatory when Stage 1 found named paths).** After the docs-subagent commit and before ticking `Documentation`, verify that every required-deliverable path has been touched. Re-run the **same deterministic helper** as Stage 1 — re-running the helper is the single source of truth; do not rely on remembered Stage 1 output:

```bash
# Same fixed-temp-FILE two-statement guard as Stage 1: gh writes the body to a literal disk
# path (statement 1), the extractor reads that file (statement 2). The intermediary is a file
# PATH, not a variable and not a shell option, so no marshaled cross-statement state has to
# survive on a stripping inline-bash runner. Each statement's `if ! A && ! B` reads its OWN
# command's exit status inline (gh's, then the extractor's); read AND retry both failing →
# fail CLOSED to Blocked; an rc-0 EMPTY extraction stays the genuine no-op signal.
if ! gh issue view $ISSUE_NUMBER --json body --jq '.body' > /tmp/devflow-docgate-body-$ISSUE_NUMBER.txt 2>/tmp/devflow-docgate-gh.err \
   && ! gh issue view $ISSUE_NUMBER --json body --jq '.body' > /tmp/devflow-docgate-body-$ISSUE_NUMBER.txt 2>/tmp/devflow-docgate-gh.err; then
  "${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/workpad.py update $ISSUE_NUMBER --status Blocked --reflection-kind dropped-failed --reflection "Phase 4.1: could not read the issue body to extract Documentation Needed deliverables (gh command failure); the deliverable cross-check could not run — retry when GitHub is reachable"
  # then emit the 👎 outcome reaction and STOP the run.
fi
if ! DOC_NEEDED_PATHS=$("${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/extract-doc-needed-paths.sh < /tmp/devflow-docgate-body-$ISSUE_NUMBER.txt) \
   && ! DOC_NEEDED_PATHS=$("${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/extract-doc-needed-paths.sh < /tmp/devflow-docgate-body-$ISSUE_NUMBER.txt); then
  "${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/workpad.py update $ISSUE_NUMBER --status Blocked --reflection-kind dropped-failed --reflection "Phase 4.1: the Documentation Needed extractor failed (token scan error); the deliverable cross-check could not run — retry"
  # then emit the 👎 outcome reaction and STOP the run.
fi
```

**Each `if ! A && ! B` guard discriminates a command failure by that command's own exit status, never stdout emptiness** — symmetric to the diff side below. A gh failure (auth, network, rate-limit, or a wrong issue number) fails statement 1's guard; an extractor failure (its own token scan failed) fails statement 2's — either is a *command failure* that says nothing about which paths the issue names, so **never treat its empty stdout as a no-op** (the step-1 escape hatch below), which would silently wave the gate through exactly when the deliverable list could not be read. Each statement's retry is folded into its `if ! A && ! B` guard so the fail-closed branch fires only when the read *and* its retry both fail, then routes to the Blocked path shown above, emits the 👎 outcome reaction, and stops; passing the body through a fixed temp file (not a reused `ISSUE_BODY` value, not a `set -o pipefail` option) keeps it robust on a runner that strips cross-statement state. Only an rc-0 read with empty `DOC_NEEDED_PATHS` is the legitimate empty signal step 1 treats as a no-op.

1. **No-op when empty.** If `DOC_NEEDED_PATHS` is empty, this cross-check is a no-op — proceed directly to the post-docs-labels + `--tick-progress "Documentation"` step below.

2. **Compute the diff once; fail closed on a broken command.** Verify `$BASE` is non-empty; if empty, re-derive it exactly as Phase 1.4 does, **applying its non-empty fallback and not just the config read** — the read alone returns nothing on malformed config and would otherwise leave `$BASE` empty, collapsing the range to `origin/...HEAD` and judging every path absent. Compute the cumulative diff, guarding git's exit status **inline** (never a captured rc read in a later statement, which a cross-statement-variable-stripping inline-bash runner would leave empty):
   ```bash
   # Single-statement `if ! A && { re-fetch; ! B; }`: the failure branch fires off git's OWN
   # exit status read inline. The retry re-fetches the base branch (as Phase 1.4 does)
   # between attempts; read AND retry both failing → fail CLOSED to Blocked. An rc-0 result
   # with EMPTY stdout is NOT a failure — the `if !` leaves DIFF_OUT set and the per-path
   # check below reads it as the genuine "touched none of these files" signal.
   if ! DIFF_OUT=$(git diff --name-only "origin/$BASE...HEAD") \
      && { git fetch origin "$BASE" >/dev/null 2>&1; ! DIFF_OUT=$(git diff --name-only "origin/$BASE...HEAD"); }; then
     "${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/workpad.py update $ISSUE_NUMBER --status Blocked --reflection-kind dropped-failed --reflection "Phase 4.1: could not compute the cumulative diff for the Documentation Needed gate (git diff / base-fetch failed — offline, auth, or wrong trunk); never falling through to a path-absent verdict on a broken command"
     # then emit the 👎 outcome reaction and STOP the run.
   fi
   ```
   The `if !`-guard discriminates the failure by git's own exit status, **never** stdout emptiness. A `git diff` failure (or `origin/$BASE` not present locally) is a *command failure* that says nothing about any path: it re-fetches the base branch as Phase 1.4 does and retries once, and if the retry also fails (offline / auth / wrong trunk) it does not guess — it routes to the Blocked path and stops; **never fall through to a path-absent verdict on a broken command.** Conversely, **an rc-0 result with empty stdout is NOT a failure** — it is the legitimate signal that the diff touched none of these files (the genuine absence the gate exists to catch); treat it as real and continue to the per-path check. For each path in `DOC_NEEDED_PATHS`, decide satisfied vs absent against `DIFF_OUT`: if it is a bare filename (contains no `/`), any diff entry whose basename matches it counts as satisfied (e.g. the diff entry `docs/DEVFLOW_SYSTEM_OVERVIEW.md` satisfies the named path `DEVFLOW_SYSTEM_OVERVIEW.md`); if it contains a `/`, it must appear as an exact match in `DIFF_OUT`.

3. **Self-heal or block for each absent path.** For each named path absent from the diff, perform the missing update when you can: if the correct update can be derived from the issue body's `**Documentation Needed**` prose, perform the missing update yourself, record a workpad note (`workpad.py update $ISSUE_NUMBER --note "Phase 4.1 self-heal: <path> absent from diff; performed update from Documentation Needed prose"`), commit (`docs:` prefix), and push. **Then re-verify the self-heal landed and reached the remote:** confirm the commit and push both succeeded *and* that the local branch is in sync with its upstream — `git rev-parse HEAD` must equal `git rev-parse @{u}` (a no-op `Everything up-to-date` push or a rejected non-fast-forward leaves them unequal, so a re-diff of the still-local commit would falsely satisfy the gate) — then re-run the helper-driven diff check for that path. A non-zero rc on commit/push, an upstream that does not match HEAD, or the path still absent from the re-checked diff all mean the self-heal did not land. Only a path now present in the re-checked diff **and** whose commit and push both reached the remote counts as satisfied. If the correct update cannot be derived from context (the prose is insufficient), **or** the self-heal did not land per the re-check, do not tick `Documentation` — route to the Blocked path: `workpad.py update $ISSUE_NUMBER --status Blocked --reflection-kind blocked --reflection "Phase 4.1: Documentation Needed file content cannot be determined for <path> — the docs subagent did not update this file and the correct content cannot be derived from the issue body; update manually and re-run Phase 4.1"`, then emit the 👎 outcome reaction (see *Outcome reaction* in the Workpad Reference) and stop.

Once every named path is satisfied (or Stage 1 found no paths), apply the deferred post-docs labels — only when the docs pass succeeded per the Stage-1 decision above; a run that routed to Blocked never reaches this point, so a Blocked PR never carries them. `docs.labels` is a comma-separated list (default `Documented`); normalize it (split on commas, trim each entry, drop empties) and apply through the shared REST label-apply helper (a PR is an issue, so `POST .../issues/{n}/labels` serves it — repo-scope only, unlike `gh pr edit --add-label`'s org-scoped GraphQL resolution). The REST path needs the PR number explicitly, so resolve it first from the current branch:

**Cloud-emission discipline (label helpers): iterate at the agent level, never in a shell loop or a capture — identical to Phase 4.0/4.0.5, see the *Cloud command-shape discipline* section in `skills/implement/SKILL.md`.** This channel gets the *same* treatment as the two deferral channels, for the same reason: the `apply-labels.sh` call must be a **single leading-token statement**, not nested inside an `if` compound (a shape **no probe row measured** — see that section's *Unproven* bullet), and the config read must fail **closed** on no output rather than reading a possible denial as "no labels configured". First resolve and **print** the values (a shell variable does not survive into a later separate command on the cloud runner, so the per-call values must reach you through a tool result):

```bash
# GRANTED heads only — `paste` is granted in NO allowlist, so a `| paste -sd, -` tail makes
# the whole pipeline refused and the capture silently empty (the same trap Phase 4.0 notes).
if ! DOCS_LABELS=$("${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/config-get.sh .docs.labels Documented); then
  DOCS_LABELS=""
  "${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.1 could not read docs.labels (config-get rc≠0 — corrupt config.json or python3 missing); the PR carries none of the configured docs labels."
fi
CLEAN_LABELS=$(echo "$DOCS_LABELS" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
DOCS_PR_NUM=$(gh pr view --json number --jq '.number')
# Print all three: an emptied normalizer must not be indistinguishable from an empty config
# (CLAUDE.md guard-class 2), and the PR number is needed as a literal in the apply call below.
echo "docs.labels raw: [$DOCS_LABELS]"
echo "docs labels to apply: [$CLEAN_LABELS]"
echo "docs PR number: [$DOCS_PR_NUM]"
```

Four exits before any label is applied — the same fail-closed set the deferral channels carry:

- **No lines printed at all.** The command was refused, not answered. Do **not** read it as "no labels": record it and apply nothing — `workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.1 could not resolve docs.labels — the config-get command produced no output at all (likely a harness denial, not an empty config); the PR carries none of the configured docs labels."`
- **`raw` non-empty but `to apply` empty.** A broken normalizer (a missing/denied `tr`/`sed`/`grep`), not an empty config: record it and apply nothing — `workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.1 resolved docs.labels to a non-empty value but the normalizer produced an empty list (a missing/denied tr|sed|grep in the pipeline); the PR carries none of the configured docs labels."`
- **`docs PR number` empty.** The REST endpoint needs the PR number, which the old `gh pr edit` form resolved implicitly — so an empty value (a `gh` error, warning-corrupted output) is a real failure point, not a reason to skip silently and tick Documentation complete: record it and apply nothing — `workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.1 could not resolve the PR number to apply docs labels; the PR carries none of the configured docs labels."`
- **`raw` empty (and printed), and no rc≠0 breadcrumb above.** The config genuinely resolved to no labels: apply nothing — the clean no-op. (The `if !` hard-read-failure branch also leaves `raw` empty, but it recorded its own `dropped-failed` reflection and is not a no-op.)

Otherwise, read the printed values and apply the labels with **single granted-literal leading-token calls, iterating at the agent level**:

- For **each** label in the printed comma-list (skip blanks), ensure it exists with one call — the helper path is the leading token, and `ensure-label.sh` is best-effort (always exits 0). `ensure-label.sh` always breadcrumbs to stderr (`created` / `already exists` / `warning: …`), so **no output at all means the command was refused by the harness** — record it (`--reflection-kind dropped-failed`) and continue to the apply, which reports separately whether the label landed.
  ```bash
  "${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/ensure-label.sh "<label>"
  ```
- Apply the whole comma-list to the PR with one call — the helper path is the leading token, the PR number and resolved label list substituted as literals (**not** `$DOCS_PR_NUM`/`$CLEAN_LABELS` shell variables, which do not survive into this separate command):
  ```bash
  "${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/apply-labels.sh <docs-pr-number> "<docs-labels>"
  ```
  `apply-labels.sh` is best-effort (always exits 0) and **always** prints a breadcrumb to **stderr** on **every path it can take** — a harness refusal is its ONLY silent outcome. **Read that stderr from the tool result and route on it — all four outcomes, not just the failure one:** a `devflow: applied label(s) '…' to #N` line means the labels landed; a `devflow: warning: could not apply …` line is an **API failure** (POST `.../issues/{n}/labels` — repo-scope only; never `gh pr edit --add-label`'s org-scoped GraphQL); a `devflow: warning: apply-labels.sh got no label content …` or `… got a non-numeric issue/PR number …` line is a **caller arg-slip** — the breadcrumb says outright that it is *not* a harness denial — meaning the label list you substituted was empty/whitespace-only, or the number did not survive into this command, so re-emit the call once with the printed literal values before recording anything; and **no output at all means the command was refused by the harness** (a denied command prints nothing, which is exactly why the helper breadcrumbs on every other path — otherwise "applied", "denied" and "the caller passed no label content" would look identical and the guard below would have no comparand in the case it exists to catch). Record any surviving non-success durably (stderr is ephemeral in an autonomous cloud run), naming which outcome it was: `workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.1 could not apply the configured docs labels (<docs-labels>) to PR #<docs-pr-number> — the apply reported an API failure or a caller arg-slip, or produced no output at all (a harness denial); the PR carries none of the configured docs labels."`

Then tick the Documentation phase in the workpad: `workpad.py update $ISSUE_NUMBER --tick-progress "Documentation"`.

**Discharge every 3.4-deferred documentation AC (mandatory, before §4.3).** Phase 3.4's *Documentation-AC deferral* rule leaves any acceptance criterion whose satisfaction is a Phase-4.1-owned `docs/…` edit **unticked** at the gate, recording it in a workpad note of the form `3.4: doc-AC deferred to Phase 4.1: {AC text}`. Those deferrals are this phase's obligation to close: now that the docs pass has run and its changes are committed, for **each** such deferred doc-AC confirm the docs the criterion required actually landed in this run's diff (the Stage 2 gate above already verified the named deliverable paths), then tick it by its 1-based position, citing the deferral note — `workpad.py update $ISSUE_NUMBER --tick-ac-n {N} --note "Phase 4.1 discharged 3.4-deferred doc-AC: {AC text} — docs authored by the devflow:docs pass"` (consume the tick call's exit code per the failure-isolation contract; a non-zero exit means the index did not resolve — re-resolve and re-tick). This tick **must** happen before §4.3's terminal `--status Complete` write, because `scripts/workpad.py`'s `_terminal_complete_gate` hard-fails a Complete write while any non-post-merge Acceptance Criteria row is still `- [ ]` — a doc-AC left unticked would abort the finalize. If a deferred doc-AC genuinely **cannot** be discharged (the docs pass could not author it and the content cannot be derived), do **not** tick it and do **not** finalize Complete: take the existing Blocked path (`workpad.py update $ISSUE_NUMBER --status Blocked --reflection-kind blocked --reflection "Phase 4.1: 3.4-deferred doc-AC could not be discharged: {AC text}"`), emit the 👎 outcome reaction, and stop — never a silent Complete over an undischarged doc-AC.

**Re-anchor before §4.2 (mandatory, after the Phase 4.1 `devflow:docs` subagent returns and its docs are committed).** Phase 4.1 above dispatched a context-isolated `devflow:docs` subagent (Stage 1/Stage 2); a long subagent return can evict this phase file from your working set, which is exactly how a run stops at "documentation done" before reaching §4.2/§4.3. So now that the docs subagent has returned and its docs are committed, before proceeding to §4.2, **`Read` `"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/phases/phase-4-documentation.md` again and follow it exactly** — re-anchoring the remaining §4.2 (PR description) and §4.3 (finalize) procedure, never relying on the earlier entry-gate read. This re-anchor is scoped to **subagent** returns — here, the Phase 4.1 docs subagent; do not apply it to the Phase 2 or Phase 3 subagent returns, whose phases carry their own entry-gate reads. A **Skill-tool** return is covered instead by the generalized mid-phase re-anchor in the orchestrator's cross-phase rules, which fires after every Skill return in any phase.

### 4.2 Generate PR Description

Invoke the **Skill tool** with `skill: "pr-description"` and `args: "$ARGUMENTS"` (the issue number). The skill detects the existing PR and updates its body directly.

Verify the PR Description update landed before moving to the next step.

```bash
gh pr view --json body --jq '.body' | grep -q "Work in progress — automated review pending" && echo "STILL PLACEHOLDER" || echo "OK"
```

**Reconcile the PR body's behavioral claims (mandatory, before finalizing).** `/pr-description` authored the body just now, so this is the Phase 4.2 counterpart of the §2.3.4a self-authored-claim sweep — applied to the one surface that did not exist at commit time. Re-read the PR body and, for **every** behavioral claim it makes about what the shipped code does (a "this PR adds X that does Y", a described flow, a stated guarantee, or a `## Post-Merge Verification` item that on inspection actually describes *already-shipped* behavior rather than a genuinely live-only check — the same confirmation-of-self-claim case the Phase 3.4 gate refuses a `(post-merge)` tag for), trace the **actual shipped code path** — following dispatch into pre-existing code the diff calls — and confirm the code does what the body says. **The code is the fact**, under the same fix-or-rewrite rule as 2.3.4a:

- If the body **overclaims** (asserts a behavior the diff doesn't deliver), correct the body to the truth via REST (repo-scope only, unlike `gh pr edit`'s org-scoped GraphQL resolution): write the corrected body to a file, resolve the PR number (guarding the empty case so a `gh pr view` hiccup doesn't build a malformed `pulls/` path), and PATCH it. The `-F body=@<file>` form reads the field value literally from the file, preserving backticks and `$` exactly as `--body-file` did. This is the common case, since the body was just auto-generated and can overstate:
  ```bash
  OVERCLAIM_PR_NUM=$(gh pr view --json number --jq '.number')
  if [ -n "$OVERCLAIM_PR_NUM" ]; then
    gh api --method PATCH "repos/{owner}/{repo}/pulls/$OVERCLAIM_PR_NUM" -F body=@<file>
  else
    echo "devflow: Phase 4.2 could not resolve the PR number to correct an overclaiming body (best-effort, continuing)" >&2
  fi
  ```
- If reconciliation reveals the **code** is actually wrong (the body states the intended behavior but the diff doesn't meet it), that is a real defect that escaped review: fix the code, commit with `fix:`, and push. On the default `ready_for_review` publish path that fix rides into the cloud `/devflow:review` that re-runs when Phase 4.3 publishes the PR; **but when `implement_pr_state=draft` the PR is left a draft and the cloud review does not auto-fire until a human publishes** (see §4.3), so the fix ships *unreviewed* until then. Either way, record in `Devflow Reflection` that a post-review code fix landed here so it is not mistaken for a reviewed change — and flag it more loudly on the draft path, where no automatic re-review will catch it.

Never finalize a PR whose description asserts a behavior the diff does not deliver. Record the reconciliation in a workpad `--note` (claims checked; any divergence and how it was resolved).


### 4.3 Finalize the PR (publish or leave draft) and Finalize Workpad

**Clean-tree backstop (always, before the publish decision).** Assert nothing uncommitted survives the run — this runs **unconditionally**, independent of whether the PR will be published or left a draft:

```bash
git status --porcelain
```

If it is non-empty, **do not** finalize yet. The run began from a clean base-branch checkout (`origin/` + the configured `base_branch`), so anything dirty here is this run's own work an earlier phase failed to commit. Commit the part that belongs to this PR with the right prefix (`feat:`/`fix:`/`docs:`/`chore:`) and push, and record which phase under-committed via `--reflection-kind note --reflection "…"` (a corrected under-commit is informational, not a standing failure) — surface the gap, don't paper over it. Surface (do not blindly `git add`) any unexpected untracked file. When the tree is already clean this is a no-op — create no empty commit.

**Run-transient files are the exception — delete, never commit.** A leftover **reflection-payload file** under `.devflow/tmp/` (authored by the file-based `--reflection-file` recipe when a reflection's text carried backticks/`$`/quotes — see `skills/implement/SKILL.md`) is run-transient scratch, not a deliverable: the recipe is supposed to `rm` it after the helper call, but if one survives here, **delete it** rather than committing it. This repo and `install.sh`-scaffolded adopters ignore `.devflow/tmp/`, so the porcelain status above won't even list it there — but a **plugin-only adopter** has no `.devflow/.gitignore` scaffold, so the same leftover shows up as an untracked file that a blind `git add` would commit into the PR. Treat any `.devflow/tmp/` reflection-payload leftover as transient (delete it), never as run work to commit.

**Base-branch update checkpoint 4 (pre-ready) — after the clean-tree backstop, before the publish decision.** So the terminal *published* state carries current base (the review-tier deferral's head-scoped re-evaluation cannot see base advances — issue #448), bring the branch up to date one last time:

```bash
"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/update-branch-checkpoint.sh
```

Handle the printed token **per the implement-driven outcome-handling contract in phase-1-setup.md §1.4.1** (workpad recording; `Blocked` on `MERGE_IN_PROGRESS` or a failed conflict resolution; resolve a `CONFLICT`, run the suite, and re-run the Phase 2.3.0 sweep; record-and-continue on `UNVERIFIED`/`PUSH_REJECTED`), with one **checkpoint-4-specific** addition that gates the publish below:

- On **`UPDATED`** (a real merge landed) the pushed state was **not** seen by any review pass, so **re-run the project test suite** before publishing. A **pass** proceeds to the publish decision. A **fail** routes to the **Blocked path** (`workpad.py update $ISSUE_NUMBER --status Blocked --reflection-kind blocked --reflection "checkpoint 4: post-merge suite failed — not publishing"`, emit the 👎 reaction, stop) **instead of** publishing. A suite that is **absent, ungranted, or otherwise unrunnable on this tier** publishes anyway with `--reflection-kind note --reflection "checkpoint 4: merged origin/base at pre-ready but the suite was not locally re-runnable — merge not locally re-verified; CI is the validating gate"` (CI validates on push).
- On **`UP_TO_DATE` / `DISABLED`** nothing changed, so no suite re-run is needed — proceed to the publish decision unchanged.

**Publish decision — `implement_pr_state`.** Whether the run publishes the PR or leaves it the draft created in Phase 3.1 is a per-consumer config choice. Read it (default `ready_for_review`), then publish **only** when it is not the exact literal `draft` — default-to-publish is the safe direction, so a missing key, empty string, or any unrecognized value publishes, and a hard read failure (malformed config) falls back to publishing. **Capture whether `gh pr ready` actually succeeded** so the finalize wording reflects the *real* end state — a bare `gh pr ready` whose failure (the `else` arm catches *any* non-zero exit — e.g. auth scope, GitHub 5xx, rate limit, a race that already merged/closed the PR) fell through would otherwise leave the workpad falsely claiming the PR was published when it is still a draft:

```bash
PR_STATE=$("${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/config-get.sh .devflow_implement.implement_pr_state ready_for_review) || PR_STATE=ready_for_review
PR_OUTCOME=draft   # one of: draft | published | publish_failed (overwritten below unless PR_STATE=draft)
if [ "$PR_STATE" = "draft" ]; then
    echo "devflow: implement_pr_state=draft — leaving PR as a draft (skipping gh pr ready)" >&2
elif gh pr ready; then
    PR_OUTCOME=published
elif [ "$(gh pr view --json isDraft --jq '.isDraft' 2>/dev/null)" = "false" ]; then
    # `gh pr ready` exited non-zero but the PR is NOT a draft — `gh pr ready` returns
    # non-zero on any non-draft PR, so this is the already-ready case (a Phase 4.3 re-run
    # after context recovery, or a PR a human/race already published). Treat as published,
    # not a failure, so a re-run doesn't emit a spurious "publish failed" reflection
    # contradicting reality. The check fails SAFE: if `gh pr view` itself errors (auth,
    # 5xx, PR deleted by a race), the substitution is empty, `!= "false"`, so it falls to
    # the else arm → publish_failed, the conservative direction.
    PR_OUTCOME=published
    echo "devflow: gh pr ready returned non-zero but PR is already non-draft — treating as published (idempotent re-run)" >&2
else
    PR_OUTCOME=publish_failed
    echo "devflow: gh pr ready FAILED — PR is still a draft, or its state could not be confirmed (implement_pr_state=$PR_STATE); do NOT finalize the workpad as 'marked ready'" >&2
fi
```

When `PR_STATE` is `draft` the PR is **left as the draft** from Phase 3.1: no `gh pr ready`, and **no additional comment** is posted to the PR thread. The downstream consequence is documented in [`docs/implement-skill.md`](../../../docs/implement-skill.md) — the cloud review (`devflow-review.yml`'s `ready_for_review` event) and CI's `ready_for_review` listener do not auto-fire until a human publishes the PR.

Then finalize the workpad — tick the final `## Progress` item and flip `Status` to `Complete` (the helper swaps the glyph to 🎉) in **every** case; only the `--note` wording differs, and on a publish failure a `dropped-failed` reflection is added (in its own `update` call, see below), so the workpad never falsely claims a PR was published. Pick the `--note` by `PR_OUTCOME`:

- **`PR_OUTCOME=draft`** → `--note "/devflow:implement run finished, PR left as draft per implement_pr_state=draft: <PR_URL>"`
- **`PR_OUTCOME=published`** → `--note "/devflow:implement run finished, PR published (gh pr ready): <PR_URL>"`
- **`PR_OUTCOME=publish_failed`** → `--note "/devflow:implement run finished, but gh pr ready FAILED — PR is still a draft, or its state could not be confirmed: <PR_URL>"` **and** emit a separate `workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "gh pr ready failed at Phase 4.3 — PR left unpublished despite implement_pr_state=$PR_STATE; publish it manually (gh pr ready) so the cloud review and CI ready_for_review listener fire"` call (the durable note mirrors the stderr breadcrumb's wording — it must not assert "still a draft" as fact on the unconfirmed-state path where the `isDraft` re-check itself errored). It is a **`dropped-failed`** reflection (a publish failure needing human action), so it goes in its own `update` call — separate from the `note`-kind finalize below — because one `--reflection-kind` applies to the whole call.

```bash
# Substitute the PR_OUTCOME-specific --note above. The general --reflection events
# are `note`-kind (informational troubleshooting log); the publish_failed
# `dropped-failed` reflection above is a SEPARATE update call (different kind).
# `--tick-progress "PR marked ready"` MUST match the `## Progress` row label verbatim — that
# label is owned by scripts/workpad.py (cmd_new_body template + _PROGRESS_PHASES +
# _STATUS_TO_PROGRESS_PHASE); do NOT rename it here without renaming it there (and in the
# python tests). If it no longer matches a row, the tick is a *volatile* miss (the
# `## Progress` section is still present), so this call still flips Status to Complete
# and writes the note but exits NON-ZERO — it does NOT abort. Per the failure-isolation
# contract, consume that exit code: a non-zero finalize means the "PR marked ready" box
# is still `- [ ]`, so re-resolve and re-tick it (or take the publish/clean-tree Blocked
# handling) rather than treating the run as cleanly Complete.
#
# TWO distinct non-zero exits are now possible here — read the stderr to tell them apart:
#   (1) a *volatile* tick miss (above): the body WAS PATCHed (Status flipped, note written),
#       only the "PR marked ready" row is still `- [ ]` — re-tick just that row.
#   (2) the terminal self-record gate (issue #258) *structurally aborts* this Complete write
#       — NO PATCH, Status NOT flipped — when a non-post-merge `## Acceptance Criteria` row
#       is still `- [ ]` (stderr: "refusing to finalize Status: Complete — … Acceptance
#       Criteria row(s) still unticked"). The Phase 3.4 gate should have ticked every
#       non-post-merge AC, so this fires only on a drift; do NOT retry the finalize verbatim.
#       Resolve the outstanding AC the same way Phase 3.4 does — tick it once its work is
#       real (`--tick-ac-n {N}`), or take the Blocked path if it genuinely cannot be met —
#       THEN re-issue the finalize. (post-merge AC rows never trip this; an unticked `## Plan`
#       row — or an `## Acceptance Criteria` section still holding the un-mirrored placeholder,
#       i.e. AC-mirroring never ran — only prints a non-blocking warning and the finalize still
#       succeeds. If that AC-placeholder warning fires, the self-record was never populated from
#       the issue: investigate the mirroring, do not just re-run the finalize.)
"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/workpad.py update $ISSUE_NUMBER \
    --status Complete \
    --tick-progress "PR marked ready" \
    --note "{PR_OUTCOME-specific note above}" \
    [--reflection-kind note --reflection "{noteworthy event}" ...repeat --reflection per event]
# Check the exit code of the finalize update above (per the failure-isolation
# contract): exit 0 means the "PR marked ready" box is now `- [x]` and the run is
# Complete; a non-zero exit means the tick missed (label drift / already ticked on a
# resumed run) — re-resolve and re-tick the row before treating the run as done.
```

Add one `--reflection` flag per noteworthy event a human should know for troubleshooting: a failed step that was skipped, a subagent that returned no useful output, a permission denial, a test you couldn't run, an ambiguity you resolved with an assumption, or any deviation from the planned flow. Kind each by the reflection style contract's routing rule (see `skills/implement/SKILL.md`): a deviation you worked around is the *informational* `note` kind (`--reflection-kind note`); an engine/process-improvement proposal is `improvement`; feedback that the driving issue's claims were wrong or underspecified is `issue-accuracy`; genuinely actionable failures (a dropped manifest entry, a publish failure) are emitted at the point they occur with `--reflection-kind dropped-failed` so they land under `### ⚠️ Action required`. `--reflection` is repeatable so all the same-kind events land in a single atomic update. (No separate "Notes from /devflow:implement run" comment is posted — the workpad replaces it.)

Finally, emit the 🎉 outcome reaction on the triggering comment (`REACTION=hooray`; see *Outcome reaction* in the Workpad Reference) — the implement lifecycle completed regardless of the publish decision (`draft`, `published`, or `publish_failed`; the publish failure is surfaced via the `--reflection` above, not by suppressing the reaction) — then output the PR URL and a one- or two-line summary of what was accomplished (state whether the PR was published, left a draft, or whether `gh pr ready` failed).
