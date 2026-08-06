---
name: placeholder-probe
description: Render-time placeholder precondition probe for issue #1264. Measures whether claude-code-action substitutes a `!` placeholder in a plugin-sourced SKILL.md, whether the injected command sees DEVFLOW_PROMPT_EXTENSION_ROOT, and whether rendering is gated by --allowed-tools.
---

# Render-time placeholder probe (issue #1264 precondition)

PHPROBE_LINE_A: !`.github/probe-plugin/phprobe-read-env.sh`

<!--
  The line above is the entire measurement. Three limbs at once:

  (a) SUBSTITUTION — if claude-code-action renders the placeholder, `PHPROBE_LINE_A:` is
      followed by the script's stdout (`PHPROBE_ENV <value>`). If it does not, the raw
      `!`-backtick text survives verbatim and the agent echoes that back instead.
  (b) ENVIRONMENT — the script reads DEVFLOW_PROMPT_EXTENSION_ROOT, which the probe job
      sets to a sentinel via the step-level `env:`, and reports the literal token UNSET
      when it is absent rather than emitting an empty line.
  (c) ALLOWLIST GATING — the head is a repo-relative script path, deliberately NOT
      `printf`. The job grants only `Bash(printf:*)` and `Skill`, so this head is
      UNGRANTED. Output appearing here proves rendering is not refused by --allowed-tools.

  WHY THE COMMAND IS A BARE PATH WITH NO `${…}` IN IT. The first shape inlined the read as
  `!`/bin/echo "PHPROBE_ENV ${DEVFLOW_PROMPT_EXTENSION_ROOT:-UNSET}"`` and the action
  REFUSED it before substitution — `Shell command permission check failed … Contains
  expansion` (run 31058109064). Placeholders are permission-checked under
  claude-code-action, which contradicts issue #1264's bare-CLI measured fact, so the shell
  expansion now lives inside the script instead of in the command text.

  The script always exits 0, which matters: a non-zero exit from an injected command
  aborts the whole skill invocation at zero turns.
-->

You are a RENDER-TIME PLACEHOLDER PROBE. Do EXACTLY the numbered actions below, ALL of
them, in order, each exactly once, and nothing else.

Your text output is not measured. Only the harness record of your tool calls is measured
— so every marker line MUST be produced through a Bash tool call, not merely written in
your reply.

Action 1 (positive control, BEFORE) — run this Bash command once:
printf '%s\n' 'PHPROBE_SKILL_REACHED'

Action 2 (the measurement) — look at the `PHPROBE_LINE_A:` line near the top of this
skill body. Take **everything that follows the `PHPROBE_LINE_A: ` prefix** and echo it
back, exactly as it appears to you, behind the fixed token `PHPROBE_SAW`:
printf '%s\n' 'PHPROBE_SAW PASTE_THE_LINE_A_CONTENT_HERE'

Replace only the `PASTE_THE_LINE_A_CONTENT_HERE` token with what you actually see; keep
the `PHPROBE_SAW ` prefix and the surrounding single quotes exactly as written. Report it
verbatim whether it looks like command output or like an unexecuted command — reporting
what is actually there IS the measurement, and there is no wrong content to find. If the
content itself contains a single quote, use a double-quoted argument instead so the
command still parses.

If that line is missing from this body entirely, run this instead:
printf '%s\n' 'PHPROBE_LINE_A_ABSENT'

Action 3 (positive control, AFTER — proves you reached and passed Action 2) — run this
Bash command once:
printf '%s\n' 'PHPROBE_CONTROL_AFTER'

After the last numbered action, STOP and reply with the single word DONE.
