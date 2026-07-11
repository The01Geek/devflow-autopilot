# Durable fix for cloud-review no-verdict stalls caused by permission-denial burn

**Date:** 2026-07-10
**Evidence base:** Devflow Review run [29105381021](https://github.com/The01Geek/devflow-autopilot/actions/runs/29105381021) on PR #397 (22 denials, engine ended mid-Phase-3, no verdict, required check failed "incomplete — re-run needed"). Prior approving run 29100342503 on the same PR recorded 13 denials — the friction is chronic; this run crossed the threshold where the engine gave up. Same failure mode previously: PR #340 (7 of 14 denials were the engine trying to run the test suite; led to issue #363).

## Problem

The cloud review engine stalls with no verdict when it burns its run on commands the
read-only `review` tool profile silently denies. Three distinct defect layers:

1. **The skill teaches denied shapes.** `skills/review/SKILL.md` Phase 0.3.5 instructs
   `MARKER="…"` / `RUN_URL="…"` assignments followed by `printf … > /tmp/review-wp.md`
   and `cat >> /tmp/review-wp.md <<'EOF'`, and its inline comment *claims* these are
   granted. In run 29105381021 exactly those composites were denied (4–6 of the 22).
   The issue-#363 guard (`lib/test/extract-command-heads.py`) validates command
   *heads*, not composite *shapes* (leading assignments, multi-statement blocks,
   heredocs), so it stayed green.
2. **Engine-improvised shapes have nowhere legal to go.** Verifying PR #397's long
   pin literals pushed the engine into `cd`-led compounds, assignment-led loops,
   `python3` helper scripts, and `Write`-tool temp files — every formulation denied,
   ~6 retries of the same check in different shapes.
3. **No shape guidance up front.** The injected grounding block lists the granted
   rules but says nothing about the *shapes* the matcher accepts, so the engine
   iterates denied variants instead of switching to a legal form.

Decisions already made with the maintainer: **targeted profile widening** (no
`python3`, read-only-tree spirit preserved); **no auto-retry backstop** (purely
preventive fix); covers **both** cloud allowlists (auto-review profile in
`devflow-runner.yml` + the hoisted `TOOLS` in `devflow.yml`) plus **grounding-block
discipline**; test-layer meta-guard included at implementer's discretion (it is
included, driven by verified evidence only).

