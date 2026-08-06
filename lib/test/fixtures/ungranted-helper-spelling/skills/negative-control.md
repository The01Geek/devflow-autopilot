<!-- The AC4 combined negative control: all three forms below PASS the lint. -->

(a) The granted invocation form is the vendored literal:
`.prflow/vendor/prflow/scripts/post-review-verdict.sh "$PR_NUMBER" "REJECT" body.md "$SHA" "$MARKER"`
and the dismissal `.prflow/vendor/prflow/scripts/dismiss-stale-rejections.sh "$PR_NUMBER"`.

(b) A sentence that merely names the helper uses its bare filename: the emitter
`post-review-verdict.sh` stamps the verdict marker, and `dismiss-stale-rejections.sh`
clears a stale REJECT.

(c) Ordinary English prose containing the word "scripts": these scripts are shell
scripts, and the scripts directory holds many such scripts.

The portable source anchor also passes:
`"${CLAUDE_SKILL_DIR:-...}"/../../scripts/post-review-verdict.sh` is the #275 form.
