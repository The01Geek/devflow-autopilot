## Phase 4: Documentation

Output: `Phase 4/4: Documentation — updating docs and finalizing PR...`

`workpad.py update $ISSUE_NUMBER --status Documenting`.

### 4.0 File Follow-Up Issues for Deferred Work

If Phase 2.2.5's scope-adjustment rule deferred any acceptance criteria, file a follow-up GitHub issue capturing them now. Skip this step if no criteria were deferred.

For each logical chunk of deferred work (typically: one issue per remaining "phase" in a phased cleanup), create a GitHub issue. If multiple follow-up issues are needed, issue all `gh issue create` calls in a single assistant turn so they run in parallel, and append a single combined note (`--note`) afterward (do not PATCH the workpad between each `gh issue create`).

**Body format — follow the create-issue template.** Build each follow-up issue body to the section structure and writing discipline of `skills/create-issue/references/issue-template.md` (the same format authority `/devflow:create-issue` uses), so an implement-generated follow-up reads like every other devflow-authored issue rather than a two-section stub. Specifically:

- **Sections, in this order:** `## Problem Statement`, `## Current Behavior`, `## Desired Behavior`, `## User Impact`, `## Technical Context`, `## Acceptance Criteria`, `## Implementation Notes`. (The template groups the first four — Problem Statement / Current Behavior / Desired Behavior / User Impact — as bullets under a single Description heading; flatten them to top-level `##` sections here, matching how parent issues are written.) Populate them from the parent issue and the workpad's 2.2.5 scope-decision note: the scope decision and the parent's framing → Problem Statement / Current Behavior / Desired Behavior / User Impact; the parent's relevant classes/files, architecture alignment, and cross-layer impact → Technical Context; the verbatim deferred criteria → Acceptance Criteria; the parent issue cross-reference threads through Problem Statement and Technical Context. (Technical Context and Implementation Notes carry a deliberate subset of the template's sub-bullets — the ones an implement-generated follow-up needs — rather than the full set; the template's Dependencies, Data/Schema Considerations, Testing Strategy, and Documentation Needed bullets are intentionally omitted.)
- **Acceptance Criteria are carried verbatim.** The deferred criteria were already-decided acceptance criteria on the parent issue — reproduce them exactly under `## Acceptance Criteria` as `- [ ]` checkboxes, preserving the 2.2.5 verbatim-preservation guarantee. Do not reword, split, or merge them.
- **No-options rule applies.** Observe the template's no-options discipline — no choice / hedge / deferral language (no "or", "could", "consider", "TBD", "for now", "(optional)") anywhere in the body. The deferred criteria are resolved decisions, so the gate is satisfied by construction; do not reintroduce hedging when describing the deferred scope.
- **Autonomous-run adaptation.** Phase 4.0 runs inside an autonomous /devflow:implement execution with no user present, so the template's *interactive* elements do not apply: there is **no clarification round** and **no `## 🚫 Blocked` section** — the deferred criteria are already-decided acceptance criteria, so nothing is unresolved. Build the body inline here; do **not** invoke the full interactive `/devflow:create-issue` pipeline.
- **GitHub autolink hygiene.** Applies to the follow-up issue body too — see *GitHub autolink hygiene* in the Workpad Reference.
- **Posting rules.** Pass the body via a quoted-heredoc on stdin (`--body "$(cat <<'EOF' … EOF)"`) so backticks and `$` in the markdown are not expanded, and add **no** `--label` on the `gh issue create` call itself — the configured `deferred.labels` are applied best-effort *after* creation (see *Apply the deferred-issue labels* below), mirroring the post-creation label-apply idiom Phase 3.1 uses for the `DevFlow` provenance label and Phase 4.1 uses for `docs.labels`. Do **not** switch to `--body-file`. (This posting command is a deliberate, small departure from the template's own *example*, which pipes the body through `--body-file -`; only the body's section structure and writing discipline follow the template, not its exact posting command — the quoted-heredoc form keeps the no-expansion guarantee either way.)

```bash
gh issue create \
  --title "<short descriptive title — e.g. 'Phase N of <parent topic>'>" \
  --body "$(cat <<'EOF'
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

## Acceptance Criteria
- [ ] {deferred criterion verbatim}
- [ ] {deferred criterion verbatim}
…

## Implementation Notes
- **Approach** — <the decided design for this chunk, drawn from the parent's plan.>
- **Code Patterns** — <patterns in this codebase to mirror.>
- **Potential Gotchas** — <constraints or pitfalls carried from the parent issue.>
EOF
)"
```

