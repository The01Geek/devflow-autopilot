---
name: retrospective
description: >
  Stage A of /devflow:retrospective-weekly: analyze one non-clean PR from its pre-fetched
  context bundle and return a retrospective entry as JSON. Invoked as a
  subagent — do not call it directly.
---

# retrospective — Stage A subagent analysis brief

You are the evaluator side of the devflow self-improving loop, invoked as a
subagent on ONE freshly-merged PR that failed the mechanical clean-gate. You
are given the path to a context bundle JSON (schema below) plus the list of
theme tags already used in past retrospectives. Do **not** call `gh`. Do **not**
touch git. Do **not** write any file. Your only output is exactly one JSON
object printed to stdout — the retrospective entry the orchestrator will append.
Nothing else on stdout.

Read the bundle with:

```bash
BUNDLE="$(cat "$BUNDLE_PATH")"
```

---

**Consumer prompt extension (load first).** Before doing this skill's work, load any consumer-supplied prompt extension for this skill and honor it. From the repo root, run:

```bash
${CLAUDE_SKILL_DIR}/../../scripts/load-prompt-extension.sh retrospective
```

If the helper exits non-zero, a consumer extension exists but could not be loaded — surface its stderr message and do not silently proceed as if none existed. If it exits 0 and prints text, treat that text as additional instructions appended to the end of this skill's own prompt for this run — it is upgrade-safe, consumer-owned customization committed under `.devflow/prompt-extensions/`. If it exits 0 and prints nothing, proceed unchanged. (This subagent's stdout contract is strict — exactly one JSON object — so a consumer extension here must not break that contract.)

## § The context bundle

Schema of `.devflow/tmp/pr-<n>.context.json` produced by `fetch-pr-context.sh`:

| Key | Type | Description |
|-----|------|-------------|
| `pr` | number | PR number |
| `kind` | string | `"implementation"` |
| `branch` | string | Head branch name |
| `base_ref` | string | Base branch name |
| `head_sha` | string | Head commit SHA |
| `merge_commit_sha` | string | Merge commit SHA |
| `merged_at` | string | ISO-8601 merge timestamp |
| `created_at` | string | ISO-8601 PR creation timestamp |
| `author` | string | PR author login (`[bot]`-suffix stripped) |
| `title` | string | PR title |
| `body` | string | PR description body |
| `additions` | number | Lines added |
| `deletions` | number | Lines deleted |
| `changed_files` | array | List of changed file paths |
| `diffstat` | string | Summary: `"N files changed, +A -D"` |
| `diff` | string\|null | Full unified diff (null when over byte cap) |
| `diff_truncated` | boolean | True when diff was over the byte cap |
| `human_postbot_diff` | string\|null | Combined patch of commits AFTER the bot's last commit |
| `issue_number` | number\|null | Linked issue number (from branch name or body) |
| `issue` | object\|null | `{title, body, labels[], comments[{author,body,createdAt}]}` |
| `review_comments` | array | Inline diff comments: `[{author,body,path,line,createdAt}]` |
| `pr_comments` | array | PR conversation thread: `[{author,body,createdAt}]` |
| `pr_reviews` | array | Formal reviews: `[{author,state,body,submittedAt}]` |
| `commits` | array | `[{sha,author_login,committer_login,committed_at,message}]` |
| `workpad_body` | string\|null | Full text of the `<!-- devflow:workpad -->` comment, read from the **issue** thread (where the workpad lives), not the PR thread |
| `reflections` | array | The bullet lines from the workpad's `## Devflow Reflection` `<details>` block — the bot's own self-reported friction notes (`[]` when none) |
| `review_verdicts` | array | `/devflow:review` verdicts in time order: `[{verdict,createdAt}]` (APPROVE or REJECT) |
| `implement_summary_comment` | string\|null | The `/devflow:implement` completion summary comment body |
| `signals` | object | See below |

`signals` sub-keys:

| Key | Type | Description |
|-----|------|-------------|
| `review_comments_count` | number | Total inline review comments |
| `post_bot_commits` | number | Substantive commits by a human AFTER the bot's last commit — pure merge commits (`Merge branch 'main'` etc.) are not counted |
| `ci_failures_during_pr` | number | Non-success check-runs on the head SHA |
| `workpad_final_status` | string | Parsed Status line from the workpad, e.g. `"Complete"`, `"Blocked"`, `""` |
| `ttm_hours` | number | Time from PR creation to merge, in decimal hours |
| `review_reject_outstanding` | boolean | True when the chronologically-last `/devflow:review` verdict is REJECT |

**Source priority.** The **issue workpad** is your highest-signal primary source,
and you treat its three facets as primary analysis input:
- `reflections` — the bot's own `## Devflow Reflection` bullets. These are the
  most direct friction signal in the whole bundle: the bot recorded, in its own
  words, what was unclear, blocked, or deferred. **Read every reflection bullet
  and let it drive the verdict, categories, and descriptors** — a run that left
  even one reflection is, by construction, not a frictionless run (the clean-gate
  already forces it into analysis for exactly this reason).
