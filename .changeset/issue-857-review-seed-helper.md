---
bump: patch
---

Route the review engine's live-progress-comment seed through a new bundled helper,
`scripts/seed-review-progress.sh`, so the issue #384 find-or-create screens (S1 numeric
guard, S2 workpad.py readability precheck, S3 rc-2 silent-exit discriminator) run as
ordinary shell instead of an inline prompt-fence `case`/`if`/`elif` compound the cloud
review matcher refused. The helper performs the find-or-create decision internally and
prints exactly one token line — `RESUME <id>` / `CREATED <id>` (exit 0) or
`SKIP not-numeric` / `SKIP workpad-unreadable` / `SKIP api-error` (exit 3) — with no
silent path, so the #384 duplicate-workpad-comment guard is now actually enforced in
cloud rather than only nominally present. `skills/review/SKILL.md` invokes it as a
single leading-token statement with a `;`-joined empty-output fallback arm;
`scripts/workpad.py acs-resolve` now routes a non-numeric issue argument as a
`resolver-unavailable` outcome with exit 0, letting Phase 0.4 reduce to a bare
`acs-resolve` call. Adds the desk-lint rule `R5` (flagging a command-substitution
condition) and four matcher-probe review rows to catch and eventually retire the
discipline.
