#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Single-flight verification coordination ledger (issue #528, Wave 2).

A NON-executing coordination helper. It never launches the verification command,
never accepts an executable argv to run, spawns no subprocess, makes no network
call, and runs no `git` — it is a pure Python standard-library data-only state
machine over a local, per-checkout ledger. Existing callers keep ownership of the
already-authorized verification command; this helper only grants one owner claim,
records logical owner evidence, stores terminal evidence through a token-checked
compare-and-swap, and lets a later same-checkout caller attach and consume the
result. Missing, partial, timed-out, unreadable, and stale state never becomes a
pass and never authorizes an automatic relaunch.

Subcommands:
  descriptor    Print the immutable command descriptor digest + flight key for an
                input declaration (data only; callers cannot supply a static digest).
  claim         Atomically publish a `claimed` handle and mint a one-time owner
                token, OR attach to an existing flight for the same key — active or
                terminal (e.g. a `passed` flight to consume) — without a second owner.
  mark-running  Owner-only CAS: claimed -> running, recording logical owner evidence
                immediately before the caller launches its authorized command.
  finish        Owner-only CAS: running -> passed/failed/timed_out/cancelled with
                terminal evidence (suite summary, skip details, exit status).
  status        Read a flight (token redacted); report whether it satisfies
                verification. Applies lease-expiry (-> incomplete) and checkout
                drift (-> stale) read-transitions. Any unreadable/malformed shape is
                an attributable non-pass, never a pass.
  wait          Bounded, non-mutating poll for a terminal state; a wait-bound expiry
                returns a `wait_expired` observation and leaves an active flight
                unchanged.

State lives under .devflow/tmp/verification-flights/ (directory mode 0700,
file mode 0600), published atomically (O_CREAT|O_EXCL create for the single-owner
guarantee; temp + os.replace for updates), and is durable only within the current
checkout.

Determinism for tests: the wall clock is read through _now(), which honors the
DEVFLOW_FLIGHT_NOW epoch-seconds override so lease-expiry and duration are testable
without real sleeping.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import secrets
import sys
import time
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
DEFAULT_LEASE_SECONDS = 900  # bounded owner-token lease on a `claimed` handle
STATE_DIRNAME = os.path.join(".devflow", "tmp", "verification-flights")
LOGS_DIRNAME = os.path.join(".devflow", "logs", "verification-flight")

# The exact, exhaustive state set (issue #528 AC). Only `passed` (with complete,
# matching input + command bindings) satisfies verification.
ACTIVE_STATES = ("claimed", "running")
TERMINAL_STATES = ("passed", "failed", "timed_out", "cancelled", "stale", "incomplete")
ALL_STATES = ACTIVE_STATES + TERMINAL_STATES

# Exit codes — a shell caller gates reuse on `status`/`wait` exiting 0.
EXIT_OK = 0            # operation succeeded; for status/wait: state satisfies verification
EXIT_NON_PASS = 2     # read succeeded but the flight does NOT satisfy verification
EXIT_INVALID = 3      # invalid / incomplete declaration or arguments
EXIT_CAS_REJECT = 4   # ownership / transition compare-and-swap rejected
EXIT_UNREADABLE = 5   # state file missing, empty, truncated, or malformed
EXIT_WAIT_EXPIRED = 6  # wait bound elapsed with the flight still active


# ─────────────────────────────────────────────────────────────────────────────
# Time (test-overridable) and canonicalization
# ─────────────────────────────────────────────────────────────────────────────
def _now() -> float:
    """Wall-clock epoch seconds, overridable via DEVFLOW_FLIGHT_NOW for tests."""
    override = os.environ.get("DEVFLOW_FLIGHT_NOW")
    if override:
        try:
            return float(override)
        except ValueError:
            pass
    return time.time()


