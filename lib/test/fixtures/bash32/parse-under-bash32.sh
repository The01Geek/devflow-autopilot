#!/bin/bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
#
# The per-surface fixture the registry's `fixture_command` names: load one portable
# shell surface under the running interpreter and report whether it parses.
#
# WHAT THIS ESTABLISHES, exactly — do not read it as more. `bash -n` is a parse, so it
# catches the incompatibilities that are SYNTAX under Bash 3.2 (`coproc`, `;;&` case
# fallthrough, and anything else 4.x added to the grammar), for the file itself and not
# for what it sources. It does NOT catch a runtime-only incompatibility such as
# `${v,,}` or `declare -A`, which parse cleanly on 3.2 and misbehave when reached.
# Those are covered from the other side: the construct fixtures in this directory
# assert the interpreter genuinely refuses them, and `lib/shell-surface-registry.json`
# is what classifies a file that uses one as `excluded`. The registry's own
# classification is not re-derived here.
#
# Usage: parse-under-bash32.sh <path>...
# Exit 0 = every named path parses. Exit 1 = one did not, or none was named.
set -u

if [ "$#" -eq 0 ]; then
  echo "parse-under-bash32: no surface named — refusing to report a clean parse of nothing" >&2
  exit 1
fi

rc=0
for surface in "$@"; do
  if [ ! -f "$surface" ]; then
    echo "parse-under-bash32: $surface does not exist" >&2
    rc=1
    continue
  fi
  if ! err=$("$BASH" -n "$surface" 2>&1); then
    echo "parse-under-bash32: $surface does not parse under Bash ${BASH_VERSION}: $err" >&2
    rc=1
  fi
done

[ "$rc" -eq 0 ] && echo "parse-under-bash32: $# surface(s) parse under Bash ${BASH_VERSION}"
exit "$rc"
