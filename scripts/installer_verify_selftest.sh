#!/usr/bin/env bash
# installer_verify_selftest.sh — SEC-07 (#795) AC1–AC4: fixture-release IT
# for site/install.sh. Builds a local fixture "release" (asset + signed
# SHA256SUMS), points the installer at it via FA_RELEASE_BASE_URL with a
# throwaway trust anchor (FA_SIGNING_PEM), and asserts:
#   AC1  tampered asset (bit-flip)      → abort E_CHECKSUM_MISMATCH, nothing installed
#   AC2  missing signature / bad sig    → abort E_PROVENANCE_*, nothing installed
#   AC3  valid fixture                  → installs; the macOS quarantine strip
#                                        runs only AFTER verification (order
#                                        asserted via an xattr PATH shim)
#   AC4  CI runs this script on every PR (installer-verify job in ci.yml)
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$REPO_ROOT/site/install.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fixture="$work/release"
install_dir="$work/bin"
mkdir -p "$fixture" "$install_dir"

# Same platform mapping the installer uses, so the fixture asset matches.
case "$(uname -s)" in
  Darwin*) f_os=macos ;;
  Linux*)  f_os=linux ;;
  *) echo "skip: unsupported test platform"; exit 0 ;;
esac
case "$(uname -m)" in
  x86_64|amd64)  f_arch=x64 ;;
  arm64|aarch64) f_arch=arm64 ;;
  *) echo "skip: unsupported test arch"; exit 0 ;;
esac
asset="fa-${f_os}-${f_arch}.tar.gz"

# xattr PATH shim: logs every invocation — proves whether the quarantine
# strip ran (and it must only ever run in the verified-good case). The REAL
# xattr binary is resolved now and baked in (the shim must not find itself).
real_xattr="$(command -v xattr 2>/dev/null || true)"
shim="$work/shim"
mkdir -p "$shim"
cat > "$shim/xattr" <<SHIM
#!/bin/sh
printf '%s\n' "\$*" >> "$work/xattr.log"
${real_xattr:-/usr/bin/true} "\$@" 2>/dev/null || true
SHIM
chmod +x "$shim/xattr"

# Throwaway trust anchor for the fixture release.
openssl genrsa -out "$work/test.key" 2048 2>/dev/null
openssl rsa -in "$work/test.key" -pubout -out "$work/test.pub" 2>/dev/null

# Fixture release: bundle/bin/fa + version.txt, like `dart build cli`.
mkdir -p "$fixture/bundle/bin"
printf '#!/bin/sh\necho fa-fixture-0.0.0\n' > "$fixture/bundle/bin/fa"
chmod +x "$fixture/bundle/bin/fa"
printf '0.0.0-test\n' > "$fixture/bundle/version.txt"
tar -czf "$fixture/$asset" -C "$fixture" bundle

sums_tool() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

sign_fixture() { # sign_fixture <fixture-dir>
  (cd "$1" && sums_tool "$asset" > SHA256SUMS)
  openssl dgst -sha256 -sign "$work/test.key" \
    -out "$1/SHA256SUMS.sig" "$1/SHA256SUMS" 2>/dev/null
}

run_install() { # run_install <fixture-dir>; output captured, exit code returned
  (cd "$work" &&
    FA_INSTALL_DIR="$install_dir" \
    FA_VERSION="0.0.0-test" \
    FA_RELEASE_BASE_URL="file://$1" \
    FA_SIGNING_PEM="$work/test.pub" \
    PATH="$shim:$PATH" \
    sh "$INSTALLER" > "$work/out.log" 2>&1
  )
}

expect_fail() { # expect_fail <fixture-dir> <expected-error> <label>
  set +e
  run_install "$1"
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    echo "FAIL ($3): installer exited 0, expected abort with $2"; sed -n '1,40p' "$work/out.log"; exit 1
  fi
  if ! grep -q "$2" "$work/out.log"; then
    echo "FAIL ($3): expected $2 in output, got:"; sed -n '1,40p' "$work/out.log"; exit 1
  fi
  if [ -e "$install_dir/fa" ]; then
    echo "FAIL ($3): installer left a binary behind — 'nothing installed' violated"; exit 1
  fi
  echo "ok  ($3): aborted with $2 (exit $status), nothing installed"
}

