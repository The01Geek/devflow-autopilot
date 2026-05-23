# `/devflow:implement` skill — Phase 2.3 sweep discipline

**Skill:** `skills/implement/SKILL.md` (Phase 2.3, *Implement*)

The `/devflow:implement` orchestrator runs a set of mandatory **sweeps** in Phase 2.3, after writing the
code and before running tests. Each sweep closes a class of blast-radius bug that survives `git diff`
review because nothing is *syntactically* broken — the affected lines still compile, parse, or run;
they are only *semantically* stale. This doc is the internal-docs counterpart of that section: it
records *why* each sweep exists so the skill text can stay terse.

## The sweeps

| Sweep | Triggers on | Closes |
|---|---|---|
| 2.3.0 Changed-contract | a change that **modifies** a signature, renames/moves a symbol, tightens a validator, or alters a classifying predicate | dependent sites left on the *old* contract (other predicate branches, sibling callers, fixtures/assertions) |
| 2.3.1 Orphaned-setup | a **deletion** of code | setup lines (a dependency fetch, lookup, computed local, import) whose only consumer was the deleted code |
| 2.3.2 Stranded-dependents | a **deletion** of a method, file, route, or page | references *outside* the diff the deletion stripped of purpose (callerless public methods, dead args, surviving inbound links) |
| 2.3.3 Convention-compliance | any code the diff **added or modified** | `CLAUDE.md` convention violations in touched code |
| 2.3.4 Boundary-assumption | any diff that **depends on** a fact about something it does not own | claims about a dependency version, the supported runtime, a sibling producer's output, or the real host that were asserted from memory instead of verified |

2.3.1–2.3.3 trigger on *deletion* or *addition*. **2.3.0** fills the gap for *modification*: changing a
contract is just as blast-radius-prone as deleting one, but it is harder to catch because every
dependent site still compiles. The common failure mode is fixing the originating site but not its
siblings — a predicate corrected in one branch but not the others, one caller that plumbs a new
per-request input while its sibling sharing the same object does not, or a fixture/assertion left
encoding the old contract. **2.3.4** is orthogonal to all of the above: it is not about the diff's own
consistency but about facts the diff *relies on* across a boundary it does not control.

## Changed-contract sweep (2.3.0) and the post-merge re-sweep

The skill spells out the three checks (predicate variants, sibling call sites, fixtures/assertions).
The *why*: the common failure mode is fixing the originating site but not its siblings — and those
siblings still compile, so `git diff` review misses them.

The sweep must also be **re-run after any merge or rebase of `main`** — the skill's Error Handling
conflict-recovery path (`git pull --rebase origin {branch}`) and anywhere else the run pulls in
`main`. A clean textual merge is not a clean semantic merge: `main` can arrive with a fixture, call
site, or assertion (often from a concurrently-merged PR) that the change's new contract now rejects,
merged cleanly with no conflict. A newly-arrived violating site is a defect in *this* PR, not a
follow-up.

## Boundary-assumption sweep (2.3.4)

The four boundary kinds and how to verify each are in the skill (and summarized in the table above).
The *why*: these bugs ship clean and pass the author's own tests — because the tests encode the same
wrong assumption — so a green run is not confirmation, and a test assertion *about* a boundary is
itself an unverified claim. A boundary that genuinely cannot be verified in-environment is never
asserted as true: it is recorded with a `--reflection` note and, only when a specific acceptance
criterion's verification depends on it, retagged `(post-merge)`.

## Scope boundary between Phase 2.3.2 and Phase 4.1

The 2.3.2 stranded-dependents sweep covers references in **code, config, and routing tables** — things
that break behavior at runtime if left dangling (a surviving `href` to a deleted page, a call site
still passing dead arguments). It does **not** cover prose references to the deleted symbols/paths
inside `docs/internal/` (descriptions, walkthroughs, install steps). Those are handled by the Phase
4.1 documentation pass, which spawns the `devflow:docs` subagent after the code is committed. If a
2.3.2 grep turns up only docs hits, the skill notes them and moves on rather than editing
`docs/internal/` from Phase 2.3 — the docs pass has the full picture (shipped code, not just the
plan) and the right mandate to update prose.
