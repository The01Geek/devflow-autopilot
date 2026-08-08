---
bump: patch
---

The never-shipped-workflow lint no longer counts the withheld tier as shipped. Only the installer's workflow copy loop puts a file in a consumer's `.github/workflows/`, so a withheld-tier workflow — which reaches no fresh install and survives only in a repo that installed before the tier was withheld — is now forbidden on the shipped prompt surface like any other never-shipped name. `DEVFLOW_WITHHELD_TIER` is no longer read by the lint at all, leaving the installer's own removal machinery as its single reader.

Three shipped bodies that named such a workflow are reworded to name none. The implement skill's cloud-tier workflow impact check now scans the repo's own workflow directory and the vendored copy as separate families instead of grepping one hardcoded path, so an absent family reports "check NOT applicable" for itself rather than being hidden behind the other family's result.
