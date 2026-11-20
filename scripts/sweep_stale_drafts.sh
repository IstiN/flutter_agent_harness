#!/usr/bin/env bash
# Daily release-draft sweeper (issue #282), rides daily-publish.yml:
#
#   - lists DRAFT releases older than $SWEEP_MAX_AGE_SECONDS (default 24h);
#   - deletes stale drafts created by the pipeline (author.type == Bot, a
#     *[bot] login, the repo's machine account (DAILY_PUBLISH_ASSIGNEE,
#     default ai-teammate — gh-2287: its drafts (ai-gh-*/ai-pr-*) are
#     User-typed and marker-less but machine-created), OR the body
#     carries a well-formed `release-draft-owner: run/<id>/job/<job>`
#     marker — the exact shape
#     release_lazy_draft.sh / release_attach_or_create.sh stamp and
#     release_draft_guard.sh parses; since the drafts are created with
#     GH_TOKEN=RELEASE_PAT the API author is the PAT's human owner, so
#     the marker is the only ownership proof, gh-2008. Prose that merely
#     MENTIONS the substring or a malformed marker is NOT ownership —
#     those drafts stay human/kept, E1) — draft assets are unpublished by
#     definition and published releases are the artifact store, so
#     deletion is safe (issue #282 E2). The git tag is never touched;
#   - stale HUMAN drafts are listed in the summary, never deleted (E1);
#   - fresh drafts (<24h) are counted, never touched — an in-flight run
#     may legitimately own them. EXCEPTION (gh-2318): a fresh draft with a
#     well-formed release-draft-owner marker is RECLAIMED immediately when
#     its owner run completed, no ci.yml push train on the tag is still
#     queued/in-flight, and the tag's newest concluded ci.yml push train
#     failed with release-provenance SKIPPED (the publish point is
#     unreachable — rerun --failed cannot resurrect skipped jobs, so
#     nobody will ever publish it; the same criterion as ci.yml's gh-2230
#     train-draft-guard, which only sees drafts visible at train end).
#     A rerunnable (FAILED) provenance keeps the draft as the rerun
#     --failed recovery vessel (gh-1899) until it goes stale below;
#   - files ONE deduplicated, self-closing issue (label release-hygiene)
#     whenever anything stale was found — a comment on the open issue
#     instead of a duplicate, auto-closed again once a sweep comes up
#     clean (same convention as nightly.yml / daily_publish_report.sh).
#
# ── artefact-cache drafts have their own lifecycle (gh-236) ────────────────
# The machine loop (dmtools-agents factory: timerAutoCommitAndSave.js →
# releaseArtefacts.uploadRawFile → github_get_or_create_draft_release, tag
# template `ai-{ticketKey}`) writes every fa leg's session/output snapshots
# as assets of a per-ticket DRAFT release `ai-gh-<n>` / `ai-pr-<n>`, created
# with the ai-teammate token — User-typed, marker-less, no Actions run owns
# it. Those drafts are caches by design (never published, assets
# best-effort), NOT failed release-train drafts — but without a lifecycle
# they rotted 24h, were swept as generic bot-bucket findings, and re-filed
# the recurring sweep issue every day (gh-2287 → gh-2318 → gh-236). The
# guard: a machine-account draft whose tag matches `ai-(gh|pr)-<digits>` is
#   - RECLAIMED NOW, any age, when the ticket entity is `closed` — a closed
#     cycle never resumes (a reopened ticket starts a fresh session; the
#     pack's restore path is non-fatal and recreates the cache on "first
#     run"), so the draft is provably garbage the moment the cycle ends;
#   - swept by the existing 24h backstop when the ticket is still open (a
#     parked leg — the cache is recreated if the leg resumes);
#   - kept untouched while the ticket is open and the draft is fresh (an
#     in-flight leg may be writing snapshots into it);
#   - KEPT on any ticket-state lookup failure (never delete blind) — only
#     the 24h backstop then applies.
# The class is EXCLUDED from the sweep-issue finding counters: reclaiming a
# lifecycle-managed cache is routine hygiene, not a stale-draft finding, so
# the issue auto-closes when only cache traffic remains. Human-authored
# `ai-*` drafts are NOT lifecycle-managed (E1 holds — they stay listed,
# kept), and machine-authored non-matching drafts (e.g. a machine-authored
# `vX.Y.Z` train draft) stay in the bot bucket and remain findings.
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
# The repo's machine-account identity (same env + default as
# daily_publish_report.sh): drafts authored by it are pipeline-created —
# gh-2287: the ai-teammate factory's drafts (ai-gh-*/ai-pr-*) are User-typed
# and marker-less, so author-only Bot detection bucketed them as human and
# they rotted forever while the sweep issue never auto-closed.
assignee="${DAILY_PUBLISH_ASSIGNEE:-ai-teammate}"
title="[daily-publish] stale release drafts swept"
daily_url="${GITHUB_SERVER_URL:-https://github.com}/$repo/actions/runs/${GITHUB_RUN_ID:-manual}"

