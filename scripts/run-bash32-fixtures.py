#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""The trusted process-group supervisor for the macOS Bash 3.2 lane (issue #1277).

Runs the construct-fixture corpus and the per-surface parse fixture under a named
Bash, enforces a deadline on each, and reports **exactly one** domain result from the
closed set ``pass`` / ``fail`` / ``not_applicable``.

Why a Python supervisor rather than `timeout`
---------------------------------------------
GNU `timeout` is not on a stock macOS runner, and this repository's preflight
guarantees only `git`/`gh`/`jq`/`python3` — so a lane built on `timeout` would not
fail, it would produce an empty measurement while every step reported success. It
also would not be enough on its own: a fixture that backgrounds a child and dies
leaves that child holding the job open, so the deadline has to reach the whole
**process group**, not the direct child. Each fixture is therefore launched with
``start_new_session=True`` (its own group) and killed with ``os.killpg`` on expiry.

Watchdog expiry is a distinct outcome, not a fixture failure
------------------------------------------------------------
An expired fixture is recorded as ``watchdog_expiry`` and reported that way per
fixture, and it maps to the domain result ``fail``. Folding it into an ordinary
failure would make a hung lane read as a detected incompatibility — the same
unknown-is-not-zero conflation the classifier avoids on its own inputs.

Interpreter precondition
------------------------
No fixture runs until the named Bash reports ``BASH_VERSINFO[0] == 3`` and
``BASH_VERSINFO[1] == 2``. A corpus that ran green under Bash 5 would report a
verified portable surface it never exercised, so a wrong interpreter is a `fail`
before any fixture starts rather than a green run over the wrong thing.

Domain result
-------------
``not_applicable`` is reserved for one fully-established state: the classifier
established the changed-file population and it selected **no** portable surface. It
is never the result of a failed read — that is what the classifier's ``established``
flag carries, and an unestablished classification arrives here as the complete
portable population instead.

Exit codes: 0 on domain ``pass`` or ``not_applicable``, 1 on domain ``fail``, 2 when
the supervisor could not run at all (unusable manifest, unusable classifier result).
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

DOMAIN_PASS = "pass"
DOMAIN_FAIL = "fail"
DOMAIN_NOT_APPLICABLE = "not_applicable"

#: The classifier contract this supervisor accepts — validated, never coerced.
CLASSIFIER_SCHEMA_VERSION = 1
EXECUTION_SELECTIVE = "selective"

OUTCOME_PASS = "pass"
OUTCOME_FAIL = "fail"
OUTCOME_WATCHDOG = "watchdog_expiry"

#: Grace between the group SIGTERM and the group SIGKILL. A fixture that installs a
#: trap gets a chance to run it — which is exactly what `trap-forms.sh` is about — but
#: cannot hold the lane open by ignoring the signal.
KILL_GRACE_SECONDS = 2.0

#: How long to drain a killed group's pipes. Deliberately its own constant rather than
#: reusing KILL_GRACE_SECONDS: that one is a policy choice about how much time a
#: fixture's trap deserves, and sharing it would silently double the worst-case
#: watchdog latency the next time someone tuned the grace.
KILL_DRAIN_SECONDS = 1.0

#: The interpreter-identity probe's own deadline — a wedged `/bin/bash -c` must not
#: hang the lane either, so the probe is supervised like any fixture.
PROBE_DEADLINE_SECONDS = 30

#: Deadline for the per-surface parse fixture, which runs once over the whole selected
#: population (the construct fixtures carry their own, from the manifest's 4th column).
SURFACE_PARSE_DEADLINE_SECONDS = 60


