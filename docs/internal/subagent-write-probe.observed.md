<!-- Dispatched-subagent Write probe — OBSERVED ARTIFACT (committed evidence) -->

# Dispatched-subagent `Write` probe — observed artifact (issue #858)

Machine-produced output of `scripts/subagent-write-probe-verdict.py`, copied verbatim
from the two `matcher-probe.yml` job step summaries of run `30956039324`
(`anthropics/claude-code-action@v1`, Claude Code 2.1.221, 2026-08-04). This provenance
header is the ONLY addition; everything below each `## Dispatched-subagent Write probe`
heading is the helper's own emitted summary, unedited — including the resolved
`--allowed-tools` literal each job actually ran under.

Committed deliberately, on the same reasoning as
`lib/test/fixtures/execution-file-shape.observed.txt`:
GitHub logs and artifacts expire (~90 days), after which the verdict rows in
`docs/internal/cloud-allowlist.md` would become unfalsifiable — a claim with no surviving evidence.
This file is that evidence. It is redaction-safe by construction: the helper emits no
secret values, and the `--allowed-tools` literal is a generated region already committed
in the tree.

This is a DATED OBSERVATION OF ONE ACTION VERSION AND ONE SUBAGENT DEFINITION (the
built-in `general-purpose` type), not a platform contract. The run carries
`--permission-mode acceptEdits`, so a `PERMITTED` answers "did the dispatched subagent's
`Write` land under that permission mode?" — it does not isolate the allowlist from the
permission mode as the sole reason the write was allowed. Re-probe after any
`claude-code-action` / CLI upgrade and refresh this file and the doc rows together.

Run:       https://github.com/The01Geek/prflow/actions/runs/30956039324
Ref:       issue-1152-command-profile-shape-lint
Head:      85e57ac1c6dcf732a861230f82182191977c6e41
Job (review tier):    92149631372
Job (implement tier): 92149629323

---

## Dispatched-subagent Write probe — review tier (issue #858)

**Verdict: `PERMITTED`**

a subagent Write tool_use targeting subwrite-review.txt was recorded, its parent chains to a dispatch recorded in this file (tool_use id 'toolu_01SbG9oxWxp5PTNS3bbymzD3' -> parent_tool_use_id 'toolu_01Cd3LViMMbQw2surtkyDFGL'), and the on-disk side-effect file carries the probe's payload marker.

Deterministic verdict from the execution file's recorded `tool_use` inputs, their `parent_tool_use_id`, and `permission_denials`, corroborated by the on-disk side-effect file this run actually stat'ed: `.prflow/tmp/subwrite-review.txt`. The model's prose is never the measurement.

> [!IMPORTANT]
> This verdict is a dated observation of one `claude-code-action` version and one subagent definition (the built-in general-purpose type dispatched by the probe's own prompt under the tier's generated baseline at the recorded commit) — not a platform contract, and it establishes nothing for a differently-defined subagent type or a later claude-code-action version. SCOPE: the run carries `--permission-mode acceptEdits`, so a `PERMITTED` answers "did the dispatched subagent's Write land under that permission mode?" — it does not isolate the allowlist from the permission mode as the sole reason the write was allowed. Re-probe (dispatch matcher-probe.yml, or push to a same-repo PR touching it) after a claude-code-action / CLI upgrade before trusting it.

| Field | Value |
|-------|-------|
| tier | `review` |
| verdict | **PERMITTED** |
| dispatch_outcome | recorded |
| recorded_at_all | yes |
| chain_attributable | yes |
| control_before | yes |
| control_after | yes |
| write_outcome | recorded |
| write_chain_ok | yes |
| side_effect_state | corroborated |

**permission_mode:** `acceptEdits`

**model:** `claude-haiku-4-5-20251001`

**effort:** `low`

**ref:** `issue-1152-command-profile-shape-lint`

**head_commit:** `85e57ac1c6dcf732a861230f82182191977c6e41`

**Resolved `--allowed-tools` literal (the measured condition, verbatim):**

