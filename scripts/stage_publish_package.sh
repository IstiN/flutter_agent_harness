#!/usr/bin/env bash
# Stage the publishable package surface into /tmp/publish-stage (#571, #597).
# Single staging source of truth: the tag-time publish job (ci.yml) and the
# PR-time static-leg dry-run both call this, so what dry-runs on a PR is
# byte-for-byte the tree `dart pub publish --force` ships. Operates on the
# repo root (parent of this script's directory); run from anywhere.
set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p /tmp/publish-stage
rsync -a ./ /tmp/publish-stage/ \
  --exclude '.git' --exclude '.github' --exclude '.worktrees' \
  --exclude 'flutter_app' --exclude 'browser_ext' \
  --exclude 'office_addin' --exclude 'yoclip' \
  --exclude 'vendor' --exclude 'docs' --exclude 'fa-local' \
  --exclude 'packages' \
  --exclude '.dart_tool' --exclude 'build' --exclude '.fah' \
  --exclude 'memory' --exclude '.trash'
size=$(du -sm /tmp/publish-stage | cut -f1)
echo "staged package: ${size} MB"
if [ "$size" -gt 90 ]; then
  echo "::error::staged package is ${size} MB (>90) — pub.dev caps uploads at 100 MB. Trim the staging excludes."
  exit 1
fi
(cd /tmp/publish-stage && dart pub get)
