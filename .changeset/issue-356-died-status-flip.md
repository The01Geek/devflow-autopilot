---
bump: patch
type: Added
---

- **Mark a dead cloud run's Status comment as died instead of leaving it frozen.** When a
  cloud run dies — job failure, cancellation, or an exhausted implement auto-resume cap — its
  Status-bearing comment no longer lies at its last interim value. The implement workpad gains
  a new terminal status word **`Failed`** (glyph **💥**, a workpad-only glyph with no
  triggering-comment reaction): every fail-loud exit of the stall backstop that is reached
  after reading a genuinely **interim** Status flips the workpad to `💥 Failed`, best-effort
  and never altering the step's exit code (a terminal, unreadable, or auth-failure Status is
  never clobbered, and the green auto-resume path never flips). The review
  engine's live progress comment is flipped to its existing `❌ Review failed` state by a new
  best-effort helper (`scripts/flip-review-progress-failed.sh`) wired into `devflow-review.yml`'s
  `finalize_check` and `devflow.yml`'s comment-triggered job — each covering the same three
  non-success arms: job/step failure, cancellation, and an engine that ended `is_error` while
  the step itself still reported success. Both flips fire only when the
  comment's Status is still interim (🚀), so a terminal Status is never clobbered and an
  auto-resume in flight is untouched. A `💥 Failed` workpad also gates non-clean in the weekly
  retrospective, so dead implement runs stop masquerading as clean. (#356)
