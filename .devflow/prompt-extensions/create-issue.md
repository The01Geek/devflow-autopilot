## Interaction-surface map — establish the contract before you design against it

**When this fires.** Your mechanism amends a DevFlow engine surface that *decides* something: a
**gate's firing condition**, an **outcome or verdict selection** (a Decide outcome, a verdict arm, a
promotion), a **novelty or comparison rule** (what counts as new, changed, a subset, a duplicate), or
a **sentinel surface** (a status token, a closed enum, a provenance literal, a pinned marker) — in
`skills/review-and-fix/SKILL.md`, `skills/review/SKILL.md`, or any shared-engine file. It does not
fire on a draft that adds a standalone helper, changes docs only, or creates a surface no step reads
yet.

**Produce the map before any mechanism prose exists** — not alongside it, and not to justify a design
you have already chosen. Write an **Interaction-surface map** block into this run's derivation
artifact (`.devflow/tmp/issue-derivation-<slug>.md`, which the Step 2 gate already requires; in a
read-only sandbox it goes in the same visible chat block that stands in for that file). The block has
four parts, in this order. Every entry is a **`Verified:` bullet quoting the sentence from the file
verbatim, with its location** — the repo's existing cited-evidence convention, applied to contract
text:

1. **Firing conditions** — the surface's current trigger predicate, quoted whole, **plus the rule
   that orders it against its neighbours** (what is evaluated first, what dominates, what is
   unreachable when it fires).
2. **Every consumer of the value you are amending** — each step, comparison count, subset test,
   verdict selection, record render, or downstream gate that reads it, with the quoted sentence that
   reads it. A consumer you cannot name is a consumer you have not looked for, not one that does not
   exist.
3. **Every producer of every operand your mechanism reads** — for each operand, the line that emits
   it and the paths on which it is emitted, **including which populations have no producer**. An
   operand with no producer on a path your mechanism now selects fails open exactly where you are
   claiming it fails closed.
4. **Every pinned literal and sentinel in the blast radius** — each `lib/test/run.sh` pin, enum
   value, and mirror site whose text your change would touch, enumerated with a
   **whitespace-normalized** search (a contract phrase wrapped across lines lives on no single line).

**Quote, never paraphrase — this is the part that carries the weight.** A contract sentence is where
the design error is born, and it is born in the summary of it. A sentence of the form *"an X in state
S cannot drive outcome O"* paraphrases with equal ease into "S demotes it," "S excludes it from the
count," and "S does not apply here" — three different mechanisms, one contract, and at most one of
them correct. Each reading feels verified, because you did read the file; what you carried away was
your compression of it. The quote is what makes the contradiction visible while the design is still
cheap to change. Design against the quoted text, and keep the quote where the next reader can check
it against the source.

**Then design, and cite the map.** Each mechanism claim that rests on a mapped fact points at the
entry that established it. A mechanism claim resting on a contract you did not quote is unverified —
write it as a flagged assumption or resolve it now, exactly as the Step 3.5 steelman requires of every
other load-bearing premise. The map persists in the derivation artifact as this run's verified-claims
ledger, so a later audit round spot-checks it and audits the delta instead of re-deriving the whole
surface from scratch.

## Deployment-variance steelman — design for the consumer's repo, not this one

**When this fires.** Your draft amends anything that *ships*: `skills/`, `agents/`, `scripts/`,
`lib/`, `.github/workflows/`, the config schema, or `install.sh`. It does not fire on a draft that
touches only repo-internal surfaces (the suite, CI wiring, dev-only docs).

**Why it exists.** This repo is the plugin's development tree, not its deployment target, and every
premise you absorb from working here — that `scripts/` sits at the repo root, that the shell is
bash 5 on macOS, that a human is present to answer a question, that a denied command fails loudly —
is false somewhere in the installed base. A mechanism that is correct here and wrong there does not
announce itself: it no-ops, or it silently selects the wrong branch, and the consumer sees a
degraded run they cannot diagnose. So before you present the draft, walk the four axes below and,
for each one your mechanism touches, either **resolve it against cited evidence or write it into
the draft as a flagged assumption** — the same discharge the Step 3.5 steelman demands of every
other load-bearing premise. Silence on an axis your mechanism touches is not "not applicable"; it
is an unexamined premise.

