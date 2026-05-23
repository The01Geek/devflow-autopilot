# Handoff — Bash + jq dependency elimination (resume notes)

**Branch:** `refactor/bash-jq-only-deps`
**Date paused:** 2026-05-22
**Goal:** Remove all Python/PyYAML **and** Node from devflow so the only runtime deps are `bash + git + gh + jq` (all already required today).
**Full task plan (gitignored, local only):** `docs/superpowers/plans/2026-05-22-bash-jq-deps.md`

This file is WIP scaffolding; delete it before merging the branch.

---

## Decision recap (why we're doing this)

- Claude Code's **native installer** (now the recommended default) bundles **no Node** and puts only the `claude` binary on PATH — so the old "node is guaranteed" assumption was false for native-installer users.
- `jq` is **already a hard dependency** (fetch-pr-context.sh, actionable-patterns.sh, the `.jq` files) and covers JSON **and** date math (`now`/`gmtime`/`strftime`/`fromdateiso8601`).
- Prior art (lefthook vs husky, jq) says the winning adoption pattern is "no language runtime to provision"; for a text-distributed plugin that means **bash + jq**, not a compiled binary.
- End state target: `bash + git + gh + jq` only. The lone PyYAML user (`match-deferrals.py`) is removed by switching the PR-body deferred-findings block from a YAML fence to a **JSON** fence (jq-native).

## Hard constraints (apply to ALL remaining work)

1. **Portability contract** (`lib/preflight.sh` states it): NO GNU-only flags.
   - No `grep -P` / PCRE lookarounds → use POSIX ERE (`grep -E`) or awk.
   - No gawk 3-arg `match(s, re, arr)` → use 2-arg `match()` + `RSTART`/`RLENGTH`/`substr` (the 3-arg form crashes mawk/BSD awk; CI ubuntu `awk` is mawk).
   - `sed -E` not `sed -r`; no `date -d`, no `readlink -f`.
   - All JSON via `jq`; structured/markdown text via awk, not fragile sed.
2. **`jq` strftime needs UTC**: use `now | gmtime | strftime(...)` (not bare `now | strftime`) to match Python's `datetime.now(UTC)`.
3. **CI job-name trap**: the workflow job named **`lib + python tests`** is the *protected required status check* (ruleset 16652954). Do **NOT** rename it in this branch or PRs wedge forever ("Expected — waiting for status"). Rename only later in a coordinated ruleset+workflow change. (Task 8.4.)
4. **Keep `bash lib/test/run.sh` green after every task** (currently `236 passed, 0 failed`). Run a **py-vs-sh parity gate** for every script port before trusting it.
5. **Per-task commit** workflow is authorized **for this migration only** (normal rule: don't auto-commit). Pattern used: implementer commits, review fixes folded via `git commit --amend`.

---

## Progress — 12 of 23 tasks DONE & committed

Commits on branch (newest first):
```
f5bc272 refactor(implement): port file-deferrals to bash + jq
ba02cb4 refactor(implement): port parse-acs to bash + awk
ec11164 refactor(implement): port branch-for-issue to bash
712492c refactor(diff): noise elision via awk not python3
839454a refactor(lib): date math via jq not python3
bdcf244 ci(actions): read-project-config validates via jq not node
cb3b209 refactor(config): drop node fallback in scaffold-config
87fbc04 refactor(config): replace node resolver with jq getpath
d484d6e chore: gitignore superpowers plan dir
```

- **Phase 1 — Node eliminated:** `config-get.sh` (node→jq `getpath`), `scaffold-config.sh` (node fallback dropped), `read-project-config` action (node→`jq -c`). No Node left in committed code except the `setup-project-env` action's *generic* provisioning (intentionally kept for adopter projects; devflow's own `node_version` will be blanked in Task 8.5).
- **Phase 2 — lib-layer Python eliminated:** date math in `scan.sh`/`actionable-patterns.sh`/`fetch-pr-context.sh ttm_hours` → jq (UTC-correct); diff-trim → shared **`lib/diff-trim.awk`** (unified the two call sites on the production marker).
- **Phase 3 — `branch-for-issue.py` → `.sh`:** exact py↔sh parity across the realistic domain. Fixed in review: local-vs-UTC date, whitespace strip, both-sources→exit 2, iconv double-emit. Unicode note: `iconv //TRANSLIT` ≠ Python NFKD for exotic symbols (½, ×, →) — accepted as cosmetic (slug is just a deterministic branch name).
- **Phase 4 — `parse-acs.py` → `.sh`:** full md+json parity. Fixed in review: replaced `grep -P` word-boundary with awk POSIX-ERE; dropped gawk-only 3-arg `match()`. POST_MERGE_TRIGGERS copied verbatim.
- **Phase 5 — `file-deferrals.py` → `.sh`:** sha256 ids match Python exactly, issue-body byte-identical, atomic manifest rewrite verified with a fake `gh`, guards (existing-follow_up / bad-schema) → exit 2, dry-run network-free.

