---
bump: patch
type: Fixed
---

- **Armed the inert guards and mechanized the unenforced verification policy shipped by #707.**
  The retired-convention sweep's ninth arm was re-spanned to a literal that actually exists on a
  single baseline line, and its self-referential planting control was replaced by a
  baseline-corpus control that validates every literal against the pre-#707 baseline blobs read
  through `git show` (with a planted-defect positive control and four fail-closed degraded-input
  arms). The `harness-python-guards` focused module is now driven through its own runner by a
  `runs_green_through_the_real_runner` test, and `CONTRIBUTING.md`'s module-authoring checklist
  requires that test going forward. The parallelized final gate now produces an inspectable
  artifact: the local/interactive tier captures its full-suite launch to a named file and records
  a `Verification evidence:` marker in the workpad, so a refused launch is observable rather than
  invisible (runtime enforcement deferred to #730). The undefined `or path` disjunct was deleted
  from every operative policy surface, and the `#528`/`#556`/`#668` guards and their comments were
  corrected. (#719)
