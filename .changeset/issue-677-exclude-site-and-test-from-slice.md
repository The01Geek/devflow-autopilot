---
bump: patch
type: Changed
---

- **Exclude the published-site HTML and DevFlow's own test suite from the vendored plugin slice.** `devflow_copy_slice` now prunes `docs/site` and `lib/test` from the staged tree — after the `cp -R` and before the sanity floor — so a consumer that materializes the cloud tier no longer downloads or stores roughly eleven megabytes of artifacts no run of theirs reaches (a published web page and tests that assert against DevFlow's own sources). The rest of `docs/` still ships, because shipped skill bodies link into it, and the suite now asserts both exclusions and the surviving required members so the copy list cannot silently reintroduce either subtree. (#677)