Bash test harness `lib/test/test_scripts.sh` accumulates per-script tests (`test_config_get`, `test_branch_for_issue`, `test_parse_acs`, `test_file_deferrals`). It is **not yet wired into `run.sh`** (that's Task 8.3; today it's run directly and `run.sh` still runs the Python tests).

---

## CURRENT WIP — Task 6 (workpad) — committed as WIP, NOT done

Files committed in the WIP commit but **not yet correct/finished**:
- `scripts/workpad.sh` (all subcommands present: id/body/patch/create/now/update; `--dry-print` test seam exists; `now` works; shellcheck clean)
- `lib/workpad-sections.awk` (section model: split/find/set/insert/tick/rewrite/append)
- `lib/test/fixtures/workpad-gh-stub.sh`, `lib/test/fixtures/WORKPAD-prcomments.json` (test fixtures)

Still TODO for Task 6: add `test_workpad` to `test_scripts.sh`, fix the bugs below, re-run parity, flip remaining skill refs, finalize.

### Parity-gate findings (RUN the gate before trusting anything)

Using a **corrected** gh stub that honors `--jq .body`, most `update` mutations already match Python (`tick-plan` batch, `tick-ac`, `note`, `rewrite-ac`, `reflection`) and dup-tick atomicity works (exit 1, no partial). Two real bugs + one harness bug remain:

1. **BUG (real, must fix) — sed delimiter injection in front-matter mutations.**
   `scripts/workpad.sh` cmd_update does the `**Status:**` / `**Branch:**` / `**Last updated:**` replacements with `sed -E "s/.../\1 ${value}/"` using `/` as the delimiter. A value containing `/` — e.g. `--branch feat/new` (branch names routinely contain `/`!) — produces `sed: unknown option to 's'`. Values with `&`, `\` would also corrupt the replacement.
   **Recommended fix:** do the three front-matter line replacements **in awk** (literal string replacement, count=1, error if the line is absent) — consistent with the rest of the mutation logic and immune to delimiter/metachar injection. Python used `re.subn` with a *literal* replacement string, so it had no such issue; the awk port should match that. (Lines ~242–274 of workpad.sh.)

2. **BUG (minor) — missing trailing newline.** Python `_apply_mutations` / `_join_sections` ends the body with `\n`; the bash `--dry-print` / join output omits the final newline (`\ No newline at end of file` in every diff). Fix the join (or dry-print) to emit a trailing `\n`.

3. **TEST-HARNESS BUG — `workpad-gh-stub.sh` ignores `--jq`.** Its single-comment branch returns the whole JSON object `{"id":...,"body":"..."}` instead of honoring `gh api ... --jq .body` (which real gh applies, returning the raw body). With the committed stub, `workpad.sh` runs `sed` against JSON and every front-matter mutation reports "Status line not found". Fix the stub so the `issues/comments/<id>` branch returns just the body string when `--jq .body` is present (real-gh behavior). Otherwise `test_workpad` will test against JSON, not markdown.

### Reusable parity harness (paste to resume)

```bash
cd /home/natprog/devflow-autopilot
BODY=$(mktemp); cat >"$BODY" <<'EOF'
<!-- devflow:workpad -->
# DevFlow Workpad — Issue #99

**Status:** Implementing
**Branch:** `feat/test`
**Last updated:** 2026-05-15T00:00:00Z

## Plan
- [ ] Step alpha
- [ ] Step beta
- [ ] Step gamma

## Acceptance Criteria
- [ ] AC one
- [ ] AC two

## Decisions / Notes

