#!/usr/bin/env bash
# check_install_pin.sh — SEC-07 (#795) pin-integrity gate.
#
# install.sh installs the PINNED default from site/install-config.yaml
# (install.pinned_cli_version). The #1015 incident: the pin pointed at a
# release that predates the signed-provenance pipeline, so the hardened
# installer refused its own default (E_PROVENANCE_MISSING on a fresh
# curl|sh). This gate closes the loop on every PR:
#
#   1. E_PIN_DRIFT — the generated site/install.sh must embed exactly the
#      config pin (catches hand-edits of generated files and regeneration
#      skips, both of which silently re-introduce a stale pin).
#   2. E_PIN_PROVENANCE_MISSING — the pinned release must publish
#      SHA256SUMS + SHA256SUMS.sig (fail-closed, like the installer).
#   3. E_PIN_PROVENANCE_INVALID — the manifest signature must verify
#      against the trust anchor in install-config.yaml.
#   4. E_PIN_ASSET_COVERAGE — the signed manifest must cover every
#      platform archive the installer can request.
#
# Modes:
#   (default)   full gate: drift checks + live release provenance
#   --offline   drift checks only (no network)
#
# Overridable inputs (tests/fixtures):
#   FA_PIN_CONFIG        install-config.yaml path (default: site/install-config.yaml)
#   FA_PIN_INSTALLER     generated install.sh path (default: site/install.sh)
#   FA_PIN_RELEASE_BASE  release download base (default:
#                        https://github.com/IstiN/flutter_agent_harness/releases/download)
#
# Exit 0 with "ok" lines on success; exit 1 with a single ::error::-style
# E_PIN_* line on failure (the selftest greps for these markers).
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${FA_PIN_CONFIG:-$REPO_ROOT/site/install-config.yaml}"
INSTALLER="${FA_PIN_INSTALLER:-$REPO_ROOT/site/install.sh}"
RELEASE_BASE="${FA_PIN_RELEASE_BASE:-https://github.com/IstiN/flutter_agent_harness/releases/download}"
OFFLINE=false
[ "${1:-}" = "--offline" ] && OFFLINE=true

err() { printf '✘ %s\n' "$*" >&2; exit 1; }
ok()  { printf 'ok  %s\n' "$*"; }

# Every archive site/install.sh can request — the signed manifest must
# cover all of them, or some platform installs unverifiable.
REQUIRED_ASSETS="fa-linux-x64.tar.gz fa-linux-arm64.tar.gz fa-macos-arm64.tar.gz fa-macos-x64.tar.gz fa-windows-x64.zip"

# ── 1. resolve the pin from the config (source of truth) ────────────────────
[ -f "$CONFIG" ] || err "E_PIN_CONFIG: install config not found: $CONFIG"
pin="$(sed -n 's/^ *pinned_cli_version: *"\{0,1\}\([^" ]*\)"\{0,1\} *$/\1/p' "$CONFIG" | head -1)"
[ -n "$pin" ] || err "E_PIN_CONFIG: no install.pinned_cli_version in $CONFIG"
case "$pin" in
  latest) err "E_PIN_CONFIG: pinned_cli_version must be a concrete release, not 'latest' (SEC-07 pin must be known-good)" ;;
  v*)     vtag="$pin" ;;
  *)      vtag="v$pin" ;;
esac
ok "(1) pin resolved: $pin ($CONFIG)"

# ── 2. drift: generated installer must embed exactly this pin ───────────────
[ -f "$INSTALLER" ] || err "E_PIN_DRIFT: generated installer not found: $INSTALLER"
grep -qF "FA_VERSION=\"\${FA_VERSION:-$pin}\"" "$INSTALLER" \
  || err "E_PIN_DRIFT: $INSTALLER does not embed pinned_cli_version '$pin' from $CONFIG — regenerate installers (dart run scripts/gen_installers.dart), never hand-edit generated files"
ok "(2) no drift: $INSTALLER embeds pin '$pin'"

$OFFLINE && { ok "(offline) drift checks only — provenance skipped"; exit 0; }

# ── 3. the pinned release must carry signed provenance ──────────────────────
sums_url="$RELEASE_BASE/$vtag/SHA256SUMS"
sig_url="$RELEASE_BASE/$vtag/SHA256SUMS.sig"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fetch() { # fetch <url> <out>
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1" -o "$2"
  else
    wget -qO "$2" "$1"
  fi
}
fetch "$sums_url" "$work/SHA256SUMS" \
  || err "E_PIN_PROVENANCE_MISSING: release $vtag publishes no SHA256SUMS at $sums_url — the pinned default must be a release whose provenance job ran (or the release is still building; retry)"
fetch "$sig_url" "$work/SHA256SUMS.sig" \
  || err "E_PIN_PROVENANCE_MISSING: release $vtag publishes no SHA256SUMS.sig at $sig_url — refusing pin without provenance"
ok "(3) release $vtag publishes SHA256SUMS + signature"

# ── 4. signature must verify against the committed trust anchor ─────────────
sed -n '/BEGIN PUBLIC KEY/,/END PUBLIC KEY/p' "$CONFIG" | sed 's/^ *//' > "$work/anchor.pub"
grep -q "BEGIN PUBLIC KEY" "$work/anchor.pub" \
  || err "E_PIN_CONFIG: no signing_public_key block in $CONFIG"
openssl pkey -pubin -in "$work/anchor.pub" -noout 2>/dev/null \
  || err "E_PIN_CONFIG: signing_public_key in $CONFIG does not parse as a public key"
openssl dgst -sha256 -verify "$work/anchor.pub" \
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
echo "check_install_pin: pin '$pin' satisfies its own provenance gate"
