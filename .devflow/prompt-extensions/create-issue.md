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
  coupled invariant without naming the other.
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