## Devflow Reflection
EOF
STUBDIR=$(mktemp -d)            # corrected stub: HONORS --jq .body like real gh
cat >"$STUBDIR/gh" <<EOF
#!/usr/bin/env bash
B=\$(cat "$BODY"); A="\$*"
printf '%s' "\$A" | grep -q "repo view" && { echo "acme/example-repo"; exit 0; }
printf '%s' "\$A" | grep -qE "issues/comments/[0-9]+" && { printf '%s' "\$B"; exit 0; }
printf '%s' "\$A" | grep -qE "issues/[0-9]+/comments" && { printf '%s' "\$B" | jq -Rs '[{"id":9001,"body":.}]'; exit 0; }
printf '%s' "\$A" | grep -qE '\-X[[:space:]]+PATCH' && { for a in \$A; do [ "\$p" = "-F" ] && { f="\${a#body=@}"; cat "\$f"; exit 0; }; p="\$a"; done; }
echo "[]"; exit 0
EOF
chmod +x "$STUBDIR/gh"
norm() { sed -E 's/\*\*Last updated:\*\* .*/**Last updated:** NORM/'; }   # normalize the always-changing timestamp
pyapply() { python3 - "$BODY" "$1" <<'PY'
import importlib.util,sys,types
spec=importlib.util.spec_from_file_location("wp","scripts/workpad.py");wp=importlib.util.module_from_spec(spec);spec.loader.exec_module(wp)
body=open(sys.argv[1]).read()
ns=types.SimpleNamespace(status=None,branch=None,tick_plan=[],tick_ac=[],rewrite_ac=None,note=[],reflection=[],replace_plan_file=None,replace_acs_file=None,set_reproduction_file=None)
exec("ns."+sys.argv[2]);sys.stdout.write(wp._apply_mutations(body,ns))
PY
}
shapply() { PATH="$STUBDIR:$PATH" scripts/workpad.sh update 99 --dry-print "$@" 2>&1; }
# Example: diff <(pyapply "status='Done';ns.branch='feat/new'"|norm) <(shapply --status Done --branch feat/new|norm)
```
Cover at least: `status+branch` (esp. a branch WITH a slash, e.g. `claude/issue-1-x`), tick batch, tick-ac, note, rewrite-ac, reflection, replace-plan-file, set-reproduction insert-after-AC, and the dup-tick→exit-1 atomicity case.

---

## Remaining tasks (7 → 23)

- **7.1** Switch the PR-body deferred-findings block from a ```` ```yaml ```` fence to ```` ```json ````. Find writers/describers: `grep -rn 'DEVFLOW_DEFERRED_FINDINGS' skills/ scripts/ lib/`. Update `skills/review/SKILL.md` prose. (This is what removes the last PyYAML need.)
- **7.2** Port `match-deferrals.py` → `scripts/match-deferrals.sh` (bash + jq). Logic is JSON-in/JSON-out: extract block between `DEVFLOW_DEFERRED_FINDINGS_START/END`, parse the JSON fence with jq, three guards (trusted-filer via `.claude.allowed_bots`; cross-link via per-issue `gh issue view` collected into a jq `--argjson` map; widens-surface via awk diff-hunk parse), match rule (same file+kind, line_range overlap ±25), emit the documented result JSON. **Reason-code strings must stay verbatim** (mirrored in `skills/review/SKILL.md`). Exit 0 always when it ran; 2 on bad args. Test with a gh stub (no network).
- **8.1** Delete Python: confirm zero `.py` refs in skills/commands/lib/scripts/.github (`grep -rn '\.py\b'`), then `git rm` the 5 scripts + `lib/test/test_python_scripts.py` + `requirements.txt`.
- **8.2** `lib/preflight.sh`: drop the `python3`/PyYAML checks; header → "git, gh, jq" only.
- **8.3** `lib/test/run.sh`: replace the `python3 .../test_python_scripts.py` invocation (~line 794) + its summary parse with `bash .../test_scripts.sh`; ensure `test_scripts.sh` prints the `N passed, M failed` line run.sh greps.
- **8.4** `.github/workflows/ci.yml`: remove setup-python + PyYAML (test job) and setup-python + ruff (lint job). **KEEP job name `lib + python tests`** (see constraint #3); add a TODO noting the deferred rename.
- **8.5** Blank devflow's own `setup` block (`python_version`/`node_version`/`install`) in `.devflow/config.json` + `config.example.json`; update `config.schema.json` deprecation notes; verify `setup-project-env` `if: != ''` guards short-circuit on empty.
- **8.6** Docs: `grep -rn -i 'python\|pyyaml\|node \|requirements.txt' docs/ README* skills/*/SKILL.md` → update to "bash + git + gh + jq" (incl. `docs/cloud-setup.md`).
- **9** Verification: grep shows no `python3`/`PyYAML`/`node -e` remain; no `.py`/`requirements.txt`; `bash lib/preflight.sh` + `bash lib/test/run.sh` green; shellcheck + actionlint clean; **run a representative flow in a PATH with no python3 and no node** (only git/gh/jq) — that's the actual adoption claim.

## Process notes / lessons

- Subagent-driven: implementer (sonnet) per script, then an independent review subagent for the substantive ports. Reviews caught real bugs every time (grep -P, gawk 3-arg match, sed delimiter, date tz). **Keep reviewing the ports.**
- The workpad implementer subagent **timed out** mid-task (API stream idle) — that's why Task 6 is partial. Re-dispatch a fresh subagent scoped to "fix the 3 documented bugs + write test_workpad + parity-gate + flip refs", not a from-scratch rewrite.
- Mechanical one-site swaps (Phases 1–2) were done directly (no subagent) and verified against the existing `run.sh` suite — fine to continue that for the cleanup tasks (8.1–8.6).
