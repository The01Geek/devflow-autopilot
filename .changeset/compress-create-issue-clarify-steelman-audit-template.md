---
bump: patch
type: Changed
---

- **Editorially compressed three `/prflow:create-issue` reference files.** `references/step-2-clarify.md`,
  `references/step-3-5-steelman.md`, and the documentation preamble of `references/audit-prompt-template.md`
  drop rationale essays, rejected-design records, and motivating-incident archaeology. Every check,
  prohibition, degraded arm, and exact command form the three files mandate survives, and no pinned literal
  was moved, reworded, or reflowed across a newline. (#1368)
- **Reorganized, not merely trimmed — so some prose is newly written rather than deleted.** Step 3.5's
  verification-method paragraph and its omission hunt become labelled clauses and bullet lists, Step 2's
  evidence-bundle passage is split into its own paragraphs, and each of those carries a new lead label or
  connective sentence. Step 3.5's per-sweep reporting duties are consolidated into one lead rule over a
  bullet list, scoped to the sweeps that name a zero arm so that the one which never named one is not given
  a falsifiable-claim duty it cannot discharge. Step 2's evidence-bundle purpose, previously narrated as a
  past incident, is restated as a forward statement of what the sub-pass buys; it repeats obligations that
  file already states elsewhere and widens none of them. (#1368)
- **The audit-prompt template's rendered output is unchanged.** Every edit to
  `references/audit-prompt-template.md` lands in its non-emitted documentation preamble: the bytes from the
  first `<!-- render-block: ... -->` onward are identical to the previous release, so every rendered audit
  prompt (`file` / `embed` / `inline` / `checklist` / `dispatch-instructions`) and the dimension enumeration
  render byte-for-byte as before. Within that preamble the dimension-key paragraph gains one explicit
  authoring instruction — declare a `dim-key` for every checklist bullet you add — restating a rule the
  renderer already enforces fail-closed on both the render and enumeration paths, and its three
  consumer-declaration asymmetries are reordered into a single clause without changing any of them. (#1368)
- **One anti-refactor instruction was dropped.** Step 2 keeps the deliberate divergence between the
  cwd-anchored derivation artifact and the main-root-anchored draft, but no longer spells out the
  accompanying "do not unify them" instruction to a future refactorer. (#1368)
