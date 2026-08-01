---
bump: patch
type: Added
---

- **Durable, queryable permission-denial forensics on the live cloud tiers.** Denied Bash
  commands are now recorded into each run's efficiency record on the `prflow-telemetry`
  branch — the count and denied `tool_name` always, and the (credential-scrubbed)
  command text under a new key — instead of only an ephemeral, 200-char-truncated step
  summary. The step-summary denial line now renders the denied command specifically at a
  wider 500-char bound, and `scripts/build-experiment-records.py` reads the durable record
  back into the experiment store's `permission_denials_count`, restoring the producer
  removed with the withheld auto-review tier. (#1064)

- **Behavior change on upgrade — a new default-ON config key.** A new
  `.prflow.execution_denial_commands_enabled` key (default **`true`**) gates the scrubbed
  denied-command **text**. **An upgrading repository begins persisting scrubbed
  denied-command text to its own `prflow-telemetry` branch without opting in** — durably,
  not as a 7-day artifact. This is acceptable because the field is bounded, scrubbed
  (with an incomplete credential blocklist, disclosed as such in every record), and
  command-only; a repository whose access model cannot accept that sets
  `.prflow.execution_denial_commands_enabled` to `false` to turn it off. The denial count
  and `tool_name` are never gated and are always persisted. The key deliberately defaults
  opposite to `execution_transcript_artifact_enabled` (default `false`): that key gates
  the whole execution transcript, this one only a bounded scrubbed command field. (#1064)

- **The denial record keeps the command text on runs that never emitted a result event.**
  `scripts/extract-execution-shape.sh` reports every field as `unavailable` without a
  `type: "result"` event — so on a stalled, timed-out or crashed run, the very runs the
  `always()` persist step exists for, the record would have carried a positive denial
  count beside "no command could be established" while the commands sat in the file's
  streamed message events. The record now recovers them from the denial objects directly
  in that case, at the same field preference and the same 500-char/40-entry bounds, and
  the recovered text goes through the same credential scrub on the same fail-closed path.
  Where the commands genuinely cannot be established the record still reports
  `unavailable` — never an empty list and never a fabricated zero. (#1064)

- **The withheld auto-review tier resolves its transcript scrub only from a trusted
  source.** `devflow-runner.yml` checks out the PR head, so reading the extracted
  `scripts/scrub-transcript.sh` from the workspace would have let a pull request supply
  its own no-op credential scrub and cause the *unscrubbed* execution transcript — which
  carries the `Authorization` header `actions/checkout` persists — to be uploaded. The
  scrub now resolves in the same rank order the tier's other security-relevant helpers
  use (base-ref copy materialized into `RUNNER_TEMP`, then a runtime-fetched vendored copy
  at the pinned version, else fail closed and upload nothing), and never from the PR-head
  checkout. This tier ships uncallable, so no runnable path was affected. (#1064)
