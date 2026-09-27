#!/usr/bin/env bash
# auto_bump_install_pin.sh — advance the installer pin to a freshly released,
# signed tag. Fully automatic: the ci.yml `install-pin-bump` job runs this
# after release-provenance publishes the signed SHA256SUMS for the tag, so
# fa1.dev's pinned default tracks known-good releases without any manual
# step (the #1015 lesson: a pin nobody advances rots; a pin advanced without
# verification is a supply-chain hole — this script only ever pins a release
# whose signature verifies against the committed trust anchor).
#
# Usage:
#   auto_bump_install_pin.sh <tag>   bump the pin to <tag> (vX.Y.Z), commit + push
#   auto_bump_install_pin.sh is-newer <a> <b>
#                                    exit 0 iff semver(a) > semver(b)
#                                    (v-prefixes stripped; numeric compare)
#
# Environment:
#   PIN_BUMP_NO_PUSH=1  everything except the final git push (dry run)
#
# Requires: dart (gen_installers), bash scripts/check_install_pin.sh
# (live provenance re-verification, with retries — release asset
# propagation can lag the upload by a few seconds).
set -euo pipefail

# Re-exec from a stable temp copy BEFORE any git mutation: the bump flow
# resets the working tree to origin/main mid-run, and the script may not
# exist on main yet (or differ from the tagged copy) — replacing the
# running script file aborts bash mid-read (observed on macOS as a silent
# non-zero from a sub-invocation, which then took the wrong branch).
if [ -z "${PIN_BUMP_REEXEC:-}" ]; then
  export PIN_BUMP_REEXEC=1
  export PIN_BUMP_REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  tmp_self="$(mktemp "${TMPDIR:-/tmp}/auto_bump_install_pin.XXXXXX")"
  cp "$0" "$tmp_self"
  chmod +x "$tmp_self"
  # Snapshot the pin gate next to us for the same reason: the working-tree
  # reset below may remove it (a tag/main that predates the gate).
  if [ -f "$PIN_BUMP_REPO_ROOT/scripts/check_install_pin.sh" ]; then
    cp "$PIN_BUMP_REPO_ROOT/scripts/check_install_pin.sh" "${tmp_self}.gate"
    chmod +x "${tmp_self}.gate"
    export PIN_BUMP_GATE="${tmp_self}.gate"
  fi
  exec bash "$tmp_self" "$@"
fi

PIN_GATE="${PIN_BUMP_GATE:-scripts/check_install_pin.sh}"

REPO_ROOT="${PIN_BUMP_REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$REPO_ROOT"

# ── is-newer <a> <b>: numeric semver compare, v-prefix tolerated ────────────
if [ "${1:-}" = "is-newer" ]; then
  a="$(printf '%s' "${2:?usage: is-newer <a> <b>}" | sed 's/^v//')"
  b="$(printf '%s' "${3:?usage: is-newer <a> <b>}" | sed 's/^v//')"
  # Pad to three numeric components; non-numeric tails sort lowest.
  ver_key() { printf '%s' "$1" | awk -F. '{ for (i=1; i<=3; i++) printf "%010d ", (i<=NF && $i ~ /^[0-9]+$/) ? $i : -1; }'; }
  [ "$(ver_key "$a")" != "$(ver_key "$b")" ] && [ "$(ver_key "$a")" \> "$(ver_key "$b")" ]
  exit $?
fi

tag="${1:?usage: auto_bump_install_pin.sh <vX.Y.Z>}"
case "$tag" in
  v*) version="${tag#v}" ;;
  *)  version="$tag"; tag="v$tag" ;;
esac

echo "Auto-bump install pin: target $tag"

# ── 1. current pin; skip (green) when the target is not strictly newer ─────
git fetch origin main --tags --quiet
git reset --hard origin/main --quiet
config="site/install-config.yaml"
current="$(sed -n 's/^ *pinned_cli_version: *"\{0,1\}\([^" ]*\)"\{0,1\} *$/\1/p' "$config" | head -1)"
[ -n "$current" ] || { echo "::error::no pinned_cli_version in $config"; exit 1; }
if ! "$0" is-newer "$version" "$current"; then
  echo "Auto-bump: pin is already at $current (>= $tag) — nothing to do."
  exit 0
fi
echo "Auto-bump: $current -> $version"

# ── 2. rewrite the pin, regenerate the installers from the config ───────────
sed -i.bak "s/^\( *pinned_cli_version: *\"\{0,1\}\)[^\" ]*\(\"\{0,1\} *\)$/\1$version\2/" "$config"
rm -f "$config.bak"
dart run scripts/gen_installers.dart

# ── 3. the new pin must satisfy its own gate BEFORE it ships ────────────────
# check_install_pin re-verifies drift + live provenance + asset coverage;
# retry while the just-uploaded release assets propagate.
verified=false
gate_log="$(mktemp "${TMPDIR:-/tmp}/pin_gate_log.XXXXXX")"
for attempt in 1 2 3 4 5; do
  # Paths must be explicit: a snapshot gate lives in TMPDIR and would
  # otherwise resolve its own defaults there.
  if FA_PIN_CONFIG="$REPO_ROOT/site/install-config.yaml" \
     FA_PIN_INSTALLER="$REPO_ROOT/site/install.sh" \
     bash "$PIN_GATE" > "$gate_log" 2>&1; then
    verified=true
    break
  fi
  echo "Auto-bump: pin gate attempt $attempt failed — retrying in 15s (release asset propagation?):"
  tail -2 "$gate_log"
  sleep 15
done
$verified || { echo "::error::pin gate rejected $tag — refusing to publish an unverifiable pin:"; cat "$gate_log"; exit 1; }

# ── 4. commit + push (rebase over racing main pushes) ───────────────────────
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
for attempt in 1 2 3; do
  git add "$config" site/install.sh site/install.ps1 site/install.bat site/setup.sh site/setup.ps1
  git commit -m "chore(install): bump pinned default to $tag (auto, provenance-verified)" && committed=true || committed=false
  if [ "${PIN_BUMP_NO_PUSH:-0}" = "1" ]; then
    echo "Auto-bump: PIN_BUMP_NO_PUSH=1 — stopping before push."
    exit 0
  fi
  if git pull --rebase origin main --quiet && git push origin main; then
    echo "Auto-bump: pin $tag pushed — Pages redeploys fa1.dev from this commit."
    exit 0
  fi
  echo "Auto-bump: push raced (attempt $attempt) — rebasing over origin/main."
  git rebase --abort 2>/dev/null || true
  git reset --hard origin/main --quiet
  # Re-apply on the refreshed main: current pin may have moved past us.
  current="$(sed -n 's/^ *pinned_cli_version: *"\{0,1\}\([^" ]*\)"\{0,1\} *$/\1/p' "$config" | head -1)"
  if ! "$0" is-newer "$version" "$current"; then
    echo "Auto-bump: another run already advanced the pin to $current — done."
    exit 0
  fi
  sed -i.bak "s/^\( *pinned_cli_version: *\"\{0,1\}\)[^\" ]*\(\"\{0,1\} *\)$/\1$version\2/" "$config"
  rm -f "$config.bak"
  dart run scripts/gen_installers.dart
done
echo "::error::auto_bump_install_pin: could not push after 3 attempts"
exit 1
