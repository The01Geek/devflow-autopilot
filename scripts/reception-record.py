#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Receiving-review session artifact producer (issue #668).

One invocation of `record` derives the content-based candidate identity (via the
importable scripts/reception_identity.py — exactly one implementation of the
identity format ships), mints a per-session cryptographic claim-context nonce,
and writes two durable session artifacts plus a fixed-name session pointer under
the gitignored session directory. `append-disposition` appends one per-finding
disposition to the session's findings ledger, assigning the finding identifier
itself so no consumer joins against a hand-authored key.

Subcommands:
  record              Derive identity + mint token + write both artifacts and the
                      pointer in one call; print a JSON object to stdout carrying
                      `claim_context_token`, `candidate_identity`, `rebound_from`,
                      and the three artifact paths (`identity_path`,
                      `findings_path`, `pointer_path`). Idempotent in shape for an existing
                      --token: the findings ledger is preserved, not reset, and
                      the identity artifact is rewritten with a FRESHLY re-derived
                      candidate identity — equal to the recorded one only for an
                      unchanged working tree. A re-record after an edit therefore
                      rebinds the token to the new content identity by design (the
                      preflight re-runs on compaction/resume against a possibly
                      edited tree); read the artifact, never a remembered value.
                      A rebind is never silent: the stdout record carries
                      `rebound_from` (the superseded identity, else null) and a
                      `candidate_identity_rebound` warning record is written to
                      stderr, so a consumer holding the old value can detect the
                      change instead of assuming continuity. An unchanged tree
                      re-derives the same value and emits no warning. When the
                      prior identity artifact exists but cannot be read (any
                      degraded shape), the rebind is UNDETERMINED, not absent:
                      `rebound_from` is the literal `"unknown"` and a
                      `prior_identity_unreadable` warning names the reason — a
                      null there is the positive claim "identity unchanged" and
                      must never stand in for "could not tell".
  append-disposition  Append one disposition to the findings ledger with a
                      helper-assigned finding id. A deferral-class disposition must
                      name one of the skill's four durable channels; a channel-less
                      deferral is rejected with a named breadcrumb.

Failure discipline (mirrors scripts/verification-flight.py): every error path
writes an attributable {"ok": false, "reason": …} record to STDERR, prints
nothing a caller would read as a derived identity on stdout, and exits non-zero.
Before writing any artifact — on BOTH the `record` and `append-disposition`
paths, since `--session-dir` is per-invocation and nothing binds an append to the
directory a prior record validated — the helper confirms its session directory is
ignored through git's own ignore resolution (`git check-ignore`), so a repository
lacking the ignore rule is reported rather than given a self-invalidating
identity.

