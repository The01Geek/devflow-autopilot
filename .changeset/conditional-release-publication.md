---
bump: patch
type: Changed
---

- Version bumps now publish a GitHub Release only for `minor` and `major` bumps; a `patch` bump still gets its annotated tag. Publishing a Release emails every watcher subscribed to Releases, and patch merges were landing several times a day. Tagging is unchanged, so pinned install URLs keep resolving and reproducibility is unaffected — only the announcement is conditional. `scripts/consolidate-changesets.py` gained an `--emit-bump-to` side channel reporting the computed highest pending bump, and `scripts/publish-release.sh` gained a `--release minor-major` mode plus `--bump`; an unestablished bump kind fails loud rather than being read as `patch`. The install docs no longer link `releases/latest` (which names the newest *Release*, not the newest tag). (#970)