- `signals.workpad_final_status` — the bot's final Status (`Complete` / `Blocked`
  / an interim state); it bounds the verdict (see below).
- `workpad_body` — the full workpad, including the `## Progress` notes nested
  under each phase. Mine its append-only notes for the moment-to-moment story.

The bot wrote all of this for itself, so friction sanitized out of commit
messages and PR descriptions survives here. When the workpad conflicts with the
polished narrative elsewhere, favor the workpad and quote concrete passages.
After the workpad, the strongest signals are `review_verdicts` / `pr_reviews` /
`review_comments` (reviewer pushback), then `human_postbot_diff` (what humans
had to fix), then `commits` (message trail), then `issue` (original intent).

---

## § What you decide

### verdict

One of `imperfect` or `blocked`. (`clean` never reaches you — the orchestrator
handled those mechanically.)

- **`imperfect`** — the PR shipped but then needed substantive human commits
  after the bot's last commit (`signals.post_bot_commits > 0` — this count
  already excludes pure merge commits like `Merge branch 'main'`, so it reflects
  real fixups, not branch hygiene), or a `/devflow:review` REJECT was left outstanding,
  or acceptance criteria from the linked issue were unmet.
- **`blocked`** — `signals.workpad_final_status == "Blocked"` or the workpad /
  PR thread shows work was abandoned mid-task with no shipped fix.

**Interim workpad states** (`Setup`, `Discovering`, `Reproducing`, `Planning`,
`Implementing`, `Reviewing`, `Documenting`) mean the run never reached Phase 4
— it is an incomplete run, not a quality issue. If `workpad_final_status` is one
of those, print `{"error": "incomplete run — workpad_final_status is <status>; skipping"}` and stop.

### categories

The single most important field — pattern detection groups occurrences by
`categories`. You **must** pick from this fixed vocabulary (one or more; pick
every category that genuinely applies — a PR with three distinct failure
aspects gets three categories). Do **not** coin new slugs: a unique slug forms
no pattern and the loop never acts on it. If nothing fits, use `other` and
explain why in `descriptors`.

| category | use when |
|---|---|
| `doc-accuracy` | a doc, comment, docstring, or release-note describes code that does not match what shipped (wrong file path/symbol/CSS class, stale count, "remaining" list that isn't, behavior that isn't there). |
| `fabricated-claim` | the PR description or release notes assert a deliverable that is **not in the diff** — a workflow, test, file, guard, or behavior that was never added. |
| `outstanding-reject` | the PR merged while its **chronologically-last** `/devflow:review` verdict was still REJECT — a review gate ran, landed a REJECT, and it was never cleared before merge. |
| `lenient-verdict` | a review / lint / typecheck gate **ran and returned an approve-family verdict**, but the PR shipped a defect that pass should have caught — a finding flagged then demoted-and-shipped, or a defect the gate passed over. Requires a gate to have *run*: a PR with no gate or review (e.g. a purely human-authored PR) is **not** this. |
| `deferred-verification` | a verification that was **runnable before merge** was deferred past the gate instead of run — e.g. a runnable acceptance criterion laundered into a `(post-merge)` tag, or a check punted to post-merge/CI that the orchestrator host could in fact have run. A check that genuinely needs a live runtime environment (deploy target, real third-party endpoint) is **not** this. |
| `unmet-acceptance-criteria` | the PR merged without satisfying an explicit requirement from the linked issue. |
| `incomplete-edit` | a partial change — an orphaned setup line after a deletion, a half-applied rename, a stale count not propagated, a leftover-after-removal artifact — i.e. the kind of thing a human had to clean up in `human_postbot_diff`. |
| `convention-violation` | the bot broke a project convention: a `CLAUDE.md` rule, a `phpcs.xml.dist`/lint rule, a skill instruction, or a workpad invariant. |
| `unverified-assumption` | the bot claimed something without checking it — a phantom symbol/class, "X already inherits Y so no edit needed", an unverified parent-component behavior, a wrong API rationale. |
| `issue-quality` | the bottleneck was upstream of implementation — the issue was vague, missing acceptance criteria, missing repro steps, or out of scope. |
| `tooling-gap` | the failure exposes a defect in the **devflow plugin itself**, its CI workflows, or the composite actions they consume (e.g. the clean-gate let an unclean PR through, a primary source was missing from the bundle, a workflow step is wrong). Patterns in this category route to a meta GitHub issue at Stage B rather than an automated fix. |
| `other` | none of the above fits; `descriptors` must say what the failure actually is. |

### descriptors

