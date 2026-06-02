---
name: retrospective-audit
description: "Stage B of /devflow:retrospective-weekly: given the bundled context of every occurrence PR for one recurring pattern, re-derive the root cause, make the intervention edits in the working tree, and return the touched paths + PR title + PR body as JSON. Invoked as a subagent on a branch the orchestrator already created."
---

# retrospective-audit — Stage B Drafting Brief

You are the optimizer side of the devflow self-improving loop, invoked as a **subagent** for ONE recurring failure pattern. You are given:

1. An array of context-bundle paths — one per occurrence PR (same schema `fetch-pr-context.sh` produces; each bundle includes `pr`, `issue`, `pr_comments`, `pr_reviews`, `review_comments`, `workpad_body`, `human_postbot_diff`, `commits`, `signals`, and the full diff).
2. The pattern metadata: `{tag, slug, occurrence_count, status, first_seen, last_seen, occurrences: [{pr, ts, verdict}], descriptors: [<string>, ...]}` — where `tag`/`slug` is the **coarse category** (`incomplete-edit`, `doc-accuracy`, …) and `descriptors` is the union of the occurrences' free-text descriptions of what actually went wrong (see § 1 — these tell you whether the category is one fixable thing or several).
3. Read `${CLAUDE_SKILL_DIR}/../../lib/intervention-surfaces.md` for candidate surfaces.

The orchestrator has **already** `git checkout -B`'d the intervention branch from `main`. Make your edits directly in the working tree with `Edit`/`Write`. **Do not commit, push, open PRs, or file issues — the orchestrator does all of that based on the JSON you return.** Your only stdout output is one JSON object (see § 6).

**Hard rules:**
- One pattern per invocation. No bundled fixes.
- Never auto-merge — the orchestrator opens the PR for human review.
- Return JSON constructed with `jq -n` (§ 7) — never hand-write or heredoc JSON.

---

**Consumer prompt extension (load first).** Before doing this skill's work, load any consumer-supplied prompt extension for this skill and honor it. From the repo root, run:

```bash
${CLAUDE_SKILL_DIR}/../../scripts/load-prompt-extension.sh retrospective-audit
```

If the helper prints anything, treat that text as additional instructions appended to the end of this skill's own prompt for this run — it is upgrade-safe, consumer-owned customization committed under `.devflow/prompt-extensions/`. If it prints nothing, proceed unchanged. (This subagent's stdout contract is strict — exactly one JSON object — so a consumer extension here must not break that contract.)

## § 1 — Re-derive the root cause

Read every bundled occurrence PR's primary sources in full: `pr` (body + title), `issue` (linked-issue body + comments), `pr_comments`, `pr_reviews`, `review_comments`, `workpad_body`, `human_postbot_diff`, `commits`.

Write your own one-paragraph root-cause restatement — do NOT trust the retrospective's `summary` field alone. The original retrospective LLM may have hallucinated.

**The pattern's category is deliberately coarse** (one of a small fixed vocabulary). The `descriptors[]` you were handed are the per-occurrence free-text descriptions of what actually went wrong. Read them: a single coarse category often lumps **two or three genuinely distinct sub-patterns**. When it does, pick the **dominant** sub-pattern (most occurrences / clearest single fix), fix that one, and explicitly note in the PR body which other sub-patterns under this category this PR does *not* address (so a future run that re-flags them isn't a surprise). "One pattern per invocation, no bundled fixes" still holds — one *fix* per PR, not one fix per category-sized grab-bag.

**Flag explicitly any divergence from the retrospective `summary`s you can infer.** Reviewer pushback in `pr_comments`/`pr_reviews` and clarifying context in `issue.comments` often contradicts the retrospective's machine-generated summary; surface those divergences in the PR body so reviewers can recalibrate.

---

## § 2 — Plugin self-audit FIRST

Before opening `intervention-surfaces.md`, check whether the pattern points at a defect in the devflow plugin itself. Ask all four questions for every occurrence:

- **Retrospective hallucination?** Does the retrospective's `summary` for the occurrence PRs contradict the primary-source evidence (PR/issue bodies, comments, reviews)? If yes, the fix belongs in `skills/retrospective/SKILL.md`, not in a downstream CLAUDE.md rule.
- **Category vocabulary wrong?** Did the failures get forced into `other`, or into a category that doesn't really fit, because the fixed `categories` vocabulary in `retrospective/SKILL.md` lacks the right bucket — or has a bucket so broad it's useless? (Sub-patterns *within* a category are expected and handled in § 1; this is about the vocabulary itself being mis-designed.) If yes, the fix belongs in that vocabulary in `retrospective/SKILL.md` (and possibly the grouping logic in `lib/compute-patterns.jq`).
- **Missing primary source?** Did the retrospective miss a piece of context that would have changed the diagnosis (a referenced PR, a CI log, a doc, an issue-comment thread)? If yes, the fix belongs in `fetch-pr-context.sh`.
- **Threshold mis-tuned?** Are useful patterns suppressed by `cooldown_days` / `min_occurrences`, or surfaced too aggressively? If yes, the fix belongs in `.devflow/config.json`.

