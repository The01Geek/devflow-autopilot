#!/bin/bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
#
# Process-control behaviour shipped helpers depend on, and the Bash 4.3 construct they
# must not depend on.
#
# `wait -n` (reap any one job) is 4.3 only. A pool that reaches for it does not fail on
# macOS — `wait` without `-n` reaps *everything*, so the pool serialises silently and
# its concurrency claim quietly becomes false. That is why this fixture asserts the
# absence rather than trusting the version string.
#
# Exit 0 = the 3.2 process-control set works and `wait -n` is refused.
# Exit 1 = otherwise, naming which claim failed.
set -u

fail() { echo "process-control: $1" >&2; exit 1; }

# Backgrounding, $!, and a status-preserving wait.
sleep 0 &
child=$!
[ -n "$child" ] || fail "\$! was empty after backgrounding"
wait "$child" || fail "wait on a backgrounded child did not report its success"

# A non-zero child status must survive `wait`.
"$BASH" -c 'exit 7' &
child=$!
wait "$child"
status=$?
[ "$status" -eq 7 ] || fail "wait reported $status for a child that exited 7"

# Process substitution — the shape the repository's helpers use instead of a temp file.
got=$(cat <(printf 'substituted'))
[ "$got" = 'substituted' ] || fail "process substitution produced '$got'"

# Subshell exit status propagates through a pipeline's last element.
if printf 'x' | "$BASH" -c 'exit 3'; then
  fail "a failing pipeline element reported success"
fi

# `wait -n` is Bash 4.3 only — and, as above, 126/127 would establish its absence by
# never running the probe, so they are called out rather than counted as a refusal.
"$BASH" -c 'sleep 0 & wait -n' 2>/dev/null
status=$?
case "$status" in
  0) fail "interpreter supports wait -n — this is not Bash 3.2" ;;
  126|127) fail "the probe interpreter '$BASH' could not be run (status $status) — wait -n's absence was never established" ;;
esac

echo "process-control: backgrounding, status-preserving wait and process substitution work; wait -n is refused"
exit 0
