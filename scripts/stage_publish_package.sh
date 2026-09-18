#!/usr/bin/env bash
# Stage the publishable package into a target directory (issue #597).
#
# `dart publish` packs everything under the repo root that isn't
# gitignored — and the root hosts sub-projects that are NOT part of the
# pub package (flutter_app with its 57 MB wasm toolchain, yoclip media,
# browser_ext, office_addin, vendored forks, docs, packages/*). That
# blew the archive past pub.dev's hard 100 MB cap (v0.1.406: 100.4 MB).
#
# The staged copy carries the package surface (~32 MB) plus the two PATH
# dev-dependencies (packages/fa_llm_mock, vendored vendor/xterm —
# accepted by pub.dev since v0.1.369). pubspec_overrides.yaml (the
# local-only dart_tui vendor pin, "never ships to pub.dev" by its own
# comment) must NOT enter the stage: version solving would re-pin the
# path dep and fail (the v0.1.407 failure, exit 66).
#
# Usage: stage_publish_package.sh <target-dir>
# Exits non-zero (with ::error) when the staged tree exceeds the guard.
# The repo root hosts sub-projects that are NOT part of the pub package
# (flutter_app, yoclip, browser_ext, office_addin, vendored forks, docs)
# — `dart publish` packs everything under the root that isn't gitignored
# (v0.1.406: 100.4 MB, over pub.dev's hard cap). Stage the package
# surface instead. PATH dev-deps of the core pubspec must resolve inside
# the stage (#584, `dart pub get` exit 66 on v0.1.407): their subtrees
# are included BEFORE the parent excludes, and the parent excludes are
# child-scoped (vendor/*) — excluding the parent dir itself would prune
# the subtree before the includes are ever consulted.
# pubspec_overrides.yaml is the workspace-only dart_tui pin (never
# published, see its header); shipped into the stage it re-dangles
# dart_tui onto the excluded vendor dir.
set -euo pipefail

target="${1:?usage: stage_publish_package.sh <target-dir>}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mkdir -p "$target"
# Root-scoped excludes are ANCHORED: rsync matches an unanchored name
# against the basename at ANY depth — `memory` also pruned lib/src/memory/,
# shipping v0.1.411 with broken memory imports (issue #613). build/ and
# .dart_tool stay unanchored: build artifacts may appear at any depth and
# never belong in the stage.
rsync -a "$repo_root"/ "$target"/ \
  --include 'vendor/xterm/' --include 'vendor/xterm/**' \
  --include 'packages/fa_llm_mock/' --include 'packages/fa_llm_mock/**' \
  --exclude '/.git' --exclude '/.github' --exclude '/.worktrees' \
  --exclude '/flutter_app' --exclude '/browser_ext' \
  --exclude '/office_addin' --exclude '/yoclip' \
  --exclude 'vendor/*' --exclude '/docs' --exclude '/fa-local' \
  --exclude 'packages/*' \
  --exclude '/pubspec_overrides.yaml' \
  --exclude '.dart_tool' --exclude 'build' \
  --exclude '/memory' --exclude '/.trash' --exclude '/coverage'

size=$(du -sm "$target" | cut -f1)
echo "staged package: ${size} MB"
if [ "$size" -gt 90 ]; then
  echo "::error::staged package is ${size} MB (>90) — pub.dev caps uploads at 100 MB. Trim the staging excludes."
  exit 1
fi
