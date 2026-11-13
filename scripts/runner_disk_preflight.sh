#!/usr/bin/env bash
# gh-2152 — disk preflight + bounded, flip-aware reclaim for the
# self-hosted macOS publish legs (build-mobile.yml build-ios,
# build-macos.yml build-macos).
#
# Incident: run 43371287393 (2026-11-13) — the daily testflight leg's
# `Build iOS IPA` job died 7m08s in with NO step log: the GitHub Actions
# WORKER on the self-hosted macos-m5 box crashed with
# `System.IO.IOException: No space left on device` writing its own
# _diag log, mid-way through `Setup Flutter (self-hosted)`. The
# 3.47.7→3.50.0 pin bump forced a one-time ~2.3 GB SDK download + ~6 GB
# extraction into the persistent slot while the superseded tree sat under
# the slot GC's 2-day drain — on a box whose single disk is shared by up
# to three concurrent runner registrations (gh-2026). The sibling
# build-macos arm64 job died the same way ("runner lost communication").
#
# What this step does, BEFORE any multi-GB SDK work:
#   1. ALWAYS prints a df diagnosis line per checked path — every run's
#      log carries the box's free-space picture (gh-1692 doctrine: the
#      evidence must reach GitHub, not only the runner).
#   2. When free space is under the floor: a BOUNDED reclaim of
#      repo-known consumers —
#        - abandoned SDK slot `.stage.*` download dirs (a live download
#          keeps its mtime fresh; only dirs older than the stage drain
#          are abandoned),
#        - superseded SDK version trees, ONLY when the last `current`
#          flip is older than the in-flight drain (default 4h > any job's
#          90–150m ceiling, so no live sibling leg can still hold a tree
#          it resolved through `current` before the flip — the gh-2134
#          cross-registration deletion class stays dead) AND the tree
#          itself is not freshly installed (a concurrent leg may be
#          staging its flip onto it), and never the current target,
#        - gym logs older than the gym max age (they are uploaded as
#          failure artifacts — gh-1692; the on-box copies are
#          convenience only; a live gym run writes fresh mtimes).
#   3. Re-checks the floor; still under → a quotable ::error:: naming
#      the exact free/floor MB and the owner action, exit 1 — the
#      gh-1478 signal-first issue excerpt carries a real diagnosis
#      instead of "(no failed-step log available)".
#
# Deliberately NOT touched: ~/Library/Developer/Xcode/DerivedData
# (blanket purges break sibling registrations on the shared box —
# gh-2125 doctrine; ci.yml's gh-2134 scoped sweep owns that root),
# other registrations' _work/_temp trees, the git mirror (blobless).
#
# Env seams (tests): FAH_DISK_FLOOR_MB, FAH_SDK_ROOT, FAH_GYM_LOG_DIR,
# FAH_FLIP_DRAIN_SEC, FAH_STAGE_DRAIN_SEC, FAH_GYM_MAX_AGE_SEC.
# Behavioral coverage: test/runner_disk_preflight_test.dart.
set -euo pipefail

floor_mb="${FAH_DISK_FLOOR_MB:-20480}"
sdk_root="${FAH_SDK_ROOT:-$HOME/actions-runner-yoloit/flutter-sdk}"
gym_dir="${FAH_GYM_LOG_DIR:-$HOME/Library/Logs/gym}"
flip_drain="${FAH_FLIP_DRAIN_SEC:-14400}"
stage_drain="${FAH_STAGE_DRAIN_SEC:-360}"
gym_max_age="${FAH_GYM_MAX_AGE_SEC:-604800}"

if [ "$#" -eq 0 ]; then
  echo "::error::gh-2152 disk preflight: no paths given — pass the workspace and the SDK slot root" >&2
  exit 2
fi

now_s=$(date +%s)

# GNU stat does not dereference symlinks by default (what the flip clock
# needs) and so does BSD stat — but their flags differ, so pick the
# binary by behavior, never by guess (`stat -f %m` on GNU means
# FILESYSTEM fields and would silently return garbage).
mtime_of() {
  if stat --version >/dev/null 2>&1; then
    stat -c %Y "$1" 2>/dev/null || echo 0
  else
    stat -f %m "$1" 2>/dev/null || echo 0
  fi
}

# df needs an existing path; the SDK slot root may not exist yet on a
# fresh runner. The VOLUME is what matters — walk up to the nearest
# existing ancestor and measure that.
resolve_existing() {
  local p="$1"
  while [ "$p" != "/" ] && ! df -Pm "$p" >/dev/null 2>&1; do
    p=$(dirname "$p")
  done
  printf '%s' "$p"
}

