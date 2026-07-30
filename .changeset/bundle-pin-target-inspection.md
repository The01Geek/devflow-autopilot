---
bump: patch
type: Fixed
---

- **The `# structural-pin-ok:` declaration on a pin that targets a runtime-concatenated
  bundle can be edited again.** `lib/test/pin-corpus-lint.py` now resolves a bundle
  variable (`$CI_BUNDLE`, `$MAXI_BUNDLE`) back to the repository files its own builder
  call concatenates, and inspects a typed declaration against that member set: every
  member must be inside the repository and readable, and the literal must be present in
  at least one of them. Before this, such a target resolved to a scratch path no static
  resolution reached, so the gate reported `typed structural declaration target cannot be
  inspected` for any declared pin on it — and because a site is classified whenever its
  lines land in the diff's added set, the whole logical line, declaration text included,
  was permanently uneditable. Eleven retained pins were frozen that way. Membership is
  resolved only through a closed grammar (a builder call, an array built from literal
  words and/or one for-loop over a path glob with an optional basename skip, and
  whole-variable aliases of a resolved bundle); an unresolvable build, an ambiguous name,
  an empty glob expansion and an unreadable member all keep the existing refusal, and a
  literal present in no member is still reported absent. Prose resolution follows the same
  member set, so the routing ladder still requires an authorized ledger row and a tag
  cannot self-grant a bundle pin. Eleven declarations now carry a legal category authored
  from the site's own recorded ledger rationale. (#956)
