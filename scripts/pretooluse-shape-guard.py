#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""pretooluse-shape-guard.py — the review-tier PreToolUse command-shape guard (issue #805).

A DevFlow cloud review run that emits a command in a shape the harness matcher denies
gets a terse refusal and re-emits variants of the same denied shape instead of
switching (review run 30138268273: five `/tmp`-redirect denials, the last 228 events
after the first). Advisory prompt prose against exactly this has already been measured
failing. This guard is the compensating control that is NOT more prose: run as a
`PreToolUse` hook on the review tier, it reads the Bash tool payload on stdin and, for a
command any of whose statements matches a probe-proven denied shape, returns a `deny`
decision whose `permissionDecisionReason` names the permitted alternative for that shape
— delivered at the moment of the offending call, through the same tool-result channel
the harness's own refusal uses (`permissionDecisionReason` is "shown to Claude in the
tool result", per https://code.claude.com/docs/en/hooks).

REGISTRATION IS NOT YET WIRED (scope of this change). This change ships the guard BODY,
its unit coverage, and its trusted-source hardening only. Nothing in the tree registers
it: `.claude/settings.json` carries no `PreToolUse` key, and
`.github/workflows/devflow-runner.yml` passes no `settings` input to the action. Until
both land the guard never executes, so every runtime behavior described below is the
contract this file implements, not behavior observable at this HEAD. Registration is
where the two channels below become live.

DENY SET (arms, not rule ids). The guard denies exactly `R1`, the `/tmp`-target arm of
R3 (`R3-tmp`), and `R4` — every `lib/test/extract-command-shapes.py` `REVIEW_RULES` arm
whose rule-table entry cites a probe row OR an observed run denial. `R2` (a leading
`cd`, DROPPED as unproven/confounded) and `R3-heredoc` (an in-workspace `cat`-heredoc
write, banned as authoring discipline, not a probe result) are EXCLUDED: a runtime deny
is terminal for the call, so denying an arm the harness would have permitted costs the
engine a working shape — the cost this issue exists to remove. Because that arm split
cannot be expressed at rule-id granularity (`classify()` returns the single token `R3`
for both arms), the guard resolves through that module's `classify_arms()` arm-level
classifier.

FAIL-OPEN. Every failure — an unparseable payload, an internal exception, a failed
breadcrumb or counter write — resolves to `defer` (the default permission flow) and
exit 0. A guard that blocked on an unparsed payload would deny legitimate commands; a
guard that exited non-zero with no heartbeat would read to the workflow as the
never-fired case for a guard that in fact ran, destroying the distinguishability the
heartbeat exists to provide. The harness also caps consecutive hook blocks, so a guard
that denied everything would stall a run — the `defer` majority path is what bounds it.

REPEAT BOUND. The load-bearing assumption (a per-call remediation changes behavior where
generic refusal did not) may fail, so the guard also carries a control: a second denial
of the same arm within one run escalates the remediation to name the abandonment rule
explicitly. The per-arm counts live in a WORKSPACE-scoped store under `.devflow/tmp/`
(each hook invocation is a separate process) written under an exclusive lock, so
parallel subagent invocations cannot interleave and undercount. It is per-RUN only
because the cloud tier gets a fresh workspace each run; the store carries no run key, so
on a persistent local checkout the counts accumulate across sessions and the escalation
can fire on a later session's first denial of an arm.

