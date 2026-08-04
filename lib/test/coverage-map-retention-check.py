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

THREE OUTCOMES, because "I could not establish whether a key was lost" is not "no key
was lost" (the repository's *unknown is not zero* rule):

  0  clean       — the base comparand WAS established and nothing was dropped.
  1  loss        — a key or its note/owner content was dropped RELATIVE TO A SOUND
                   comparand (or an input the check needs — the head map, the allow
                   file — could not be read).
  3  unestablished — the base comparand is degraded, so the comparison proves nothing.
                   This INCLUDES a difference detected against a SUBSTITUTED comparand:
                   see the substituted-comparand note below.

Exit 3 is deliberately distinct from BOTH 0 and 1 so no caller can read an unestablished
comparand as a clean result, and so a diagnosis never misattributes "the base is missing"
as "a key was dropped". A degraded base arises on a shallow or partial clone: `git
merge-base` can FAIL outright, or — worse, because it looks healthy — it can SUCCEED
against a truncated commit graph and hand back a shallow-boundary commit whose tree
predates the coverage map, leaving an empty base map and therefore nothing to compare.
Both shapes previously reported only on stderr and exited 0, laundering a real
merge-dropped key into a green pass on the desk-runnable path.

A shallow clone is a legitimate desk workflow, so the degraded case is not an
unconditional hard failure: `--allow-degraded-base` is an EXPLICIT, per-invocation
acknowledgement that downgrades exit 3 to exit 0. It is opt-in and it is never silent —
the acknowledged reasons are printed on stdout and the result is reported as an
acknowledged degraded run rather than as a clean retention pass. The default direction
is what matters: unacknowledged, the check fails closed.

SUBSTITUTED COMPARAND: when `git merge-base` cannot name a commit, `_merge_base` hands
back BASE_REF's own TIP as the comparand. A difference found against that tip is NOT an
established loss — BASE_REF may have added a key AFTER the fork point that the branch
legitimately never had, and reporting that as `a merge/resolution dropped it` is a
misattribution about a comparison the run never actually performed. So a violation
detected against a substituted comparand routes through the degraded arm: it is reported
with the substitution named, `--allow-degraded-base` CAN acknowledge it, and the exit is
3 (or an acknowledged 0), never 1. The invariant that matters is preserved in the other
direction — a loss found against a SOUND comparand keeps exit 1 and no flag can
acknowledge it away. Whichever arm fires, every degraded reason is printed: a developer
never reads `a merge/resolution dropped it` without also reading that the comparand was
a substitute tip.

CI keeps a real comparand by checking out full history (`fetch-depth: 0`). That coupling
now enforces ITSELF: strip `fetch-depth: 0` and this check exits 3 (no merge base /
empty base map) or 1 (`origin/<base>` unresolvable), so the workflow goes RED instead of
silently losing the protection.

Pure core (`detect_losses`, `classify_outcome`) so the focused test drives every arm —
including every branch and the arm ORDER of the outcome selection — from in-memory
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
# The three outcomes. `unknown is not zero`: an unestablished base comparand takes a
# status distinct from BOTH the clean pass and the loss, so no caller can collapse it
# onto either. Kept as named constants because the focused test asserts them by name.
EXIT_CLEAN = 0
EXIT_LOSS = 1
EXIT_UNESTABLISHED = 3
# The flag that turns exit 3 into an acknowledged exit 0. Named once so the help text,
# the remedy line and the test all quote the same literal.
ACK_FLAG = "--allow-degraded-base"
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


