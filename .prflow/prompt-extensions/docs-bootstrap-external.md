# PRFlow Public Documentation Contract

This repository publishes its customer-facing documentation with Mintlify from `docs/external/`.

## Source Boundary

Exclude `docs/external/**` from internal source discovery. It is the output tree for this skill, not an internal source of truth. Read the remaining internal documentation, relevant implementation and tests before drafting public guidance.

## Output Shape

- Treat `docs/external/docs.json` as the navigation manifest and update it whenever a page is added, moved or removed.
- Keep the filesystem hierarchy and navigation hierarchy aligned.
- Give every category and subcategory directory a substantive `index.md` landing page.
- Keep content at no more than category/subcategory/page depth.
- Use `.md` for normal documentation pages. Use `.mdx` only for the root landing page when Mintlify components are useful.
- Store only authored Markdown, MDX and Mintlify configuration in this tree. Do not add generated HTML, CSS, JavaScript, dependency manifests, lockfiles or `node_modules`.

## Public-Safety Review

Write for PRFlow users. Include supported commands, user-visible configuration and recovery steps. Exclude credentials, private operational details, maintainer-only mechanics and speculative behavior. Verify commands and setting names against the current repository before publishing them.
