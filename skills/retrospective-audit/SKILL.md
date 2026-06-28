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

If the helper exits non-zero, a consumer extension exists but could not be loaded — surface its stderr message and do not silently proceed as if none existed. If it exits 0 and prints text, treat that text as additional instructions appended to the end of this skill's own prompt for this run — it is upgrade-safe, consumer-owned customization committed under `.devflow/prompt-extensions/`. If it exits 0 and prints nothing, proceed unchanged. (This subagent's stdout contract is strict — exactly one JSON object — so a consumer extension here must not break that contract.)

## § 1 — Re-derive the root cause

Read every bundled occurrence PR's primary sources in full: `pr` (body + title), `issue` (linked-issue body + comments), `pr_comments`, `pr_reviews`, `review_comments`, `workpad_body`, `human_postbot_diff`, `commits`.

Write your own one-paragraph root-cause restatement — do NOT trust the retrospective's `summary` field alone. The original retrospective LLM may have hallucinated.

**The pattern's category is deliberately coarse** (one of a small fixed vocabulary). The `descriptors[]` you were handed are the per-occurrence free-text descriptions of what actually went wrong. Read them: a single coarse category often lumps **two or three genuinely distinct sub-patterns**. When it does, pick the **dominant** sub-pattern (most occurrences / clearest single fix), fix that one, and explicitly note in the PR body which other sub-patterns under this category this PR does *not* address (so a future run that re-flags them isn't a surprise). "One pattern per invocation, no bundled fixes" still holds — one *fix* per PR, not one fix per category-sized grab-bag.

**Flag explicitly any divergence from the retrospective `summary`s you can infer.** Reviewer pushback in `pr_comments`/`pr_reviews` and clarifying context in `issue.comments` often contradicts the retrospective's machine-generated summary; surface those divergences in the PR body so reviewers can recalibrate.

---

## § 2 — Plugin self-audit FIRST

**Can this fix be a prompt-extension? (ask this BEFORE the self-audit questions and the exclusion match below).** A large class of "make skill X also do Y" fixes is a purely **additive** change to a skill's behavior — extra instructions appended to what the skill already does, overriding nothing. DevFlow ships a surface built exactly for that: `scripts/load-prompt-extension.sh` prints `.devflow/prompt-extensions/<skill>.md` and the skill is instructed to append that file's contents **verbatim** to its own prompt (every skill that calls the loader honors this; an absent or empty file is a silent no-op — while a *present-but-undeliverable* file (unreadable, a broken symlink, not a regular file) fails **loud** with exit 2 — so the fix is live only when the named `<skill>` actually invokes the loader). That directory is **in scope** — it is not on the canonical exclusion list below, and `lib/check-excluded-path.sh` does not match it.

So before routing any skill-behavior change to the meta-issue form, ask: **is the fix expressible as an appended instruction, and is it appropriately consumer-local?** If yes, **first verify the route is actually live**: confirm `skills/<skill>/SKILL.md` exists and genuinely invokes `scripts/load-prompt-extension.sh <skill>` (`git grep -n load-prompt-extension.sh skills/<skill>/`). If the skill directory is absent, the `<skill>` name is wrong, or that skill never calls the loader, an extension file would be written but never read — a silent inert no-op that *looks* applied (file committed, PR merged) yet never executes, so the pattern recurs — therefore treat the fix as **structural** and fall through to condition (i) (the meta-issue) instead. When the route is live, apply it as a normal `excluded: false` edit (§ 5 / § 6) by writing or extending `.devflow/prompt-extensions/<skill>.md` — put that path in `targets[]` — instead of editing the excluded skill body or filing a meta-issue. `<skill>` is the skill's directory name under `skills/` (`create-issue`, `implement`, `review`, …). This mirrors how DevFlow already keeps its own versioning rule in `.devflow/prompt-extensions/implement.md` rather than in the `implement` skill body.

