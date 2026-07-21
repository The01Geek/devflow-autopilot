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

import fnmatch
import hashlib
import json
import re
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
        "skills/review/phases/phase-4-1-8-prose-cutover.md",
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
        # Phase 4.0.5's discovery step, invoked in the SAME fence as
        # file-deferrals.py above (issue #555). Registered alongside it so the
        # deferrals pipeline's two helpers share one trust boundary: pinning the
        # filing half while leaving the discovery half out is the asymmetry a
        # reader would take for a deliberate exclusion rather than an omission.
        ".devflow/vendor/devflow/scripts/discover-deferral-manifests.py",
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


# --- AC9: grant synchronization ------------------------------------------------
# The AC1-closure per-profile reachable helper literals (REQUIRED_HELPER_HEADS)
# must each be granted in that profile's workflow as the exact vendored leading
# token, and no OTHER grant covering a reachable helper may WIDEN the executable
# trust boundary — by an absolute path, a repo-root path, a basename-wildcard, or
# a directory/blanket glob IN THE GRANT'S COMMAND-POSITION TOKEN.
# check_grant_sync() enforces both directions over the three cloud profiles keyed
# by ROOTS.
#
# KNOWN, DELIBERATE SCOPE LIMITS — three surfaces this guard does not measure.
# Each is disclosed because an undisclosed non-goal reads as a closed hole.
#
# (i) Interpreter and wrapper grants. _ANY_BASH_GRANT_RE reads only the grant's
# leading command-position token, so Bash(python3:*) yields 'python3', which
# neither glob-matches a vendored literal nor shares a reachable basename — yet
# it can execute every reachable helper (`python3 .devflow/vendor/devflow/
# scripts/workpad.py …`). The same blindness covers any wrapper head. This is
# not an oversight detection could simply close: every live profile grants at
# least one interpreter head — `env` in all three, `python3` in implement and
# light-command (the review profile deliberately grants NO python3 head; do not
# "restore" one) — so flagging that class would turn the guard RED on the healthy
# tree. AC9's stated scope is the path classes above; bounding the interpreter
# surface is a separate policy question, tracked in the #650 follow-up. The same
# leading-token truncation also hides a widened path in WRAPPER ARGUMENT
# position: `Bash(python3 /home/x/workpad.py:*)` enumerates as `python3`, so the
# absolute path beside it is never classified.
#
# (ii) Whole-file grant pooling. _grant_source_text returns the ENTIRE workflow
# text, so every surviving `Bash(...)` in the file is pooled as that profile's
# grants — there is no scoping to the profile's own TOOLS='…' / --allowed-tools
# region. This is behavioural parity with the runtime validator's
# extract_profile_grants, which reads whole-file the same way, but it is a
# fail-open direction on arm (1) and is stated here rather than left implicit.
# Measured on the review profile today: exactly two pooled tokens — `cargo` and
# `go` — come from outside any grant-bearing line, both from a `run:` echo in
# devflow-runner.yml naming them inside a user-facing warning string. (That pair
# is the measurement, not an exhaustive class: re-derive it rather than trusting
# this figure.) It is currently harmless — neither is a reachable
# helper, so arm (1) ignores them and arm (2)'s coverage test rejects them — but
# a `run:` line or doc string that mentions a VENDORED LITERAL (e.g. an echo
# reading "grant it with Bash(.devflow/vendor/devflow/scripts/workpad.py:*)")
# would satisfy arm (1) for a helper the profile does not actually grant. Region
# scoping — anchored on the generated capability-manifest banner, failing closed
# via the existing "grant source unavailable" violation when the region cannot be
# located — is tracked in the #650 follow-up alongside the AC3 re-home, because
# it belongs with extract-command-heads.py's authoritative scoper rather than as
# a second hand-rolled parser here.
#
# (iii) Consumer-spliced grants. devflow-implement.yml's --allowed-tools baseline
# is followed by a `${{ needs.config.outputs.allowed_tools_extra }}` splice, so a
# consumer's devflow_implement.allowed_tools entries never appear in the file
# this guard reads. A widened grant added there is outside the measured surface.
#
# Do not read arm (2) as "no grant can reach a helper" — it is "no PATH-SHAPED
# grant IN THE COMMITTED WORKFLOW is broader than the vendored literal".
#
# Why the generated workflow and not lib/capability-profiles.json (the manifest
# those literals are generated FROM): the rendered literal is what the cloud
# runner's matcher actually reads, so it is the surface a widening would have to
# reach to matter. Manifest-vs-literal parity is separately enforced in this same
# suite by `python3 lib/generate-capability-profiles.py --check` (#561), so
# reading the rendered side loses nothing and measures the real boundary. Do not
# "fix" this into a manifest read.
#
# Scoped-home note (deviates from issue #650's AC9 wording "the command-head
# test", which names lib/test/extract-command-heads.py's comment-aware scoper as
# the eventual home; see the workpad AC-rewrite/deviation note). This slice ships
# AC9 alone: it lives here, on the AC1-closure module that OWNS REQUIRED_HELPER_HEADS
# and ROOTS. Re-homing onto extract-command-heads.py's authoritative
# comment-aware parser is coupled with the deferred AC3 leading-token guard
# (which uses that parser) and is tracked in the #650 follow-up, not built
# half-way here.
#
# Arm (1) below (a reachable literal with no explicit vendored grant) is the
# same defect class the runtime validator reports as class 17 (HEAD_ABSENT) in
# scripts/validate-cloud-writer-contract.py. Neither is redundant: the validator
# grades the checked-in manifest at runtime, this guard grades the AC1 closure
# against the live workflows at desk/CI time and additionally owns arm (2)
# (widening), which the validator has no equivalent of. Retire neither believing
# the other is the sole owner.
#
# Grant-shape regexes, mirroring validate-cloud-writer-contract.py's _GRANT_RE for
# the vendored form. Both anchor on `Bash(` so a vendored path that appears only in
# a comment or a shell assignment is never counted as a grant (the same fail-open
# guard the validator's _GRANT_RE documents).
# A properly-scoped vendored grant: the exact tight trust boundary. Its
# `(?:scripts|lib)` alternation is COUPLED to REQUIRED_HELPER_HEADS: a head added
# under any other vendored subdirectory would match neither this regex (so arm (1)
# would fire on a helper that IS correctly granted) nor the vendored-grant skip in
# arm (2) (so the real grant would also be flagged as a widening) — one omission,
# two false positives. The coupling is asserted in lib/test/test_python_scripts.py
# rather than left to a reader, so widening the alternation is forced in lockstep.
_VENDORED_GRANT_RE = re.compile(
    r"Bash\(\s*(\.devflow/vendor/devflow/(?:scripts|lib)/[A-Za-z0-9._-]+)"
)
# Any `Bash(<spec>)` grant's command-position path token (up to the first `:` /
# `)` / whitespace). Used to enumerate every grant so a widened one covering a
# reachable helper can be detected — a vendored-only regex is blind to exactly
# the widened classes AC9 must reject.
_ANY_BASH_GRANT_RE = re.compile(r"Bash\(\s*([^\s:)]+)")

