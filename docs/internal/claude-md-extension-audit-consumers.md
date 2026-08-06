# CLAUDE.md / prompt-extension machine-reader enumeration (issue #1352 AC3)

This is the **AC3 consumer enumeration** for issue #1352: an exhaustive, verified inventory of every
MACHINE reader (`.py`, `.sh`, `.jq`, `.yml`) that depends on a heading, marker comment, or distinctive
literal in `CLAUDE.md` and the `.prflow/prompt-extensions/*.md` surfaces likely to be moved, compressed,
renamed, or split by this audit. Each consumer below records the exact literal/heading it reads, the
`file:line` it reads it at, and the failure mode if the audit changes that surface without updating the
reader in the same commit — classified as **silent truncation** (a reader that quietly extracts the wrong
or empty content), **loud pin failure** (a suite assertion that turns RED at the desk / CI), or
**proximity** (a section/heading-relative rule that breaks when a paragraph crosses a heading boundary).
Both suite pins and non-pin runtime readers are covered, and `lib/test/modules/*.sh` is swept alongside
`lib/test/run.sh`. All named consumers were confirmed to still exist as of this writing.

---

## 1. `scripts/render-audit-prompt.py` — heading + `dim-key` section extractor (runtime, non-pin)

Reads `.prflow/prompt-extensions/create-issue.md` by **literal heading**. This is the authoritative
owner of the heading-extraction rule (per `skills/create-issue/references/step-2-clarify.md`).

- `scripts/render-audit-prompt.py:161-163` — `_HOOKS = {"audit-dimensions": "## Audit dimensions", "evidence-axes": "## Evidence axes"}`. These two exact heading strings are the extraction keys.
- `scripts/render-audit-prompt.py:188` — `_DIM_KEY_TOKEN = "dim-key:"`; the `<!-- dim-key: <lowercase-kebab> -->` declaration markers pair each `## Audit dimensions` bullet with a stable key (parsing at lines ~1037-1208).
- Section-span rule (documented at `render-audit-prompt.py:463-534`, `981-985`, `1140-1282`): a section spans its heading line to the **next line beginning `## `** (two hashes + space), else to EOF; an inserted `## ` heading therefore **truncates** the section.

**Failure mode: silent truncation.** Renaming/rewording either heading makes `_HOOKS` extract nothing (empty section == absent heading), so the auditor prompt is rendered without the consumer dimensions/axes. Inserting a new `## ` heading mid-section silently cuts the section short. Moving a `dim-key` marker away from the bullet it declares raises `RenderError` (loud) or misbinds the key. `### ` sub-headings do NOT terminate — only `## `.

## 2. `scripts/load-prompt-extension.sh --section` — independent second extractor (runtime, non-pin) + its module

A sibling `--section` implementation invoked at runtime by the create-issue skill against `## Evidence axes`.

- `scripts/load-prompt-extension.sh:6,231-279,447-453` — the `--section '<## heading>'` flag; matching is EXACT on the full heading line (so `## Evidence axes <!-- note -->` is selected by the full line, not the bare heading). Reads `.prflow/prompt-extensions/create-issue.md`.
- `skills/create-issue/references/step-2-clarify.md:39,41` — runtime invocation: `load-prompt-extension.sh create-issue --section '## Evidence axes'`, re-run fresh at Step 2 forwarding and at each bundle-coverage gate site. Step 3.6 consumes `## Audit dimensions` via the renderer's splice.
- `lib/test/modules/prompt-extension-reader.sh:468-477` — drives the live `create-issue` extension through BOTH hooks (`## Audit dimensions`, `## Evidence axes`) and asserts each extracts non-empty AND that **neither hook leaks the other's section** (the dual-hook independence contract).

**Failure mode: silent truncation** at runtime (absent-heading breadcrumb → treated as "no consumer section"); **loud pin failure** in `prompt-extension-reader.sh` if a heading is renamed (extraction goes empty → the non-empty assertion fails) or if a section boundary is broken so one hook captures the other's heading (the cross-leak assertion fails).

## 3. `lib/test/run.sh` `#506` / `#719` block — byte-identity, three-file lockstep, absence sweeps (suite pins)

Block at `lib/test/run.sh:26305-26930`. Surface vars: `WSR_IMPL=implement.md`, `WSR_RAF=review-and-fix.md`, `WSR_REV=review.md`, `WSR_CLAUDE=CLAUDE.md`.

