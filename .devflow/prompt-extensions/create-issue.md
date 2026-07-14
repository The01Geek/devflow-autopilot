## Audit dimensions

DevFlow-engine-specific audit dimensions for the Step 3.6 fresh-context auditor. The skill
appends this section verbatim to its generic dimension checklist when dispatching the audit
subagent. Judge the draft against each of these, in addition to the generic dimensions:

- **Cloud-allowlist skew (issue #363).** A skill/phase change that invokes a new shell helper
  must have that helper granted in the relevant `.github/workflows/` `TOOLS=` allowlist(s), or
  the cloud runner *silently* denies it (no verdict, burned budget). Prefer designs that add
  **zero new tool grants**; when a draft claims "no new grants", the auditor confirms nothing
  the change invokes needs one, and flags the no-skew property as an unstated load-bearing
  assumption if the draft leaves it implicit.
- **Non-preflight-PATH-tool selection hazards (guard-class 2).** A value that decides a
  *selection* or an *emitted result* must not be derived through a tool preflight does not
  guarantee (`tr`/`sed`/`wc`/`cut`/`head` — only `git`/`gh`/`jq`/`python3`/PyYAML are
  guaranteed): a missing tool fails *open*, the value comes out empty, and the wrong thing is
  selected with no error. Flag any draft mechanism whose decisive value flows through such a
  tool without a fail-closed check.
- **Coupled mirror sites.** A value or contract sentence that more than one file must carry
  identically (a label literal, a config-key name, a `SKILL.md` pin a `run.sh` grep asserts, a
  self-record) is a coupled site: it must be edited in every mirror in the *same* change.
  Enumerate mirrors with a **whitespace-normalized** search (a phrase wrapped across adjacent
  string literals defeats line-based `git grep`). Flag any draft that touches one half of a
  coupled invariant without naming the other. **A mirror is only as correct as its source:**
  the source form must itself be internally reconciled before it is propagated to its mirror
  sites (the within-text multi-state-contract reconciliation the Step 3.5 hunt performs).
- **Cloud matcher command shapes (issue #401).** Even when every command *head* is granted, the
  cloud review/runner matcher denies composite *shapes* — leading `VAR=value`, leading `cd`,
  `>`/`2>` redirects, heredoc writes, interpreter heads, and an unexpanded
  `"${CLAUDE_SKILL_DIR:-…}"` leading token. Flag any draft whose mechanism depends on a denied
  shape rather than a probe-proven permitted one.
- **Context-compaction and auto-resume premise loss.** A long or resumed run loses turn-one
  context: a mechanism that relies on the agent *remembering* something loaded at the top of a
  skill, or on a background wakeup/notification re-invoking a headless run, silently no-ops.
  Flag any premise that a compaction or a stall-backstop auto-resume would defeat.
- **Shallow-clone safety.** A mechanism that reads git history (ancestor checks, merge-base,
  behind-by counts, `git show <ref>:<path>`) can error or mislead on a shallow clone. Flag any
  draft step whose correctness depends on full history without a fail-closed degraded path.
- **Authoring-discipline defects (DevFlow specifics, issue #462).** Sharpening the generic
  authoring-discipline dimension for this repo: (1) a **value-comparison** AC/assertion ungrounded
  on the type axis — check the cited probe actually exercises the **type-boundary fixture** (a JSON
  string `"true"` vs. a boolean `true`, the exact #446 shape), not merely that the resolver prints
  strings; (2) a Testing-Strategy **case matrix** for a best-effort parser or reader of hand-corruptible
  input that narrows below the **governing matrix appropriate to that surface's input type**
  without an explicit named-and-justified narrowing — **CLAUDE.md's six-shape adversarial matrix**
  (`{object, array, scalar, valid-falsy, missing, wrong-type}`) for a config-JSON consumer, and the
  **input-type analogue** for the widened surfaces (a parser over agent/human-mutable markdown, a
  reader of a new external structured format) — independently re-run the bounded search behind any
  `governing conventions consulted:` line and flag a governing matrix at a path the line omits; (3) an **unstated mechanism dependency** resting on a
  **preflight-guaranteed helper contract** (only `git`/`gh`/`jq`/`python3`/PyYAML are guaranteed; a
  resolver's output shape, a gate's exit-code semantics) that the body never asserts as a claim; and — the cross-cutting obligation-arm check on shapes (1)
  and (3), not a fourth defect class — (4) an **execution-shaped obligation AC** whose discharge runs an in-repo command — confirm it
  names a command already granted in **`devflow_implement.allowed_tools`** (or is a code-reading
  obligation citing the producer), never one that would send a consumer's cloud implement run
  Blocked on an ungranted helper.
- **Mutation evidence for behavioral-fix pins (issue #464).** A Testing Strategy that commits to
  a **behavioral-fix / regression pin** — one added *specifically because* removing the pinned
  text would re-introduce a **named** bug or regression (a coupled-invariant pin, the operative
  qualifier of a sweep rule, a regression guard), per `CLAUDE.md`'s behavioral-fix-pin rule and
  `skills/implement/phases/phase-2-implement.md` §2.3 — must carry the `assert_pin_red_under`
  mutation-evidence obligation: a `sed -E` mutation that re-introduces the named bug by removing
  only the operative sentence, with the pin observed RED under it. The auditor flags such a pin
  plan that states no mutation obligation. **Surface-presence contract pins** — a plain
  `assert_pin_unique` on new prose whose removal breaks no behavioral guarantee — are explicitly
  **outside this dimension's scope** and carry no mutation obligation, matching the suite's own
  precedent (this very issue's prose pins are that class).
