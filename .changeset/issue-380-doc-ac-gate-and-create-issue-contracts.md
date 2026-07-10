---
bump: patch
type: Fixed
---

- **Recognize documentation acceptance criteria as Phase-4-owned in the Phase 3.4 gate.** An
  acceptance criterion whose satisfaction is a `docs/…` edit that the Phase 4.1 `devflow:docs`
  pass authors is now left unticked at the Phase 3.4 acceptance-criteria gate, recorded in a
  workpad deferral note, and exempted from the gate's blocking check (never routed through the
  `(post-merge)` channel); Phase 4.1 discharges and ticks it before the terminal
  `--status Complete` write. This removes the ordering contradiction where a documentation AC
  was structurally unsatisfiable at the gate and only passed when a reviewer happened to author
  the docs early. (#380)
- **Harden `/devflow:create-issue`'s mechanical-claim contract.** The issue template's Testing
  Strategy and the create-issue skill now require a mechanical claim ("running X reports Y" /
  "must fail RED reporting Y") to be either executed-and-cited as verified output or written as
  an obligation, never an unverified prediction; `Relevant Classes/Files` references cite a
  symbol or section rather than a rot-prone `file:line` anchor. (#380)
- **Accept `### Documentation Needed` as a third Documentation-Needed shape.**
  `scripts/extract-doc-needed-paths.sh` now opens its extraction scope on a
  `### Documentation Needed` level-3 heading (inside `## Implementation Notes`), alongside the
  existing bold-bullet and bare-bold-paragraph shapes, so a heading-form issue body no longer
  silently defeats the Phase 4.1 deliverable cross-check. The create-issue template's canonical
  bold-bullet form and the extractor's accepted shapes are pinned as a coupled pair in
  `lib/test/run.sh`, and the Phase 4.1 Stage 1 safety-net fires on either form. (#380)
