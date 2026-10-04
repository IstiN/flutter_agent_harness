#!/usr/bin/env bash
# Auto-release: bump the patch version, update CHANGELOG.md, push straight to
# protected main as the fa-release-bot GitHub App (gh-1172).
#
# Runs in CI on every push to main / the 2h catch-up cron / manual dispatch
# (the `release` job in .github/workflows/ci.yml). The job authenticates via
# actions/create-github-app-token (RELEASE_APP_ID + RELEASE_APP_PRIVATE_KEY);
# the App is the ONLY bypass actor on the main ruleset, so the bump commit
# pushes directly — no release PR, no machine review round-trip, no CI queue
# burn on a chore change. The tag + GitHub Release are still cut from the
# pushed 'chore(release):' commit by scripts/tag_release.sh (the `release-tag`
# job), riding the same App token so the tag-scoped binaries/publish jobs fire.
#
# Dry-run: RELEASE_DRY_RUN=1 (or "true") computes and commits the bump locally,
# logs the exact commit + tag that WOULD land, and skips the push.
#
# Changelog rules:
# - a curated `## Unreleased` section becomes the new version's notes;
# - otherwise notes are generated from commit subjects since the last tag;
# - a fresh empty `## Unreleased` is appended at the end (once — repeated runs
#   must not stack duplicates).
#
# Main-race honesty (E1): the push is fast-forward-only; a main that moved
# during the run rejects it and the retry loop re-computes from the fresh
# origin/main — never a blind push over new commits.
set -euo pipefail

# Commit authorship names the App so release commits are attributable in
# history (auditability contract, gh-1172).
git config user.name "fa-release-bot[bot]"
git config user.email "fa-release-bot[bot]@users.noreply.github.com"

dry_run=0
case "${RELEASE_DRY_RUN:-0}" in 1|true|yes) dry_run=1 ;; esac

# Coalescing guards: pub.dev rate-limits publishes (~12/day), so releases are
# capped at one per 2h; runs with nothing new since the last tag are skipped.
git fetch origin main --tags --quiet
last_tag=$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
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

# If the previous bump pushed but its tag hasn't been cut yet (the release-tag
# job is still running its quality gate), wait — tagging the next bump before
# the previous one would mis-tag the range. Keyed on the PUBSPEC VERSION, not
# the head commit subject: a missed release-tag run must not wedge auto-release
# forever, so after 1h the guard lets a fresh bump absorb the untagged one
# instead of blocking.
head_version=$(git show origin/main:pubspec.yaml | sed -n 's/^version: //p')
if [ -n "$head_version" ] && ! git rev-parse -q --verify "refs/tags/v$head_version^{commit}" >/dev/null 2>&1; then
  head_age=$(( $(date +%s) - $(git log -1 --format=%ct origin/main) ))
  if [ "$head_age" -lt 3600 ]; then
    echo "Auto-release: v$head_version pushed but untagged (release-tag job pending, ${head_age}s old) — skipping."
    exit 0
  fi
  echo "Auto-release: v$head_version pushed but untagged for ${head_age}s — release-tag likely wedged; proceeding so the next range absorbs it."
fi


for attempt in 1 2 3; do
  git fetch origin main
  git reset --hard origin/main

  current=$(grep '^version:' pubspec.yaml | awk '{print $2}')
  # Other workflows (iOS/macOS CI) tag releases without bumping pubspec —
  # when tags raced ahead, bump from the latest tag instead, or every run
  # dies on "tag already exists".
  latest_tag=$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
  if [ -n "$latest_tag" ]; then
    tag_version="${latest_tag#v}"
    if [ "$(printf '%s\n%s\n' "$current" "$tag_version" | sort -V | tail -1)" = "$tag_version" ]; then
      current="$tag_version"
    fi
  fi
  IFS='.' read -r major minor patch <<< "$current"
  next="$major.$minor.$((patch + 1))"
  echo "Auto-release: v$current -> v$next (attempt $attempt)"

  last_tag=$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
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

text = text.rstrip() + "\n"
# Append a fresh empty Unreleased exactly once — repeated runs (or a rerun
# after a raced push) must not stack duplicate sections.
if not re.search(r"^## Unreleased[ \t]*$", text, re.M):
    text += "\n## Unreleased\n"
open(path, "w", encoding="utf-8").write(text)
PY

  sed -i "s/^version: .*/version: $next/" pubspec.yaml
  # One version everywhere (gh-785): the app pubspec (Android versionName,
  # CFBundleShortVersionString fallback, App Store train) rides the same
  # bump so the ASC-approved floor can never outgrow it again.
  sed -i "s/^version: .*/version: $next+1/" flutter_app/pubspec.yaml

  git add pubspec.yaml flutter_app/pubspec.yaml CHANGELOG.md
  git commit -m "chore(release): v$next"

  if [ "$dry_run" -eq 1 ]; then
    echo "Auto-release DRY-RUN: would push to main: $(git rev-parse --short HEAD) 'chore(release): v$next'"
    echo "Auto-release DRY-RUN: release-tag job would then cut annotated tag v$next + GitHub Release."
    exit 0
  fi

  # Direct push to protected main as the bypass-listed App. Fast-forward only:
  # a main that moved since `reset --hard` rejects the push and the loop
  # re-computes the bump on the fresh head (E1 — never push over new commits).
  if git push origin HEAD:main; then
    echo "Auto-release: pushed chore(release): v$next to main; release-tag job cuts v$next next."
    exit 0
  fi
  echo "Main push raced, retrying..."
done

echo "Auto-release failed after 3 attempts"
exit 1