**Apply the deferred-issue labels.** As you create each follow-up issue above, **capture its number** from the `gh issue create` output (the command prints the new issue URL; the trailing path segment is the number) into `DEFERRED_ISSUE_NUMBERS` — a space-separated list you assemble from the issues you actually filed (e.g. `DEFERRED_ISSUE_NUMBERS="201 202"`). Then apply the configured `deferred.labels` to every filed issue. The labels are read from config (default `DevFlow,Deferred`) and normalized with the **same** split/trim/drop-empties idiom Phase 4.1 uses for `docs.labels`, so an empty or whitespace-only value applies no labels. Ensure each label exists first (best-effort), then apply them through the shared REST `apply-labels.sh` helper (`POST .../issues/{n}/labels` — repo-scope only, unlike `gh issue edit --add-label`'s org-scoped GraphQL resolution) per filed issue — best-effort and post-creation, so a label hiccup can never block or unwind the filing:

```bash
# Assemble this from the issue numbers you captured above (the gh issue create
# outputs). It is NOT auto-populated — set it explicitly, e.g.:
#   DEFERRED_ISSUE_NUMBERS="201 202"
DEFERRED_ISSUE_NUMBERS="${DEFERRED_ISSUE_NUMBERS:-}"
# Capture config-get's rc so a real read failure (corrupt config.json / missing python3 →
# exit 2 with empty stdout) is NOT silently indistinguishable from a deliberately-empty
# value: both yield an empty CLEAN below, but only the failure leaves a breadcrumb. The
# default arg covers the soft paths (missing file / unset key); rc≠0 is the hard path.
# The assignment runs as an `if` condition so the rc capture survives even if these
# blocks are ever executed under `set -e` (a bare `VAR=$(cmd); RC=$?` would abort at the
# assignment before the capture; an `if`-condition assignment is exempt from `set -e`).
if DEFERRED_LABELS=$(${CLAUDE_SKILL_DIR}/../../scripts/config-get.sh .deferred.labels DevFlow,Deferred); then DEFERRED_LABELS_RC=0; else DEFERRED_LABELS_RC=$?; fi
[ "$DEFERRED_LABELS_RC" -eq 0 ] || workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.0 could not read deferred.labels (config-get rc=$DEFERRED_LABELS_RC — corrupt config.json or python3 missing); deferred follow-up issues filed WITHOUT labels."
CLEAN_DEFERRED_LABELS=$(echo "$DEFERRED_LABELS" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | paste -sd, -)
if [ -z "$DEFERRED_ISSUE_NUMBERS" ]; then
  # We only reach this block because deferred work WAS filed above, so an empty list
  # means the issue-number capture was missed — a real gap, not a benign no-op. Route it
  # to the workpad (durable, retrospective-visible) like the rc-failure breadcrumb, not
  # just stderr (ephemeral in an autonomous cloud run).
  echo "devflow: Phase 4.0 captured no deferred-issue numbers — deferred.labels applied to nothing (check the gh issue create captures)" >&2
  workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.0 filed deferred follow-up issues but captured no issue numbers — the configured deferred labels were applied to NONE of them; the filed issues carry none of the configured deferred labels."
elif [ -n "$CLEAN_DEFERRED_LABELS" ]; then
  # Ensure each configured label exists (best-effort; ensure-label.sh always exits 0, so
  # this loop never aborts on a label that can't be created). `|| continue` just skips a
  # blank entry; CLEAN already drops blanks, so it is belt-and-suspenders kept symmetric
  # with the apply loop below. (These blocks run as ordinary Bash-tool invocations, not
  # under `set -e` — the best-effort idiom matches the pre-existing docs.labels block.)
  echo "$CLEAN_DEFERRED_LABELS" | tr ',' '\n' | while IFS= read -r lbl; do
    [ -n "$lbl" ] || continue
    ${CLAUDE_SKILL_DIR}/../../scripts/ensure-label.sh "$lbl"
  done
  # Apply to every issue filed above (the numbers captured into DEFERRED_ISSUE_NUMBERS)
  # through the shared REST label-apply helper (POST .../issues/{n}/labels — repo-scope
  # only; `gh issue edit --add-label` resolves the repo via org-scoped GraphQL and fails
  # under a repo-scoped token). The helper is best-effort (always exits 0) and emits a
  # specific breadcrumb to stderr ONLY on failure, so capture that stderr: a failed apply
  # is the feature's most likely real-world failure, so route it to the durable workpad
  # (retrospective-visible) as well as stderr — stderr is ephemeral in an autonomous cloud
  # run, so a stderr-only breadcrumb would leave an unlabeled issue with no durable trace.
  for n in $DEFERRED_ISSUE_NUMBERS; do
    LBL_ERR="$(${CLAUDE_SKILL_DIR}/../../scripts/apply-labels.sh "$n" "$CLEAN_DEFERRED_LABELS" 2>&1)"
    [ -n "$LBL_ERR" ] && { echo "$LBL_ERR" >&2; \
      workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.0 could not apply the configured deferred labels ($CLEAN_DEFERRED_LABELS) to issue #$n (best-effort; the issue was filed but carries none of the configured deferred labels)."; }
  done
fi
```

Record the new issue numbers in the workpad: `workpad.py update $ISSUE_NUMBER --note "Filed follow-up issues for deferred work: #N (phase 2), #N+1 (phase 3), …"` before continuing to 4.0.5.

### 4.0.5 File Follow-Up Issues for Deferred Review Findings

If Phase 3.3's /devflow:review-and-fix run emitted a deferrals manifest, file follow-up GitHub issues for those findings now and update the manifest in place with the assigned issue numbers + deterministic deferral IDs. Phase 4.2's /pr-description run will then surface them in the PR body as a Scope-Acknowledged Findings block that /devflow:review's verdict matcher honors.

**Manifests are run-scoped** (`.devflow/tmp/review/<slug>/<run-id>/deferrals.json` — see that skill's "Pre-mapping: Widens-surface guard + deferrals manifest" section for what's in it). A single /devflow:implement run can produce **two** of them: Phase 3.3's first /devflow:review-and-fix run and its bounded re-review both run on the same PR with distinct run-ids. Reading one fixed path would miss the other run's deferrals (issue #68 F1, acceptance criterion 3). So **merge every run-scoped manifest into one slug-level aggregate** before filing, then file from the aggregate. The aggregate is the single path /pr-description reads in Phase 4.2.

Skip this step if no run-scoped manifest exists or all are empty.

```bash
PR_NUMBER=$(gh pr view --json number --jq '.number')
SLUG_DIR=".devflow/tmp/review/pr-${PR_NUMBER}"
AGG="${SLUG_DIR}/deferrals.json"   # slug-level aggregate the consumers read; distinct from the per-run files
# run-id and slug are path-safe (alphanumeric/hyphen/dot), so the unquoted find-output
# word-split below is safe. -size +0c skips empty manifests.
MANIFESTS=$(find "$SLUG_DIR" -mindepth 2 -maxdepth 2 -name deferrals.json -size +0c 2>/dev/null | sort)
if [ -n "$MANIFESTS" ]; then
    # Merge the deferrals[] arrays across runs. The dedup key mirrors file-deferrals.py's
    # _compute_id payload — (file|symbol|kind|summary.strip()), every field defaulted to ""
    # — so a finding deferred in both runs collapses to one row, is filed once, and a null
    # field never errors the string concat. Header fields come from the first input.
    # Idempotent re-runs: feed any prior hydrated aggregate FIRST so its `follow_up` entries
    # win the dedup (unique_by keeps the first occurrence); otherwise a re-run rebuilds $AGG
    # from the raw run-scoped manifests (which never carry follow_up), wiping the prior
    # hydration so file-deferrals.py re-files duplicates. Write via temp so reading $AGG is safe.
    # (file-deferrals.py refuses any manifest where *some* entry is already hydrated, so on a
    # re-run this prevents duplicate filing but does not incrementally file newly-added
    # deferrals — that all-or-nothing is the helper's existing guard, handled benignly below.)
    PRIOR=""; [ -s "$AGG" ] && PRIOR="$AGG"
    if jq -s '.[0] as $f | {schema_version:$f.schema_version, pr_branch:$f.pr_branch, base_branch:$f.base_branch, generated_at:$f.generated_at,
        deferrals: ([.[].deferrals[]] | unique_by((.file // "") + "|" + (.symbol // "") + "|" + (.kind // "") + "|" + ((.summary // "") | gsub("^\\s+|\\s+$";"")))) }' \
        $PRIOR $MANIFESTS > "${AGG}.tmp"; then
        mv "${AGG}.tmp" "$AGG"
    else
        # jq failed (malformed manifest, schema drift): keep any prior hydrated $AGG
        # intact, do NOT file from a half-merged temp, and surface the gap rather than
        # silently falling through to the filing guard with a stale aggregate.
        rm -f "${AGG}.tmp"
        workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.0.5 deferrals merge (jq) failed over: ${MANIFESTS}; deferrals NOT filed this run — inspect the run-scoped manifests."
        AGG=""   # make the filing guard below unambiguously false
    fi
fi
if [ -n "$AGG" ] && [ -s "$AGG" ]; then
    # Capture rc so file-deferrals.py's exit codes aren't discarded: 0 = filed; exit 2
    # with "already has follow_up" is the benign idempotent-re-run case (the prior
    # aggregate is still hydrated and /pr-description reads it fine) — not a failure.
    FILED_OUT=$(${CLAUDE_SKILL_DIR}/../../scripts/file-deferrals.py \
        --source-issue $ARGUMENTS \
        --pr "$PR_NUMBER" \
        --manifest "$AGG" 2>/tmp/devflow-fd.err); FD_RC=$?
    if [ "$FD_RC" -eq 0 ]; then
        FILED_NUMBERS="$FILED_OUT"
        # file-deferrals.py exits 0 even on PARTIAL success: a per-file group whose
        # `gh issue create` failed is dropped from the manifest, yet the helper still
        # exits 0. Surface that so the dropped findings (which won't reach the PR's
        # Scope-Acknowledged block) leave a breadcrumb instead of vanishing silently.
        grep -q 'were dropped from manifest' /tmp/devflow-fd.err && \
            workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "file-deferrals.py filed partially (rc=0): $(cat /tmp/devflow-fd.err); dropped groups will NOT appear in the PR's Scope-Acknowledged Findings block."
    elif grep -q 'already has follow_up' /tmp/devflow-fd.err; then
        workpad.py update $ISSUE_NUMBER --note "Deferrals already filed on a prior run (idempotent re-run) — nothing new to file; the hydrated aggregate stands."
    elif grep -q 'no deferrals' /tmp/devflow-fd.err; then
        workpad.py update $ISSUE_NUMBER --note "Aggregate held no deferrals to file — nothing to do."
    else
        workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "file-deferrals.py failed (rc=${FD_RC}): $(cat /tmp/devflow-fd.err); no follow-up issues filed this run."
    fi
fi
```

The helper groups manifest entries by `file` (one issue per source file), files each issue with a repo-agnostic title/body template (`<area>: deferred review findings in <file> (carried from #<source_issue>)` and a body containing the verbatim findings plus the `PR #<pr_number>` substring that the verdict matcher's mutual-cross-link guard validates against), then rewrites the manifest in place with `id: dfr-<6-hex>` (deterministic hash of `file + symbol + kind + summary`) and `follow_up: {issue, url, filed_at, filed_by}` populated per entry. Filed issue numbers are printed to stdout, one per line.

Failure mode: if `gh issue create` fails for a particular file-group, that group's entries are dropped from the manifest entirely — no fake deferral can downgrade a future review. The helper exits 0 as long as at least one group succeeded. Capture stderr in your `Devflow Reflection` notes if anything was dropped.

Record the filed issue numbers in the workpad:

```bash
if [ -n "${FILED_NUMBERS:-}" ]; then
    NUMBERS_CSV=$(echo "$FILED_NUMBERS" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, #/g')
    workpad.py update $ISSUE_NUMBER --note "Filed follow-up issues for deferred review findings: #${NUMBERS_CSV}"
    # Apply the configured deferred.labels to each filed issue — same resolve/normalize/
    # ensure/apply idiom as Phase 4.0 (default DevFlow,Deferred; empty/whitespace → none).
    # `file-deferrals.py` itself stays out of config-reading (config is resolver
    # territory — read through config-get.sh, not re-parsed ad hoc); the skill owns
    # labeling. Best-effort and post-filing, so a label hiccup never unwinds an
    # already-filed issue.
    # Capture config-get's rc (same as Phase 4.0): a hard read failure (corrupt
    # config.json / missing python3 → exit 2, empty stdout) yields an empty CLEAN that is
    # otherwise indistinguishable from a deliberately-empty value — leave a breadcrumb so
    # the unlabeled outcome is attributable, not silent. The default arg covers the soft
    # paths (missing file / unset key); rc≠0 is the hard path. The `if`-condition form
    # keeps the rc capture alive even under `set -e` (a bare `VAR=$(cmd); RC=$?` aborts at
    # the assignment; an `if`-condition assignment is exempt).
    if DEFERRED_LABELS=$(${CLAUDE_SKILL_DIR}/../../scripts/config-get.sh .deferred.labels DevFlow,Deferred); then DEFERRED_LABELS_RC=0; else DEFERRED_LABELS_RC=$?; fi
    [ "$DEFERRED_LABELS_RC" -eq 0 ] || workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.0.5 could not read deferred.labels (config-get rc=$DEFERRED_LABELS_RC — corrupt config.json or python3 missing); deferred review-finding issues filed WITHOUT labels."
    CLEAN_DEFERRED_LABELS=$(echo "$DEFERRED_LABELS" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | paste -sd, -)
    if [ -n "$CLEAN_DEFERRED_LABELS" ]; then
        # `|| continue` just skips a blank entry (CLEAN already drops blanks — symmetric
        # with Phase 4.0); ensure-label.sh always exits 0, so the loop never aborts.
        echo "$CLEAN_DEFERRED_LABELS" | tr ',' '\n' | while IFS= read -r lbl; do
            [ -n "$lbl" ] || continue
            ${CLAUDE_SKILL_DIR}/../../scripts/ensure-label.sh "$lbl"
        done
        # Apply via the shared REST label-apply helper (POST .../issues/{n}/labels — repo-scope
        # only; `gh issue edit --add-label` resolves the repo via org-scoped GraphQL and fails
        # under a repo-scoped token). The helper is best-effort (always exits 0) and emits a
        # breadcrumb to stderr ONLY on failure, so capture that stderr and route it to the
        # durable workpad as well (same as Phase 4.0): the unlabeled outcome is the feature's
        # most likely failure and stderr is ephemeral in an autonomous cloud run, so a
        # stderr-only breadcrumb would leave no retrospective-visible trace. `|| continue`
        # skips a blank line (this piped-`while` reads blank lines that Phase 4.0's `for`
        # would word-split away); the per-issue failure is caught best-effort so the loop completes.
        echo "$FILED_NUMBERS" | while IFS= read -r n; do
            [ -n "$n" ] || continue
            LBL_ERR="$(${CLAUDE_SKILL_DIR}/../../scripts/apply-labels.sh "$n" "$CLEAN_DEFERRED_LABELS" 2>&1)"
            [ -n "$LBL_ERR" ] && { echo "$LBL_ERR" >&2; \
                workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.0.5 could not apply the configured deferred labels ($CLEAN_DEFERRED_LABELS) to issue #$n (best-effort; the issue was filed but carries none of the configured deferred labels)."; }
        done
    fi
fi
```

The rc handling above distinguishes three cases: a clean filing (rc 0), the benign idempotent-re-run (`exit 2` with "already has follow_up" — the prior aggregate is still hydrated, `/pr-description` reads it fine, recorded as a plain note), and a genuine failure (any other non-zero — every `gh issue create` group failed, or an unusable/corrupt manifest), which lands a `Devflow Reflection` breadcrumb. On a genuine failure continue to 4.1 anyway — the PR can still ship; it just won't carry the Scope-Acknowledged Findings block, so `/devflow:review` will treat any deferred findings as new.

### 4.1 Update Documentation

**The routine doc pass always runs — narrative never suppresses it.** A narrative claim that documentation is unnecessary — including an **absent, empty, or contradictory** `**Documentation Needed**` bullet — **never** suppresses the routine documentation pass: the `devflow:docs` subagent still runs and updates the documentation warranted by the shipped behavior change. The `**Documentation Needed**` bullet is an **additive floor** of mandatory deliverables (it can only *add* required files), **never a ceiling that authorizes skipping otherwise-warranted documentation**. This mirrors the §2.1 authority hierarchy — the Implementation Notes narrative, `Documentation Needed` included, is a non-authoritative starting point, so it can never narrow or suppress the doc work the shipped diff warrants. The deterministic two-stage gate below is **unchanged in behavior**: it enforces the floor (every named deliverable must ship); it does not decide whether the doc pass runs.

**Stage 1 — Pre-flight briefing (before dispatch).** Extract the issue's required documentation deliverables **deterministically — do not interpret the prose yourself.** Run the bundled helper, which scopes to the `**Documentation Needed**` bullet under `## Implementation Notes` and emits the recognizable file paths one per line:

```bash
ISSUE_BODY=$(gh issue view $ISSUE_NUMBER --json body --jq '.body'); GH_RC=$?
DOC_NEEDED_PATHS=$(printf '%s' "$ISSUE_BODY" \
  | ${CLAUDE_SKILL_DIR}/../../scripts/extract-doc-needed-paths.sh); HELPER_RC=$?
```

**Read `GH_RC`/`HELPER_RC`, never stdout emptiness, as the failure signal.** A non-zero `GH_RC` (auth, network, rate-limit, or a wrong issue number) or a non-zero `HELPER_RC` (the extractor's own token scan failed) is a *command failure* that says nothing about which paths the issue names — **never treat its empty stdout as a no-op**, the way an empty `DOC_NEEDED_PATHS` would be treated below. That is the exact fail-open this gate exists to close, moved one stage upstream. Retry the read once; if it still fails, fail closed — route to the Blocked path (`workpad.py update $ISSUE_NUMBER --status Blocked --reflection-kind dropped-failed --reflection "Phase 4.1: could not read the issue body to extract Documentation Needed deliverables (gh/extractor command failure); the deliverable cross-check could not run — retry when GitHub is reachable"`), emit the 👎 outcome reaction, and stop. Only an rc-0 read with empty `DOC_NEEDED_PATHS` is the legitimate empty signal handled below.

These paths are the required deliverables. Stage 2 re-runs the **same helper** rather than re-deriving them, so the two passes can never disagree about which files were named. If `DOC_NEEDED_PATHS` is empty (the bullet is absent, names no file paths, or holds only non-path prose), Stage 1 is a no-op and the subagent is dispatched with its normal instruction unchanged. If the helper emits nothing **but** the issue body still contains a `**Documentation Needed**` bullet (`gh issue view $ISSUE_NUMBER --json body --jq '.body' | grep -q '\*\*Documentation Needed\*\*'`), record a workpad note (`workpad.py update $ISSUE_NUMBER --note "Phase 4.1: **Documentation Needed** bullet present but the extractor found no file paths; the deliverable cross-check is skipped this run"`) so the skipped enforcement is auditable.

Spawn a **subagent** (using the Agent tool) and instruct it to invoke the `devflow:docs` skill. Compose the dispatch instruction: begin with "Invoke the `devflow:docs` skill to update all documentation (internal docs, external docs, release notes). The issue context is provided for release notes generation." If `DOC_NEEDED_PATHS` is non-empty, append: " The issue requires the following files to be updated; treat each as a mandatory deliverable: `<path1>`, `<path2>`, …" Send this composed instruction along with the issue title, body, and number to the subagent.

After the subagent completes, commit any documentation changes. Read the docs paths from `.devflow/config.json`:

```bash
DOCS_INTERNAL=$(${CLAUDE_SKILL_DIR}/../../scripts/config-get.sh .docs.internal docs/internal/)
DOCS_EXTERNAL=$(${CLAUDE_SKILL_DIR}/../../scripts/config-get.sh .docs.external docs/external/)
git status -- "$DOCS_INTERNAL" "$DOCS_EXTERNAL"
```

If there are changes:
```bash
git add "$DOCS_INTERNAL" "$DOCS_EXTERNAL"
git commit -m "docs: update documentation for issue #$ARGUMENTS"
git push
```

Then decide whether the docs pass succeeded: it succeeded if the docs subagent actually ran — either it produced changes (committed above) or it returned cleanly with no changes needed. If instead the docs subagent failed, returned no useful output, or was unable to run, that is actionable: add a `--reflection-kind dropped-failed --reflection "…"` bullet to the workpad and do **not** apply the post-docs labels at all (now or later). The post-docs labels signal "the docs pass ran and was reviewed", but they are **not** applied here — application is deferred to the end of Stage 2 so that a PR which routes to Blocked for an undelivered deliverable never carries them (the label resolution is shown there). (Downstream docs automation, if the adopter runs any, can key off these labels to avoid double-processing the PR.)

**Stage 2 — Post-hoc diff gate (mandatory when Stage 1 found named paths).** After the docs-subagent commit and before ticking `Documentation`, verify that every required-deliverable path has been touched. Re-run the **same deterministic helper** as Stage 1 — re-running the helper is the single source of truth; do not rely on remembered Stage 1 output:

```bash
ISSUE_BODY=$(gh issue view $ISSUE_NUMBER --json body --jq '.body'); GH_RC=$?
DOC_NEEDED_PATHS=$(printf '%s' "$ISSUE_BODY" \
  | ${CLAUDE_SKILL_DIR}/../../scripts/extract-doc-needed-paths.sh); HELPER_RC=$?
```

**Read `GH_RC`/`HELPER_RC`, never stdout emptiness, as the failure signal** — symmetric to the diff side below. A non-zero `GH_RC` (auth, network, rate-limit, or a wrong issue number) or a non-zero `HELPER_RC` (the extractor's own token scan failed) is a *command failure* that says nothing about which paths the issue names — **never treat its empty stdout as a no-op** (the step-1 escape hatch below), which would silently wave the gate through exactly when the deliverable list could not be read. Retry the read once; if it still fails, fail closed — route to the Blocked path (`workpad.py update $ISSUE_NUMBER --status Blocked --reflection-kind dropped-failed --reflection "Phase 4.1: could not read the issue body to extract Documentation Needed deliverables (gh/extractor command failure); the deliverable cross-check could not run — retry when GitHub is reachable"`), emit the 👎 outcome reaction, and stop. Only an rc-0 read with empty `DOC_NEEDED_PATHS` is the legitimate empty signal step 1 treats as a no-op.

1. **No-op when empty.** If `DOC_NEEDED_PATHS` is empty, this cross-check is a no-op — proceed directly to the post-docs-labels + `--tick-progress "Documentation"` step below.

2. **Compute the diff once; fail closed on a broken command.** Verify `$BASE` is non-empty; if empty, re-derive it exactly as Phase 1.4 does, **applying its non-empty fallback and not just the config read** — the read alone returns nothing on malformed config and would otherwise leave `$BASE` empty, collapsing the range to `origin/...HEAD` and judging every path absent. Capture the cumulative diff **and its exit status**:
   ```bash
   DIFF_OUT=$(git diff --name-only "origin/$BASE...HEAD"); DIFF_RC=$?
   ```
   Read the exit status, **never** stdout emptiness, as the failure signal. A non-zero `DIFF_RC` (or `origin/$BASE` not present locally) is a *command failure* that says nothing about any path: re-fetch the base branch as Phase 1.4 does and retry once. If the re-fetch itself fails (offline / auth / wrong trunk), do not guess — route to the Blocked path / `--reflection-kind dropped-failed` and stop; **never fall through to a path-absent verdict on a broken command.** Conversely, **an rc-0 result with empty stdout is NOT a failure** — it is the legitimate signal that the diff touched none of these files (the genuine absence the gate exists to catch); treat it as real and continue to the per-path check. For each path in `DOC_NEEDED_PATHS`, decide satisfied vs absent against `DIFF_OUT`: if it is a bare filename (contains no `/`), any diff entry whose basename matches it counts as satisfied (e.g. the diff entry `docs/DEVFLOW_SYSTEM_OVERVIEW.md` satisfies the named path `DEVFLOW_SYSTEM_OVERVIEW.md`); if it contains a `/`, it must appear as an exact match in `DIFF_OUT`.

3. **Self-heal or block for each absent path.** For each named path absent from the diff, perform the missing update when you can: if the correct update can be derived from the issue body's `**Documentation Needed**` prose, perform the missing update yourself, record a workpad note (`workpad.py update $ISSUE_NUMBER --note "Phase 4.1 self-heal: <path> absent from diff; performed update from Documentation Needed prose"`), commit (`docs:` prefix), and push. **Then re-verify the self-heal landed and reached the remote:** confirm the commit and push both succeeded *and* that the local branch is in sync with its upstream — `git rev-parse HEAD` must equal `git rev-parse @{u}` (a no-op `Everything up-to-date` push or a rejected non-fast-forward leaves them unequal, so a re-diff of the still-local commit would falsely satisfy the gate) — then re-run the helper-driven diff check for that path. A non-zero rc on commit/push, an upstream that does not match HEAD, or the path still absent from the re-checked diff all mean the self-heal did not land. Only a path now present in the re-checked diff **and** whose commit and push both reached the remote counts as satisfied. If the correct update cannot be derived from context (the prose is insufficient), **or** the self-heal did not land per the re-check, do not tick `Documentation` — route to the Blocked path: `workpad.py update $ISSUE_NUMBER --status Blocked --reflection-kind blocked --reflection "Phase 4.1: Documentation Needed file content cannot be determined for <path> — the docs subagent did not update this file and the correct content cannot be derived from the issue body; update manually and re-run Phase 4.1"`, then emit the 👎 outcome reaction (see *Outcome reaction* in the Workpad Reference) and stop.

Once every named path is satisfied (or Stage 1 found no paths), apply the deferred post-docs labels — only when the docs pass succeeded per the Stage-1 decision above; a run that routed to Blocked never reaches this point, so a Blocked PR never carries them. `docs.labels` is a comma-separated list (default `Documented`); normalize it (split on commas, trim each entry, drop empties) and apply through the shared REST label-apply helper (a PR is an issue, so `POST .../issues/{n}/labels` serves it — repo-scope only, unlike `gh pr edit --add-label`'s org-scoped GraphQL resolution). The REST path needs the PR number explicitly, so resolve it first from the current branch:

```bash
DOCS_LABELS=$(${CLAUDE_SKILL_DIR}/../../scripts/config-get.sh .docs.labels Documented)
CLEAN_LABELS=$(echo "$DOCS_LABELS" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | paste -sd, -)
DOCS_PR_NUM=$(gh pr view --json number --jq '.number')
# The REST endpoint needs the PR number, which the old `gh pr edit` form resolved
# implicitly — so an empty $DOCS_PR_NUM (gh error / warning-corrupted output) is a NEW
# failure point the migration introduced. Don't let it skip the apply silently and then
# tick Documentation complete: route it to the durable workpad (same discipline the 4.0/
# 4.0.5 deferral channels use, since stderr is ephemeral in an autonomous cloud run).
if [ -n "$CLEAN_LABELS" ]; then
  if [ -n "$DOCS_PR_NUM" ]; then
    ${CLAUDE_SKILL_DIR}/../../scripts/apply-labels.sh "$DOCS_PR_NUM" "$CLEAN_LABELS"
  else
    echo "devflow: Phase 4.1 could not resolve the PR number (gh pr view returned empty); docs labels ($CLEAN_LABELS) NOT applied" >&2
    workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "Phase 4.1 could not resolve the PR number to apply docs labels ($CLEAN_LABELS); the PR carries none of the configured docs labels."
  fi
fi
```

Then tick the Documentation phase in the workpad: `workpad.py update $ISSUE_NUMBER --tick-progress "Documentation"`.

**Re-anchor before §4.2 (mandatory, after the Phase 4.1 `devflow:docs` subagent returns and its docs are committed).** Phase 4.1 above dispatched a context-isolated `devflow:docs` subagent (Stage 1/Stage 2); a long subagent return can evict this phase file from your working set, which is exactly how a run stops at "documentation done" before reaching §4.2/§4.3. So now that the docs subagent has returned and its docs are committed, before proceeding to §4.2, **`Read` `${CLAUDE_SKILL_DIR}/phases/phase-4-documentation.md` again and follow it exactly** — re-anchoring the remaining §4.2 (PR description) and §4.3 (finalize) procedure, never relying on the earlier entry-gate read. This re-anchor is scoped to the Phase 4.1 docs subagent return **only** — do not apply it to the Phase 2 or Phase 3 subagent returns, whose phases carry their own entry-gate reads.

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

**Publish decision — `implement_pr_state`.** Whether the run publishes the PR or leaves it the draft created in Phase 3.1 is a per-consumer config choice. Read it (default `ready_for_review`), then publish **only** when it is not the exact literal `draft` — default-to-publish is the safe direction, so a missing key, empty string, or any unrecognized value publishes, and a hard read failure (malformed config) falls back to publishing. **Capture whether `gh pr ready` actually succeeded** so the finalize wording reflects the *real* end state — a bare `gh pr ready` whose failure (the `else` arm catches *any* non-zero exit — e.g. auth scope, GitHub 5xx, rate limit, a race that already merged/closed the PR) fell through would otherwise leave the workpad falsely claiming the PR was published when it is still a draft:

```bash
PR_STATE=$(${CLAUDE_SKILL_DIR}/../../scripts/config-get.sh .devflow_implement.implement_pr_state ready_for_review) || PR_STATE=ready_for_review
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
workpad.py update $ISSUE_NUMBER \
    --status Complete \
    --tick-progress "PR marked ready" \
    --note "{PR_OUTCOME-specific note above}" \
    [--reflection-kind note --reflection "{noteworthy event}" ...repeat --reflection per event]
# Check the exit code of the finalize update above (per the failure-isolation
# contract): exit 0 means the "PR marked ready" box is now `- [x]` and the run is
# Complete; a non-zero exit means the tick missed (label drift / already ticked on a
# resumed run) — re-resolve and re-tick the row before treating the run as done.
```

Add one `--reflection` flag per noteworthy event a human should know for troubleshooting: a failed step that was skipped, a subagent that returned no useful output, a permission denial, a test you couldn't run, an ambiguity you resolved with an assumption, or any deviation from the planned flow. These are the *informational* `note` kind (`--reflection-kind note`); genuinely actionable failures (a dropped manifest entry, a publish failure) are emitted at the point they occur with `--reflection-kind dropped-failed` so they land under `### ⚠️ Action required`. `--reflection` is repeatable so all the note-kind events land in a single atomic update. (No separate "Notes from /devflow:implement run" comment is posted — the workpad replaces it.)

Finally, emit the 🎉 outcome reaction on the triggering comment (`REACTION=hooray`; see *Outcome reaction* in the Workpad Reference) — the implement lifecycle completed regardless of the publish decision (`draft`, `published`, or `publish_failed`; the publish failure is surfaced via the `--reflection` above, not by suppressing the reaction) — then output the PR URL and a one- or two-line summary of what was accomplished (state whether the PR was published, left a draft, or whether `gh pr ready` failed).
