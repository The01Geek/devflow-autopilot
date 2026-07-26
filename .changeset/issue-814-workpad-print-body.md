---
bump: minor
type: Changed
---

- **`workpad.py update` no longer writes the patched workpad body to stdout by
  default.** The echo cost a caller the whole workpad comment on every call — thousands
  of tokens per phase boundary in a `/devflow:implement` run — and nothing consumed it.
  The exit code is now the documented success signal for a clean mutation, and a short
  stderr breadcrumb naming the PATCHed comment id (plus the `Status:` value read back
  from the PATCH response on a `--status` call) keeps a successful call distinguishable
  from one a permission matcher silently refused. The unchanged failure-isolation
  contract still governs a **volatile tick miss**, where the exit code is non-zero
  *and* the call's other mutations did land — so a non-zero exit never means "nothing
  landed"; re-tick only the named row rather than re-sending the whole call. The PATCH
  payload, every exit code, and every existing stderr diagnostic are unchanged, and the
  volatile-tick-miss path still writes the body because the caller must re-resolve a
  checkbox index against it.
  **This is behavior-changing for any out-of-tree caller that captures `update`'s
  stdout**: pass the new `--print-body` flag to restore the previous bytes exactly. The
  flag exists from the release this changeset produces onward, so a vendor tree pinned
  to an earlier `devflow_version` rejects it with an argparse error rather than printing
  the old body — pin forward before adding it to a consumer recipe. (#814)
