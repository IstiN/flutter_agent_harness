#!/usr/bin/env bash
# Auto-release: bump the patch version, update CHANGELOG.md, commit, tag, push.
#
# Runs in CI on every push to main (the `release` job in
# .github/workflows/ci.yml). The pushed tag triggers the tag-scoped
# integration/publish jobs, so this must push with a PAT (checkout token),
# not GITHUB_TOKEN — GITHUB_TOKEN pushes never trigger downstream runs.
#
# Changelog rules:
# - a curated `## Unreleased` section becomes the new version's notes;
# - otherwise notes are generated from commit subjects since the last tag;
# - a fresh empty `## Unreleased` is appended at the end.
#
# Retries the whole bump from origin/main when another push races it.
set -euo pipefail

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

# Coalescing guards: pub.dev rate-limits publishes (~12/day), so releases are
# capped at one per 2h; runs with nothing new since the last tag are skipped.
git fetch origin main --tags --quiet
last_tag=$(git describe --tags --abbrev=0 origin/main 2>/dev/null || true)
if [ -n "$last_tag" ]; then
  pending=$(git rev-list --count "$last_tag..origin/main")
  if [ "$pending" -eq 0 ]; then
    echo "Auto-release: nothing new since $last_tag, skipping."
    exit 0
  fi
  tag_age=$(( $(date +%s) - $(git log -1 --format=%ct "$last_tag") ))
  if [ "$tag_age" -lt 7200 ]; then
    echo "Auto-release: coalesced — $last_tag is ${tag_age}s old (<2h); $pending commit(s) pending. Next eligible push or the 2h cron will release them."
    exit 0
  fi
fi

for attempt in 1 2 3; do
  git fetch origin main
  git reset --hard origin/main

  current=$(grep '^version:' pubspec.yaml | awk '{print $2}')
  IFS='.' read -r major minor patch <<< "$current"
  next="$major.$minor.$((patch + 1))"
  echo "Auto-release: v$current -> v$next (attempt $attempt)"

  last_tag=$(git describe --tags --abbrev=0 2>/dev/null || true)
  if [ -n "$last_tag" ]; then range="$last_tag..HEAD"; else range="HEAD"; fi
  bullets=$(git log "$range" --pretty='- %s' --no-merges | grep -v '^- chore(release):' || true)
  [ -z "$bullets" ] && bullets="- Maintenance release."

  NEXT="$next" BULLETS="$bullets" python3 - <<'PY'
import os
import re

nxt = os.environ["NEXT"]
bullets = os.environ["BULLETS"].strip()
path = "CHANGELOG.md"
text = open(path, encoding="utf-8").read()
section = f"## {nxt}\n\n{bullets}\n"

m = re.search(r"^## Unreleased[ \t]*$", text, re.M)
if m:
    rest = text[m.end():]
    head = re.search(r"^## ", rest, re.M)
    body = rest[: head.start()] if head else rest
    tail = rest[head.start():] if head else ""
    if body.strip():
        # Curated Unreleased content becomes this release's notes.
        new_section = f"## {nxt}\n" + body.rstrip() + "\n"
    else:
        new_section = section
    text = text[: m.start()] + new_section + ("\n" + tail if tail else "")
else:
    text = text.rstrip() + "\n\n" + section

text = text.rstrip() + "\n\n## Unreleased\n"
open(path, "w", encoding="utf-8").write(text)
PY

  sed -i "s/^version: .*/version: $next/" pubspec.yaml

  git add pubspec.yaml CHANGELOG.md
  git commit -m "chore(release): v$next"
  # Annotated tag: --follow-tags only pushes annotated tags, lightweight
  # ones stay local. --atomic makes main+tag land together or not at all.
  git tag -a "v$next" -m "Release v$next"
  if git push --atomic origin main --follow-tags; then
    echo "Released v$next"
    exit 0
  fi
  echo "Push raced with another commit, rebasing and retrying..."
  git tag -d "v$next" >/dev/null 2>&1 || true
done

echo "Auto-release failed after 3 attempts"
exit 1
