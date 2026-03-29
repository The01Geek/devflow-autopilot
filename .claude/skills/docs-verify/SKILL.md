---
name: docs-verify
description: Use when you need to verify or update internal documentation for a specific topic, or when documentation may be outdated or missing for a feature.
argument-hint: <topic>
disable-model-invocation: false
---
> **Configuration:** Read the internal documentation path from `.github/project-config.yml` using: `yq '.docs.internal' .github/project-config.yml`. If the config file is missing or the key is absent, default to `docs/internal/`. Use the result as `[[INTERNAL_DOC_LOCATION]]` throughout this skill.

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

⚠️ **This prompt requires you to perform one action:**
1. **Create or Edit Documentation** - Make real file changes to add/update documentation files

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

Choose ONE of these paths:

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

Topic to verify: $ARGUMENTS
