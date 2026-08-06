---
bump: patch
type: Fixed
---

- **Exempt documented `docs.*` config defaults from `lint-shipped-pruned-path.py` (#1366).** The
  shipped-surface lint pruned-path check flagged any shipped skill sentence naming `docs/external`
  or `docs/internal` — which are simultaneously the documented defaults of the `.docs.external` /
  `.docs.internal` config keys, i.e. the consumer's own doc roots that are expected to exist in
  their checkout. The lint now derives an exemption set from the path-shaped `docs.*` defaults in
  `.prflow/config.schema.json` (by trailing-slash-normalized equality, never prefix) and subtracts
  it from the derived prune set before scanning, so a shipped line naming a documented `docs.*`
  default needs no `<!-- pruned-path-ok: … -->` marker. The exemption keeps the lint's fail-closed
  posture: an unestablished schema, or an exemption that empties the forbidden set, refuses non-zero
  rather than auditing nothing. Two new observability flags — `--print-exempt-set` and the
  post-exemption `--print-prune-set` — expose the derivation. The now-redundant `pruned-path-ok`
  marker lines the false-positive class had forced into consumer-facing skill prose are removed.