def _iso(epoch: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def _canonical(obj: Any) -> bytes:
    """Sorted-key, compact, UTF-8 JSON — the byte form fed to SHA-256."""
    return json.dumps(
        obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


# ─────────────────────────────────────────────────────────────────────────────
# Declaration validation + descriptor/flight-key derivation
# ─────────────────────────────────────────────────────────────────────────────
_PROFILE_REQUIRED = (
    "profile_version",
    "argv",
    "cwd",
    "environment",
    "toolchain",
    "dependencies",
    "output_roots",
    "external_services",
)
_CHECKOUT_REQUIRED = (
    "checkout_id",
    "head",
    "index_digest",
    "tracked_digest",
    "untracked_digest",
)


class DeclarationError(Exception):
    """An incomplete / non-hermetic declaration — reuse is disabled."""

    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


def _validate_profile(profile: Any) -> dict:
    if not isinstance(profile, dict):
        raise DeclarationError("profile_not_object")
    for key in _PROFILE_REQUIRED:
        if key not in profile:
            raise DeclarationError(f"profile_missing_field:{key}")
    # argv is a data descriptor operand, never an argv the helper will execute.
    if not isinstance(profile["argv"], list) or not profile["argv"]:
        raise DeclarationError("profile_argv_not_nonempty_list")
    if not all(isinstance(x, str) for x in profile["argv"]):
        raise DeclarationError("profile_argv_not_all_strings")
    if not isinstance(profile["cwd"], str) or not profile["cwd"]:
        raise DeclarationError("profile_cwd_not_nonempty_string")
    for key in ("environment", "toolchain", "dependencies"):
        if not isinstance(profile[key], dict):
            raise DeclarationError(f"profile_{key}_not_object")
    if not isinstance(profile["output_roots"], list):
        raise DeclarationError("profile_output_roots_not_list")
    # Hermeticity: only external_services == "none" is reusable. A profile that
    # declares any external service dependency is non-reusable by construction.
    if profile["external_services"] != "none":
        raise DeclarationError("non_hermetic_profile")
    return profile


def _validate_checkout(checkout: Any) -> dict:
    if not isinstance(checkout, dict):
        raise DeclarationError("checkout_not_object")
    for key in _CHECKOUT_REQUIRED:
        if key not in checkout:
            raise DeclarationError(f"checkout_missing_field:{key}")
        if not isinstance(checkout[key], str) or not checkout[key]:
            raise DeclarationError(f"checkout_incomplete_fingerprint:{key}")
    return checkout


def _descriptor_bytes(profile: dict) -> bytes:
    """The immutable command descriptor — the canonical JSON of the profile's
    identity operands only. Byte-distinct argv/cwd/environment/toolchain/
    dependency/profile_version inputs produce distinct descriptors."""
    ident = {
        "profile_version": profile["profile_version"],
        "argv": profile["argv"],
        "cwd": profile["cwd"],
        "environment": profile["environment"],
        "toolchain": profile["toolchain"],
        "dependencies": profile["dependencies"],
    }
    return _canonical(ident)


def _derive(declaration: Any) -> dict:
    """Validate a declaration and derive descriptor digest + flight key.

    Raises DeclarationError on any incomplete/non-hermetic input. The helper
    derives SHA-256 itself; a caller-supplied digest is never trusted.
    """
    if not isinstance(declaration, dict):
        raise DeclarationError("declaration_not_object")
    if declaration.get("schema_version") != SCHEMA_VERSION:
        raise DeclarationError("unknown_schema_version")
    profile = _validate_profile(declaration.get("profile"))
    checkout = _validate_checkout(declaration.get("checkout"))
    descriptor_digest = _sha256(_descriptor_bytes(profile))
    flight_key = _sha256(
        _canonical({"descriptor_digest": descriptor_digest, "checkout": checkout})
    )
    return {
        "descriptor_digest": descriptor_digest,
        "flight_key": flight_key,
        "profile": profile,
        "checkout": checkout,
    }


# ─────────────────────────────────────────────────────────────────────────────
# Ledger IO — atomic, owner-only-permission
# ─────────────────────────────────────────────────────────────────────────────
def _state_dir(root: str | None) -> Path:
    base = Path(root) if root else Path.cwd() / STATE_DIRNAME
    base.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(base, 0o700)
    except OSError:
        pass
    return base


def _flight_path(state_dir: Path, flight_key: str) -> Path:
    return state_dir / f"{flight_key}.json"


def _atomic_replace(path: Path, body: dict) -> None:
    data = _canonical(body)
    tmp = path.with_suffix(path.suffix + f".tmp.{os.getpid()}.{secrets.token_hex(4)}")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)
    os.replace(tmp, path)


class ReadError(Exception):
    """A flight file that is missing, empty, truncated, or malformed — a
    non-pass with an attributable reason, never inferred as terminal."""

    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


def _read_flight(path: Path) -> dict:
    try:
        raw = path.read_bytes()
    except FileNotFoundError:
        raise ReadError("missing")
    except OSError as exc:
        raise ReadError(f"unreadable:{exc.__class__.__name__}")
    if not raw.strip():
        raise ReadError("empty")
    try:
        obj = json.loads(raw.decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError):
        raise ReadError("malformed_json")
    if not isinstance(obj, dict):
        # array / scalar top-level payloads are not a flight handle.
        raise ReadError("not_object")
    if obj.get("schema_version") != SCHEMA_VERSION:
        raise ReadError("unknown_schema_version")
    state = obj.get("state")
    # `state` must be present and a member of the exact set; a wrong-typed value
    # such as the string "true" or a missing field is a non-pass, never coerced.
    if not isinstance(state, str) or state not in ALL_STATES:
        raise ReadError("missing_or_invalid_state")
    for field in ("flight_key", "descriptor_digest", "token_digest"):
        if not isinstance(obj.get(field), str) or not obj.get(field):
            raise ReadError(f"missing_field:{field}")
    return obj


# ─────────────────────────────────────────────────────────────────────────────
# Telemetry (best-effort, local, hermetic)
# ─────────────────────────────────────────────────────────────────────────────
def _emit_telemetry(logs_dir: str | None, event: str, payload: dict) -> None:
    """Append a per-event JSON record under .devflow/logs/verification-flight/.

    Best-effort and hermetic: a stale/incomplete handle is never recorded as
    saved work (callers pass suppressed_launch only on a genuine pass attach).
    A failure to write telemetry never fails the coordination operation.
    """
    try:
        base = Path(logs_dir) if logs_dir else Path.cwd() / LOGS_DIRNAME
        base.mkdir(parents=True, exist_ok=True)
        rec = {"event": event, "recorded_at": _iso(_now()), **payload}
        name = f"{event}-{secrets.token_hex(8)}.json"
        _atomic_replace(base / name, rec)
    except OSError:
        pass


# ─────────────────────────────────────────────────────────────────────────────
# Read-time transitions (lease expiry -> incomplete; checkout drift -> stale)
# ─────────────────────────────────────────────────────────────────────────────
def _apply_read_transitions(
    path: Path, flight: dict, current_checkout: dict | None
) -> dict:
    """Apply the two non-owner read-transitions, persisting if either fires.

    * A `claimed` handle whose owner-token lease has expired before mark-running
      becomes `incomplete` (owner loss at the claim boundary; the ledger never
      infers the unobserved command ran).
    * An active handle whose stored checkout no longer matches a supplied current
      checkout becomes `stale` (repository/environment drift invalidates reuse).

    Terminal handles are immutable — never re-transitioned.
    """
    state = flight["state"]
    if state not in ACTIVE_STATES:
        return flight

    # Drift first: a mismatched checkout invalidates regardless of lease.
    if current_checkout is not None and flight.get("checkout") != current_checkout:
        flight["state"] = "stale"
        flight["invalidation_reason"] = "checkout_drift"
        flight["finished_at"] = _iso(_now())
        _atomic_replace(path, flight)
        return flight

    if state == "claimed" and _lease_expired(flight):
        _expire_claim(path, flight)
    return flight


def _lease_expired(flight: dict) -> bool:
    """True when a `claimed` handle's owner-token lease has elapsed."""
    expiry = flight.get("lease_expiry_epoch")
    return isinstance(expiry, (int, float)) and _now() > expiry


def _expire_claim(path: Path, flight: dict) -> dict:
    """Transition a lease-expired `claimed` handle to `incomplete` and persist.

    The single writer of this transition — shared by the read-time path
    (`_apply_read_transitions`) and the owner's own `mark-running` guard — so the
    two can never drift on the mutation. The error *responses* stay distinct (a
    read-transition vs. a CAS reject); only the mutation is shared.
    """
    flight["state"] = "incomplete"
    flight["invalidation_reason"] = "lease_expired_before_running"
    flight["finished_at"] = _iso(_now())
    _atomic_replace(path, flight)
    return flight


def _satisfies(flight: dict) -> bool:
    """Only a `passed` terminal handle satisfies verification."""
    return flight["state"] == "passed"


def _public_view(flight: dict) -> dict:
    """A token-redacted view for status/wait output."""
    view = dict(flight)
    view["token_digest"] = "REDACTED"
    view["satisfies_verification"] = _satisfies(flight)
    return view


def _print_public(flight: dict, **extra) -> None:
    """Emit a token-redacted public view with ok=True plus any extra fields."""
    view = _public_view(flight)
    view["ok"] = True
    view.update(extra)
    _print(view)


# ─────────────────────────────────────────────────────────────────────────────
# Subcommand handlers
# ─────────────────────────────────────────────────────────────────────────────
def _load_json_arg(path_str: str) -> Any:
    data = Path(path_str).read_bytes()
    return json.loads(data.decode("utf-8"))


def _print(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj, sort_keys=True) + "\n")