TRUST BOUNDARY (the contract registration must satisfy). This file is inert unless its
path is in the trusted-base HOOK_TARGETS: the hook command a `settings` input would
register points at a path the #458 harden step has already displaced-or-stubbed from the
base ref, so a pull-request-head guard body never executes in the secrets-bearing review
job. That half IS shipped here — the path is in `HOOK_ENTRY_TARGETS` and `HOOK_TARGETS`.
The two registration channels are not, and each has a distinct job: a committed
`.claude/settings.json` `PreToolUse` entry is what would ARM the #458 relevance gate
(`--wired-check` substring-matches `HOOK_ENTRY_TARGETS` against the trusted base
settings, so a guard registered only through the action's `settings` input leaves that
gate unarmed), while the action's `settings` input is what would make the guard
EFFECTIVE in a run. Registering through `settings` alone would run pull-request-editable
guard code in a secrets-bearing job; both channels must land together. See
scripts/harden-stop-hooks.sh and docs/cloud-allowlist.md.
"""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import time

# The arm identifiers this guard denies, in the SORTED order the multi-match tie-break
# selects — sorted("R1","R3-tmp","R4") is exactly this. A command matching more than one
# deny-set arm emits the first-sorting arm's remediation, so the choice is deterministic
# across invocations rather than dependent on an unstated spelling.
DENY_ARMS = ("R1", "R3-tmp", "R4")

# ── Arm → permitted-alternative remediation (issue #805) ──────────────────────
# This table is the guard's own named table; NO remediation text is composed at runtime,
# and it carries NO entry for an excluded arm (R2, R3-heredoc). docs/cloud-allowlist.md
# is the AUTHORITATIVE record of each arm's permitted alternative and this table is its
# mirror — a lib/test/run.sh assertion ties each arm's row to that document's row for the
# same arm, so the two cannot drift apart silently (the same coupled-mirror discipline the
# closure literals carry, applied to a scripts/-to-docs/ pair). The JOIN LITERAL differs by
# arm and is not uniformly the alternative: R1 joins on `VAR=$(cmd)` and R3-tmp on
# `.devflow/tmp/` (both permitted alternatives), while R4 joins on the DENIED-SHAPE token
# `python3/python/node`, because R4's alternative is a whitespace-bearing English phrase
# that the issue-810 boundary classifies as markdown prose on the docs side. So an edit to
# R4's alternative cell alone does not turn the suite RED; reconcile it by hand.
REMEDIATION = {
    "R1": (
        "devflow shape guard (R1): a leading VAR=value assignment or env-prefix "
        "(M=x cmd) is denied by the review-tier matcher. Permitted alternative: "
        "capture a command's output with VAR=$(cmd), or pass the value as an argument "
        "to the command; do not prefix the command with VAR=value."
    ),
    "R3-tmp": (
        "devflow shape guard (R3-tmp): a >/>> redirect targeting /tmp is denied by the "
        "review-tier matcher. Permitted alternative: author the file with the Write tool "
        "under .devflow/tmp/, or stream through a pipe into tee; do not redirect to /tmp."
    ),
    "R4": (
        "devflow shape guard (R4): an interpreter head (python3/python/node) is granted "
        "by no review-tier profile. Permitted alternative: invoke the helper directly by "
        "its granted path as the command's leading token; do not prefix it with an "
        "interpreter."
    ),
}

# The escalation suffix for a SECOND denial of the same arm within one run: it names the
# abandonment rule explicitly for that arm. Appended to the base remediation above.
_ABANDON = (
    " REPEAT: this shape ({arm}) was already denied once this run. The two-denials rule "
    "applies — abandon this shape now and switch to the permitted alternative above; do "
    "not iterate variants of the denied shape (that is what exhausts the run's budget)."
)

_HEARTBEAT = "pretooluse-guard-fired"
_COUNTS = "pretooluse-guard-counts.json"
_LOCK = "pretooluse-guard-counts.lock"
_LOCK_WAIT_SECONDS = 2.0  # bounded wait; on timeout, emit the decision without incrementing


def _repo_root() -> str:
    """The repository root, NOT the process working directory (a hook's cwd is not
    guaranteed). Mirrors scripts/stop-hook-probe.sh: git toplevel, else cwd."""
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        root = out.stdout.strip()
        if out.returncode == 0 and root:
            return root
    except Exception:
        pass
    return os.getcwd()


def _tmp_dir(root: str) -> str:
    d = os.path.join(root, ".devflow", "tmp")
    os.makedirs(d, exist_ok=True)
    return d


def _decision_object(permission_decision: str, reason: str | None) -> dict:
    out: dict = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": permission_decision,
        }
    }
    if reason is not None:
        out["hookSpecificOutput"]["permissionDecisionReason"] = reason
    return out


def _emit(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj))
    sys.stdout.write("\n")


def _load_shapes_module():
    """Load lib/test/extract-command-shapes.py by its committed relative position.

    The module's filename carries hyphens, so it is loaded through the
    `importlib.util.spec_from_file_location` idiom its existing consumers use — which is
    the guard's own dependency edge that scripts/detect-hook-closure-edges.py must model
    (both this file and lib/test/extract-command-shapes.py, plus the extract-command-
    heads.py it loads in turn, are in the trusted-base HOOK_TARGETS closure)."""
    root = _repo_root()
    path = os.path.join(root, "lib", "test", "extract-command-shapes.py")
    spec = importlib.util.spec_from_file_location("devflow_extract_command_shapes", path)
    if spec is None or spec.loader is None:
        raise ImportError(f"devflow: cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _matched_arms(command: str, shapes) -> set[str]:
    """The deny-set arms any statement of `command` matches."""
    matched: set[str] = set()
    for statement in shapes._statements(command):
        for arm in shapes.classify_arms(statement):
            if arm in DENY_ARMS:
                matched.add(arm)
    return matched


def _write_heartbeat(tmp: str) -> None:
    with open(os.path.join(tmp, _HEARTBEAT), "w", encoding="utf-8") as fh:
        fh.write("fired\n")


def _read_command(payload) -> str | None:
    """The Bash command string, or None for any shape the guard cannot classify.

    Every None path is a fail-open route to `defer`: valid JSON that is not an object, an
    object with no `tool_input`, a `tool_input` that is not an object, or an object with
    no `command` string."""
    if not isinstance(payload, dict):
        return None
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return None
    command = tool_input.get("command")
    if not isinstance(command, str):
        return None
    return command


def _bump_counts(tmp: str, arm: str, tool_use_id: str | None) -> tuple[bool, bool]:
    """Under an exclusive lock, record one denial of `arm` in the workspace-scoped store
    (see the module docstring's REPEAT BOUND note: no run key is carried) and return
    `(escalated, incremented)`.

    - Idempotent across duplicate registration: a `tool_use_id` already recorded returns
      its stored `escalated` verdict WITHOUT incrementing the per-arm counter a second
      time (so a double-fired guard cannot double the counter or fire the escalation on
      the engine's first offending command).
    - `escalated` is True on the SECOND (or later) distinct denial of the same arm.
    - A lock that cannot be acquired within the bounded wait returns
      `(False, False)` — the guard emits its (base) decision WITHOUT incrementing rather
      than blocking the tool call.

    Import fcntl lazily so a platform without it still fails open to a defer rather than
    at module import."""
    import fcntl

    lock_path = os.path.join(tmp, _LOCK)
    store_path = os.path.join(tmp, _COUNTS)
    lock_fh = open(lock_path, "w", encoding="utf-8")
    try:
        deadline = time.monotonic() + _LOCK_WAIT_SECONDS
        acquired = False
        while True:
            try:
                fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired = True
                break
            except OSError:
                if time.monotonic() >= deadline:
                    break
                time.sleep(0.02)
        if not acquired:
            return (False, False)
        store = {"arms": {}, "seen": {}}
        try:
            with open(store_path, encoding="utf-8") as fh:
                loaded = json.load(fh)
            if isinstance(loaded, dict):
                store["arms"] = loaded.get("arms") if isinstance(loaded.get("arms"), dict) else {}
                store["seen"] = loaded.get("seen") if isinstance(loaded.get("seen"), dict) else {}
        except (OSError, ValueError):
            pass  # absent / malformed store — start fresh (fail toward re-counting)
        if tool_use_id and tool_use_id in store["seen"]:
            prior = store["seen"][tool_use_id]
            escalated = bool(prior.get("escalated")) if isinstance(prior, dict) else False
            return (escalated, False)
        current = store["arms"].get(arm, 0)
        current = current + 1 if isinstance(current, int) else 1
        store["arms"][arm] = current
        escalated = current >= 2
        if tool_use_id:
            store["seen"][tool_use_id] = {"arm": arm, "escalated": escalated}
        with open(store_path, "w", encoding="utf-8") as fh:
            json.dump(store, fh)
        return (escalated, True)
    finally:
        try:
            fcntl.flock(lock_fh.fileno(), fcntl.LOCK_UN)
        except Exception:
            pass
        lock_fh.close()


def _run() -> None:
    # BOOKKEEPING NEVER DECIDES. The heartbeat and the counter store are telemetry; a
    # failure in either must not change the decision. Un-guarded, an unwritable
    # .devflow/tmp raised here — BEFORE any classification — and main()'s blanket handler
    # turned it into a `defer`, silently disarming the guard for the whole run. So the
    # store is best-effort and `tmp is None` simply means "classify, do not count".
    root = _repo_root()
    try:
        tmp = _tmp_dir(root)
        _write_heartbeat(tmp)  # every invocation, incl. a defer — the never-fired signal
    except Exception as exc:  # noqa: BLE001 - telemetry must never decide
        sys.stderr.write(
            "devflow: pretooluse-shape-guard: heartbeat/store unavailable "
            f"({type(exc).__name__}: {exc}); classifying anyway, denials go uncounted\n"
        )
        tmp = None

    raw = sys.stdin.buffer.read()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        _emit(_decision_object("defer", None))
        return
    if not text.strip():
        _emit(_decision_object("defer", None))
        return
    try:
        payload = json.loads(text)
    except ValueError:
        _emit(_decision_object("defer", None))
        return

    command = _read_command(payload)
    if command is None:
        _emit(_decision_object("defer", None))
        return

    tool_use_id = payload.get("tool_use_id") if isinstance(payload, dict) else None
    if not isinstance(tool_use_id, str) or not tool_use_id:
        tool_use_id = None

    shapes = _load_shapes_module()
    matched = _matched_arms(command, shapes)
    if not matched:
        _emit(_decision_object("defer", None))
        return

    # Deterministic tie-break: the first-sorting matched deny-set arm.
    arm = sorted(matched)[0]
    # The deny is already decided; counting it is telemetry. A store write that raises
    # must cost the ESCALATION, never the decision — an obstructed counts file used to
    # revoke an established deny and emit `defer` with no signal at all.
    escalated = False
    if tmp is not None:
        try:
            escalated, _incremented = _bump_counts(tmp, arm, tool_use_id)
        except Exception as exc:  # noqa: BLE001 - telemetry must never decide
            sys.stderr.write(
                "devflow: pretooluse-shape-guard: denial counter write failed "
                f"({type(exc).__name__}: {exc}); emitting the base remediation for "
                f"{arm} without escalation\n"
            )
    reason = REMEDIATION[arm]
    if escalated:
        reason = reason + _ABANDON.format(arm=arm)
    _emit(_decision_object("deny", reason))


def main() -> int:
    # Catch EVERY exception (BaseException, so a stubbed dependency's SystemExit at import
    # cannot escape) and fail open to defer. An uncaught internal error would exit
    # non-zero with no decision, which the workflow reports as never-fired for a guard
    # that ran. The heartbeat is best-effort inside _run and is itself covered here.
    try:
        _run()
    except BaseException as exc:
        # Name the failure on stderr. Without it a fully disarmed guard (a bash-stubbed
        # importlib dependency raising SyntaxError, a renamed shapes symbol, a wrong
        # repo root) is byte-identical on stdout to a clean run that matched nothing,
        # and the heartbeat says "fired" for both — so the only signal the operator
        # would have is the denied shapes reappearing.
        try:
            sys.stderr.write(
                "devflow: pretooluse-shape-guard: failed open to defer "
                f"({type(exc).__name__}: {exc}) — this command was NOT classified\n"
            )
        except Exception:
            pass
        try:
            _emit(_decision_object("defer", None))
        except Exception:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
