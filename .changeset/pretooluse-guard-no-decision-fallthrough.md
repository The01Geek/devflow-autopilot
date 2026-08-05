---
bump: patch
type: Fixed
---

- **The PreToolUse shape guard's fall-through was fail-CLOSED, not fail-open — it now
  reports no decision instead of emitting `defer`.** Every classification-path failure in
  `scripts/pretooluse-shape-guard.py` (an unparseable payload, a non-`Bash` tool, an
  unloadable classifier, a clean command matching no deny-set arm, and `main()`'s blanket
  exception handler) emitted `permissionDecision: "defer"`, documented as the guard's
  fail-open majority path. Run
  [`30967680822`](https://github.com/The01Geek/prflow/actions/runs/30967680822)'s
  `defer-probe` arm measured the opposite on the CLI `claude-code-action@v1` installs
  (2.1.222): `DEFER-BLOCKED` — the hook fired and the granted command's side effect was
  absent, so the tool did not execute — corroborated by `STOP-REASON-DEFERRED`. A wired
  guard would therefore have ended the run on the first command it did not recognize. All
  six sites now take the documented true fall-through — exit 0 with an empty stdout, the
  no-decision shape — through a single named `_emit_no_decision()`, and `deny` (measured
  honored, with its `permissionDecisionReason` delivered to the transcript) is the only
  token the guard writes. `scripts/harden-stop-hooks.sh`'s Python stub for a `.py` entry
  target, which printed the same `defer` object as its "benign" no-op, now prints nothing
  and exits 0. The guard's header records the measured `deny`/`defer` verdicts in place of
  its superseded `UNESTABLISHED … permissionDecision VOCABULARY` block — including that
  they were taken on CLI 2.1.222 and that the floating `claude-code-action@v1` tag can
  expire them — and its consecutive-hook-block-cap rationale is rewritten: a no-decision is
  not a hook block, so the bound on blocking now holds without depending on such a cap
  existing. Registration remains unwired; this change only makes the guard correct if and
  when it is wired.
