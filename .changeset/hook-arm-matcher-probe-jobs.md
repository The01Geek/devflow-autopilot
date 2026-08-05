---
bump: patch
type: Added
---

- **Three new `matcher-probe.yml` jobs measure the cloud harness's hook surface.**
  `permissionrequest-probe` registers a `PermissionRequest`/`Bash` hook that records the
  tool input it saw and denies with a distinctive message, and brackets the ungranted
  command between two GRANTED control commands — so the run establishes not only whether
  the event fires but **which** calls reach it (the published permission order does not
  place `PermissionRequest` anywhere, and a hook that sees calls the allowlist would have
  approved is a very different thing from one that sees only what the allowlist declined),
  and a session that silently declines to issue the ungranted command is reported as such
  rather than as an ambiguous negative. `pretooluse-deny-probe` emits a real `deny` with a sentinel reason
  on a sacrificial command, measuring deny-path reason delivery — an axis the existing
  allow-only `pretooluse-probe` structurally cannot answer, since
  `permissionDecisionReason` is specified to be ignored on an `allow`. `defer-probe`
  settles whether a `defer` falls through to the default permission flow, the
  unestablished premise `scripts/pretooluse-shape-guard.py` records in its own header.
  All three additionally measure whether a **hook-issued** deny still appears in
  `permission_denials`, and record the observed CLI version beside the run id so a verdict
  cannot silently outlive the `@v1` action ref it was taken on. Unlike the older probe
  jobs they pass no `--permission-mode`, matching both live tiers.
- Verdicts are rendered by three suite-driven helpers —
  `scripts/describe-permissionrequest-probe.sh`,
  `scripts/describe-pretooluse-deny-probe.sh`, `scripts/describe-defer-probe.sh` — over
  the shared execution-file readers in `lib/probe-observation.sh`. Each verdict is
  breadcrumb-first (derivable from a truncated run, and on the `defer` arm from a run
  whose execution file a honored defer destroyed), and each keeps an established negative
  distinct from `unavailable`. Measurement only: no production behavior changes.
