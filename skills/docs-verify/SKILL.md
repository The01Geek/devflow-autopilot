---
name: docs-verify
description: Use when you need to verify or update internal documentation for a specific topic, or when documentation may be outdated or missing for a feature.
argument-hint: <topic>
---
> **Configuration:** Read the internal documentation path from `.github/project-config.yml` using: `${CLAUDE_SKILL_DIR}/../../scripts/config-get.sh .docs.internal docs/internal/`. The helper falls back to `docs/internal/` when the config file is missing or the key is absent. Use the result as `[[INTERNAL_DOC_LOCATION]]` throughout this skill.

## **Mode**

`$ARGUMENTS` may begin with a `--report-only` flag; everything after it is the **topic**. Strip the flag before treating the remainder as the topic.

- **Default (no flag) — write mode:** verify docs and **make file changes** to bring them into line with the code (the behavior described throughout this skill).
- **`--report-only` — analysis-only mode:** perform the same verification but **make no changes** — no Edit, no Write, no commit, no push. Instead, return a structured findings report (see *Report-Only Output* under Step 4). Used by `/create-issue` to inform a new issue without writing to a protected branch.

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
Search for any existing documentation about the topic:
- Use `glob` to find files in `[[INTERNAL_DOC_LOCATION]]` matching the topic name
- Search for files containing the topic using `grep` and `find` commands
- Document all files found (or note if no files exist)

### **Step 2: Search Codebase for Topic**
Identify all code related to the topic:
- Search the codebase (`grep`, `find`) for classes, functions, features mentioned in the topic
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

Make no Edit, Write, commit, or push in this mode. The working tree must be unchanged when you finish.


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

Before completing, verify you have:

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

✅ **Task Complete When:**
1. Documentation accurately reflects current code implementation
2. All important details about the topic are documented
3. No contradictions between documentation and code
4. Documentation file(s) created/updated in `[[INTERNAL_DOC_LOCATION]]`

(In `--report-only` mode, success = an accurate findings report and an unchanged working tree — no files created or edited.)

Arguments (optional leading `--report-only` flag, then the topic): $ARGUMENTS
