---
bump: patch
type: Changed
---

- **Exclude the published-site HTML and DevFlow's own test suite from the vendored plugin slice.**
  `devflow_copy_slice` now prunes `docs/site/` and `lib/test/` from the staged tree before the
  sanity floor, so a consumer materializes a substantially smaller plugin (~11M less) without the
  web-page artifacts and suite that no consumer run reaches. The rest of `docs/` still ships, since
  shipped skill bodies link into it. (#677)
