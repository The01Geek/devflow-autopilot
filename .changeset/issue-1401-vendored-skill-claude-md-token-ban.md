---
bump: patch
---

`skills/receiving-code-review/SKILL.md` no longer points at PRFlow's own `CLAUDE.md`, a
file the vendor slice never copies into a consumer repo — the `**Why:**` sentence in
*Share the Contract: Parse, Don't Validate* now states the `unverified-assumption`
guard rule on its own authority. The consumer-facing body carries no dangling citation.

`lib/test/lint-shipped-pruned-path.py` gains a third forbidden class: it reports an
unmarked `CLAUDE.md` token anywhere inside a vendored-skill directory — every
`skills/<name>/` whose `SKILL.md` carries the vendored-provenance sentence. The scope is
derived from that sentence, not a transcribed file list, so it follows a rename or a
newly-vendored skill, and an empty derivation fails the run closed. Every other
`skills/**` / `agents/**` file keeps its freedom to name `CLAUDE.md` as the consumer's
own project memory.
