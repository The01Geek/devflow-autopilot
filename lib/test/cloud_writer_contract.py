#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Cloud-writer reachability contract (AC1) + runtime-manifest producer (AC18).

Why this exists (issue #543, deferred half of #533): bundled-helper skill call
sites are authored around the portable ``${CLAUDE_SKILL_DIR:-…}`` anchor while
the cloud permission matcher grants only repo-relative
``.devflow/vendor/devflow/`` leading tokens. There was no machine-auditable
source of truth for *which* skill/phase assets a cloud writer session reaches,
and no runtime manifest a workflow preflight could validate before the agent
boots. This module is that source of truth.

It declares, as checked-in data:

* ``ROOTS`` — the three cloud execution roots (the workflow that dispatches the
  first skill and the entry skill it dispatches).
* ``DISPATCH_EDGES`` — every classified transitive edge out of a root: direct
  dispatch, nested skill invocation, inline engine reuse, and documentation
  subagents.
* ``SKILL_ASSETS`` — for every skill in the closure, the repository-owned
  reachable assets a cloud writer session can read: the ``SKILL.md`` plus
  whichever asset family a skill actually uses — ``phases/*.md`` (implement,
  review), ``references/*.md`` (review-and-fix's fix-loop procedure), or
  top-level reviewer prose (``requesting-code-review/code-reviewer.md``).
* ``REQUIRED_HELPER_HEADS`` — per cloud profile, the exact vendored leading
  tokens the profile grants (the executable trust boundary).

``check_closure()`` is the AC1 guard: it fails when a root or a dispatch edge
names a skill that is not classified in ``SKILL_ASSETS``, when a dispatch edge
carries an unknown ``kind``, when a classified asset (or a required helper's
source file) does not exist on disk, when a reachable ``*.md`` asset exists on
disk under a classified skill but is not listed (the reverse-drift check, which
covers ``phases/``, ``references/``, and top-level reviewer prose alike), or
when ``REQUIRED_HELPER_HEADS`` and ``ROOTS`` name different profile sets.
``build_manifest()`` renders the AC18
``devflow-cloud-writer-contract-v1`` manifest from this same data, so the manifest
can never silently drift from the closure it claims to describe.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

# Repo root: this file is lib/test/cloud_writer_contract.py.
REPO_ROOT = Path(__file__).resolve().parents[2]

PROTOCOL = "devflow-cloud-writer-contract-v1"

# The immediately preceding supported workflow profile set (AC18
# `legacy_profile_baseline`). Consumers older than this refresh workflows and
# plugin content together before their next cloud-writer run (see docs/install.md).
LEGACY_PROFILE_BASELINE = "2.15.13"

# The one repo-relative prefix a cloud-reached bundled helper is granted under.
VENDOR_PREFIX = ".devflow/vendor/devflow/"

# --- AC1: cloud execution roots ------------------------------------------------
# Each root is a cloud writer entry surface: the workflow that dispatches the
# first skill, plus that entry skill. Keyed by the profile id the matcher grants
# under (implement / light-command / review).
ROOTS = {
    "implement": {
        "workflow": ".github/workflows/devflow-implement.yml",
        "entry_skill": "implement",
    },
    "light-command": {
        # devflow.yml is the light command-listener. It fires on a bare
        # /devflow:review, /devflow:review-and-fix, or /devflow:pr-description
        # comment and NEVER on /devflow:implement — every trigger negates it
        # (the partition invariant), and the heavy implement path lives in
        # devflow-implement.yml under the "implement" root. Its writer entry is
        # therefore review-and-fix (the command that pushes fixes); the other two
        # dispatched commands (review, pr-description) are covered by direct edges.
        "workflow": ".github/workflows/devflow.yml",
        "entry_skill": "review-and-fix",
    },
    "review": {
        "workflow": ".github/workflows/devflow-runner.yml",
        "entry_skill": "review",
    },
}

# --- AC1: classified transitive dispatch edges ---------------------------------
# Every edge OUT of a root's closure. `kind` classifies the reach:
#   direct   — a slash-command the light-command listener can dispatch
#   nested   — a Skill-tool invocation from within a skill
#   inline   — the shared review engine executed inline under the caller's profile
#   docs     — a documentation Agent-tool subagent
DISPATCH_KINDS = frozenset({"direct", "nested", "inline", "docs"})
DISPATCH_EDGES = [
    {"from": "implement", "to": "review", "kind": "inline"},
    {"from": "implement", "to": "review-and-fix", "kind": "nested"},
    {"from": "implement", "to": "pr-description", "kind": "nested"},
    {"from": "implement", "to": "docs", "kind": "docs"},
    # The docs Agent-tool subagent (implement Phase 4.1) invokes the docs skill,
    # which in turn invokes docs-sync-internal / docs-sync-external /
    # docs-release-notes via the Skill tool (skills/docs/SKILL.md). Those three
    # sub-skills carry the ${CLAUDE_SKILL_DIR:-…} anchors this manifest exists to
    # pin, so they are part of the reachable closure (they invoke no further
    # skills). Omitting them would leave the "every reached asset" contract false.
    {"from": "docs", "to": "docs-sync-internal", "kind": "nested"},
    {"from": "docs", "to": "docs-sync-external", "kind": "nested"},
    {"from": "docs", "to": "docs-release-notes", "kind": "nested"},
    {"from": "review", "to": "requesting-code-review", "kind": "nested"},
    {"from": "review-and-fix", "to": "review", "kind": "inline"},
    {"from": "review-and-fix", "to": "requesting-code-review", "kind": "nested"},
    {"from": "review-and-fix", "to": "receiving-code-review", "kind": "nested"},
    # The three writer commands the light-command listener (devflow.yml) dispatches.
    {"from": "light-command", "to": "review-and-fix", "kind": "direct"},
    {"from": "light-command", "to": "review", "kind": "direct"},
    {"from": "light-command", "to": "pr-description", "kind": "direct"},
]

# --- AC1: classified skill assets ----------------------------------------------
# Every skill the closure reaches, mapped to its repository-owned reachable
# assets (relative to REPO_ROOT). A root or edge naming a skill absent here is an
# AC1 violation (check_closure).
SKILL_ASSETS = {
    "implement": [
        "skills/implement/SKILL.md",
        "skills/implement/phases/phase-1-setup.md",
        "skills/implement/phases/phase-2-implement.md",
        "skills/implement/phases/phase-3-review.md",
        "skills/implement/phases/phase-4-documentation.md",
    ],
    "review": [
        "skills/review/SKILL.md",
        "skills/review/phases/phase-0-setup.md",
        "skills/review/phases/phase-0-3-6-blocker-recheck.md",
        "skills/review/phases/phase-0-6-stale-prose-lint.md",
        "skills/review/phases/phase-1-checklist.md",
        "skills/review/phases/phase-2-verification.md",
        "skills/review/phases/phase-3-agents.md",
        "skills/review/phases/phase-4-verdict.md",
        "skills/review/phases/phase-4-1-7-stale-adjudication.md",
        "skills/review/phases/phase-4-4-github-post.md",
    ],
    # review-and-fix has NO phases/ dir — its fix-loop procedure lives in
    # references/*.md that skills/review-and-fix/SKILL.md reads at runtime (and
    # several carry the ${CLAUDE_SKILL_DIR:-…} anchors this manifest exists to
    # pin), so they are reachable assets and must be classified/pinned.
    "review-and-fix": [
        "skills/review-and-fix/SKILL.md",
        "skills/review-and-fix/references/convergence.md",
        "skills/review-and-fix/references/error-handling.md",
        "skills/review-and-fix/references/fix-delta-gate.md",
        "skills/review-and-fix/references/fixing.md",
        "skills/review-and-fix/references/loop-control.md",
        "skills/review-and-fix/references/loop-exit.md",
        "skills/review-and-fix/references/pre-fix-gates.md",
        "skills/review-and-fix/references/shadow-review.md",
    ],
    # requesting-code-review's SKILL.md dispatches the reviewer persona prose in
    # code-reviewer.md — a reachable top-level (non-phases) asset.
    "requesting-code-review": [
        "skills/requesting-code-review/SKILL.md",
        "skills/requesting-code-review/code-reviewer.md",
    ],
    "receiving-code-review": ["skills/receiving-code-review/SKILL.md"],
    "docs": ["skills/docs/SKILL.md"],
    "docs-sync-internal": ["skills/docs-sync-internal/SKILL.md"],
    "docs-sync-external": ["skills/docs-sync-external/SKILL.md"],
    "docs-release-notes": ["skills/docs-release-notes/SKILL.md"],
    "pr-description": ["skills/pr-description/SKILL.md"],
}

# --- AC18: per-profile required helper heads -----------------------------------
# The vendored leading tokens each cloud profile must grant — a *required subset*
# of the workflow `--allowed-tools` / TOOLS grants (each profile grants a superset
# of infrastructure helpers too). Validator class 17 (HEAD_ABSENT) asserts each of
# these is actually granted. These are the executable trust boundary the runtime
# manifest pins.
REQUIRED_HELPER_HEADS = {
    "implement": [
        ".devflow/vendor/devflow/scripts/run-jq.sh",
        ".devflow/vendor/devflow/scripts/config-get.sh",
        ".devflow/vendor/devflow/scripts/workpad.py",
        ".devflow/vendor/devflow/scripts/parse-acs.py",
        ".devflow/vendor/devflow/scripts/branch-for-issue.py",
        ".devflow/vendor/devflow/scripts/update-branch-checkpoint.sh",
        ".devflow/vendor/devflow/scripts/file-deferrals.py",
        ".devflow/vendor/devflow/scripts/match-deferrals.py",
        ".devflow/vendor/devflow/scripts/resolve-review-overrides.py",
        ".devflow/vendor/devflow/scripts/apply-labels.sh",
        ".devflow/vendor/devflow/scripts/ensure-label.sh",
        ".devflow/vendor/devflow/scripts/stale-prose-lint.py",
        ".devflow/vendor/devflow/scripts/dismiss-stale-rejections.sh",
        ".devflow/vendor/devflow/scripts/match-lint-adjudications.py",
        ".devflow/vendor/devflow/scripts/load-prompt-extension.sh",
        ".devflow/vendor/devflow/scripts/react-to-trigger.sh",
        ".devflow/vendor/devflow/scripts/extract-doc-needed-paths.sh",
        ".devflow/vendor/devflow/lib/efficiency-trace.sh",
    ],
    # Note the absent apply-labels.sh / ensure-label.sh: those are implement-only
    # (Phases 3.1/4.0/4.1). devflow.yml dispatches only review-and-fix /
    # review / pr-description — none applies labels — and grants no label helper,
    # so requiring one here would fail class 17 (HEAD_ABSENT) against a grant the
    # profile correctly does not carry. (Completeness of this per-profile list vs.
    # what the reached skills actually invoke is the deferred grant-sync work, AC9.)
    "light-command": [
        ".devflow/vendor/devflow/scripts/run-jq.sh",
        ".devflow/vendor/devflow/scripts/config-get.sh",
        ".devflow/vendor/devflow/scripts/workpad.py",
        ".devflow/vendor/devflow/scripts/parse-acs.py",
        ".devflow/vendor/devflow/scripts/branch-for-issue.py",
        ".devflow/vendor/devflow/scripts/update-branch-checkpoint.sh",
        ".devflow/vendor/devflow/scripts/file-deferrals.py",
        ".devflow/vendor/devflow/scripts/match-deferrals.py",
        ".devflow/vendor/devflow/scripts/match-lint-adjudications.py",
        ".devflow/vendor/devflow/scripts/resolve-review-overrides.py",
        ".devflow/vendor/devflow/scripts/stale-prose-lint.py",
        ".devflow/vendor/devflow/scripts/dismiss-stale-rejections.sh",
        ".devflow/vendor/devflow/scripts/load-prompt-extension.sh",
        ".devflow/vendor/devflow/lib/efficiency-trace.sh",
    ],
    "review": [
        ".devflow/vendor/devflow/scripts/run-jq.sh",
        ".devflow/vendor/devflow/scripts/match-deferrals.py",
        ".devflow/vendor/devflow/scripts/match-lint-adjudications.py",
        ".devflow/vendor/devflow/scripts/dismiss-stale-rejections.sh",
        ".devflow/vendor/devflow/scripts/workpad.py",
        ".devflow/vendor/devflow/scripts/config-get.sh",
        ".devflow/vendor/devflow/scripts/load-prompt-extension.sh",
        ".devflow/vendor/devflow/scripts/resolve-review-overrides.py",
        ".devflow/vendor/devflow/scripts/stale-prose-lint.py",
        ".devflow/vendor/devflow/lib/efficiency-trace.sh",
    ],
}


def reachable_skills():
    """Transitive closure of skills reachable from the roots via DISPATCH_EDGES.

    An edge's ``from`` is either a root id (a direct dispatch out of a workflow
    root, e.g. the light-command listener) or an already-reached skill.
    """
    reached = {root["entry_skill"] for root in ROOTS.values()}
    # Seed edges whose source is a root id (roots are not skills). Use .get() so a
    # malformed edge missing `from`/`to` never crashes here — check_closure()
    # reports it as a violation instead (a well-formed edge always has both).
    for edge in DISPATCH_EDGES:
        if edge.get("from") in ROOTS and edge.get("to") is not None:
            reached.add(edge["to"])
    # Fixpoint over skill->skill edges (edges are few; iterate to convergence).
    changed = True
    while changed:
        changed = False
        for edge in DISPATCH_EDGES:
            if edge.get("from") in reached and edge.get("to") not in reached and edge.get("to") is not None:
                reached.add(edge["to"])
                changed = True
    return reached


def check_closure():
    """AC1 guard. Return a list of human-readable violations (empty == OK).

    Fails when a reached skill is unclassified, when an edge/root names an
    unknown skill, when an edge carries an unknown ``kind``, when a classified
    asset or a required helper's source file does not exist on disk, when a
    ``phases/*.md`` file on disk under a classified skill is not listed (the
    reverse-drift check), or when ``REQUIRED_HELPER_HEADS`` and ``ROOTS`` name
    different profile sets.
    """
    errors = []
    classified = set(SKILL_ASSETS)

    # Every dispatch edge must carry from/to/kind, and kind must be a classified
    # reach kind. Missing from/to is reported here (fail-soft) rather than crashing
    # the guard with a KeyError in the subscript loops below.
    for edge in DISPATCH_EDGES:
        for field in ("from", "to"):
            if not edge.get(field):
                errors.append(f"dispatch edge {edge!r} is missing required field '{field}'")
        if edge.get("kind") not in DISPATCH_KINDS:
            errors.append(
                f"dispatch edge {edge.get('from')}->{edge.get('to')} has unknown "
                f"kind {edge.get('kind')!r} (not one of {sorted(DISPATCH_KINDS)})"
            )

    # REQUIRED_HELPER_HEADS must name exactly the ROOTS profile set.
    if set(REQUIRED_HELPER_HEADS) != set(ROOTS):
        errors.append(
            "REQUIRED_HELPER_HEADS profiles "
            f"{sorted(REQUIRED_HELPER_HEADS)} != ROOTS profiles {sorted(ROOTS)}"
        )

    # Every root's entry skill must be classified.
    for rid, root in ROOTS.items():
        if root["entry_skill"] not in classified:
            errors.append(
                f"root '{rid}' entry_skill '{root['entry_skill']}' is not "
                f"classified in SKILL_ASSETS"
            )

    # Every edge's `to` must be a classified skill; its `from` must be a
    # classified skill or a known root id. (A from/to-less edge was already
    # reported above; skip it here so this loop never subscripts a missing key.)
    for edge in DISPATCH_EDGES:
        src, dst = edge.get("from"), edge.get("to")
        if not src or not dst:
            continue
        if src not in classified and src not in ROOTS:
            errors.append(
                f"dispatch edge {src}->{dst} has unknown "
                f"source '{src}' (not a classified skill or root id)"
            )
        if dst not in classified:
            errors.append(
                f"dispatch edge {src}->{dst} names unclassified target skill '{dst}'"
            )

    # Every reached skill must be classified (a root/edge added without
    # classifying the reached asset is the AC1 failure).
    for skill in sorted(reachable_skills()):
        if skill not in classified:
            errors.append(f"reached skill '{skill}' is not classified in SKILL_ASSETS")

    # Every classified asset must exist on disk.
    for skill, assets in SKILL_ASSETS.items():
        for rel in assets:
            if not (REPO_ROOT / rel).is_file():
                errors.append(f"classified asset for '{skill}' missing on disk: {rel}")

    # Every required helper's source file must exist on disk, so `check` reports
    # a rename/removal cleanly instead of `generate`/`verify` crashing with an
    # uncaught FileNotFoundError from sha256_of().
    for profile, heads in REQUIRED_HELPER_HEADS.items():
        for token in heads:
            try:
                rel = _helper_source_path(token)
            except ValueError as exc:
                errors.append(f"profile '{profile}' helper token invalid: {exc}")
                continue
            if not (REPO_ROOT / rel).is_file():
                errors.append(
                    f"profile '{profile}' required helper missing on disk: {rel}"
                )

    # Every reachable .md asset on disk under a classified skill must be listed.
    # The listed-assets-exist check above is one-directional (it never notices a
    # NEW on-disk asset), so a reachable asset added without classifying would
    # otherwise leave the closure green — exactly the AC1 drift this guard exists
    # to catch.
    errors.extend(unlisted_skill_assets())

    return errors


def unlisted_skill_assets():
    """Reachable ``*.md`` assets on disk under a classified skill that are not listed.

    Globs every ``*.md`` under ``skills/<skill>/`` (recursively) other than the
    skill's own ``SKILL.md`` — so ``phases/*.md`` (implement, review),
    ``references/*.md`` (review-and-fix), and top-level reviewer prose
    (``requesting-code-review/code-reviewer.md``) are all covered. Globbing a
    single asset family (the old phases-only check) left every other reachable
    family structurally invisible to the reverse-drift guard.
    """
    missing = []
    for skill, assets in SKILL_ASSETS.items():
        skill_dir = REPO_ROOT / "skills" / skill
        if not skill_dir.is_dir():
            continue
        skill_md = f"skills/{skill}/SKILL.md"
        listed = set(assets)
        for md_file in sorted(skill_dir.rglob("*.md")):
            rel = md_file.relative_to(REPO_ROOT).as_posix()
            if rel == skill_md:
                continue
            if rel not in listed:
                missing.append(f"skill '{skill}' has an unclassified reachable asset on disk: {rel}")
    return missing


def _helper_source_path(vendored_token):
    """Map a vendored leading token to its repository-owned source path.

    `.devflow/vendor/devflow/scripts/workpad.py` -> `scripts/workpad.py`.
    """
    if not vendored_token.startswith(VENDOR_PREFIX):
        raise ValueError(f"helper token not under vendor prefix: {vendored_token}")
    return vendored_token[len(VENDOR_PREFIX):]


def manifest_file_paths():
    """Sorted, de-duplicated repo-relative paths the manifest pins.

    Every AC1-reached skill asset plus every required helper's source file.
    """
    paths = set()
    for assets in SKILL_ASSETS.values():
        paths.update(assets)
    for heads in REQUIRED_HELPER_HEADS.values():
        for token in heads:
            paths.add(_helper_source_path(token))
    return sorted(paths)


def sha256_of(rel_path):
    """Lowercase hex SHA-256 of a repo-relative file."""
    h = hashlib.sha256()
    with open(REPO_ROOT / rel_path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def build_manifest():
    """Render the AC18 devflow-cloud-writer-contract-v1 manifest dict."""
    return {
        "protocol": PROTOCOL,
        "legacy_profile_baseline": LEGACY_PROFILE_BASELINE,
        "files": {rel: sha256_of(rel) for rel in manifest_file_paths()},
        "required_helper_heads": {
            profile: list(heads) for profile, heads in REQUIRED_HELPER_HEADS.items()
        },
    }


def canonical_json(obj):
    """Canonical JSON: sorted keys, 2-space indent, UTF-8, one trailing newline."""
    return json.dumps(obj, sort_keys=True, indent=2, ensure_ascii=False) + "\n"


MANIFEST_PATH = "scripts/devflow-cloud-writer-contract.json"


def main(argv=None):
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=("check", "generate", "verify"),
        help="check: AC1 closure guard; generate: write the manifest; "
        "verify: assert the checked-in manifest matches the closure",
    )
    args = parser.parse_args(argv)

    # generate and verify both render the manifest from the closure, so a closure
    # that `check` would reject (a helper token missing the vendor prefix, a
    # classified asset absent on disk) must fail here with the same clean report
    # rather than crashing later in manifest_file_paths()/sha256_of() with an
    # uncaught ValueError/FileNotFoundError.
    errors = check_closure()
    if errors:
        for e in errors:
            print(f"cloud-writer-contract: {e}")
        return 1

    if args.command == "check":
        print("cloud-writer-contract: closure OK")
        return 0

    manifest = build_manifest()
    rendered = canonical_json(manifest)
    target = REPO_ROOT / MANIFEST_PATH

    if args.command == "generate":
        target.write_text(rendered, encoding="utf-8")
        print(f"cloud-writer-contract: wrote {MANIFEST_PATH}")
        return 0

    # verify
    if not target.is_file():
        print(f"cloud-writer-contract: manifest missing at {MANIFEST_PATH}")
        return 1
    current = target.read_text(encoding="utf-8")
    if current != rendered:
        print(
            "cloud-writer-contract: checked-in manifest is stale — "
            f"regenerate with `python3 {Path(__file__).name} generate`"
        )
        return 1
    print("cloud-writer-contract: manifest matches closure")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
