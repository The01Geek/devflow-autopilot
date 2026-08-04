# NEITHER fixture — enrolled site carries neither the anchor nor the vendored form (issue #1124)

The enrolled load for this file was renamed/removed, so `load-prompt-extension.sh review`
appears in no leading-token form — this must fail closed (stale inventory), not pass silently.
