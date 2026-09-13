#!/usr/bin/env bash
# Daily release-draft sweeper (issue #282), rides daily-publish.yml:
#
#   - lists DRAFT releases older than $SWEEP_MAX_AGE_SECONDS (default 24h);
#   - deletes stale drafts created by bots (author.type == Bot or a
#     *[bot] login) — draft assets are unpublished by definition and
#     published releases are the artifact store, so deletion is safe
#     (issue #282 E2). The git tag is never touched;
#   - stale HUMAN drafts are listed in the summary, never deleted (E1);
#   - fresh drafts (<24h) are counted, never touched — an in-flight run
#     may legitimately own them;
#   - files ONE deduplicated, self-closing issue (label release-hygiene)
#     whenever anything stale was found — a comment on the open issue
#     instead of a duplicate, auto-closed again once a sweep comes up
#     clean (same convention as nightly.yml / daily_publish_report.sh).
#
# Drafts are deleted by release id via the API: a draft may carry an empty
# tag_name, which makes every tag-based `gh release delete` ambiguous.
#
# Env: GITHUB_REPOSITORY, GH_TOKEN, SWEEP_MAX_AGE_SECONDS (default 86400),
#      SWEEP_LABEL (default release-hygiene).
set -euo pipefail

repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
max_age="${SWEEP_MAX_AGE_SECONDS:-86400}"
label="${SWEEP_LABEL:-release-hygiene}"
title="[daily-publish] stale release drafts swept"
daily_url="${GITHUB_SERVER_URL:-https://github.com}/$repo/actions/runs/${GITHUB_RUN_ID:-manual}"

gh label create "$label" --repo "$repo" --color B60205 \
  --description "Auto-filed by the release-draft sweeper" >/dev/null 2>&1 || true

# ── inventory ──────────────────────────────────────────────────────────────
# gh api --paginate emits one JSON array per page; the jq stream filter
# flattens them all. Bucketing happens in jq so the whole rule is
# reviewable in one place:
#   stale + bot  -> delete      stale + human -> keep, list
#   fresh        -> untouched
drafts=$(gh api --paginate "repos/$repo/releases" | jq -r --argjson maxage "$max_age" '
  [ .[] | select(.draft == true)
    | { bucket: (
          if ((now - (.created_at | fromdateiso8601)) > $maxage)
          then (if ((.author.type // "User") == "Bot"
                    or ((.author.login // "") | test("\\[bot\\]$")))
               then "bot" else "human" end)
          else "fresh" end),
        tag: (.tag_name // "(untagged)"),
        id: (.id | tostring),
        created: (.created_at // "?"),
        author: (.author.login // "unknown") } ]
  | sort_by(.created)[]
  | [ .bucket, .tag, .id, .created, .author ] | @tsv')

deleted=""
deleted_tags=""
deleted_count=0
humans=""
human_tags=""
fresh_count=0

while IFS=$'\t' read -r bucket tag id created author; do
  [ -n "$bucket" ] || continue
  case "$bucket" in
    fresh)
      fresh_count=$((fresh_count + 1))
      ;;
    human)
      humans="$humans- \`$tag\` — created $created by @$author (human draft: listed, kept)\n"
      human_tags="$human_tags $tag"
      ;;
    bot)
      gh api -X DELETE "repos/$repo/releases/$id" >/dev/null
      deleted_count=$((deleted_count + 1))
      # Name the creating run so a RECURRING stuck draft points at its
      # broken step instead of rotting silently (AC2). Dispatch-time
      # drafts have no run on their ref — then say so.
      run_url=""
      if [ "$tag" != "(untagged)" ]; then
        run_url=$(gh run list --repo "$repo" --branch "$tag" --limit 1 \
          --json url --jq '.[0].url // empty' 2>/dev/null || true)
      fi
      [ -n "$run_url" ] || run_url="no run on ref \`$tag\` (dispatch-time draft — the creating step died mid-run)"
      deleted="$deleted- \`$tag\` — created $created by @$author; creating run: $run_url\n"
      deleted_tags="$deleted_tags $tag"
      ;;
  esac
done <<< "$drafts"

# ── issue lifecycle (dedup + self-closing) ─────────────────────────────────
find_open_issue() { # echoes the issue number of the open sweep issue, or nothing
  gh issue list --repo "$repo" --state open --label "$label" \
    --limit 100 --json number,title --jq '.[] | [.number, .title] | @tsv' 2>/dev/null \
    | while IFS=$'\t' read -r n t; do
        if [ "$t" = "$title" ]; then echo "$n"; fi
      done | head -1
}

stale_count=$((deleted_count + $(printf '%s' "$humans" | grep -c . || true) ))

if [ "$stale_count" -gt 0 ]; then
  body=$(mktemp)
  {
    echo "**Sweep run:** $daily_url"
    echo "**Swept:** $deleted_count stale bot draft(s) older than $((max_age / 3600))h"
    printf '%b' "$deleted"
    [ -n "$humans" ] && { echo; echo "**Kept (human drafts, listed not deleted — E1):**"; printf '%b' "$humans"; }
    echo
    echo "**Fresh drafts (<$((max_age / 3600))h):** $fresh_count — untouched (an in-flight run may own them)"
    echo
    echo "A stale draft means a \`gh release create\` step died between asset upload and publish — check the creating run's failed step. Recurrence means a lifecycle guard is missing (issue #282)."
    echo
    echo "---"
    echo "Auto-filed by the daily draft sweeper; auto-closes when a sweep finds nothing stale."
  } > "$body"
  existing=$(find_open_issue)
  if [ -n "$existing" ]; then
    gh issue comment "$existing" --repo "$repo" --body-file "$body" >/dev/null
    issue_action="commented on #$existing (still finding stale drafts)"
  else
    created_issue=$(gh issue create --repo "$repo" --title "$title" \
      --body-file "$body" --label bug --label "$label" 2>/dev/null || true)
    issue_action="filed ${created_issue:-<issue creation failed>}"
  fi
  rm -f "$body"
else
  existing=$(find_open_issue)
  issue_action="none needed"
  if [ -n "$existing" ]; then
    gh issue close "$existing" --repo "$repo" \
      --comment "✅ sweep found nothing stale — auto-closing." >/dev/null
    issue_action="auto-closed #$existing (clean sweep)"
  fi
fi

# ── job summary ────────────────────────────────────────────────────────────
{
  echo "### Release-draft sweeper"
  echo
  echo "Deleted **$deleted_count** stale bot draft(s) • kept human drafts: **$(printf '%s' "$humans" | grep -c . || true)** • fresh (<$((max_age / 3600))h): **$fresh_count** • issue lifecycle: $issue_action"
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"

echo "sweeper: deleted=${deleted_tags# } human-kept=${human_tags# } fresh=$fresh_count issue=$issue_action"
