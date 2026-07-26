---
bump: patch
---

Close the two actionable residuals deferred from the #781 review loop (PR #846):
add a composed-output assertion for `workpad.py acs --emit-source-token` on a
criteria-bearing fixture (the source-token line followed by the rendered
criteria, the shape Phase 0.4 parses positionally), and add the matching in-fence
`if [ -z "$ISSUE_NUM" ]` guard to both PR-body issue-number derivation fences in
the review engine's Phase 0.4 so a literal execution can no longer clobber a
caller-supplied `--issue` value.
