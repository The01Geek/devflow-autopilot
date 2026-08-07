# NEITHER fixture — enrolled site carries neither the anchor nor the vendored form (issue #1374)

The enrolled presence-predicate call for this file was renamed/removed, so
`discover-deferral-manifests.py --presence-for-pr <this-run's-PR-number>` appears in no leading-token form — this must fail closed (stale inventory),
not pass silently.