```
Read,Glob,Grep,LS,Skill,Agent,TodoWrite,WebFetch,WebSearch,Bash(git status:*),Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(git ls-files:*),Bash(git rev-parse:*),Bash(git merge-base:*),Bash(git blame:*),Bash(git branch:*),Bash(git cat-file:*),Bash(git hash-object:*),Bash(git checkout:*),Bash(mkdir:*),Bash(tee:*),Bash(mktemp:*),Bash(cmp:*),Bash(rm -f:*),Bash(*/load-prompt-extension.sh:*),Bash(gh pr diff:*),Bash(gh pr view:*),Bash(gh pr comment:*),Bash(gh pr list:*),Bash(gh pr checks:*),Bash(gh issue view:*),Bash(gh issue comment:*),Bash(gh issue list:*),Bash(gh search:*),Bash(gh repo view:*),Bash(gh run view:*),Bash(gh run list:*),Bash(gh api:*),Bash(jq:*),Bash(.prflow/vendor/prflow/scripts/run-jq.sh:*),Bash(grep:*),Bash(rg:*),Bash(find:*),Bash(wc:*),Bash(sort:*),Bash(uniq:*),Bash(cut:*),Bash(tr:*),Bash(xargs:*),Bash(awk:*),Bash(sed:*),Bash(diff:*),Bash(comm:*),Bash(cat:*),Bash(head:*),Bash(tail:*),Bash(ls:*),Bash(tree:*),Bash(file:*),Bash(stat:*),Bash(date:*),Bash(pwd:*),Bash(realpath:*),Bash(dirname:*),Bash(basename:*),Bash(which:*),Bash(type:*),Bash(env:*),Bash(echo:*),Bash(printf:*),Bash(test:*),Bash(.prflow/vendor/prflow/scripts/match-deferrals.py:*),Bash(.prflow/vendor/prflow/scripts/match-lint-adjudications.py:*),Bash(.prflow/vendor/prflow/scripts/normalize-verdicts.py:*),Bash(.prflow/vendor/prflow/scripts/dismiss-stale-rejections.sh:*),Bash(.prflow/vendor/prflow/scripts/post-review-verdict.sh:*),Bash(.prflow/vendor/prflow/scripts/workpad.py:*),Bash(.prflow/vendor/prflow/scripts/seed-review-progress.sh:*),Bash(.prflow/vendor/prflow/scripts/config-get.sh:*),Bash(.prflow/vendor/prflow/scripts/load-prompt-extension.sh:*),Bash(.prflow/vendor/prflow/scripts/resolve-review-overrides.py:*),Bash(.prflow/vendor/prflow/scripts/stale-prose-lint.py:*),Bash(.prflow/vendor/prflow/lib/efficiency-trace.sh:*),Write(.prflow/tmp/**),Bash(cd:*),Write(/tmp/**),Bash(scripts/*.sh:*),Task,Agent
```

### Observed `permission_denials` entries (0)

_No permission_denials entries found in the execution file._

---

## Dispatched-subagent Write probe — implement tier (issue #858)

**Verdict: `PERMITTED`**

a subagent Write tool_use targeting subwrite-implement.txt was recorded, its parent chains to a dispatch recorded in this file (tool_use id 'toolu_01NmqhQw56kRuoGSXdr3e1Ph' -> parent_tool_use_id 'toolu_01CAkuq4wZ4x9M82HazPicfF'), and the on-disk side-effect file carries the probe's payload marker.

Deterministic verdict from the execution file's recorded `tool_use` inputs, their `parent_tool_use_id`, and `permission_denials`, corroborated by the on-disk side-effect file this run actually stat'ed: `.prflow/tmp/subwrite-implement.txt`. The model's prose is never the measurement.

> [!IMPORTANT]
> This verdict is a dated observation of one `claude-code-action` version and one subagent definition (the built-in general-purpose type dispatched by the probe's own prompt under the tier's generated baseline at the recorded commit) — not a platform contract, and it establishes nothing for a differently-defined subagent type or a later claude-code-action version. SCOPE: the run carries `--permission-mode acceptEdits`, so a `PERMITTED` answers "did the dispatched subagent's Write land under that permission mode?" — it does not isolate the allowlist from the permission mode as the sole reason the write was allowed. Re-probe (dispatch matcher-probe.yml, or push to a same-repo PR touching it) after a claude-code-action / CLI upgrade before trusting it.

| Field | Value |
|-------|-------|
| tier | `implement` |
| verdict | **PERMITTED** |
| dispatch_outcome | recorded |
| recorded_at_all | yes |
| chain_attributable | yes |
| control_before | yes |
| control_after | yes |
| write_outcome | recorded |
| write_chain_ok | yes |
| side_effect_state | corroborated |

**permission_mode:** `acceptEdits`

**model:** `claude-haiku-4-5-20251001`

**effort:** `low`

**ref:** `issue-1152-command-profile-shape-lint`

**head_commit:** `85e57ac1c6dcf732a861230f82182191977c6e41`

**Resolved `--allowed-tools` literal (the measured condition, verbatim):**

