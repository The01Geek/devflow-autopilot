---
bump: patch
---

Add the declarative lint manifest (`.prflow/lint-manifest.json`) and its strict
reader/validator (`scripts/lint_manifest.py`) — the foundation of issue #1276's
deterministic lint provisioning. The manifest is versioned and declarative
(exact ShellCheck/Ruff versions, per-platform artifact digests, selectors,
exclusions, closed special-invocation IDs, timeout bounds, full-profile IDs) and
carries no executable behavior. The validator follows the six-shape reader
matrix: every degraded input resolves to a typed `unestablished` result with a
specific reason, never a plausible `N/A`, and declarative purity is enforced so
shell strings, package-manager snippets, executable paths, URL templates, and
environment expansion are all rejected. The committed manifest is re-included in
`.gitignore` so it ships and stays tracked. (PR #1386)
