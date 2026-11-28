---
type: ci
scope: release
issue: 2463
---

- ci(release): the single shared CHANGELOG.md becomes per-change entry
  files — every PR adds its own `changelog/entries/<issue-or-pr>-<slug>.md`
  (zero merge conflicts by construction), `scripts/gen_changelog.dart`
  aggregates them into the release notes at cut time, and CHANGELOG.md is
  now a generated index (hand edits rejected by the CI changelog guard).
  Versioned history moved to `changelog/archive/`.
