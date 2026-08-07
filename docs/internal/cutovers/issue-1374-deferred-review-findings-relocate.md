# Cutover — issue #1374: Phase 4.0.5 relocated behind a predicate-gated reference

`/prflow:implement` reads `skills/implement/phases/phase-4-documentation.md` in full on every
Phase 4 entry, and again after the §4.1 documentation subagent returns. Both reads are
mandated by the always-resident orchestrator, so neither is avoidable. §4.0.5's filing
procedure — which runs only when Phase 3.3 produced a deferrals manifest — was paid on every
one of those reads regardless, because the decision to skip it is one the agent makes *after*
reading it.

This change applies §4.0's shape (issue #815) to the other deferral channel: a short stub in
the phase file, one predicate, and a gated reference read only when the predicate says a
deferred review finding is present.

## Measured delta (a past-time snapshot, counted with `wc -c` at commit `42f894af6`, captured 2026-08-07)

| File | Before | After |
| --- | --- | --- |
| `skills/implement/phases/phase-4-documentation.md` | 95,988 | 68,764 |
| `skills/implement/references/deferred-review-findings.md` | — | 30,316 |

The phase file is the always-read surface, so the always-read count falls from 95,988 to
68,764 bytes per mandated read — 27,224 fewer, and 54,448 fewer across the two reads a Phase
4 run makes. These figures are a **past-time snapshot**, not a live measurement: they record
what the move cost at the moment it was made, so a later change to either file does not
retroactively falsify the record. **No byte ceiling on either file is enforced anywhere in
the tree**, and this page registers none — the same correction this change made to the #815
cutover page, which had described such a gate as live.

## The predicate's three-state contract

`scripts/discover-deferral-manifests.py --presence-for-pr N` answers over **both** presence
sources — the run-scoped manifests it discovers under the candidate search directories, and
the slug-level aggregate at `pr-<N>/deferrals.json`. Reading either alone fails open: on a
first Phase 4 entry the aggregate has no producer, and on a re-entry after filing the
run-scoped manifests are already consumed.

| State | Exit | stdout |
| --- | --- | --- |
| present | `0` | `present: <n>` |
| absent | `1` | `absent: 0` |
| unestablished | `2` | `unestablished: reason=<token>` (plus an optional `root:` line) |

Every state is decided from the process exit status alone; nothing parses stdout to route. A
malformed invocation reports `2`, the same fail-closed convention `scripts/workpad.py
deferred-presence` adopts, so a bad call loads the reference rather than silently skipping it.

## Accepted loss: partial and all-failed collapse into unestablished

The helper's discovery mode distinguishes a *partial* traversal failure (`3`) from a *total*
one (`4`). Presence mode does not: any unreadable candidate directory or unreadable aggregate
reports `2`, whether one candidate failed or both. That distinction is genuinely lost, and it
is taken deliberately so both gated Phase 4 sub-steps document one identical three-state
contract a reader learns once. The cost is bounded — the stub's response to `2` is to read the
reference, which is the same response it would give to a partial failure — and the discovery
mode's own richer contract is untouched for the filing fence that consumes it.

## The stub's degraded arms, in full

- **exit 1** — do not read the reference; continue to §4.1.
- **exit 0** — read the reference and follow it.
- **exit 2** — read the reference anyway and record a `note`-kind reflection naming the
  operand that could not be established, quoting the `reason=` token.
- **no output at all** — the shape a harness refusal takes. Routes exactly as exit 2 does,
  except that the reflection records the no-output condition itself rather than a token the
  run never received. An unavailable operand is never read as "nothing was deferred".
- **the reference read fails** — absent, empty, harness-refused, or mismatched boundary
  markers. Records a `dropped-failed` reflection naming the reference path and continues to
  §4.1 without halting Phase 4.

## The `tr` dependence the predicate does not inherit

The filing fence derives its branch-slug search directory through a `tr` chain, and `tr` is
not in the project's preflight-guaranteed set. A missing `tr` empties the slug, which the
fence handles with a breadcrumb and a fallback to `pr-<N>`-only search. The predicate cannot
take that fallback silently — a gate that skips a search directory would report `absent` for a
PR whose deferrals live under the branch slug — so it derives the slug in Python instead, and
`lib/test/test_python_scripts.py` asserts the port against the fence's own live `tr` pipeline
over a table of branch-name shapes.

This closes the dependence for the **gate**, not for the fence: on a host without `tr` the
predicate can now report present from a branch-slug directory the fence then does not search,
which routes to the fence's existing breadcrumb and files nothing from that root. That is the
pre-existing behaviour for such a host, unchanged.

## Coupled sites moved in the same commit

Every assertion that located §4.0.5 content by naming the phase file's path was re-targeted,
never deleted: an assertion left on the phase file reports a count of zero and passes nothing.
That covers the `#254` branch-slug and search-set pins, the `#555` discovery pins, the `#275`
portable-anchor `file-deferrals.py` pin, the `#271` `run-jq.sh` pin, the `#480` sentinel pins
(two of which *execute* the shipped sentinel line, and one of which probes operand-initialization
ordering), the `ensure-label.sh` per-file counts, and the positional routing-bullet count. The
`### 4.0.5` heading stays at line start in the phase file, because the `#815` section-4.0 `sed`
range terminates on it and would otherwise run to end of file and pass vacuously.
