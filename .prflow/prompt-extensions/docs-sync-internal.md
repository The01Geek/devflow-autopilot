# PRFlow Documentation Boundary

The configured internal root contains a nested public site. Do not inspect or edit `docs/external/**` during internal documentation synchronization. Treat that subtree as customer-facing output owned by `docs-sync-external`.

This is runtime policy for the prompt-driven documentation skill, not passive commentary. It is intentionally not mirrored by wording-only test pins. Revisit the boundary only if the documentation runtime gains a deterministic post-edit path hook; at that point, enforce the exclusion through that hook rather than by pinning these sentences.

When the branch changes user-visible behavior, record the public-doc impact in the status summary so the external synchronization step can update it separately in the same implementation run.