def _derive_arg(input_file: str):
    """Load + derive a declaration file. Returns (derived, None) on success or
    (None, (payload, exit_code)) on an unreadable input or invalid declaration —
    the single shared preamble for `descriptor` and `claim`. An incomplete /
    non-hermetic declaration disables reuse (EXIT_INVALID)."""
    try:
        decl = _load_json_arg(input_file)
    except (OSError, json.JSONDecodeError, UnicodeDecodeError) as exc:
        return None, ({"ok": False, "result": "invalid", "reason": f"input:{exc.__class__.__name__}"}, EXIT_INVALID)
    try:
        return _derive(decl), None
    except DeclarationError as exc:
        return None, ({"ok": False, "result": "invalid", "reason": exc.reason}, EXIT_INVALID)


def cmd_descriptor(args) -> int:
    derived, err = _derive_arg(args.input_file)
    if err:
        _print(err[0])
        return err[1]
    _print(
        {
            "ok": True,
            "descriptor_digest": derived["descriptor_digest"],
            "flight_key": derived["flight_key"],
        }
    )
    return EXIT_OK


def cmd_claim(args) -> int:
    derived, err = _derive_arg(args.input_file)
    if err:
        _print(err[0])
        return err[1]

    state_dir = _state_dir(args.state_dir)
    path = _flight_path(state_dir, derived["flight_key"])
    now = _now()
    lease = args.lease_seconds if args.lease_seconds is not None else DEFAULT_LEASE_SECONDS
    # token_hex (not token_urlsafe): 256 bits of entropy, unguessable, but drawn
    # from [0-9a-f] only — so a minted token can never begin with '-' and be
    # mis-parsed as an option flag when passed as `--token <value>` on the CLI.
    token = secrets.token_hex(32)
    handle = {
        "schema_version": SCHEMA_VERSION,
        "flight_key": derived["flight_key"],
        "descriptor_digest": derived["descriptor_digest"],
        "profile_version": derived["profile"]["profile_version"],
        "checkout": derived["checkout"],
        "state": "claimed",
        "token_digest": _sha256(token.encode("utf-8")),
        "claimed_at": _iso(now),
        "claimed_at_epoch": now,
        "lease_seconds": lease,
        "lease_expiry_epoch": now + lease,
        "lease_expiry": _iso(now + lease),
        "running_at": None,
        "running_at_epoch": None,
        "owner_evidence": None,
        "finished_at": None,
        "result": None,
        "suite_summary": None,
        "skipped_checks": [],
        "invalidation_reason": None,
    }
    data = _canonical(handle)
    # Single-owner guarantee: O_CREAT|O_EXCL means at most one concurrent caller
    # wins the create; every other caller falls through to attach.
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            os.write(fd, data)
        finally:
            os.close(fd)
        _emit_telemetry(
            args.logs_dir, "flight_claimed",
            {"flight_key": derived["flight_key"], "descriptor_digest": derived["descriptor_digest"]},
        )
        _print(
            {
                "ok": True,
                "role": "owner",
                "flight_key": derived["flight_key"],
                "descriptor_digest": derived["descriptor_digest"],
                "state": "claimed",
                "token": token,  # printed exactly once, never persisted in cleartext
                "lease_expiry": handle["lease_expiry"],
            }
        )
        return EXIT_OK
    except FileExistsError:
        pass

    # A flight already exists for this exact key — attach without a second owner.
    try:
        flight = _read_flight(path)
    except ReadError as exc:
        _print({"ok": False, "result": "unreadable", "reason": exc.reason, "flight_key": derived["flight_key"]})
        return EXIT_UNREADABLE
    flight = _apply_read_transitions(path, flight, None)
    _emit_telemetry(
        args.logs_dir, "flight_attached",
        {"flight_key": derived["flight_key"], "attached_state": flight["state"]},
    )
    _print_public(flight, role="attacher")
    return EXIT_OK


