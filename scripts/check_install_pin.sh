#!/usr/bin/env bash
# check_install_pin.sh — SEC-07 (#795) pin-integrity gate for the vpinned
# release-marker model.
#
# The installer's default does NOT carry a baked-in version: it resolves
# the `vpinned` release marker (a GitHub Release whose PINNED_VERSION asset
# names the current known-good release). That removes the #1015 failure
# class (a committed pin rotting) — and this gate guards the marker:
#
#   1. E_PIN_DRIFT — the generated site/install.sh must track the vpinned
#      marker and embed a trust anchor identical to the config's
#      signing_public_key.
#   2. E_PIN_MISSING / E_PIN_INVALID — the marker release must publish a
#      well-formed PINNED_VERSION (a vX.Y.Z-ish tag).
#   3. E_PIN_PROVENANCE_MISSING / E_PIN_PROVENANCE_INVALID — the MARKED
#      release must publish SHA256SUMS + a signature that verifies against
#      the committed trust anchor (the marker itself is never trusted —
#      this is what makes a tampered pointer fail closed).
#   4. E_PIN_ASSET_COVERAGE — the signed manifest must cover every
#      platform archive the installer can request.
#
# Modes:
#   (default)   full gate: drift checks + marker + marked-release provenance
#   --offline   drift checks only (no network)
#
# FA_PIN_TARGET=<tag> verifies a concrete tag instead of following the
# marker — pin_release.sh uses this to prove a NEW release BEFORE pointing
# the marker at it.
#
# Overridable inputs (tests/fixtures):
#   FA_PIN_CONFIG        install-config.yaml path (default: site/install-config.yaml)
#   FA_PIN_INSTALLER     generated install.sh path (default: site/install.sh)
#   FA_PIN_RELEASE_BASE  release download base (default:
#                        https://github.com/IstiN/flutter_agent_harness/releases/download)
#
# Exit 0 with "ok" lines on success; exit 1 with an E_PIN_* line on failure
# (the selftest greps for these markers).
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${FA_PIN_CONFIG:-$REPO_ROOT/site/install-config.yaml}"
INSTALLER="${FA_PIN_INSTALLER:-$REPO_ROOT/site/install.sh}"
RELEASE_BASE="${FA_PIN_RELEASE_BASE:-https://github.com/IstiN/flutter_agent_harness/releases/download}"
TARGET_OVERRIDE="${FA_PIN_TARGET:-}"
OFFLINE=false
[ "${1:-}" = "--offline" ] && OFFLINE=true

err() { printf '✘ %s\n' "$*" >&2; exit 1; }
ok()  { printf 'ok  %s\n' "$*"; }

# Every archive site/install.sh can request — the signed manifest must
# cover all of them, or some platform installs unverifiable.
REQUIRED_ASSETS="fa-linux-x64.tar.gz fa-linux-arm64.tar.gz fa-macos-arm64.tar.gz fa-macos-x64.tar.gz fa-windows-x64.zip"

fetch() { # fetch <url> <out>
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1" -o "$2"
  else
    wget -qO "$2" "$1"
  fi
}

# ── 1. drift: generated installer tracks the marker; anchors match ─────────
[ -f "$CONFIG" ] || err "E_PIN_CONFIG: install config not found: $CONFIG"
[ -f "$INSTALLER" ] || err "E_PIN_DRIFT: generated installer not found: $INSTALLER"
grep -q 'FA_VERSION="${FA_VERSION:-vpinned}"' "$INSTALLER" \
  || err "E_PIN_DRIFT: $INSTALLER does not default to the vpinned marker — regenerate installers (dart run scripts/gen_installers.dart), never hand-edit generated files"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
sed -n '/BEGIN PUBLIC KEY/,/END PUBLIC KEY/p' "$CONFIG" | sed 's/^ *//' > "$work/config-anchor.pem"
grep -q "BEGIN PUBLIC KEY" "$work/config-anchor.pem" \
  || err "E_PIN_CONFIG: no signing_public_key block in $CONFIG"
