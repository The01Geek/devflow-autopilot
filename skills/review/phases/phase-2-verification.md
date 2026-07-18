<!-- devflow:review-ref phase=2 file=skills/review/phases/phase-2-verification.md start -->
## Phase 2: Checklist Verification

Output: `Phase 2/4: Verifying {N} checklist items...`

### 2.0 Partition by verification_mode

Split the checklist into two groups based on each item's `verification_mode` field (set by the generator in Phase 1):

- **Lite items** (`verification_mode: "lite"`) — the orchestrator runs `grep -n` / `rg` directly. No agent dispatch. See 2.1a.
- **Agent items** (`verification_mode: "agent"`, or missing/unrecognized) — dispatch the `devflow:checklist-verifier` agent. See 2.1b.

This partition supersedes the old "one verifier agent per checklist item, no batching exceptions" rule. For pure string-presence claims, an orchestrator-direct `grep -n` is 5–10x cheaper than spawning a verifier subagent and produces an identical verdict. The lite path is bounded to claims that reduce mechanically to substring presence/absence — see `checklist-generator.md` for the eligibility rules the generator applies.

### 2.0.5 Narrow-reuse from iter-(N-1) (fix-loop callers only)

When invoked by `/devflow:review-and-fix` on iteration N≥2, iter-(N-1)'s workpad is available and the caller has supplied (a) the iter-(N-1) checklist and (b) the set of files modified by the iter-(N-1) fix commit (`fix_files`). Before partitioning into lite/agent batches, the orchestrator MAY short-circuit verification for items whose verdicts are mechanically guaranteed to be unchanged.

For each item in the **current iteration's** checklist, reuse the prior verdict (skip verification) iff ALL of the following hold:

1. There exists an item in the iter-(N-1) checklist with the **same `claim_signature`**.
2. That prior item's `verdict` is **`PASS`**.
3. The current item's `source_file` is **NOT in `fix_files`** (the fix commit did not touch it).

For each reused item, copy `verdict`, `evidence`, and `file_checked` from the prior result and tag it `reused_from_iter_<N-1>: true` in the workpad. Everything else — new items the generator emitted in variance-recovery mode, items whose prior verdict was FAIL or INCONCLUSIVE, items whose `source_file` was touched by the fix commit — verifies fresh.

**Why narrow.** The framing the user established: iterations exist for two distinct reasons. *Fix-induced defects* (did the fix introduce new bugs?) are well-served by file-intersection — a PASS item whose file the fix didn't touch is genuinely unchanged. *Variance-recovered defects* (did iter-1 miss something a second look would find?) are the opposite — they're the entire purpose of running Phase 1 again, and a coarse "the fix didn't touch any prior-checklist file, so skip Phase 1+2 wholesale" gate would silently dismiss them. The narrow per-item reuse here optimizes only the first case.

Output: `Reused {K} of {N} checklist verdicts from iter-(N-1) (matching claim_signature, prior verdict PASS, source_file untouched by fix commit). Verifying remaining {N-K} fresh.`

### 2.1a Run lite probes directly

For each `lite` item, execute the probe described in `lite_probe`:

- `kind: "string_present"` — run `grep -nF -- "<string>" <file>` (or `rg -nF "<string>" <file>` if available). If a `line_range` is present, additionally check that at least one hit falls inside `[L1, L2]` (inclusive). Verdict: PASS if any in-range hit (or any hit when no range), FAIL otherwise.
- `kind: "string_absent"` — run the same grep. Verdict: PASS if no hit; FAIL if any hit.

Use fixed-string mode (`-F`) by default — `lite_probe.string` is a literal, not a regex. Escape shell-special characters by quoting.

Edge cases:
- File missing → record INCONCLUSIVE with `evidence: "file not found"`.
- `lite_probe` field missing despite `verification_mode: "lite"` (malformed item) → promote the item to the agent path; do not silently PASS.
- `grep` exit code 2 (real error, not just no-match) → INCONCLUSIVE with the stderr text in `evidence`.

