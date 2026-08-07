---
"prflow": patch
---

Editorially compress `/prflow:implement`'s Phase 2 prompt surface outside `### 2.3 Implement`.

The resume-idempotency gate, durability checkpoints, discovery, reproduce-first gate, planning, test and commit sections of `skills/implement/phases/phase-2-implement.md` — plus the file's opening block — carried rationale essays, rejected-design records, motivating-incident archaeology and epistemics commentary aimed at a human maintainer, inside a file whose only runtime reader is an agent that needs to know what to do. That prose is now compressed under `CLAUDE.md`'s instruction-plus-consequence rule, which allows an instruction and at most one sentence naming what breaks if it is skipped.

Every instruction, prohibition, degraded arm, named failure token, exact command form and closed-set enumeration present before the change survives. Two walls of text became labelled recipes: the Phase-2 subagent number re-derivation rules, and the cloud-tier workflow-edit commit guard — the latter keeping its fire condition and both exempt cases, both detection commands, the repo-own-versus-vendored carve-out, the coupled-file revert obligation with its disclosed best-effort limit, both backstop arms, the scope-adjustment routing including the empty-pushable-subset stop, and the durability helper's spelling-only detect-and-do-not-stage half with the path forms it does not match.

`### 2.3 Implement` is byte-unchanged and no behavior changes. The file drops from 142,459 B to 138,586 B.
