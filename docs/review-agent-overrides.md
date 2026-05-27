# Per-subagent model & effort overrides for the review engine

**Config block:** `devflow_review.agent_overrides` in `.devflow/config.json`
**Resolver:** `scripts/resolve-review-overrides.py` (reads via `scripts/config-get.sh`)
**Applied by:** `skills/review/SKILL.md` (the shared review engine)

The shared `/devflow:review` engine fans out to up to nine subagents across Phases 1, 1.5, 2,
and 3. By default every one inherits the orchestrator's model and the session effort. The
`devflow_review.agent_overrides` block lets operators tune each subagent's `model` and `effort`
individually — turning the effectiveness telemetry in [efficiency-trace.md](efficiency-trace.md)
into an actionable lever.

Because the engine is shared, the overrides take effect **identically** whether it is reached via
standalone `/devflow:review` or via `/devflow:review-and-fix` (and thus the Phase-3 code-review
pass of `/devflow:implement`).

## The nine configurable identifiers

The override keys are byte-identical to the telemetry identifiers (`phase3_dispatched`, each
finding's `agent`) so config, dispatch, and the effectiveness trace stay aligned:

| Identifier | Phase | Notes |
|---|---|---|
| `devflow:checklist-generator` | 1 | Verification-checklist generation. |
| `devflow:checklist-deduper` | 1.5 | Cross-batch dedup (only when >1 generator batch). |
| `devflow:checklist-verifier` | 2 | One dispatch per agent-mode checklist item. |
| `pr-review-toolkit:code-reviewer` | 3 | Always-on. |
| `pr-review-toolkit:silent-failure-hunter` | 3 | Always-on. |
| `pr-review-toolkit:comment-analyzer` | 3 | Always-on. |
| `pr-review-toolkit:type-design-analyzer` | 3 | Gated — only when the diff adds/changes types. |
| `pr-review-toolkit:pr-test-analyzer` | 3 | Gated — only when the test-relevance predicate matches. |
| `superpowers:requesting-code-review` | 3 | Final pass; dispatched as a `general-purpose` Task but keyed under this identifier. |

Plus the special `default` key (below).

## Shape

Each value optionally sets `model` and/or `effort`:

```jsonc
{
  "devflow_review": {
    "agent_overrides": {
      "default": { "effort": "medium" },
      "devflow:checklist-deduper": { "model": "claude-haiku-4-5-20251001", "effort": "low" },
      "pr-review-toolkit:code-reviewer": { "model": "claude-opus-4-7", "effort": "high" }
    }
  }
}
```

- `model` — free-form model id, forwarded to the dispatch as given (no *value* validation). A
  present-but-unusable model (empty string or non-string) is dropped with a `::warning::`, mirroring
  the invalid-effort path.
- `effort` — one of `low`, `medium`, `high`, `xhigh`, `max`.

## Resolution rules

- **Entry-level precedence.** A subagent with its own entry uses **only** that entry; the
  `default` does **not** backfill its missing fields. The `default` entry supplies model/effort
  only for subagents that have no entry of their own. (So `code-reviewer: { model: m }` with a
  `default: { effort: high }` dispatches `code-reviewer` with model `m` and the **session** effort
  — not `high`.)
- **Explicit empty entry opts out of `default`.** An explicit empty entry (`"pr-review-toolkit:code-reviewer": {}`) counts as "has an entry": it sets neither model nor effort **and** does not inherit `default`. Use it to deliberately exclude one subagent from a broad `default` override.
- **No-entry fallback.** A subagent with **neither its own entry nor a `default`** is dispatched
  exactly as today — the global `claude_model` and the session effort — with **no `--agents`
  override emitted for it**. Existing configs (which have no `agent_overrides` block at all) are
  therefore completely unaffected.
- **Invalid effort → warn + fall back.** An `effort` value outside the enum produces a
  `::warning::` and falls back to the session effort rather than aborting the run. A non-empty
  `model` string is forwarded as given; an empty/non-string `model` is dropped with its own warning.
- **Malformed shapes never abort.** A non-object entry (a hand-edited `"agent": "high"` or a list,
  which bypasses schema validation) is ignored with a warning and treated as no-entry, so `default`
  still applies. A non-object `default` is likewise ignored. An entry that resolves to neither a
  model nor a valid effort emits no override at all. The engine never aborts on config shape.
  - **Object-valued `model`/`effort` leaf.** A hand-edited object leaf (e.g. `"model": {…}`) is
    dropped with a warning. If that was the entry's only field, the entry resolves to `{}` — which,
    being a present (empty) entry, **shadows `default`** for that subagent (it is dispatched at the
    session model/effort, not the `default` override).
  - **Array-valued leaf (narrow gap).** `config-get.sh` joins an array leaf with commas before this
    resolver sees it, so it is indistinguishable from a scalar string. A multi-element array effort
    (`["high","low"]` → `"high,low"`) fails the enum check and is dropped with a warning, but a
    **single-element** array (`["high"]` → `"high"`) silently passes, and an array `model`
    (`["a","b"]` → `"a,b"`) is forwarded verbatim as a model id. All of these require hand-editing
    past the schema (`additionalProperties:false` + the `effort` enum + `model:string` reject them
    in any validated config); the worst case is one malformed dispatch the harness would itself reject.
- **Gated agents.** The two structurally-gated Phase-3 analyzers (`type-design-analyzer`,
  `pr-test-analyzer`) are only dispatched on applicable diffs; an override is emitted only for an
  agent actually dispatched in a given run.

## Mechanism

Five of the nine subagents are **external plugins** (`pr-review-toolkit:*`, `superpowers:*` /
`general-purpose`) whose frontmatter DevFlow cannot edit, and **effort is not a dispatch-time
`Agent`/`Task` parameter**. Both model and effort must therefore ride on a per-run `--agents` JSON
block. The engine resolves the overrides with `scripts/resolve-review-overrides.py` (which reads
the config through `config-get.sh`) and materializes that block at each dispatch phase; the
external plugins' own `description`/`prompt`/`tools` come from their installed definitions, with
only the configured `model`/`effort` layered on. DevFlow never edits any external plugin's files.

The helper must be the command's **leading token** (the same cloud allow-list rule that governs
`workpad.py`); `OVERRIDES=$(…/resolve-review-overrides.py …)` is fine — the path is the leading
token inside the command substitution — but routing it through a shell variable or prepending a
`VAR=value` env-assignment makes the read-only cloud `review` profile deny it, and every override
silently resolves to `{}`. In the cloud review profile, `resolve-review-overrides.py` must also be
on the `review` tool allow-list for overrides to take effect (see
[cloud-setup.md](cloud-setup.md)); a local/interactive run is unaffected.