def classify_outcome(
    violations: "list[str]",
    unestablished: "list[str]",
    allow_degraded: bool,
    base_ref: str,
    comparand_substituted: bool,
) -> "tuple[int, list[str]]":
    """Select the outcome. Pure — the focused test drives every arm and the arm ORDER.

    COMPARAND_SUBSTITUTED says the comparison ran against BASE_REF's own tip rather than
    a computed merge base (see `_merge_base`). It is what separates arm 1 from arm 2:
    the same violation list is an established loss against a sound comparand and merely
    a difference against a substituted one.

    Returns (exit status, report lines). Arm order is load-bearing and is asserted:

      1. VIOLATIONS against a SOUND comparand first. The key really is absent from head
         relative to the true merge base, so the loss is an ESTABLISHED fact — it
         outranks any degradation that only widens what the comparison might have
         missed, exits 1, and NO flag can acknowledge it away. Any unestablished reasons
         are appended to the report all the same: a loss is never announced without the
         context the comparison ran under.
      2. Anything unestablished — INCLUDING violations found against a SUBSTITUTED
         comparand, which are differences rather than established losses (BASE_REF may
         have added a key after the fork point that this branch legitimately never had).
         Nothing here was proven, so: exit 3 unless explicitly acknowledged.
      3. Acknowledged degraded run: exit 0, but reported as acknowledged-degraded and
         never as a clean retention pass.
      4. Clean: the comparand was established and nothing was dropped.
    """
    if violations and not comparand_substituted:
        lines = list(violations)
        if unestablished:
            # The loss above stands on its own — it was measured against a real merge
            # base — but the run still could not establish everything, and hiding that
            # leaves the developer with no hint of the conditions it ran under.
            lines.append(
                "[retain] for context, this run ALSO could not establish the following "
                "(the loss above is measured against the real merge base and stands "
                "regardless):"
            )
            lines.extend(f"[retain]   - {reason}" for reason in unestablished)
        return EXIT_LOSS, lines
    if violations or unestablished:
        lines = [
            "[retain] the base comparand could not be established, so this run proves "
            "nothing about key retention — it is NOT a clean pass:"
        ]
        lines.extend(f"[retain]   - {reason}" for reason in unestablished)
        if violations:
            # Never print `a merge/resolution dropped it` without saying, right beside
            # it, what it was actually compared against.
            lines.append(
                f"[retain] the differences below were detected against a SUBSTITUTE "
                f"comparand — {base_ref}'s own tip, NOT a merge base — so they are NOT "
                f"established losses: {base_ref} may have added a key after this "
                "branch forked, which the branch legitimately never had. Treat each as "
                "unconfirmed until the real merge base resolves:"
            )
            lines.extend(violations)
        if not allow_degraded:
            lines.append(
                "[retain] refusing to report a green result from an unestablished "
                "comparand (unknown is not zero). Fetch full history (git fetch "
                f"--unshallow, or CI's fetch-depth: 0) so {base_ref} and the merge base "
                f"resolve, or re-run with {ACK_FLAG} to acknowledge the degraded "
                "comparand deliberately."
            )
            return EXIT_UNESTABLISHED, lines
        lines.append(
            f"[retain] {ACK_FLAG} was passed, so the degraded comparand is acknowledged "
            "and the exit status is 0 — this is an acknowledged degraded run, not a "
            "verified clean one."
        )
        return EXIT_CLEAN, lines
    return EXIT_CLEAN, [
        f"[retain] no coverage-map key or content was dropped relative to {base_ref}"
    ]