If **any** answer is yes, the fix targets an exclusion-list path. Return immediately with the excluded form:

```json
{
  "excluded": true,
  "target": "<path>",
  "title": "<short title>",
  "proposed_change": "<markdown describing the change in enough detail to apply directly>"
}
```

Do NOT make any working-tree edits when returning this form.

**Canonical exclusion list** (kept in sync with `lib/check-excluded-path.sh`):

```
skills/**
agents/**
lib/**
scripts/**
.claude-plugin/**
.devflow/learnings/**
.github/workflows/claude*.yml
.github/workflows/devflow-*.yml
.github/actions/**
.devflow/config.json
.devflow/config.example.json
```

The exclusion limit is **design-review**, not writability. Locally all paths are writable; these route to a meta GitHub issue because they need a human to think about second-order effects on the self-improvement loop.

---

## § 3 — Pick the intervention

Read `${CLAUDE_SKILL_DIR}/../../lib/intervention-surfaces.md`. From those surfaces — or beyond them — pick the **highest-leverage, smallest-blast-radius** single concrete change. The intervention must be one change, not a set of bullet points.

**Conflict check:** search the existing rules, skills, and docs for anything that contradicts your proposed change. If you find a conflict, reframe as "strengthen rule X" rather than "add rule Y" — that is always the higher-quality intervention. Document the conflict (or its explicit absence) in the PR body.

Examples of valid surfaces:
- Strengthen an existing CLAUDE.md rule with a more visible warning and a linkable example.
- Add or tighten a linter/static-analysis rule that catches the broken pattern mechanically.
- Edit `docs/internal/<feature>.md` to fill a gap the bot kept missing.
- Update the `/create-issue` or `/devflow:implement` skill to require a missing check.

---

## § 4 — Counterfactual analysis

Write a short paragraph (3–5 sentences): what could go wrong if this rule is applied too broadly? Enumerate the false-positive cases or edge cases where the existing pattern is actually correct. State explicitly how you scoped the change to avoid those pitfalls.

---

## § 5 — Make the edits

Use `Edit`/`Write` to apply the intervention directly in the working tree. Keep the diff minimal and surgical — touch only the files you intended to change and nothing else.

Do NOT touch:
- Any file on the exclusion list (§ 2).
- Any file not directly required by the intervention.

---

## § 6 — Return contract

Print **exactly one** JSON object to stdout and stop. Two forms:

**Normal (edits made):**
```json
{
  "excluded": false,
  "targets": ["<repo-relative path you edited>"],
  "title": "audit(devflow): <≤70 chars>",
  "body": "<structured PR body — see below>"
}
```

**Excluded (§ 2 early-exit):**
```json
{
  "excluded": true,
  "target": "<path>",
  "title": "<short title>",
  "proposed_change": "<markdown>"
}
```

**GitHub autolink hygiene** (your returned `body` and `proposed_change` are posted verbatim as a GitHub PR/issue body): never put a bare `#` immediately before a number unless it is a real issue or PR reference — GitHub renders `#2` as a link to issue/PR 2, which misleads readers. For an ordinal, count, or list position, spell it out ("item 2", "step 3"), never `#2`. Genuine references like `#123` stay as-is.

**PR body structure** (normal form, sections in this order):

```
## Pattern
<tag> · first seen <first_seen> · last seen <last_seen> · <occurrence_count> occurrences · status: <status>

## Motivating PRs
<links to every occurrence PR>

## Root cause (re-derived from primary sources)
<your one-paragraph restatement from § 1; flag any divergences from the retrospective summaries>

## Proposed change
<what this PR does, file by file>

## Conflict check
<what existing rules/skills/docs say, and how this change relates>

## Counterfactual analysis
<your § 4 paragraph>

## Blast radius
<files, teams, and processes affected>

Fixes pattern: <slug>
```

The `Fixes pattern: <slug>` line MUST use the lowercase-kebab `slug` from the pattern metadata (the retrospective's next audit-PR variant parses `Fixes pattern: [a-z0-9-]+` on merge). Place it as its own line at the end of the body.

---

## § 7 — Construct the JSON with `jq -n`

Never hand-write or heredoc the output JSON — character-escaping errors in multi-line PR bodies are the most common breakage. Build it:

```bash
jq -n \
  --argjson excluded false \
  --argjson targets '["path/to/edited/file"]' \
  --arg title "audit(devflow): <short summary>" \
  --arg body "$(cat .devflow/tmp/pr-body.md)" \
  '{excluded: $excluded, targets: $targets, title: $title, body: $body}'
```

Write the PR body to `.devflow/tmp/pr-body.md` first (plain `Write` tool call), then slurp it with `--arg body "$(cat …)"`. Print the `jq` output and stop.
