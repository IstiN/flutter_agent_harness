#!/usr/bin/env bash
# pin_release.sh — advance the `vpinned` release marker to a freshly signed
# tag. PURE RELEASE-ARTIFACT MANIPULATION: no commits, no pushes, no
# working-tree mutation — the marker lives entirely in GitHub Releases.
# The tag-scoped install-pin-bump CI job runs this after release-provenance
# published SHA256SUMS(.sig) for the tag.
#
# Trust model (SEC-07 #795): the marker is only a POINTER. Before it moves,
# the target release must pass check_install_pin.sh (signature verifies
# against the committed trust anchor + full platform coverage); after it
# moves, the gate runs again against the marker itself. A compromised
# marker therefore degrades to a DoS (install fails closed), never to a
# bad binary — the installer's embedded anchor is the real trust root.
#
# Usage:
#   pin_release.sh <tag>            point the vpinned marker at <tag> (vX.Y.Z)
#   pin_release.sh is-newer <a> <b> exit 0 iff semver(a) > semver(b)
#                                   (v-prefixes stripped; numeric compare)
#
# Environment:
#   GH_TOKEN             release write token (live mode)
#   PIN_RELEASE_BASE     file:// dir acting as the release root — fixture
#                        mode: the marker becomes $base/vpinned/PINNED_VERSION
#                        and no gh/network is touched (selftest/dry runs)
#   PIN_RELEASE_REPO     owner/repo for gh calls (default: IstiN/flutter_agent_harness)
#   MARKER_TAG           marker release/tag name (default: vpinned)
# POSIX-only below: Ubuntu's /bin/sh is dash — no pipefail, no arrays/[[]].
# Enable pipefail only where the shell supports it (same convention as
# site/install.sh.template).
set -eu
( set -o pipefail ) 2>/dev/null && set -o pipefail || true

MARKER="${MARKER_TAG:-vpinned}"
REPO="${PIN_RELEASE_REPO:-IstiN/flutter_agent_harness}"
BASE="${PIN_RELEASE_BASE:-https://github.com/$REPO/releases/download}"

# ── is-newer <a> <b>: numeric semver compare, v-prefix tolerated ────────────
# POSIX-pure on purpose: ubuntu runners give `sh` = dash and `awk` = mawk,
# whose printf does not apply the %010d zero-padding this compare relies on
# (the old awk ver_key made equal keys and silently reported "not newer").
# Here every component is normalized with the SHELL printf (dash/bash both
# implement %010d) to a zero-padded digit string — pure digits of equal
# length, so the lexical `>` is collation-independent.
if [ "${1:-}" = "is-newer" ]; then
  a="$(printf '%s' "${2:?usage: is-newer <a> <b>}" | sed 's/^v//')"
  b="$(printf '%s' "${3:?usage: is-newer <a> <b>}" | sed 's/^v//')"
  a_num="${a%%-*}"; a_sfx="${a#"$a_num"}"
  b_num="${b%%-*}"; b_sfx="${b#"$b_num"}"
  # leading digits of a dotted component, zero-stripped, padded to 10
  comp10() {
    c="$(printf '%s' "$1" | tr -cd '0-9' | sed -e 's/^0*//' -e 's/^$/0/')"
    printf '%010d' "$c"
  }
  split3() { # $1 = "X.Y.Z" → newline-separated X, Y, Z (missing pieces empty)
    rest="$1"
    c1="${rest%%.*}"; [ "$c1" = "$rest" ] && rest="" || rest="${rest#*.}"
    c2="${rest%%.*}"; [ "$c2" = "$rest" ] && c3="" || c3="${rest#*.}"
    printf '%s\n%s\n%s\n' "$c1" "$c2" "$c3"
  }
  # sed-extract instead of `set -- $(...)` — word-splitting drops the empty
  # components, and `set -u` then kills $2/$3 in dash.
  a123="$(split3 "$a_num")"
  a1="$(printf '%s\n' "$a123" | sed -n 1p)"
  a2="$(printf '%s\n' "$a123" | sed -n 2p)"
  a3="$(printf '%s\n' "$a123" | sed -n 3p)"
  b123="$(split3 "$b_num")"
  b1="$(printf '%s\n' "$b123" | sed -n 1p)"
  b2="$(printf '%s\n' "$b123" | sed -n 2p)"
  b3="$(printf '%s\n' "$b123" | sed -n 3p)"
  ka="$(comp10 "$a1")$(comp10 "$a2")$(comp10 "$a3")"
  kb="$(comp10 "$b1")$(comp10 "$b2")$(comp10 "$b3")"
  if [ "$ka" != "$kb" ]; then
    [ "$ka" \> "$kb" ]
    exit $?
  fi
  # equal numerics: a release outranks its own pre-release; release vs
  # release is equal (NOT newer)
  if [ -z "$a_sfx" ] && [ -n "$b_sfx" ]; then exit 0; fi
  if [ -n "$a_sfx" ] || [ -z "$b_sfx" ]; then exit 1; fi
  [ "$a_sfx" \> "$b_sfx" ]
  exit $?
