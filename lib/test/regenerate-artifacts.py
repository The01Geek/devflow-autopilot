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
loop-induced edits AND which has a standalone non-writing check command (a
regeneration command, for a mechanical row).

DELIBERATELY EXCLUDED as artifact rows (disclosed non-goal):
`scripts/workflow-flight-recorder-registry.json` and `lib/test/prompt-mass-manifest.json`
are hand-maintained inventories with no standalone check command, so they meet no
inclusion criterion and are not rows here.

KNOWN UNCOVERED SIBLING (disclosed, not a claim of completeness):
`docs/review-and-fix-budget.md` meets the drift half of the inclusion criterion — its
suite-bound Measured/cumulative cells go stale the moment a loop edits the
review-and-fix root or its extension — but it has no row here. The registry is the
closed set issue #619 specified, not an exhaustive sweep of every stale-able record;
adding this sibling (as a second git-staleness row) is deliberately left to a follow-up
rather than widened in silence.

WRITE SCOPE: the only file under the target root this helper writes is
`scripts/devflow-cloud-writer-contract.json` (the mechanical row's output). Every
judgment row runs a non-writing check and never writes its artifact.

EXIT CONTRACT (exactly three states):
  0 — every row's command exited in its declared clean state, the mechanical
      regeneration changed nothing, and no exit-1-forcing judgment item was printed.
  1 — at least one of {the manifest bytes changed, an exit-1-forcing judgment item
      was printed} holds, and no row hit the infrastructure state.
  2 — infrastructure failure: a row's command failed to launch (absent file,
      interpreter launch failure), or a launched command exited outside its row's
      declared exit set. Exit 2 takes precedence over exit 1.
