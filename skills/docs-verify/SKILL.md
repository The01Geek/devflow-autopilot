---
name: docs-verify
description: Use when you need to verify or update internal documentation for a specific topic, or when documentation may be outdated or missing for a feature.
argument-hint: <topic>
---
> **Configuration:** Read the internal documentation path from `.devflow/config.json` using: `"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/config-get.sh .docs.internal docs/internal/`. The helper falls back to `docs/internal/` when the config file is missing or the key is absent. Use the result as `[[INTERNAL_DOC_LOCATION]]` throughout this skill.

**Portable helper anchor (single-statement).** The bundled-helper commands in this skill resolve the skill directory inline at each call site via `${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}`. When `$CLAUDE_SKILL_DIR` is set and non-empty (Claude Code), run each command exactly as written. On a runner where it is unset or empty, replace the placeholder with the skill base directory the runner reports in context (e.g. a `Base directory for this skill:` line) before running the command; if that reported path is Windows-form (`C:\...`), first convert it to this shell's POSIX form with one standalone `wslpath -u '<path>'` (WSL) or `cygpath -u '<path>'` (Git Bash/MSYS2) command and substitute the printed result **only if the command succeeds and prints a non-empty path — otherwise fall through to the drive-letter rules exactly as if the tool were absent, the same success-and-non-empty acceptance the platform's path-normalization rules apply** (if neither tool exists: lowercase the drive letter, map `C:\` to `/mnt/c` on WSL or `/c` on MSYS2, and turn backslashes into `/`; if the environment is neither WSL nor MSYS2, use the path unchanged and report that it could not be normalized — the same arm the platform's path-normalization rules take). Resolve the anchor inline at every call site — never capture it into a shell variable that a later statement reads, because some runners' inline-bash marshaling drops such variables (observed on Copilot CLI). If neither `$CLAUDE_SKILL_DIR` nor a runner-reported base directory is available, stop and report that the helper anchor could not be resolved rather than running a command with a broken path.

**Consumer prompt extension (load first).** Before doing this skill's work, load any consumer-supplied prompt extension for this skill and honor it. From the repo root, run:

```bash
"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/load-prompt-extension.sh docs-verify
```

If the invocation fails because the helper path does not exist (`No such file`, exit 127, or the platform equivalent), that is the **anchor-resolution** failure described in the *Portable helper anchor* note above — fix the anchor, don't report a missing extension. Otherwise, if the helper exits non-zero, a consumer extension exists but could not be loaded — surface its stderr message and do not silently proceed as if none existed. If it exits 0 and prints text, treat that text as additional instructions appended to the end of this skill's own prompt for this run — it is upgrade-safe, consumer-owned customization committed under `.devflow/prompt-extensions/`. If it exits 0 and prints nothing, proceed unchanged.

## **Mode**

`$ARGUMENTS` is a **leading run of flags, then the topic**. Parse flags only while the next argument begins with `--`; when that flag is a **value-taking** flag (`--search-space`), the single argument immediately after it is consumed as its value **without applying the topic test**, and parsing then resumes at the argument after that. The first argument that is tested and does not begin with `--` is where the **topic** begins, and everything from there on is the topic — so a topic is never mistaken for a flag value and a flag value is never absorbed into the topic. Strip the flags before treating the remainder as the topic.

- `--report-only` — a bare flag.
- `--search-space <pathspec>` — takes exactly the **one** argument that follows it. That argument is the flag's value, never part of the topic.

**Malformed invocations (all arms explicit).** A `--`-prefixed token that is **not** one of the two flags above is a malformed invocation: report the unrecognized token and refuse the run — never strip it as a bare flag. Silently consuming a mistyped `--reprot-only` would drop the caller into the **default write mode**, which makes file changes, so the parser fails closed on an unrecognized flag exactly as it does below. `--search-space` with **no following argument** is likewise malformed: report it and refuse the run — never parse it as an empty value. An operand supplied but **empty** (`--search-space ''`) does **not** fall through to the no-operand default: report `unestablished` for the *exact operand and population identity* duty. Silently coercing a real empty value onto the default would restore the whole-tracked-tree sweep and destroy the two legs' disjointness — this repo's documented off-switch-that-never-worked defect.

Grammar: `[--report-only] [--search-space <pathspec>] <topic…>`.

- **Default (no flag) — write mode:** verify docs and **make file changes** to bring them into line with the code (the behavior described throughout this skill).
- **`--report-only` — analysis-only mode:** perform the same verification but **make no changes** — no Edit, no Write, no commit, no push. Instead, return a structured findings report (see *Report-Only Output* under Step 4). Used by `/devflow:create-issue` to inform a new issue without writing to a protected branch.
- **`--search-space <pathspec>` — the search-space operand (report-only mode):** the population this run surveys, in place of this skill's defaults. Steps 1 and 2 both read it. When it is **not** supplied, behavior is unchanged: Step 1 searches `[[INTERNAL_DOC_LOCATION]]` and Step 2 searches the whole tracked tree.

### Breadth bound (report-only mode)

In report-only mode the **duty floor — not the size of the search space — bounds the work.** The floor is exactly these six duties: exact operand and population identity; code-versus-doc authority; reachability and writer classification; sibling consumer and output enumeration; coupled-doc and guard propagation; and reusable contradictions. A large operand does not license a proportionally larger survey; it states where you may look, not how much you must read.

Return a status for **every** duty on the floor, never only for the duties you were assigned:

- `discharged` — carried out on this run.
- `unestablished` — engaged but could not be discharged. Record it; never pass it silently.
- `judged-not-engaged` — judged not to bear on this topic. For each such duty **additionally return a bearing observation**: the paths you opened that bear on that duty, or the explicit token `none-observed` for having observed none. This field is always present, because the caller's escalation trigger reads it.

**A report-only pass dispatches no subagent of its own** — nested dispatch is unsupported on some harnesses and on DevFlow's cloud tier, so the pass is always a leaf. Escalation is a **return-value contract**: return your verdict and your per-duty statuses, and the caller decides. Never branch into a deeper pass internally.

## **Objective**
You are a **Documentation Accuracy Verification Agent** for code repositories.
Your task is to verify that documentation about a specific topic in `[[INTERNAL_DOC_LOCATION]]` is **accurate, complete, and aligned with the current codebase**.

## **Primary Mission**
Analyze a specific topic and verify:
1. **Does the documentation exist** for this topic?
2. **Is the documentation accurate** and aligned with current code?
3. **Is the documentation complete** (not missing important details)?
4. If outdated or missing: **Draft or update documentation** based on the codebase as the source of truth

## **Input Parameter**
- **Topic**: The specific topic to verify documentation for (e.g., "customer-auto-verification", "orders-backorder-system", "jsx-components-guide")

## **Core Principles**

### Source of Truth
- **The codebase is the source of truth** - documentation must reflect what the code actually does
- If code and documentation conflict, the code is correct and documentation must be updated
- Use code behavior, not historical documentation, to validate accuracy

### Documentation Scope
Documentation files are located in `[[INTERNAL_DOC_LOCATION]]` and organized by category in subdirectories.

---

## **Execution Model**

⚠️ **Your action depends on the mode (see *Mode* above):**
- **Write mode (default):** Create or Edit Documentation — make real file changes to add/update documentation files.
- **Report-only mode (`--report-only`):** Make no changes — return the findings report described in *Report-Only Output* (under Step 4).

---

## **Detailed Execution Steps**

### **Step 1: Locate Documentation Files**
Search for any existing documentation about the topic **within the supplied `--search-space` operand**; when no operand was supplied, search `[[INTERNAL_DOC_LOCATION]]`:
- Use `glob` to find files in that search space matching the topic name
- Search for files containing the topic using `grep` and `find` commands
- Document all files found (or note if no files exist)

### **Step 2: Search Codebase for Topic**
Identify all code related to the topic, **searching the supplied `--search-space` operand**; when no operand was supplied, search the whole tracked tree. In report-only mode the duty floor above — not the size of that space — bounds how far this search goes:
- Search that space (`grep`, `find`) for classes, functions, features mentioned in the topic
- Review all relevant source files
- Document the key files and features involved

### **Step 3: Compare Documentation vs Code**

For **existing documentation**:
- Read the documentation file(s)
- Compare content with current code implementation
- Identify:
  - **Accurate sections** - Document these findings
  - **Inaccurate sections** - What's wrong and what the code actually does
  - **Missing sections** - Important details not covered
  - **Outdated information** - References to removed/changed code

For **missing documentation**:
- Note that no documentation exists for this topic
- Flag this as a gap that needs to be filled

### **Step 4: Determine Actions Needed**

**Report-only mode (`--report-only`):** do not edit or create any files. Skip the paths below and produce the *Report-Only Output* instead, classifying the topic as accurate / drifted / missing based on Steps 1–3.

**Write mode (default):** choose ONE of these paths:

**Path A: Documentation is accurate and complete**
- Provide analysis confirming accuracy
- No file edits needed
- Recommend areas for future enhancement

**Path B: Documentation is outdated or inaccurate**
- Identify specific inaccuracies
- Provide corrected content
- Edit the documentation file(s) to align with current code
- Preserve accurate sections while fixing inaccurate ones

**Path C: Documentation is missing**
- Analyze the codebase thoroughly
- Draft comprehensive documentation
- Create a new `.md` file in appropriate `[[INTERNAL_DOC_LOCATION]]` subdirectory
- Include all essential information about the topic

### Report-Only Output (`--report-only` mode)

Return findings as text — **do not write them to a file**. Structure:

- **Verdict:** `DOCS ACCURATE` | `DRIFT FOUND` | `DOCS MISSING`
- **Relevant code files:** the files that implement the topic (the map for the issue and the implementer)
- **Current behavior:** what the code actually does today, in brief
- **Drift detail:** for `DRIFT FOUND` / `DOCS MISSING`, the doc path(s) and the specific inaccurate / outdated / missing sections
- **Search space surveyed:** the `--search-space` operand this run used, or the default it fell back to
- **Duty statuses:** one status per duty on the *Breadth bound* floor — `discharged`, `unestablished`, or `judged-not-engaged` — for **all six** duties, not only the assigned ones
- **Bearing observations:** for every duty reported `judged-not-engaged`, the paths opened that bear on it, or `none-observed`

Make no Edit, Write, commit, or push in this mode, and dispatch no subagent. The working tree must be unchanged when you finish.


---

### Quality Checklist
- [ ] All related code files examined
- [ ] Documentation content compared against actual code behavior
- [ ] Inaccuracies identified and corrected
- [ ] Missing sections added
- [ ] Documentation file(s) created or edited
- [ ] Outdated references removed or updated

---

## **File Operations**

### Creating New Documentation
- Create in appropriate `[[INTERNAL_DOC_LOCATION]]` subdirectory
- Use Markdown formatting with clear structure
- Include: Overview, Key Components, Code Examples, Configuration, Important Notes
- Follow existing documentation style and formatting in `[[INTERNAL_DOC_LOCATION]]`
- Reference source files by bare path only (e.g., `src/app/server.py`) — **never append line numbers** (e.g., do not write `server.py:42`); use function or class names instead, as line numbers change as code evolves

### Editing Existing Documentation
- Update content to match current code
- Preserve accurate sections
- Replace/update inaccurate sections
- Add missing details
- Remove outdated information
- Maintain consistent formatting

### File Naming
Use descriptive names matching the topic:
- Lowercase with hyphens: `feature-name.md`
- Examples: `customer-auto-verification.md`, `order-backorder-system.md`

---

## **Quality Standards**

- **Accuracy**: Every statement must reflect current code implementation
- **Completeness**: All essential information about the topic must be included
- **Clarity**: Use simple, clear language that developers can understand
- **Consistency**: Match formatting and style of existing documentation files
- **Examples**: Include code examples showing actual usage where applicable
- **Alignment Rule**: After reading the documentation, a developer should understand the current implementation

---

## **Important Constraints**

**Scope:**
- Focus only on the specified topic
- Search comprehensively for all related code and documentation
- Stay within `[[INTERNAL_DOC_LOCATION]]` boundaries for edits

**File Operations:**
- Create or edit only documentation files inside `[[INTERNAL_DOC_LOCATION]]`
- Do not modify code files
- Do not modify files outside `[[INTERNAL_DOC_LOCATION]]`

---

## **Verification Checklist**

> **`--report-only` mode:** the file-creation/edit items below do **not** apply — verify only that you searched docs and code, compared them, and produced an accurate findings report. The checklist and the *Success Criteria* below describe the standalone **write-mode** run; do not treat them as your "done" state in report-only mode.

Before completing (write mode), verify you have:

- [ ] Located all existing documentation about the topic
- [ ] Searched codebase comprehensively for related code
- [ ] Compared documentation against actual code implementation
- [ ] Identified inaccuracies, missing content, and outdated information
- [ ] Determined if documentation needs to be Created, Edited, or is Accurate
- [ ] Created or edited documentation files as needed
- [ ] Ensured documentation aligns with current code
- [ ] Verified documentation is complete and accurate
- [ ] Stayed within `[[INTERNAL_DOC_LOCATION]]` boundaries

---

## **Success Criteria**

**`--report-only` mode:** success = an accurate findings report returned as text and an unchanged working tree (no files created or edited). This mode is typically a **sub-step of another skill (e.g. `/devflow:create-issue`)** — when you finish, hand the report back to the calling flow and let it continue. Do **not** announce overall task completion or stop the larger task; the "Task Complete" criteria below are for standalone write-mode runs only.

✅ **Write mode — Task Complete When:**
1. Documentation accurately reflects current code implementation
2. All important details about the topic are documented
3. No contradictions between documentation and code
4. Documentation file(s) created/updated in `[[INTERNAL_DOC_LOCATION]]`

Arguments (`[--report-only] [--search-space <pathspec>] <topic…>` — leading flags, then the topic): $ARGUMENTS
