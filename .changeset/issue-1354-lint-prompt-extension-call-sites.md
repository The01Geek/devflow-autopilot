---
bump: patch
type: Added
---

- **Lint command call sites in `.prflow/prompt-extensions/**`.** The desk gates
  `lib/test/extract-command-heads.py` and `extract-command-shapes.py` now also audit the
  repository's live tracked prompt extensions, each against the head allowlist union
  (baked workflow `TOOLS` ∪ the matching `.prflow/config.json` `allowed_tools` array) and
  the command-shape profile of the tier(s) that load it. An ungranted command head or a
  matcher-denied command shape authored in an extension — previously silent at the desk
  and silent in the run (the matcher refuses such a command with no output and no error) —
  now turns the suite RED. Desk-gate only; no runtime behavior changes for a consumer. (#1354)
