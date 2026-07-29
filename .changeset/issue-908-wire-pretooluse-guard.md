---
bump: patch
type: Added
---

Wire the PreToolUse shape guard to fire, publish its denial visibility, and add a settings-input probe arm (issue #908, follow-up to #805/#906)

`devflow-runner.yml` now registers `scripts/pretooluse-shape-guard.py` as a `PreToolUse`/`Bash` hook via `claude-code-action`'s `settings` input (review tier only — `devflow-implement.yml` registers no guard), and publishes three new job outputs: the guard's heartbeat presence, its per-arm denial counts, and the denied-command detail already extracted by `scripts/extract-execution-shape.sh`. `devflow-review.yml` renders all three in the check-run summary beneath the existing `permission_denials_count` line, via a new `scripts/render-guard-visibility.sh` helper that neutralizes the un-redacted, attacker-influenced command text (backtick-strip, `::`-workflow-command neutralization, fencing, truncation marker) before it ever reaches the summary.

The guard's counts store is written only on a deny decision, so a run where the guard fires but denies nothing never creates it — collapsing that onto "unavailable" would misreport a positively-known zero as unknown. The new `id: guard` step disambiguates against the heartbeat (written on every invocation) before falling back, and a new `scripts/resolve-guard-counts-file.sh` helper owns the run-keyed/bare/glob file-selection logic so it stays suite-drivable rather than inline YAML.

`.github/workflows/matcher-probe.yml` gains a `pretooluse-probe` job (Part 1 of the follow-up) that registers an ad hoc always-allow `PreToolUse` hook via the `settings` input directly — independent of the base-branch `.claude/settings.json` `hook-probe` relies on — to measure whether the settings-input mechanism itself delivers a hook and its `permissionDecisionReason`. A new `scripts/describe-pretooluse-probe.sh` renders the FIRED/NOT-FIRED and REASON-DELIVERED/REASON-ABSENT observation. Recording that probe's evidence against `docs/cloud-allowlist.md`'s placeholder table remains #919's job.
