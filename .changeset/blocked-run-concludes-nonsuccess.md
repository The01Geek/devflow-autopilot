---
bump: patch
---

Fix: an implement run that ends `👎 Blocked` (or `💥 Failed`) now concludes the cloud job non-`success` instead of green.

`scripts/workpad.py status` previously collapsed all four terminal glyphs (🎉 👎 💥 🛑) to a single `terminal` class, so the cloud stall backstop could not tell a blocked run from a completed one and concluded both `success`. The status classification now names each terminal glyph with its own class (`complete`/`blocked`/`failed`/`cancelled`), and `scripts/stall-backstop-decide.sh` maps a `blocked`/`failed` terminal status to a new `fail-blocked` outcome that the `Stall backstop` step in `.github/workflows/devflow-implement.yml` acts on: it emits a `::error::` annotation naming the issue number and the workpad status and exits non-zero, so `gh run list` plus the run's own annotation distinguish a blocked run from a completed one without opening the workpad. `🎉 Complete` still concludes `success` and `🛑 Cancelled` is never converted to a failure. The workpad is left unchanged (its `👎`/`💥` status is already truthful).