# ── AC2: fail-closed on missing / invalid provenance ────────────────────────
sign_fixture "$fixture"
cp -R "$fixture" "$work/release-unsigned"
rm "$work/release-unsigned/SHA256SUMS.sig"
expect_fail "$work/release-unsigned" "E_PROVENANCE_MISSING" "AC2 unsigned"

cp -R "$fixture" "$work/release-badsig"
printf 'X' | dd of="$work/release-badsig/SHA256SUMS.sig" bs=1 seek=10 conv=notrunc 2>/dev/null
expect_fail "$work/release-badsig" "E_PROVENANCE_INVALID" "AC2 bad-sig"

# ── AC1: tampered artifact (bit-flip inside the archive) ────────────────────
cp -R "$fixture" "$work/release-tampered"
printf '\x00' | dd of="$work/release-tampered/$asset" bs=1 seek=100 count=1 conv=notrunc 2>/dev/null
rm -f "$work/xattr.log"
expect_fail "$work/release-tampered" "E_CHECKSUM_MISMATCH" "AC1 tampered"

# Order assertion (AC3): the strip shim must NOT have run in any abort case.
if [ -f "$work/xattr.log" ]; then
  echo "FAIL (order): quarantine strip ran despite failed verification"; exit 1
fi

# ── AC3: valid fixture installs; strip only after verification ──────────────
if ! run_install "$fixture"; then
  echo "FAIL (AC3): valid fixture failed to install:"; sed -n '1,60p' "$work/out.log"; exit 1
fi
# gh-814 r2: the resolved version prints in its NORMALIZED (v-tagged) form.
grep -q "Installing Fa version: v0.0.0-test" "$work/out.log" || {
  echo "FAIL (AC3): resolved version not printed (normalized v-form)"; exit 1
}
grep -q "Checksum manifest signature verified" "$work/out.log" || {
  echo "FAIL (AC3): provenance verification did not run"; exit 1
}
[ -x "$install_dir/fa" ] || { echo "FAIL (AC3): $install_dir/fa missing"; exit 1; }
[ "$(sh "$install_dir/fa")" = "fa-fixture-0.0.0" ] || {
  echo "FAIL (AC3): installed binary does not run"; exit 1
}
[ -f "$install_dir/version.txt" ] || { echo "FAIL (AC3): version.txt not installed"; exit 1; }
case "$(uname -s)" in
  Darwin*)
    grep -q "com.apple.quarantine" "$work/xattr.log" 2>/dev/null || {
      echo "FAIL (AC3): quarantine strip did not run after verification on macOS"; exit 1
    }
    ;;
esac
echo "ok  (AC3): valid fixture installed; verification preceded install + strip"

# ── pinned default + latest override resolve (contract 1) ───────────────────
# (no network here — just assert the script carries a baked non-empty pin)
grep -q 'FA_VERSION="${FA_VERSION:-[0-9v]' "$INSTALLER" || {
  echo "FAIL (contract1): no pinned default version in installer"; exit 1
}
grep -q 'FA_VERSION=latest' "$INSTALLER" || {
  echo "FAIL (contract1): no explicit latest override in installer"; exit 1
}
# gh-814 r2: release tags are v-prefixed — the installer must normalize a
# bare X.Y.Z pin/override to vX.Y.Z or every pinned download 404s.
grep -qF 'latest|v*)' "$INSTALLER" || {
  echo "FAIL (contract1): no v-prefix normalization for FA_VERSION"; exit 1
}
echo "ok  (contract1): installer pins a default version; latest is opt-in; bare pins normalize to v-tags"

# ── embedded trust anchor (gh-814 r2): parses WITHOUT any override ──────────
# The production trust path is the PEM baked into the installer (single-
# sourced from install-config.yaml). This asserts the committed anchor is a
# real public key — no FA_SIGNING_PEM fixture override involved.
sed -n '/BEGIN PUBLIC KEY/,/END PUBLIC KEY/p' "$INSTALLER" |
  sed "1s/^.*BEGIN/-----BEGIN/; \$s/END.*\$/END PUBLIC KEY-----/" \
  > "$work/embedded-anchor.pem"
if ! openssl pkey -pubin -in "$work/embedded-anchor.pem" -noout 2>/dev/null; then
  echo "FAIL (anchor): embedded trust anchor does not parse as a public key"
  exit 1
