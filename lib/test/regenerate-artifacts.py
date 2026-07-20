#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""One batched pass over the suite-owned generated artifacts (issue #619).

A fix or implement loop that edits prompt surfaces, engine files, the capability
manifest, or review-bundle prose induces drift in checked-in generated records.
Discovering that drift one full-suite run at a time is the dominant cost of a loop
iteration, because the full suite is the slowest verification step in the repo. Run
this helper once after applying edits and before each full-suite re-verify run: it
regenerates the mechanically-safe artifact, runs each judgment-gated artifact's
non-writing check, and reports every resulting judgment item together, so the next
suite run verifies a tree whose generated artifacts are already reconciled.

REGISTRATION RULE (shipped as artifact content, not merely convention). Kept on ONE
line deliberately: a sentence wrapped across a line break lives on no single line, so
the suite's line-based pin on it would silently find nothing (the issue-375
wrapped-literal hazard).
A PR that adds a checked-in generated artifact gated by the suite adds a row to this registry in the same PR.

Machine-enforcing that rule for future generators is a disclosed NON-GOAL — it is a
review convention of the same class as the capability manifest's `manifest_version`
bump rule. The suite pins the current rows through `--list`.

INCLUSION CRITERION for a row: a checked-in record whose suite gate goes RED on
loop-induced edits AND whose state this helper can establish without writing it — either
a standalone non-writing check command (a regeneration command, for a mechanical row) or
an in-helper git-derived staleness check (a budget row, which launches no command).

DELIBERATELY EXCLUDED as artifact rows, because they are REDUNDANT — not because they
are uncovered: `scripts/workflow-flight-recorder-registry.json` and
`lib/test/prompt-mass-manifest.json` are hand-maintained inventories with no
*regeneration* command (nothing can rewrite them from the tree), and each is already
checked by a command a row here runs — the census's `manifest completeness failure`
arm covers the prompt-mass manifest, and the coverage guard's `[arm8]` arm covers the
flight-recorder registry. A row of their own could only re-report what
`prompt-mass-baseline` and `coverage-map-ratchet` already report.

WRITE SCOPE: the only file under the target root this helper writes is
`scripts/devflow-cloud-writer-contract.json` (the mechanical row's output). Every
judgment row runs a non-writing check and never writes its artifact.

EXIT CONTRACT (exactly three states):
  0 — every row resolved in its declared clean state (for a command-backed row, its
      command exited in that state; a command-less budget row has no command and
      resolves clean, informational, or judgment on its own git-derived arms), the
      mechanical regeneration changed nothing, and no exit-1-forcing judgment item
      was printed.
  1 — at least one of {the manifest bytes changed, an exit-1-forcing judgment item
      was printed} holds, and no row hit the infrastructure state.
  2 — infrastructure failure. Exit 2 takes precedence over exit 1. It is reached from
      an exit code OUTSIDE a row's declared set, from paths that occur despite an
      IN-set exit, and from paths where no row exit code was ever established — the
      declared set bounds what the row's generator is expected to return, not what
      counts as an established check:
        * a row's command failed to launch (absent file, interpreter launch failure);
        * a launched command exited outside its row's declared exit set;
        * a judgment row exited inside its declared set but its output matched one of
          the row's `infra_markers` (an input failure reported as an exit code that
          otherwise means drift);
        * the mechanical row exited in its clean state but produced no artifact;
        * the mechanical row exited 1 with no `cloud-writer-contract:` marker (an
          interpreter traceback rather than a reconcilable closure error);
        * an artifact snapshot could not be read;
        * the helper itself raised an unhandled exception (the top-level net at the
          bottom of this file — without it CPython would exit 1, aliasing an unchecked
          run onto the resolvable "action required" state).
