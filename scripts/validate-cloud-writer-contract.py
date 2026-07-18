#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Pre-agent validator for the devflow-cloud-writer-contract-v1 runtime manifest (AC18, #543).

Runs before a cloud writer agent boots and fails closed if the vendored runtime
manifest does not describe the installed plugin. Its rejection matrix is closed
at exactly seventeen classes, complete by construction from the v1 schema,
content binding, reachability binding, and profile check:

  1  ABSENT_FILE           the manifest file does not exist
  2  UNREADABLE_FILE       the manifest file cannot be read
  3  INVALID_JSON          the manifest is not valid JSON
  4  TOP_LEVEL_ARRAY       the top-level value is a JSON array
  5  TOP_LEVEL_STRING      the top-level value is a JSON string
  6  TOP_LEVEL_FALSE       the top-level value is the valid-falsy `false`
  7  MISSING_KEY           a required top-level key is absent
  8  EXTRA_KEY             an unexpected top-level key is present
  9  DUPLICATE_KEY         a key is duplicated in the JSON source
  10 WRONG_FIELD_TYPE      a field has the wrong JSON type
  11 MALFORMED_DIGEST      a files digest is not lowercase 64-hex
  12 INVALID_PATH          a files key is absolute or escapes the vendored root
  13 MISSING_ASSET         a listed file does not exist on disk
  14 HASH_MISMATCH         a listed file's recomputed hash differs
  15 REACHED_ASSET_OMITTED an AC1-reached asset is absent from `files`
  16 PROFILE_OMITTED       a required cloud profile is absent from required_helper_heads
  17 HEAD_ABSENT           a required helper head is absent from that profile's grants

Exit 0 == valid; exit 1 == one or more violations (each printed to stdout).
"""
from __future__ import annotations

import hashlib
import json
import posixpath
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]

PROTOCOL = "devflow-cloud-writer-contract-v1"
REQUIRED_KEYS = {"protocol", "legacy_profile_baseline", "files", "required_helper_heads"}
_HEX64 = re.compile(r"^[0-9a-f]{64}$")
_MANIFEST_DEFAULT = REPO_ROOT / "scripts" / "devflow-cloud-writer-contract.json"

# Rejection-class codes (the closed seventeen).
ABSENT_FILE = "ABSENT_FILE"
UNREADABLE_FILE = "UNREADABLE_FILE"
INVALID_JSON = "INVALID_JSON"
TOP_LEVEL_ARRAY = "TOP_LEVEL_ARRAY"
TOP_LEVEL_STRING = "TOP_LEVEL_STRING"
TOP_LEVEL_FALSE = "TOP_LEVEL_FALSE"
MISSING_KEY = "MISSING_KEY"
EXTRA_KEY = "EXTRA_KEY"
DUPLICATE_KEY = "DUPLICATE_KEY"
WRONG_FIELD_TYPE = "WRONG_FIELD_TYPE"
MALFORMED_DIGEST = "MALFORMED_DIGEST"
INVALID_PATH = "INVALID_PATH"
MISSING_ASSET = "MISSING_ASSET"
HASH_MISMATCH = "HASH_MISMATCH"
REACHED_ASSET_OMITTED = "REACHED_ASSET_OMITTED"
PROFILE_OMITTED = "PROFILE_OMITTED"
HEAD_ABSENT = "HEAD_ABSENT"


class _StopValidation(Exception):
    """Raised for a fatal load/shape failure — no further checks are meaningful."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def _no_duplicate_keys(pairs):
    """object_pairs_hook that rejects a duplicate key at any nesting level."""
    seen = {}
    for key, value in pairs:
        if key in seen:
            raise ValueError(f"duplicate key: {key!r}")
        seen[key] = value
    return seen


def _load(path):
    """Return the parsed top-level object or raise _StopValidation.

    Covers classes 1 (absent), 2 (unreadable), 3 (invalid JSON), 9 (duplicate key).
    """
    p = Path(path)
    if not p.exists():
        raise _StopValidation(ABSENT_FILE, f"manifest file does not exist: {path}")
    try:
        raw = p.read_text(encoding="utf-8")
    except OSError as exc:
        raise _StopValidation(UNREADABLE_FILE, f"manifest file unreadable: {exc}")
    except UnicodeDecodeError as exc:
        raise _StopValidation(UNREADABLE_FILE, f"manifest file not UTF-8: {exc}")
    try:
        return json.loads(raw, object_pairs_hook=_no_duplicate_keys)
    except ValueError as exc:
        msg = str(exc)
        if msg.startswith("duplicate key:"):
            raise _StopValidation(DUPLICATE_KEY, msg)
        raise _StopValidation(INVALID_JSON, f"manifest is not valid JSON: {exc}")


def _check_top_level_shape(obj):
    """Covers classes 4/5/6 and any other non-object top-level value."""
    if isinstance(obj, dict):
        return
    if isinstance(obj, list):
        raise _StopValidation(TOP_LEVEL_ARRAY, "top-level value is a JSON array")
    if isinstance(obj, str):
        raise _StopValidation(TOP_LEVEL_STRING, "top-level value is a JSON string")
    if obj is False:
        raise _StopValidation(TOP_LEVEL_FALSE, "top-level value is the valid-falsy `false`")
    raise _StopValidation(
        WRONG_FIELD_TYPE, f"top-level value is not an object (got {type(obj).__name__})"
    )


def _path_is_safe(key, base_dir):
    """A files key must be a relative path that stays beneath base_dir."""
    if key.startswith("/") or "\\" in key or posixpath.isabs(key):
        return False
    normalized = posixpath.normpath(key)
    if normalized == ".." or normalized.startswith("../"):
        return False
    resolved = (Path(base_dir) / normalized).resolve()
    base = Path(base_dir).resolve()
    return base == resolved or base in resolved.parents


