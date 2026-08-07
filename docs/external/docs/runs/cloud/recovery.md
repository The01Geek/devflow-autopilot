---
title: "Cloud Recovery"
description: "Resume or recover a blocked, failed or interrupted PRFlow cloud run."
---

Resume an implementation or review when a cloud run stops making progress or ends before completing the handoff.

## Start With Recorded State

Start with the workpad or review-progress comment. Cross-check its status against the linked Actions run, current pull-request head and remote branch. For implementation, the workpad is the primary progress record, not a transaction log.

Interpret an implementation workpad status as follows:

- An interim 🚀 status means the lifecycle did not reach a terminal state.
- 🎉 Complete means PRFlow finished its lifecycle. It does not mean the pull request was merged.
- 👎 Blocked names a prerequisite or verification that needs human action.
- 💥 Failed or 🛑 Cancelled means the run stopped terminally.

## Recover From a Stopped Run

1. Read the last workpad note and the matching Actions step.
2. Check authentication, runner prerequisites and `.prflow/config.json` before changing code.
3. Fix the named blocker or confirm that the failure was transient.
4. Reissue the original standalone command.
5. Confirm that the new run adopts the existing workpad or current pull-request head.

Implementation pushes progress at branch checkpoints. A later run can adopt the existing branch and pull request. Work after the last pushed checkpoint can still be lost. A run interrupted before its first checkpoint may have no branch changes to recover.

Configured stall backstops can post bounded resume requests for interim runs. They do not resume cancelled runs. When the cap is exhausted, authentication is unavailable or state cannot be read, the workflow reports the failure instead of looping indefinitely.

Do not repeatedly retry an unchanged deterministic failure. Use [Cloud-Run Problems](/docs/troubleshooting/cloud-runs) to match the symptom to a correction first.