Informational lines (the budget row's resolved and `unestablished` arms) select no
state by themselves.

These three are the states main() itself selects. argparse also exits 2 on a usage
error (an unknown flag) before any row runs — the same code as the infrastructure
state, and consistent with it (nothing was checked), but it is not one of the three
states above and no row report accompanies it.
"""

import argparse
import subprocess
import sys
import traceback
from pathlib import Path, PurePosixPath

MECHANICAL_ARTIFACT = "scripts/devflow-cloud-writer-contract.json"

# A budget row's watch list is carried by the ROW (`record` / `watch_literals` /
# `watch_globs`), not by module-level constants: with more than one such row the registry
# stays the single enumeration point, which is the property issue #619 established and
# issue #624 preserved when the second row landed. Each row's glob member joins its watch
# list the moment the file lands on disk. `is_budget_row` keys on `watch_literals` as the
# single spelling of that membership test — see its docstring for why the "has no argv"
# proxy is not used.

# Ordered registry. `argv` is resolved under the target root and run with that root as
# the working directory, so a fixture root exercises the fixture's own generators.
# `exits` is the row's declared exit-code set and `clean` its positive arm; an exit
# outside `exits` is the infrastructure state, never a clean pass.
# `check` is the row's own strategy callable: main() dispatches through it uniformly
# rather than re-deciding per row. The binding lives in exactly one place (the loop
# below the function definitions) and is keyed on whether the row declares an `argv`,
# NOT on `kind` — `kind` is "judgment" for both callables, so a kind->callable mapping
# does not exist. It is not branch-free: run_row still special-cases the mechanical kind.
ROWS = (
    {
        "name": "cloud-writer-manifest",
        "kind": "mechanical",
        "argv": ("python3", "lib/test/cloud_writer_contract.py", "generate"),
        "check": None,  # bound to run_row below.
        "clean": (0,),
        "exits": (0, 1),
        "writes": MECHANICAL_ARTIFACT,
        "policy": (
            "the closure data in lib/test/cloud_writer_contract.py "
            "(ROOTS / DISPATCH_EDGES / SKILL_ASSETS / required helper heads)"
        ),
    },
    {
        "name": "capability-profile-literals",
        "kind": "judgment",
        "argv": ("python3", "lib/generate-capability-profiles.py", "--check"),
        "check": None,  # bound to run_row below.
        "clean": (0,),
        "exits": (0, 1),
        "policy": (
            "edit lib/capability-profiles.json, regenerate with "
            "`python3 lib/generate-capability-profiles.py`, and update "
            "lib/review-profile.tokens when the resolved review list widens"
        ),
        # Same discriminator the other marker-bearing judgment rows carry: the generator raises
        # GenError for an INPUT failure (an absent/unreadable/malformed manifest, an
        # unreadable target workflow, an unreadable reviewer lock) and exits 1 —
        # byte-identically to a real token drift. Without these markers a malformed
        # lib/capability-profiles.json would be reported as a judgment item telling the
        # agent to regenerate from the very file the generator could not read, and the
        # pass would record `run` for a row that was never checked.
        # Deliberately EXCLUDED: the `manifest: …` schema errors, the `region …` anchor
        # errors, and the review-boundary/token-drift outputs — those ARE genuine
        # findings, and matching them would hide a real one (the worse error).
        "infra_markers": (
            "manifest absent:",
            "manifest unreadable:",
            "manifest malformed JSON:",
            "target workflow unreadable:",
            "target workflow file absent:",
            "reviewer security boundary lock unreadable:",
        ),
    },
    {
        "name": "prompt-mass-baseline",
        "kind": "judgment",
        "argv": ("python3", "lib/test/prompt-mass-census.py"),
        "check": None,  # bound to run_row below.
        "clean": (0,),
        "exits": (0, 1),
        "policy": "the mandatory-byte census section of .devflow/prompt-extensions/implement.md",
        # The census returns 1 for an unusable ROOT as well as for real drift. Without
        # this discriminator an unmeasurable tree would be reported as a judgment item
        # telling the agent to edit a baseline whose measurement never happened —
        # unknown collapsed onto a real value, the very class this helper exists to
        # avoid. The mechanical row got this reasoning first; it applies here too.
        # The unambiguous input-failure shapes only. `CensusError` is documented as
        # "an attributable, fail-closed input error" and `main` renders it as
        # `prompt-mass census: {exc}` — the SAME prefix a real drift report carries, so
        # the prefix cannot discriminate. These three sub-shapes can: a drift report
        # states paths and byte counts and never says a file was unreadable, malformed,
        # or absent. A completeness failure ("manifest completeness failure: …") is
        # genuine drift and deliberately does NOT match — matching it would hide a real
        # finding, the opposite and worse error.
        # `manifest-listed file is unreadable:` is listed separately from `: unreadable:`
        # and is NOT redundant with it: the census spells that arm
        # "manifest-listed file is unreadable: <path>: <exc>" — "is unreadable:", with no
        # colon before the word — so the `: unreadable:` literal (which matches the
        # manifest/baseline JSON read arm) does not cover it. An unreadable CLAUDE.md or
        # skill asset is the likeliest input failure of all, and without this row it was
        # reported as baseline drift.
        "infra_markers": (
            "not found or not a directory",
            ": malformed JSON:",
            ": unreadable:",
            "manifest-listed file is unreadable:",
        ),
    },
    {
        "name": "review-bundle-budget",
        "kind": "judgment",
        "check": None,  # bound to budget_row below (defined after this table).
        "argv": None,  # git-derived staleness detection, not a launched command.
        "policy": (
            "docs/review-bundle-budget.md — re-measure with lib/test/run.sh's _rb_words "
            "(python3, never wc -w) and update the record"
        ),
        "record": "docs/review-bundle-budget.md",
        "watch_literals": ("skills/review/SKILL.md", ".devflow/prompt-extensions/review.md"),
        "watch_globs": ("skills/review/phases/*.md",),
    },
    {
        "name": "review-and-fix-budget",
        "kind": "judgment",
        "check": None,  # bound to budget_row below (defined after this table).
        "argv": None,  # git-derived staleness detection, not a launched command.
        "policy": (
            "docs/review-and-fix-budget.md — re-measure with lib/test/run.sh's _raf_words "
            "(python3 bytes.split(), never wc -w) and update the record"
        ),
        # The sibling git-staleness row (issue #624). It meets the same inclusion criterion
        # as review-bundle-budget: PR #622 showed that editing the review-and-fix root
        # or its extension moves this record's suite-bound Measured/cumulative cells and
        # turns the suite RED — the discover-drift-a-full-suite-run-later cost this helper
        # exists to remove. Like its sibling it measures NOTHING: re-deriving `_raf_words`
        # here would be a second implementation of a measurement the suite already owns.
        "record": "docs/review-and-fix-budget.md",
        "watch_literals": (
            "skills/review-and-fix/SKILL.md",
            ".devflow/prompt-extensions/review-and-fix.md",
        ),
        "watch_globs": ("skills/review-and-fix/references/*.md",),
    },
    {
        "name": "coverage-map-ratchet",
        "kind": "judgment",
        "argv": ("python3", "lib/test/coverage_map_guard.py", "."),
        "check": None,  # bound to run_row below.
        "clean": (0,),
        "exits": (0, 1),
        "policy": "add the missing coverage rows per the issue-591 ratchet in lib/test/modules/coverage-map.json",
        # Same discriminator: the guard prefixes a genuine input failure (git absent,
        # not a repo) with `[input-error]` and exits 1, identically to a real ratchet
        # violation. That is not a coverage-row problem and must not be reported as one.
        # `[input-error]` covers only the git-ls-files failure. An absent or malformed
        # coverage-map / registry takes a different path (`[arm4]` / `[arm8]`), and arm 4
        # RETURNS before every map-dependent arm — so an unreadable map both suppresses
        # every real violation AND, without these markers, reported as a judgment item
        # telling the agent to add rows to the very file the guard could not read.
        # Matched on the ARM PREFIX, not on each arm's message text. Arm 4 has two
        # early-return legs — `coverage-map unreadable: …` AND `{shape_error}` (a
        # structurally-valid but wrong-shape map: a bad merge, a truncated write, a
        # schema bump landing before the migration) — and both suppress every
        # map-dependent arm identically. Enumerating the unreadable leg alone left the
        # shape leg reported as `add the missing coverage rows`, telling the agent to
        # edit rows in the very file whose schema is broken, while every genuine
        # violation stayed invisible. Enumerating each shape string instead would
        # re-couple this row to a dozen literals in another module with nothing pinning
        # them together; the prefix is stable and cannot drift that way.
        # Safe because EVERY `[arm4]`/`[arm8]` emission in coverage_map_guard.py is an
        # input failure — genuine ratchet violations carry the other arm numbers.
        "infra_markers": (
            "[input-error]",
            "[arm4] ",
            "[arm8] ",
        ),
    },
)


def default_repo_root():
    """The repo root to operate on when `--repo-root` is absent.

    `git rev-parse --show-toplevel` first (mirroring the repo's #295 root-anchoring
    contract), falling back to the checkout containing this script when git cannot
    answer — a fixture root is commonly not a git repository at all.

    The probe runs with `cwd` anchored to THIS SCRIPT's checkout, not the process
    working directory. Unanchored, the helper invoked from inside a different
    repository would resolve that repository as its root and regenerate the manifest
    under the wrong tree — not hypothetical in a repo that runs agents from
    `.claude/worktrees/` checkouts.
    """
    here = Path(__file__).resolve().parents[2]
    try:
        out = subprocess.run(
            ("git", "rev-parse", "--show-toplevel"),
            cwd=str(here),
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return here
    if out.returncode == 0 and out.stdout.strip():
        return Path(out.stdout.strip())
    return here


def watch_list(row, root):
    """One budget row's watch list expanded against disk under `root`.

    Returns `(members, missing)`. Expansion (rather than a literal glob string) is what
    lets the suite compare this against the disk-derived bundle membership, so a new
    reference cannot make the row silently fail open on ADDITIONS.

    `missing` closes the opposite direction, for BOTH legs. Filtering by existence alone
    is a guard standing in for membership: a renamed or moved member would simply vanish
    from the list, and the row would then report "no bundle member changed" for the very
    change that moved it. That holds for a literal (`is_file()` false) and equally for a
    glob whose PARENT directory is gone — `Path.glob` over a nonexistent directory yields
    nothing and raises nothing, so a renamed reference directory would empty the list in
    silence. Both are reported as UNESTABLISHED, never silently dropped — the same
    unknown-is-not-zero discipline the git legs follow.
    """
    members, missing = [], []
    for rel in row["watch_literals"]:
        (members if (root / rel).is_file() else missing).append(rel)
    for pattern in row["watch_globs"]:
        parent, _, leaf = pattern.rpartition("/")
        if not (root / parent).is_dir():
            missing.append(pattern)
            continue
        # `glob` walks the directory, so an unreadable one raises rather than yielding
        # nothing. Report the pattern as missing (the UNESTABLISHED arm the caller
        # already handles) instead of letting an OSError escape as a traceback.
        try:
            found = sorted(
                p.relative_to(root).as_posix() for p in (root / parent).glob(leaf)
            )
        except OSError:
            missing.append(pattern)
            continue
        members.extend(found)
    return sorted(set(members)), sorted(missing)


def _git_out(root, argv):
    """One git call under `root`. Returns its stdout, or None if unestablished.

    None means the measurement could not be established (git missing, a git error, a
    shallow clone with no merge-base) — a caller must not read that as "no output".
    Every git call in the CHANGE-SET DERIVATION goes through here, so the OSError guard
    cannot be present at one derivation call site and forgotten at another.
    (`default_repo_root` above is the one git call outside this helper — it runs before
    a root exists to pass as `cwd`, and carries its own OSError guard.)
    """
    try:
        out = subprocess.run(
            argv, cwd=str(root), capture_output=True, text=True, check=False
        )
    except OSError:
        return None
    return out.stdout if out.returncode == 0 else None


def _git_paths(root, argv):
    """A git path-listing call as a set of repo-relative paths, or None (unestablished)."""
    text = _git_out(root, argv)
    return None if text is None else {line for line in text.splitlines() if line}


def is_budget_row(row):
    """Whether `row` is a git-staleness budget row.

    ONE spelling of this predicate, used by both the check-strategy binding below and
    `emit_list`. Keyed on the watch list the callers actually consume, never on the proxy
    "has no argv": those coincide only because every command-less row today is a budget
    row. Keying on the real property means a misregistered row fails where it is used,
    with the missing key named — a command-less non-budget row (a pure-Python check, a
    placeholder) is classified False here and reaches `run_row`, which says so. Under the
    proxy the same row would be classified True and handed to `budget_row`/`watch_list` as
    if it carried a watch list it never declared. The module's registry-invariant arm pins
    the coincidence and the budget-row key set, so the day either breaks, the suite says so
    rather than this docstring silently going stale.
    """
    return "watch_literals" in row


def budget_row(row, root, report):
    """Detect a stale budget record for whichever budget row is passed in.

    Returns `(forces_exit_1, infrastructure)`, like every other row's check callable —
    `budget_row` never selects the infrastructure state, so its second element is
    always False, but the arity is the uniform one `main()` dispatches through.

    Every record/watch-list value is read from `row`, never from module-level constants,
    so a second budget row is a registry entry rather than a second copy of this
    function. This row measures nothing: re-deriving the suite's word counter here would
    be a second implementation of a measurement the suite already owns. It only answers
    "did the bundle prose change while the record stayed untouched?", which is the
    staleness a loop induces and the suite then discovers a full run later.
    """
    name = row["name"]
    record = row["record"]
    uncommitted = _git_paths(root, ("git", "diff", "--name-only", "HEAD"))
    untracked = _git_paths(
        root, ("git", "ls-files", "--others", "--exclude-standard")
    )
    # Three-dot syntax IS the merge-base-then-diff composition, in one process rather
    # than two — and it degrades identically (exit 128, hence None) when
    # refs/remotes/origin/main is absent, which is what the `unestablished` arm keys on.
    branch = _git_paths(root, ("git", "diff", "--name-only", "origin/main...HEAD"))

    # Each of the three inputs is required. An unestablished one is never collapsed
    # onto an empty set: that would silently report a clean record for a branch whose
    # diff could not be read at all.
    if uncommitted is None or untracked is None or branch is None:
        report.append(
            f"[{name}] INFO unestablished — the change set could not be derived "
            "(no origin/main, a shallow clone, or a git error). The budget record was "
            "NOT checked for staleness; this arm is unresolvable in-loop and forces no "
            "exit state."
        )
        return False, False

    members, missing = watch_list(row, root)
    if missing:
        report.append(
            f"[{name}] INFO unestablished — watch-list member(s) absent from the tree: "
            f"{', '.join(missing)}. A renamed or moved bundle member cannot be checked "
            "for staleness, so this row reports no verdict rather than a false clean."
        )
        return False, False
    union = uncommitted | untracked | branch
    # Intersecting against the EXPANDED members alone fails open on a DELETED or renamed
    # individual glob member: the parent still exists (so `missing` is empty and the
    # unestablished arm never fires), the old path is gone from disk (so it is not in
    # `members`), yet git reports it in the change set. The row would then print "no
    # review-bundle member changed" for exactly the change that moved it. Matching the
    # patterns themselves closes that leg — the same direction already closed for the
    # renamed-literal and renamed-parent legs.
    touched = sorted(
        path
        for path in union
        if path in set(members)
        # PurePosixPath.match, not fnmatch: fnmatch's `*` crosses `/`, so it would
        # match a NESTED path (skills/review/phases/sub/x.md) that the disk-side
        # Path.glob leg never yields. The two legs must accept the same set, or this
        # one over-reports on a tree the other cannot produce.
        or any(
            PurePosixPath(path).match(pattern) for pattern in row["watch_globs"]
        )
    )
    if not touched:
        report.append(f"[{name}] clean — no bundle member changed in this change set")
        return False, False
    if record in union:
        report.append(
            f"[{name}] INFO bundle members changed ({', '.join(touched)}) and "
            f"{record} is already in this change set — figure correctness is "
            "deferred to the suite's own word measurement. No action forced."
        )
        return False, False
    report.append(
        f"[{name}] JUDGMENT bundle prose changed but the record is untouched.\n"
        f"    changed members: {', '.join(touched)}\n"
        f"    governing policy: {row['policy']}\n"
        f"    Re-measure the affected figures in one pass and apply one edit to "
        f"{record}."
    )
    return True, False


def _marker_hit(markers, output):
    """The first marker contained in some single output line, else None.

    Scoped per LINE rather than against the concatenated blob: a marker must appear
    within one emitted diagnostic, so it can never be assembled across a line break
    from two unrelated messages.

    Deliberately NOT anchored to the line start. The markers are not uniformly
    line-leading — the census's `: malformed JSON:` and `: unreadable:` are mid-line
    fragments of `prompt-mass census: <path>: malformed JSON: …`, while the
    coverage-map guard's `[arm4] …` and `[input-error]` are line-leading. A
    startswith() rule would silently stop matching every marker the census row declares
    — they are all mid-line — and reopen exactly the fail-open this discriminator exists
    to close, so the residual risk (a marker quoted inside a longer diagnostic on one
    line) is accepted rather than traded for a worse one.
    """
    return next(
        (m for m in markers if any(m in line for line in output.splitlines())),
        None,
    )


def run_row(row, root, report):
    """Execute one command-backed row. Returns (forces_exit_1, infrastructure)."""
    name = row["name"]
    # The script is the first non-flag argv element after the interpreter — NOT slot 1
    # positionally. A future row spelled `("python3", "-m", "pkg")` (or carrying a
    # leading flag) would resolve `root / "-m"`, which never exists, and the
    # declared-set branch below would then assert `(target absent: -m)` about a script
    # that is present — a misdirected diagnosis on an already-failing path. When no
    # script can be identified, claim no absence at all.
    target_rel = next((a for a in row["argv"][1:] if not a.startswith("-")), None)
    # The mechanical generator writes unconditionally on success, so "did anything
    # change?" is answered by bracketing the run with byte snapshots — never by the
    # generator's own wording, which says "wrote <path>" either way.
    written = root / row["writes"] if row["kind"] == "mechanical" else None
    # The snapshot is an OS read, and it brackets the run OUTSIDE the try below (which
    # covers only subprocess.run). An unreadable/undeletable manifest (PermissionError,
    # IsADirectoryError — what a half-restored worktree or a root-owned fixture
    # produces) would otherwise escape as a traceback, and a traceback exits 1: the
    # infrastructure state aliased onto "action required", which is the exact
    # unknown-collapsed-onto-a-real-value class this helper exists to prevent.
    try:
        before = written.read_bytes() if written and written.is_file() else None
    except OSError as error:
        report.append(
            f"[{name}] INFRASTRUCTURE could not read {row['writes']} before the run "
            f"({error}) — nothing was compared and nothing was verified."
        )
        return False, True
    try:
        proc = subprocess.run(
            row["argv"], cwd=str(root), capture_output=True, text=True, check=False
        )
    except OSError as error:
        report.append(
            f"[{name}] INFRASTRUCTURE the command failed to launch: "
            f"{' '.join(row['argv'])} ({error})"
        )
        return False, True
    output = (proc.stdout + proc.stderr).strip()

    # An absent script is reported by the interpreter as exit 2 with a "can't open
    # file" diagnostic rather than an OSError, so the declared-set check below is what
    # actually catches it. Naming the path here keeps that diagnosis attributable.
    declared = row["exits"]
    if proc.returncode not in declared:
        missing = (
            ""
            if target_rel is None or (root / target_rel).exists()
            else f" (target absent: {target_rel})"
        )
        report.append(
            f"[{name}] INFRASTRUCTURE `{' '.join(row['argv'])}` exited "
            f"{proc.returncode}, outside its declared set {declared}{missing}\n"
            f"    output: {output or '(none)'}"
        )
        return False, True

    if row["kind"] == "mechanical":
        try:
            after = written.read_bytes() if written.is_file() else None
        except OSError as error:
            report.append(
                f"[{name}] INFRASTRUCTURE could not read {row['writes']} after the run "
                f"({error}) — the change comparison never happened."
            )
            return False, True
        return _mechanical_outcome(row, proc, output, before != after, after, report)

    if proc.returncode in row["clean"]:
        report.append(
            f"[{name}] clean — `{' '.join(row['argv'])}` exited {proc.returncode}"
        )
        return False, False
    hit = _marker_hit(row.get("infra_markers", ()), output)
    if hit is not None:
        report.append(
            f"[{name}] INFRASTRUCTURE `{' '.join(row['argv'])}` exited "
            f"{proc.returncode} reporting an input failure, not drift "
            f"(matched {hit!r}) — the artifact was NOT checked:\n"
            f"    output: {output or '(none)'}"
        )
        return False, True
    report.append(
        f"[{name}] JUDGMENT `{' '.join(row['argv'])}` exited {proc.returncode}\n"
        f"    output: {output or '(none)'}\n"
        f"    governing policy: {row['policy']}"
    )
    return True, False


def _mechanical_outcome(row, proc, output, changed, after, report):
    """Classify the mechanical row's outcome. Returns (forces_exit_1, infrastructure)."""
    name = row["name"]
    if proc.returncode in row["clean"]:
        if after is None:
            report.append(
                f"[{name}] INFRASTRUCTURE `{' '.join(row['argv'])}` exited 0 but "
                f"{row['writes']} is absent — the generator produced no artifact, so "
                "there is nothing to compare and nothing was verified."
            )
            return False, True
        if not changed:
            report.append(f"[{name}] clean — {row['writes']} already matches the closure")
            return False, False
        report.append(
            f"[{name}] REGENERATED {row['writes']} changed — commit it with your edits."
        )
        return True, False

    # Exit 1. `check_closure()` runs before every subcommand and returns 1 with
    # `cloud-writer-contract:`-prefixed lines when a classified asset is absent, a
    # helper head is missing, and the like — exactly what a loop's rename/delete edits
    # produce. Keying on the generator's own marker is what separates that reconcilable
    # closure error from an interpreter traceback, which must not be dressed up as a
    # judgment item the agent is told to "resolve".
    if _marker_hit(("cloud-writer-contract:",), output) is not None:
        report.append(
            f"[{name}] JUDGMENT the closure is broken (exit 1):\n"
            f"{output}\n"
            f"    governing policy: {row['policy']}\n"
            "    Reconcile the closure — this is a closure error, not an "
            "infrastructure fault."
        )
        return True, False
    report.append(
        f"[{name}] INFRASTRUCTURE exited 1 with no `cloud-writer-contract:` marker "
        "(an interpreter traceback or an unhandled exception):\n"
        f"{output or '(no output)'}"
    )
    return False, True


# Bind each row's check strategy now that both callables exist. Done here rather than
# in the table because the table is defined above the functions it names.
for _row in ROWS:
    _row["check"] = budget_row if is_budget_row(_row) else run_row


def emit_list(root):
    for row in ROWS:
        command = " ".join(row["argv"]) if row["argv"] else "(git-derived staleness check)"
        print(f"artifact\t{row['name']}\t{row['kind']}\t{command}")
    # Row-attributed since issue #624: with more than one budget row a bare
    # `budget-watch\t<path>` line cannot say WHICH row's watch list a member belongs to,
    # so a member silently migrating between rows — or a row losing its list entirely
    # while the other still emits — would read identically. The row name is the second
    # field precisely so a consumer keys on (row, member), never on the path alone.
    for row in ROWS:
        if not is_budget_row(row):
            continue
        members, missing = watch_list(row, root)
        for member in members:
            print(f"budget-watch\t{row['name']}\t{member}")
        for absent in missing:
            print(f"budget-watch-missing\t{row['name']}\t{absent}")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=(
            "Run one batched pass over the suite-owned generated artifacts: regenerate "
            "the mechanical row, check every judgment row, and report all judgment "
            "items together."
        )
    )
    parser.add_argument(
        "--repo-root",
        default=None,
        help=(
            "Root to operate on. Defaults to `git rev-parse --show-toplevel`, falling "
            "back to the checkout containing this script."
        ),
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="Print the registered artifacts and the budget watch list; run no row.",
    )
    args = parser.parse_args(argv)
    root = Path(args.repo_root).resolve() if args.repo_root else default_repo_root()

    if args.list:
        return emit_list(root)

    report = []
    forces_one = False
    infrastructure = False

    # `report` is accumulated and flushed only after every row, so an exception in a
    # late row would discard the earlier rows' findings too — the caller would then see
    # a traceback, exit 1, and NO report lines, and the prompt guard (which keys the
    # never-checked verdict on the literal INFRASTRUCTURE plus exit 2) would fall
    # through to the exit-1 branch over an empty report. `finally` guarantees whatever
    # was established still prints; the top-level net below supplies the exit-2 state.
    try:
        for row in ROWS:
            forced, infra = row["check"](row, root, report)
            forces_one = forced or forces_one
            infrastructure = infra or infrastructure
    finally:
        for line in report:
            print(line)

    if infrastructure:
        print("regenerate-artifacts: INFRASTRUCTURE failure — exit 2")
        return 2
    if forces_one:
        print(
            "regenerate-artifacts: action required — commit any regenerated artifact "
            "and resolve each JUDGMENT item under its named policy before the suite run "
            "— exit 1"
        )
        return 1
    print("regenerate-artifacts: all artifacts reconciled — exit 0")
    return 0


if __name__ == "__main__":
    # An unhandled exception would otherwise exit 1 — the SAME code as "a judgment item
    # was printed" — so the caller could not tell an unchecked run from a resolvable
    # one. Route it to the declared infrastructure state (exit 2) with the same
    # `INFRASTRUCTURE` literal the row reports use, so a consumer keying on that token
    # sees it here too. `SystemExit` is re-raised untouched: main()'s own three states
    # pass through unchanged.
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except Exception as _error:  # noqa: BLE001 — deliberate top-level net
        traceback.print_exc()
        print(
            "regenerate-artifacts: INFRASTRUCTURE failure — unhandled "
            f"{type(_error).__name__}: {_error} — no artifact state was established "
            "— exit 2",
            file=sys.stderr,
        )
        raise SystemExit(2) from None