def _sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def validate(
    manifest_path=None,
    *,
    base_dir=None,
    expected_assets=None,
    required_profiles=None,
    profile_grants=None,
):
    """Validate the manifest. Return a list of (code, message) violations.

    Dependencies are injectable so the closed rejection matrix is unit-testable:
      * expected_assets    — AC1-reached repo-relative asset paths (class 15)
      * required_profiles  — cloud profile ids that must be present (class 16)
      * profile_grants     — {profile: set(granted vendored heads)} (class 17)
    Defaults are derived from the sibling reachability contract and the workflows.
    """
    manifest_path = manifest_path or _MANIFEST_DEFAULT
    base_dir = base_dir if base_dir is not None else REPO_ROOT

    if expected_assets is None or required_profiles is None or profile_grants is None:
        contract = _load_contract_module()
        if expected_assets is None:
            expected_assets = contract.manifest_file_paths()
        if required_profiles is None:
            required_profiles = list(contract.ROOTS.keys())
        if profile_grants is None:
            profile_grants = {
                p: extract_profile_grants(base_dir / contract.ROOTS[p]["workflow"])
                for p in contract.ROOTS
            }

    try:
        obj = _load(manifest_path)
        _check_top_level_shape(obj)
    except _StopValidation as stop:
        return [(stop.code, stop.message)]

    violations = []

    # Classes 7/8: required and extra top-level keys.
    keys = set(obj)
    for missing in sorted(REQUIRED_KEYS - keys):
        violations.append((MISSING_KEY, f"required top-level key absent: {missing}"))
    for extra in sorted(keys - REQUIRED_KEYS):
        violations.append((EXTRA_KEY, f"unexpected top-level key: {extra}"))

    # Class 10: field types (and the exact protocol value).
    protocol = obj.get("protocol")
    if "protocol" in obj:
        if not isinstance(protocol, str):
            violations.append((WRONG_FIELD_TYPE, "protocol is not a string"))
        elif protocol != PROTOCOL:
            violations.append(
                (WRONG_FIELD_TYPE, f"protocol is {protocol!r}, expected {PROTOCOL!r}")
            )
    if "legacy_profile_baseline" in obj and not isinstance(
        obj.get("legacy_profile_baseline"), str
    ):
        violations.append((WRONG_FIELD_TYPE, "legacy_profile_baseline is not a string"))

    files = obj.get("files")
    if "files" in obj and not isinstance(files, dict):
        violations.append((WRONG_FIELD_TYPE, "files is not an object"))
        files = None
    heads = obj.get("required_helper_heads")
    if "required_helper_heads" in obj and not isinstance(heads, dict):
        violations.append((WRONG_FIELD_TYPE, "required_helper_heads is not an object"))
        heads = None

    # Classes 11/12/13/14: files content binding.
    if isinstance(files, dict):
        for rel, digest in sorted(files.items()):
            if not isinstance(digest, str) or not _HEX64.match(digest):
                violations.append((MALFORMED_DIGEST, f"malformed digest for {rel}: {digest!r}"))
                continue
            if not _path_is_safe(rel, base_dir):
                violations.append((INVALID_PATH, f"invalid or escaping relative path: {rel}"))
                continue
            disk = Path(base_dir) / rel
            if not disk.is_file():
                violations.append((MISSING_ASSET, f"listed file does not exist: {rel}"))
                continue
            actual = _sha256(disk)
            if actual != digest:
                violations.append(
                    (HASH_MISMATCH, f"hash mismatch for {rel}: manifest {digest}, disk {actual}")
                )

        # Class 15: every AC1-reached asset must appear in files.
        for rel in expected_assets:
            if rel not in files:
                violations.append(
                    (REACHED_ASSET_OMITTED, f"AC1-reached asset omitted from files: {rel}")
                )

    # Classes 16/17: profile binding.
    if isinstance(heads, dict):
        for profile in required_profiles:
            if profile not in heads:
                violations.append((PROFILE_OMITTED, f"required cloud profile omitted: {profile}"))
                continue
            declared = heads.get(profile)
            if not isinstance(declared, list):
                violations.append(
                    (WRONG_FIELD_TYPE, f"required_helper_heads[{profile}] is not a list")
                )
                continue
            granted = profile_grants.get(profile, set())
            for head in declared:
                if head not in granted:
                    violations.append(
                        (HEAD_ABSENT, f"required head absent from {profile} grants: {head}")
                    )

    return violations


def _load_contract_module():
    """Import the sibling AC1 reachability contract (lib/test/cloud_writer_contract.py)."""
    contract_dir = REPO_ROOT / "lib" / "test"
    if str(contract_dir) not in sys.path:
        sys.path.insert(0, str(contract_dir))
    import cloud_writer_contract  # noqa: E402

    return cloud_writer_contract


_GRANT_RE = re.compile(r"\.devflow/vendor/devflow/(?:scripts|lib)/[A-Za-z0-9._-]+")


def extract_profile_grants(workflow_path):
    """Return the set of vendored helper leading tokens granted in a workflow file."""
    try:
        text = Path(workflow_path).read_text(encoding="utf-8")
    except OSError:
        return set()
    return set(_GRANT_RE.findall(text))


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    manifest_path = argv[0] if argv else _MANIFEST_DEFAULT
    violations = validate(manifest_path)
    if violations:
        for code, message in violations:
            print(f"cloud-writer-contract INVALID [{code}]: {message}")
        return 1
    print("cloud-writer-contract: manifest valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
