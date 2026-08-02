## Acceptance Criteria

**AC1 — Enumerate and fix the stale instruction sites in a single change.** All 12 files in the "Stale — must change" table below are corrected in the same commit. Verified by: `git grep -c -F 'devflow.allowed_tools' -- <each path>` returns the expected post-fix count (`0` for the stale-only files; the preserved counts for the mixed files per AC2).

**AC2 — Leave every correct-as-written occurrence byte-identical.** The 5 files in the "Correct as written — must NOT change" table are unmodified. Verified by: `git diff --stat origin/main..HEAD -- <those paths>` is empty for the four pure-preserve files, and shows no change to the preserved line in `lib/test/run.sh`.

**AC3 — Regenerate the SHA-pinned cloud writer contract in the same commit.** `scripts/devflow-cloud-writer-contract.json` SHA-256-pins `skills/implement/phases/phase-3-review.md`, `skills/review-and-fix/references/fixing.md`, and `skills/review/phases/phase-0-6-stale-prose-lint.md`; editing any of the three turns the required `lib + python tests` check RED until regenerated. Run `python3 lib/test/cloud_writer_contract.py generate` and commit the result in the same change. Verified by: the full suite is green.

**AC4 — Prompt-surface edits route through `writing-skills`.** The four `skills/**` files are prompt surfaces. Per the repo's prompt-surface edit routing rule, each edit is made through a context-isolated Agent-tool subagent invoking `superpowers:writing-skills`, with a `Writing-skills evidence:` marker recorded in the workpad. The `CLAUDE.md` edit is made **directly by the orchestrator** under the #366 carve-out, cited and recorded in the workpad.

**AC5 — Full suite and lints green.** `lib/test/run.sh` reports `0 failed, 0 skipped`; `git ls-files '*.sh' | grep -v '^lib/test/' | xargs -r shellcheck --severity=warning -e SC1091` and `git ls-files '*.py' | xargs -r ruff check` are clean. This is in-env verifiable on both tiers (the suite direct forms are granted).

**AC6 — Add a changeset.** This touches the engine surface (`skills/`, `scripts/`, workflows, config schema), so a uniquely-named `.changeset/*.md` with `bump: patch` frontmatter is added. Do not edit `.claude-plugin/plugin.json` or `CHANGELOG.md` directly.

**AC7 — No frozen spelling is swept.** Verified by: `git diff origin/main..HEAD` contains no rename of any frozen identifier (see "What this issue does NOT touch").

### Optional / deferrable — decide explicitly, do not silently bundle

**AC8 (proposed, splittable)** — Close the detection gap so a stray superseded top-level family beside a present canonical one is *loud on the run path*, not merely at install time. The narrow form: extend the two workflows' `config` jobs with a check that emits a `::warning::` when the config carries any top-level key named in `lib/rename-map.json`'s `config_keys` **alongside** its canonical counterpart. This is a behavior change to a security-adjacent trigger-time surface and deserves its own adversarial input-shape matrix (`{top-level, devflow, prflow}` × `{object, array, scalar, valid-falsy, missing, wrong-type}`) plus `lib/test/run.sh` arm coverage. **Recommend splitting this into a prerequisite-independent follow-up issue** — bundling a docs correction with a new workflow guard puts a seam in the middle of the change.
