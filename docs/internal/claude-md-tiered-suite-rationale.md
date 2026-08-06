# Tiered suite-running — maintainer rationale relocated from `CLAUDE.md` (issue #1352)

This page holds maintainer rationale and deep coordinator mechanics that were relocated out of
`CLAUDE.md`'s tiered suite-running bullet (the local/interactive-tier item of the "Running the
suite when the `bash <path>` wrapper above is denied" ladder) under the issue #1352 placement
audit's preserve-and-relocate rule (AC5). The **operative** statement of the policy is
single-sourced in the three prompt extensions
(`.prflow/prompt-extensions/{implement,review-and-fix,receiving-code-review}.md`), and the
`CLAUDE.md` bullet is their compact coupled mirror. Nothing links here from either loaded
surface; this record is discoverable by search and git history.

## Parallel coordinator internals (`lib/test/run-parallel.sh`, issue #1086)

The final full-suite command on the local/interactive tier is the parallel coordinator
`lib/test/run-parallel.sh`. It derives CI's own shard population from
`lib/test/run-shard.sh --list-shards`, runs it concurrently in this checkout, recombines it
through `lib/test/shard-tally.py`, retains every launched shard's complete log under an ignored
run root (so the caller composes no redirect of its own), and prints one compact aggregate
capped per detail class by its own `DETAIL_CAP` constant. The cloud tiers invoke it as a direct
leading token with nothing around it; the local/interactive tier invokes it through the
`DEVFLOW_BASH` invocation boundary. `lib/test/run.sh` stays the serial primitive the `monolith`
shard runs and the uncovered-surface fallback names.

## `monolith`-shard mid-iteration instrument (issue #1253)

Mid-iteration on a tier where the coordinator meaningfully exceeds a single shard (the cloud
implement tier, measured), the `monolith` shard may stand in for the whole suite on a
`run.sh`-resident surface via `lib/test/run-shard.sh monolith`. It never discharges the
completion gate. The operative statement, its four limits, and the AC1 tier measurement are
single-sourced in the three prompt extensions.

## Diagnosing a failing full suite

When the full suite fails, read its terminal `Failure recap` (#789) from the stderr-merged
capture rather than relaunching. A mid-iteration `#434` stale-prose skip on a dirty tree is
expected and clears on commit — never re-run the full suite solely to clear it. The exec bit is
necessary but not sufficient for the leading-token retry — the leading-token form must also be
permitted on the tier.

## Wall-clock is not CI's

The coordinator's `real` time is not CI's: CI isolates each shard on its own runner, while the
coordinator's shards share one host's CPU/memory/checkout/process namespace, so its wall-clock
is the slowest shard *under contention*, not the slowest runner.

## Why the local run stays authoritative

The local run stays the authoritative local signal because its failure detail is richer than
CI's for troubleshooting. The `#456` skip accounting is unchanged: a nonempty skip tally is not
clean, and a focused module may not self-skip.
