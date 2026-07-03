# DevFlow repo — operative policy for `/devflow:review-and-fix`

This repository is the DevFlow plugin itself: its findings frequently concern the
engine prose in `skills/` and the best-effort shell/`jq`/Python helpers in
`scripts/`/`lib/`. The base skill's gates stand unchanged — this extension **sharpens**
(never supplants) the **fix-delta gate** (Step 0.9) and the **Step 2.6 shadow reviewer
prompts** with two repo-specific fail-open guard classes the issue-#247 dogfooding run
reproduced at runtime. Flag an instance of either shape as at least **Important** (a
silent selection/output change is a correctness defect), and require the fix to verify
the *outcome*, not the precondition.

## Guard-class shape 1 — existence-vs-sourceability (verify the outcome, not the precondition)

A guard that tests a file's **existence** and then treats a later **consumption** of that
file as guaranteed is fail-open: the file can exist yet be unreadable, corrupt, or fail to
parse/source, so the precondition passes while the outcome it stands in for never happens.

- **Flag:** any `[ -f <file> ] && . <file>` (or `[ -f x ] && source x`, `[ -e x ]` gating a
  later read/parse) where the guard's *intent* is "the thing the file provides is now
  available." `[ -f ]` proves the path exists — it proves nothing about whether sourcing
  succeeded or the symbol/function it defines is now callable.
- **Fix (verify the outcome):** assert the *consumed result* directly. For a sourced helper,
  check the function is defined after sourcing — `. <file> 2>/dev/null; type <fn> >/dev/null 2>&1 || { breadcrumb; fail-closed; }` — not that the file exists. For a parsed value, check the
  parse produced a usable value. Fail **closed** with a specific breadcrumb when the outcome
  check fails, never silently continue as if the sibling loaded.
- **#247 reproduction (local instance):** a resolver sibling guarded by `[ -f file ] && . file`
  fails open when the sibling exists but is unreadable or corrupt — the guard reports "present"
  and the run proceeds without the function the sibling was supposed to define. The corrected
  guard verifies `type <fn>` (the outcome) instead of the file's mere existence (the precondition).

## Guard-class shape 2 — tr-dependence (an external PATH tool whose absence silently changes output)

A value (a slug, a branch name, a path segment, a normalized identifier) derived by piping
through an external tool consulted on `PATH` — `tr`, `sed`, `awk`, `paste`, `jq` — degrades
**silently** on a host where that tool is missing or behaves differently: the pipeline still
runs, the value comes out wrong (empty, unnormalized, or truncated), and the wrong value then
selects the wrong directory / writes the wrong file / no-ops a gate, with no error.

- **Flag:** any selection- or output-determining value derived through such a tool where a
  failure of the tool (absent on `PATH`, a BSD/GNU behavioral difference, a locale effect)
  would silently change *which* thing is selected or *what* is emitted, rather than surfacing
  an error. Especially where the derived value keys a filesystem path or a comparison.
- **Fix:** either prove the tool is a hard, preflight-guaranteed prerequisite (and cite it), or
  make the failure observable — check the derived value is non-empty/well-formed before it is
  used to select or emit, and fail closed with a breadcrumb naming the tool if it is not. A
  value that is *only* correct when an un-guaranteed tool is present is an unverified boundary.
- **#247 reproduction (local instance):** a name or path derived through `tr` (e.g. a sanitized
  branch slug built with `tr '/' '-' | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9._-'`) silently
  degrades on a `PATH` without `tr` — the slug comes back empty or unnormalized and the run then
  reads/writes the wrong slug directory, with no error to signal the degraded selection.
