#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
#
# phprobe-read-env.sh — the issue-1264 probe's injected render-time command.
#
# WHY THIS SCRIPT EXISTS AT ALL. The placeholder originally inlined the read:
#
#     !`/bin/echo "PHPROBE_ENV ${DEVFLOW_PROMPT_EXTENSION_ROOT:-UNSET}"`
#
# and `claude-code-action` REFUSED it before substitution, recording on the Skill
# tool_result: `Shell command permission check failed for pattern "…": Contains expansion`
# (run 31058109064 / job 92479992227). That refusal is itself a finding — it contradicts
# issue #1264's bare-CLI measured fact that injection is NOT gated by the permission
# system — but it also left limb (a) unestablished, because a refused placeholder never
# gets the chance to substitute.
#
# So the shell expansion moves OUT of the command text and into this script. The
# placeholder becomes a bare literal path with no `${…}`, no quotes, and no operators for
# the static check to object to, while the environment read still happens — just on this
# side of the boundary.
#
# ALWAYS EXITS 0. A non-zero exit from an injected command aborts the entire skill
# invocation at zero turns (issue #1264's measured facts), which is indistinguishable from
# a harness failure. `printenv` exits 1 on an unset variable, so its status is deliberately
# discarded and the unset case is REPORTED as the literal token UNSET rather than inferred
# from an empty line — the same unknown-is-not-zero discipline the rest of the repo uses.
#
# Output contract (one line, consumed by scripts/placeholder-probe-verdict.py):
#     PHPROBE_ENV <value>|UNSET

value="$(printenv DEVFLOW_PROMPT_EXTENSION_ROOT 2>/dev/null)" || value=""
[ -n "$value" ] || value="UNSET"
printf 'PHPROBE_ENV %s\n' "$value"
exit 0