Route to the **meta-issue form** (the four questions + the `excluded: true` early-exit below) when, and **only** when, the fix is one of:
- **(i) a structural engine defect a prose append cannot express** — it must override or remove existing skill text, or correct broken logic, not merely add to it. Rewording or replacing an existing skill step is condition (i), not an additive append. So is any behavior that must hold across *two* skills through one file — most notably the **shared review engine** (`skills/review/SKILL.md` Phases 0–4.3, executed verbatim by both `/devflow:review` and `/devflow:review-and-fix`): each wrapper loads only *its own* extension (`/devflow:review` loads `review.md`, `/devflow:review-and-fix` loads `review-and-fix.md`), so no single extension file can carry a behavior the shared engine must exhibit under *both* — and duplicating it into two extension files would drift. A behavior that must reach both is structural — change the engine, don't append to either wrapper.
- **(ii) a change to a non-prose engine file** — any path `lib/check-excluded-path.sh` treats as excluded (`lib/**`, `scripts/**`, `agents/**`, `.claude-plugin/**`, `.github/actions/**` and the `claude*`/`devflow-*` workflows — note `.github/ISSUE_TEMPLATE/` stays a valid additive surface — `.devflow/learnings/**`, `.devflow/config.json` and its `.example` / `.schema` siblings) or a jq filter / embedded program — anything a skill-prose append cannot carry. (This is the gating *question*, not a second exclusion list: `lib/check-excluded-path.sh` is the authoritative matcher for the exact paths — defer to it, not to any prose copy, which can drift.)
- **(iii) a fix that would materially benefit adopters and is expressible as engine prose** — even when a repo-local extension *could* carry it here, an engine-general rule lands in the shipped engine upstream on the first pass rather than dogfooding repo-local and waiting for a manual promotion. (The narrower "must ship in the engine to take effect for adopters — no extension can reach it" case is the strict subset this still covers.)

Two limits bound this route, so do not over-apply it:
- **Append-only.** A prompt extension can only *add* instructions; it cannot override or delete existing skill prose. A fix that must change what the skill already says is condition (i), not a prompt-extension.
- **Consumer-local.** "Consumer-local" here means *applied via the repo-local extension surface rather than the shipped skill body* — **not** "only this one repo benefits." Route an engine-general rule to condition (iii) — upstream, via the meta-issue — whenever it would materially benefit adopters and is expressible as engine prose, so it lands in the shipped skill on the first pass instead of dogfooding repo-local and waiting for a manual promotion. Keep a fix repo-local only when it is genuinely specific to this repo (e.g. DevFlow's own versioning policy in `.devflow/prompt-extensions/implement.md`) or not yet worth shipping to adopters; an extension lives in this repo's `.devflow/prompt-extensions/` and never reaches them.

**When the additive-vs-structural call is genuinely ambiguous, default to the meta-issue.** The meta-issue route fails *loudly* to a human reviewer; an inert, mis-routed, or subtly-overriding extension fails *silently* and the pattern simply recurs next cycle. So under real uncertainty the safe tie-break is the human-reviewed route, not the autonomous one.

If the fix is *not* a prompt-extension (it hits one of (i)–(iii)), fall through to the self-audit below.

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
.devflow/config.schema.json
```

The exclusion limit is **design-review**, not writability. Locally all paths are writable; these route to a meta GitHub issue because they need a human to think about second-order effects on the self-improvement loop.

---

## § 3 — Pick the intervention

Read `${CLAUDE_SKILL_DIR}/../../lib/intervention-surfaces.md`. From those surfaces — or beyond them — pick the **highest-leverage, smallest-blast-radius** single concrete change. The intervention must be one change, not a set of bullet points.

**Conflict check:** search the existing rules, skills, and docs for anything that contradicts your proposed change. If you find a conflict, reframe as "strengthen rule X" rather than "add rule Y" — that is always the higher-quality intervention. Document the conflict (or its explicit absence) in the PR body.

Examples of valid surfaces:
- Append an additive skill-behavior change to `.devflow/prompt-extensions/<skill>.md` (the in-scope prompt-extension surface from § 2) rather than editing the excluded skill body — for any "make skill X also do Y" fix expressible as an appended instruction and appropriately consumer-local.
- Strengthen an existing CLAUDE.md rule with a more visible warning and a linkable example.
- Add or tighten a linter/static-analysis rule that catches the broken pattern mechanically.
- Edit `docs/internal/<feature>.md` to fill a gap the bot kept missing.
- Update the `/create-issue` or `/devflow:implement` skill to require a missing check (when the change is *structural* — overriding existing prose or correcting logic; a purely additive requirement is the prompt-extension surface above).

---

## § 4 — Counterfactual analysis

Write a short paragraph (3–5 sentences): what could go wrong if this rule is applied too broadly? Enumerate the false-positive cases or edge cases where the existing pattern is actually correct. State explicitly how you scoped the change to avoid those pitfalls.

---

## § 5 — Make the edits

Use `Edit`/`Write` to apply the intervention directly in the working tree. Keep the diff minimal and surgical — touch only the files you intended to change and nothing else.

**Write prose interventions operative-only.** When the intervention is prose appended to a skill body, a prompt-extension, or a CLAUDE.md rule, write **only** the instruction a future agent must act on — the smallest recipe that changes behavior (trigger → action → surfaces). Do **not** copy the root cause, the motivating-PR post-mortems, the counterfactual, or a "not covered" note into the edited file — those belong in the PR body (§ 6) and git history. Add a worked example only when the rule is genuinely ambiguous without one — a single tightened example, never per-occurrence narration. **The file gets the rule; the PR gets the why.**

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