> **Superseded (issue #408):** the "no auto-retry backstop" decision and the
> first non-goal below were **reversed** by issue #408, which added the bounded
> `devflow_review.stall_backstop` no-verdict auto-resume. The transcript evidence
> gathered after this spec showed the residual failure is a benign timing race a
> re-run wins, and the maintainer approved the reversal when scoping #408. This
> record is kept as-is for provenance; see `docs/DEVFLOW_SYSTEM_OVERVIEW.md` for
> the shipped behavior.

## Non-goals

- No auto re-run / session-resume backstop on a no-verdict run. _(Superseded by #408 — see the note above.)_
- No `python3` (or any interpreter) grant in the review profile.
- No unscoped `Write`/`Edit` in the review profile; the reviewer's
  `contents: read` token and read-only-tree posture are unchanged.
- Not fixing the nested-`case` / prose-command scope boundaries of the #363
  head extractor (documented limitations stay as-is).

## Constraint that shapes the rollout

Review runs execute `main`'s workflow copy, vendor the plugin at
`devflow_version` (= `main`), and read `devflow_runner.allowed_tools` from the
**trusted base ref** (a PR must not be able to widen its own reviewer). Therefore
nothing committed to a PR branch changes how that same PR is reviewed. A
config.json-only deployment was considered and rejected: the config append (the `PROVISION_ENV` gate in
`.github/workflows/devflow-runner.yml`) requires `devflow_runner.provision_env: true`,
which would switch every review into build-aware mode and run `setup.install`, scoped `Write(/tmp/**)` only passes the
deny floor through an exact-match gap contrary to the floor's stated intent, and the
largest denial class (assignment-led compounds) is not grant-fixable at all — no
allowlist rule can match a leading `VAR=`; only shape changes fix those.

## Design: two PRs

### PR A — evidence + grants (small, fast-tracked to `main` first)

**A1. Matcher probe workflow** (`.github/workflows/matcher-probe.yml`, permanent):

- Triggers: `workflow_dispatch` plus `pull_request` scoped to its own path (so it
  runs from the branch pre-merge; a same-repo PR has secrets access).
- One `claude-code-action` run on Haiku (~$0.10) whose `--allowed-tools` is the
  review profile **plus the candidate grants** under test, and whose prompt
  instructs one tool call per corpus shape, verbatim, no retries.
- **Measurement is deterministic:** a follow-up step parses the execution file's
  `permission_denials` array and checks side-effect files; the model's self-report
  is never trusted (local probing during design produced a false-DENIED control —
  the real environment is the only authoritative matcher).
- Corpus (from run 29105381021's denial list + candidate fixes):
  1. `cat > /tmp/f <<'EOF'…EOF` (heredoc write, granted head) — observed denied; confirm.
  2. `M=x` assignment-led compound with granted head — observed denied; confirm.
  3. `cd <dir> && grep …` with `Bash(cd:*)` granted — does the grant make the compound pass?
  4. Unexpanded `"${CLAUDE_SKILL_DIR:-…}"/../../scripts/load-prompt-extension.sh …`
     vs `Bash(*/load-prompt-extension.sh:*)` — matcher tolerance of the anchor form.
  5. Repo-relative vendored literal (`.devflow/vendor/devflow/scripts/workpad.py …`) — expected permitted (control).
  6. `tee /tmp/f <<'EOF'` and multi-arg `printf '%s\n' a b c > /tmp/f` — candidate legal write shapes.
  7. `Write` tool with `Write(/tmp/**)` and `Write(.devflow/tmp/**)` rules granted — path-scoped file-tool rules under `--allowed-tools`.
  8. Plainly granted single command (positive control).
- Output: permitted/denied table in the job summary. The table is the *evidence of
  record*: PR A's grants and PR 397's shape rules each cite it. Re-run it whenever
  `claude-code-action` or Claude Code CLI upgrades.

**A2. Targeted profile widening**, keyed to A1's table, in the same PR:

- `devflow-runner.yml` `review` profile: add `Bash(cd:*)`, `Write(/tmp/**)`,
  `Write(.devflow/tmp/**)` (temp scratch only), plus exactly whatever the probe
  proves necessary for the anchor form (nothing speculative).
- `devflow.yml` hoisted `TOOLS`: add `Bash(cd:*)` (it already has full `Write`).
- Same change updates the read-only-profile comment block (it currently reads
  "No Edit/Write" — becomes "no tree-writable Edit/Write; scoped temp-file Write
  only") and any `lib/test/run.sh` pins asserting profile contents, per the
  coupled-invariant rule.
- If a probe row shows a candidate grant does NOT unlock its shape (e.g. `cd`
  compounds stay denied even with `Bash(cd:*)`), that grant is dropped and the
  corresponding shape becomes a PR-397 shape rule instead.

**Merge order:** probe runs from PR A's branch → read table → finalize grants →
merge PR A. From that moment every review run (including PR #397's next re-review)
executes under the new profile.

### PR 397 — shapes, guidance, guards (lands on the existing branch)

**B1. Skill recipe fixes** (`skills/review/SKILL.md`, edited under the
`superpowers:writing-skills` discipline):

- Phase 0.3.5 progress-comment recipe: replace the assignment-led
  `printf`/`cat`-heredoc composite with a probe-verified legal shape — preferred:
  author `/tmp/review-wp.md` via the (now scoped-granted) `Write` tool; fallback if
  the probe disproves scoped Write under `--allowed-tools`: verified `tee` form.
  Delete the false "(cat/printf are granted…)" comment.
- Anchor-form call sites: keep whichever of {unexpanded anchor, reported-base-dir
  literal substitution} the probe proves the matcher accepts, consistently, with the
  #241/#275 portability contract preserved (the recipe must still work on runners
  that only report a base-directory context line).
- New short subsection **"Cloud command-shape discipline"**: single statements; no
  leading `cd` or `VAR=`; granted heads only; author files via Write/tee; never
  `python3` in the review tier; **after two denials of a shape, switch to a listed
  legal alternative — never iterate variants** (caps the budget burn that killed
  run 29105381021).

**B2. Grounding-block shape rules** (`scripts/render-grounding-block.sh`): append a
compact "command shapes" section immediately after the allowed-tools fence, stating
the same rules for *improvised* commands. Rendered once; both workflows inherit it;
no second copy anywhere (same rationale as the existing injection-defense prose).

**B3. Suite guards** (`lib/test/`):

- A fence **shape-lint** beside `extract-command-heads.py` over
  `skills/review/SKILL.md`'s ```bash fences: flags assignment-led statements,
  `cd`-led statements (if A1 disproves the `cd` grant), ungranted heads (existing
  check), and heredoc-write forms proven denied. Rule table entries cite the probe
  run URL. Wired into `lib/test/run.sh`.
- Pins per repo discipline: the new Phase 0.3.5 shape pinned with
  `assert_pin_red_under` (a `sed -E` mutation reintroducing the assignment-led form
  goes RED); the grounding-block section pinned in `run.sh`; both allowlist adds
  pinned in the existing #363 dual-allowlist test.

**B4. Bookkeeping:** changeset (`bump: patch`, prose citing PR #397's postmortem);
PR 397 workpad self-record updated for the scope addition; CLAUDE.md #363 gotcha
extended from "heads" to "shapes" (via `revise-claude-md`); file a separate issue
for the deny-floor exact-match gap (`Write(**)` passes a filter whose intent bans
tree-mutation tools) — out of scope to fix here.

## Verification / observables

1. Probe table on PR A (pre-merge) — every grant and shape rule keys to a row.
2. `lib/test/run.sh` + shape-lint green in PR 397's CI (pre-merge); mutation runs
   recorded RED→GREEN for behavioral pins.
3. After PR A merges: Re-run PR 397's review — `permission_denials_count` published
   by the run drops (target: single digits from grant-fixable classes even before
   B1/B2 deploy).
4. After PR 397 merges: the next DevFlow PR's review run publishes
   `permission_denials_count` at or near 0 with a verdict posted; that run is the
   acceptance evidence for the whole fix.

## Risks and accepted limitations

- Matcher semantics are version-dependent; the permanent probe workflow is the
  mitigation (re-run on upgrades), not frozen assumptions.
- PR 397's reviews *before* PR A merges still run under the old profile and may
  stall again; mitigation is the existing manual Re-run button.
- The shape-lint covers the review skill's fences only (the surface with the
  read-only profile); improvised-command discipline relies on B2's grounding rules,
  which is guidance, not enforcement — residual denials are still possible, just
  bounded by the two-denials-then-switch rule.
- `Write(/tmp/**)` scoping assumes path-scoped file-tool rules work under
  `--allowed-tools` (probe row 7 verifies; fallback is the `tee` shape with no
  Write grant at all).
