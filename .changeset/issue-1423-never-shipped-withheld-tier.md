---
bump: patch
---

The never-shipped-workflow lint no longer counts the withheld tier as shipped. Only the installer's workflow copy loop puts a file in a consumer's `.github/workflows/`, so a withheld-tier workflow — which reaches no fresh install and survives only in a repo that installed before the tier was withheld — is now forbidden on the shipped prompt surface like any other never-shipped name, and a finding for one carries a distinguishing provenance clause.

Three shipped bodies that named such a workflow are reworded to name none. The implement skill's cloud-tier workflow impact check now enumerates the workflow files the checkout actually has instead of grepping one hardcoded path, so a checkout without that file reports "check NOT applicable" rather than an empty result a reader could take for "no allowlist gap".
