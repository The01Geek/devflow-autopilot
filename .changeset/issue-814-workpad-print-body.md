---
bump: minor
type: Changed
---

- **`workpad.py update` no longer writes the patched workpad body to stdout by
  default.** The echo cost a caller the whole workpad comment on every call — thousands
  of tokens per phase boundary in a `/devflow:implement` run — and no production caller
  consumed it (the four in-repo test harnesses that did now pass `--print-body`).
  The exit code is now the documented success signal for a clean mutation, and a short
  stderr breadcrumb naming the PATCHed comment id (plus the `Status:` value read back
  from the PATCH response on a `--status` call) keeps a successful call distinguishable
  from one a permission matcher silently refused. The unchanged failure-isolation
  contract still governs a **volatile tick miss**, where the exit code is non-zero
  *and* the call's other mutations did land — so a non-zero exit never means "nothing
  landed"; re-tick only the named row rather than re-sending the whole call. The PATCH
  payload, every exit code, and every existing stderr diagnostic are unchanged, and the
  volatile-tick-miss path still writes the body because the caller must re-resolve a
  checkbox index against it. One stderr line shape is **new** beside the breadcrumb —
  `workpad.py update: WARNING: the PATCH response reads Status …, not the requested …`,
  emitted on an exit-0 call whose `--status` read-back does not match — so a consumer
  that parses `update`'s stderr should expect it.
  **This is behavior-changing for any out-of-tree caller that captures `update`'s
  stdout**: pass the new `--print-body` flag to restore the previous bytes exactly. The
  flag exists from the release this changeset produces onward, so a vendor tree pinned
  to an earlier `devflow_version` rejects it with an argparse error rather than printing
  the old body — pin forward before adding it to a consumer recipe. (#814)
