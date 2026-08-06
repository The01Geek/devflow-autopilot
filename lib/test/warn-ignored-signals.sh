#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
#
# Issue #1216 (AC4/AC5). Advisory startup check for lib/test/run.sh: detect a
# SIGINT or SIGQUIT that arrived ALREADY IGNORED (SIG_IGN) and say so loudly,
# naming the likely cause and the shipped remedy. bash cannot un-ignore a signal
# it inherited as SIG_IGN, so a suite launched this way carries signal-trap
# assertions that fail — or hang — for a reason that is otherwise invisible.
#
# This is strictly ADVISORY: it changes no exit code (always exits 0) and
# registers NO skipped check (it touches no SKIPS_FILE and writes nothing to
# stdout), so a run carrying it still satisfies the completion gate's zero-skip
# requirement. Run BEFORE any trap is installed so the inherited disposition is
# read, not a disposition the caller set.
#
# The disposition is read with the `trap -p` builtin and matched with bash
# pattern matching — never a non-preflight PATH tool, whose absence would empty
# the result and silently suppress the warning (CLAUDE.md guard-class 2). An
# inherited SIG_IGN prints as `trap -- '' SIG<NAME>`; a default disposition
# prints nothing. The leading text deliberately avoids the `  NOTE ` printf shape
# the #456 meta-assertion scans run.sh for.

_devflow_warn_ignored_signal() { # SIG-name
  local sig="$1" desc
  desc="$(trap -p "$sig" 2>/dev/null)"
  case "$desc" in
    *"-- '' "*)
      printf 'run.sh: ADVISORY: SIG%s arrived IGNORED (SIG_IGN) — bash cannot un-ignore it, so signal-trap assertions may fail or hang. Likely cause: the suite was started from a background launch (`cmd &`) in a shell without job control. Remedy: launch through lib/test/launch-detached.py, which restores default signal dispositions in the child.\n' \
        "$sig" >&2
      ;;
  esac
}

_devflow_warn_ignored_signal INT
_devflow_warn_ignored_signal QUIT

exit 0
