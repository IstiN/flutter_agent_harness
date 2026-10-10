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
#   LEG_PUBDEV_*        status (up-to-date/private/recovered/release-in-flight),
#                       versions, tag-run URL
#   NEXT_TAG            estimated next tag (informational; legs derive latest+1 themselves)
#   GITHUB_RUN_ID, GITHUB_REPOSITORY, GITHUB_SERVER_URL   runner defaults
#
# Exits non-zero when any leg failed or was cancelled (the daily run goes
# red too); all-skipped stays green (#159 lesson).
set -euo pipefail

repo="${GITHUB_REPOSITORY}"
daily_url="${GITHUB_SERVER_URL}/${repo}/actions/runs/${GITHUB_RUN_ID}"
assignee="${DAILY_PUBLISH_ASSIGNEE:-ai-teammate}"
next_tag="${NEXT_TAG:-}"
failed_legs=""
actions=""
rows="$(mktemp)"
trap 'rm -f "$rows"' EXIT

gh label create daily-publish --repo "$repo" --color B60205 \
  --description "Auto-filed by the daily auto-publish pipeline" >/dev/null 2>&1 || true

# ── log collection ─────────────────────────────────────────────────────────
# Failing job/step names and the last ~50 log lines, from the child run when
# one exists, else from this daily run's leg job (jobs API — the run is
# still in progress here, and GitHub serves no logs for it mid-run).
failing_steps() { # $1 = child run id ("" = this run), $2 = log prefix
  if [ -n "$1" ]; then
    gh run view "$1" --repo "$repo" --json jobs --jq '
      [.jobs[] | select(.conclusion == "failure" or .conclusion == "cancelled")
        | .name + " — " +
          ([.steps[] | select(.conclusion == "failure" or .conclusion == "cancelled")
            | .name] | join(", "))]
      | join("\n")' 2>/dev/null || true
  else
    # The report job runs INSIDE the daily run, so the run is still in
    # progress here — and GitHub serves no logs for in-progress runs
    # (--log-failed returns empty: issue #208 was filed as "unknown (job
    # cancelled or timed out)" for a leg that died in 4s with a clear
    # error). Job/step data IS served mid-run — read failed steps from it.
    gh run view "$GITHUB_RUN_ID" --repo "$repo" --json jobs 2>/dev/null \
      | jq -r --arg job "$2" '
          [.jobs[] | select(.name == $job
                              and (.conclusion == "failure"
                                or .conclusion == "cancelled"))
            | .name + " — " +
              ([.steps[] | select(.conclusion == "failure"
                               or .conclusion == "cancelled")
                | .name] | join(", "))]
          | join("\n")' 2>/dev/null || true
  fi
}