# Deliberately-sanctioned basename-wildcard grants (NOT widening defects),
# **keyed per profile**. The light-command and review profiles grant
# Bash(*/load-prompt-extension.sh:*) ALONGSIDE the explicit vendored literal
# (lib/capability-profiles.json): the prompt-extension loader is reached through
# the portable ${CLAUDE_SKILL_DIR:-…} anchor, which can resolve to a non-vendored
# absolute path on some runners, so the wildcard is an intentional companion to
# the tight grant, not a replacement of it.
#
# The per-profile keying is load-bearing, not tidiness. The implement profile
# does NOT carry that wildcard, so a global exemption set would wave it through
# there too — re-opening, for the read-write profile, exactly the basename-
# wildcard widening arm (2) exists to reject. An unknown profile gets an EMPTY
# exemption set (see the `.get(profile, frozenset())` read), so the failure
# direction of a future profile addition is fail-closed.
SANCTIONED_WILDCARD_GRANTS = {
    "implement": frozenset(),
    "light-command": frozenset({"*/load-prompt-extension.sh"}),
    "review": frozenset({"*/load-prompt-extension.sh"}),
}


def _grant_source_text(profile, profile_grants):
    """Return the raw grant-source text for one profile.

    When ``profile_grants`` is provided it is a ``{profile: text}`` mapping
    (the injection point unit tests use to drive synthetic grants); otherwise
    the profile's ROOTS workflow file is read from disk. A missing injected
    profile or an unreadable workflow yields ``None`` so the caller can report a
    targeted violation rather than silently treating the grant set as empty
    (unknown is not zero).
    """
    if profile_grants is not None:
        return profile_grants.get(profile)
    workflow = ROOTS[profile]["workflow"]
    try:
        return (REPO_ROOT / workflow).read_text(encoding="utf-8")
    # UnicodeDecodeError is a ValueError, NOT an OSError: a workflow carrying a
    # non-UTF-8 byte would otherwise escape this handler as a raw traceback and
    # abort the whole guard, defeating the very unknown-is-not-zero contract this
    # function documents. Catch both so an undecodable source is reported as
    # unavailable exactly like an unreadable one.
    except (OSError, ValueError):
        return None