- **Byte-identity** (`26889-26896`): the entire `## Prompt-surface edit routing evidence gate` section (heading → EOF) of `review-and-fix.md` must be **byte-identical** to that of `review.md`. Heading pinned present-and-unique first (`26889-26892`) so the equality can't pass vacuously on two empty extracts.
- **Operative-sentence pins**: implement.md `'the orchestrator dispatches a context-isolated Agent-tool subagent whose prompt instructs'` (`26878-26879`); review-and-fix.md + review.md both `'the review reports a **FAIL** finding naming'` (`26882-26885`); CLAUDE.md `'Autonomous \`/devflow:implement\` runs satisfy this mandate differently'` (`26900-26901`).
- **Three-file lockstep literals** (`26380-26388`, `26908-26918`): `WSR_TGL` trigger-glob list (`` `skills/*/SKILL.md`, `skills/implement/phases/*.md`, `skills/implement/references/*.md`, `skills/review/phases/*.md`, `skills/review-and-fix/references/*.md`, `.prflow/prompt-extensions/*.md` ``) must be identical across implement/review-and-fix/review; `WSR_MARK='Writing-skills evidence:'` must be present in implement.md's contract and both review gate copies.
- **Zero-occurrence ABSENCE sweeps** — `_WSR_RETIRED_LITS[]` (`26449-26461`, retired-convention phrases e.g. `'A focused result discharges no gate'`, `'A focused result is never a completion gate.'`, `'Before a commit, phase completion, push, or'`, …) swept to 0 hits across implement.md, review-and-fix.md, **receiving-code-review.md**, CLAUDE.md, `docs/internal/DEVFLOW_SYSTEM_OVERVIEW.md`, CONTRIBUTING.md (loop at `26490-26491`); plus the `#719` undefined-disjunct sweeps (`26866-26875`): `'module or path'` == 0 in implement.md/review-and-fix.md/receiving-code-review.md/overview, `'focused path'` == 0 in CONTRIBUTING.md. `#719` also carries a per-member baseline-corpus control against blob ref `607ec800`.

**Failure mode: loud pin failure.** Renaming the gate heading breaks the heading pin and empties the byte-identity extract; letting the two review copies diverge breaks byte-identity; editing the trigger-glob list or evidence marker in only some of the three files breaks lockstep; re-introducing any retired phrase anywhere in the six-file set turns the sweep RED.

## 4. `lib/test/lint-subagent-extension-handoff.py` — section-proximity rule (suite lint)

Splits a file into sections at markdown headings (`#`..`######`), each section owning only its **own** lines (heading through the next heading of ANY level — a nested subsection is a separate section). A section is a candidate when it contains BOTH a dispatch token AND a skill reference **in the same section** (`lint-subagent-extension-handoff.py:41-93,260-316`).

- `declared_non_dispatch` registry is **keyed per `(dispatcher-path, section-heading)`** (`:89-104`); a stale entry (naming a section the scan no longer flags) is itself a failure.
- Registry file `lib/subagent-dispatch-sites.json`: `schema_version:1`, a `sites[]` array (dispatcher/skill/handoff), and `"declared_non_dispatch": []` (currently empty, line 30).

**Failure mode: proximity.** Moving a paragraph across a heading boundary re-scopes which section owns the token/reference conjunction — a token and reference that were co-located can split into two sections (or two that were split can merge), changing candidacy. A `declared_non_dispatch` waiver keyed on a heading breaks the instant that heading is renamed or the paragraph moves out from under it.

## 5. `lib/test/modules/create-issue-contract.sh` — hardcoded bullet-count assertions (suite pins)

Counts `^- **`-shaped bullets within a heading-delimited section of `create-issue.md` (`CI_EXT`) via `awk '/^## Heading/{f=1;next} /^## /{f=0} f' | grep -c '^- \*\*'`:

- `create-issue-contract.sh:758-759` — `## Audit dimensions` section == **9** dimension bullets (`#467 D3`, re-scoped by `#548`).
- `create-issue-contract.sh:766-767` — `## Evidence axes` section == **6** axis bullets (`#548`).
- Related template count (`CI_TMPL_AUDIT`) `:715` — `**Audit dimensions` → `{CONSUMER_DIMENSIONS}` range == **10** bullets, with START/END line-anchor pins at `:711-714` and END-anchor existence pin `:707-708`.
- Heading-presence pin `:222-223` — `'## Audit dimensions'` present-and-unique in `CI_EXT`.

**Failure mode: loud pin failure.** Adding/removing a dimension or axis bullet without updating the count literal turns the suite RED; renaming a heading empties the `awk` range (count → 0) and fails; inserting a stray `## ` heading inside the section truncates the count.

## 6. All CLAUDE.md / review-and-fix.md pin calls across `run.sh` AND `lib/test/modules/*.sh`

CLAUDE.md is reached via `$LIB/../CLAUDE.md`, `$WSR_CLAUDE`, `$E711_CLAUDE`, and (in modules) `$CI_CLAUDE = $CI_ROOT/CLAUDE.md`. Each pin below is an exact literal that must survive verbatim in CLAUDE.md.

