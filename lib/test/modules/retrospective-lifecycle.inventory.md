# retrospective-lifecycle.sh — extracted-coverage inventory

Issue #788. This module owns the executable coverage for the retrospective
issue-closure lifecycle: the reconciler (`lib/pattern-state.sh`), the v2 overrides
migration, the status arms of `lib/compute-patterns.jq`, the number-keyed
lifecycle write in `lib/meta-issue.sh`, the regressed occurrence-threshold bypass
and the liveness warning in `lib/actionable-patterns.sh`, and the filing decisions
and report-field producers in `lib/filing-decisions.sh`.

| Contract group | Former `lib/test/run.sh` location | Now |
| --- | --- | --- |
| `compute-patterns.jq` status derivation (open / fixed / regressed / dismissed, slug normalization, occurrence grouping) | `lib/test/run.sh` `compute-patterns.jq` block **and** the non-adjacent status-arm group that sat after the config-jq block | **Relocated into this module**, together with the `declined`/`filed`/precedence/canonicalization arms #788 introduced. |
| `meta-issue.sh` lifecycle write, de-dup, `--dry-run`, URL-shape and `--slug` grammar guards | `lib/test/run.sh` `meta-issue.sh` block | **Relocated into this module**, together with the number-keyed single-entry assertion. |
| `pattern-state.sh` migrate + reconcile transitions | new (issue #788) | This module (no former home — the helper is new). |
| `actionable-patterns.sh` regressed bypass + liveness warning | new (issue #788) | This module (the bypass and the liveness diagnostic are new behavior). |
| `filing-decisions.sh` cap arms + arm order + fail-closed operands + the two cap comparands and the no-shell-options-leak contract of the sourced helper; liveness capture, won't-fix re-raise, per-pattern annotation; end-to-end render of every report section | new (issue #788) | This module (the helper is new — it is the executable owner of decisions that were previously Step 8c/9 prose). |

## What deliberately stayed in `lib/test/run.sh`

The two repo-wide tracked-surface prose guards that used to sit under the
`compute-patterns.jq` section header — the `#129` removed-slug lockstep scan and
the `#412` `config.json`-tracking claim scan — are **not** `compute-patterns.jq`
coverage. Each `git grep`s every tracked file in the repository, so neither
belongs to this module's ownership set in `coverage-map.json`; both remain in the
monolith under their own section header.

Three further blocks stay in `lib/test/run.sh` for the same reason — they are not
coverage of an owned file's *behavior*, so `coverage-map.json` ownership of that
file does not imply they should move:

- the **`clean-entry.jq` / `actionable-patterns.sh`** section, whose subject is
  `clean-entry.jq` — a file this module does **not** own — with the
  `actionable-patterns.sh` assertions beside it exercising the same clean-gate
  pipeline end-to-end rather than the lifecycle behavior extracted here;
- the **`#152`/`#228` `meta-issue.sh` pins**, which are cross-file *wiring*
  contracts (the orchestrator invokes the helper; label application routes
  through the REST helpers rather than porcelain), not lifecycle-write behavior;
- the **`#152` orchestrator blocker-recording** assertions, whose subject is
  `skills/retrospective-weekly/SKILL.md`'s failure handling.

Ownership in `coverage-map.json` names who owns a file's *lifecycle* coverage;
these three keep assertions whose subject is a different file or a cross-file
contract, and moving them would put a `clean-entry.jq` or SKILL.md assertion
under a module named for the lifecycle.

## Line-count evidence (AC)

The reduction is evidenced in **the PR description and the diffstat**, not by an
assertion in this module.

An earlier revision asserted it here, comparing `lib/test/run.sh`'s line count
against `merge-base(origin/main, HEAD)`. That assertion was **self-invalidating**:
after this change merges, any later branch's merge-base already contains the
reduction, so before == after and the assertion would be RED on `main` forever —
failing the required `lib + python tests` check for every subsequent PR. It also
asserted a property of *this diff* rather than of the product, which is not what
a permanent suite is for.

If a durable guard is ever wanted, it must be a checked-in **ceiling pin** — the
issue-#656 enforcement-constant exception, where the literal *is* the enforcement
— never a comparison against a moving base ref.