def _cas_load(path: Path, token: str) -> tuple[dict | None, int, str]:
    """Load a flight and verify owner-token CAS. Returns (flight, exit, reason)."""
    try:
        flight = _read_flight(path)
    except ReadError as exc:
        return None, EXIT_UNREADABLE, exc.reason
    if _sha256(token.encode("utf-8")) != flight.get("token_digest"):
        # attacher / stale-token / replay-with-wrong-token
        return None, EXIT_CAS_REJECT, "token_mismatch"
    return flight, EXIT_OK, ""


def cmd_mark_running(args) -> int:
    state_dir = _state_dir(args.state_dir)
    path = _flight_path(state_dir, args.flight)
    flight, code, reason = _cas_load(path, args.token)
    if flight is None:
        _print({"ok": False, "result": "rejected", "reason": reason})
        return code
    # Lease must still be valid at the transition; an expired lease is owner loss.
    # Shares the single _expire_claim mutation with the read-transition path.
    if flight["state"] == "claimed" and _lease_expired(flight):
        _expire_claim(path, flight)
        _print({"ok": False, "result": "rejected", "reason": "lease_expired", "state": "incomplete"})
        return EXIT_CAS_REJECT
    if flight["state"] != "claimed":
        # replay (already running) or post-terminal transition
        _print({"ok": False, "result": "rejected", "reason": f"not_claimed:{flight['state']}"})
        return EXIT_CAS_REJECT
    now = _now()
    flight["state"] = "running"
    flight["running_at"] = _iso(now)
    flight["running_at_epoch"] = now
    flight["owner_evidence"] = args.evidence or "owner running verification command"
    _atomic_replace(path, flight)
    _print({"ok": True, "state": "running", "flight_key": args.flight})
    return EXIT_OK