fi

tag="${1:?usage: pin_release.sh <vX.Y.Z>}"
case "$tag" in
  v*) version="${tag#v}" ;;
  *)  version="$tag"; tag="v$tag" ;;
esac
echo "pin_release: target $tag (marker: $MARKER)"

# The gate speaks URLs; a bare fixture path gets a file:// scheme. The raw
# path is kept for fixture-mode marker writes.
BASE_URL="$BASE"
case "$BASE_URL" in
  *://*) ;;
  *) BASE_URL="file://$BASE_URL" ;;
esac

fetch_text() {
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$1"; else wget -qO- "$1"; fi
}

# ── 1. read the current marker (absent = first pin) ─────────────────────────
current=""
if current="$(fetch_text "$BASE_URL/$MARKER/PINNED_VERSION" 2>/dev/null | tr -d '[:space:]')"; then
  echo "pin_release: marker currently at $current"
else
  echo "pin_release: no marker yet — first pin"
fi
if [ -n "$current" ] && ! "$0" is-newer "$version" "$current"; then
  echo "pin_release: marker is already at $current (>= $tag) — nothing to do."
  exit 0
fi

# ── 2. the target must pass the provenance gate BEFORE the marker moves ─────
# FA_PIN_TARGET checks the concrete tag regardless of where the marker
# currently points; PATH overrides keep a fixture-mode gate anchored here.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FA_PIN_TARGET="$tag" \
FA_PIN_CONFIG="${FA_PIN_CONFIG:-$SCRIPT_DIR/../site/install-config.yaml}" \
FA_PIN_INSTALLER="${FA_PIN_INSTALLER:-$SCRIPT_DIR/../site/install.sh}" \
FA_PIN_RELEASE_BASE="$BASE_URL" \
  bash "$SCRIPT_DIR/check_install_pin.sh" \
  || { echo "::error::pin_release: $tag failed the provenance gate — marker NOT moved"; exit 1; }

# ── 3. publish the marker ───────────────────────────────────────────────────
# NB: gh names the uploaded asset after the FILE basename — the file must
# literally be called PINNED_VERSION inside a temp dir.
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/pin_marker.XXXXXX")"
printf '%s\n' "$tag" > "$tmp_dir/PINNED_VERSION"
if [ -n "${PIN_RELEASE_BASE:-}" ]; then
  # Fixture mode: write the marker file directly into the release root.
  mkdir -p "$BASE/$MARKER"
  cp "$tmp_dir/PINNED_VERSION" "$BASE/$MARKER/PINNED_VERSION"
  echo "pin_release: fixture marker written: $BASE/$MARKER/PINNED_VERSION"
else
  if ! gh release view "$MARKER" --repo "$REPO" >/dev/null 2>&1; then
    echo "pin_release: creating marker release $MARKER"
    gh release create "$MARKER" --repo "$REPO" \
      --title "Pinned known-good release" \
      --notes "Pointer release: the PINNED_VERSION asset names the current known-good Fa release. Advanced only by the install-pin-bump CI job after signed provenance (SEC-07 #795). The marker itself is untrusted — installers verify the pointed release's SHA256SUMS.sig against the committed trust anchor."
  fi
  gh release upload "$MARKER" "$tmp_dir/PINNED_VERSION" --repo "$REPO" --clobber
  echo "pin_release: marker uploaded: $MARKER -> $tag"
fi
rm -rf "$tmp_dir"

# ── 4. post-publish: the marker itself must now verify end-to-end ───────────
retried=false
for attempt in 1 2 3; do
  if FA_PIN_CONFIG="${FA_PIN_CONFIG:-$SCRIPT_DIR/../site/install-config.yaml}" \
     FA_PIN_INSTALLER="${FA_PIN_INSTALLER:-$SCRIPT_DIR/../site/install.sh}" \
     FA_PIN_RELEASE_BASE="$BASE_URL" \
     bash "$SCRIPT_DIR/check_install_pin.sh"; then
    retried=true
    break
  fi
  echo "pin_release: post-publish gate attempt $attempt failed — retrying in 10s (asset propagation?)"
  sleep 10
done
$retried || { echo "::error::pin_release: marker does not verify after publish"; exit 1; }

echo ""
echo "pin_release: marker $MARKER now points at $tag (provenance-verified)"