def _load_signal_launcher(root: Path):
    module_path = root / "lib" / "test" / "signal_launcher.py"
    spec = importlib.util.spec_from_file_location("_portability_signal_launcher", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load the shared spawn helpers at {module_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def read_manifest(path: Path):
    """Return `[(id, script, construct, deadline)]`, raising ValueError on a bad row."""
    rows = []
    for lineno, line in enumerate(path.read_text(encoding="utf-8").split("\n"), start=1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 4:
            raise ValueError(f"{path}:{lineno}: expected 4 tab-separated fields, got {len(fields)}")
        fixture_id, script, construct, deadline = (f.strip() for f in fields)
        if not fixture_id or not script:
            raise ValueError(f"{path}:{lineno}: the id and script fields must both be non-empty")
        try:
            seconds = int(deadline)
        except ValueError:
            raise ValueError(f"{path}:{lineno}: deadline {deadline!r} is not an integer") from None
        if seconds <= 0:
            raise ValueError(f"{path}:{lineno}: deadline must be positive, got {seconds}")
        rows.append((fixture_id, script, construct, seconds))
    if not rows:
        raise ValueError(f"{path}: the manifest declares no fixtures — refusing to report a clean empty corpus")
    return rows


def run_supervised(argv, deadline_seconds, launcher, env=None):
    """Run `argv` in its own process group under a deadline.

    Returns `(outcome, status, duration_seconds, output)`. `outcome` is
    `pass` / `fail` / `watchdog_expiry`; a spawn failure is a `fail` carrying the
    shell status the shared launcher selects (127 not found, 126 not executable), so
    "never started" is never reported as "ran and failed with 1".
    """
    started = time.monotonic()
    try:
        child = subprocess.Popen(  # noqa: S603 - fixed argv, no shell
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            encoding="utf-8",
            errors="replace",
            start_new_session=True,
            preexec_fn=launcher.restore_default_signals,  # noqa: PLW1509 - POSIX-only by design
            env=env,
        )
    except OSError as exc:
        detail = exc.strerror or type(exc).__name__
        # The shared 127-not-found / 126-not-executable policy, so "your fixture never
        # started" is never reported as "your fixture ran and exited 1".
        status = launcher.spawn_failure_status(exc)
        return OUTCOME_FAIL, status, time.monotonic() - started, f"could not start {argv[0]}: {detail}"

    try:
        output = child.communicate(timeout=deadline_seconds)[0] or ""
    except subprocess.TimeoutExpired:
        _terminate_group(child)
        output = ""
        try:
            output = child.communicate(timeout=KILL_DRAIN_SECONDS)[0] or ""
        except (subprocess.TimeoutExpired, ValueError, OSError):
            pass
        return OUTCOME_WATCHDOG, None, time.monotonic() - started, output

    status = launcher.exit_status(child.returncode)
    return (OUTCOME_PASS if status == 0 else OUTCOME_FAIL), status, time.monotonic() - started, output


def _terminate_group(child) -> None:
    """SIGTERM then SIGKILL the child's whole process group.

    The group, not the child: a fixture that backgrounded a helper would otherwise
    leave it running and holding the lane's pipes open, so the job would sit at its
    15-minute ceiling with the supervisor already finished.
    """
    try:
        pgid = os.getpgid(child.pid)
    except OSError as exc:
        print(f"run-bash32-fixtures: could not resolve the process group of pid {child.pid} "
              f"({exc}) — the expired fixture's group may still be running", file=sys.stderr)
        return
    try:
        os.killpg(pgid, signal.SIGTERM)
    except OSError as exc:
        print(f"run-bash32-fixtures: could not SIGTERM process group {pgid} ({exc}) — "
              "the expired fixture's group may still be running", file=sys.stderr)
        return
    deadline = time.monotonic() + KILL_GRACE_SECONDS
    while time.monotonic() < deadline and child.poll() is None:
        time.sleep(0.05)
    if child.poll() is not None:
        return
    try:
        os.killpg(pgid, signal.SIGKILL)
    except OSError as exc:
        print(f"run-bash32-fixtures: could not SIGKILL process group {pgid} ({exc}) — "
              "it may still be running", file=sys.stderr)


def assert_interpreter(bash: str, launcher) -> tuple[bool, str]:
    """Return `(is_bash_32, reported_version)` for the named interpreter."""
    outcome, _status, _duration, output = run_supervised(
        [bash, "-c", 'printf "%s|%s|%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}" "${BASH_VERSION}"'],
        PROBE_DEADLINE_SECONDS, launcher,
    )
    if outcome != OUTCOME_PASS:
        return False, f"the interpreter could not be probed ({outcome})"
    parts = (output or "").strip().split("|")
    if len(parts) != 3:
        return False, f"unreadable version probe output: {output!r}"
    major, minor, version = parts
    return (major == "3" and minor == "2"), version or f"{major}.{minor}"


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Run the Bash 3.2 fixture corpus under a process-group watchdog.")
    parser.add_argument("--root", default=".", help="repository root")
    parser.add_argument("--manifest", default=None, help="path to the construct-fixture manifest")
    parser.add_argument("--bash", default="/bin/bash", help="the interpreter under test")
    parser.add_argument("--classification", default=None,
                        help="path to the classifier's JSON result; omitted means the complete portable population")
    parser.add_argument("--registry", default=None, help="path to lib/shell-surface-registry.json")
    parser.add_argument("--result-file", default=None, help="also write the JSON result to this path")
    args = parser.parse_args(argv)

    root = Path(args.root).resolve()
    manifest_path = Path(args.manifest) if args.manifest else root / "lib/test/fixtures/bash32/manifest.tsv"
    registry_path = Path(args.registry) if args.registry else root / "lib/shell-surface-registry.json"

    try:
        launcher = _load_signal_launcher(root)
    except (OSError, RuntimeError) as exc:
        print(f"run-bash32-fixtures: {exc}", file=sys.stderr)
        return 2
    try:
        fixtures = read_manifest(manifest_path)
    except (OSError, ValueError) as exc:
        print(f"run-bash32-fixtures: the fixture manifest is unusable: {exc}", file=sys.stderr)
        return 2

    # Resolve the selected surface. An absent --classification means "verify
    # everything", which is the conservative default, never an empty selection.
    selected: list[str]
    established = True
    execution = None
    if args.classification:
        try:
            classification = json.loads(Path(args.classification).read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            print(f"run-bash32-fixtures: the classifier result is unusable: {exc}", file=sys.stderr)
            return 2
        # Validate the contract rather than coercing it. `list(classification["selected"])`
        # would turn the string "pass" into four one-character surfaces, and a missing
        # `established` would default to a value this run then treats as a measurement.
        if not isinstance(classification, dict) or classification.get("schema_version") != CLASSIFIER_SCHEMA_VERSION:
            print("run-bash32-fixtures: the classifier result is not a schema_version "
                  f"{CLASSIFIER_SCHEMA_VERSION} object", file=sys.stderr)
            return 2
        raw_selected = classification.get("selected")
        if not isinstance(raw_selected, list) or not all(isinstance(entry, str) for entry in raw_selected):
            print("run-bash32-fixtures: the classifier result's `selected` is not a list of paths",
                  file=sys.stderr)
            return 2
        selected = raw_selected
        established = classification.get("established") is True
        execution = classification.get("execution")
    else:
        try:
            entries = json.loads(registry_path.read_text(encoding="utf-8"))["entries"]
        except (OSError, ValueError, KeyError, TypeError) as exc:
            print(f"run-bash32-fixtures: the registry is unusable: {exc}", file=sys.stderr)
            return 2
        # Shape-guarded like the other three registry readers, and INSIDE the refusal
        # rather than beside it: a parseable-but-non-mapping `entries`, or a scalar
        # record, would otherwise leave the try/except and surface as a traceback
        # instead of this file's one-line `return 2` diagnostic.
        if not isinstance(entries, dict) or not all(isinstance(r, dict) for r in entries.values()):
            print("run-bash32-fixtures: the registry is unusable: `entries` is not a mapping "
                  "of path to record", file=sys.stderr)
            return 2
        selected = sorted(p for p, r in entries.items() if r.get("state") == "portable")

    result = {
        "schema_version": 1,
        "bash": args.bash,
        "selected_surface_count": len(selected),
        "fixtures": [],
    }

    # A fully-established classification that selected nothing is the ONE state that
    # earns not_applicable. Checked before the interpreter probe so a repository with
    # no macOS-relevant change is not gated on the runner's interpreter identity.
    if not selected:
        if established and execution == EXECUTION_SELECTIVE:
            result.update(domain_result=DOMAIN_NOT_APPLICABLE, bash_version=None,
                          detail="the classifier established the changed-file population and it selected "
                                 "no portable surface")
            _emit(result, args.result_file)
            return 0
        # Every other empty selection is an empty MEASUREMENT, not an empty answer: an
        # unestablished classification, or a conservative decision that somehow selected
        # nothing, would otherwise run the construct fixtures over zero repository
        # surface and report the lane `pass`. Refuse instead of reporting a clean lane
        # over nothing.
        print("run-bash32-fixtures: an empty selection that is not a fully-established selective "
              f"decision (established={established}, execution={execution!r}) — refusing to report a "
              "clean lane over no surface at all", file=sys.stderr)
        return 2

    is_32, version = assert_interpreter(args.bash, launcher)
    result["bash_version"] = version
    if not is_32:
        result.update(domain_result=DOMAIN_FAIL,
                      detail=f"{args.bash} is not stock Bash 3.2 (reported {version}); no fixture was run, "
                             "because a corpus green under another interpreter verifies nothing")
        _emit(result, args.result_file)
        return 1

    failed = False
    for fixture_id, script, construct, deadline in fixtures:
        path = manifest_path.parent / script
        outcome, status, duration, output = run_supervised(
            [args.bash, str(path)], deadline, launcher, env={**os.environ, "BASH": args.bash},
        )
        result["fixtures"].append({
            "id": fixture_id, "construct": construct, "outcome": outcome,
            "status": status, "duration_ms": int(duration * 1000),
        })
        print(f"{fixture_id} {outcome} {int(duration * 1000)}ms")
        if outcome != OUTCOME_PASS:
            failed = True
            sys.stderr.write(_diagnostic(output))

    # Unconditional: every empty selection already returned above, either as the one
    # established not_applicable or as a refusal. Re-testing `selected` here would read
    # as if a lane could reach this point with nothing to parse.
    if not selected:
        # Not reachable by reasoning, and refused rather than skipped anyway: silently
        # omitting the per-surface parse would report a lane that verified no surface.
        print("run-bash32-fixtures: reached the per-surface parse with an empty selection",
              file=sys.stderr)
        return 2
    parse_fixture = manifest_path.parent / "parse-under-bash32.sh"
    outcome, status, duration, output = run_supervised(
        [args.bash, str(parse_fixture), *[str(root / p) for p in selected]],
        SURFACE_PARSE_DEADLINE_SECONDS, launcher, env={**os.environ, "BASH": args.bash},
    )
    result["fixtures"].append({
        "id": "portable-surface-parse", "construct": f"{len(selected)} selected surface(s) parse",
        "outcome": outcome, "status": status, "duration_ms": int(duration * 1000),
    })
    print(f"portable-surface-parse {outcome} {int(duration * 1000)}ms")
    if outcome != OUTCOME_PASS:
        failed = True
        sys.stderr.write(_diagnostic(output))

    result["domain_result"] = DOMAIN_FAIL if failed else DOMAIN_PASS
    _emit(result, args.result_file)
    return 1 if failed else 0


def _diagnostic(output) -> str:
    """The failing fixture's own output, or an explicit statement that it was lost.

    A blank line here reads as "the fixture said nothing", which is what a reader
    debugging a watchdog expiry would then believe; a killed group whose pipes never
    drained said plenty and this process could not hear it.
    """
    text = (output or "").rstrip()
    if text:
        return text + "\n"
    return ("(no output was captured — a killed process group that does not drain within "
            "KILL_DRAIN_SECONDS loses whatever the fixture had written)\n")


def _emit(result, result_file) -> None:
    """Print the domain result and, when asked, persist it.

    The persisted file leads with the same `DOMAIN_RESULT: <token>` line the console
    gets, because `lib/test/gate-portability-result.sh` reads that line with shell
    builtins — no `grep`/`jq`, neither of which the lane can assume on a stock macOS
    runner, and either of which would leave the gate reading an empty value as an
    unestablished lane rather than as the tooling gap it is. The JSON follows for a
    human and for any later consumer; the workflow appends the native Actions
    conclusion as its own line, which the gate ignores and a reader does not.
    """
    line = f"DOMAIN_RESULT: {result['domain_result']}"
    print(line)
    if result_file:
        Path(result_file).write_text(line + "\n" + json.dumps(result, sort_keys=True) + "\n",
                                     encoding="utf-8")


if __name__ == "__main__":
    sys.exit(main())