log_excerpt() { # $1 = child run id ("" = this run), $2 = job-name fragment
  # gh-1478: signal-first excerpt. Grep the failed log for error signal
  # lines and quote the first matches with context; the raw tail is only
  # the fallback when nothing matches (the #1473 tree-noise digest).
  local raw=""
  if [ -n "$1" ]; then
    raw=$(gh run view "$1" --repo "$repo" --log-failed 2>/dev/null \
      | tail -n 400 || true)
  fi
  if [ -z "$raw" ]; then
    # No child log (child in flight/cancelled, or never dispatched). The
    # RUN-level log zip is 409 while the daily run is in progress, but the
    # per-JOB log endpoint serves completed jobs — resolve the failed or
    # cancelled leg job and take ITS log (the #1472 empty-shrug class, and
    # the inject_failure TEST hook shape: a failed leg job, no child run).
    local job_id
    job_id=$(gh run view "$GITHUB_RUN_ID" --repo "$repo" --json jobs \
      2>/dev/null | jq -r --arg frag "$2" '
        [.jobs[] | select((.conclusion == "failure" or .conclusion == "cancelled")
                          and (.name | contains($frag))) | .databaseId]
        | last // empty' 2>/dev/null || true)
    if [ -n "$job_id" ]; then
      raw=$(gh run view --job "$job_id" --repo "$repo" --log 2>/dev/null \
        | tail -n 400 || true)
    fi
  fi
  [ -n "$raw" ] || return 0
  printf '%s\n' "$raw" | signal_excerpt
}

signal_excerpt() { # stdin: log text; stdout: first signal matches w/ context, else tail
  awk '
    { lines[NR] = $0
      if ($0 ~ /::error::|Message from server|(^|[^A-Za-z])error:|(^|[^A-Za-z])FAIL|[Ee]xit code|exited with/) {
        if (++hits <= 3)
          for (i = NR - 3; i <= NR + 3; i++) if (i >= 1) want[i] = 1
      }
    }
    END {
      if (hits == 0) { # no signal line — the raw tail is the fallback
        start = NR - 49; if (start < 1) start = 1
        for (i = start; i <= NR; i++) print lines[i]
        exit
      }
      i = 1; snip = 0
      while (i <= NR) {
        if (!want[i]) { i++; continue }
        if (snip++) print "[...]"
        while (i <= NR && want[i]) { print lines[i]; i++ }
      }
    }'
}

error_signature() { # stdin: excerpt/log; stdout: normalized root-cause signature
  # Priority order: ::error::, Message from server, error:, FAIL, exit-code
  # lines. The signature is the first line of the highest-priority class,
  # stripped of gh log prefixes (job<TAB>step<TAB>timestamp) — the dedup
  # key for the root-cause search (#1473 vs #1452).
  awk '
    {
      pr = 0
      if ($0 ~ /::error::/) pr = 1
      else if ($0 ~ /Message from server/) pr = 2
      else if ($0 ~ /(^|[^A-Za-z])error:/) pr = 3
      else if ($0 ~ /(^|[^A-Za-z])FAIL/) pr = 4
      else if ($0 ~ /[Ee]xit code|exited with/) pr = 5
      if (pr && (best == 0 || pr < best)) { best = pr; sig = $0 }
    }
    END { if (best) print sig }' \
    | awk -F '\t' '{print $NF}' \
    | sed -e 's/^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9:.]\{1,\}Z *//' \
        -e 's/^::error:://' \
        -e 's/[[:space:]][[:space:]]*/ /g' \
        -e 's/^ //' -e 's/ $//' \
    | cut -c1-200
}

find_issue_by_signature() { # $1 = normalized signature; echoes an open issue number or nothing
  # gh-1478 root-cause dedup: GitHub issue search matches open issues'
  # bodies AND comments — a hit means the root cause is already tracked, so
  # the caller comments there instead of filing a symptom duplicate.
  local q
  q=$(printf '%s' "$1" \
      | tr -cs '[:alnum:]./+-' ' \
      | sed -e 's/^ *//' -e 's/ *$//' \
      | cut -c1-200)
  [ -n "$q" ] || return 0
  gh search issues "\"$q\"" --repo "$repo" --state open \
    --match body,comments --limit 5 --json number \
    --jq '.[0].number // empty' 2>/dev/null || true
}

cancelled_job_info() { # $1 = job-name fragment; "name<TAB>startedAt<TAB>completedAt" or nothing
  gh run view "$GITHUB_RUN_ID" --repo "$repo" --json jobs 2>/dev/null \
    | jq -r --arg frag "$1" '
        [.jobs[] | select(.conclusion == "cancelled"
                          and (.name | contains($frag)))]
        | .[0] | if . == null then "" else [.name, .startedAt, .completedAt] | @tsv end' \
    2>/dev/null || true
}

leg_ceiling_minutes() { # $1 = job-name fragment; echoes timeout-minutes from the workflow or nothing
  local wf="${DAILY_PUBLISH_WORKFLOW:-${GITHUB_WORKSPACE:-.}/.github/workflows/daily-publish.yml}"
  [ -f "$wf" ] || return 0
  awk -v frag="$1" '
    index($0, "name: .Leg: " frag) { injob = 1; next }
    injob && /^  [A-Za-z0-9_-]+:/ { injob = 0 }
    injob && /^    timeout-minutes:/ {
      line = $0
      sub(/^ *timeout-minutes: */, "", line)
      sub(/[^0-9].*/, "", line)
      if (line != "") print line
      exit
    }' "$wf"
}

