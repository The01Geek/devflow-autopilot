---
bump: patch
type: Added
---

- **`stale-prose-lint.py` gains a non-gating R3 recognition-only tier.** A diff-added prose or
  comment line matching a widened counted-claim shape — a spelled-out numeral word (`two`…`twelve`),
  up to two intervening modifier words, and a widened noun set (the existing nouns plus plural-only
  additions like `tags`/`members`/`rows`/`rules`) — that the gating `_COUNT_RE` does not match now
  emits a single `UNRESOLVABLE` `R3` row whose detail carries the `count-locked` literal the
  pin-or-don't-write policy keys on. The tier resolves no referent, never emits `STALE`, and never
  affects the exit code, so it adds no gating surface: it only makes unpinned counted-prose claims
  self-announce in the fix loop's pre-check and the Phase 0.6 note. The engine skill's Phase 4.2
  verdict criteria gain a one-sentence clarification that a deterministic Phase 0.6 `STALE` finding
  participates via its configured severity only and never invokes the self-contradicting-diff
  carve-out. (#439)