fi
echo "ok  (anchor): embedded trust anchor parses (no FA_SIGNING_PEM override)"

# ── contract 5: the pinned default satisfies its OWN provenance gate ────────
# gh follow-up to #814/#1015: install.sh refused its own default pin
# (v0.1.452 predates SHA256SUMS → E_PROVENANCE_MISSING on a fresh
# curl|sh). scripts/check_install_pin.sh closes the loop: the pin in
# install-config.yaml must (a) match the generated installer (no
# hand-edited/generated drift) and (b) resolve on the release to a
# signature-verified SHA256SUMS covering every platform asset.
PIN_GATE="$REPO_ROOT/scripts/check_install_pin.sh"

# 5a: offline drift gate passes on the real repo files (no network).
if [ ! -f "$PIN_GATE" ]; then
  echo "FAIL (pin-gate): scripts/check_install_pin.sh missing"; exit 1
fi
if ! FA_PIN_CONFIG="$REPO_ROOT/site/install-config.yaml" \
     FA_PIN_INSTALLER="$INSTALLER" \
     sh "$PIN_GATE" --offline > "$work/pingate-offline.log" 2>&1; then
  echo "FAIL (pin-gate): offline drift check failed on repo files:"
  cat "$work/pingate-offline.log"; exit 1
fi
echo "ok  (pin-gate 5a): offline drift check passes on repo files"

# 5b: config-pin != installer-pin is caught (E_PIN_DRIFT), not waved through.
mkdir -p "$work/drift"
sed 's/^  pinned_cli_version: .*/  pinned_cli_version: "9.9.9"/' \
  "$REPO_ROOT/site/install-config.yaml" > "$work/drift/config.yaml"
cp "$INSTALLER" "$work/drift/install.sh"
set +e
FA_PIN_CONFIG="$work/drift/config.yaml" FA_PIN_INSTALLER="$work/drift/install.sh" \
  sh "$PIN_GATE" --offline > "$work/drift.log" 2>&1
status=$?
set -e
if [ "$status" -eq 0 ] || ! grep -q "E_PIN_DRIFT" "$work/drift.log"; then
  echo "FAIL (pin-gate 5b): config/installer pin drift not caught (exit $status):"
  cat "$work/drift.log"; exit 1
fi
echo "ok  (pin-gate 5b): E_PIN_DRIFT on config/installer pin mismatch"

# 5c: live provenance gate against a fixture release (file:// — no network).
# Fixture config carries the throwaway anchor + a 0.0.0-test pin; the
# fixture release under v0.0.0-test/ is signed with the throwaway key.
mkdir -p "$work/pinfix"
{
  echo "install:"
  echo "  pinned_cli_version: \"0.0.0-test\""
  echo "  signing_public_key: |"
  sed 's/^/    /' "$work/test.pub"
} > "$work/pinfix/config.yaml"
sed "s/FA_VERSION:-[^}]*}/FA_VERSION:-0.0.0-test}/" "$INSTALLER" \
  > "$work/pinfix/install.sh"
pinrels="$work/pinrels/v0.0.0-test"
mkdir -p "$pinrels"
for a in fa-linux-x64.tar.gz fa-linux-arm64.tar.gz fa-macos-arm64.tar.gz \
         fa-macos-x64.tar.gz fa-windows-x64.zip; do
  printf 'fixture-%s\n' "$a" > "$pinrels/$a"
done
pin_sign() { # pin_sign <dir> <key> [assets...]
  d="$1"; k="$2"; shift 2
  (cd "$d" && sums_tool "$@" > SHA256SUMS)
  openssl dgst -sha256 -sign "$k" -out "$d/SHA256SUMS.sig" "$d/SHA256SUMS" 2>/dev/null
}
pin_sign "$pinrels" "$work/test.key" \
  fa-linux-x64.tar.gz fa-linux-arm64.tar.gz fa-macos-arm64.tar.gz \
  fa-macos-x64.tar.gz fa-windows-x64.zip

pin_run() { # pin_run; runs the gate against $work/pinrels, prints exit code
  set +e
  FA_PIN_CONFIG="$work/pinfix/config.yaml" \
  FA_PIN_INSTALLER="$work/pinfix/install.sh" \
  FA_PIN_RELEASE_BASE="file://$work/pinrels" \
  sh "$PIN_GATE" > "$work/pinfix.log" 2>&1
  status=$?
  set -e
  echo "$status"
}