fmt_elapsed() { # $1 = seconds -> "359m53s" / "1h02m03s"
  local s="$1" h m
  h=$((s / 3600)); m=$(((s % 3600) / 60)); s=$((s % 60))
  if [ "$h" -gt 0 ]; then echo "${h}h${m}m${s}s"; else echo "${m}m${s}s"; fi
}

# ── issue lifecycle ────────────────────────────────────────────────────────
find_open_issue() { # $1 = exact title; echoes the issue number or nothing
  gh issue list --repo "$repo" --state open --label daily-publish \
    --limit 200 --json number,title --jq '.[] | [.number, .title] | @tsv' 2>/dev/null \
    | while IFS=$'\t' read -r n t; do
        if [ "$t" = "$1" ]; then echo "$n"; fi
      done | head -1
}

file_or_comment() { # $1 = leg id, $2 = log prefix, $3 = child run url, $4 = leg result
  local leg="$1" prefix="$2" url="$3" result="${4:-failure}"
  # Job-name fragment for the own-run jobs API (the yaml display names add
  # parentheticals the report's display names don't carry).
  local frag="${prefix%% (*}"
  local child_id title steps excerpt body sig
  child_id="${url##*/}"
  title="[daily-publish] $leg leg failed"
  steps=$(failing_steps "$child_id" "$prefix")
  excerpt=$(log_excerpt "$child_id" "$frag")
  sig=""
  [ -z "$excerpt" ] || sig=$(printf '%s\n' "$excerpt" | error_signature)

  body="$(mktemp)"
  {
    echo "**Leg:** \`$leg\`"
    # #345/#347: a cancelled leg job means the WATCHER died (whole-run
    # cancellation or leg timeout) — not a child-workflow failure verdict.
    # The child may still be in flight, which is also why the steps/log
    # excerpts below can come up empty mid-run. Say so up front instead of
    # letting "unknown (job cancelled or timed out)" read like a leg defect.
    if [ "$result" = "cancelled" ]; then
      echo "**Leg job result:** cancelled — the leg's watcher was killed mid-watch (whole-run cancellation or leg timeout), NOT a child-workflow failure verdict. The child run may have been healthy or still in flight; correlate its timeline before treating this as a leg defect."
      # gh-1478: a cancelled run gets a real digest — which job was in
      # flight, its timeout-minutes ceiling, elapsed-vs-ceiling — instead of
      # the #1472 empty "no failed-step log available" shrug.
      local cinfo cname cstart cend csec ceiling
      cinfo=$(cancelled_job_info "$frag")
      ceiling=$(leg_ceiling_minutes "$frag")
      if [ -n "$cinfo" ]; then
        IFS=$'\t' read -r cname cstart cend <<< "$cinfo"
        local celapsed="unknown"
        local cs="" ce=""
        cs=$(date -u -d "$cstart" +%s 2>/dev/null || true)
        ce=$(date -u -d "$cend" +%s 2>/dev/null || true)
        if [ -n "$cs" ] && [ -n "$ce" ] && [ "$ce" -ge "$cs" ]; then
          celapsed=$(fmt_elapsed $((ce - cs)))
        fi
        echo "**Cancelled while running:** job \`$cname\` — killed after ${celapsed} elapsed."
        if [ -n "$ceiling" ]; then
          echo "**Timeout ceiling:** \`${ceiling}m\` (timeout-minutes in daily-publish.yml)."
          if [ "$celapsed" != "unknown" ]; then
            local csec_elapsed=$((ce - cs)) csec_ceiling=$((ceiling * 60))
            if [ "$csec_elapsed" -ge $((csec_ceiling - 60)) ]; then
              echo "**Elapsed vs ceiling:** ${celapsed} of ${ceiling}m — at the ceiling, so the leg hit its own timeout (a wedged child or too-tight ceiling; the child chain timeouts are the #351 arithmetic)."
            elif [ "$((csec_elapsed * 2))" -le "$csec_ceiling" ]; then
              echo "**Elapsed vs ceiling:** ${celapsed} of ${ceiling}m — far below the ceiling, so this looks like a whole-run/operator cancellation or an infrastructure kill, not the leg's own timeout."
            else
              echo "**Elapsed vs ceiling:** ${celapsed} of ${ceiling}m — below the ceiling; check the run timeline for a whole-run cancellation before treating this as a leg defect."
            fi
          fi
        fi
      else
        echo "**Cancelled while running:** could not resolve which job was in flight from the jobs API — see the run timeline."
      fi
    fi
    echo "**Daily run:** $daily_url"
    [ -n "$url" ] && echo "**Leg run:** $url"
    echo "**Failing job/step:** ${steps:-unknown (job cancelled or timed out)}"
    if [ -n "$sig" ]; then
      # The normalized signature is both human-visible and machine-matchable
      # (root-cause dedup searches open issues' bodies/comments for it).
      echo "**Error signature:** \`$sig\`"
      echo "<!-- daily-publish-sig: $sig -->"
    fi
    echo
    echo "Failure excerpt (signal-first: error lines with context; raw tail when no signal line matches):"
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

  # gh-1478 root-cause dedup: when the normalized signature matches an OPEN
  # issue's body/comments (any label — #1452 is not a daily-publish issue),
  # the root cause is already tracked: comment there with the new run link
  # instead of filing a symptom duplicate that re-fires every day.
  if [ -n "$sig" ]; then
    local sigmatch
    sigmatch=$(find_issue_by_signature "$sig")
    if [ -n "$sigmatch" ]; then
      {
        echo "**Root-cause dedup (gh-1478):** this failure's error signature matches #$sigmatch — the digest below is a fresh data point for that issue, not a new bug."
        echo
        cat "$body"
      } > "$body.sig"
      gh issue comment "$sigmatch" --repo "$repo" --body-file "$body.sig" >/dev/null
      actions+="updated #${sigmatch} ($leg — signature matches an open root cause)"$'\n'
      rm -f "$body" "$body.sig"
      return 0
    fi
  fi

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
      # A neutral-skip override («skipped: …») marks an UNOBSERVED outcome
      # (#1368 false green: release-in-flight rendered ✅ and auto-closed the
      # leg's stuck-release issue without ever seeing the publish). Render it
      # as a skip — never ✅ — and keep any open leg issue open; only a
      # verified outcome (up-to-date/recovered/private) closes it.
      if [[ "$override" == "skipped:"* ]]; then
        icon="⏭️"
        status="$override"
      else
        icon="✅"
        status="${override:-success}"
        close_if_open "$id"
      fi
      ;;
    failure)
      icon="❌"; status="failure"; failed_legs+="$id "
      file_or_comment "$id" "$prefix" "$url"
      ;;
    cancelled)
      icon="⚠️"; status="cancelled (timeout?)"; failed_legs+="$id "
      file_or_comment "$id" "$prefix" "$url" "cancelled"
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
  # gh-1192/#1368: the tag-publish outcome is UNOBSERVED (still executing or
  # the bounded wait lapsed) — neutral, no issue filed, none closed, and the
  # summary renders it as a skip, never a ✅.
  release-in-flight) pubdev_override="skipped: release in flight (tag-publish outcome unobserved this run; the next daily re-verifies)";;
esac

process_leg testflight "TestFlight" "${LEG_TESTFLIGHT:-}" "${LEG_TESTFLIGHT_URL:-}" \
  "$next_tag (est.)" "[release](https://github.com/${repo}/releases/tag/${next_tag})"
process_leg play "Play (Android beta)" "${LEG_PLAY:-}" "${LEG_PLAY_URL:-}" \
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
