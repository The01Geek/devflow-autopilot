#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""CI-side coverage-map key-retention check (issue #1194).

The JSON-aware merge driver (`lib/test/coverage-map-merge-driver.py`) removes the
adjacent-key conflict class on the LOCAL merge/rebase path, but it is client-side
only: it does not run on GitHub's servers or in the web conflict editor, and it does
nothing for a client that never registered it. This check covers that residual path.
It runs in CI (so it does not depend on any local configuration) and at the desk
against the same inputs.

It compares the coverage map at the merge base against the map in the working tree
(which is HEAD in a fresh CI checkout) and fails when a key present in the base is
absent from the head result — in EITHER half (`files` and `run_sh_blocks`), including
the curated `run_sh_blocks` keys with no live derivation that no coverage-guard arm
reports — or when a key survived but its `note`
or `owner` content was DROPPED (non-empty at base, empty/absent at head). This is
exactly the population no guard arm inspects, and it is where a semantic-free conflict
resolved by taking one side silently discards a recorded coverage decision.

A legitimate removal (a deleted tracked file, a genuinely retired block) is declared
through the escape hatch `lib/test/coverage-map-retention-allow.json`: a JSON array of
`{"half", "key", "reason"}` objects. The escape hatch cannot be satisfied by an empty
or absent declaration — a matching entry must carry a non-empty `reason`.

Pure core (`detect_losses`) so the focused test drives every arm from in-memory
fixtures; the CLI resolves the base map through git and reads the head map from the
working tree.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

MAP_REL = "lib/test/modules/coverage-map.json"
ALLOW_REL = "lib/test/coverage-map-retention-allow.json"
HALVES = ("files", "run_sh_blocks")
# The per-entry fields whose DROP (non-empty → empty/absent, key surviving) is a loss.
# A legitimate change of `owner` from one non-empty module to another is NOT a drop and
# is deliberately not flagged; only emptying/removing recorded content is.
CONTENT_FIELDS = ("note", "owner")


def _allow_index(allow_value: object) -> "tuple[set[tuple[str, str]], list[str]]":
    """Return ({(half, key) with a non-empty reason}, [breadcrumbs]).

    A malformed allowlist is fail-closed: it contributes NO permitted removals and a
    breadcrumb, so a broken escape hatch can never launder a loss into a pass."""
    permitted: "set[tuple[str, str]]" = set()
    errors: "list[str]" = []
    if allow_value is None:
        return permitted, errors
    if not isinstance(allow_value, list):
        errors.append(f"{ALLOW_REL} must be a JSON array of {{half, key, reason}} objects")
        return permitted, errors
    for index, entry in enumerate(allow_value):
        if not isinstance(entry, dict):
            errors.append(f"{ALLOW_REL}[{index}] is not an object")
            continue
        half = entry.get("half")
        key = entry.get("key")
        reason = entry.get("reason")
        if half not in HALVES:
            errors.append(f"{ALLOW_REL}[{index}] 'half' must be one of {HALVES}")
            continue
        if not isinstance(key, str) or not key:
            errors.append(f"{ALLOW_REL}[{index}] 'key' must be a non-empty string")
            continue
        if not isinstance(reason, str) or not reason.strip():
            # The escape hatch cannot be satisfied by an empty/absent declaration.
            errors.append(
                f"{ALLOW_REL}[{index}] ({half}:{key}) carries no non-empty 'reason' — "
                "a legitimate removal must state why"
            )
            continue
        permitted.add((half, key))
    return permitted, errors


def _content(entry: object, field: str) -> str:
    """The stripped string content of ENTRY[FIELD], or '' when absent/blank/non-string."""
    if not isinstance(entry, dict):
        return ""
    value = entry.get(field, "")
    return value.strip() if isinstance(value, str) else ""


def detect_losses(base_map: object, head_map: object, allow_value: object) -> "list[str]":
    """Return retention violations (empty ⇒ clean). Pure — never raises, never reads a file.

    A base or head that is not a well-shaped map contributes a fail-closed breadcrumb
    rather than being read as 'no keys' — an unestablished comparand is never a pass."""
    violations: "list[str]" = []
    permitted, allow_errors = _allow_index(allow_value)
    violations.extend(f"[retain] {e}" for e in allow_errors)

    if not isinstance(base_map, dict):
        return violations + [f"[retain] base {MAP_REL} is not a JSON object — comparand unestablished"]
    if not isinstance(head_map, dict):
        return violations + [f"[retain] head {MAP_REL} is not a JSON object — comparand unestablished"]

    for half in HALVES:
        base_half = base_map.get(half, {})
        head_half = head_map.get(half, {})
        if not isinstance(base_half, dict):
            violations.append(f"[retain] base {MAP_REL} '{half}' is not an object — comparand unestablished")
            continue
        if not isinstance(head_half, dict):
            violations.append(f"[retain] head {MAP_REL} '{half}' is not an object — comparand unestablished")
            continue
        for key in sorted(base_half):
            if key not in head_half:
                if (half, key) in permitted:
                    continue
                violations.append(
                    f"[retain] {half} key {key!r} was present in the merge base but is absent "
                    f"from the head {MAP_REL} — a merge/resolution dropped it; restore it, or "
                    f"declare the removal with a reason in {ALLOW_REL}"
                )
                continue
            for field in CONTENT_FIELDS:
                base_content = _content(base_half[key], field)
                head_content = _content(head_half[key], field)
                if base_content and not head_content:
                    if (half, key) in permitted:
                        continue
                    violations.append(
                        f"[retain] {half} key {key!r} survived but its {field!r} content was "
                        f"dropped (non-empty at the merge base, empty at head) — restore it, or "
                        f"declare it with a reason in {ALLOW_REL}"
                    )
    return violations


