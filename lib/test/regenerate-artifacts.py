#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""One batched pass over the suite-owned generated artifacts (issue #619).

A fix or implement loop that edits prompt surfaces, engine files, or the capability
manifest induces drift in checked-in generated records.
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
loop-induced edits AND whose state this helper can establish without writing it via a
standalone non-writing check command (a regeneration command, for a mechanical row, or a
non-writing checker for a judgment row).

DELIBERATELY EXCLUDED as an artifact row, because it is REDUNDANT — not because it is
uncovered: `scripts/workflow-flight-recorder-registry.json` is a hand-maintained
inventory with no *regeneration* command (nothing can rewrite it from the tree), and it
is already checked by a command a row here runs — the coverage guard's `[arm8]` arm
covers the flight-recorder registry. A row of its own could only re-report what
`coverage-map-ratchet` already reports.

WRITE SCOPE: the only file under the target root this helper writes is
`scripts/devflow-cloud-writer-contract.json` (the mechanical row's output). Every
judgment row runs a non-writing check and never writes its artifact.

EXIT CONTRACT (exactly three states):
  0 — every row resolved in its declared clean state (its command exited in that
      state), the mechanical regeneration changed nothing, and no exit-1-forcing
      judgment item was printed.
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

These three are the states main() itself selects. argparse also exits 2 on a usage
error (an unknown flag) before any row runs — the same code as the infrastructure
state, and consistent with it (nothing was checked), but it is not one of the three
states above and no row report accompanies it.
"""

import argparse
import importlib.util
import subprocess
import sys
import traceback
from pathlib import Path

MECHANICAL_ARTIFACT = "scripts/devflow-cloud-writer-contract.json"

# The closed set of conflict-resolution classes (issue #655). A merge conflict in a
# checked-in generated artifact must never be hand-merged: hand-merged bytes match no
# source of truth, and the row's own gate then reports the result as drift with a remedy
# that steers the agent at the wrong file. `conflict_class` states WHICH remedy applies:
#   regenerate       — re-run the row's writer against the merged tree; the artifact is a
#                      pure function of its source, so the merged source is the answer.
#   reconcile-source — merge the SOURCE of truth first, regenerate from it, then
#                      hand-update whatever coupled by-hand sibling the row names.
#   by-hand          — no writer exists; a human re-measures or hand-merges the record.
# Kept a module-level constant so a row's class is validated against one enumeration
# rather than each consumer re-spelling the vocabulary.
CONFLICT_CLASSES = ("regenerate", "reconcile-source", "by-hand")

# Ordered registry. `argv` is resolved under the target root and run with that root as
# the working directory, so a fixture root exercises the fixture's own generators.
# `exits` is the row's declared exit-code set and `clean` its positive arm; an exit
# outside `exits` is the infrastructure state, never a clean pass.
# Every row is command-backed: main() dispatches each through run_row uniformly rather than
# re-deciding per row (run_row still special-cases the mechanical kind internally).
ROWS = (
    {
        "name": "cloud-writer-manifest",
        "kind": "mechanical",
        "argv": ("python3", "lib/test/cloud_writer_contract.py", "generate"),
        "clean": (0,),
        "exits": (0, 1),
        "writes": MECHANICAL_ARTIFACT,
        # `policy` is the SINGLE recipe source (issue #655): the batched-pass
        # `governing policy:` line and the `conflict-recipe` emit read this one field, so
        # a second, parallel recipe field cannot drift from it. A `regenerate` row's policy
        # must therefore name a runnable WRITE command — the row's `argv` here happens to
        # be that writer, but two other rows' `argv` is a non-writing checker, so the
        # recipe states the command explicitly rather than deriving it from `argv`.
        "policy": (
            "the closure data in lib/test/cloud_writer_contract.py "
            "(ROOTS / DISPATCH_EDGES / SKILL_ASSETS / required helper heads) — "
            "regenerate against the merged tree with "
            "`python3 lib/test/cloud_writer_contract.py generate`"
        ),
        "conflict_class": "regenerate",
    },
    {
        "name": "capability-profile-literals",
        "kind": "judgment",
        "argv": ("python3", "lib/generate-capability-profiles.py", "--check"),
        "clean": (0,),
        "exits": (0, 1),
        "policy": (
            "merge lib/capability-profiles.json first, regenerate with "
            "`python3 lib/generate-capability-profiles.py`, and hand-"
            "update lib/review-profile.tokens when the resolved review list widens"
        ),
        # reconcile-source, not regenerate: the generated workflow literals are a pure
        # function of the manifest, but the manifest itself is the conflicted source and
        # the reviewer lock is a by-hand sibling the generator NEVER writes. Regenerating
        # before merging the manifest would silently revert whichever grant the
        # concurrent PR added.
        "conflict_class": "reconcile-source",
        # The conflicted SOURCE of truth is the manifest; the generated workflow literals
        # are appended at emit time from the generator's own REGIONS (bound below).
        "conflict_paths": ("lib/capability-profiles.json",),
        "conflict_paths_extra": None,  # bound to _capability_region_targets below.
        "coupled_by_hand": (("lib/review-profile.tokens", "by-hand"),),
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
        "name": "coverage-map-ratchet",
        "kind": "judgment",
        "argv": ("python3", "lib/test/coverage_map_guard.py", "."),
        "clean": (0,),
        "exits": (0, 1),
        "policy": "add the missing coverage rows per the issue-591 ratchet in lib/test/modules/coverage-map.json (for a run_sh_blocks completeness/attribution item, `python3 lib/test/coverage_map_guard.py . --fix` is the hand-invoked repair)",
        # by-hand, and it STAYS by-hand: since issue #695 coverage_map_guard.py does have
        # a write path, but only behind the explicit, hand-invoked `--fix` flag. The
        # `argv` above deliberately omits it, so this row still runs a non-writing check
        # and the batched pass leaves the map byte-unchanged — the property the `#619 A3`
        # write-scope assertion pins. Wiring `--fix` into this row would flip that
        # assertion RED. The files half of the map remains hand-merged, row by row.
        "conflict_class": "by-hand",
        "conflict_paths": ("lib/test/modules/coverage-map.json",),
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


def _capability_region_targets(root):
    """The generated workflow literal files, read from the GENERATOR's own region list.

    Sourced rather than re-enumerated (issue #655): the five workflow paths already live
    in `lib/generate-capability-profiles.py`'s `REGIONS`, and a second copy here would be
    a coupled mirror that goes stale the day a region is added or renamed — the exact
    drift class this repo's coupled-invariant rule exists to stop.

    The generator is stdlib-only with no import side effects (it defines constants and
    functions; every file read happens inside a subcommand), so importing it is safe.
    A failure to import or to read `REGIONS` RAISES rather than returning a partial set:
    a silently short list would leave a real conflict path unmatched, and the conflict
    rule would then send the agent down its hand-merge default for a generated artifact —
    unknown collapsed onto "not a generated artifact", the fail-open this helper's whole
    exit contract is built to avoid. The top-level net routes the raise to exit 2.
    """
    path = root / "lib" / "generate-capability-profiles.py"
    spec = importlib.util.spec_from_file_location("_devflow_capgen", path)
    # Defensive, and deliberately not covered by a test arm (#659 review, Suggestion 3): this is
    # the documented `None` return of the importlib API (an unrecognized suffix / no loader for
    # the location), which a `.py` path cannot reach — an ABSENT file still yields a spec with a
    # loader and surfaces as `exec_module`'s FileNotFoundError, which is the arm `_ra_region_fails_infra`
    # actually drives. Kept rather than removed: it raises into the same exit-2 route as every
    # other arm here, so its cost is two lines and its removal would make an API contract change
    # fail open on a partial region set. There is no fixture that reaches it without mutating
    # importlib itself.
    if spec is None or spec.loader is None:
        raise RuntimeError(f"capability generator not importable: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    targets = {
        Path(region["file"]).resolve().relative_to(Path(module.REPO_ROOT).resolve()).as_posix()
        for region in module.REGIONS
    }
    if not targets:
        raise RuntimeError("capability generator declared no regions")
    return tuple(sorted(targets))


def conflict_paths(row, root):
    """The generated artifact file path(s) a merge conflict in `row` can land in.

    Two sources, both keyed on a DECLARED FIELD — never on the row's name. Keying on a name
    string is a "proxy instead of the real property": a row rename is an ordinary registry
    edit, and under a name check it would silently drop the generator-sourced workflow
    literals with no field anywhere declaring that the name was load-bearing.

    * the row's static `conflict_paths`, defaulting to the `writes` field the mechanical
      row already states, so no row restates a path the registry already carries; plus
    * `conflict_paths_extra`, an optional per-row callable taking the target root and
      returning additional paths derived at emit time. Bound below the function definitions
      because the table is defined above the function it names.
    """
    static = tuple(row["conflict_paths"]) if "conflict_paths" in row else (row["writes"],)
    extra = row.get("conflict_paths_extra")
    return static + (tuple(extra(root)) if extra else ())


def _marker_hit(markers, output):
    """The first marker contained in some single output line, else None.

    Scoped per LINE rather than against the concatenated blob: a marker must appear
    within one emitted diagnostic, so it can never be assembled across a line break
    from two unrelated messages.

    Deliberately NOT anchored to the line start. The markers are not uniformly
    line-leading — the capability row's `manifest unreadable:` and `manifest malformed
    JSON:` appear mid-line in a diagnostic such as `capability profiles: <path>: manifest
    unreadable: …`, while the coverage-map guard's `[arm4] …` and `[input-error]` are
    line-leading. A startswith() rule would silently stop matching every mid-line marker a
    row declares and reopen exactly the fail-open this discriminator exists to close, so
    the residual risk (a marker quoted inside a longer diagnostic on one line) is accepted
    rather than traded for a worse one.
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


# The capability row's extra paths come from the capability generator's own REGIONS. Bound
# here rather than in the table (which is defined above the function it names), and as a
# FIELD, so `conflict_paths` never keys on a row name.
for _row in ROWS:
    if _row.get("conflict_paths_extra", "unset") is None:
        _row["conflict_paths_extra"] = _capability_region_targets


def _validate_registry():
    """Fail closed on a misregistered conflict class, recipe, or path source (issue #655).

    Run at import (below), so every entry path — main, --list, an importing test — hits it
    and a row that cannot be classified never reaches `--list` to emit an unknown class a
    consumer would have no route for.

    Import-time strictness is kept, but the raise is ROUTED to the exit-2 infrastructure
    state for a script run (see the module-level call below). A bare module-level raise
    would exit **1** — the resolvable "action required" code — because the module body runs
    before the `if __name__ == "__main__"` net at the bottom of this file can catch
    anything. That aliases an unchecked run onto a resolvable one, the precise
    discrimination this module's EXIT CONTRACT says the net exists to preserve.
    """
    for row in ROWS:
        if row.get("conflict_class") not in CONFLICT_CLASSES:
            raise ValueError(
                f"registry row {row['name']!r} declares conflict_class "
                f"{row.get('conflict_class')!r}, which is outside {CONFLICT_CLASSES}"
            )
        if not (row.get("policy") or "").strip():
            raise ValueError(f"registry row {row['name']!r} declares an empty recipe (policy)")
        # A row must declare SOME static path source, checked at this same import-time point
        # rather than left to KeyError inside emit_list: a row that reaches `--list` before
        # failing has already been handed to a consumer.
        # Membership is not enough: `"conflict_paths": ()` satisfies `in` and short-circuits the
        # writes fallback, so the row resolves to NO path and the shipped rule routes its
        # artifact to the hand-merge default — the fail-open the rule exists to close, reached
        # through the one invariant #655 states and nothing enforced. Require a non-empty source.
        if "conflict_paths" in row:
            if not tuple(row["conflict_paths"]):
                raise ValueError(
                    f"registry row {row['name']!r} declares an empty conflict_paths; "
                    "a row must resolve to at least one conflict path"
                )
        elif "writes" not in row:
            raise ValueError(
                f"registry row {row['name']!r} declares no conflict-path source "
                "(needs one of conflict_paths / writes)"
            )


# Validate at import — but route a script run's failure to exit 2 (INFRASTRUCTURE), never the
# exit 1 a bare module-level raise would produce. An IMPORTING caller still gets the raw
# ValueError, so a test can assert the exception itself.
try:
    _validate_registry()
except ValueError as _bind_error:
    if __name__ != "__main__":
        raise
    print(
        f"regenerate-artifacts: INFRASTRUCTURE — registry validation failed: {_bind_error} "
        "— nothing was checked — exit 2",
        file=sys.stderr,
    )
    raise SystemExit(2) from None


def emit_list(root):
    for row in ROWS:
        command = " ".join(row["argv"])
        print(f"artifact\t{row['name']}\t{row['kind']}\t{command}")
    # The conflict-oracle lines (issue #655), emitted AFTER the artifact lines above so
    # that format stays byte-unchanged and every existing prefix-anchored consumer
    # (`artifact\tNAME\t`) parses exactly as before.
    #
    # A conflict rule matches a conflicted path against `conflict-path` and
    # `conflict-sibling`, then reads that row's `conflict-class` and `conflict-recipe`.
    # The recipe is the row's `policy` verbatim — the SAME field the batched pass prints
    # as `governing policy:` — so the two consumers structurally cannot drift.
    #
    # A coupled by-hand sibling is a file the row's gate READS but never writes, and which
    # is not a registry row of its own (it has no independent check, so it fails the
    # registry's inclusion criterion). The oracle must still name it, or a conflict in it
    # matches nothing and takes the hand-merge default.
    #
    # One pass over ROWS rather than one pass per line kind: every consumer lookup is
    # prefix-anchored (`conflict-path\t<row>\t…`), so nothing depends on the kinds being
    # grouped, and a single loop keeps "what one row emits" readable in one place.
    # No path may be claimed by two rows: the conflict rule reads the matched path's class, so a
    # duplicate would yield two contradictory classes with no stated tiebreak. Resolution is
    # root-dependent (the capability row derives its workflow literals), so this cannot move to the
    # import-time bind loop; it raises here and the top-level net routes it to the exit-2
    # infrastructure state — never a listing a consumer could act on.
    # Siblings join the SAME uniqueness namespace as conflict paths (#659 review, Suggestion 1):
    # the shipped rule matches a conflicted path against the `conflict-path` AND
    # `conflict-sibling` lines together, and the two line kinds carry DIFFERENT classes (a
    # sibling's class is its own fourth field, never the owning row's). A path emitted as both
    # would therefore hand the rule two contradictory classes with no stated tiebreak — the same
    # fail-open a two-row duplicate is, one line kind over. Deduping only within the path set
    # leaves exactly that gap unguarded.
    _seen_paths = {}
    for row in ROWS:
        for path in conflict_paths(row, root):
            if path in _seen_paths:
                raise ValueError(
                    f"conflict path {path!r} is claimed by both {_seen_paths[path]!r} and "
                    f"{row['name']!r}; a path must resolve to exactly one conflict class"
                )
            _seen_paths[path] = row["name"]
    for row in ROWS:
        for path, _sibling_class in row.get("coupled_by_hand", ()):
            if path in _seen_paths:
                raise ValueError(
                    f"conflict path {path!r} is claimed by both {_seen_paths[path]!r} and "
                    f"{row['name']!r} (as a coupled by-hand sibling); a path must resolve to "
                    "exactly one conflict class"
                )
            _seen_paths[path] = row["name"]
    for row in ROWS:
        print(f"conflict-class\t{row['name']}\t{row['conflict_class']}")
        for path in conflict_paths(row, root):
            print(f"conflict-path\t{row['name']}\t{path}")
        print(f"conflict-recipe\t{row['name']}\t{row['policy']}")
        for path, sibling_class in row.get("coupled_by_hand", ()):
            print(f"conflict-sibling\t{row['name']}\t{path}\t{sibling_class}")
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
        help="Print the registered artifacts; run no row.",
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
            forced, infra = run_row(row, root, report)
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