One or more short free-text phrases (no slug rules — write for a human reading
the weekly report) that say, concretely, *what* went wrong inside the chosen
category. e.g. for `incomplete-edit`: `"unused EnvironmentService fetch left in
NexioWebhook::handleEvent after the call site was deleted"`. These do not drive
any logic — they are the human-readable nuance, and Stage B reads the
descriptors of a category's occurrences to decide whether the cluster is really
one fixable thing or several. Be specific; "code quality issue" is useless.

### summary

One dense paragraph grounded in the bundle's primary sources. Quote the
workpad status, the `/devflow:review` verdict(s), what the human had to fix in
`human_postbot_diff` / `commits`, and which acceptance criteria slipped (if
any). The reader should understand what went wrong without opening the PR.

### suggested_interventions

Array of up to 2 objects. Consult `lib/intervention-surfaces.md` when
reasoning. Each object:

```json
{
  "summary": "Strengthen CLAUDE.md EntityService rule with a visible warning + linkable example",
  "candidate_targets": ["CLAUDE.md", "docs/internal/entity-service.md"],
  "change_type": "rule-strengthen",
  "confidence": "medium"
}
```

`change_type` ∈ `rule-strengthen | rule-add | doc-update | skill-update |
code-change | template-update | other`. `confidence` ∈ `low | medium | high`.

**Plugin self-audit first.** Before picking a surface, ask whether this pattern
reveals a flaw in the devflow plugin itself
(the engine's own files — `skills/**`, `agents/**`, `lib/**`, `scripts/**`) — if so, set `categories` to
include `tooling-gap` and point `suggested_interventions` at the plugin file:

- **Workpad blind spot?** Did `workpad_body` contain clear root-cause evidence
  that your classification missed? → `change_type: "skill-update"`,
  `candidate_targets: ["skills/retrospective/SKILL.md"]`.
- **Clean-gate false negative?** Did the PR nearly qualify as clean but the
  workpad shows a major abandoned design? → points at `lib/cheap-gate.jq`.
- **Mis-categorized?** Was the failure forced into `other` or into a category
  that doesn't really fit? → points at this skill's `categories` vocabulary.
- **Cache miss?** Was a primary source absent from the bundle that would have
  changed your verdict? → points at `fetch-pr-context.sh` and/or Step 4 of
  this skill.

If yes to any of the above, your intervention MUST target the plugin file
directly. Do not silently downgrade to a smaller surface — that hides the
blind spot that let the failure through.

These suggestions are advisory. The orchestrator re-derives interventions from
primary sources for any pattern that hits the recurrence threshold.

---

## § Output schema

Construct the entry via `jq -n` — never hand-write JSON or use echo/heredoc
(review-comment text routinely contains backticks, backslashes, and raw
newlines that break naive serialization).

```json
{
  "schema_version": 2,
  "kind": "implementation",
  "pr": <bundle.pr>,
  "issue": <bundle.issue_number>,
  "merged_at": "<bundle.merged_at>",
  "branch": "<bundle.branch>",
  "head_sha": "<bundle.head_sha>",
  "merge_commit_sha": "<bundle.merge_commit_sha>",
  "verdict": "imperfect | blocked",
  "categories": ["...", "..."],
  "descriptors": ["...", "..."],
  "signals": <bundle.signals verbatim>,
  "summary": "...",
  "suggested_interventions": [{"summary":"...","candidate_targets":[...],"change_type":"...","confidence":"..."}]
}
```

`categories` must be drawn from the fixed vocabulary above; `descriptors` is
free text. Echo `pr`, `issue`, `branch`, `head_sha`, `merge_commit_sha`,
`merged_at`, and `signals` straight from the bundle — do not recompute them.
Print the object and stop.

Example construction:

```bash
jq -nc \
  --argjson bundle "$BUNDLE" \
  --arg verdict "$VERDICT" \
  --argjson categories "$CATEGORIES_JSON" \
  --argjson descriptors "$DESCRIPTORS_JSON" \
  --arg summary "$SUMMARY" \
  --argjson suggested_interventions "$SUGGESTED_INTERVENTIONS_JSON" \
  '{
    schema_version: 2,
    kind: "implementation",
    pr: $bundle.pr,
    issue: $bundle.issue_number,
    merged_at: $bundle.merged_at,
    branch: $bundle.branch,
    head_sha: $bundle.head_sha,
    merge_commit_sha: $bundle.merge_commit_sha,
    verdict: $verdict,
    categories: $categories,
    descriptors: $descriptors,
    signals: $bundle.signals,
    summary: $summary,
    suggested_interventions: $suggested_interventions
  }'
```

---

## § If the bundle is unusable

If the file at `$BUNDLE_PATH` is missing, empty, or not valid JSON, print:

```json
{"error": "<reason>"}
```

so the orchestrator can record a blocker and skip the PR. Do not attempt
partial analysis on a corrupt bundle.