Data-only besides git: no `gh` call, no network call, no PyYAML, and no decisive
value derived through a non-preflight PATH tool.
"""

from __future__ import annotations

import argparse
import json
import os
import secrets
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import reception_identity as ri  # noqa: E402

SCHEMA_VERSION = 1
SESSION_DIRNAME = os.path.join(".devflow", "tmp", "reception-sessions")
POINTER_NAME = "current-session.json"
GIT = os.environ.get("DEVFLOW_GIT") or "git"

DIR_MODE = 0o700
FILE_MODE = 0o600

# Disposition vocabulary (closed). A deferral-class disposition must name a
# channel; `fixed` needs none.
DISPOSITION_KINDS = ("fixed", "deferred", "pushback", "disclosed")
# DERIVED, never restated: a second literal here would be a coupled mirror that
# silently drifts the moment DISPOSITION_KINDS gains a member.
DEFERRAL_KINDS = frozenset(DISPOSITION_KINDS) - {"fixed"}

# Deferred review findings (PR #681 reception pass) — WHAT / WHY / revisit:
#   * Non-atomic three-artifact write: a mid-sequence OSError can leave an
#     orphaned identity.json. WHY deferred: fails CLOSED — the caller sees
#     write_failed, and FOR A FRESH TOKEN the pointer is written last, so no
#     consumer reads a partial session; the residue is debris, not a wrong
#     value. Scope limit (PR #681 review): on a RE-record the prior pointer
#     already exists, so a mid-sequence failure leaves a live pointer addressing
#     a half-rewritten session — still fail-closed to the caller, but detectable
#     only by re-running. Each individual artifact write is itself atomic
#     (temp file + os.replace), so no artifact is ever left truncated. Revisit if
#     a consumer is ever added that reads identity.json without the pointer.
#   * append-disposition is a lock-free read-modify-write with position-derived
#     finding ids; two concurrent appends can collide and lose one. WHY
#     deferred: SINGLE-WRITER BY DESIGN — one reception pass owns one session
#     token. Revisit if dispositions are ever appended from parallel agents.
#   * A `fixed` disposition may still carry a --channel (permissive guard), and
#     the reused --token path validates charset but not length. WHY deferred:
#     both fail closed or are harmless-permissive; neither admits a wrong
#     identity. Revisit if a consumer keys behavior off channel-on-fixed.
#   * IdentityError.reason's closed vocabulary is documented but not enforced as
#     a type. WHY deferred: reasons are asserted by the test suite's breadcrumb
#     pins. Revisit if reasons become a consumed API rather than diagnostics.
# The skill's four durable deferral channels, in its stated order of preference.
CHANNELS = ("loop-record", "code-comment", "pr-thread", "follow-up-issue")

# Token charset guard: token_hex yields [0-9a-f]+, so an artifact filename key is
# always a safe basename with no path separator and never begins with '-'.
_TOKEN_LEN_HEX = 32  # 16 random bytes


def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _fail(reason: str, code: int = 1) -> int:
    sys.stderr.write(json.dumps({"ok": False, "reason": reason}) + "\n")
    return code


def _atomic_write_json(path: Path, obj: dict) -> None:
    """Write JSON atomically (temp file + os.replace); 0600 file, 0700 dir best-effort.

    The file mode is a real guarantee; the directory mode is attempted and its
    failure is non-fatal but never silent — the directory holds the session
    FILENAMES, which embed the claim-context nonce, so a world-readable session
    directory leaks the nonce to `ls` even with owner-only files.
    """
    parent = path.parent
    parent.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(parent, DIR_MODE)
    except OSError as exc:
        # Non-fatal (the 0600 file mode below is the real guard) but attributable:
        # a silent failure here hides a nonce-leaking directory permission.
        sys.stderr.write(
            json.dumps(
                {
                    "ok": True,
                    "warning": "session_dir_chmod_failed",
                    "reason": exc.__class__.__name__,
                    "path": str(parent),
                },
                sort_keys=True,
            )
            + "\n"
        )
    data = (json.dumps(obj, sort_keys=True, indent=2) + "\n").encode("utf-8")
    fd, tmp = tempfile.mkstemp(dir=str(parent), prefix=".rr-")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, FILE_MODE)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass


def _read_json_object(path: Path) -> "tuple[dict | None, str | None]":
    """Read a JSON *object* artifact, applying the six-shape adversarial matrix.

    Returns (obj, None) for a real object, or (None, reason) for every degraded
    shape. The reason vocabulary is CLOSED and caller-visible (callers
    interpolate it into `existing_findings_{reason}` / `findings_{reason}`
    breadcrumbs), so it is enumerated here in full:

      * object                              -> (obj, None)
      * array / scalar / valid-falsy /
        wrong-type                          -> `not_object`
      * absent file                         -> `missing`
      * present but unopenable (EACCES,
        EISDIR, ...)                        -> `unreadable:<ExceptionClass>`
      * empty or whitespace-only            -> `empty`
      * truncated or non-UTF-8              -> `malformed`

    No shape yields a value a caller would read as a valid ledger.
    """
    try:
        raw = path.read_bytes()
    except FileNotFoundError:
        return None, "missing"
    except OSError as exc:
        return None, f"unreadable:{exc.__class__.__name__}"
    if not raw.strip():
        return None, "empty"
    try:
        obj = json.loads(raw.decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError):
        return None, "malformed"
    if not isinstance(obj, dict):
        # array, scalar, and the valid-falsy JSON `false`/`0`/`""` all land here.
        return None, "not_object"
    return obj, None


def _repo_root(args) -> str:
    """Resolve the repository root for the DEFAULT session-dir path.

    CLAUDE.md's SHARED REPO-ROOT CONFIG CONTRACT (#295): a `.devflow/` default
    path anchors on the git repo ROOT — resolved through a native `git` subprocess
    (Windows-safe, like the `gh` callers; never a `.sh` exec) — falling back to the
    cwd when there is no git root. A cwd-anchored default composes
    `<subdir>/.devflow/...` for a run started from a subdirectory, which the
    root-anchored ignore rule cannot match, so the helper refuses with an
    ignore-rule breadcrumb whose remedy would not fix it.

    A non-empty explicit `--repo-root` is honored verbatim; root anchoring
    applies only to the default.
    """
    if args.repo_root:
        return args.repo_root
    try:
        proc = subprocess.run(  # noqa: S603 - argv list, no shell
            [GIT, "rev-parse", "--show-toplevel"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        return os.getcwd()
    if proc.returncode != 0:
        return os.getcwd()
    try:
        top = proc.stdout.decode("utf-8").strip()
    except UnicodeDecodeError:
        return os.getcwd()
    return top or os.getcwd()


def _check_ledger_tags(record: dict, token: str) -> "str | None":
    """Verify a findings ledger's own discriminators before it is joined.

    `kind` and `claim_context_token` are written as discriminators; reading a
    ledger without checking them means a ledger belonging to a DIFFERENT session
    (or an artifact of a different kind entirely) is accepted verbatim so long
    as it carries a list-valued `findings`. That is the one degraded shape the
    six-shape matrix cannot catch, because the object is structurally valid — it
    yields a valid-LOOKING ledger rather than a refusal.

    Returns a named reason, or None when the tags agree.
    """
    kind = record.get("kind")
    if kind is not None and kind != "reception-findings":
        return "findings_wrong_kind"
    recorded = record.get("claim_context_token")
    if recorded is not None and recorded != token:
        return "findings_token_mismatch"
    return None


def _session_dir(args) -> Path:
    if args.session_dir:
        return Path(args.session_dir)
    return Path(_repo_root(args)) / SESSION_DIRNAME


def _check_ignored(sample_path: Path, cwd: str) -> "bool | None":
    """Return True if `sample_path` is gitignored, False if not, None if git
    could not answer (breadcrumb-and-fail-closed at the call site).

    Uses git's own ignore resolution — `git check-ignore -q` answers for a path
    that need not yet exist — never a path-shape assumption.
    """
    try:
        proc = subprocess.run(  # noqa: S603 - argv list, no shell
            [GIT, "check-ignore", "-q", str(sample_path)],
            cwd=cwd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        return None
    if proc.returncode == 0:
        return True
    if proc.returncode == 1:
        return False
    return None  # 128 (not a git repo / error) is undecidable -> fail closed


def _paths(session_dir: Path, token: str) -> "tuple[Path, Path, Path]":
    return (
        session_dir / f"{token}.identity.json",
        session_dir / f"{token}.findings.json",
        session_dir / POINTER_NAME,
    )


def cmd_record(args) -> int:
    cwd = _repo_root(args)

    # Derive the identity FIRST — before any artifact write — so the artifacts the
    # write creates are excluded from the identity this same invocation derived.
    try:
        candidate_identity = ri.derive_candidate_identity(cwd)
    except ri.IdentityError as exc:
        return _fail(f"identity:{exc.reason}")

    token = args.token or secrets.token_hex(_TOKEN_LEN_HEX // 2)
    if not token or any(c not in "0123456789abcdef" for c in token):
        return _fail("invalid_token")

    session_dir = _session_dir(args)
    identity_path, findings_path, pointer_path = _paths(session_dir, token)

    # Confirm the session directory is ignored BEFORE writing, through git.
    ignored = _check_ignored(identity_path, cwd)
    if ignored is None:
        return _fail("ignore_check_failed:git-could-not-resolve-ignore-state")
    if ignored is False:
        return _fail(
            "session_dir_not_ignored:add-'/.devflow/*'-or-'.devflow/tmp/'-to-.gitignore"
        )

    created_at = _now_iso()
    identity_record = {
        "schema_version": SCHEMA_VERSION,
        "kind": "reception-identity",
        "claim_context_token": token,
        "candidate_identity": candidate_identity,
        "created_at": created_at,
    }

    # Preserve an existing findings ledger for an idempotent re-invocation; a
    # fresh token seeds an empty ledger. A malformed existing ledger is rejected
    # rather than silently reset (that would drop recorded dispositions).
    findings_record = {
        "schema_version": SCHEMA_VERSION,
        "kind": "reception-findings",
        "claim_context_token": token,
        "findings": [],
    }
    if findings_path.exists():
        existing, reason = _read_json_object(findings_path)
        if existing is None:
            return _fail(f"existing_findings_{reason}")
        tag_reason = _check_ledger_tags(existing, token)
        if tag_reason:
            return _fail(f"existing_{tag_reason}")
        prior = existing.get("findings")
        if not isinstance(prior, list):
            return _fail("existing_findings_not_list")
        findings_record["findings"] = prior

    # Surface a rebind. The identity is re-derived on every invocation, so a re-record
    # under an existing token whose tree changed silently rebinds that token to a new
    # content identity — the AC calls the identity artifact idempotent, and it is only
    # so for an unchanged tree. Rebinding is the correct behaviour for a CONTENT
    # identity (the #545 compaction/resume re-run depends on it), so this does not
    # fail: it emits one stderr breadcrumb naming both values, and reports the rebind
    # on stdout so a consumer holding the old value can detect it rather than assume
    # continuity. An unchanged tree re-derives the same value and emits nothing.
    rebound_from = None
    if identity_path.exists():
        prior_identity, prior_reason = _read_json_object(identity_path)
        if prior_identity is None:
            # UNDETERMINED, not absent. `rebound_from: null` is the positive claim
            # "the identity did not change"; emitting it for an artifact we could
            # not read would assert continuity across an overwrite we cannot
            # verify — the fail-open this arm exists to close. The write still
            # proceeds (a degraded prior must not block the session), but the
            # caller is told the comparison could not be made.
            rebound_from = "unknown"
            sys.stderr.write(
                json.dumps(
                    {
                        "ok": True,
                        "warning": "prior_identity_unreadable",
                        "reason": prior_reason,
                        "claim_context_token": token,
                        "candidate_identity": candidate_identity,
                    },
                    sort_keys=True,
                )
                + "\n"
            )
        else:
            prior_value = prior_identity.get("candidate_identity")
            if isinstance(prior_value, str) and prior_value != candidate_identity:
                rebound_from = prior_value
                sys.stderr.write(
                    json.dumps(
                        {
                            "ok": True,
                            "warning": "candidate_identity_rebound",
                            "claim_context_token": token,
                            "previous_candidate_identity": prior_value,
                            "candidate_identity": candidate_identity,
                        },
                        sort_keys=True,
                    )
                    + "\n"
                )

    pointer_record = {
        "schema_version": SCHEMA_VERSION,
        "kind": "reception-session-pointer",
        "claim_context_token": token,
        "identity_path": str(identity_path),
        "findings_path": str(findings_path),
        "updated_at": created_at,
    }

    try:
        _atomic_write_json(identity_path, identity_record)
        _atomic_write_json(findings_path, findings_record)
        _atomic_write_json(pointer_path, pointer_record)
    except OSError as exc:
        return _fail(f"write_failed:{exc.__class__.__name__}")

    sys.stdout.write(
        json.dumps(
            {
                "ok": True,
                "claim_context_token": token,
                "candidate_identity": candidate_identity,
                "rebound_from": rebound_from,
                "identity_path": str(identity_path),
                "findings_path": str(findings_path),
                "pointer_path": str(pointer_path),
            },
            sort_keys=True,
        )
        + "\n"
    )
    return 0


def cmd_append_disposition(args) -> int:
    if args.disposition in DEFERRAL_KINDS and not args.channel:
        return _fail(f"deferral_missing_channel:one-of-{'/'.join(CHANNELS)}")
    if args.channel and args.channel not in CHANNELS:
        return _fail(f"unknown_channel:one-of-{'/'.join(CHANNELS)}")

    token = args.token
    if not token or any(c not in "0123456789abcdef" for c in token):
        return _fail("invalid_token")

    cwd = _repo_root(args)
    session_dir = _session_dir(args)
    _, findings_path, _ = _paths(session_dir, token)

    # Confirm the session directory is ignored BEFORE writing, exactly as cmd_record
    # does. --session-dir is a per-invocation argument, so nothing binds this call to
    # the directory a prior `record` validated: without this check an append pointed at
    # a non-ignored --session-dir writes a TRACKED artifact, which then becomes part of
    # the very working-tree content derive_candidate_identity() hashes — the
    # self-invalidating-identity condition the precondition exists to prevent.
    ignored = _check_ignored(findings_path, cwd)
    if ignored is None:
        return _fail("ignore_check_failed:git-could-not-resolve-ignore-state")
    if ignored is False:
        return _fail(
            "session_dir_not_ignored:add-'/.devflow/*'-or-'.devflow/tmp/'-to-.gitignore"
        )

    record, reason = _read_json_object(findings_path)
    if record is None:
        return _fail(f"findings_{reason}")
    tag_reason = _check_ledger_tags(record, token)
    if tag_reason:
        return _fail(tag_reason)
    findings = record.get("findings")
    if not isinstance(findings, list):
        return _fail("findings_not_list")

    finding_id = f"f{len(findings) + 1:03d}"
    entry = {
        "finding_id": finding_id,
        "summary": args.summary,
        "disposition": args.disposition,
        "channel": args.channel,
        "severity": args.severity,
        "recorded_at": _now_iso(),
    }
    findings.append(entry)
    record["findings"] = findings

    try:
        _atomic_write_json(findings_path, record)
    except OSError as exc:
        return _fail(f"write_failed:{exc.__class__.__name__}")

    sys.stdout.write(
        json.dumps(
            {"ok": True, "finding_id": finding_id, "claim_context_token": token},
            sort_keys=True,
        )
        + "\n"
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="reception-record.py",
        description="Receiving-review session artifact producer (issue #668).",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    def add_common(p):
        p.add_argument("--session-dir", default=None,
                       help="Override the session artifact directory (default: "
                            "<repo>/.devflow/tmp/reception-sessions).")
        p.add_argument("--repo-root", default=None,
                       help="Repository root to derive from (default: cwd).")

    p_rec = sub.add_parser("record", help="Derive identity, mint token, write artifacts.")
    p_rec.add_argument("--token", default=None,
                       help="Reuse an existing token (idempotent); omit to mint one.")
    add_common(p_rec)
    p_rec.set_defaults(func=cmd_record)

    p_app = sub.add_parser("append-disposition", help="Append one finding disposition.")
    p_app.add_argument("--token", required=True)
    p_app.add_argument("--summary", required=True)
    p_app.add_argument("--disposition", required=True, choices=DISPOSITION_KINDS)
    p_app.add_argument("--channel", default=None, choices=CHANNELS)
    p_app.add_argument("--severity", default=None)
    add_common(p_app)
    p_app.set_defaults(func=cmd_append_disposition)

    return parser


def main(argv: "list[str] | None" = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except Exception as exc:  # noqa: BLE001 - contract: no bare traceback escapes
        # The module contract is that EVERY error path emits the attributable
        # {"ok": false, "reason": ...} record. Without this arm a residual
        # exception (a non-serializable value reaching json.dumps, an OSError
        # subclass raised outside a guarded block) escaped as a raw traceback —
        # a shape no consumer parsing the contracted record reads as a failure.
        # The class name keeps it attributable without leaking the message.
        return _fail(f"internal_error:{exc.__class__.__name__}")


if __name__ == "__main__":
    raise SystemExit(main())
