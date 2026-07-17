---
bump: patch
type: Added
---

- **Added `assert_count_red_under` — a range-scoped count guard that proves it goes RED under a mutation and cannot pass on a collapsed range.** The count-shaped sibling of `assert_pin_red_under`: it counts ERE matches between START/END anchors, asserts the count satisfies `OP BOUND` on the real file and violates it on the mutated copy, and establishes the measurement independently of the grep anchor gate (the slice `sed`'s own return code) so a missing-tool-mid-pipe zero is never collapsed onto a real value. Each FAIL arm writes a bare `FAIL` plus a distinct cause token on the following line (a two-line verdict protocol served by a new `probe_two_line` probe), and an anchor-collapse mutation cannot masquerade as the operative regression. Ships the primitive plus full self-test coverage of every contract arm; migrates no existing call site (the #480 and #467 A3 hand-rolled anchor siblings stay in place). (#553)