# good fixture: full gate passes (drift + provenance + asset coverage)
s=$(pin_run)
if [ "$s" -ne 0 ]; then
  echo "FAIL (pin-gate 5c): signed fixture release rejected (exit $s):"
  cat "$work/pinfix.log"; exit 1
fi
echo "ok  (pin-gate 5c): signed fixture release passes the full gate"

# missing signature → E_PIN_PROVENANCE_MISSING (fail-closed)
mkdir -p "$work/pinrels-nosig/v0.0.0-test"
cp "$work/pinrels/v0.0.0-test/"* "$work/pinrels-nosig/v0.0.0-test/"
rm "$work/pinrels-nosig/v0.0.0-test/SHA256SUMS.sig"
set +e
FA_PIN_CONFIG="$work/pinfix/config.yaml" FA_PIN_INSTALLER="$work/pinfix/install.sh" \
  FA_PIN_RELEASE_BASE="file://$work/pinrels-nosig" \
  sh "$PIN_GATE" > "$work/pinfix-nosig.log" 2>&1
s=$?
set -e
if [ "$s" -eq 0 ] || ! grep -q "E_PIN_PROVENANCE_MISSING" "$work/pinfix-nosig.log"; then
  echo "FAIL (pin-gate 5c): missing signature not caught (exit $s):"
  cat "$work/pinfix-nosig.log"; exit 1
fi
echo "ok  (pin-gate 5c): E_PIN_PROVENANCE_MISSING without SHA256SUMS.sig"

# wrong-key signature → E_PIN_PROVENANCE_INVALID
mkdir -p "$work/pinrels-badkey/v0.0.0-test"
cp "$work/pinrels/v0.0.0-test/"* "$work/pinrels-badkey/v0.0.0-test/"
openssl genrsa -out "$work/other.key" 2048 2>/dev/null
pin_sign "$work/pinrels-badkey/v0.0.0-test" "$work/other.key" \
  fa-linux-x64.tar.gz fa-linux-arm64.tar.gz fa-macos-arm64.tar.gz \
  fa-macos-x64.tar.gz fa-windows-x64.zip
set +e
FA_PIN_CONFIG="$work/pinfix/config.yaml" FA_PIN_INSTALLER="$work/pinfix/install.sh" \
  FA_PIN_RELEASE_BASE="file://$work/pinrels-badkey" \
  sh "$PIN_GATE" > "$work/pinfix-badkey.log" 2>&1
s=$?
set -e
if [ "$s" -eq 0 ] || ! grep -q "E_PIN_PROVENANCE_INVALID" "$work/pinfix-badkey.log"; then
  echo "FAIL (pin-gate 5c): wrong-key signature not caught (exit $s):"
  cat "$work/pinfix-badkey.log"; exit 1
fi
echo "ok  (pin-gate 5c): E_PIN_PROVENANCE_INVALID on wrong-key signature"

# manifest missing a platform asset → E_PIN_ASSET_COVERAGE
mkdir -p "$work/pinrels-gap/v0.0.0-test"
cp "$work/pinrels/v0.0.0-test/"* "$work/pinrels-gap/v0.0.0-test/"
pin_sign "$work/pinrels-gap/v0.0.0-test" "$work/test.key" \
  fa-linux-x64.tar.gz fa-macos-arm64.tar.gz fa-windows-x64.zip
set +e
FA_PIN_CONFIG="$work/pinfix/config.yaml" FA_PIN_INSTALLER="$work/pinfix/install.sh" \
  FA_PIN_RELEASE_BASE="file://$work/pinrels-gap" \
  sh "$PIN_GATE" > "$work/pinfix-gap.log" 2>&1
s=$?
set -e
if [ "$s" -eq 0 ] || ! grep -q "E_PIN_ASSET_COVERAGE" "$work/pinfix-gap.log"; then
  echo "FAIL (pin-gate 5c): asset coverage gap not caught (exit $s):"
  cat "$work/pinfix-gap.log"; exit 1
fi
echo "ok  (pin-gate 5c): E_PIN_ASSET_COVERAGE when a platform asset is unsigned"

echo ""
echo "installer_verify_selftest: ALL GREEN (AC1-AC4, contracts 1+5)"
