---
bump: patch
---

### Changed

- Rewrote the `description` frontmatter of the primary PRFlow skills (`implement`, `review`,
  `review-and-fix`, `create-issue`) and the docs family (`docs`, `docs-sync-internal`,
  `docs-sync-external`, `docs-release-notes`, `docs-verify`, `docs-bootstrap-internal`,
  `docs-bootstrap-external`) so the agent selects them from ordinary natural-language requests
  instead of relying on the user to remember a slash command. Each description leads with
  concrete triggering phrasings in the user's own vocabulary, and the overlapping skills name
  the sibling to use instead.
- `review` and `review-and-fix` now split on an observable predicate rather than an inferred
  one: an unqualified "review my PR" defaults to `review`, and `review-and-fix` requires
  explicit fix intent.
- `docs-sync-internal`, `docs-sync-external` and `docs-release-notes` gained the reciprocal
  "narrower than `prflow:docs`" boundary their siblings already stated, so the parent skill no
  longer silently absorbs their prompts. `docs-release-notes` also picked up the `changeset`
  keyword, which is the mechanism this repo actually uses.
- `create-issue` now also triggers on writing up an implementation plan, reflecting how it is
  commonly used. The wording keys on the work being *tracked rather than built*, and routes
  designing the work itself to a brainstorming or planning skill, so bare planning prompts are
  not poached. That hand-off names a *class* of skill rather than a specific one, because these
  descriptions ship into consumer repositories where no particular planning plugin is
  guaranteed to be installed.
- `docs-verify`'s description now surfaces its `--report-only` mode, in which the skill acts as
  a codebase exploration agent producing a read-only map of how a feature works from the
  internal docs. It requires user-stated docs framing and explicitly cedes undecorated
  "explain / map out / trace how X works" requests to ordinary code exploration.

### Fixed

- `implement`'s description previously stated its trigger as the literal presence of
  `/prflow:implement` in the message, which is false for any natural request such as
  "implement issue #123". It now describes the real triggering condition. Slash-command
  dispatch is unaffected: the cloud tier matches the comment body in the workflow trigger and
  `resolve-implement-trigger.sh`, and both the synthesised cloud prompt and the local command
  resolve by skill name; none of those paths read the description.
- Removed the workflow summary ("runs the full 4-phase lifecycle") from `implement`, per the
  skill-authoring rule that a description states when to use a skill — a workflow summary
  invites agents to follow the description instead of reading the skill body.
