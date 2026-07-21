<!-- devflow:create-issue-ref step=fallback-read-only-sandbox file=skills/create-issue/references/fallback-read-only-sandbox.md start -->

**Step 2 — the derivation artifact.** If the write genuinely fails (e.g. a read-only sandbox) — the delete above fails the same way, which is itself the signal you are in the read-only case — say so in chat and record the derivation inline in your message **as a visible block — the actual derived list, not a bare claim that you derived it** — so it is still observable; never silently skip writing it down. **When the filesystem is read-only, do not trust any on-disk `issue-derivation-<slug>.md` (the failed delete may have left a stale leftover from a prior run); rely solely on the visible inline block as the gate's stand-in.**

**Step 2 / Step 3 — the derivation gate's stand-in.** (If the write itself failed in a read-only sandbox, a **visible block you posted in chat this run containing the full derived Definition of Ready** — the actual list, not a bare claim of having derived it nor a pointer to earlier prose — stands in for the file. "Present" means it is in *this run's* transcript; because later checks run in subsequent turns, on a read-only filesystem re-post that full block in the current turn whenever you reach a check that fires there. A derivation in neither this run's file nor such a visible block means the pass did not run.)

**Step 3.6 — the audit report artifact.** In a **read-only sandbox** the write fails (as the delete does); fall back to a **visible inline-in-chat block** carrying the audit findings and verdict, and — per the Step 2 distrust rule — **do not trust any on-disk `issue-audit-<slug>.md`** (it can only be a stale leftover).

**Step 4 — the presentation gate.** **In a read-only sandbox, rely solely on the visible inline-in-chat audit block re-posted this turn and do not trust any on-disk `issue-audit-<slug>.md`** (it can only be a stale leftover — the same read-only distrust rule the Step 2 gate applies).

<!-- devflow:create-issue-ref step=fallback-read-only-sandbox file=skills/create-issue/references/fallback-read-only-sandbox.md end -->
