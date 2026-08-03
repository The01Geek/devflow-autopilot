# PRFlow Documentation Boundary

The configured internal root contains a nested public site. Do not inspect or edit `docs/external/**` during internal documentation synchronization. Treat that subtree as customer-facing output owned by `docs-sync-external`.

When the branch changes user-visible behavior, record the public-doc impact in the status summary so the external synchronization step can update it separately in the same implementation run.