`lib/test/run.sh`:
- `2758-2759` — `$SIXSHAPE_SET` (six-shape valid-falsy matrix set) present in CLAUDE.md's best-effort-parser gotcha.
- `4384-4385` — `'is made **directly by the orchestrator**, citing this carve-out and recording it in the workpad, **never** by invoking'` (#366 carve-out).
- `4393-4394` — `'whether by a Phase-3 review finding **or by the issue'` (#366 AC4 widening).
- `26900-26901` — `'Autonomous \`/devflow:implement\` runs satisfy this mandate differently'` (#506, via `$WSR_CLAUDE`).
- `26272-26274` — `$SP_PAT_WRI_DEV` present AND `'devflow:writing-skills'` absent in CLAUDE.md (writing-skills mandate).
- `42845-42846` — `'sources its population from an index-reading \`git ls-files\`'` (#711, via `$E711_CLAUDE`; carries `# structural-pin-ok: helper-contract`).

`lib/test/modules/capability-profiles.sh` (targets `$LIB/../CLAUDE.md`):
- `374-375` — `'Implement-tier bundled-helper grant flow (issue #555)'`.
- `376-377` — `'**Never hand-edit either workflow literal** to add such a grant.'`.

`lib/test/modules/create-issue-contract.sh` (targets `$CI_CLAUDE`):
- `737-738` — `'The governed surface is broader than config JSON'` (#467 D2 CLAUDE.md leg; same literal also pinned in the implement-skill bundle `$CI_IMPL_BUNDLE` at `:739-740`).
- `758-759` — `'in-PR-inert and post-merge-only'` (#593 grant-timing gotcha).

`lib/test/modules/review-and-fix-contract.sh` — module-private `_raf_pin_unique` wrapper pins against `RAF_EXTENSION = .prflow/prompt-extensions/review-and-fix.md`:
- `178-179` — `'lib/test/run-module.sh review-and-fix-contract'`.
- `180-181` — `'automate changed-file-to-module routing'`.
- `182-183` — `'A nonempty skip tally is not clean.'`.
  (The same wrapper also pins `RAF_SKILL`, `RAF_REVIEW_BUNDLE`, `RAF_RECEIVING_SKILL`, and the overview page; those are review-engine surfaces, not the extension.)

**Failure mode: loud pin failure.** Rewording, moving between files, or renaming any pinned CLAUDE.md / review-and-fix.md literal turns the required `lib + python tests` check RED. Note `assert_pin_unique` also fails if the literal becomes **non-unique** (appears twice), so duplicating a sentence during a "split" also breaks it.

## 7. Trusted prompt-extension materialization + dispatch-namespace guards (workflow + suite)

- `scripts/materialize-trusted-prompt-extensions.sh` — populates the review tier's trusted prompt-extension closure from the base ref; reads `.prflow/prompt-extensions/${name}.md` (`:136`) for each protected NAME. It reads the extension **files by name**, not their headings.
- `DEVFLOW_PROTECTED_PROMPT_EXTENSIONS` job env:
  - `.github/workflows/devflow-runner.yml:199` — `"review requesting-code-review"` (consumed at `:381`, `:803`).
  - `.github/workflows/devflow.yml:766` — `"pr-description receiving-code-review requesting-code-review review review-and-fix"` (consumed at `:961`).
- Two `run.sh` drift guards assert the declared protected set equals the extension names actually loaded via `load-prompt-extension.sh <name>` from the dispatched skill trees:
  - `run.sh:21276-21300` (#874) — devflow-runner.yml `run` job set vs names reachable from `skills/review/`.
  - `run.sh:21640-21665` (#1075) — devflow.yml `command` job set vs names from `skills/review`, `skills/review-and-fix`, `skills/pr-description`. Regex: `^(?:"[^"]*"|\S)*?/load-prompt-extension\.sh\s+([A-Za-z0-9][A-Za-z0-9._-]*)`.
- `lib/test/lint-subagent-dispatch-namespace.py` — audits `.prflow/prompt-extensions/*.md` (`_EXTENSION_RE`, `:91`) for `<namespace>:<leaf>` subagent references, failing when a dispatchable leaf carries a non-canonical namespace (`:103-106`).

**Failure mode: mixed.** **Renaming a prompt-extension FILE** (e.g. splitting `review.md`) without updating `DEVFLOW_PROTECTED_PROMPT_EXTENSIONS` and the skill's `load-prompt-extension.sh <name>` call: the materializer silently produces no file for the renamed name (`::warning::`, reviewer runs with no extension text — **silent-ish at runtime**), and the #874/#1075 drift guards turn **RED** at the desk if the declared set and the loaded names diverge. Renaming the plugin namespace inside an extension without sweeping references is caught **loud** by `lint-subagent-dispatch-namespace.py`.

---

### Cross-cutting audit cautions

- The two `## Audit dimensions` / `## Evidence axes` headings in `create-issue.md` are read by **four** independent machine consumers (render-audit-prompt `_HOOKS`, load-prompt-extension `--section`, prompt-extension-reader module, create-issue-contract bullet counts) — renaming either heading breaks all four, some silently (extractors) and some loudly (counts).
- The `## Prompt-surface edit routing evidence gate` heading anchors a **byte-identity** extract across two files; any edit must be applied identically to review.md and review-and-fix.md in the same commit.
- CLAUDE.md pins use `assert_pin_unique`, which is sensitive to both **absence** and **duplication** of the pinned sentence — a compression pass that de-duplicates prose can break a uniqueness pin.
