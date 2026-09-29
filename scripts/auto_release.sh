#!/usr/bin/env bash
# Auto-release: bump the patch version, update CHANGELOG.md, open the release PR.
#
# Runs in CI on every push to main / the 2h catch-up cron (the `release` job in
# .github/workflows/ci.yml). Protected main rejects the bot's direct bump push
# ("3 of 3 required status checks are expected" — enforce_admins + strict since
# 2026-09-29), so the bump lands as a PR the machine reviews, validates and
# merges. The tag + GitHub Release are cut from the merged 'chore(release):'
# commit by scripts/tag_release.sh (the `release-tag` job) — a tag push with the
# RELEASE_PAT still fires the tag-scoped binaries/publish jobs.
#
# Changelog rules:
# - a curated `## Unreleased` section becomes the new version's notes;
# - otherwise notes are generated from commit subjects since the last tag;
# - a fresh empty `## Unreleased` is appended at the end.
#
# Idempotent: an open release PR whose branch tree already matches the computed
# bump is left alone (the 2h cron and racing pushes re-run this harmlessly).
set -euo pipefail

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

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

# One release PR at a time; and if the previous bump merged but its tag hasn't
# been cut yet (release-tag job is still running its quality gate), wait —
# tagging the next bump before the previous one would mis-tag the range.
open_release_prs=$(gh pr list --state open --json headRefName \
  --jq '[.[].headRefName | select(startswith("chore/release-v"))] | length' 2>/dev/null || echo 0)
if [ "${open_release_prs:-0}" -ge 1 ]; then
  echo "Auto-release: an open release PR is already queued for the machine — skipping."
  exit 0
fi
head_subject=$(git log -1 --format=%s origin/main)
case "$head_subject" in
  chore\(release\)*)
    head_version=$(git show origin/main:pubspec.yaml | sed -n 's/^version: //p')
    if ! git rev-parse -q --verify "refs/tags/v$head_version^{commit}" >/dev/null 2>&1; then
      echo "Auto-release: v$head_version merged but untagged (release-tag job pending) — skipping."
      exit 0
    fi
    ;;
esac

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

text = text.rstrip() + "\n\n## Unreleased\n"
open(path, "w", encoding="utf-8").write(text)
PY

  sed -i "s/^version: .*/version: $next/" pubspec.yaml
  # One version everywhere (gh-785): the app pubspec (Android versionName,
  # CFBundleShortVersionString fallback, App Store train) rides the same
  # bump so the ASC-approved floor can never outgrow it again.
  sed -i "s/^version: .*/version: $next+1/" flutter_app/pubspec.yaml

  git add pubspec.yaml flutter_app/pubspec.yaml CHANGELOG.md
  git commit -m "chore(release): v$next"
  branch="chore/release-v$next"

  # Idempotency: if the release branch already carries exactly this tree and
  # its PR is open, leave it alone (the cron would otherwise rewrite the head
  # every run and re-trigger validation + review each time).
  tree_now=$(git rev-parse HEAD^{tree})
  tree_branch=$(git ls-remote origin "refs/heads/$branch" | awk '{print $1}')
  if [ -n "$tree_branch" ]; then
    git fetch -q origin "$branch"
    tree_branch=$(git rev-parse "FETCH_HEAD^{tree}" 2>/dev/null || echo none)
  fi
  if [ "$tree_branch" = "$tree_now" ]; then
    open_pr=$(gh pr list --head "$branch" --state open --json number --jq 'length' 2>/dev/null || echo 0)
    if [ "${open_pr:-0}" -ge 1 ]; then
      echo "Auto-release: PR for $branch already open with identical content — nothing to do."
      exit 0
    fi
  fi

  if git push --force origin "HEAD:refs/heads/$branch"; then
    if [ "$(gh pr list --head "$branch" --state open --json number --jq 'length')" -ge 1 ]; then
      echo "Auto-release: $branch refreshed; open PR now carries v$next."
    else
      gh pr create --base main --head "$branch" \
        --title "chore(release): v$next" \
        --body "Automated patch release **v$next**.

- \`pubspec.yaml\` + \`flutter_app/pubspec.yaml\` bumped to \`$next\`
- \`CHANGELOG.md\`: new \`## $next\` section (curated \`## Unreleased\` notes or generated bullets)

Protected main no longer accepts direct release pushes (enforce_admins + strict, 2026-09-29), so the bump rides the machine: review → validate → merge. The \`release-tag\` job cuts the annotated tag + GitHub Release from the merged commit — the tag is pushed with RELEASE_PAT so the tag-scoped binaries/publish jobs still fire."
      echo "Auto-release: PR for v$next opened."
    fi
    exit 0
  fi
  echo "Branch push raced, retrying..."
done

echo "Auto-release failed after 3 attempts"
exit 1
