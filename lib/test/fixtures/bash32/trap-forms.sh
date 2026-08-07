#!/bin/bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
#
# Trap forms shipped helpers rely on, exercised rather than assumed. This is the
# construct class that reached final review unverified on the run this lane was
# created for, so the fixture asserts the *behaviour*, not the version number.
#
# Three claims, each a real dependency of the shipped signal-handling helpers:
#   1. `trap -p` lists an installed trap in a form `eval` can reinstall.
#   2. A trap installed for a named signal fires when that signal is delivered.
#   3. `trap - SIGNAL` restores the default disposition, observably.
#
# Exit 0 = all three hold on this interpreter. Exit 1 = one did not, naming which.
set -u

fail() { echo "trap-forms: $1" >&2; exit 1; }

# 1. trap -p round-trip. Bash 3.2 prints `trap -- 'cmd' SIGNAME`; the round-trip is
#    what shipped code actually does, so assert that rather than the exact spelling.
listed=$("$BASH" -c "trap 'echo caught' USR1; trap -p USR1" 2>/dev/null) \
  || fail "trap -p exited non-zero"
case "$listed" in
  *"echo caught"*) : ;;
  *) fail "trap -p did not report the installed handler (got: ${listed:-<empty>})" ;;
esac

reinstalled=$("$BASH" -c "eval \"$listed\"; trap -p USR1" 2>/dev/null) \
  || fail "the trap -p output could not be eval'd back"
case "$reinstalled" in
  *"echo caught"*) : ;;
  *) fail "the eval'd trap -p output did not reinstall the handler" ;;
esac

# 2. Delivery. Send the signal to the shell itself and observe the handler run.
delivered=$("$BASH" -c "trap 'printf fired' USR1; kill -USR1 \$\$; wait 2>/dev/null; :" 2>/dev/null)
case "$delivered" in
  *fired*) : ;;
  *) fail "a USR1 trap did not fire on delivery (got: ${delivered:-<empty>})" ;;
esac

# 3. Reset to default. After `trap - USR1` the shell must die on the signal rather
#    than run the old handler, so the child's exit status is the observable.
#    The whole probe runs inside a subshell whose stderr is closed, because the shell
#    ANNOUNCES a signal-killed child ("User defined signal 1") on the parent's stderr,
#    and that notice is normal here rather than a diagnostic worth surfacing.
( "$BASH" -c "trap 'printf stale' USR1; trap - USR1; kill -USR1 \$\$; sleep 1" >/dev/null 2>&1 ) 2>/dev/null
status=$?
# The observable is death BY SIGUSR1 — status 128+SIGUSR1 — not merely a non-zero exit.
# "Non-zero" would also be satisfied by 126/127 (a $BASH that could not run at all) and
# by any unrelated failure of the probe body, either of which would let this fixture
# report a restored default disposition it never observed. SIGUSR1 is 30 on macOS/BSD
# and 10 on Linux, so both encodings are accepted; the point is which signal, not which
# platform.
case "$status" in
  0)       fail "trap - USR1 did not restore the default disposition (child exited 0)" ;;
  158|138) : ;;
  126|127) fail "the probe interpreter '$BASH' could not be run (status $status) — the reset-to-default was never established" ;;
  *)       fail "expected death by SIGUSR1 (128+30 or 128+10), got $status" ;;
esac

echo "trap-forms: trap -p round-trip, delivery, and reset-to-default all behave as shipped helpers require"
exit 0
