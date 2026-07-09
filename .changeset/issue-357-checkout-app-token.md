---
bump: patch
type: Fixed
---

- **Cloud writers now actually push under the configured GitHub App, so `/devflow:implement`
  and `/devflow:review-and-fix` can finally land `.github/workflows/` changes.** The push
  credential is the one `actions/checkout` persists — **not** the `github_token` handed to
  `claude-code-action`. `actions/checkout@v6` stopped writing its auth header into
  `.git/config` and now writes `http.<server>/.extraheader` to an external config file wired
  in via `includeIf.gitdir:` (covering `.git/worktrees/*`), so `claude-code-action`'s
  `git config --unset-all http.<server>/.extraheader` — which searches only `.git/config` —
  clears nothing, and the surviving preemptive `Authorization:` header outranks the App token
  that action embeds in `origin`'s URL. Every push in both writer jobs therefore
  authenticated as `github-actions[bot]`, a GitHub App holding no `workflows` permission:
  ordinary pushes succeeded and only `.github/workflows/` pushes died with `refusing to allow
  a GitHub App to create or update workflow … without workflows permission`, which is why the
  failure was repeatedly misread as a missing App permission. The writer mint now runs
  **before** `actions/checkout` in `devflow-implement.yml`'s `claude` job and `devflow.yml`'s
  `command` job, and is passed to it as
  `token: ${{ steps.app-token.outputs.token || secrets.GITHUB_TOKEN }}` — mirroring
  `version-consolidate.yml`, the one job that already did this and the only one whose pushes
  were correctly attributed to `devflow-autopilot[bot]`. Unset-App behavior is byte-for-byte
  unchanged (mint skipped → `GITHUB_TOKEN`, which is also checkout's own default), and on a
  `/devflow:review` command the writer mint stays skipped so the checkout falls back to
  `GITHUB_TOKEN` rather than receiving the read-only `DevFlow-Reviewer` token — preserving the
  #300 review-identity split. `lib/test/run.sh` pins both halves per pushing job (mint
  precedes checkout; checkout consumes the app token with the `GITHUB_TOKEN` fallback; the
  reviewer token is never a checkout credential), each mutation-checked RED against the
  pre-fix layout. `docs/cloud-setup.md` documents why the checkout token, not `github_token`,
  is the push credential. (#357)
