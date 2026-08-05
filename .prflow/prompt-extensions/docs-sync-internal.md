# PRFlow Documentation Boundary

The internal documentation root (`docs/internal/`) and the published public site (`docs/external/`) are **sibling** directories; neither contains the other. Internal documentation synchronization operates within `docs/internal/` and does not touch `docs/external/`, which is customer-facing output owned by `docs-sync-external`. The split is now structural — the internal root does not enclose the public site — so this exclusion holds by layout rather than by a carve-out (issue #1188 moved the internal tree from `docs/` to `docs/internal/`).

This is runtime policy for the prompt-driven documentation skill, not passive commentary. It is intentionally not mirrored by wording-only test pins.

When the branch changes user-visible behavior, record the public-doc impact in the status summary so the external synchronization step can update it separately in the same implementation run.
