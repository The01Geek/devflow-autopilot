---
bump: patch
type: Changed
---

- **`/devflow:implement` §3.1 now resolves the existing-PR question through a tested helper, and validates the PR it adopts.** The three-arm resolution (refuse / adopt / create) moved out of inline skill shell into `scripts/resolve-existing-pr.sh`, which prints exactly one token — `ADOPT <n> OK`, `ADOPT <n> WARN:<checks>`, `CREATE`, or `REFUSED` — with a matching exit code, so the test suite drives every arm and its arm-order over the full input matrix (a `gh` failure, an empty listing, one PR, two PRs on one head, an empty branch name) rather than grep-pinning a message literal. The resolver also fetches `baseRefName` and `closingIssuesReferences` and names each validation that did not hold, so a resumed run that adopts an unrelated PR merely sharing its head branch records a durable warning instead of silently binding its workpad link, provenance label, description and publish step to the wrong PR. (#782, PR #787)
