---
bump: patch
type: Changed
---

- **Trim `skills/implement/phases/phase-4-documentation.md` under an instruction-plus-consequence prose rule.** Compress defensive-why prose (which pre-empts a reviewer's misreading) and maintainer notes (which direct no agent action), plus the in-fence `#` comment lines, keeping every instruction and every consequence — the file drops from 628 lines / 107,200 bytes to 553 lines / 95,988 bytes with no executable fence content, declaration marker, or pinned literal changed. The `#815` byte-ceiling check and its ledger comment are retired from `lib/test/run.sh`, along with `CONTRIBUTING.md`'s "Raising the phase-4 documentation byte ceiling" section, and the instruction-plus-consequence rule is added as a `CLAUDE.md` Conventions bullet so it applies to every skill/phase-file edit rather than only implement runs. (#1351)
