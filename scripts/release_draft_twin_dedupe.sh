#!/usr/bin/env bash
# Post-create twin-draft self-dedupe (gh-2372) — the success-path half of
# the issue #282 invariant for CHILD-run drafts.
#
# Why this exists: the view→create race between sibling jobs of ONE
# release run is NOT benign for DRAFT objects. GitHub does not enforce
# one release per tag for drafts (gh-1899, v1.0.641: twin drafts 87 ms
# apart), so when two legs of the same build-macos.yml run hit the race
# window — production: the SAME SECOND (v1.0.760: build-extension won +
# was published, its build-macos-cli twin rotted 43h and was swept by
# gh-2372; v1.0.763: build-macos-cli-arm64 won, the build-extension twin
# is a live zero-asset draft) — BOTH `gh release create --draft` calls
# succeed and two twin drafts are born. The tag train publishes exactly
# ONE object; the twin rots until the daily sweeper deletes it and
# re-files the recurring "[daily-publish] stale release drafts swept"
# issue. No existing guard fires: every creating job SUCCEEDED (the
# failure-path guards never run), and release_draft_dedupe.sh matches
# only twins stamped with the TRAIN's GITHUB_RUN_ID — child-run twins
# carry the build-macos run's id and are invisible to it.
#
# This closes the race at the source. Call it RIGHT AFTER a successful
# draft create (release_lazy_draft.sh + release_attach_or_create.sh):
#
#   - OUR draft = a same-tag DRAFT whose body carries EXACTLY this job's
#     ownership marker (release-draft-owner: run/<id>/job/<name>, the
#     stampers' exact shape; capture + full-value equality, so run/111
#     can never match run/1111 — the release_draft_guard.sh discipline).
#     A job can only ever delete the draft(s) it just created.
#   - WINNER ELECTION (deterministic): the OLDEST same-tag release wins —
#     ids are monotonic, so the first-created object always has the
#     lowest id and a later creator always sees it in its listing; no
#     interleaving can make both jobs keep a twin. The winner is any
#     older same-tag release that is PUBLISHED (the train already flipped
#     the sibling) or PIPELINE-created: a well-formed
#     release-draft-owner marker in the body, author.type == Bot, a
#     *[bot] login, or the machine account (DAILY_PUBLISH_ASSIGNEE —
#     the sweeper's exact gh-2287 bucket rule, kept consistent).
#   - When a winner exists, every draft carrying OUR exact marker is
#     deleted BY ID via the API — never a tag-based delete (drafts may
#     carry an empty tag_name; under duplicate releases a tag lookup is
#     ambiguous — the very class this guards). The caller then attaches
#     into the winner by tag — release_lazy_draft's gh-1801 contract
#     "the loser just uploads into the winner's release", now actually
#     true.
#   - HUMAN drafts (unmarked, User author) never win and never trigger a
#     self-delete (E1): the pipeline must not ride a human draft, and a
#     human draft must never be deleted by automation. Our draft stays
#     and is reclaimed by the 24h sweeper as today.
#   - BEST-EFFORT (gh-1899 review convention): every failure here — the
#     listing blips, one failed DELETE — warns and exits 0. The call
#     site is a green create path; a cleanup blip must never red a leg
#     whose leftover is harmless (the sweeper remains the backstop, and
#     sweep_stale_drafts.sh reclaims fresh twins whose tag is already
#     published). Only a malformed RELEASE_DRAFT_IDENTITY fails loud —
#     the marker-stamping scripts already validate it pre-create; a
#     marker nothing could ever match is a configuration bug, not a
#     cleanup blip.
#
# Usage: release_draft_twin_dedupe.sh <tag>
# Env: GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_JOB (Actions defaults),
#      RELEASE_DRAFT_IDENTITY (optional leg-suffixed override, same as
#      release_lazy_draft.sh / release_draft_guard.sh),
#      DAILY_PUBLISH_ASSIGNEE (default ai-teammate), GH_TOKEN/GITHUB_TOKEN.
set -euo pipefail

tag="${1:?usage: release_draft_twin_dedupe.sh <tag>}"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
identity="${RELEASE_DRAFT_IDENTITY:-run/${GITHUB_RUN_ID:?GITHUB_RUN_ID must be set (GitHub Actions default env)}/job/${GITHUB_JOB:?GITHUB_JOB must be set (GitHub Actions default env)}}"
assignee="${DAILY_PUBLISH_ASSIGNEE:-ai-teammate}"

printf '%s' "$identity" | grep -Eq '^run/[0-9]+/job/[A-Za-z0-9_-]+$' || {
  echo "::error::RELEASE_DRAFT_IDENTITY '$identity' does not match 'run/<id>/job/<name>' — the marker we stamped could never be matched by any guard" >&2
  exit 1
}

# One paginated listing answers both questions (ours + winner). A blip
# degrades to keep — never judge twins off a partial roster.
list=$(gh api --paginate "repos/$repo/releases" 2>/dev/null) || {
  echo "::warning::release twin dedupe: the release listing failed — cannot judge twins, keeping our draft for $tag" >&2
  exit 0
}

# Same-tag drafts carrying EXACTLY our marker (capture + full-value
# equality — the prefix trap release_draft_guard.sh pins: run/111/job/x
# must never match run/1111/job/x or run/111/job/x-longer).
mine_ids=$(printf '%s' "$list" | jq -s -r --arg tag "$tag" --arg id "$identity" '
  [ flatten[]
    | select(.draft == true and .tag_name == $tag)
    | select((((.body // "")
        | (capture("release-draft-owner: (?<m>run/[0-9]+/job/[A-Za-z0-9_-]+)")? | .m) // "")
        == $id))
    | .id | tostring ]
  | unique | .[]')

if [ -z "$mine_ids" ]; then
  echo "release twin dedupe: no own draft for $tag in the listing — nothing to clean"
  exit 0
fi

# Deterministic winner: any older (lower id — first-created) same-tag
# release that is published or pipeline-created.
mine_min=$(printf '%s\n' "$mine_ids" | sort -n | head -1)
winner=$(printf '%s' "$list" | jq -s -r --arg tag "$tag" --arg assignee "$assignee" --argjson mine "$mine_min" '
  [ flatten[]
    | select(.tag_name == $tag and .id < $mine)
    | select(.draft == false
        or ((.author.type // "User") == "Bot")
        or ((.author.login // "") | test("\\[bot\\]$"))
        or ((.author.login // "") == $assignee)
        or ((.body // "") | test("release-draft-owner: run/[0-9]+/job/[A-Za-z0-9_-]+"))) ]
  | length > 0')

if [ "$winner" != "true" ]; then
  echo "release twin dedupe: our draft for $tag is the oldest same-tag release — it stays"
  exit 0
fi

deleted=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  if gh api -X DELETE "repos/$repo/releases/$id" >/dev/null 2>&1; then
    deleted=$((deleted + 1))
  else
    echo "::warning::release twin dedupe: deleting our twin draft $id for $tag failed — the daily sweeper reclaims it (fresh twins whose tag is published are reclaimed immediately; gh-2372)" >&2
  fi
done <<< "$mine_ids"

if [ "$deleted" -gt 0 ]; then
  echo "::warning::release twin dedupe: deleted $deleted own twin draft(s) for $tag — an older release already owns the tag (the same-run sibling create race, gh-2372); the caller attaches into the winner by tag (gh-1801 tolerance), nothing was lost: the twin carried only our unpublished assets" >&2
fi
exit 0
