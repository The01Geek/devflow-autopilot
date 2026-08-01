---
bump: patch
type: Fixed
---

- **Close three test-coverage gaps and a docstring nit left by the terminal-status widening.** Exercise the `implement-stop-guard.sh` legacy `terminal` alias arm with a fixture emitting the un-upgraded token (proving the arm load-bearing); assert the `failed -> fail-blocked` stall-backstop arm never invokes `gh`, matching its `blocked` sibling; add a behavioral negative assertion that no recognized status classifies as the bare legacy `terminal` token; and disambiguate the `cmd_status` docstring clause in `scripts/workpad.py`. (#1056)