def cmd_finish(args) -> int:
    state_dir = _state_dir(args.state_dir)
    path = _flight_path(state_dir, args.flight)
    flight, code, reason = _cas_load(path, args.token)
    if flight is None:
        _print({"ok": False, "result": "rejected", "reason": reason})
        return code
    if flight["state"] != "running":
        # A terminal handle is immutable; a claimed handle never skips running.
        _print({"ok": False, "result": "rejected", "reason": f"not_running:{flight['state']}"})
        return EXIT_CAS_REJECT

    summary = None
    skipped: list = []
    if args.summary_file:
        try:
            summary = _load_json_arg(args.summary_file)
        except (OSError, json.JSONDecodeError, UnicodeDecodeError) as exc:
            _print({"ok": False, "result": "rejected", "reason": f"summary:{exc.__class__.__name__}"})
            return EXIT_INVALID
        if isinstance(summary, dict) and isinstance(summary.get("skipped_checks"), list):
            skipped = summary["skipped_checks"]

    # Terminal evidence on a `passed`/`failed` result is not inferred as a clean
    # end from mere presence — the evidence gate is the one place the whole helper
    # decides a pass, so a *malformed* summary (a non-dict scalar/array, or an
    # empty `{}` carrying no command/exit/result fields) is the same unknown class
    # as an absent one and must NOT be recorded as `passed`: it becomes
    # `incomplete` and blocks any automatic relaunch. Only a non-empty object
    # counts as present terminal evidence.
    if args.result in ("passed", "failed") and not (isinstance(summary, dict) and summary):
        flight["state"] = "incomplete"
        flight["invalidation_reason"] = "missing_terminal_evidence"
        flight["finished_at"] = _iso(_now())
        _atomic_replace(path, flight)
        _print({"ok": False, "result": "incomplete", "reason": "missing_terminal_evidence"})
        return EXIT_CAS_REJECT

    now = _now()
    flight["state"] = args.result
    flight["result"] = args.result
    flight["finished_at"] = _iso(now)
    flight["finished_at_epoch"] = now
    flight["suite_summary"] = summary
    flight["skipped_checks"] = skipped
    running_epoch = flight.get("running_at_epoch")
    if isinstance(running_epoch, (int, float)):
        flight["command_duration_s"] = max(0.0, now - running_epoch)
    _atomic_replace(path, flight)
    _emit_telemetry(
        args.logs_dir, "flight_finished",
        {
            "flight_key": args.flight,
            "terminal_state": args.result,
            "command_duration_s": flight.get("command_duration_s"),
            "skipped_checks_count": len(skipped),
        },
    )
    _print({"ok": True, "state": args.result, "flight_key": args.flight})
    return EXIT_OK


