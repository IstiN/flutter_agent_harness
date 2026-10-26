#!/usr/bin/env bash
# Post-publish orphan-draft twin cleanup (gh-1899).
#
# Why this exists: GitHub does NOT atomically enforce one release per tag.
# The lazy draft create (scripts/release_lazy_draft.sh) tolerates the
# view→create race with `|| true` on the assumption that a second
# `gh release create` for the same tag is rejected — it is not always:
# run 40163369302 (v1.0.641, fully green) created TWO draft releases for
# the same tag 87 ms apart (both binaries legs logged "lazy draft ready";
# duplicate-tag precedent: v0.1.120, release ids 363745676/363745677).
# release-provenance flips exactly ONE object to --draft=false --latest;
# the twin stays a draft forever — no failure-path guard can fire because
# every creating leg SUCCEEDED — so the only reclaimer was the 24h
# sweeper, which deleted the twin and filed the recurring
# "[daily-publish] stale release drafts swept" issue (gh-1899).
#
# This is the missing success-path half of the issue #282 invariant ("a
# run ends with its draft published or deleted — never orphaned") — the
# failure half lives in scripts/release_draft_guard.sh. Call it AFTER the
# publish flip (ci.yml release-provenance's "Upload provenance assets",
# release_attach_or_create.sh's servable-recovery publish):
#
#   - PRECONDITION: the tag must have a PUBLISHED release. A red
#     provenance (gh-1832 gate, signing) leaves the draft on purpose — it
#     is the recovery vessel for `gh run rerun --failed` — and this guard
#     must never take it away. No published release → no-op.
#   - Deletes every DRAFT for <tag> stamped with THIS run's ownership
#     marker (<!-- release-draft-owner: run/<GITHUB_RUN_ID>/job/<name> -->)
#     by release id via the API — those are proven orphan twins of the
#     just-published release, carrying unpublished-only assets (issue
#     #282 E2). The tag-based `gh release delete` is never used: under
#     duplicate releases a tag lookup is ambiguous, the very class this
#     guard exists for.
#   - Foreign-run and unmarked drafts are NEVER deleted here — the same
#     ownership discipline as release_draft_guard.sh; the daily sweeper
#     (scripts/sweep_stale_drafts.sh) reclaims those after 24h.
#
# Usage: release_draft_dedupe.sh <tag>
# Env: GITHUB_REPOSITORY, GITHUB_RUN_ID (Actions defaults), GH_TOKEN/
#      GITHUB_TOKEN.
set -euo pipefail

tag="${1:?usage: release_draft_dedupe.sh <tag>}"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID must be set (GitHub Actions default env)}"

# One listing, two questions. `gh api --paginate` concatenates one JSON
# array per page; -s flattens them into a single release roster before
# the filter runs (a per-page filter could miss a twin on another page).
list=$(gh api --paginate "repos/$repo/releases")

# PRECONDITION: the tag's release is published. Until the flip happens,
# a leftover draft is the recovery vessel, not an orphan.
if ! printf '%s' "$list" | jq -s -e --arg tag "$tag" \
    'flatten | any(.[]; .tag_name == $tag and .draft == false)' \
    >/dev/null; then
  echo "release draft dedupe: no published release for $tag — a leftover draft is the rerun --failed recovery vessel; nothing reclaimed (gh-1899)"
  exit 0
fi

# The marker's run segment is matched with its trailing slash so run/111
# can never match run/1111 (the prefix trap release_draft_guard.sh pins).
twins=$(printf '%s' "$list" | jq -s -r --arg tag "$tag" --arg run "run/$GITHUB_RUN_ID/" '
  [ flatten
    | .[]
    | select(.draft == true and .tag_name == $tag
        and ((.body // "") | contains("release-draft-owner: " + $run)))
    | .id | tostring ]
  | join("\n")')

if [ -z "$twins" ]; then
  echo "release draft dedupe: nothing to reclaim for $tag (no own-run twin drafts)"
  exit 0
fi

deleted=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  gh api -X DELETE "repos/$repo/releases/$id" >/dev/null
  deleted=$((deleted + 1))
  echo "::warning::release draft dedupe: deleted orphaned twin draft $id for $tag — the lazy-create race minted two releases for one tag and only one could be published (gh-1899); its assets were unpublished-only, the published release is the artifact store (issue #282 E2)"
done <<< "$twins"

echo "release draft dedupe: reclaimed $deleted orphaned twin draft(s) for $tag (gh-1899)"