# ── failed-train diagnosis (gh-2105 + gh-2318) ──────────────────────────────
# The staged draft's publish owner is the TAG TRAIN (ci.yml's push run on
# the tag ref — release-provenance is the sole publish point, gh-1801).
# Diagnose <tag>'s newest CONCLUDED failed ci.yml push train; prints one
# TSV row:
#
#   train_id <TAB> conclusion <TAB> url <TAB> failed_jobs <TAB> prov_conclusion <TAB> in_flight
#
# `failed_jobs` names the train's failure-concluded jobs (the gh-2105 issue
# prose). `prov_conclusion` is the release-provenance job's OWN conclusion —
# "skipped" means the publish point is UNREACHABLE (`rerun --failed` never
# resurrects skipped jobs — the gh-2230 train-guard criterion), "failure"
# means it is rerunnable (the staged draft is the `rerun --failed` recovery
# vessel, gh-1899 — the stale 24h sweep reclaims it if the train is never
# recovered). `in_flight` is "in_flight" when ANY fetched ci.yml push run
# on the tag has a null conclusion (queued or in progress), "none" when all
# have concluded, and "unknown" if that check fails; the fresh-draft reclaim
# keeps unless it is explicitly "none", because a live train may still
# publish even when an older train failed. The publish-point job is matched
# by its ci.yml `name:` —
# "Sign release checksums" (pinned by test/release_stale_draft_reclaim_test.dart,
# gh-2318 group; update both together). Empty output = no failed train /
# lookup failed; every consumer degrades fail-safe (keep), and nothing
# here may gate the stale >24h delete (the diagnosis is never a
# precondition — gh-2105).
train_diagnosis() {
  local tag="$1" train_json failed_train train_id jobs_json in_flight
  train_json=$(gh run list --repo "$repo" --workflow ci.yml \
    --branch "$tag" --event push --limit 5 \
    --json databaseId,conclusion,url 2>/dev/null || echo "[]")
  in_flight=$(printf '%s' "$train_json" | jq -r '
    if any(.[]; .conclusion == null) then "in_flight" else "none" end
  ' 2>/dev/null || echo "unknown")
  failed_train=$(printf '%s' "$train_json" | jq -cr '
    ([.[] | select(.conclusion != "success" and .conclusion != null)][0]
      | if . == null then empty else
          {c: .conclusion, u: (.url // ""), i: .databaseId}
        end)' 2>/dev/null || echo "")
  [ -n "$failed_train" ] || return 0
  train_id=$(printf '%s' "$failed_train" | jq -r '.i // ""' 2>/dev/null || echo "")
  jobs_json=$(gh run view "$train_id" --repo "$repo" --json jobs 2>/dev/null || echo "")
  printf '%s\t%s\t%s\t%s\t%s\t%s' \
    "$train_id" \
    "$(printf '%s' "$failed_train" | jq -r '.c // "unknown"' 2>/dev/null || echo "unknown")" \
    "$(printf '%s' "$failed_train" | jq -r '.u // ""' 2>/dev/null || echo "")" \
    "$(printf '%s' "$jobs_json" | jq -r '[.jobs[] | select(.conclusion == "failure") | .name] | join(", ")' 2>/dev/null || echo "")" \
    "$(printf '%s' "$jobs_json" | jq -r '([.jobs[] | select(.name == "Sign release checksums")][0].conclusion // "")' 2>/dev/null || echo "")" \
    "$in_flight"
}


gh label create "$label" --repo "$repo" --color B60205 \
  --description "Auto-filed by the release-draft sweeper" >/dev/null 2>&1 || true

# ── inventory ──────────────────────────────────────────────────────────────
# gh api --paginate emits one JSON array per page; the jq stream filter
# flattens them all. Bucketing happens in jq so the whole rule is
# reviewable in one place:
#   artifacts (machine account + ai-(gh|pr)-<n> tag — gh-236)
#                    -> lifecycle-managed: reclaim at cycle end / 24h
#                    backstop / keep in flight; NEVER a sweep finding
#   stale + pipeline (bot author, the machine account, or well-formed
#                    release-draft-owner: run/<id>/job/<job>
#                    marker in the body) -> delete, name the marker run
#   stale + human (no marker)          -> keep, list
#   fresh                              -> untouched, EXCEPT the gh-2318
#                    reclaim: a marked draft whose owner run completed and
#                    whose tag's train failed with release-provenance
#                    SKIPPED (publish point unreachable) is deleted NOW
drafts=$(gh api --paginate "repos/$repo/releases" | jq -r --argjson maxage "$max_age" --arg assignee "$assignee" '
  [ .[] | select(.draft == true)
    | { stale: ((now - (.created_at | fromdateiso8601)) > $maxage),
        bucket: (
          # gh-236 first: the machine loop artefact-cache class, keyed on
          # the machine account AND the `ai-{ticketKey}` tag shape the
          # factory releaseArtefacts.buildTag() produces (lowercased,
          # non-alnum to '-', so `GH-2288` becomes `ai-gh-2288`,
          # `pr-2293` becomes `ai-pr-2293`). Human-authored ai-* drafts and
          # machine-authored vX.Y.Z drafts never match and fall through to
          # the buckets below.
          if (((.author.login // "") == $assignee)
              and ((.tag_name // "") | test("^ai-(gh|pr)-[0-9]+$")))
          then "artifacts"
          elif ((now - (.created_at | fromdateiso8601)) > $maxage)
          then (if ((.author.type // "User") == "Bot"
                    or ((.author.login // "") | test("\\[bot\\]$"))
                    or ((.author.login // "") == $assignee)
                    or ((.body // "") | test("release-draft-owner: run/[0-9]+/job/")))
               then "bot" else "human" end)
          else "fresh" end),
        tag: (.tag_name // "(untagged)"),
        id: (.id | tostring),
        created: (.created_at // "?"),
        author: (.author.login // "unknown"),
        # Exact creating run parsed from the ownership marker ("" for
        # non-marker drafts) — the creating run executed on main, so a
        # tag-ref run lookup cannot find it (gh-2008). The array wrapper
        # keeps exactly one value: a bare capture(...)? on a non-matching
        # body yields an EMPTY stream, and an empty field would drop the
        # whole draft row from the object stream.
        run: ([ (.body // "")
                | capture("release-draft-owner: run/(?<run>[0-9]+)/")?
                | .run ]
              | .[0] // "") } ]
  | sort_by(.created)[]
  # Column order matters: `read` collapses runs of whitespace IFS chars, so
  # the only possibly-EMPTY field (.run — marker-less drafts) must stay
  # LAST; .stale sits before it (gh-236: the artifacts branch branches on it).
  | [ .bucket, .tag, .id, .created, .author, .stale, .run ] | @tsv')

deleted=""
deleted_tags=""
deleted_count=0
failed_trains=0
# gh-2318: fresh (<24h) pipeline drafts reclaimed early — provably
# never-publishable (completed owner, failed train with skipped
# release-provenance). Tracked separately from the >24h sweep deletions.
reclaimed=""
reclaimed_tags=""
reclaimed_count=0
humans=""
human_tags=""
fresh_count=0
# gh-236: machine-loop artefact-cache drafts — lifecycle-managed, NOT
# sweep findings (reclaiming a cache whose ticket cycle ended is routine
# hygiene; the issue must auto-close when only cache traffic remains).
#   reclaimed at cycle end (ticket closed, any age) / swept by the 24h
#   backstop (ticket still open / state unknown) / kept (fresh + open).
art_reclaimed=""
art_reclaimed_tags=""
art_reclaimed_count=0
art_swept=""
art_swept_tags=""
art_swept_count=0
art_kept_tags=""
art_kept_count=0

while IFS=$'\t' read -r bucket tag id created author stale marker_run; do
  [ -n "$bucket" ] || continue
  case "$bucket" in
    artifacts)
      # gh-236: the machine loop's per-ticket artefact-cache draft
      # (`ai-gh-<n>` / `ai-pr-<n>` — timerAutoCommitAndSave.js snapshot
      # storage). The tag shape was validated by the jq bucket rule, so
      # `gh #<num>` / `pr #<num>` parsing below is total. State lookup:
      # the issues REST API serves PRs too (state=closed covers merged).
      # Any lookup failure yields an empty state — fail-safe: no early
      # reclaim, only the 24h backstop below may delete.
      rest="${tag#ai-}"
      kind="${rest%%-*}"
      num="${rest##*-}"
      state=$(gh api "repos/$repo/issues/$num" 2>/dev/null \
        | jq -r '.state // ""' 2>/dev/null || echo "")
      if [ "$state" = "closed" ]; then
        gh api -X DELETE "repos/$repo/releases/$id" >/dev/null
        art_reclaimed_count=$((art_reclaimed_count + 1))
        art_reclaimed="$art_reclaimed- \`$tag\` — created $created by @$author; ticket cycle ended (\`$kind #$num\` closed) — reclaimed at cycle end, no 24h wait: a closed cycle never resumes and the cache is recreated on any future first run (gh-236)\n"
        art_reclaimed_tags="$art_reclaimed_tags $tag"
      elif [ "$stale" = "true" ]; then
        gh api -X DELETE "repos/$repo/releases/$id" >/dev/null
        art_swept_count=$((art_swept_count + 1))
        art_swept="$art_swept- \`$tag\` — created $created by @$author; swept after 24h with the ticket still open or its state unknown (parked leg — the cache is recreated if the leg resumes; gh-236)\n"
        art_swept_tags="$art_swept_tags $tag"
      else
        art_kept_count=$((art_kept_count + 1))
        art_kept_tags="$art_kept_tags $tag"
      fi
      ;;
    fresh)
      # gh-2318: "fresh — untouched" is right while an in-flight run may
      # own the draft, but a fresh draft can already be PROVABLY
      # never-publishable: the v1.0.739 shape — a daily-child staging leg
      # minted the tag (release_tag_mint.sh) and staged the draft, the
      # freshly fired train failed upstream of release-provenance, and the
      # gh-2230 train-draft-guard either ran before the draft existed (a
      # long attach leg created it later) or kept it while its owner was
      # still in-flight. Nothing re-examined such a draft with train
      # knowledge, so it rotted the full 24h and re-filed the recurring
      # sweep issue. Apply the train guard's EXACT criterion here —
      # reclaim only a well-formed-marker draft whose owner run COMPLETED,
      # whose tag has NO queued/in-flight ci.yml push train, and whose
      # newest concluded ci.yml push train failed with release-provenance
      # SKIPPED (rerun --failed cannot resurrect skipped jobs — nobody
      # will ever publish it). Fail-safe keeps mirror the train guard:
      # unmarked/human drafts (E1), an in-flight owner run (possibly
      # mid-upload), ANY queued/in-flight tag train (it may still publish
      # even when an older train failed), a rerunnable FAILED provenance
      # (that draft stays the `rerun --failed` recovery vessel, gh-1899,
      # until the stale sweep), any lookup failure (never delete blind),
      # and untagged drafts (no train to diagnose).
      if [ -n "$marker_run" ] && [ "$tag" != "(untagged)" ]; then
        owner_status=$(gh run view "$marker_run" --repo "$repo" --json status 2>/dev/null \
          | jq -r '.status // empty' 2>/dev/null || echo "")
        if [ "$owner_status" = "completed" ]; then
          diag=$(train_diagnosis "$tag")
          train_url_found=$(printf '%s' "$diag" | cut -f3)
          failed_jobs=$(printf '%s' "$diag" | cut -f4)
          prov_conclusion=$(printf '%s' "$diag" | cut -f5)
          train_conclusion=$(printf '%s' "$diag" | cut -f2)
          train_in_flight=$(printf '%s' "$diag" | cut -f6)
          if [ -n "$diag" ] && [ "$prov_conclusion" = "skipped" ] \
            && [ "$train_in_flight" = "none" ]; then
            gh api -X DELETE "repos/$repo/releases/$id" >/dev/null
            reclaimed_count=$((reclaimed_count + 1))
            failed_trains=$((failed_trains + 1))
            run_url="${GITHUB_SERVER_URL:-https://github.com}/$repo/actions/runs/$marker_run"
            train_line="  - tag train: ${train_url_found:-<url unavailable>} concluded ${train_conclusion:-unknown} — the staged draft was never published (release-provenance, the sole publish point, is gated behind the tag train; a superseded failed train is never rerun — verify_pubdev_release.sh heals the LATEST tag only)"
            [ -n "$failed_jobs" ] && train_line="$train_line; failed jobs: $failed_jobs"
            reclaimed="$reclaimed- \`$tag\` — created $created by @$author; creating run: $run_url\n  - reclaimed early: the draft is younger than $((max_age / 3600))h but its publish point is unreachable (failed train, skipped release-provenance — rerun --failed cannot resurrect skipped jobs), so no in-flight run can own it and nobody will ever publish it (gh-2318)\n$train_line\n"
            reclaimed_tags="$reclaimed_tags $tag"
            continue
          fi
        fi
      fi
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
      # broken step instead of rotting silently (AC2). Marker drafts name
      # it exactly (the stamping scripts write run/<id>); untagged
      # author-bot drafts fall back to the newest run on the tag ref;
      # dispatch-time drafts have no run on their ref — then say so.
      run_url=""
      if [ -n "$marker_run" ]; then
        run_url="${GITHUB_SERVER_URL:-https://github.com}/$repo/actions/runs/$marker_run"
      elif [ "$tag" != "(untagged)" ]; then
        run_url=$(gh run list --repo "$repo" --branch "$tag" --limit 1 \
          --json url --jq '.[0].url // empty' 2>/dev/null || true)
      fi
      if [ -z "$run_url" ]; then
        if [ "$author" = "$assignee" ]; then
          # gh-2287: a machine-account draft carries no marker (the
          # automation created it with its own token, outside this repo's
          # runners) — name the account as the creator; the dispatch-time
          # "creating step died mid-run" prose below would misdirect the
          # RCA (gh-2105 class) — nothing died.
          run_url="the @$assignee automation loop (machine-account draft — created outside this repo's runners, no Actions run owns it)"
        else
          run_url="no run on ref \`$tag\` (dispatch-time draft — the creating step died mid-run)"
        fi
      fi
      # gh-2105: the staging draft's publish owner is the TAG TRAIN
      # (ci.yml's push run on the tag ref — release-provenance is the
      # sole publish point, gh-1801). When that train failed, the
      # creating run named above is NOT the broken step — the train is,
      # and a superseded failed train is never rerun
      # (verify_pubdev_release.sh heals the LATEST tag only). Name it
      # (URL + conclusion + failed jobs) so the sweep issue points at
      # the true blocker. Any lookup failure degrades to the static
      # prose below — the delete + issue filing must never depend on
      # the diagnosis.
      train_line=""
      if [ "$tag" != "(untagged)" ]; then
        diag=$(train_diagnosis "$tag")
        if [ -n "$diag" ]; then
          train_conclusion=$(printf '%s' "$diag" | cut -f2)
          train_url_found=$(printf '%s' "$diag" | cut -f3)
          failed_jobs=$(printf '%s' "$diag" | cut -f4)
          failed_trains=$((failed_trains + 1))
          train_line="  - tag train: ${train_url_found:-<url unavailable>} concluded ${train_conclusion:-unknown} — the staged draft was never published (release-provenance, the sole publish point, is gated behind the tag train; a superseded failed train is never rerun — verify_pubdev_release.sh heals the LATEST tag only)"
          [ -n "$failed_jobs" ] && train_line="$train_line; failed jobs: $failed_jobs"
          train_line="$train_line\n"
        fi
      fi
      deleted="$deleted- \`$tag\` — created $created by @$author; creating run: $run_url\n$train_line"
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

stale_count=$((deleted_count + reclaimed_count + $(printf '%s' "$humans" | grep -c . || true) ))

if [ "$stale_count" -gt 0 ]; then
  body=$(mktemp)
  {
    echo "**Sweep run:** $daily_url"
    echo "**Swept:** $deleted_count stale pipeline-created draft(s) older than $((max_age / 3600))h"
    printf '%b' "$deleted"
    # gh-2318: fresh drafts reclaimed early — their publish point is
    # unreachable, so the 24h wait would only delay the inevitable and
    # keep the sweep issue recurring (see the branch comment for the
    # full fail-safe keep list).
    if [ "$reclaimed_count" -gt 0 ]; then
      echo
      echo "**Reclaimed early (<$((max_age / 3600))h):** $reclaimed_count fresh pipeline draft(s) whose publish point is unreachable (gh-2318)"
      printf '%b' "$reclaimed"
    fi
    [ -n "$humans" ] && { echo; echo "**Kept (human drafts, listed not deleted — E1):**"; printf '%b' "$humans"; }
    # gh-236: cache lifecycle activity rides the filed issue for
    # visibility — in its own section, with the release-failure prose
    # never attached (nothing died, nothing failed to publish). It does
    # NOT contribute to the finding count above.
    if [ "$((art_reclaimed_count + art_swept_count))" -gt 0 ]; then
      echo
      echo "**Artefact-cache drafts (machine-loop \`ai-gh-*\`/\`ai-pr-*\` caches — lifecycle-managed, not release failures):** $art_reclaimed_count reclaimed at cycle end, $art_swept_count swept after 24h"
      printf '%b' "$art_reclaimed"
      printf '%b' "$art_swept"
    fi
    echo
    echo "**Fresh drafts (<$((max_age / 3600))h):** $fresh_count — untouched (an in-flight run may own them)"
    if [ "$art_kept_count" -gt 0 ]; then
      echo "**Artefact-cache drafts kept (ticket in flight):** $art_kept_count — reclaimed when the cycle closes, swept after 24h if parked (gh-236)"
    fi
    echo
    if [ "$failed_trains" -gt 0 ]; then
      echo "**Failed tag trains named above:** $failed_trains"
      echo
      echo "A stale draft whose tag train failed means the publish owner never ran — the draft was the gh-1801 staging draft and release-provenance (its sole publish point) is gated behind the failed train. Rerun the train if the tag should still ship; recurrence means a lifecycle guard is missing (issue #282)."
    elif [ "$deleted_count" -gt 0 ]; then
      echo "A stale draft means a \`gh release create\` step died between asset upload and publish — check the creating run's failed step. Recurrence means a lifecycle guard is missing (issue #282)."
    else
      # Findings are kept human drafts only (gh-236: cache lifecycle
      # traffic is excluded from the finding counters) — the create-death
      # prose would misdirect: nothing died and nothing failed to publish.
      echo "Kept human drafts above are listed, never deleted (E1) — delete by hand once done with them. Machine-loop artefact-cache drafts (\`ai-gh-*\`/\`ai-pr-*\`) are lifecycle-managed (gh-236): reclaimed when their ticket cycle closes, swept after 24h when the ticket stays open or its state is unknown."
    fi
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
      --body-file "$body" --label bug --label "$label" --assignee "$assignee" 2>/dev/null || true)
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
  echo "Deleted **$deleted_count** stale pipeline-created draft(s) • reclaimed early: **$reclaimed_count** • artefact-cache (gh-236): **$art_reclaimed_count** reclaimed at cycle end, **$art_swept_count** swept, **$art_kept_count** kept • failed tag trains named: **$failed_trains** • kept human drafts: **$(printf '%s' "$humans" | grep -c . || true)** • fresh (<$((max_age / 3600))h): **$fresh_count** • issue lifecycle: $issue_action"
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"

echo "sweeper: deleted=${deleted_tags# } reclaimed-early=${reclaimed_tags# } human-kept=${human_tags# } fresh=$fresh_count art-reclaimed=${art_reclaimed_tags# } art-swept=${art_swept_tags# } art-kept=$art_kept_count issue=$issue_action"