def _read_and_report(args) -> tuple[dict | None, int, str]:
    state_dir = _state_dir(args.state_dir)
    path = _flight_path(state_dir, args.flight)
    current_checkout = None
    if getattr(args, "current_checkout_file", None):
        try:
            current_checkout = _load_json_arg(args.current_checkout_file)
        except (OSError, json.JSONDecodeError, UnicodeDecodeError) as exc:
            return None, EXIT_INVALID, f"current_checkout:{exc.__class__.__name__}"
    try:
        flight = _read_flight(path)
    except ReadError as exc:
        return None, EXIT_UNREADABLE, exc.reason
    flight = _apply_read_transitions(path, flight, current_checkout)
    return flight, EXIT_OK, ""


def cmd_status(args) -> int:
    flight, code, reason = _read_and_report(args)
    if flight is None:
        # Missing/unreadable/malformed shapes: attributable non-pass, never pass.
        _print({"ok": False, "result": "non_pass", "reason": reason, "satisfies_verification": False})
        return code if code != EXIT_OK else EXIT_UNREADABLE
    _print_public(flight)
    if _satisfies(flight):
        return EXIT_OK
    return EXIT_NON_PASS


def cmd_wait(args) -> int:
    state_dir = _state_dir(args.state_dir)
    path = _flight_path(state_dir, args.flight)
    deadline = time.monotonic() + max(0.0, args.timeout)
    poll = max(0.0, args.poll_interval)
    current_checkout = None
    if args.current_checkout_file:
        try:
            current_checkout = _load_json_arg(args.current_checkout_file)
        except (OSError, json.JSONDecodeError, UnicodeDecodeError) as exc:
            _print({"ok": False, "result": "non_pass", "reason": f"current_checkout:{exc.__class__.__name__}", "satisfies_verification": False})
            return EXIT_INVALID

    last_reason = "missing"
    while True:
        try:
            flight = _read_flight(path)
            flight = _apply_read_transitions(path, flight, current_checkout)
            if flight["state"] in TERMINAL_STATES:
                _print_public(flight)
                _emit_telemetry(
                    args.logs_dir, "flight_wait_completed",
                    {"flight_key": args.flight, "terminal_state": flight["state"]},
                )
                return EXIT_OK if _satisfies(flight) else EXIT_NON_PASS
            last_reason = f"active:{flight['state']}"
        except ReadError as exc:
            last_reason = exc.reason
        if time.monotonic() >= deadline:
            break
        # A caller-requested busy poll (--poll-interval 0) is floored to 50ms so
        # the loop never spins hot; the top-of-loop deadline check terminates it.
        time.sleep(poll if poll > 0 else 0.05)

    # Wait bound elapsed with the flight still active/unreadable: a NON-mutating
    # observation. An active flight is left exactly as it was — the owner alone
    # records a terminal `timed_out` after its command reports a real timeout.
    _print({"ok": False, "result": "wait_expired", "reason": last_reason, "satisfies_verification": False})
    return EXIT_WAIT_EXPIRED


# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────
def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="verification-flight.py",
        description="Single-flight verification coordination ledger (issue #528). "
        "Data-only: launches no subprocess and accepts no executable argv.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    def add_common(p):
        p.add_argument("--state-dir", default=None, help="Override the flight state directory (default: <cwd>/.devflow/tmp/verification-flights).")
        p.add_argument("--logs-dir", default=None, help="Override the telemetry logs directory.")

    p_desc = sub.add_parser("descriptor", help="Print the descriptor digest + flight key for a declaration.")
    p_desc.add_argument("--input-file", required=True)
    add_common(p_desc)
    p_desc.set_defaults(func=cmd_descriptor)

    p_claim = sub.add_parser("claim", help="Atomically claim a flight or attach to a matching active one.")
    p_claim.add_argument("--input-file", required=True)
    p_claim.add_argument("--lease-seconds", type=int, default=None)
    add_common(p_claim)
    p_claim.set_defaults(func=cmd_claim)

    p_run = sub.add_parser("mark-running", help="Owner-only CAS: claimed -> running.")
    p_run.add_argument("--flight", required=True)
    p_run.add_argument("--token", required=True)
    p_run.add_argument("--evidence", default=None)
    add_common(p_run)
    p_run.set_defaults(func=cmd_mark_running)

    p_fin = sub.add_parser("finish", help="Owner-only CAS: running -> terminal with evidence.")
    p_fin.add_argument("--flight", required=True)
    p_fin.add_argument("--token", required=True)
    p_fin.add_argument("--result", required=True, choices=("passed", "failed", "timed_out", "cancelled"))
    p_fin.add_argument("--summary-file", default=None)
    add_common(p_fin)
    p_fin.set_defaults(func=cmd_finish)

    p_stat = sub.add_parser("status", help="Read a flight; report whether it satisfies verification.")
    p_stat.add_argument("--flight", required=True)
    p_stat.add_argument("--current-checkout-file", default=None)
    add_common(p_stat)
    p_stat.set_defaults(func=cmd_status)

    p_wait = sub.add_parser("wait", help="Bounded, non-mutating poll for a terminal state.")
    p_wait.add_argument("--flight", required=True)
    p_wait.add_argument("--timeout", type=float, required=True)
    p_wait.add_argument("--poll-interval", type=float, default=2.0)
    p_wait.add_argument("--current-checkout-file", default=None)
    add_common(p_wait)
    p_wait.set_defaults(func=cmd_wait)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
