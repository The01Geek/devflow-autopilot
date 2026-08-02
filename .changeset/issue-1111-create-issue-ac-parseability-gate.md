---
bump: patch
type: Added
---

- **`/prflow:create-issue` now gates drafts on the shipped acceptance-criteria parser.** At Step 3.6's pre-dispatch canonical write the skill runs `scripts/parse-acs.py --body-file <draft> --format json` and refuses to present a draft whose `acceptance_criteria` array is empty, rewriting the criterion rows and re-running the gate (bounded at three attempts) before surfacing the failure. This closes a silent failure where a drafted `## Acceptance Criteria` section the parser could not read reached an implementing run as an empty specification, letting the Phase 3.4 gate pass vacuously. The parser-cannot-run arm degrades best-effort and never blocks issue creation. (#1111)