openssl pkey -pubin -in "$work/config-anchor.pem" -noout 2>/dev/null \
  || err "E_PIN_CONFIG: signing_public_key in $CONFIG does not parse as a public key"
sed -n '/BEGIN PUBLIC KEY/,/END PUBLIC KEY/p' "$INSTALLER" \
  | sed "1s/^.*BEGIN/-----BEGIN/; \$s/END.*\$/END PUBLIC KEY-----/" > "$work/installer-anchor.pem"
cmp "$work/config-anchor.pem" "$work/installer-anchor.pem" \
  || err "E_PIN_DRIFT: the trust anchor embedded in $INSTALLER differs from install.signing_public_key in $CONFIG — regenerate installers (dart run scripts/gen_installers.dart)"
ok "(1) no drift: installer tracks the vpinned marker; trust anchors match"

$OFFLINE && { ok "(offline) drift checks only — marker/provenance skipped"; exit 0; }

# ── 2. resolve the target: marker (default) or FA_PIN_TARGET override ──────
if [ -n "$TARGET_OVERRIDE" ]; then
  case "$TARGET_OVERRIDE" in
    v*) vtag="$TARGET_OVERRIDE" ;;
    *)  vtag="v$TARGET_OVERRIDE" ;;
  esac
  ok "(2) target override: $vtag (marker not consulted)"
else
  if ! fetch "$RELEASE_BASE/vpinned/PINNED_VERSION" "$work/PINNED_VERSION"; then
    err "E_PIN_MISSING: the vpinned marker publishes no PINNED_VERSION at $RELEASE_BASE/vpinned/PINNED_VERSION — create the marker release (scripts/pin_release.sh) before serving this installer"
  fi
  resolved="$(tr -d '[:space:]' < "$work/PINNED_VERSION")"
  case "$resolved" in
    ''|*[!0-9A-Za-z.-]*) err "E_PIN_INVALID: the vpinned marker returned '$resolved' — not a release tag" ;;
  esac
  case "$resolved" in
    v*) vtag="$resolved" ;;
    *)  vtag="v$resolved" ;;
  esac
  ok "(2) marker resolves to: $vtag"
fi

# ── 3. the marked release must carry signed provenance ──────────────────────
sums_url="$RELEASE_BASE/$vtag/SHA256SUMS"
sig_url="$RELEASE_BASE/$vtag/SHA256SUMS.sig"
fetch "$sums_url" "$work/SHA256SUMS" \
  || err "E_PIN_PROVENANCE_MISSING: release $vtag publishes no SHA256SUMS at $sums_url — the marker must not point at an unsigned release (or assets are still uploading; retry)"
fetch "$sig_url" "$work/SHA256SUMS.sig" \
  || err "E_PIN_PROVENANCE_MISSING: release $vtag publishes no SHA256SUMS.sig at $sig_url — refusing a pin without provenance"
ok "(3) release $vtag publishes SHA256SUMS + signature"

# ── 4. signature must verify against the committed trust anchor ─────────────
openssl dgst -sha256 -verify "$work/config-anchor.pem" \
  -signature "$work/SHA256SUMS.sig" "$work/SHA256SUMS" >/dev/null 2>&1 \
  || err "E_PIN_PROVENANCE_INVALID: SHA256SUMS.sig on release $vtag does not verify against the trust anchor in $CONFIG — possible drift or tampering"
ok "(4) signature verifies against the committed trust anchor"

# ── 5. the signed manifest must cover every installable platform archive ────
missing=""
for a in $REQUIRED_ASSETS; do
  grep -q "  $a\$" "$work/SHA256SUMS" || missing="$missing $a"
done
[ -z "$missing" ] \
  || err "E_PIN_ASSET_COVERAGE: signed SHA256SUMS on release $vtag does not cover:$missing — every platform archive must be checksummed by the signed manifest"
ok "(5) signed manifest covers all platform archives"

echo ""
echo "check_install_pin: target '$vtag' satisfies the provenance gate"
