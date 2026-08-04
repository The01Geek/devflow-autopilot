---
bump: patch
type: Added
---

- **Add a producer-emitted loop-verdict marker across the implement ↔ review-and-fix skill boundary.** `/prflow:review-and-fix` now emits a machine-readable `<!-- prflow:loop-verdict result=<token> coverage=<full|not-verified> -->` line as line 1 of its chat output, composed by the new `scripts/loop-verdict-marker.py` helper (never hand-written), and `/prflow:implement` Phase 3.3 reads it first — routing on a closed vocabulary — while keeping its exact-wording headline match as a version-gap fallback. This replaces the fragile exact-string-match contract that could silently read an `APPROVE WITH UNRESOLVED SHADOW FINDINGS` run as a clean approve across a plugin-version boundary. A missing, malformed, or out-of-vocabulary marker is never read as a clean, fully-covered approval. Both directions of the supported one-version gap work; version pinning is not adopted. (#1212)
