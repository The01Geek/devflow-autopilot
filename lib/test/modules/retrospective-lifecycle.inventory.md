# retrospective-lifecycle module — coverage inventory

Issue #788. Maps each contract group in `retrospective-lifecycle.sh` back to the
surface it covers. This is a **deliberately partial** extraction (mirroring
`experiment-records.inventory.md`): the module owns the *new* lifecycle behavior,
while the pre-existing fail-closed assertions for these files stay inline in
`lib/test/run.sh`. The `coverage-map.json` owner for all five files below is
`retrospective-lifecycle`.

| Contract group | Subject | Former / sibling `run.sh` location |
| --- | --- | --- |
| `#788 compute-patterns.jq v2 status arms` | `lib/compute-patterns.jq` — six-arm order, fix-timestamp precedence, declined→regressed, dismissed as the absolute suppressor, one canonicalization | New behavior added by #788; the legacy grouping/slug/`fixed`/`regressed` arm assertions remain in run.sh's `compute-patterns.jq` section |
| `#788 pattern-state.sh migrate + reconcile` | `lib/pattern-state.sh` (new) — migrate v1→v2 (loop-vs-hand-written split), the five reconcile transitions with prefetch + by-number fallback, `fixed_at` stamping, idempotency, wholesale-prefetch fail-closed, no-URL warning, absent→v2 stub, two-entry derivation | New file; no former run.sh location |
| `#788 meta-issue.sh lifecycle-record write` | `lib/meta-issue.sh` — the `filed` lifecycle-record write keyed by issue number, no `.dismissed` write, `--slug` grammar validation, `--dry-run` no-op | The v2-shaped `meta-issue.sh` write assertions were updated in run.sh's `meta-issue.sh` section; the fail-closed (empty/garbage URL, de-dup lookup failure, non-JSON body) assertions stay inline there |

`lib/actionable-patterns.sh` and `lib/render-report.sh` are also owned by this
module in `coverage-map.json`; their assertions (cooldown emit, report rendering)
remain inline in run.sh as part of the same partial-extraction decision.
