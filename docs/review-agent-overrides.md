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

## Migration (v2.8.12): the five review-agent keys were renamed

**Breaking config change.** The five Phase-3 review agents were internalized as first-party DevFlow
agents (vendored from Anthropic's pr-review-toolkit plugin), so the engine now dispatches them under
the `devflow:` namespace. Their `agent_overrides` keys were renamed accordingly:

| Old key (pre-2.8.12) | New key |
|---|---|
| `pr-review-toolkit:code-reviewer` | `devflow:code-reviewer` |
| `pr-review-toolkit:silent-failure-hunter` | `devflow:silent-failure-hunter` |
| `pr-review-toolkit:comment-analyzer` | `devflow:comment-analyzer` |
| `pr-review-toolkit:type-design-analyzer` | `devflow:type-design-analyzer` |
| `pr-review-toolkit:pr-test-analyzer` | `devflow:pr-test-analyzer` |

If your `.devflow/config.json` keys `agent_overrides` on any old identifier, rename it to the new
one. A stale old key does **not** abort a run, but it silently stops applying: the engine only ever
dispatches the new `devflow:` identifier, so the resolver only ever reads the new key — it never
reads (and therefore never warns about) a stale `pr-review-toolkit:` key. Renaming is the only way
to make the override take effect again. (If you validate `.devflow/config.json` against
`config.schema.json`, the stale key is rejected outright by `additionalProperties: false`.) The
`devflow:checklist-*` keys are unchanged.

## Migration (v2.8.12): the final-pass reviewer key was renamed

**Breaking config change.** The `superpowers` plugin's `requesting-code-review` skill — the Phase-3
final-pass reviewer — was internalized as a first-party DevFlow skill (vendored under
`skills/requesting-code-review/`, seam 3 of the #139 internalization), so its `agent_overrides` key
was renamed to the `devflow:` namespace:

| Old key (pre-2.8.12) | New key |
|---|---|
| `superpowers:requesting-code-review` | `devflow:requesting-code-review` |

Same rename discipline as the v2.8.12 table above — a stale old key is not an error, but it silently
stops applying: the engine only ever dispatches the new `devflow:requesting-code-review` identifier,
so the resolver only ever reads the new key and never warns about the stale one. Renaming is the
only way to make the override take effect again. With this seam DevFlow has **zero** companion-plugin
dependencies.

## The nine configurable identifiers

The override keys are byte-identical to the subagent identifiers the engine dispatches under, so
config, dispatch, and the effectiveness trace stay aligned. The six Phase-3 keys appear verbatim in
the `phase3_dispatched` telemetry and in each finding's `agent`; the three checklist-phase keys
(`devflow:checklist-generator`/`-deduper`/`-verifier`) run earlier, at Phases 1/1.5/2, and so do not
appear in `phase3_dispatched`:

| Identifier | Phase | Notes |
|---|---|---|
| `devflow:checklist-generator` | 1 | Verification-checklist generation. |
| `devflow:checklist-deduper` | 1.5 | Cross-batch dedup (only when >1 generator batch). |
| `devflow:checklist-verifier` | 2 | One dispatch per agent-mode checklist item. |
| `devflow:code-reviewer` | 3 | Always-on. |
| `devflow:silent-failure-hunter` | 3 | Always-on. |
| `devflow:comment-analyzer` | 3 | Always-on. |
| `devflow:type-design-analyzer` | 3 | Gated — only when the diff adds/changes types. |
| `devflow:pr-test-analyzer` | 3 | Gated — only when the test-relevance predicate matches. |
| `devflow:requesting-code-review` | 3 | Final pass; a first-party skill dispatched as a `general-purpose` Task but keyed under this identifier. |

Plus the special `default` key (below).

## Shape

Each value optionally sets `model`, `effort`, and/or `iterations`:

```jsonc
{
  "devflow_review": {
    "agent_overrides": {
      "default": { "effort": "high" },
      "devflow:checklist-deduper": { "model": "claude-sonnet-4-6", "effort": "medium" },
      "devflow:code-reviewer": { "model": "claude-opus-4-8", "effort": "high", "iterations": "first-only" }
    }
  }
}
```

- `model` — free-form model id, forwarded to the dispatch as given (no *value* validation). A
  present-but-unusable model (empty string or non-string) is dropped with a `::warning::`, mirroring
  the invalid-effort path.
- `effort` — one of `low`, `medium`, `high`, `xhigh`, `max`.
- `iterations` — optional, **default-off**; the only valid value is `first-only`. An agent whose
  resolved override carries it is **excluded from the Phase-3 review roster on fix-loop iterations
  ≥ 2** — so it reviews only on iteration 1 of a `/devflow:review-and-fix` (and thus
  `/devflow:implement`) fix loop. It is a **roster-scoping** key, not a dispatch-time model/effort
  parameter: the resolver only reads it and passes a valid value through, and the exclusion itself is
  enforced engine-side in `skills/review/SKILL.md` Phase 3.1. In **standalone `/devflow:review`** (a
  single pass) and on **iteration 1** the key is a no-op — behavior is byte-identical to omitting it.
  It is also **never** applied to the Step 2.6 shadow fan-out, whose blinded audit always keeps the
  full roster. An out-of-enum value (or empty string) is dropped with a `::warning::`, mirroring the
  invalid-effort path; the run never aborts.

> **Claude Haiku rejects `effort`.** The `effort` parameter is supported only on Opus 4.5–4.8 and
> Sonnet 4.6; Claude Haiku rejects it with **HTTP 400**. So any entry that pins a Haiku model (a
> `claude-haiku-*` id) **must not** also carry an `effort` key. The shipped `devflow:checklist-deduper`
> override pins Claude Sonnet 4.6 (which *does* support `effort`) with effort `medium`, so it is exempt;
> the constraint matters if you re-pin a Haiku id there. The schema does not enforce this (it is a model-API fact, not a structural
> one), so the constraint is documented on the `devflow:checklist-deduper` property in
> `config.schema.json` and guarded by the shipped-example test in `lib/test/run.sh`.
>
> **Re-scaffold repairs stale configs.** Earlier releases shipped the deduper override *with* an
> `effort` key, so configs scaffolded before that was removed silently retain the HTTP-400 combo.
> The add-only config backfill cannot fix this — a key *removal* in the example never propagates to
> an existing config. Instead, `scripts/scaffold-config.sh` runs a best-effort, idempotent cleanup
> on every re-scaffold (`/devflow:init` or `install.sh`): it strips `effort` from *any*
> `agent_overrides` entry whose `model` is a Haiku id, leaving non-Haiku overrides untouched. An
> already-clean config is a quiet no-op (no file churn, no log line).

## This repo's `code-reviewer` application — baseline, revert trigger, deferred repricing (issue #425)

DevFlow's own tracked `.devflow/config.json` sets
`"devflow:code-reviewer": { "model": "claude-opus-4-8", "effort": "low", "iterations": "first-only" }`.
The `iterations` scoping was added on the evidence of replay study **R2** (2026-07-11): on this repo's
overwhelmingly `engine_self_modifying` diffs, `devflow:code-reviewer` measured **6.7% unique-effective**
(9 of 135 dispatches), **2 sole-source applied Importants across 129 dispatches**, and — the positional
finding — **zero sole-source applied findings after iteration 1** (61 late-iteration dispatches produced
nothing unique). Scoping the agent to `first-only` stops ~47% of its dispatches (the positionally-worthless
late ones) with no measured loss.

- **Revert trigger for the `iterations` key.** Any retrospective entry attributing an escaped
  Important-or-higher defect on this repo to a *late-iteration miss* in this agent's specialty class
  (guideline-adherence / doc-mirror) reverts the `iterations` key. Baseline for adjudication is R2 above
  (6.7% unique-effective, 2/129 sole-source, 0 sole-source late).
- **Deferred repricing (pre-registered follow-up).** Model repricing is deliberately deferred:
  `agent_overrides` model values apply identically to standalone `/devflow:review`, and the frozen-judge
  guardrail of the 2026-07-11 optimization methodology forbids repricing the outcome judge's roster
  mid-window. After the current experiment window closes, a follow-up PR reprices `model` from
  `claude-opus-4-8` to `claude-haiku-4-5-20251001` (the exact id, since the resolver forwards model
  strings unvalidated) **and drops the entry's `effort: "low"` key** — a Haiku id must not carry
  `effort` (see the Haiku HTTP-400 callout above), so the swap is not literally one line: the entry
  becomes `{ "model": "claude-haiku-4-5-20251001", "iterations": "first-only" }`. That follow-up
  carries its own trigger: any specialty-class escaped
  Important-or-higher finding on a PR reviewed under the repriced config within **4 retrospective weeks**
  (extended until **30 repriced dispatches**) reverts the model to `claude-opus-4-8`. A deterministic
  auto-revert mechanism was considered and rejected — no machinery exists to edit tracked config on a
  metric threshold, and building it is out of proportion to a one-line revert.

## Resolution rules

- **Entry-level precedence.** A subagent with its own entry uses **only** that entry; the
  `default` does **not** backfill its missing fields. The `default` entry supplies model/effort
  only for subagents that have no entry of their own. (So `code-reviewer: { model: m }` with a
  `default: { effort: high }` dispatches `code-reviewer` with model `m` and the **session** effort
  — not `high`.)
- **Explicit empty entry opts out of `default`.** An explicit empty entry (`"devflow:code-reviewer": {}`) counts as "has an entry": it sets neither model nor effort **and** does not inherit `default`. Use it to deliberately exclude one subagent from a broad `default` override.
- **No-entry fallback.** A subagent with **neither its own entry nor a `default`** is dispatched
  exactly as today — the global `claude_model` and the session effort — with **no per-agent
  `model` override supplied at dispatch** (a `session-inheritance` in the per-tier matrix above).
  Existing configs (which have no `agent_overrides` block at all) are therefore completely
  unaffected.
- **Invalid effort → warn + fall back.** An `effort` value outside the enum produces a
  `::warning::` and falls back to the session effort rather than aborting the run. A non-blank
  `model` string is forwarded as given; an empty, whitespace-only, or non-string `model` is dropped
  with its own warning.
- **Malformed shapes never abort.** A non-object entry (a hand-edited `"agent": "high"` or a list,
  which bypasses schema validation) is ignored with a warning and, on the engine-facing end-to-end
  path (`read_raw`), treated as no-entry — so `default` still applies. (A direct `resolve_overrides`
  call handed the same non-object entry skips it *without* applying `default`, since the entry's
  presence already counts as "has an entry"; operators only reach the resolver via `read_raw`, so the
  `default`-applies behavior is the one they observe.) A non-object `default` is likewise ignored. An
  entry that resolves to neither a model nor a valid effort emits no override at all. The engine never
  aborts on config shape.
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
- **`iterations` roster scoping (default-off).** An optional `iterations: "first-only"` key excludes
  its agent from the Phase-3 roster on fix-loop iterations ≥ 2 (enforced engine-side, not by this
  resolver). It obeys the same **entry-level precedence** as `model`/`effort` — a
  `default: { "iterations": "first-only" }` supplies it only to no-entry agents, and an agent's own
  entry does not inherit the `default`'s `iterations`. The resolver only **reads** the key and passes
  a valid value through the resolved map; an out-of-enum value (or empty string) is dropped with a
  `::warning::` and the agent then participates on every iteration (the run never aborts). Standalone
  `/devflow:review` has a single pass, so the key is a structural no-op there. An excluded agent is
  legitimately absent from that iteration's `phase3_dispatched` (like a gated-out analyzer). An entry
  carrying *only* `iterations` (no `model`/`effort`) still resolves.
- **Gated agents.** The two structurally-gated Phase-3 analyzers (`type-design-analyzer`,
  `pr-test-analyzer`) are only dispatched on applicable diffs; an override is emitted only for an
  agent actually dispatched in a given run.

## Version-skew safety of the `iterations` key (both directions)

The `iterations` key was added additively (issue #425); it is safe across a version skew between a
consumer's vendored resolver/schema and its `.devflow/config.json`, in **both** directions:

- **Old resolver, new config.** A resolver vendored before the key existed reads only `model`/`effort`
  and simply ignores an `iterations` entry key — so a config that carries `iterations` degrades to
  today's behavior (the agent participates on every iteration). No error, no abort.
- **New config, stale schema.** If you validate `.devflow/config.json` against a `config.schema.json`
  that predates the key, `additionalProperties: false` on each override entry **rejects** the unknown
  `iterations` key outright. The fix is to ship the schema version that declares it — the key requires
  the schema that ships it. (An unvalidated config is unaffected; validation is opt-in.)

## Mechanism — how model and effort actually reach a subagent (issue #554)

All nine subagents are **first-party DevFlow assets** (the three `devflow:checklist-*` and the
five vendored `devflow:` review agents under `agents/`, plus the vendored `devflow:requesting-code-review`
skill under `skills/`, dispatched via `general-purpose`). The engine resolves the overrides with
`scripts/resolve-review-overrides.py` (which reads the config through `config-get.sh`); each agent's
own `description`/`prompt`/`tools` come from its committed first-party definition (under `agents/`, or
`skills/` for the final-pass reviewer), with only the configured `model`/`effort` considered per run.

**Model and effort do NOT reach the subagent by the same path, and effort is not applied per-agent
on the path both tiers use today.** The review engine dispatches its subagents from an
**already-running session** via the **Agent tool**. That tool exposes a per-dispatch **`model`**
override parameter but **no effort parameter**, and an already-running session has **no per-dispatch
`--agents` injection**. So:

- a resolved per-agent **`model`** override IS delivered — supplied as the Agent tool's `model`
  override parameter at dispatch;
- a resolved per-agent **`effort`** override is **NOT** deliverable per-agent on this in-session path
  — the subagent inherits the **session effort**. This is reported honestly (a per-resolve
  `::notice::` summary from the resolver, distinct from `::warning::`), never claimed as applied.

Earlier releases of this doc and the engine described both model and effort as riding a per-run
`--agents` JSON block "for every subagent". That mechanism does **not** exist in an already-running
session — it was fictional for **model as well as effort** (model happens to be delivered by the
Agent tool's `model` parameter, a different, unstated mechanism). The description is corrected here;
"model behavior preserved" refers to model *delivery* (unchanged), not that old (false) description.

### Per-tier effort application-point matrix

Each dispatched review agent's effort decision carries an **application point** — one of four values:

| Application point | Meaning |
|---|---|
| `agent-definition` | The resolved per-agent effort was composed into a **proven** process-start agent-definition seam (an applied arm). This arm exists **only if** an empirical cloud-action seam spike proves the seam is reachable — see below; it is **not** shipped today. |
| `process-start-session` | The section-level session effort (`devflow.effort` / `devflow_implement.effort` / `devflow_runner.effort`) composed into `--effort` at process start — session-wide, inherited by all subagents, capability-gated by `providers.*.effort_supported` (#313). Not per-agent. |
| `session-fallback` | A resolved **per-agent** effort override the tier **cannot apply** (or a capability-restricted one). The override is not emitted; the agent inherits the session effort; the resolver reports the fallback with a reason. |
| `session-inheritance` | A dispatched agent with **no** per-agent effort override — it simply inherits the session effort. All-null effort block, no fallback reason. |

Per execution tier:

| Tier / dispatch context | Per-agent effort application point | Per-agent effort applied? |
|---|---|---|
| **Cloud** review — fresh `claude-code-action` process per run | `session-fallback` (see spike note) | **No** — the process-start `--agents` effort seam is **hypothesized but unproven** (no `--agents` usage exists in `.github/`); until a seam spike proves it, the cloud per-agent row is honest fallback identical to local. |
| **Cloud/local session effort** — `devflow.effort` / `devflow_implement.effort` / `devflow_runner.effort` | `process-start-session` | Session-wide, not per-agent — capability-gated by `effort_supported` (#313). |
| **Local** review — already-running interactive session dispatching via the Agent tool | `session-fallback` | **No** — the Agent tool carries `model` but no effort, and no per-dispatch `--agents` injection exists; the run reports the limitation and effective fallback with a reason. |

On any `session-fallback` arm the resolved per-agent effort is **not** applied; the subagent inherits
the session effort, and the run states the limitation and the fallback reason at resolution time. The
**effective** effort is recorded only when it can be read back from an applied/composed artifact — on
every in-session arm the engine cannot introspect its own session effort, so `effective` is **null**
(unknown is not zero), never guessed. Model overrides are delivered exactly as before on every tier.

**How the fallback is reported (per resolve, i.e. per dispatch phase).** `resolve-review-overrides.py`
distinguishes the *cause* so a genuine misconfiguration is never laundered into steady-state noise:

- a **benign** in-session no-seam fallback (a valid override the tier simply has no per-agent effort
  seam for — the permanent local/unproven-cloud steady state) is reported as **one informational
  `::notice::` summary** over all such agents (never one line per agent), distinct from `::warning::`;
- a **capability-restricted** fallback (the resolved model is a Claude Haiku id that rejects `effort`,
  or the routed provider's `effort_supported` is `false`) is a genuine unusable-model/provider
  misconfiguration, so it is a **`::warning::` naming the model/provider** — the same channel the
  resolver already uses for an invalid effort value or an unusable model.

The provider `effort_supported` capability is a **caller-supplied** input (`--effort-supported`, default
`true` — the Anthropic path): the in-session engine cannot introspect the routed provider's capability,
so the model-level Haiku restriction (read from the resolved model) is the capability guard active by
default, and a caller that knows the provider capability passes it in.

> **Scope of the Haiku guard: the *resolved override entry's* model, not the session model.** The
> guard reads the `model` of the entry `resolve-review-overrides.py` resolved for that agent. Because
> resolution is **entry-level**, a `default`-supplied Haiku *is* covered — an agent with no entry of
> its own resolves to the `default` entry, so the guard sees that Haiku id, exactly as the dispatch
> would. The one uncovered case is the **global** `claude_model` (or a per-section
> `devflow_runner.claude_model`) being a Haiku id while the agent's resolved entry carries `effort`
> but **no** `model`: the resolver reads only `.devflow_review.agent_overrides.*`, so it cannot see
> that session model and classifies the fallback as the benign `::notice::` rather than a capability
> `::warning::`. **The outcome message stays honest either way** — both arms report the effort as NOT
> applied and the agent as inheriting the session effort; only the *cause* bucket is imprecise.
> Closing it needs a caller-supplied session model (the tier decides which section supplies it, so
> the resolver cannot derive it alone) and is deferred follow-up work, not a silent gap.

> **Spike-gated applied arm (`agent-definition`).** A per-agent *applied* arm — composing the
> resolved effort into a process-start agent-definition the platform reads at launch — exists only
> where an empirical spike in the real `claude-code-action` proves the startup `--agents` effort seam
> is reachable AND governs a runtime Agent-tool dispatch. That spike is a deferred follow-up; until it
> proves the seam, **no per-agent effort application code ships** and every tier records honest
> fallback. On a proven applied arm the recorded `effective` would be the effort *composed into* the
> agent-definition — a spike-grounded proxy for the effort the dispatch reasons at, re-established by
> re-running the spike after a `claude-code-action` upgrade, **not** a per-run measurement.

The helper must be the command's **leading token** (the same cloud allow-list rule that governs
`workpad.py`); `OVERRIDES=$(…/resolve-review-overrides.py …)` is fine — the path is the leading
token inside the command substitution — but routing it through a shell variable or prepending a
`VAR=value` env-assignment makes the read-only cloud `review` profile deny it, and every override
silently resolves to `{}`. In the cloud review profile, `resolve-review-overrides.py` must also be
on the `review` tool allow-list for overrides to take effect (see
[cloud-setup.md](cloud-setup.md)); a local/interactive run is unaffected.