def _strip_yaml_comment(line):
    """Return ``line`` with any YAML comment removed, quote-aware.

    A `#` starts a YAML comment only at the start of the line or after
    whitespace, and only outside a quoted scalar — so `Bash(x:*)'  # note` is
    stripped while a `#` inside `'...'` (or in a path) is preserved.

    **Deliberately stricter than the runtime validator's extract_profile_grants**
    (which drops full-line comments only, and documents that residual fail-open).
    An inline `# was Bash(.../workpad.py:*)` would otherwise be counted as a live
    grant, letting arm (1) pass for a helper the profile does not actually grant
    — the silent-matcher-denial class (#363/#401).

    **Unbalanced-quote fail-closed arm.** Quote state is per-line, so a line
    carrying an unpaired `'` or `"` before the `#` (an apostrophe in an unquoted
    YAML scalar — `run: echo don't  # Bash(scripts/x.sh:*)`) would leave the
    scanner "inside" a string for the rest of the line and strip nothing. That
    direction counts MORE than the validator, not fewer: the commented text is
    scanned as live, manufacturing a phantom grant (or a phantom widening). So a
    line whose quote is still open at end-of-line is re-scanned quote-blind,
    stripping at the first whitespace-preceded `#`. With that arm in place the
    divergence from the validator is one-way — this function only ever counts
    FEWER things as grants — because every line the validator drops whole is
    also reduced to a grant-free prefix here.
    """
    def _scan(text, quote_aware):
        quote = None
        for i, ch in enumerate(text):
            if quote_aware and quote is not None:
                if ch == quote:
                    quote = None
            elif quote_aware and ch in ("'", '"'):
                quote = ch
            elif ch == "#" and (i == 0 or text[i - 1].isspace()):
                return text[:i], quote
        return text, quote

    stripped, open_quote = _scan(line, quote_aware=True)
    if open_quote is not None:
        # Unterminated quote: the quote state is not trustworthy, so do not let it
        # protect a `#`. Re-scan treating quotes as ordinary characters.
        stripped, _ = _scan(line, quote_aware=False)
    return stripped


def _scan_grants(text):
    """Return ``(vendored_grants, any_grants)`` for a grant-source text.

    YAML comments — full-line *and* inline — are stripped first (see
    ``_strip_yaml_comment``) so a commented-out grant is counted neither as a
    grant nor as a widening. ``vendored_grants`` is the set of properly-scoped
    vendored leading tokens; ``any_grants`` is the set of every ``Bash(...)``
    command-position path token (used for widening detection).
    """
    scanned = "\n".join(_strip_yaml_comment(line) for line in text.splitlines())
    return set(_VENDORED_GRANT_RE.findall(scanned)), set(_ANY_BASH_GRANT_RE.findall(scanned))


def _classify_widening(spec):
    """Label a grant ``spec`` that covers a reachable helper by its widened class.

    Returns ``absolute`` / ``basename-wildcard`` / ``repo-root`` / ``wildcard``
    / ``bare-name`` / ``unclassified``. It **never returns None**: labelling
    only, never the decision of whether a spec is a violation — that decision is
    ``_grant_covers``. An earlier shape returned ``None`` for any spec outside
    three enumerated prefixes and the caller dropped the finding, so genuinely
    widening shapes (``./scripts/x``, ``../scripts/x``, ``~/scripts/x``,
    ``**/x``, ``*x``, a bare ``x``) were silently accepted — a guard that failed
    open exactly where it claimed to fail closed. An unrecognized shape is now
    reported as ``unclassified``, never waved through.
    """
    if spec.startswith("/"):
        return "absolute"
    if spec.startswith("*/"):
        return "basename-wildcard"
    if spec.startswith("scripts/") or spec.startswith("lib/"):
        return "repo-root"
    if "*" in spec or "?" in spec:
        return "wildcard"
    if "/" not in spec:
        # A bare name is resolved through PATH, so it is the BROADEST path-class
        # widening, not an unrecognized one — label it precisely rather than
        # letting the catch-all bucket describe the most dangerous shape.
        return "bare-name"
    return "unclassified"


def _grant_covers(spec, literals, basenames):
    """Return True when grant ``spec`` can execute a reachable helper.

    Two independent coverage tests, unioned, because either alone fails open:

    * **glob coverage** — ``spec`` read as a shell pattern matches a reachable
      vendored literal. This is what catches a *directory* or blanket wildcard
      (``.devflow/vendor/devflow/scripts/*``, ``*``, ``**/workpad.py``), whose
      basename is ``*`` and so never matches a reachable basename.
    * **basename coverage** — ``spec``'s final path segment names a reachable
      helper. This catches a widened *path* to the same helper
      (``scripts/workpad.py``, ``/home/x/workpad.py``, ``./scripts/workpad.py``,
      a bare ``workpad.py``), which does not glob-match the vendored literal.

    A bare granted command name that is not a reachable helper (``awk``, ``jq``,
    ``git`` — every non-vendored grant the live workflows actually carry) matches
    neither test, so the healthy tree stays clean.
    """
    if any(fnmatch.fnmatchcase(literal, spec) for literal in literals):
        return True
    return spec.rsplit("/", 1)[-1] in basenames


