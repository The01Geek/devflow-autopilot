#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# compose-implement-prompt.sh — compose the `/prflow:implement <n>` prompt with the
# engine-ground-truth block prepended, and publish it as the `prompt` step output
# (issue #1170).
#
# Why a helper rather than inline shell in devflow-implement.yml's `Compose implement
# grounding block` step: this file makes a three-way SELECTION (renderer absent /
# renderer produced nothing / compose and publish), and inline shell inside YAML cannot
# be unit-tested. A grep-pin on one of the two `::warning::` literals is not coverage of
# the selection that chooses between them — a reordered or inverted arm would ship green.
# Extracted here so lib/test/run.sh drives every arm and the arm ORDER directly. Same
# reasoning, and same shape, as scripts/describe-denial-count.sh (issue #363).
#
# Reads from the environment:
#   ALLOWED_TOOLS  the exact resolved --allowed-tools string for this run (the
#                  `Resolve allowed-tools` step output). Forwarded to the renderer,
#                  which fails closed on an empty value (it renders "no commands are
#                  granted to this run" rather than an empty, unrestricted-looking fence).
#   NUMBER         the issue number the `/prflow:implement` command names.
#   GITHUB_OUTPUT  the step-output file. Absent/empty means there is nowhere to publish;
#                  the composed prompt is dropped with a breadcrumb rather than
#                  redirected somewhere arbitrary.
#
# The arms, IN ORDER — the order is the contract, not an implementation detail:
#
#   1. renderer absent at BOTH the vendored and the repo-root path
#        -> ::warning::, write NO `prompt` output, exit 0
#   2. renderer resolved but produced no block (empty stdout, or a non-zero exit)
#        -> ::warning::, write NO `prompt` output, exit 0
#   3. otherwise
#        -> append `prompt<<DELIM … DELIM` to $GITHUB_OUTPUT, exit 0
#
# Arms 1 and 2 write NO `prompt` key at all — this is load-bearing, not incidental.
# devflow-implement.yml consumes the output as
# `steps.compose.outputs.prompt || format('/prflow:implement {0}', …)`, so the bare-prompt
# default fires precisely because the key is absent. Publishing an empty `prompt=` instead
# would be a silent way to defeat that fallback, so both arms exit BEFORE the write.
#
# Renderer resolution is cwd-relative, matching every other bundled-helper call in the
# workflow (the run begins at the actions/checkout workspace root and the working
# directory persists): the vendored copy the `vendor-plugin` step materializes, then the
# repo-root copy so a self-repo checkout still finds one. Verification is of the
# renderer's OUTCOME (a non-empty block), never merely of the file's existence — a
# truncated vendored copy that exits 0 printing nothing must take arm 2, not ship an
# empty block into the prompt.
#
# Always exits 0. A missing or empty block degrades to the pre-#1170 bare prompt; it must
# never fail the implement job.

set -u

# Default the optional inputs once, up front, so every use below is a plain expansion —
# the same shape render-grounding-block.sh uses, and what keeps the renderer call line
# byte-identical to the inline one this helper replaces.
ALLOWED_TOOLS="${ALLOWED_TOOLS:-}"
NUMBER="${NUMBER:-}"

RGB=.prflow/vendor/prflow/scripts/render-grounding-block.sh
[ -f "$RGB" ] || RGB=scripts/render-grounding-block.sh
if [ ! -f "$RGB" ]; then
  echo "::warning::devflow: render-grounding-block.sh not found at either the vendored or repo path — the implement prompt carries no engine-ground-truth block this run" >&2
  exit 0
fi

GROUNDING=$(MODE=implement ALLOWED_TOOLS="$ALLOWED_TOOLS" bash "$RGB") || GROUNDING=""
if [ -z "$GROUNDING" ]; then
  echo "::warning::devflow: render-grounding-block.sh produced no output — the implement prompt carries no engine-ground-truth block this run (the engine will rediscover its tool boundary by trial and denial)" >&2
  exit 0
fi

if [ -z "${GITHUB_OUTPUT:-}" ]; then
  echo "::warning::devflow: GITHUB_OUTPUT is unset or empty — the composed implement prompt cannot be published, so the run falls back to the bare prompt" >&2
  exit 0
fi

PROMPT="${GROUNDING}

/prflow:implement ${NUMBER}"
# Randomized heredoc delimiter, not `prompt=<value>`: the block is multi-line, and a
# `key=value` append would truncate it at the first newline. `date` is not a preflight
# prerequisite, but it decides nothing here — a missing one only shortens the delimiter,
# which stays unique through `$$`.
delim="PROMPT_EOF_$(date +%s%N)_$$"
{ printf 'prompt<<%s\n' "$delim"; printf '%s\n' "$PROMPT"; printf '%s\n' "$delim"; } >> "$GITHUB_OUTPUT" \
  || echo "::warning::devflow: could not append the composed implement prompt to GITHUB_OUTPUT ('$GITHUB_OUTPUT') — the run falls back to the bare prompt" >&2
exit 0
