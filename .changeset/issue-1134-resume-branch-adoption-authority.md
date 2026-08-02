---
bump: patch
---

Base implement resume branch adoption on observable pull-request state, not the workpad-derived resume kind (#1134).

Phase 1.3 derives its durable `resume-kind:` marker from workpad content alone,
so a resume whose prior attempt's workpad writes were silently denied classifies
itself `fresh` — and one such backstop resume started a second branch while the
first attempt's branch and an open pull request closing the issue were both on
the remote. §1.4's resume pre-check reads exactly that observable state and
exists to stop "opening a second branch and a second PR while silently
abandoning the committed work", but nothing said which of the two surfaces
governs, so the seam between them was where the duplicate branch came through.

The authority split is now stated where each half is read. **§1.4's resume
pre-check is the sole authority on branch adoption**: it runs on every §1.4
entry — fresh run, resume, and terminal re-trigger alike — no value of the
`resume-kind:` marker waives it, and branch creation is reachable only through a
recorded pre-check outcome. **Phase 1.3's marker classifies the workpad, not the
repository**, and feeds only the Phase 2 §2.0 resume-idempotency gate; `fresh`
means *this workpad carries no record of a prior attempt*, never *no prior
attempt exists*.

The observable state is deliberately **not** promoted into that classification,
and the `resume-kind:` vocabulary stays the same closed three-token set compared
by exact value. A terminal re-trigger over a completed run routinely still has an
open pull request closing the issue; relabeling that population as an in-flight
resume would arm §2.0's first conjunct over the prior run's stale all-ticked
Plan — the failure that conjunct exists to prevent. So a run whose pre-check
adopted a branch under a `fresh` marker does not fire the gate: it re-runs full
discovery over the adopted branch, the safe direction, and its workpad recorded
no Plan either. §2.0's reader is reconciled with that statement in the same
change.

Every arm of the pre-check — adopted, queried-cleanly-none-found, and
unresolvable — now writes one durable `resume-precheck: ` workpad note naming
the observable state it consulted: the `**Branch:**` value, whether each of the
two open-pull-request queries ran, and what was selected. A maintainer can tell
an adoption from a first attempt from the workpad alone, and Phase 3.1's
resume-aware refusal arm reads that note rather than relying on context that
compaction can drop. Nothing parses the note and no step routes on its text; the
pre-check's arms still route on the same `PR_JSON` / `HEAD_REF` / `LANDED`
operands as before.

The pre-check's adoption operand remains an **open pull request** for the issue,
never the bare existence of a branch named for it — stated explicitly so later
work that changes when an implement run's branch first carries commits can be
sequenced against this pre-check rather than assuming its behavior.
