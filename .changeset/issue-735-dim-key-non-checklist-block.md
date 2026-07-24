---
bump: patch
type: Fixed
---

- **Reject a `<!-- dim-key: … -->` dimension declaration authored outside the checklist
  block in the create-issue audit-prompt template.** `render-audit-prompt.py` stripped the
  declaration marker from every rendered block but validated declarations only in the
  checklist block, so a declaration in a `file`/`embed`/`inline`/`di` block was silently
  stripped from the auditor-facing prose and never enumerated while its bullet still
  rendered as a keyless, dimension-shaped instruction. It now fails closed on every render
  and enumeration path with a breadcrumb naming the block that carries the stray
  declaration. (#735)