def _merge_base(repo_root: Path, base_ref: str) -> "tuple[str | None, str | None, str | None]":
    """The merge base of HEAD and BASE_REF as (base, error, degraded_reason).

    Falls back to BASE_REF's own tip when a merge base cannot be computed (a shallow
    clone or any other git error). The substitute is semantically different from the
    true merge base — BASE_REF may have advanced past the fork point, removing a key or
    ADDING one this branch legitimately never had — so the fallback is reported as a
    DEGRADED reason the caller must resolve, never as a silent substitution. Returning
    it anyway lets the comparison still run and surface differences worth looking at;
    because the comparand is a substitute, `classify_outcome` reports those as
    unconfirmed differences rather than as established losses (a non-None degraded
    reason here is exactly what sets its COMPARAND_SUBSTITUTED)."""
    try:
        result = subprocess.run(
            ["git", "-C", str(repo_root), "merge-base", "HEAD", base_ref],
            capture_output=True,
            text=True,
            check=False,
        )
    except (FileNotFoundError, OSError) as error:
        return None, f"git merge-base failed ({error})", None
    if result.returncode != 0:
        return base_ref, None, (
            f"could not compute a merge base against {base_ref} "
            f"({result.stderr.strip() or 'git merge-base failed'}); compared against "
            f"{base_ref}'s tip instead — a shallow clone or a git error"
        )
    base = result.stdout.strip()
    if not base:
        # rc 0 with no output is the same silent substitution as the rc!=0 arm: git
        # reported no merge base at all, so BASE_REF's tip stands in for one.
        return base_ref, None, (
            f"git merge-base against {base_ref} succeeded but named no commit; "
            f"compared against {base_ref}'s tip instead"
        )
    return base, None, None


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
    parser.add_argument(
        ACK_FLAG,
        dest="allow_degraded",
        action="store_true",
        help=(
            "acknowledge a degraded base comparand (a shallow or partial clone) and exit 0 "
            f"instead of {EXIT_UNESTABLISHED}. The reasons are still printed and the run is "
            "reported as acknowledged-degraded, never as a verified clean pass."
        ),
    )
    args = parser.parse_args(argv[1:])
    repo_root = Path(args.repo_root).resolve()

    base_ref = args.base_ref
    if base_ref is None:
        base_ref = f"origin/{_read_config_base(repo_root)}"

    # Every reason the base comparand cannot be trusted. Non-empty ⇒ a green result would
    # be a claim the run never established, so it routes to EXIT_UNESTABLISHED.
    unestablished: "list[str]" = []

    merge_base, mb_error, mb_degraded = _merge_base(repo_root, base_ref)
    if merge_base is None:
        print(f"[retain] could not establish a merge base against {base_ref}: {mb_error}")
        return EXIT_LOSS
    if mb_degraded is not None:
        unestablished.append(mb_degraded)

    base_map, base_error = _git_show_json(repo_root, merge_base, MAP_REL)
    if base_error is not None:
        print(f"[retain] could not read the base {MAP_REL}: {base_error}")
        return EXIT_LOSS
    # An empty base comparand inspects nothing and therefore proves nothing. That is the
    # SECOND fail-open shape and the one that looks healthiest: on a shallow clone `git
    # merge-base` can succeed against a truncated graph and name a boundary commit whose
    # tree predates the map, so the base map reads as {} and every key looks retained.
    # It is a degraded comparand, not a pass — even when the map genuinely did not exist
    # at the base, in which case the acknowledgement flag is the way to say so.
    if isinstance(base_map, dict) and not base_map.get("files") and not base_map.get("run_sh_blocks"):
        unestablished.append(
            f"the base {MAP_REL} at {merge_base} carried no files/run_sh_blocks keys, so "
            "there was nothing to compare against — a degraded comparand, or a base that "
            "genuinely predates the map"
        )

    head_path = repo_root / MAP_REL
    try:
        head_map = json.loads(head_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        print(f"[retain] could not read the head {MAP_REL} ({error})")
        return EXIT_LOSS

    allow_path = repo_root / ALLOW_REL
    allow_value: object = None
    if allow_path.exists():
        try:
            allow_value = json.loads(allow_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            print(f"[retain] {ALLOW_REL} is unreadable ({error}); refusing to treat it as empty")
            return EXIT_LOSS

    violations = detect_losses(base_map, head_map, allow_value)
    # `mb_degraded` is non-None on exactly the two `_merge_base` arms that hand back
    # BASE_REF's tip in place of a merge base (rc != 0, and rc 0 naming no commit); the
    # success arm returns None and the OSError arm returns before this line. So this is
    # a direct read of the producer, not an inference: it is true iff the comparison
    # below ran against a substitute.
    comparand_substituted = mb_degraded is not None
    status, lines = classify_outcome(
        violations, unestablished, args.allow_degraded, base_ref, comparand_substituted
    )
    for line in lines:
        print(line)
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv))