def check_grant_sync(profile_grants=None):
    """AC9 guard. Return a list of human-readable violations (empty == OK).

    For each of the three cloud profiles keyed by ROOTS (implement,
    light-command, review), maps every AC1-closure reachable helper literal in
    REQUIRED_HELPER_HEADS to that profile's workflow grants and fails when:

    * a reachable literal lacks an explicit vendored ``Bash(<literal>:*)`` grant, or
    * any other grant *covering* a reachable helper (see ``_grant_covers``)
      widens the executable trust boundary — an absolute-path, repo-root,
      basename-wildcard, directory/blanket glob, PATH-resolved bare name, or
      otherwise unclassified shape (excluding that profile's sanctioned
      wildcards in ``SANCTIONED_WILDCARD_GRANTS``).

    ``profile_grants`` (optional ``{profile: workflow-text}``) injects synthetic
    grant sources for unit tests; when omitted each profile's ROOTS workflow is
    read from disk.
    """
    errors = []

    # "exactly three current cloud profiles, complete by AC1's workflow roots":
    # REQUIRED_HELPER_HEADS must name precisely the ROOTS profile set. (A subset
    # or superset here is the drift this half of the guard exists to catch; the
    # profile parity in check_closure() covers the healthy tree, this restates it
    # so grant-sync is self-standing when driven in isolation.)
    if set(REQUIRED_HELPER_HEADS) != set(ROOTS):
        errors.append(
            "AC9 grant-sync: REQUIRED_HELPER_HEADS profiles "
            f"{sorted(REQUIRED_HELPER_HEADS)} != ROOTS profiles {sorted(ROOTS)}"
        )
        return errors

    for profile in sorted(ROOTS):
        heads = REQUIRED_HELPER_HEADS[profile]
        text = _grant_source_text(profile, profile_grants)
        if text is None:
            errors.append(
                f"AC9 grant-sync: profile '{profile}' grant source unavailable "
                f"({ROOTS[profile]['workflow']}); cannot confirm grants (unknown is not zero)"
            )
            continue
        vendored_grants, any_grants = _scan_grants(text)

        # (1) Every reachable literal must be explicitly granted, tight-scoped.
        reachable_basenames = set()
        for literal in heads:
            reachable_basenames.add(literal.rsplit("/", 1)[-1])
            if literal not in vendored_grants:
                errors.append(
                    f"AC9 grant-sync: profile '{profile}' reaches helper "
                    f"'{literal}' but grants no explicit Bash({literal}:*) — "
                    f"add the vendored-literal grant"
                )

        # (2) No grant COVERING a reachable helper may widen the boundary.
        # Fail-closed polarity: any non-vendored, non-sanctioned grant that can
        # execute a reachable helper is a violation, and _classify_widening only
        # LABELS it. Never drop a covering spec because its shape is unfamiliar.
        for spec in sorted(any_grants):
            if spec in vendored_grants:
                continue  # a proper vendored grant is never a widening
            if spec in SANCTIONED_WILDCARD_GRANTS.get(profile, frozenset()):
                continue  # deliberate companion wildcard for THIS profile (documented)
            if not _grant_covers(spec, heads, reachable_basenames):
                continue  # cannot execute any helper this profile reaches
            errors.append(
                f"AC9 grant-sync: profile '{profile}' grants '{spec}' covering "
                f"reachable helper(s) as a {_classify_widening(spec)} class — widens "
                f"the executable trust boundary; grant only the vendored literal"
            )

    return errors


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
        choices=("check", "generate", "verify", "grant-sync"),
        help="check: AC1 closure guard; generate: write the manifest; "
        "verify: assert the checked-in manifest matches the closure; "
        "grant-sync: AC9 guard — every reachable helper literal is granted "
        "tight-scoped in its profile and no grant widens the trust boundary",
    )
    args = parser.parse_args(argv)

    # grant-sync is a standalone guard over the workflow grants — it does not
    # render the manifest, so it runs before the check_closure()/build path below.
    #
    # This subcommand is an OPERATOR-FACING entry point, not the CI wiring: the
    # guard reaches the required `lib + python tests` job because
    # lib/test/test_python_scripts.py calls check_grant_sync() and
    # main(["grant-sync"]) directly. Do not read the absence of a run.sh
    # invocation as the guard being ungated, and do not add one believing it
    # closes a coverage hole — it would be duplicate coverage.
    if args.command == "grant-sync":
        gs_errors = check_grant_sync()
        if gs_errors:
            for e in gs_errors:
                print(f"cloud-writer-contract: {e}")
            return 1
        print("cloud-writer-contract: grant-sync OK")
        return 0

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
