#!/usr/bin/env bash
# Daily auto-publish report (issue #161): renders the per-run job-summary
# table and drives the self-healing issue lifecycle.
#
#   failing/cancelled leg -> file a bug issue assigned to the owner; dedup
#     guard: an OPEN issue labeled `daily-publish` with the same title gets
#     a fresh comment (new run link + log excerpt) instead of a duplicate
#   green leg -> auto-close that leg's still-open issue with a comment
#
# Inputs come from environment (set by the daily-publish.yml report job):
#   PLAN_RESULT         needs.plan.result — a plan failure files its own issue
#   LEG_<NAME>          needs result: success | failure | skipped | cancelled
#   LEG_<NAME>_URL      child run URL (empty on internal/skip paths)
#   LEG_PUBDEV_*        status (up-to-date/private/recovered), versions, tag-run URL
#   NEXT_TAG            estimated next tag (informational; legs derive latest+1 themselves)
#   GITHUB_RUN_ID, GITHUB_REPOSITORY, GITHUB_SERVER_URL   runner defaults
#
# Exits non-zero when any leg failed or was cancelled (the daily run goes
# red too); all-skipped stays green (#159 lesson).
set -euo pipefail

repo="${GITHUB_REPOSITORY}"
daily_url="${GITHUB_SERVER_URL}/${repo}/actions/runs/${GITHUB_RUN_ID}"
assignee="${DAILY_PUBLISH_ASSIGNEE:-vabhzw17eg2qu4m9-bit}"
next_tag="${NEXT_TAG:-}"
failed_legs=""
actions=""
rows="$(mktemp)"
trap 'rm -f "$rows"' EXIT

gh label create daily-publish --repo "$repo" --color B60205 \
  --description "Auto-filed by the daily auto-publish pipeline" >/dev/null 2>&1 || true

# ── log collection ─────────────────────────────────────────────────────────
# Failing job/step names and the last ~50 log lines, from the child run when
# one exists, else from this daily run filtered by the leg job's log prefix.
failing_steps() { # $1 = child run id ("" = this run), $2 = log prefix
  if [ -n "$1" ]; then
    gh run view "$1" --repo "$repo" --json jobs --jq '
      [.jobs[] | select(.conclusion == "failure" or .conclusion == "cancelled")
        | .name + " — " +
          ([.steps[] | select(.conclusion == "failure" or .conclusion == "cancelled")
            | .name] | join(", "))]
      | join("\n")' 2>/dev/null || true
  else
    gh run view "$GITHUB_RUN_ID" --repo "$repo" --log-failed 2>/dev/null \
      | grep -F "$2" | awk -F'\t' '{print $2}' | sort -u | paste -sd, - || true
  fi
}

log_excerpt() { # $1 = child run id ("" = this run), $2 = log prefix
  if [ -n "$1" ]; then
    gh run view "$1" --repo "$repo" --log-failed 2>/dev/null | tail -n 50 || true
  else
    gh run view "$GITHUB_RUN_ID" --repo "$repo" --log-failed 2>/dev/null \
      | grep -F "$2" | tail -n 50 || true
  fi
}

# ── issue lifecycle ────────────────────────────────────────────────────────
find_open_issue() { # $1 = exact title; echoes the issue number or nothing
  gh issue list --repo "$repo" --state open --label daily-publish \
    --json number,title --jq '.[] | [.number, .title] | @tsv' 2>/dev/null \
    | while IFS=$'\t' read -r n t; do
        if [ "$t" = "$1" ]; then echo "$n"; fi
      done | head -1
}

file_or_comment() { # $1 = leg id, $2 = log prefix, $3 = child run url
  local leg="$1" prefix="$2" url="$3"
  local child_id title steps excerpt body
  child_id="${url##*/}"
  title="[daily-publish] $leg leg failed"
  steps=$(failing_steps "$child_id" "$prefix")
  excerpt=$(log_excerpt "$child_id" "$prefix")

  body="$(mktemp)"
  {
    echo "**Leg:** \`$leg\`"
    echo "**Daily run:** $daily_url"
    [ -n "$url" ] && echo "**Leg run:** $url"
    echo "**Failing job/step:** ${steps:-unknown (job cancelled or timed out)}"
    echo
    echo "Last lines of the failed step's log:"
    echo
    if [ -n "$excerpt" ]; then
      sed -e 's/\t/  /g' -e 's/^/    /' <<< "$excerpt"
    else
      echo "    (no failed-step log available — see the run link)"
    fi
    echo
    echo "---"
    echo "Auto-filed by the daily auto-publish pipeline; auto-closes when this leg goes green. Pause the pipeline with \`gh workflow disable daily-publish.yml -R $repo\`."
  } > "$body"

  local existing
  existing=$(find_open_issue "$title")
  if [ -n "$existing" ]; then
    gh issue comment "$existing" --repo "$repo" --body-file "$body" >/dev/null
    actions+="updated #${existing} ($leg still failing)"$'\n'
  else
    local created
    created=$(gh issue create --repo "$repo" --title "$title" --body-file "$body" \
      --label bug --label daily-publish --assignee "$assignee" 2>/dev/null || true)
    if [ -n "$created" ]; then
      actions+="filed ${created} ($leg failed)"$'\n'
    else
      echo "::warning::could not file the self-healing issue for leg '$leg' (permissions?)"
      actions+="FAILED to file an issue for $leg"$'\n'
    fi
  fi
  rm -f "$body"
}