def _git_show_json(repo_root: Path, ref: str, rel: str) -> "tuple[object, str | None]":
    """Parse `git show <ref>:<rel>` as JSON. Returns (value, error).

    A path absent at REF (the map did not exist there) is the empty map, not an error."""
    try:
        result = subprocess.run(
            ["git", "-C", str(repo_root), "show", f"{ref}:{rel}"],
            capture_output=True,
            text=True,
            check=False,
        )
    except (FileNotFoundError, OSError) as error:
        return None, f"git show {ref}:{rel} failed ({error})"
    if result.returncode != 0:
        stderr = result.stderr.strip().lower()
        if "does not exist" in stderr or "exists on disk, but not in" in stderr:
            return {}, None
        return None, f"git show {ref}:{rel} failed: {result.stderr.strip()}"
    try:
        return json.loads(result.stdout), None
    except json.JSONDecodeError as error:
        return None, f"{ref}:{rel} is malformed JSON ({error})"


def _merge_base(repo_root: Path, base_ref: str) -> "tuple[str | None, str | None]":
    """The merge base of HEAD and BASE_REF, or (None, breadcrumb). Falls back to BASE_REF
    itself when a merge base cannot be computed (a shallow clone) — reading BASE_REF's map
    directly is still a sound 'what did the base carry' comparand."""
    try:
        result = subprocess.run(
            ["git", "-C", str(repo_root), "merge-base", "HEAD", base_ref],
            capture_output=True,
            text=True,
            check=False,
        )
    except (FileNotFoundError, OSError) as error:
        return None, f"git merge-base failed ({error})"
    if result.returncode != 0:
        # A shallow clone (and any other git error) cannot produce a merge base. Fall
        # back to BASE_REF's own tip, but say so on stderr: the substitute comparand is
        # semantically different from the true merge base (BASE_REF may have advanced and
        # removed a key on the trunk after the fork point), so a green result reached this
        # way must carry that fact rather than launder a degraded comparand into a pass
        # ("unknown is not zero"). Still returns the substitute so the check runs.
        print(
            f"[retain] note: could not compute a merge base against {base_ref} "
            f"({result.stderr.strip() or 'git merge-base failed'}); comparing against "
            f"{base_ref}'s tip instead — a shallow clone or git error, so the base "
            "comparand is degraded",
            file=sys.stderr,
        )
        return base_ref, None
    base = result.stdout.strip()
    return (base or base_ref), None


def _read_config_base(repo_root: Path) -> str:
    """The `base_branch` config value (default 'main'), read via the shared resolver so a
    consumer's master/develop trunk is honored. Best-effort: any failure falls back to
    'main', which is the resolver's own default."""
    resolver = repo_root / "scripts" / "config-get.sh"
    try:
        result = subprocess.run(
            [str(resolver), ".base_branch", "main"],
            capture_output=True,
            text=True,
            check=False,
        )
    except (FileNotFoundError, OSError):
        return "main"
    value = result.stdout.strip()
    return value or "main"


def main(argv: "list[str]") -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repo_root", nargs="?", default=".", help="repository root (default: cwd)")
    parser.add_argument(
        "--base-ref",
        default=None,
        help="the base ref to compare against (default: origin/<base_branch>)",
    )
    args = parser.parse_args(argv[1:])
    repo_root = Path(args.repo_root).resolve()

    base_ref = args.base_ref
    if base_ref is None:
        base_ref = f"origin/{_read_config_base(repo_root)}"

    merge_base, mb_error = _merge_base(repo_root, base_ref)
    if merge_base is None:
        print(f"[retain] could not establish a merge base against {base_ref}: {mb_error}")
        return 1

    base_map, base_error = _git_show_json(repo_root, merge_base, MAP_REL)
    if base_error is not None:
        print(f"[retain] could not read the base {MAP_REL}: {base_error}")
        return 1
    # Make an empty base comparand visible: with no base keys the check inspects
    # nothing and passes, which is correct when the map genuinely did not exist at the
    # base but must not be silently laundered into a green result when it is the product
    # of a degraded merge-base fallback (see _merge_base) or an unexpectedly absent path.
    if isinstance(base_map, dict) and not base_map.get("files") and not base_map.get("run_sh_blocks"):
        print(
            f"[retain] note: the base {MAP_REL} at {merge_base} carried no files/run_sh_blocks "
            "keys, so there is nothing to retain against — verify this is a genuinely absent "
            "base map rather than a degraded comparand",
            file=sys.stderr,
        )

    head_path = repo_root / MAP_REL
    try:
        head_map = json.loads(head_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        print(f"[retain] could not read the head {MAP_REL} ({error})")
        return 1

    allow_path = repo_root / ALLOW_REL
    allow_value: object = None
    if allow_path.exists():
        try:
            allow_value = json.loads(allow_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            print(f"[retain] {ALLOW_REL} is unreadable ({error}); refusing to treat it as empty")
            return 1

    violations = detect_losses(base_map, head_map, allow_value)
    for line in violations:
        print(line)
    if violations:
        return 1
    print(f"[retain] no coverage-map key or content was dropped relative to {base_ref}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
