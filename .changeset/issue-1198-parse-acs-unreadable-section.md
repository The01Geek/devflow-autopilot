---
bump: patch
type: Fixed
---

- **`parse-acs.py` now distinguishes an unreadable acceptance-criteria section from an absent one.** A `## Acceptance Criteria` section that is present and correctly named but writes its criteria as bold paragraphs or a numbered list parses to zero checkbox items, exactly like a section that does not exist — collapsing "the parser could not read the criteria" onto "this issue has no criteria". `scripts/parse-acs.py` now emits an item-shape stderr diagnostic and sets `acceptance_criteria_unreadable: true` in its `--format json` output for that case, while still exiting 0 (so the implement skill's fail-closed §1.2 fence does not halt the run). The accepted item shape is unchanged. The implement skill's Phase 1.2 routes on that signal: the run continues, the criteria are hand-extracted into the workpad, and a friction (`issue-accuracy`) reflection records the event so it surfaces in the weekly retrospective. The misdirecting near-miss diagnostic (which blamed a heading that already matched) is fixed. (#1198)
