---
name: placeholder-probe
description: Render-time placeholder precondition probe for issue #1264. Measures whether claude-code-action substitutes a `!` placeholder in a plugin-sourced SKILL.md when the prompt is a slash command, whether the injected command sees DEVFLOW_PROMPT_EXTENSION_ROOT, and whether rendering is gated by --allowed-tools.
---

# Render-time placeholder probe (issue #1264 precondition)

PHPROBE_LINE_A: !`/bin/echo "PHPROBE_ENV ${DEVFLOW_PROMPT_EXTENSION_ROOT:-UNSET}"`

<!--
  The line above is the entire measurement. Three limbs at once:

  (a) SUBSTITUTION — if claude-code-action renders the placeholder, `PHPROBE_LINE_A:`
      is followed by the command's stdout. If it does not, the raw `!`-backtick text
      survives verbatim and the agent echoes that back instead.
  (b) ENVIRONMENT — the command reads DEVFLOW_PROMPT_EXTENSION_ROOT, which the probe
      job sets to a sentinel via the step-level `env:`. The `:-UNSET` default means a
      missing variable is REPORTED, never silently empty.
  (c) ALLOWLIST GATING — the head is `/bin/echo`, deliberately NOT `printf`. The job
      grants only `Bash(printf:*)` (plus `Skill`), so `/bin/echo` is an UNGRANTED head.
      Output appearing here therefore proves rendering is not gated by --allowed-tools.

  `/bin/echo` always exits 0, which matters: a non-zero exit from an injected command
  aborts the whole skill invocation at zero turns (measured on the bare CLI, recorded
  in issue #1264's "Measured facts" table). This probe must never trip that hazard,
  because an abort is indistinguishable from a harness failure.
-->

You are a RENDER-TIME PLACEHOLDER PROBE. Do EXACTLY the numbered actions below, ALL of
them, in order, each exactly once, and nothing else.

Your text output is not measured. Only the harness record of your tool calls is measured
— so every marker line MUST be produced through a Bash tool call, not merely written in
your reply.

Action 1 (positive control, BEFORE) — run this Bash command once:
printf '%s\n' 'PHPROBE_SKILL_REACHED'

Action 2 (the measurement) — look at the `PHPROBE_LINE_A:` line near the top of this
skill body. Echo back **everything that follows the `PHPROBE_LINE_A: ` prefix**, exactly
as it appears to you, through one Bash command:
printf '%s\n' 'PASTE_THE_PHPROBE_LINE_A_CONTENT_HERE'

Replace the placeholder token with what you actually see — keep the surrounding single
quotes and add none of your own. Report it verbatim whether it looks like command output
or like an unexecuted command: reporting what is actually there IS the measurement, and
there is no wrong content to find. If the content itself contains a single quote, use a
double-quoted argument instead so the command still parses.

If that line is missing from this body entirely, run this instead:
printf '%s\n' 'PHPROBE_LINE_A_ABSENT'

Action 3 (positive control, AFTER — proves you reached and passed Action 2) — run this
Bash command once:
printf '%s\n' 'PHPROBE_CONTROL_AFTER'

After the last numbered action, STOP and reply with the single word DONE.
