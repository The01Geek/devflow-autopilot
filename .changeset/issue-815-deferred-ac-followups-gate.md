---
bump: patch
type: Changed
---

- **`/devflow:implement` Phase 4.0 now loads its follow-up-issue procedure only when a run
  actually deferred acceptance criteria.** The procedure moved to
  `skills/implement/references/deferred-ac-followups.md`, reached through a routing stub that
  first asks a new bounded predicate — `scripts/workpad.py deferred-presence <issue> <pr>` —
  which counts the `kind=deferred` scope-decision records bound to this run's PR that carry no
  filed marker and answers through its exit code plus one count line. A run that deferred
  nothing no longer carries the ~23 KB procedure it cannot execute, and the phase file drops
  from 116,623 to 96,269 bytes. An unestablished answer (records still reading `pr=pending`,
  bound to a superseded PR, corrupted, or an unreadable workpad) loads the reference anyway and
  records a `note` reflection naming the operand, so deferred work is never silently stranded;
  a failed reference read degrades with a `dropped-failed` reflection instead of halting the
  phase. (#821)
- **`scripts/workpad.py update` gained `--mark-deferred-filed`,** which writes a durable
  `<!-- devflow:deferred-filed … -->` record when Phase 4.0 files a follow-up, so a second
  Phase 4 entry files no duplicate. It is a grammar of its own: the scope-decision regex and
  its kind constant are byte-unchanged, and `workpad.py acs-resolve` still reports a deferred
  criterion as `DEFERRED:` before and after the marker is written. (#821)
