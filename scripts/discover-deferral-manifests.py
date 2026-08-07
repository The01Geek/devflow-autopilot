#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""DevFlow deferrals-manifest discovery for /implement Phase 4.0.5.

Phase 4.0.5 of `/devflow:implement` files follow-up GitHub issues for review
findings deferred during the Phase 3.3 fix loop. Its first step discovers the
run-scoped deferrals manifests written by /devflow:review-and-fix at
`.prflow/tmp/review/<slug>/<run-id>/deferrals.json` (one per run). The old
inline `find $SEARCH_DIRS … | sort` capture collapsed a *failed* search and a
*clean no-match* search onto the same empty output — a degraded search then read
as the clean no-op and acknowledged deferrals were silently stranded (issue #555,
observed live in #533). This helper searches each candidate root INDEPENDENTLY,
classifies each root's outcome, and preserves discovery status through the exit
code so output production can never mask a failed search.

Each supplied root is classified into exactly one of three outcomes:
    ok      searched cleanly (zero matches allowed)
    absent  the root path does not exist (benign — contributes nothing)
    failed  the root exists but could not be fully traversed (an OSError at the
            root OR anywhere the walk actually visits — a non-directory root, a
            permission or I/O error, an unreadable subtree at depth <= 2). The
            walk is pruned below depth 2 (nothing deeper can match), so a
            subtree at depth >= 3 is never visited and cannot classify a root
            `failed`; that is out of the matching contract's reach by
            construction, not a swallowed error. This does NOT rely on os.walk's
            default error-swallowing (`onerror=None` silently skips an unreadable
            subtree and would classify the root `ok` with the manifest inside it
            missing — the exact silent-loss shape this helper exists to remove,
            re-created one level down). We pass a raising `onerror`.

stdout: the de-duplicated, lexicographically sorted list of matching manifest
paths, one per line, in POSIX separator form (forward slashes) so the list is
stable across native-Windows python3 hosts (#275's documented host shape).
A match is a file named `deferrals.json`, size > 0 bytes, located EXACTLY two
directory levels below a supplied root (`<root>/<run-id>/deferrals.json`) —
mirroring the retired `find -mindepth 2 -maxdepth 2 -name deferrals.json -size +0c`
(narrowed: this helper matches regular files only, where the retired `find` had no
`-type f` and would have matched a directory named `deferrals.json`).

stderr carries a roots-echo line naming every root's absolute path (os.path.abspath
— normalized, NOT symlink-resolved) and classification on every *discovery* run,
i.e. whenever at least one root argument was supplied, so an `absent` root is
observable rather than silent. The zero-argument usage error (exit 2) returns
before any root is classified and therefore emits only the usage message.
Failed roots additionally emit a per-root breadcrumb, and a discovery run emits
at most one aggregate discrimination marker the fence greps.

Exit codes (discovery mode):
    0  no root classified `failed` (all ok/absent, including zero total matches)
    2  invoked with zero root arguments (usage message; NO discovery marker)
    3  partial — at least one `failed` AND at least one `ok`/`absent`
       (discovered paths are still printed); stderr carries `devflow: discovery partial:`
    4  every root classified `failed` (empty stdout); stderr carries `devflow: discovery failed:`
An uncaught exception exits non-zero (interpreter default), which the fence's
else-arm treats as failed — ambiguous failures fail closed.

PRESENCE MODE (issue #1374). `--presence-for-pr N` answers a different question:
is any deferred review finding present for PR N? Phase 4.0.5's filing procedure now
lives in a gated reference the phase file reads only when this predicate says so, and
this mode is that predicate. It derives BOTH candidate search directories itself —
including the branch slug, in Python rather than through the fence's `tr` chain, so a
host without `tr` resolves the same directories as a host with it — and answers over
BOTH presence sources: the run-scoped manifests (which a re-entry after filing has
already consumed) and the slug-level aggregate (which has no producer on a first
entry). Reading either alone fails open.

Exit codes (presence mode) — three states, complete by construction:
    0  present       stdout `present: <n>`
    1  absent        stdout `absent: 0`
    2  unestablished stdout `unestablished: reason=<token>` (+ an optional `root:` line)
Discovery mode's `3` and `4` are unreachable here: an unreadable candidate collapses
into `2` regardless of how many others were readable. That flattening is deliberate,
so both gated Phase 4 sub-steps document one identical three-state contract; the cost
is that presence mode cannot tell a partial failure from a total one. A malformed
invocation reports `2` as well — the same fail-closed convention `workpad.py
deferred-presence` adopts, so a bad call loads the reference rather than silently
skipping it. Every state is decided from the exit status alone; no caller parses stdout
to route.

Usage:
    discover-deferral-manifests.py ROOT [ROOT ...]
    discover-deferral-manifests.py --presence-for-pr N
"""

import os
import subprocess
import sys

MANIFEST_NAME = "deferrals.json"

# The presence-mode dispatch token. It is recognized ONLY as argv[0], so a root path
# in any later position stays a root path: the filing fence passes `$SEARCH_DIRS`
# unquoted for word-splitting, and a positional-anywhere flag would let a root that
# happened to match it switch modes mid-list.
PRESENCE_FLAG = "--presence-for-pr"

# The review scratch root, cwd-relative — the identical literal the §4.0.5 filing
# fence composes SLUG_DIR and BRANCH_DIR from. Anchoring this to the git toplevel
# instead would search directories the fence never writes to.
REVIEW_ROOT = ".prflow/tmp/review"

# The character set the fence's `tr -cd 'a-z0-9._-'` keeps, spelled out so the port
# and the shell chain cannot drift through an interpretation of a range expression.
_SLUG_KEEP = frozenset("abcdefghijklmnopqrstuvwxyz0123456789._-")

# Aggregate discrimination markers the §4.0.5 fence greps. At most one is emitted
# per run (the partial/all-failed arms are exclusive branches), and the per-root
# failed breadcrumb below is deliberately worded so its own fixed text contains
# NEITHER contiguous substring — the fence's `grep -q 'devflow: discovery partial:'`
# discrimination is only sound under that exclusivity. NOTE the residual: the
# per-root breadcrumb interpolates the root path and the OSError text, so a CALLER
# that passes a root path literally containing a marker substring can defeat the
# exclusivity. The §4.0.5 fence cannot: both its roots are path-safe components
# (`pr-<N>` and an `[a-z0-9._-]`-sanitized branch slug), which admit neither `:`
# nor a space. This helper does not sanitize argv, so the guarantee is the fence's
# input discipline plus the fixed wording — not an unconditional property of the
# helper for an arbitrary caller.
MARKER_PARTIAL = "devflow: discovery partial:"
MARKER_FAILED = "devflow: discovery failed:"


def _force_utf8_streams():
    """Force stdout/stderr to UTF-8, idempotently and defensively. Called from
    the CLI entry path only (not at import) so importing this module for unit
    tests never mutates the importer's global streams. The guard tolerates a
    stream replaced with a non-`TextIOWrapper` (e.g. a test's `io.StringIO`),
    which has no `reconfigure` (issue #222)."""
    for _stream in (sys.stdout, sys.stderr):
        try:
            _stream.reconfigure(encoding="utf-8")
        except (AttributeError, ValueError):
            pass


def _raise(err):
    # os.walk's onerror: re-raise so an unreadable subtree surfaces as a `failed`
    # classification instead of being silently skipped (the #555 silent-loss shape).
    raise err


def _posix(path):
    """Render a filesystem path in POSIX separator form.

    Extracted so the suite can drive it directly: on a POSIX host `os.sep` is
    already "/", so exercising this through the walk is an identity and any
    assertion over it passes for the wrong reason. The contract exists for the
    native-Windows python3 host (#275), so the only non-vacuous test is one that
    drives the separator — which needs this as a callable, not an inline expression.
    """
    return path.replace(os.sep, "/")


def _depth_below(root, dirpath):
    # Number of path segments `dirpath` lies below `root`. The root itself is 0.
    rel = os.path.relpath(dirpath, root)
    if rel == os.curdir:
        return 0
    return rel.count(os.sep) + 1


def classify_root(root):
    """Classify one candidate root. Returns (status, matches) where status is
    one of 'ok' / 'absent' / 'failed' and matches is a list of POSIX-form paths
    to non-empty deferrals.json files exactly two levels below the root."""
    if not os.path.exists(root):
        return "absent", []
    # A non-directory root (a regular file supplied where a directory was
    # expected — the deterministic ENOTDIR shape) is a traversal failure, not an
    # empty `ok`: os.walk over a regular file yields nothing silently, which would
    # misclassify it `ok`. Catch it explicitly.
    if not os.path.isdir(root):
        # EVERY `failed` classification breadcrumbs the root and the reason — this arm
        # raises no OSError, so without its own write it would be the one failure the
        # operator cannot attribute to a root.
        sys.stderr.write(
            "devflow: discovery: root %s failed traversal (not a directory)\n"
            % os.path.abspath(root)
        )
        return "failed", []
    matches = []
    try:
        for dirpath, dirnames, filenames in os.walk(root, onerror=_raise):
            # Files exactly two levels below root live in directories exactly one
            # level below root (`<root>/<run-id>/`). Prune deeper descent for speed
            # and to keep the depth-2 contract exact.
            depth = _depth_below(root, dirpath)
            if depth >= 2:
                dirnames[:] = []
                continue
            if depth != 1:
                continue
            if MANIFEST_NAME in filenames:
                candidate = os.path.join(dirpath, MANIFEST_NAME)
                # getsize can itself raise OSError (a file vanishing mid-walk) —
                # that is a traversal failure of this root, handled by the except.
                if os.path.getsize(candidate) > 0:
                    matches.append(_posix(candidate))
    except OSError as exc:
        sys.stderr.write(
            "devflow: discovery: root %s failed traversal (%s)\n"
            % (os.path.abspath(root), exc)
        )
        return "failed", []
    return "ok", matches


def _derive_branch_slug(branch):
    """Port the §4.0.5 fence's `tr '/' '-' | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9._-'`
    chain into Python, so this mode's search directories do not depend on `tr` — a tool
    the project's preflight does not guarantee, whose absence would empty the slug and
    silently drop the branch-slug candidate (guard-class 2).

    The case fold is an explicit ASCII A–Z shift rather than str.lower(), which is
    Unicode-aware and would map characters `tr` leaves alone in the C locale — after
    which the keep-filter drops them either way, so the two agree on the result but not
    on the reasoning; the explicit shift is what makes the agreement true by construction
    rather than by coincidence.
    """
    out = []
    for ch in branch.replace("/", "-"):
        if "A" <= ch <= "Z":
            ch = chr(ord(ch) + 32)
        if ch in _SLUG_KEEP:
            out.append(ch)
    return "".join(out)


def _slug_escapes_review_root(review_root, slug):
    """True when joining `slug` onto `review_root` resolves outside it.

    The keep-filter above passes `.` and `-`, so a branch named `..` slugs to `..` and
    would point the branch candidate at the review root's parent. Discovery there would
    walk an unrelated tree and could report a manifest that belongs to no run of this PR.

    `scripts/issue-audit-state.py` guards the same hazard for its own slugs with a
    `[A-Za-z0-9][A-Za-z0-9._-]*` full-match; the two are separate stdlib-only CLIs with no
    shared module, so this is a sibling to find when hardening, not a call to make.
    """
    base = os.path.normpath(review_root)
    candidate = os.path.normpath(os.path.join(base, slug))
    return not candidate.startswith(base + os.sep)


def _resolve_current_branch():
    """The checked-out branch name, or "" when it cannot be resolved.

    Every failure — a non-zero git, a detached HEAD, no repository, git absent, a hung
    call — collapses onto the empty string, which is the fence's own benign
    detached-HEAD case: search the PR slug alone. This is deliberately NOT an
    unestablished state; a branch that cannot be named contributes no second candidate,
    and the PR slug is the one the aggregate lives under regardless.
    """
    try:
        proc = subprocess.run(
            ["git", "branch", "--show-current"],
            capture_output=True, text=True, timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    if proc.returncode != 0:
        return ""
    return proc.stdout.strip()


def _print_presence_unestablished(reason, root=None):
    """The single owner of presence mode's `unestablished` line's format.

    Every fail-closed exit routes through here, mirroring `workpad.py`'s
    `_print_unestablished`, so the token the phase-file stub quotes back into its
    reflection cannot drift between call sites. Returns the exit code rather than
    exiting, so `main` keeps one return path and the suite can drive it in-process.
    """
    sys.stdout.write("unestablished: reason=%s\n" % reason)
    if root is not None:
        sys.stdout.write("root: %s\n" % os.path.abspath(root))
    return 2


def cmd_presence(rest):
    """Answer whether a deferred review finding is present for the PR named in `rest`."""
    # Arity and type first, before any filesystem or git work: a malformed call must
    # not be able to produce a partial roots-echo that reads like a real search.
    if len(rest) != 1 or not rest[0].isdigit():
        sys.stderr.write(
            "devflow: presence: usage: discover-deferral-manifests.py %s N\n"
            % PRESENCE_FLAG
        )
        return _print_presence_unestablished("malformed-invocation")
    pr_number = rest[0]

    slug_dir = "%s/pr-%s" % (REVIEW_ROOT, pr_number)
    candidates = [slug_dir]
    # Skip the branch derivation entirely when the review root does not exist. Every
    # candidate under a missing root classifies `absent` and the aggregate cannot exist
    # either, so the answer is the same — and this is the common case on the path the
    # predicate exists to make cheap, where the git subprocess would be pure overhead.
    branch_slug = ""
    if os.path.isdir(REVIEW_ROOT):
        branch_slug = _derive_branch_slug(_resolve_current_branch())
    if branch_slug:
        if _slug_escapes_review_root(REVIEW_ROOT, branch_slug):
            sys.stderr.write(
                "devflow: presence: branch slug %r would resolve outside %s — dropping "
                "the branch candidate; searching the pr-%s slug alone\n"
                % (branch_slug, os.path.abspath(REVIEW_ROOT), pr_number)
            )
        else:
            branch_dir = "%s/%s" % (REVIEW_ROOT, branch_slug)
            if branch_dir != slug_dir:
                candidates.append(branch_dir)

    # Reuse the discovery mode's own traversal, so the depth-2 and non-zero-size rules
    # this predicate answers on are the same rules the filing fence then files from.
    results = []
    present = 0
    for root in candidates:
        status, matches = classify_root(root)
        results.append((root, status))
        present += len(matches)

    # The slug-level aggregate is a single file one level above the run-scoped
    # manifests, so the walk above never sees it. It is checked independently because
    # it is the ONLY surviving source once a prior entry has filed and consumed the
    # run-scoped manifests.
    agg_path = "%s/%s" % (slug_dir, MANIFEST_NAME)
    # Three values only, one per routing branch below. A zero-byte aggregate classifies
    # `absent` rather than taking a fourth value no branch reads — the discovery mode
    # matches only files of non-zero size, so an empty aggregate holds nothing either, and
    # a value the routing never inspects is a case a reader has to prove is not silently
    # dropped. The size fact stays visible in the breadcrumb below.
    agg_state = "absent"
    if os.path.exists(agg_path):
        if not os.path.isfile(agg_path):
            agg_state = "failed"
        else:
            try:
                agg_state = "ok" if os.path.getsize(agg_path) > 0 else "absent"
            except OSError as exc:
                sys.stderr.write(
                    "devflow: presence: aggregate %s could not be sized (%s)\n"
                    % (os.path.abspath(agg_path), exc)
                )
                agg_state = "failed"

    sys.stderr.write(
        "devflow: presence roots: %s aggregate %s=%s\n"
        % (" ".join("%s=%s" % (os.path.abspath(r), s) for r, s in results),
           os.path.abspath(agg_path), agg_state)
    )

    # Present wins over an unreadable sibling: a finding this mode positively saw is
    # not made less present by a directory it could not read, and both answers route
    # the caller to the same place.
    if present or agg_state == "ok":
        sys.stdout.write("present: %d\n" % present)
        return 0
    if agg_state == "failed":
        return _print_presence_unestablished("unreadable-aggregate", agg_path)
    first_failed = next((r for r, s in results if s == "failed"), None)
    if first_failed is not None:
        return _print_presence_unestablished("unreadable-directory", first_failed)
    sys.stdout.write("absent: 0\n")
    return 1


def main(argv=None):
    _force_utf8_streams()
    args = list(sys.argv[1:] if argv is None else argv)
    if args and args[0] == PRESENCE_FLAG:
        return cmd_presence(args[1:])
    if not args:
        # NO discovery marker here — a usage error is not a discovery outcome, so
        # it must not be mistaken for a PARTIAL one. Emitting neither marker is
        # what routes it to the fence's else arm (`DISCOVERY_STATE=failed`), the
        # fail-closed direction: nothing is filed. The fence's else-arm reflection
        # names the two shapes it expects (all roots failed / a harness denial),
        # so a usage error — which the fence itself cannot produce, since it always
        # passes $SEARCH_DIRS — would be recorded under a diagnosis one word wider
        # than the truth. That is the accepted cost of a single fail-closed arm;
        # do NOT add a marker here to sharpen it, because any marker this arm
        # emitted would have to be discriminated from a real discovery outcome.
        sys.stderr.write(
            "devflow: discovery: usage: discover-deferral-manifests.py ROOT [ROOT ...]\n"
        )
        return 2

    results = []          # (root, status)
    all_matches = set()
    for root in args:
        status, matches = classify_root(root)
        results.append((root, status))
        all_matches.update(matches)

    # Roots-echo: name every root's ABSOLUTE path (os.path.abspath — normalized,
    # NOT symlink-resolved) and classification on every run that reaches here, so
    # an `absent`-classified root is observable in the fence's tool result (the
    # fence surfaces this line unconditionally) rather than silent. The zero-arg
    # usage error returns above, before any root exists to echo.
    echo = " ".join(
        "%s=%s" % (os.path.abspath(root), status) for root, status in results
    )
    sys.stderr.write("devflow: discovery roots: %s\n" % echo)

    # stdout: sorted, de-duplicated, POSIX-form. Printed even on a partial run —
    # output production must NOT be able to alter the exit status below.
    for path in sorted(all_matches):
        sys.stdout.write(path + "\n")

    failed = sum(1 for _, s in results if s == "failed")
    total = len(results)
    if failed == 0:
        return 0
    if failed == total:
        sys.stderr.write(
            "%s all %d candidate root(s) failed traversal.\n" % (MARKER_FAILED, total)
        )
        return 4
    sys.stderr.write(
        "%s %d of %d candidate root(s) failed traversal; discovered manifests printed "
        "from the rest.\n" % (MARKER_PARTIAL, failed, total)
    )
    return 3


if __name__ == "__main__":
    sys.exit(main())
