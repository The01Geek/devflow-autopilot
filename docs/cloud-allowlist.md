# Cloud allowlist & command-shape reference

This is the detailed forensic record for the CLAUDE.md "cloud allowlist" gotchas
(issues #363, #561, #484, #455). The **operative invariants and their enforcing
pins stay in CLAUDE.md** — this doc carries the evidence, the war-stories, the
probe tables, and the reasoning that would otherwise bloat those bullets. When
CLAUDE.md says "see `docs/cloud-allowlist.md`", this is where it points.

Source-of-truth files referenced throughout (bare paths — line numbers rot):

- `lib/capability-profiles.json` — the versioned manifest, single source of truth.
- `lib/generate-capability-profiles.py` — the generator (`--check` gates CI).
- `lib/review-profile.tokens` — the review-tier security-boundary lock.
- `.github/workflows/matcher-probe.yml` — the re-runnable empirical evidence source.
- `.github/workflows/devflow-runner.yml`, `devflow.yml`, `devflow-implement.yml` — the runners whose allowlist literals are generated.
- `lib/test/extract-command-heads.py`, `lib/test/extract-command-shapes.py` — the desk/CI-time guards driven by `lib/test/run.sh`.

---

## The two allowlists (issue #363)

`skills/review/SKILL.md` — the shared review engine — executes under **two
different allowlists**, and a command head that **neither** grants is **silently
denied** (refused before it runs; it does not fail loudly, it burns budget, and a
run can end with **no verdict at all**).

- **Auto-review path**: the `review` profile's `TOOLS='…'` line in
  `.github/workflows/devflow-runner.yml`.
- **Manual `/devflow:review` comment path**: `devflow.yml`'s hoisted `TOOLS='…'`
  (the `Resolve allowed-tools` step, consumed by `claude_args` **and** by the
  injected block alike, so the two cannot drift).

A command the skill invokes but a profile omits is refused. **Evidence: PR #340 —
7 of 14 denials were the engine trying to run the test suite.** The engine ended
runs with no verdict because heads it needed were ungranted on one path.

### The head guard

`lib/test/extract-command-heads.py` (driven by `lib/test/run.sh`) extracts every
head from the skill's ```bash fences and asserts **each** allowlist grants it. The
extractor is:

- quote / comment / heredoc-aware,
- `$(…)`-descending,
- wrapper-stripping,
- **case-arm-position-aware** (issue #392): arm patterns are stripped only where
  an arm may legally begin — after `case … in` and after each `;;` — so a command
  in a case **body** (e.g. a bare subshell `(cmd)`) keeps its head instead of
  being swallowed as a bogus arm.

**Scope boundaries:**

- **Inline-backtick prose is deliberately out of reach** — matching it resurrects
  the `git a` / `git failure` / `git said` false positives. A prose-only command
  like Phase 0.3.6's `git cat-file` is pinned by **direct literal** instead.
- The case-arm tracking is a **flag, not a depth counter**, so a **nested** `case`
  block is an accepted limitation — no fence in `skills/review/SKILL.md` nests a
  `case`.

### Adding a command to a fence

Grant it by adding the token to `lib/capability-profiles.json` (the versioned
manifest) and regenerating with `python3 lib/generate-capability-profiles.py`.
The `--check` mode wired into `lib/test/run.sh` turns any manifest↔literal drift
RED before merge — you **never hand-edit** the `TOOLS='…'` literals. See
[Manifest generation](#manifest-generation-issue-561).

`Bash(cd:*)` is **deliberately ungranted**: its probe row was redirect-confounded
(unproven), and it is pinned **absent** in `run.sh`. Do not re-add it without a
fresh redirect-free probe row.

---

## Heads vs shapes (issue #401)

**Heads are not enough.** The matcher denies composite **SHAPES** whose every head
is granted. **Evidence run 29105381021: 22 denials, no verdict.**

Refused shapes in the cloud **review** runner:

- leading `VAR=value` assignments,
- leading `cd`,
- `>` / `2>` redirects targeting `/tmp`,
- `cat`-heredoc writes,
- interpreter heads (`python3`),
- the unexpanded `"${CLAUDE_SKILL_DIR:-…}"` anchor as the **leading** token.

Probe-proven **permitted** shapes (review tier):

- the **Write tool** into `.devflow/tmp/**` (granted in the review profile),
- `… | tee`,
- `tee <<'EOF'`,
- repo-relative **vendored-literal** helper paths.

The skill's "Cloud command-shape discipline" section and the grounding block's
command-shapes section carry the recipe. **Rule of thumb: two denials of a shape →
switch to a permitted alternative, never iterate variants.**

`lib/test/extract-command-shapes.py` (driven by `lib/test/run.sh`) turns a
denied-shape fence RED at the desk.

`.github/workflows/matcher-probe.yml` (repo-internal; **not** shipped by
`install.sh`) is the re-runnable evidence source — **re-run it after a
`claude-code-action` upgrade** before changing shape rules or grants (matcher
semantics are version-dependent).

---

## Probe evidence (review tier)

The review-tier `probe` job in `matcher-probe.yml` composes `--allowed-tools =`
the generated review-profile literal **plus candidate grants under test**, runs a
Haiku `claude-code-action` session that attempts each corpus shape once, and
computes a per-shape PERMITTED / DENIED / UNATTEMPTED verdict **deterministically**
from the action's execution file (`permission_denials` + recorded `tool_use`
calls) and on-disk side-effect files. **The model's own text output is never the
measurement.**

The abstract review-tier rule set is R1–R4 (leading-assignment / leading-`cd` /
`/tmp`-redirect / heredoc-write families), enforced by
`extract-command-shapes.py`. Notable recorded verdicts:

| Candidate | Verdict | Note |
| --- | --- | --- |
| `Bash(cd:*)` | DENIED | Row confounded by an independently-denied `>` redirect — **unproven**, kept for a redirect-free re-probe, pinned absent in `run.sh`. |
| `Write(/tmp/**)` | DENIED | Genuine out-of-workspace denial. |
| `Bash(scripts/*.sh:*)` (trailing-extension glob, issue #412) | DENIED — run **29135163829** (PR #413) | Even with the glob granted, `scripts/config-get.sh …` was refused (same DENIED as the ungranted control) → the trailing-extension glob does **not** match a repo-root leading token; the implement profile keeps the enumerated `*/<basename>.sh` helper globs; **no migration to `scripts/*.sh`**. |
| `Write(.devflow/tmp/**)` | PERMITTED | Landed as a grant from the probe's **first run, 29111394360**. |

Positive-control note (issue #477): the review verdict counts a
`permission_denials` match as DENIED **ahead of** `tool_use`, so an unrelated
`/etc/hosts` read (attempted by the model with a `Bash(grep:*)` grant) can make the
row-11 control read DENIED. The sibling probe jobs score their controls
differently and are unaffected.

---

## Probe evidence (implement tier) (issue #455)

The read-write `devflow-implement` profile is a **separate allowlist** with its
**own** probed denied shapes — **a shape proven on the review tier is unproven
here** — so the `implement-probe` job in `matcher-probe.yml` covers it
independently. Its abstract rule set is IR1 / IR2 / IR3 (distinct from review's
R1–R4), enforced by `lib/test/extract-command-shapes.py --profile implement`
against `skills/implement/SKILL.md` and `skills/implement/phases/*.md`.

### The recorded implement-tier table (rows I1–I6)

The original attribution-split run (issues #450/#455) proved:

| Row | Shape | Verdict |
| --- | --- | --- |
| **I1** | unexpanded `${CLAUDE_SKILL_DIR:-…}` anchor as the leading token | DENIED |
| **I2** | explicit **vendored-literal** grant form, measured on `apply-labels.sh` | **PERMITTED** (real recorded `tool_use`) |
| **I3** | config `*/basename` glob against a vendored-literal leading token, measured on `ensure-label.sh` | DENIED (the glob did not match) |
| **I4** | `for …; do …; done` wrapping a label helper | DENIED |
| **I5** | piped `while read` loop wrapping a label helper | DENIED |
| **I6** | `VAR="$(…)"` capture of a label helper (confounds label-helper + capture + inner `2>&1`) | DENIED |

**I3 is the whole reason the explicit grants had to ship.** Read it as "the glob
form was refused", **not** as "`ensure-label.sh` is unreachable". Stage B (#455)
then shipped both halves — the explicit vendored-literal grants in
`devflow-implement.yml` **and** the call-site rework — so the split is retired and
the job now measures the **real shipped profile end-to-end**.

### The issue #571 re-measurement (rows 1–16)

Observed 2026-07-18 UTC (issue #571): user-directed `workflow_dispatch` run
**29623046995**, `implement-probe` job **88021801138** (completed success before
the workflow's intentional cancel-probe cancellation), at commit
`f2162d7683bc7a352fce4efce3f092e864aab8b9`. **An autonomous implement run cannot
discharge this evidence gate without explicit human direction.** The execution-file
verdict table:

```
 1 DENIED      2 PERMITTED   3 PERMITTED   4 DENIED
 5 DENIED      6 DENIED      7 PERMITTED   8 PERMITTED
 9 DENIED     10 DENIED     11 PERMITTED  12 PERMITTED
13 PERMITTED  14 DENIED     15 DENIED     16 DENIED
```

Every row recorded `tool_use=yes`; rows with a shape discriminator recorded
`shape=ok` — so none of the #571 rows was REFORMULATED or UNATTEMPTED. In this
re-measurement rows 2/3 are PERMITTED because the shipped profile now carries
**both** the explicit grant and the glob for each label helper, so a PERMITTED
there proves the leading-token call **runs** but attributes to **neither form**
(I3's recorded glob denial remains the standing evidence that the glob does not
match a vendored-literal leading token).

### Rows 8/9 — the non-label-capture disambiguators

The `VAR=$(…)` capture carve-out (the phase-4 fences read `deferred.labels` that
way) is exempted on the **reasoning** that the matcher descends into the
substitution — **but this is an INFERENCE, not a measurement.** The only measured
capture row (I6) came back DENIED while confounding three properties (label
helper + capture + inner `2>&1`).

- **Row 8** — `VAR=$(…)` capture of a **non-label** granted helper, bare spelling
  (the disambiguator for descent). A PERMITTED means the matcher descends into a
  non-label substitution and I6's denial is label- or redirect-attributable.
  (Note: the fences actually emit the capture inside an `if !` compound, which
  remains unmeasured — a PERMITTED settles the descent question, not the fences'
  exact statement shape.)
- **Row 9** — redirect-free `VAR="$(…)"` capture of a **label** helper (identical
  to I6 but without the inner `2>&1`). Read with rows 6 and 8, it separates "the
  capture shape is denied" from "the inner redirect is denied" from "a label
  helper inside a substitution is denied".

**Until a dispatch records rows 8/9, do NOT cite the carve-out as probe-proven,
and keep every phase that depends on such a capture fail-closed** — *no output at
all* is a possible denial, never an empty value.

### Re-deriving the I2/I3 per-form attribution

The shipped profile now carries **both** the explicit grant and the `*/basename`
glob for each label helper. If an upgrade ever needs the per-form verdicts
re-measured, **re-split TEMPORARILY in a scratch branch** — grant `apply-labels.sh`
only explicitly and `ensure-label.sh` only via the glob, as the original run did —
dispatch, record, and **revert**. Do not leave the split in: it makes the job
measure a profile the repo does not ship.

Multi-operation statements (`A; B`, `A && B`) are deliberately excluded from the
probe: shipped implement phase fences already exercise them successfully, so
another row would be redundant rather than new evidence.

---

## Grants are per-HEAD across the whole pipeline (the `paste` war-story)

A repo rule from #363/#401 (**not** an implement-probe row): **grants are
per-HEAD across the whole pipeline, not just the leading token.** One ungranted
head in a tail refuses the entire statement, and it produces **no output**.

**War-story:** `paste` is granted nowhere. An in-PR draft of the reworked fences
ended the label **normalizer** in `| paste -sd, -`, which would have refused that
normalizer statement outright — leaving the resolved labels non-empty but the
**normalized list empty**, so the applies silently did nothing (caught at the
desk). Use the granted `tr` / `sed` / `grep` instead.

Consequence for the label call sites: `devflow-implement.yml`'s baked literal
grants `apply-labels.sh` / `ensure-label.sh` explicitly, and **all four label call
sites** — Phase 3.1's `DevFlow` provenance apply, Phase 4.0/4.0.5's
`deferred.labels` applies, and Phase 4.1's `Documented` apply — are reworked to
**agent-level single-leading-token calls that read their inputs from printed tool
output** (a shell variable does not survive into a later separate command).

Row I1 (the unexpanded anchor) is **not lint-pinnable on either tier** — every
legitimate helper call keeps the portable `${CLAUDE_SKILL_DIR:-…}` anchor in
source (#275) and resolves it at runtime — so it stays **prose-discipline**.

---

## Implement-profile head guard + inline-engine surface (issue #484)

Phase 3 of `/devflow:implement` runs the review engine **inline** under
`devflow-implement.yml`'s baked `--allowed-tools` (**not** the review profile), so
**every helper the normal inline flow can reach needs an implement-profile
grant** — the review engine is shared.

`lib/test/run.sh`'s #484 head guard deliberately **over-approximates** that runtime
surface. It drives `extract-command-heads.py` in an **`implement-block` parse
mode** that reads **ONLY** the baked `--allowed-tools` block — never the whole file
or `.devflow/config.json`, so a `Bash(...)` cited in a YAML comment is **not** a
grant; it fails **closed** on an absent/malformed block. It runs over all fenced
source in:

- `skills/implement/**`,
- `skills/review*/**`,
- the dispatched `skills/requesting-code-review/**` final pass,
- including standalone-only review **Phase 4.4**.

It fails when an audited fenced head is neither granted nor in the exact withheld
list (`gh pr checkout`, `git rev-list`, `mktemp`). A separate suppression list
covers shell builtins + parse artifacts, and a **removal-proof contract** requires
inline `workpad.py` shorthand to **expand to the portable granted helper path**
before emission.

---

## Manifest generation (issue #561)

The five runner/probe allowlist literals are **GENERATED from one versioned
manifest — never hand-edit them.**

### The manifest

`lib/capability-profiles.json`:

- integer `manifest_version`,
- named token `groups`,
- a `readme`,
- exactly the `review` / `implement` / `command` profiles, each composing group
  refs (`@core_review`, `@unix_text_common`, …) + inline tokens into flat ordered
  lists.

Groups are shared across profiles **only where the contiguous token runs are
genuinely identical**; most runs are per-profile.

### The five generated regions

`python3 lib/generate-capability-profiles.py` compiles the manifest into exactly
**five** regions:

1. `devflow-runner.yml`'s **review** `TOOLS='…'`,
2. `devflow.yml`'s **command** `TOOLS='…'`,
3. `devflow-implement.yml`'s `--allowed-tools` **base list** — up to the
   `${{ needs.config.outputs.allowed_tools_extra }}"` splice, which is preserved
   **verbatim** (consumer-facing surface),
4. `matcher-probe.yml`'s `REVIEW='…'` baseline,
5. `matcher-probe.yml`'s `IMPLEMENT='…'` baseline.

Each region carries a **banner comment** with `manifest_version` + the **sha256**
of that region's resolved token list. The banner is placed where it is
syntactically inert and **never contains the byte sequence `TOOLS='`**.

The generator is **python3 stdlib-only** (no `yaml`), reads **no git history**, and
has **no runtime footprint** (a `run.sh` assertion greps the six workflows for zero
non-comment references to it — desk/CI-time only, mirroring
`extract-command-heads.py`). Every defect (malformed manifest, missing/duplicated
anchor, unreadable/unwritable target, a review list that drifts from the lock)
exits **non-zero with a stderr breadcrumb** and leaves every target byte-unchanged
(fail-closed).

### `--check` gates CI

`python3 lib/generate-capability-profiles.py --check` (wired into
`lib/test/run.sh`, so the required **`lib + python tests`** CI job gates it)
byte-compares every region and turns any drift RED with a token-level
**directional** diff — a hand-added workflow token is named as **workflow-side**
with "add it to the manifest and regenerate" (blind regeneration would silently
revert the grant). It exits 0 with empty stdout when every region matches.

### The review-profile security boundary + the lock

**The review profile is a security boundary:** the generated review literal **IS**
the read-only reviewer allowlist (the deny floor filters only appended consumer
extras, **never the base**). So `lib/review-profile.tokens` **locks its exact
resolved token list** — the generator **never writes** it, and **any** manifest
edit (including to a shared group) that changes the resolved review list **fails
closed** until you update that lock **in the same PR**. Widening the reviewer
therefore always needs a **visible diff**.

An **implement-only** grant leaves the review boundary untouched, so
`lib/review-profile.tokens` and the review-region checksums stay byte-identical and
only `manifest_version` moves.

### The `manifest_version` bump rule

**Increment `manifest_version` exactly once in any PR that changes the manifest.**
This is a **review convention, not machine-enforced** (the generator reads no git
history); the **per-region checksums are the machine truth**.

### What stays hand-maintained

Empirical territory is **NOT** generated — the manifest states **policy**, never
**measurement**. The probe's candidate rows, verdict tables, command-shape
verdicts, and the `EXTRAS` config-mirror row in `matcher-probe.yml` stay
hand-maintained.

**Adding a grant** = edit the manifest (+ the lock if it widens review) →
regenerate → the same `--check` gate covers what the retired #450 token-sync pin
used to, plus the review-tier equality that never had a pin.

---

## Grant flows

### Review / command tier

Add the token to the relevant profile in `lib/capability-profiles.json`,
regenerate, update `lib/review-profile.tokens` in the same PR **if** the resolved
review list changes, bump `manifest_version`. Never hand-edit the workflow
literals.

### Implement-tier bundled-helper grant flow (issue #555)

A bundled helper that a `/devflow:implement` fence invokes — the §4.0.5-class
case, e.g. `scripts/discover-deferral-manifests.py` — is granted by adding its
vendored-literal token
`Bash(.devflow/vendor/devflow/scripts/<helper>:*)` (the **row-I2-proven** explicit
leading-token form) to the `implement` profile in `lib/capability-profiles.json`
and regenerating. That **one edit** rewrites:

- `devflow-implement.yml`'s baked `--allowed-tools` baseline, **and**
- `matcher-probe.yml`'s `IMPLEMENT` baseline

in lockstep — so the probe's baseline can never drift from the tier it is probing —
and the generator's `--check` (driven by
`lib/test/modules/capability-profiles.sh`) enforces it. **Never hand-edit either
workflow literal** to add such a grant.

### The install.sh-vs-vendor-fetch skew warning

The **workflow grants** ship to consumers via `install.sh` **file-copy**, while the
**skill rework** ships via the `devflow_version` **vendor fetch**. These are **two
independently-updated artifacts** whose skew silently **re-denies the applies**, so
**the two halves must be upgraded together** (docs: `docs/install.md`,
`docs/DEVFLOW_SYSTEM_OVERVIEW.md`).