free_mb_of() {
  local free p
  p=$(resolve_existing "$1")
  free=$(df -Pm "$p" 2>/dev/null | awk 'NR==2 {print $4}')
  [ -n "$free" ] || free=0
  printf '%s' "$free"
}

mount_of() {
  local p
  p=$(resolve_existing "$1")
  df -Pm "$p" 2>/dev/null | awk 'NR==2 {print $6}'
}

reclaimed=0

# ── floor measurement (BEFORE any reclaim — a green box reclaims nothing) ──
measure_floor() {
  min_free=""
  min_mount=""
  for p in "$@"; do
    free=$(free_mb_of "$p")
    mount=$(mount_of "$p")
    echo "gh-2152 disk preflight: $p on ${mount:-unknown}: $free MB free (floor ${floor_mb} MB)"
    if [ -z "$min_free" ] || [ "$free" -lt "$min_free" ]; then
      min_free=$free
      min_mount=$mount
    fi
  done
}

measure_floor "$@"
under_floor=false
[ "$min_free" -lt "$floor_mb" ] && under_floor=true

# ── bounded reclaim (only when the box is squeezed) ───────────────────────
if [ "$under_floor" = true ]; then
if [ -d "$sdk_root" ]; then
  # 1. Abandoned SDK download stages.
  for stage in "$sdk_root"/.stage.*; do
    [ -d "$stage" ] || continue
    age=$((now_s - $(mtime_of "$stage")))
    if [ "$age" -ge "$stage_drain" ]; then
      rm -rf "$stage"
      echo "gh-2152 reclaim: abandoned SDK stage $(basename "$stage") (age ${age}s >= ${stage_drain}s drain)"
      reclaimed=$((reclaimed + 1))
    fi
  done

  # 2. Superseded SDK version trees — flip-clock protected.
  current_target=""
  if [ -L "$sdk_root/current" ]; then
    current_target=$(readlink "$sdk_root/current")
    flip_age=$((now_s - $(mtime_of "$sdk_root/current")))
  else
    # No `current` — nothing to protect via the flip clock; the per-tree
    # freshness guard below still covers a concurrent install.
    flip_age=$((flip_drain + 1))
  fi
  if [ "$flip_age" -lt "$flip_drain" ]; then
    echo "gh-2152 reclaim: skipping superseded SDK trees — last flip ${flip_age}s ago is inside the ${flip_drain}s in-flight window (a sibling leg may still resolve them through current; gh-2134 class)"
  else
    for dir in "$sdk_root"/*/; do
      [ -d "$dir" ] || continue
      name=$(basename "$dir")
      case "$name" in current|.stage.*) continue ;; esac
      if ! [[ "$name" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then continue; fi
      tree_path="$sdk_root/$name"
      if [ "$tree_path" = "$current_target" ]; then
        continue # the live target is never eligible
      fi
      tree_age=$((now_s - $(mtime_of "$tree_path")))
      if [ "$tree_age" -lt "$stage_drain" ]; then
        continue # a seconds-old install may be a concurrent leg's staging flip
      fi
      rm -rf "$tree_path"
      echo "gh-2152 reclaim: superseded SDK tree $name (flip ${flip_age}s ago >= ${flip_drain}s drain, tree age ${tree_age}s)"
      reclaimed=$((reclaimed + 1))
    done
  fi
fi

# 3. Stale gym logs (failure diagnostics — already uploaded as artifacts).
if [ -d "$gym_dir" ]; then
  while IFS= read -r -d '' f; do
    rm -f "$f"
    echo "gh-2152 reclaim: gym log $(basename "$f") (older than $((gym_max_age / 86400))d — uploaded as a failure artifact, gh-1692)"
    reclaimed=$((reclaimed + 1))
  done < <(find "$gym_dir" -type f -mmin "+$((gym_max_age / 60))" -print0 2>/dev/null)
fi
fi # under_floor

# ── floor verdict ─────────────────────────────────────────────────────────
measure_floor "$@"

if [ "$min_free" -lt "$floor_mb" ]; then
  echo "::error::gh-2152 disk preflight: only ${min_free} MB free (floor ${floor_mb} MB) on ${min_mount:-unknown} after reclaiming ${reclaimed} item(s) — free disk on the self-hosted macos-m5 box (stale Xcode DerivedData/archives, runner _work trees) BEFORE re-running; failing fast BEFORE the multi-GB Flutter SDK install so the failure excerpt is diagnosable (gh-2152)" >&2
  exit 1
fi

if [ "$reclaimed" -gt 0 ]; then
  echo "gh-2152 disk preflight: OK — ${min_free} MB free after reclaiming ${reclaimed} item(s)"
else
  echo "gh-2152 disk preflight: OK — ${min_free} MB free, nothing to reclaim"
fi
