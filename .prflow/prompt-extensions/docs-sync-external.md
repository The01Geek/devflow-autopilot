# PRFlow Mintlify Publishing Contract

Maintain the authored Mintlify source under `docs/external/`; deployment is a consequence of merging these files, not a separate content-generation step.

## Page and Navigation Shape

- When a page is added, moved or removed, update `docs.json` in the same change.
- Mirror category and subcategory directories with nested navigation groups.
- Every category and subcategory directory has a substantive `index.md` landing page.
- Keep the hierarchy at no more than category/subcategory/page depth.
- Normal documentation pages use `.md`; only the root landing page uses `.mdx`.
- Use root-relative internal links and verify that every navigation route resolves to exactly one source page.

## Repository Boundary

Keep this tree source-only. Do not add generated HTML, CSS, JavaScript, dependency manifests, lockfiles or `node_modules`. Do not edit release-note or changelog content during this pass; those files belong to the release-notes workflow.

## Content Standard

Explain current, supported user behavior in clear customer-facing language. Verify commands, configuration keys and defaults against implementation. Exclude secrets, private operational details, internal-only review mechanics and unshipped plans.