**#504 displaced-path routing.** For a `source_file` the run's ground-truth block lists as #458-displaced, the working-tree copy is base-ref/stub bytes (not HEAD) — grep the `git show <head>:<path>` output, not the working-tree file; a base-state claim via `git show $PR_BASE_SHA:<path>`. On a routed-read error with no cached-diff deletion, INCONCLUSIVE (never working-tree/fetch fallback). Listed paths stay fully in review scope (channel, not depth). Inert with no displaced list; per-mode head binding and the full fail direction live in the truthfulness-contract routing.

Record the result in the same JSON shape as agent verdicts:
```json
{"id": "VC-N", "verdict": "PASS|FAIL|INCONCLUSIVE", "evidence": "lite probe: 2 hits in lines 113, 117", "file_checked": "path/to/file.py"}
```

**Examples:**
- *Lite-eligible:* `claim`: "License header `<expected literal>` appears in `path/to/new_source_file`". `lite_probe`: `{kind: "string_present", string: "<expected literal>", file: "path/to/new_source_file"}`. The orchestrator greps; no agent needed.
- *Agent-required (NOT lite):* `claim`: "Mock return value of `<symbol>` in `path/to/test_file` matches the real signature in `path/to/impl_file`". Two files, semantic shape comparison — must dispatch the verifier.

### 2.1b Launch verifier agents in batches

Split the *agent* items into batches of up to 8. For each batch, launch all agents in parallel using multiple Agent tool calls in a single message.

Use the **Agent tool** with `subagent_type: "devflow:checklist-verifier"` for each item. Resolve overrides for `devflow:checklist-verifier` once per Phase 2 (the verdict is identical across the batch) per **Per-Subagent Model/Effort Overrides** above, and dispatch every verifier through the materialized `--agents` block when one applies.

Pass the following prompt for each:
```
Verify this claim against the actual source code. Read the referenced files, compare the claim to reality, and report PASS, FAIL, or INCONCLUSIVE.

#504 displaced-path routing: for any referenced file the run's displaced-path list marks as #458-displaced — read that list directly from the Phase 0.1.5 scratch file `.devflow/tmp/displaced-paths.txt` before you verify (you receive this dispatch prompt, not the orchestrator's engine-ground-truth block; a missing or empty file means no displaced list, so this routing is inert) — the working-tree copy is base-ref/stub bytes (not HEAD) — read it via `git show <head>:<path>` (a base-state claim via `git show $PR_BASE_SHA:<path>`), never the working-tree file. On a routed-read error where the cached diff does not show the path deleted at head, probe `git cat-file -e <head>:<path>` and report INCONCLUSIVE with the displacement attribution — never fall back to the working tree, never `git fetch`. Listed paths stay fully in review scope (channel, not depth). With no displaced list, behave exactly as today.

Checklist item:
{paste the JSON checklist item here}

The `source_line` field (if present) is best-effort from the generator and may be approximate. Treat it as a starting hint; if the symbol/claim isn't at that line, grep the file for the relevant identifier rather than reporting INCONCLUSIVE. Report INCONCLUSIVE only when the source of truth is genuinely unreachable (file missing, claim too vague to locate, external API not consultable).

When a claim's wording is technically inaccurate but the underlying code is correct (e.g., the claim oversimplifies a branch the code handles correctly), prefer **PASS** with an evidence note explaining the wording-vs-code distinction. Reserve FAIL for cases where the code itself is wrong or contradicts the claim's intent.

Report your verdict as JSON in a ```json code fence: {"id": "VC-N", "verdict": "PASS|FAIL|INCONCLUSIVE", "evidence": "...", "file_checked": "..."}
```

### 2.2 Collect results

Collect verdicts from BOTH paths — lite probes (2.1a) and agent batches (2.1b). Parse the JSON verdict from each agent response.

If an agent times out or fails, record that item as:
```json
{"id": "VC-N", "verdict": "INCONCLUSIVE", "evidence": "Verifier agent failed or timed out.", "file_checked": "N/A"}
```

Store all verification results in a single combined array (lite + agent), keyed by `id`.

Output: `Verified: {pass_count} passed, {fail_count} failed, {inconclusive_count} inconclusive ({lite_count} via lite probe, {agent_count} via agent).`
<!-- devflow:review-ref phase=2 file=skills/review/phases/phase-2-verification.md end -->