Informational lines (the budget row's resolved and `unestablished` arms) select no
state by themselves.

These three are the states main() itself selects. argparse also exits 2 on a usage
error (an unknown flag) before any row runs — the same code as the infrastructure
state, and consistent with it (nothing was checked), but it is not one of the three
states above and no row report accompanies it.
"""

import argparse
import subprocess
from pathlib import Path

MECHANICAL_ARTIFACT = "scripts/devflow-cloud-writer-contract.json"

# The review-bundle watch list: the members whose prose the suite measures with
# `_rb_words` for the budget record. `skills/review/phases/*.md` is a glob so a new
# phase reference joins the watch list the moment it lands on disk.
BUDGET_RECORD = "docs/review-bundle-budget.md"
BUDGET_WATCH_LITERALS = ("skills/review/SKILL.md", ".devflow/prompt-extensions/review.md")
BUDGET_WATCH_GLOBS = ("skills/review/phases/*.md",)

# Ordered registry. `argv` is resolved under the target root and run with that root as
# the working directory, so a fixture root exercises the fixture's own generators.
# `exits` is the row's declared exit-code set and `clean` its positive arm; an exit
# outside `exits` is the infrastructure state, never a clean pass.
# `check` is the row's own strategy callable: main() dispatches through it uniformly
# rather than re-deciding per row. The kind->callable binding lives in exactly one place
# (the loop below the function definitions), so a reader has one site to consult; it is
# not branch-free, and run_row still special-cases the mechanical kind.
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
    },
    {
        "name": "prompt-mass-baseline",
        "kind": "judgment",
        "argv": ("python3", "lib/test/prompt-mass-census.py"),
        "check": None,  # bound to run_row below.
        "clean": (0,),
        "exits": (0, 1),
        "policy": "the mandatory-byte census section of .devflow/prompt-extensions/implement.md",
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
    },
    {
        "name": "coverage-map-ratchet",
        "kind": "judgment",
        "argv": ("python3", "lib/test/coverage_map_guard.py", "."),
        "check": None,  # bound to run_row below.
        "clean": (0,),
        "exits": (0, 1),
        "policy": "add the missing coverage rows per the issue-591 ratchet in lib/test/modules/coverage-map.json",
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


def watch_list(root):
    """The review-bundle watch list expanded against disk under `root`.

    Returns `(members, missing)`. Expansion (rather than a literal glob string) is what
    lets the suite compare this against the disk-derived bundle membership, so a new
    phase reference cannot make the budget row silently fail open on ADDITIONS.

    `missing` closes the opposite direction. Filtering the literals by `is_file()` alone
    is an existence guard standing in for membership: a renamed or moved member would
    simply vanish from the list, and the row would then report "no review-bundle member
    changed" for the very change that moved it. An absent literal is therefore reported
    as UNESTABLISHED, never silently dropped — the same unknown-is-not-zero discipline
    the git legs already follow.
    """
    members, missing = [], []
    for rel in BUDGET_WATCH_LITERALS:
        (members if (root / rel).is_file() else missing).append(rel)
    for pattern in BUDGET_WATCH_GLOBS:
        parent, _, leaf = pattern.rpartition("/")
        members.extend(
            sorted(p.relative_to(root).as_posix() for p in (root / parent).glob(leaf))
        )
    return sorted(set(members)), sorted(missing)


def _git_out(root, argv):
    """One git call under `root`. Returns its stdout, or None if unestablished.

    None means the measurement could not be established (git missing, a git error, a
    shallow clone with no merge-base) — a caller must not read that as "no output".
    Every git call in the CHANGE-SET DERIVATION goes through here, so the OSError guard
    cannot be present at one derivation call site and forgotten at another.
    (`default_repo_root` below is the one git call outside this helper — it runs before
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


def budget_row(row, root, report):
    """Detect a stale review-bundle budget record. Returns True when exit-1-forcing.

    This row measures nothing: re-deriving `_rb_words` here would be a second
    implementation of a measurement the suite already owns. It only answers "did the
    bundle prose change while the record stayed untouched?", which is the staleness a
    loop induces and the suite then discovers a full run later.
    """
    name = row["name"]
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

    members, missing = watch_list(root)
    if missing:
        report.append(
            f"[{name}] INFO unestablished — watch-list member(s) absent from the tree: "
            f"{', '.join(missing)}. A renamed or moved bundle member cannot be checked "
            "for staleness, so this row reports no verdict rather than a false clean."
        )
        return False, False
    union = uncommitted | untracked | branch
    touched = sorted(union & set(members))
    if not touched:
        report.append(f"[{name}] clean — no review-bundle member changed in this change set")
        return False, False
    if BUDGET_RECORD in union:
        report.append(
            f"[{name}] INFO bundle members changed ({', '.join(touched)}) and "
            f"{BUDGET_RECORD} is already in this change set — figure correctness is "
            "deferred to the suite's own _rb_words measurement. No action forced."
        )
        return False, False
    report.append(
        f"[{name}] JUDGMENT bundle prose changed but the record is untouched.\n"
        f"    changed members: {', '.join(touched)}\n"
        f"    governing policy: {row['policy']}\n"
        f"    Re-measure the affected figures in one pass and apply one edit to "
        f"{BUDGET_RECORD}."
    )
    return True, False


def run_row(row, root, report):
    """Execute one command-backed row. Returns (forces_exit_1, infrastructure)."""
    name = row["name"]
    target = root / row["argv"][1]
    # The mechanical generator writes unconditionally on success, so "did anything
    # change?" is answered by bracketing the run with byte snapshots — never by the
    # generator's own wording, which says "wrote <path>" either way.
    written = root / row["writes"] if row["kind"] == "mechanical" else None
    before = written.read_bytes() if written and written.is_file() else None
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
        missing = "" if target.exists() else f" (target absent: {row['argv'][1]})"
        report.append(
            f"[{name}] INFRASTRUCTURE `{' '.join(row['argv'])}` exited "
            f"{proc.returncode}, outside its declared set {declared}{missing}\n"
            f"    output: {output or '(none)'}"
        )
        return False, True

    if row["kind"] == "mechanical":
        after = written.read_bytes() if written.is_file() else None
        return _mechanical_outcome(row, proc, output, before != after, report)

    if proc.returncode in row["clean"]:
        report.append(f"[{name}] clean — `{' '.join(row['argv'])}` exited 0")
        return False, False
    report.append(
        f"[{name}] JUDGMENT `{' '.join(row['argv'])}` exited {proc.returncode}\n"
        f"    output: {output or '(none)'}\n"
        f"    governing policy: {row['policy']}"
    )
    return True, False


def _mechanical_outcome(row, proc, output, changed, report):
    """Classify the mechanical row's outcome. Returns (forces_exit_1, infrastructure)."""
    name = row["name"]
    if proc.returncode in row["clean"]:
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
    if "cloud-writer-contract:" in output:
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
    _row["check"] = budget_row if _row["argv"] is None else run_row


def emit_list(root):
    for row in ROWS:
        command = " ".join(row["argv"]) if row["argv"] else "(git-derived staleness check)"
        print(f"artifact\t{row['name']}\t{row['kind']}\t{command}")
    members, missing = watch_list(root)
    for member in members:
        print(f"budget-watch\t{member}")
    for absent in missing:
        print(f"budget-watch-missing\t{absent}")
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

    for row in ROWS:
        forced, infra = row["check"](row, root, report)
        forces_one = forced or forces_one
        infrastructure = infra or infrastructure

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
    raise SystemExit(main())
