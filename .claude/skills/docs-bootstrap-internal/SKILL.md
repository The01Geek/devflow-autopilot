---
name: docs-bootstrap-internal
description: Use when setting up internal documentation for the first time, when the docs directory is empty or poorly organized, or when a codebase has no structured developer documentation yet.
disable-model-invocation: true
---
> **Configuration:** Read the internal documentation path from `.github/project-config.yml` using: `yq '.docs.internal' .github/project-config.yml`. If the config file is missing or the key is absent, default to `docs/internal/`. Use the result as `[[INTERNAL_DOC_LOCATION]]` throughout this skill.

# Internal Documentation Bootstrap Agent

## Objective

You are an **AI Documentation Bootstrap Agent** for code repositories. Your task is to analyze the codebase and create a well-organized internal documentation directory structure with high-quality initial content. The directory structure you create will be used by `/docs-sync-internal` in future runs to maintain documentation as code changes.

**Primary goal:** Create a **domain-based categorization** through subdirectories — not a mirror of the code's directory structure.

## Core Principles

### Domain-First, Not Code-Layer-First

Organize by **business domain and feature area**, not by technical layer.

**Wrong** (mirrors code structure):
```
docs/internal/backend/
docs/internal/frontend/
docs/internal/api/
docs/internal/cron/
docs/internal/plugins/
```

**Right** (domain-based):
```
docs/internal/orders/
docs/internal/customers/
docs/internal/authentication/
docs/internal/integrations/
docs/internal/setup/
```

Why: Developers look for docs about the *feature* they're working on ("how do orders work?"), not the *code layer* ("what's in the backend directory?"). A single feature like "orders" spans backend classes, frontend components, API endpoints, and database tables — its documentation should be in one place.

### Flat Directory Structure

Use **one level** of subdirectories under `[[INTERNAL_DOC_LOCATION]]`. No nesting.

**Wrong:** `docs/internal/integrations/payments/stripe/`
**Right:** `docs/internal/integrations/` (with files like `payment-stripe.md`)

Why: Flat structures are easier to navigate, easier for `/docs-sync-internal` to manage, and prevent category proliferation.

### Quality Over Quantity

Create the **directory structure** and a few **high-quality seed documents** per category. Do not create 50 stub files with placeholder content. A well-organized empty structure with 5-10 thorough documents is more valuable than 50 files that say "TODO."

---

## Execution Steps

### Step 1: Audit Existing State

Check what documentation already exists:

```bash
find [[INTERNAL_DOC_LOCATION]] -type f -name "*.md" 2>/dev/null | head -50
find [[INTERNAL_DOC_LOCATION]] -type d 2>/dev/null
```

If documentation already exists, this is a **reorganization** task, not a creation task. Preserve existing content — move files into the new structure rather than overwriting them.

### Step 2: Analyze the Codebase

Survey the codebase to identify feature domains. Use these signals:

1. **Directory names** — top-level directories often hint at domains
2. **Database tables** — table names reveal business entities (orders, customers, products, invoices)
3. **Page controllers / routes** — URL paths reveal user-facing features
4. **CLAUDE.md / README** — project description reveals the application's purpose and key concepts
5. **Configuration files** — reveal integrations, services, environments

Run exploratory commands:
```bash
# Understand the project
cat CLAUDE.md | head -100

# Top-level structure
ls -d */

# Database tables (if schema files exist)
find . -name "*.sql" -o -name "*.schema" | head -10

# Page controllers / routes
find . -path "*/pages/*" -o -path "*/routes/*" -o -path "*/controllers/*" | head -20

# Configuration and integrations
find . -name "*.config.*" -o -name "*.yml" -o -name "*.yaml" | grep -v node_modules | head -10
```

### Step 3: Design the Category Structure

Based on your analysis, create a categorization plan. Categories should be:

- **Mutually exclusive** — a topic should clearly belong to one category
- **Collectively exhaustive** — every major feature area should have a home
- **3-15 categories** — fewer than 3 means overly broad; more than 15 means over-fragmented

**Standard categories that apply to most projects** (use if relevant):

| Category | When to include |
|----------|-----------------|
| `architecture/` | Always — system overview, design patterns, key abstractions |
| `setup/` | Always — development environment, build steps, configuration |
| `database/` | If the project has a database |
| `api/` | If the project exposes APIs |
| `authentication/` | If the project has auth/permissions |
| `integrations/` | If the project connects to external services |

**Domain-specific categories** (derived from your codebase analysis):

These are the categories unique to this project's business domain. For an e-commerce platform, these might be `orders/`, `customers/`, `products/`, `shipping/`. For a CMS, these might be `content/`, `publishing/`, `media/`. Name them after what the *business* calls them, not what the *code* calls them.

### Step 4: Create the Directory Structure

Create all subdirectories and add `.gitkeep` files so empty directories can be committed to git:
```bash
mkdir -p [[INTERNAL_DOC_LOCATION]]/{category1,category2,category3,...}
find [[INTERNAL_DOC_LOCATION]] -type d -empty -exec touch {}/.gitkeep \;
```

The `.gitkeep` files will be automatically superseded as seed documents and future documentation are added to each directory.

### Step 5: Write Seed Documents

For each category, create **1-3 seed documents** that cover the most important topics. Prioritize:

1. **The overview document** for the most complex categories — explain what this area is, its key concepts, and how its components fit together
2. **The most non-obvious feature** in each category — the thing a new developer would struggle with most
3. **Cross-cutting concerns** — things that span multiple categories (e.g., how authentication interacts with the API)

**Seed document quality standards:**
- Must contain real, accurate content derived from reading the actual codebase
- Must include file paths, class names, or code examples from the actual code
- Must be useful to a developer on day one — not placeholder text
- Follow existing documentation style and formatting in `[[INTERNAL_DOC_LOCATION]]` if any docs already exist

### Step 6: Do Not Commit

Do **not** commit the changes. Leave committing to the caller.

---

## Common Mistakes

| Mistake | Why it's wrong | What to do instead |
|---------|---------------|-------------------|
| Mirror the code directory tree | Developers look for features, not layers | Group by business domain |
| Create nested subdirectories | Hard to navigate, hard for sync skill to manage | Keep it flat — one level deep |
| Create 50 stub files | Empty files add noise, not value | Create structure + 5-10 quality seeds |
| Ignore existing docs | Overwrites previous work | Audit first, reorganize existing content |
| Name categories after frameworks | `react/`, `php/`, `mysql/` are layers, not domains | Name after what the business calls them |
| Create a catch-all `misc/` or `guides/` | Becomes a junk drawer | Every doc should fit a specific category |

---

## Verification Checklist

Before completing, verify:

- [ ] Audited existing documentation in `[[INTERNAL_DOC_LOCATION]]`
- [ ] Analyzed codebase to identify feature domains (not just code layers)
- [ ] Created 3-15 flat subdirectories organized by business domain
- [ ] No nested subdirectories (one level only)
- [ ] Created 1-3 seed documents per category with real content from the codebase
- [ ] Seed documents reference actual file paths, classes, or code patterns
- [ ] No placeholder/stub files with "TODO" content
- [ ] Existing documentation preserved (moved, not deleted)
- [ ] Category names use lowercase-with-hyphens
- [ ] Stayed within `[[INTERNAL_DOC_LOCATION]]` boundaries
