---
bump: patch
type: Fixed
---

- **`apply-issue-dependencies.py` now names a prerequisite it skipped for outbound
  direction instead of dropping it silently or misdescribing the body.** A
  `## Dependencies` line that reads as an OUTBOUND relation (this issue is the
  prerequisite) is dropped by the recognizer; previously the native-registration
  helper either said nothing at all (the some-dropped-some-kept path) or claimed the
  issue "declares no prerequisites" (the every-entry-dropped path), breaking its own
  no-silent-path contract. The helper now emits an `apply-issue-dependencies.py:`-prefixed
  breadcrumb naming each skipped number and the direction on both paths, and the
  every-entry-dropped summary no longer asserts "no prerequisites" when one was
  skipped for direction. `preflight.py` gains a `dependency_section_scan` accessor
  returning `(found, skipped)`; the existing `dependency_numbers` /
  `dependency_section_numbers` wrappers keep their `list[str]` shape unchanged. (#1268)
