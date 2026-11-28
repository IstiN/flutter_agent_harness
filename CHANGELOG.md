# Changelog

<!-- GENERATED FILE — `dart scripts/gen_changelog.dart --write-changelog`.
     DO NOT HAND-EDIT: the CI changelog guard rejects direct edits
     (gh-2463). Regenerate instead. -->

Per-change entries live in `changelog/entries/` — one Markdown file per
change (`<issue-or-pr>-<slug>.md`, YAML frontmatter `type`/`scope`/`issue`
plus 1–3 user-facing bullet lines). Every PR adds ITS OWN entry file
instead of editing this file, so parallel changes never touch a shared
file (zero merge conflicts by construction). At release time the pending
entries aggregate into the `Unreleased` section below and
`scripts/release_notes.sh` folds them into the release notes; versioned
history lives in `changelog/archive/` (one file per version — the
pre-1.0.506 tail stays in `CHANGELOG_ARCHIVE.md`). Conventions:
`docs/agents/commits-releases.md`.

## Unreleased

- ci(release): the single shared CHANGELOG.md becomes per-change entry
  files — every PR adds its own `changelog/entries/<issue-or-pr>-<slug>.md`
  (zero merge conflicts by construction), `scripts/gen_changelog.dart`
  aggregates them into the release notes at cut time, and CHANGELOG.md is
  now a generated index (hand edits rejected by the CI changelog guard).
  Versioned history moved to `changelog/archive/`.

## Archive index

- [1.0.551.md](changelog/archive/1.0.551.md)
- [1.0.550.md](changelog/archive/1.0.550.md)
- [1.0.549.md](changelog/archive/1.0.549.md)
- [1.0.548.md](changelog/archive/1.0.548.md)
- [1.0.547.md](changelog/archive/1.0.547.md)
- [1.0.546.md](changelog/archive/1.0.546.md)
- [1.0.545.md](changelog/archive/1.0.545.md)
- [1.0.543.md](changelog/archive/1.0.543.md)
- [1.0.542.md](changelog/archive/1.0.542.md)
- [1.0.541.md](changelog/archive/1.0.541.md)
- [1.0.540.md](changelog/archive/1.0.540.md)
- [1.0.539.md](changelog/archive/1.0.539.md)
- [1.0.538.md](changelog/archive/1.0.538.md)
- [1.0.537.md](changelog/archive/1.0.537.md)
- [1.0.535.md](changelog/archive/1.0.535.md)
- [1.0.534.md](changelog/archive/1.0.534.md)
- [1.0.533.md](changelog/archive/1.0.533.md)
- [1.0.532.md](changelog/archive/1.0.532.md)
- [1.0.531.md](changelog/archive/1.0.531.md)
- [1.0.529.md](changelog/archive/1.0.529.md)
- [1.0.528.md](changelog/archive/1.0.528.md)
- [1.0.527.md](changelog/archive/1.0.527.md)
- [1.0.526.md](changelog/archive/1.0.526.md)
- [1.0.525.md](changelog/archive/1.0.525.md)
- [1.0.524.md](changelog/archive/1.0.524.md)
- [1.0.523.md](changelog/archive/1.0.523.md)
- [1.0.522.md](changelog/archive/1.0.522.md)
- [1.0.521.md](changelog/archive/1.0.521.md)
- [1.0.520.md](changelog/archive/1.0.520.md)
- [1.0.518.md](changelog/archive/1.0.518.md)
- [1.0.517.md](changelog/archive/1.0.517.md)
- [1.0.516.md](changelog/archive/1.0.516.md)
- [1.0.515.md](changelog/archive/1.0.515.md)
- [1.0.514.md](changelog/archive/1.0.514.md)
- [1.0.513.md](changelog/archive/1.0.513.md)
- [1.0.511.md](changelog/archive/1.0.511.md)
- [1.0.510.md](changelog/archive/1.0.510.md)
- [1.0.509.md](changelog/archive/1.0.509.md)
- [1.0.508.md](changelog/archive/1.0.508.md)
- [1.0.507.md](changelog/archive/1.0.507.md)
- [1.0.506.md](changelog/archive/1.0.506.md)
- [legacy-unreleased.md](changelog/archive/legacy-unreleased.md)
