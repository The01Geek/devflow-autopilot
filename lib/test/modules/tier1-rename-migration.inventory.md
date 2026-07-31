# Tier-1 rename/migration contract module inventory

This inventory records the provenance of the focused Tier-1 rename/migration contract
module (issue #1002). It is a navigation aid, not a second source of behavior:
`tier1-rename-migration.sh` owns the executable assertions, and the complete suite
calls the same module through `module-harness.sh`'s `devflow_run_full_suite_module`
boundary.

Source baseline: `f3c6dac8` (`origin/main` before issue #1002).

Unlike the issue-#591 extractions, this module was **authored with the change** rather
than lifted out of `lib/test/run.sh` — its subjects (`lib/rename-map.json`,
`lib/resolve-state-dir.sh`, `lib/state_dir.py`, `scripts/migrate-consumer-tier1.sh`,
and the new arms in `scripts/config-get.sh` and `scripts/scaffold-config.sh`) did not
exist at the baseline, so there is no former `run.sh` region to map back to.

| Contract group | Subject | Representative contract |
| --- | --- | --- |
| Rename map is the single source | `lib/rename-map.json` | the map declares exactly the seven superseded top-level keys and a four-member atomic unit; both state-directory resolvers agree with it *and* with each other, so the shell/python pair is enforced rather than asserted |
| Shipped config vocabulary | `.prflow/config.schema.json`, `.prflow/config.example.json` | no top-level property begins `devflow`; the FROZEN `workflows.{devflow,devflow-review}` sub-keys survive, so the purity assertion cannot be read as licence to sweep them |
| State-directory read-through | `lib/resolve-state-dir.sh`, `lib/state_dir.py` | canonical wins when present; the superseded directory is used ONLY when it alone is present, and every such resolution breadcrumbs the remedy; a fresh repository earns no breadcrumb; a plain file or dangling symlink at the canonical name is not a state directory |
| Superseded-key probe | `scripts/config-get.sh` | an absent new key whose superseded counterpart is present breadcrumbs on both the default path and the exit-1 path; a new key present and holding `""`/`false`/`0`/`null` does NOT — the absent-versus-present-and-empty distinction the resolver structurally could not make; only the first dot-path segment is mapped; the documented exit codes are unchanged |
| Config-key migration + gate | `scripts/scaffold-config.sh` | with the gate satisfied every superseded key is renamed with its value carried across; a stale SHIPPED workflow refuses and names `install.sh --apply`; a stale RETAINED workflow does NOT refuse (the negative control that pins the gated set to the two shipped filenames) and is reported by name on every run |
| Anti-graft guard | `scripts/scaffold-config.sh` backfill | no `prflow_*` key is grafted while its `devflow_*` counterpart is present — asserted on the refusal path and on the jq-unusable path, the two paths where the cooperative migration step did not run |
| Both-present conflict arms | `scripts/scaffold-config.sh` | an example-valued new block loses to the superseded value and is removed; a DIFFERING new block is a deliberate consumer edit, so neither block changes and both operator resolutions are named |
| The atomic unit | `scripts/migrate-consumer-tier1.sh` | a preview writes nothing and is labelled distinctly from an applied run; an apply lands all four members; the migrated tree contains no reference to the superseded vendored path; the staging directory and commit journal are removed |
| **All-or-nothing (load-bearing)** | `scripts/migrate-consumer-tier1.sh` | one arm per member of the atomic unit: block THAT member alone, and the run refuses, names it, and leaves the repository **byte-identical**. Four RED arms if the apply is not transactional — this is what makes "no member can be applied without the others" executable rather than prose |
| Frozen controls over a migrated tree | the migration output | `workflows.{devflow,devflow-review}` survive; the workpad marker VALUE is not rewritten; the workflow FILENAMES are unchanged; a `learnings/` record moves with its bytes intact |
| Per-family fail-loud guard | `.github/workflows/devflow.yml`, `devflow-implement.yml` | the selector is driven over the adversarial shape matrix (present / un-migrated / one-absent / leaves-absent / null-valued / four non-object roots) rather than grep-pinned on its `::error::` literal, because a pin on the message is not coverage of the branch that chooses it |

Every assertion is behavioural — a helper driven file-in/file-out over a fixture
consumer tree and judged on its exit code, its emitted report, and the resulting
BYTES. The module adds **no** wording-only pin, so it sits outside the #375/#666/#810
prohibition and needs no `# structural-pin-ok:` declaration. `_t1_snap`'s fixture-tree
walk carries the `# tree-walk-ok:` declaration required by issue #711's convention; it
is rooted at the module's own `mktemp` root and can never reach the repository tree.

The generic test harness, registry validation, module registration, full-suite
boundary, and module-runner tests stay global so deleting this module cannot also
delete the checks that prove it is selected and executed. The module uses only
`assert_eq` plus its `_t1_*` domain-private helpers — it references no monolith
`lib/test/run.sh` helper.
