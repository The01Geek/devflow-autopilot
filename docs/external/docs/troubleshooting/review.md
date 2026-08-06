---
title: "Review Problems"
description: "Fix unresolved pull-request targets, stale bases, missing progress and verdict problems."
---

# Review Problems

This page is for users whose review cannot resolve or finish the intended pull request.

## The Pull Request Cannot Be Resolved

Pass a numeric pull-request number and confirm it exists in the current repository. Run:

```bash
gh pr view <number>
gh pr diff <number>
```

If either command fails, fix GitHub authentication or repository access. Do not pass additional flags where the skill expects only a number.

## The Review Targets the Wrong Branch or Commit

Standalone review uses the pull request's pushed head and its current base. Confirm the pull request has the expected head commit and base branch in GitHub. Push local commits before requesting standalone review.

If a pull request was retargeted, fetch the new base and retry. A deleted or unreachable base can stop review because the diff cannot be established safely.

## A Cloud Review Comment Does Nothing

Post `/prflow:review` as a standalone comment on the pull request's **Conversation** tab. Review-submission text and inline review comments are not subscribed trigger surfaces. The requester must be an authorized repository collaborator.

## A Duplicate Review Was Suppressed

PRFlow suppresses a second review request while a fresh progress comment shows a review of the same head commit in flight. Wait for that run. Push a new commit before requesting review again if the pull-request head has changed.

## The Progress Comment Has No Verdict

Open the linked Actions run and inspect execution diagnostics for permission denials or an engine error. A failed run can flip the comment to `Review failed`. A configured backstop may post a bounded resume request, but it does not retry forever.

Fresh installs do not provide the old automatic `Devflow Review` status workflow. Do not add that status as a required check unless your repository deliberately retained and operates the legacy tier.

## The Review Did Not Apply My Prompt Extension

`/prflow:review`, `/prflow:review-and-fix` and `/prflow:implement` receive `.prflow/prompt-extensions/<skill>.md` as prompt text prepared before the agent starts, so the extension no longer depends on the agent choosing to load it. Check three things when a run appears to ignore your policy:

- **The extension is reported as `unestablished`.** The run states this rather than staying silent. It means the extension's state could not be established — an unreadable file, a broken symlink, something that is not a regular file, or a trusted-extension directory that did not materialize. Treat it as *not applied*, never as an empty extension. Fix the file and re-run.
- **The file name does not match the skill.** The name is the skill's own directory name: `review.md`, `review-and-fix.md`, `implement.md`. `/prflow:review-and-fix` additionally reads `receiving-code-review.md`, because its fix loop applies that skill's principles without invoking it.
- **A cloud installation is out of date.** The delivery mechanism needs a permission entry that ships in the installed workflow files, while the skills themselves ship in the plugin. Updating only `prflow_version` leaves the two halves out of sync and the run falls back to the older, less reliable path. Re-run the installer with the new tag — see [Cloud Updates](/docs/runs/cloud/updates).

A file that is absent or empty is not an error. The run proceeds with PRFlow's own defaults.
