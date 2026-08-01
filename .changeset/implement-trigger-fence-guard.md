---
bump: patch
---

Fixed: the heavy `/prflow:implement` trigger now shares the same markdown-aware, fail-closed standalone-command detector the light command path uses, so a comment that merely *quotes* the implement token — in prose, a `>` blockquote, an indented or fenced code block — no longer fires a full implement run. Previously the resolver matched the token with a bare `grep` and fell through to the attached issue's number, so any quoted mention (or a foreign `/xflow:implement` namespace) started a real run. `scripts/resolve-implement-trigger.sh` now routes number resolution through `scripts/detect-standalone-command.sh` (the token was added to its most-specific-first ladder), and `scripts/resolve-command-trigger.sh` re-excludes the implement token defensively so the light command path is unchanged. Fail-closed behavior on an unbalanced fence and the existing authorization and self-trigger guards are preserved.
