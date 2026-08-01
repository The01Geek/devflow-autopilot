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