```
Read,Write,Edit,Glob,Grep,LS,Skill,Agent,TodoWrite,EnterPlanMode,ExitPlanMode,WebFetch,WebSearch,Bash(git add:*),Bash(git commit:*),Bash(git push:*),Bash(git pull:*),Bash(git fetch:*),Bash(git ls-remote:*),Bash(git status:*),Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(git hash-object:*),Bash(git checkout:*),Bash(git branch:*),Bash(git stash:*),Bash(git rm:*),Bash(git mv:*),Bash(git restore:*),Bash(git revert:*),Bash(git blame:*),Bash(git ls-files:*),Bash(git rev-parse:*),Bash(git merge-base:*),Bash(git merge:*),Bash(gh pr create:*),Bash(gh pr edit:*),Bash(gh pr comment:*),Bash(gh pr diff:*),Bash(gh pr view:*),Bash(gh pr ready:*),Bash(gh pr list:*),Bash(gh pr checks:*),Bash(gh pr status:*),Bash(gh pr reopen:*),Bash(gh issue view:*),Bash(gh issue comment:*),Bash(gh issue list:*),Bash(gh issue edit:*),Bash(gh issue create:*),Bash(gh issue reopen:*),Bash(gh issue status:*),Bash(gh search:*),Bash(gh label list:*),Bash(gh repo view:*),Bash(gh run view:*),Bash(gh run list:*),Bash(gh workflow view:*),Bash(gh workflow list:*),Bash(gh api:*),Bash(jq:*),Bash(.prflow/vendor/prflow/scripts/run-jq.sh:*),Bash(.prflow/vendor/prflow/scripts/config-get.sh:*),Bash(.prflow/vendor/prflow/scripts/workpad.py:*),Bash(.prflow/vendor/prflow/scripts/seed-review-progress.sh:*),Bash(.prflow/vendor/prflow/scripts/verification-flight.py:*),Bash(.prflow/vendor/prflow/scripts/reception-record.py:*),Bash(.prflow/vendor/prflow/scripts/checkout-fingerprint.py:*),Bash(.prflow/vendor/prflow/scripts/check-completion-evidence.py:*),Bash(.prflow/vendor/prflow/scripts/parse-acs.py:*),Bash(.prflow/vendor/prflow/scripts/check-verified-premises.py:*),Bash(.prflow/vendor/prflow/scripts/preflight.py:*),Bash(.prflow/vendor/prflow/scripts/branch-for-issue.py:*),Bash(.prflow/vendor/prflow/scripts/update-branch-checkpoint.sh:*),Bash(.prflow/vendor/prflow/scripts/phase2-durability-checkpoint.sh:*),Bash(.prflow/vendor/prflow/scripts/file-deferrals.py:*),Bash(.prflow/vendor/prflow/scripts/discover-deferral-manifests.py:*),Bash(.prflow/vendor/prflow/scripts/match-deferrals.py:*),Bash(.prflow/vendor/prflow/scripts/resolve-review-overrides.py:*),Bash(.prflow/vendor/prflow/scripts/apply-labels.sh:*),Bash(.prflow/vendor/prflow/scripts/ensure-label.sh:*),Bash(.prflow/vendor/prflow/scripts/apply-pr-triggerer.sh:*),Bash(.prflow/vendor/prflow/scripts/apply-issue-dependencies.py:*),Bash(.prflow/vendor/prflow/scripts/resolve-existing-pr.sh:*),Bash(.prflow/vendor/prflow/lib/efficiency-trace.sh:*),Bash(.prflow/vendor/prflow/scripts/stale-prose-lint.py:*),Bash(.prflow/vendor/prflow/scripts/dismiss-stale-rejections.sh:*),Bash(.prflow/vendor/prflow/scripts/post-review-verdict.sh:*),Bash(.prflow/vendor/prflow/scripts/loop-verdict-marker.py:*),Bash(.prflow/vendor/prflow/scripts/match-lint-adjudications.py:*),Bash(.prflow/vendor/prflow/scripts/normalize-verdicts.py:*),Bash(.prflow/vendor/prflow/scripts/load-prompt-extension.sh:*),Bash(.prflow/vendor/prflow/scripts/react-to-trigger.sh:*),Bash(.prflow/vendor/prflow/scripts/extract-doc-needed-paths.sh:*),Bash(pip install:*),Bash(pip:*),Bash(python:*),Bash(python3:*),Bash(python -m:*),Bash(python3 -m:*),Bash(ruff:*),Bash(ruff check:*),Bash(ruff format:*),Bash(pytest:*),Bash(mypy:*),Bash(grep:*),Bash(rg:*),Bash(find:*),Bash(wc:*),Bash(sort:*),Bash(uniq:*),Bash(cut:*),Bash(tr:*),Bash(xargs:*),Bash(awk:*),Bash(sed:*),Bash(diff:*),Bash(cmp:*),Bash(comm:*),Bash(cat:*),Bash(head:*),Bash(tail:*),Bash(less:*),Bash(ls:*),Bash(tree:*),Bash(file:*),Bash(stat:*),Bash(date:*),Bash(pwd:*),Bash(realpath:*),Bash(dirname:*),Bash(basename:*),Bash(which:*),Bash(type:*),Bash(env:*),Bash(echo:*),Bash(printf:*),Bash(test:*),Bash(touch:*),Bash(mkdir:*),Bash(rmdir:*),Bash(rm:*),Bash(mv:*),Bash(cp:*),Bash(tee:*),Bash(lib/test/run.sh:*),Bash(lib/test/run-parallel.sh:*),Bash(lib/test/run-module.sh:*),Bash(lib/test/run-shard.sh:*),Bash(lib/test/shard-tally.py:*),Bash(lib/test/test_python_scripts.py:*),Bash(lib/test/test_workflow_flight_recorder.py:*),Bash(lib/test/test_workflow_analyzer.py:*),Bash(lib/test/test_verification_baseline.py:*),Bash(lib/test/test_create_issue_context_eval.py:*),Bash(lib/test/coverage_map_guard.py:*),Bash(lib/preflight.sh:*),Bash(shellcheck:*),Bash(chmod:*),Bash(git ls-remote:*),Bash(git check-ignore:*),Bash(lib/efficiency-trace.sh:*),Bash(/home/runner/work/prflow/prflow/lib/efficiency-trace.sh:*),Bash(scripts/apply-labels.sh:*),Bash(/home/runner/work/prflow/prflow/scripts/apply-labels.sh:*),Bash(scripts/apply-pr-triggerer.sh:*),Bash(/home/runner/work/prflow/prflow/scripts/apply-pr-triggerer.sh:*),Bash(scripts/branch-for-issue.py:*),Bash(/home/runner/work/prflow/prflow/scripts/branch-for-issue.py:*),Bash(scripts/check-completion-evidence.py:*),Bash(/home/runner/work/prflow/prflow/scripts/check-completion-evidence.py:*),Bash(scripts/config-get.sh:*),Bash(/home/runner/work/prflow/prflow/scripts/config-get.sh:*),Bash(scripts/discover-deferral-manifests.py:*),Bash(/home/runner/work/prflow/prflow/scripts/discover-deferral-manifests.py:*),Bash(scripts/dismiss-stale-rejections.sh:*),Bash(/home/runner/work/prflow/prflow/scripts/dismiss-stale-rejections.sh:*),Bash(scripts/ensure-label.sh:*),Bash(/home/runner/work/prflow/prflow/scripts/ensure-label.sh:*),Bash(scripts/apply-issue-dependencies.py:*),Bash(/home/runner/work/prflow/prflow/scripts/apply-issue-dependencies.py:*),Bash(scripts/extract-doc-needed-paths.sh:*),Bash(/home/runner/work/prflow/prflow/scripts/extract-doc-needed-paths.sh:*),Bash(scripts/file-deferrals.py:*),Bash(/home/runner/work/prflow/prflow/scripts/file-deferrals.py:*),Bash(scripts/load-prompt-extension.sh:*),Bash(/home/runner/work/prflow/prflow/scripts/load-prompt-extension.sh:*),Bash(scripts/match-deferrals.py:*),Bash(/home/runner/work/prflow/prflow/scripts/match-deferrals.py:*),Bash(scripts/match-lint-adjudications.py:*),Bash(/home/runner/work/prflow/prflow/scripts/match-lint-adjudications.py:*),Bash(scripts/normalize-verdicts.py:*),Bash(/home/runner/work/prflow/prflow/scripts/normalize-verdicts.py:*),Bash(scripts/parse-acs.py:*),Bash(/home/runner/work/prflow/prflow/scripts/parse-acs.py:*),Bash(scripts/preflight.py:*),Bash(/home/runner/work/prflow/prflow/scripts/preflight.py:*),Bash(scripts/react-to-trigger.sh:*),Bash(/home/runner/work/prflow/prflow/scripts/react-to-trigger.sh:*),Bash(scripts/reception-record.py:*),Bash(/home/runner/work/prflow/prflow/scripts/reception-record.py:*),Bash(scripts/resolve-existing-pr.sh:*),Bash(/home/runner/work/prflow/prflow/scripts/resolve-existing-pr.sh:*),Bash(scripts/resolve-review-overrides.py:*),Bash(/home/runner/work/prflow/prflow/scripts/resolve-review-overrides.py:*),Bash(scripts/run-jq.sh:*),Bash(/home/runner/work/prflow/prflow/scripts/run-jq.sh:*),Bash(scripts/stale-prose-lint.py:*),Bash(/home/runner/work/prflow/prflow/scripts/stale-prose-lint.py:*),Bash(scripts/update-branch-checkpoint.sh:*),Bash(/home/runner/work/prflow/prflow/scripts/update-branch-checkpoint.sh:*),Bash(scripts/verification-flight.py:*),Bash(/home/runner/work/prflow/prflow/scripts/verification-flight.py:*),Bash(scripts/workpad.py:*),Bash(/home/runner/work/prflow/prflow/scripts/workpad.py:*),Bash(mktemp:*),Bash(bash:*),Task,Agent
```

### Observed `permission_denials` entries (0)

_No permission_denials entries found in the execution file._