1. **Consumer-repo shape.** A consumer's checkout has the plugin vendored under
   `.devflow/vendor/devflow/` and **no repo-root `scripts/`** — a workflow step invoking
   `scripts/foo.sh` is rc 127 in every consumer run (#502). Ask which paths your mechanism reads
   that exist only here (`lib/test/run.sh`, `.changeset/`, this repo's own `.devflow/config.json`),
   and which **artifact ships each half** of it: workflows reach consumers by `install.sh`'s
   file-copy loop, skills by the `devflow_version` vendor fetch. Those are two independently
   upgraded artifacts, so a mechanism split across both must say what happens when only one side
   lands — a skew that silently re-denies a grant is the #455 failure, not a hypothetical.
2. **OS, shell, and binaries.** macOS/BSD without GNU coreutils (no `grep -P`, no `date -d`,
   no GNU-only flags); Windows via WSL / Git Bash / MSYS2, where a Windows-form path breaks a POSIX
   consumer and a `.sh` exec from Python is `[WinError 193]` (#275). The bash that runs the helpers
   is chosen at the **invocation** boundary (`DEVFLOW_BASH`), never by a sourced resolver (#248);
   `gh`/`jq` route through the `resolve-*.sh` family. State which of these your mechanism depends on
   rather than inheriting this machine's answer.
3. **Tier.** The tiers have *different* failure modes, and a mechanism proven on one is unproven on
   the others. Local/interactive: the classifier denies `bash <path>` and helper-by-path
   invocations, and the run cannot self-grant. Cloud: the read-only `review` profile and the
   read-write `devflow-implement` profile are **separate allowlists with separately probed denied
   shapes** — a shape permitted on one tier is evidence for nothing on the other (#455), and an
   ungranted head refuses the whole statement with *no output at all*, never an empty value.
   Headless: there is no user to ask, so a mechanism that prompts, or that invokes a nested
   interactive skill, stalls the run instead of failing (#362, #366).
4. **Cost and quality — what does this tax, and on which runs?** Name what the mechanism adds per
   run (an agent dispatch, an audit round, a re-load, a poll) and how often it fires. A gate that
   runs on every consumer's every run to catch a rare defect is a permanent tax paid by everyone;
   prefer a design that fires on the population that can actually exhibit the defect. And treat the
   merge-gating judge's economics as frozen: `agent_overrides` model/effort values reach the
   standalone `/devflow:review` that gates every PR before merge, so a draft must not cheapen that
   reviewer as a side effect of tuning something else (#425).

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
- **Deployment-variance silence.** A draft amending a *shipped* surface (`skills/`, `agents/`,
  `scripts/`, `lib/`, workflows, config schema, `install.sh`) rests on four axes of variance the
  drafting environment hides: **consumer-repo shape** (no repo-root `scripts/`, the vendored path,
  the `install.sh`-vs-`devflow_version` two-artifact skew — #502/#455), **OS/shell/binaries**
  (BSD without GNU coreutils, Windows path forms and `.sh`-exec failure, `DEVFLOW_BASH`, the
  `resolve-*.sh` family — #275/#248), **tier** (local classifier denials; the review and implement
  allowlists as *separate* probed surfaces where an ungranted head yields no output at all; headless
  runs with no user to prompt — #455/#362/#366), and **cost/quality** (what the mechanism taxes per
  run, and the frozen merge-gating-judge economics — #425). Judge each axis the mechanism touches:
  it must be resolved against cited evidence or carried as a flagged assumption.
  **Silence on a touched axis is a finding**, not an implicit N/A — that is the shape in which an
  environment-variance defect ships. The narrower dimensions above (allowlist skew, matcher shapes,
  non-preflight PATH tools, shallow clone) are specific instances; this one catches the axis a draft
  never considered at all.
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

## Evidence axes

DevFlow-specific evidence axes for the Step 2 evidence-bundle sub-pass. The skill appends this
section to its generic axis floor when computing the effective axis list. Record a bundle entry
for each of these, in addition to the generic axes:

- **Per-profile cloud allowlists.** A skill/phase change that invokes a shell helper touches the
  relevant `.github/workflows/` `TOOLS=`/`--allowed-tools` allowlist(s) — the read-only `review`
  profile and the read-write `devflow-implement` profile are **separate, separately-probed**
  allowlists (a shape proven on one tier is unproven on the other, #363/#455). Record which
  profiles run the changed surface and whether each invoked head is granted.
- **Install-channel skew.** Workflows reach consumers by `install.sh`'s file-copy loop while
  skills reach them by the `devflow_version` vendor fetch — two independently-upgraded artifacts
  (#455/#502). Record which artifact ships each half of the change and what happens when only one
  side lands.
- **Workpad and retrospective lifecycle surfaces.** The issue workpad's status/reflection
  vocabulary, the `DevFlow`/`Documented`/`Deferred` label constants, and the weekly-retrospective
  cheap-gate signals are lifecycle surfaces a change can perturb. Record which lifecycle states,
  labels, or gate signals the change reads or writes.
- **The `lib/test/run.sh` pin corpus.** A contract sentence, literal, or count this change ships
  is likely mirrored by a `lib/test/run.sh` pin (or an extension count guard). Record the pins the
  change adds, moves, or must keep byte-identical (enumerated with a whitespace-normalized search).