close_if_open() { # $1 = leg id
  local title="[daily-publish] $1 leg failed"
  local existing
  existing=$(find_open_issue "$title")
  if [ -n "$existing" ]; then
    gh issue close "$existing" --repo "$repo" \
      --comment "✅ leg \`$1\` went green again in $daily_url — auto-closing." >/dev/null
    actions+="auto-closed #${existing} ($1 green again)"$'\n'
  fi
}

# ── per-leg processing ─────────────────────────────────────────────────────
# process_leg <id> <display> <result> <url> <version> <links> <status-override>
process_leg() {
  local id="$1" display="$2" result="${3:-}" url="${4:-}" version="${5:-}" links="${6:-}" override="${7:-}"
  local prefix="Leg: $2" icon status
  case "$result" in
    success)
      icon="✅"
      status="${override:-success}"
      close_if_open "$id"
      ;;
    failure)
      icon="❌"; status="failure"; failed_legs+="$id "
      file_or_comment "$id" "$prefix" "$url"
      ;;
    cancelled)
      icon="⚠️"; status="cancelled (timeout?)"; failed_legs+="$id "
      file_or_comment "$id" "$prefix" "$url"
      ;;
    *)
      icon="⏭️"; status="skipped"
      ;;
  esac

  local link_cell="-"
  if [ -n "$url" ]; then
    link_cell="[run]($url)"
    [ -n "$links" ] && link_cell+=" • $links"
  elif [ -n "$links" ]; then
    if [ "$result" = "success" ]; then
      link_cell="$links"
    else
      link_cell="$links • [daily run]($daily_url)"
    fi
  fi
  [ -n "$version" ] || version="-"
  echo "| $display | \`$version\` | $icon $status | $link_cell |" >> "$rows"
}

# Plan job: a failure here means legs never ran correctly — it gets its own
# issue instead of escaping the self-healing loop.
if [ "${PLAN_RESULT:-success}" != "success" ]; then
  file_or_comment plan "Plan (change detection + versions)" ""
  failed_legs+="plan "
  echo "| Plan | - | ❌ ${PLAN_RESULT} | [daily run]($daily_url) |" >> "$rows"
else
  close_if_open plan
fi

# pub.dev status override — display names MUST match the workflow job names
# exactly ("Leg: <name>"): the log-prefix filter relies on them.
pubdev_override=""
case "${LEG_PUBDEV_STATUS:-}" in
  private)    pubdev_override="private (publish_to: none)";;
  recovered)  pubdev_override="recovered — tag-publish rerun, pub.dev serves ${LEG_PUBDEV_PUBLISHED:-?}";;
  up-to-date) pubdev_override="up-to-date (pub.dev serves ${LEG_PUBDEV_PUBLISHED:-?})";;
esac

process_leg testflight "TestFlight" "${LEG_TESTFLIGHT:-}" "${LEG_TESTFLIGHT_URL:-}" \
  "$next_tag (est.)" "[release](https://github.com/${repo}/releases/tag/${next_tag})"
process_leg pubdev "pub.dev" "${LEG_PUBDEV:-}" "${LEG_PUBDEV_URL:-}" \
  "${LEG_PUBDEV_PUBSPEC:-}" "[pub.dev](https://pub.dev/packages/flutter_agent_harness)" "$pubdev_override"
process_leg cli "CLI + macOS desktop" "${LEG_CLI:-}" "${LEG_CLI_URL:-}" \
  "$next_tag (est.)" "[release](https://github.com/${repo}/releases/tag/${next_tag})"
process_leg website "Website" "${LEG_WEBSITE:-}" "${LEG_WEBSITE_URL:-}" \
  "" "[fa1.dev](https://fa1.dev)"
process_leg addin "Outlook add-in" "${LEG_ADDIN:-}" "${LEG_ADDIN_URL:-}" \
  "" "[manifest](https://fa1.dev/outlook/manifest.xml)"

# ── job summary ────────────────────────────────────────────────────────────
{
  echo "## Daily auto-publish"
  echo
  echo "Run: $daily_url • est. next tag: \`$next_tag\` (each leg derives latest+1 at its own dispatch)"
  echo "| Leg | Version | Status | Links |"
  echo "| --- | --- | --- | --- |"
  cat "$rows"
  echo
  if [ -n "$actions" ]; then
    echo "### Self-healing issues"
    echo
    printf '%s' "$actions"
  else
    echo "_No issue lifecycle actions this run._"
  fi
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"

if [ -n "$failed_legs" ]; then
  echo "::error::daily-publish legs failed: ${failed_legs% } — issues filed/updated, see the job summary"
  exit 1
fi
echo "daily-publish report complete — no failing legs"
