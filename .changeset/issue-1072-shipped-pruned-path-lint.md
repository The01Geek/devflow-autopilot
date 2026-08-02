---
bump: patch
type: Fixed
---

- **Stop shipping prompt instructions that name paths the vendor slice prunes.** The
  implement-phase and review-engine prompts told a consumer's agent to run files under
  `lib/test/`, and named this project's own declaration markers and desk-time pins — a subtree
  `.github/actions/vendor-plugin/vendor-slice.sh` deletes before the plugin reaches a consumer,
  so the paths resolved against a tree where they do not exist. Those sentences are reworded to
  name the project's own test/lint/relocation commands generically (the concrete repo-specific
  command names moved into the non-shipped `implement`/`review`/`review-and-fix` prompt
  extensions), and a new desk-time lint (`lib/test/lint-shipped-pruned-path.py`) derives the
  pruned-path set from the vendor slice itself and fails the suite if any `skills/**` or
  `agents/**` file references a pruned path without a `pruned-path-ok` declaration marker. (#1072)
