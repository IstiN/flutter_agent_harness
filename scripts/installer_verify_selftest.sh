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
# 32 fresh random bytes over the signature head — a single-byte flip can hit
# an identical byte (1/256; the key is regenerated every run) and silently
# no-op the tamper, so the fixture would verify garbage instead of failing.
dd if=/dev/urandom of="$work/release-badsig/SHA256SUMS.sig" bs=1 count=32 conv=notrunc 2>/dev/null
expect_fail "$work/release-badsig" "E_PROVENANCE_INVALID" "AC2 bad-sig"

# ── AC1: tampered artifact (bit-flip inside the archive) ────────────────────
cp -R "$fixture" "$work/release-tampered"
# Same no-op-tamper guard as AC2: 32 random bytes cannot collide with the
# original gzip stream (2^-256), a single flipped byte can (1/256).
dd if=/dev/urandom of="$work/release-tampered/$asset" bs=1 seek=100 count=32 conv=notrunc 2>/dev/null
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
# The default is the `vpinned` release marker (resolved at install time),
# NOT a baked-in version — a baked pin rots (#1015). Explicit overrides:
# FA_VERSION=<tag> and FA_VERSION=latest.
grep -q 'FA_VERSION="${FA_VERSION:-vpinned}"' "$INSTALLER" || {
  echo "FAIL (contract1): installer does not default to the vpinned marker"; exit 1
}
grep -q 'FA_VERSION=latest' "$INSTALLER" || {
  echo "FAIL (contract1): no explicit latest override in installer"; exit 1
}
grep -qF 'latest|v*)' "$INSTALLER" || {
  echo "FAIL (contract1): no v-prefix normalization for FA_VERSION"; exit 1
}
echo "ok  (contract1): installer defaults to the vpinned marker; latest is opt-in; bare pins normalize to v-tags"

# ── marker resolution through the real installer (contract 1b) ──────────────
# Default install (no FA_VERSION) must resolve vpinned/PINNED_VERSION from
# the SAME fixture base and install the marked release.
run_install_default() { # run_install_default <fixture-dir>; no FA_VERSION
  rm -rf "$install_dir"; mkdir -p "$install_dir"
  (cd "$work" &&
    FA_INSTALL_DIR="$install_dir" \
    FA_RELEASE_BASE_URL="file://$1" \
    FA_SIGNING_PEM="$work/test.pub" \
    PATH="$shim:$PATH" \
    sh "$INSTALLER" > "$work/out-default.log" 2>&1
  )
}
mkdir -p "$fixture/vpinned"
printf 'v0.0.0-test\n' > "$fixture/vpinned/PINNED_VERSION"
if ! run_install_default "$fixture"; then
  echo "FAIL (contract1b): default install via marker failed:"; cat "$work/out-default.log"; exit 1
fi
grep -q "Pinned marker resolves to: v0.0.0-test" "$work/out-default.log" || {
  echo "FAIL (contract1b): marker resolution not logged:"; cat "$work/out-default.log"; exit 1
}
[ -x "$install_dir/fa" ] || { echo "FAIL (contract1b): resolved install left no binary"; exit 1; }
echo "ok  (contract1b): default install resolves the marker and installs the marked release"

# marker missing → E_PIN_MISSING, fail-closed, nothing installed
cp -R "$fixture" "$work/release-nomarker"
rm -rf "$work/release-nomarker/vpinned"
set +e
run_install_default "$work/release-nomarker"
status=$?
set -e
if [ "$status" -eq 0 ] || ! grep -q "E_PIN_MISSING" "$work/out-default.log"; then
  echo "FAIL (contract1b): missing marker not caught (exit $status):"; cat "$work/out-default.log"; exit 1
fi
if [ -e "$install_dir/fa" ]; then
  echo "FAIL (contract1b): installer left a binary behind on E_PIN_MISSING"; exit 1
fi
echo "ok  (contract1b): E_PIN_MISSING without the marker, nothing installed"

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

# ── contract 5: the vpinned marker satisfies its OWN provenance gate ────────
# gh follow-up to #814/#1015: a committed pin rots and a hand-bumped pin is
# unverified. The default now resolves the `vpinned` release marker;
# scripts/check_install_pin.sh guards it: installer↔config drift (anchor +
# marker default), marker well-formedness, and — the actual trust root —
# the MARKED release's signature + platform coverage.
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

# 5b: a generated installer that drifts from the marker model is caught.
mkdir -p "$work/drift"
sed 's/FA_VERSION="${FA_VERSION:-vpinned}"/FA_VERSION="${FA_VERSION:-9.9.9}"/' \
  "$INSTALLER" > "$work/drift/install.sh"
set +e
FA_PIN_CONFIG="$REPO_ROOT/site/install-config.yaml" FA_PIN_INSTALLER="$work/drift/install.sh" \
  sh "$PIN_GATE" --offline > "$work/drift.log" 2>&1
status=$?
set -e
if [ "$status" -eq 0 ] || ! grep -q "E_PIN_DRIFT" "$work/drift.log"; then
  echo "FAIL (pin-gate 5b): installer drift not caught (exit $status):"
  cat "$work/drift.log"; exit 1
fi
echo "ok  (pin-gate 5b): E_PIN_DRIFT when the installer stops tracking the marker"

# 5c: full gate against a fixture release root (file:// — no network).
# Root layout: vpinned/PINNED_VERSION names the tag; v0.0.0-test/ carries
# the five platform archives + a manifest signed with the throwaway key.
mkdir -p "$work/pinfix"
{
  echo "install:"
  echo "  signing_public_key: |"
  sed 's/^/    /' "$work/test.pub"
} > "$work/pinfix/config.yaml"
# The copied installer must carry the THROWAWAY anchor (the gate compares
# the embedded PEM against the config — production checks they match).
awk -v pubfile="$work/test.pub" '
  /BEGIN PUBLIC KEY/ && !done {
    while ((getline line < pubfile) > 0) print line
    close(pubfile)
    done=1; skipping=1
  }
  skipping && !/END PUBLIC KEY/ { next }
  skipping && /END PUBLIC KEY/ { skipping=0; next }
  { print }
' "$INSTALLER" > "$work/pinfix/install.sh"
ALL_ASSETS="fa-linux-x64.tar.gz fa-linux-arm64.tar.gz fa-macos-arm64.tar.gz fa-macos-x64.tar.gz fa-windows-x64.zip"
mkdir -p "$work/pinrels/vpinned" "$work/pinrels/v0.0.0-test"
printf 'v0.0.0-test\n' > "$work/pinrels/vpinned/PINNED_VERSION"
for a in $ALL_ASSETS; do
  printf 'fixture-%s\n' "$a" > "$work/pinrels/v0.0.0-test/$a"
done
pin_sign() { # pin_sign <dir> <key> [assets...]
  d="$1"; k="$2"; shift 2
  (cd "$d" && sums_tool "$@" > SHA256SUMS)
  openssl dgst -sha256 -sign "$k" -out "$d/SHA256SUMS.sig" "$d/SHA256SUMS" 2>/dev/null
}
pin_sign "$work/pinrels/v0.0.0-test" "$work/test.key" $ALL_ASSETS

pin_run() { # pin_run; gate against $work/pinrels, prints exit code
  set +e
  FA_PIN_CONFIG="$work/pinfix/config.yaml" \
  FA_PIN_INSTALLER="$work/pinfix/install.sh" \
  FA_PIN_RELEASE_BASE="file://$work/pinrels" \
  sh "$PIN_GATE" > "$work/pinfix.log" 2>&1
  status=$?
  set -e
  echo "$status"
}

# good fixture: marker resolves, target signature verifies, full coverage
s=$(pin_run)
if [ "$s" -ne 0 ]; then
  echo "FAIL (pin-gate 5c): signed fixture release rejected (exit $s):"
  cat "$work/pinfix.log"; exit 1
fi
grep -q "marker resolves to: v0.0.0-test" "$work/pinfix.log" || {
  echo "FAIL (pin-gate 5c): marker resolution not logged:"; cat "$work/pinfix.log"; exit 1
}
echo "ok  (pin-gate 5c): marker → signed fixture release passes the full gate"

# marker missing → E_PIN_MISSING
mkdir -p "$work/pinrels-nomarker/v0.0.0-test"
cp "$work/pinrels/v0.0.0-test/"* "$work/pinrels-nomarker/v0.0.0-test/"
set +e
FA_PIN_CONFIG="$work/pinfix/config.yaml" FA_PIN_INSTALLER="$work/pinfix/install.sh" \
  FA_PIN_RELEASE_BASE="file://$work/pinrels-nomarker" \
  sh "$PIN_GATE" > "$work/pinfix-nomarker.log" 2>&1
s=$?
set -e
if [ "$s" -eq 0 ] || ! grep -q "E_PIN_MISSING" "$work/pinfix-nomarker.log"; then
  echo "FAIL (pin-gate 5c): missing marker not caught (exit $s):"
  cat "$work/pinfix-nomarker.log"; exit 1
fi
echo "ok  (pin-gate 5c): E_PIN_MISSING without the marker release"

# marker names a release with no signature → E_PIN_PROVENANCE_MISSING
mkdir -p "$work/pinrels-nosig/vpinned" "$work/pinrels-nosig/v0.0.0-test"
printf 'v0.0.0-test\n' > "$work/pinrels-nosig/vpinned/PINNED_VERSION"
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
echo "ok  (pin-gate 5c): E_PIN_PROVENANCE_MISSING when the marked release is unsigned"

# wrong-key signature → E_PIN_PROVENANCE_INVALID
mkdir -p "$work/pinrels-badkey/vpinned" "$work/pinrels-badkey/v0.0.0-test"
printf 'v0.0.0-test\n' > "$work/pinrels-badkey/vpinned/PINNED_VERSION"
cp "$work/pinrels/v0.0.0-test/"* "$work/pinrels-badkey/v0.0.0-test/"
openssl genrsa -out "$work/other.key" 2048 2>/dev/null
pin_sign "$work/pinrels-badkey/v0.0.0-test" "$work/other.key" $ALL_ASSETS
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
mkdir -p "$work/pinrels-gap/vpinned" "$work/pinrels-gap/v0.0.0-test"
printf 'v0.0.0-test\n' > "$work/pinrels-gap/vpinned/PINNED_VERSION"
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

# FA_PIN_TARGET override: verify a concrete tag regardless of the marker
# (pin_release.sh pre-checks the NEW release BEFORE moving the marker).
mkdir -p "$work/pinrels-override/vpinned" "$work/pinrels-override/v0.0.0-test"
printf 'v9.9.9\n' > "$work/pinrels-override/vpinned/PINNED_VERSION"
cp "$work/pinrels/v0.0.0-test/"* "$work/pinrels-override/v0.0.0-test/"
set +e
FA_PIN_TARGET="0.0.0-test" \
FA_PIN_CONFIG="$work/pinfix/config.yaml" FA_PIN_INSTALLER="$work/pinfix/install.sh" \
  FA_PIN_RELEASE_BASE="file://$work/pinrels-override" \
  sh "$PIN_GATE" > "$work/pinfix-override.log" 2>&1
s=$?
set -e
if [ "$s" -ne 0 ]; then
  echo "FAIL (pin-gate 5c): FA_PIN_TARGET override rejected the good release (exit $s):"
  cat "$work/pinfix-override.log"; exit 1
fi
grep -q "target override: v0.0.0-test" "$work/pinfix-override.log" || {
  echo "FAIL (pin-gate 5c): target override not logged:"; cat "$work/pinfix-override.log"; exit 1
}
echo "ok  (pin-gate 5c): FA_PIN_TARGET verifies a concrete tag past a stale marker"

# ── contract 6: pin_release.sh — marker arithmetic + fixture end-to-end ─────
# scripts/pin_release.sh advances the vpinned marker to a freshly signed
# tag: is-newer keeps bumps forward-only; the pre-move gate proves the
# target; the post-move gate proves the published marker.
BUMPER="$REPO_ROOT/scripts/pin_release.sh"
[ -f "$BUMPER" ] || { echo "FAIL (pin-bump): scripts/pin_release.sh missing"; exit 1; }
bump_newer() { sh "$BUMPER" is-newer "$1" "$2" >/dev/null 2>&1; }
bump_newer v1.0.481 1.0.480 || { echo "FAIL (pin-bump): v1.0.481 should be newer than 1.0.480"; exit 1; }
bump_newer 2.0.0 1.9.9    || { echo "FAIL (pin-bump): 2.0.0 should be newer than 1.9.9"; exit 1; }
bump_newer 1.0.10 1.0.9   || { echo "FAIL (pin-bump): 1.0.10 should be newer than 1.0.9 (numeric, not lexical)"; exit 1; }
if bump_newer 1.0.480 1.0.480; then echo "FAIL (pin-bump): equal versions must NOT count as newer"; exit 1; fi
if bump_newer 1.0.479 1.0.480; then echo "FAIL (pin-bump): older version must NOT count as newer"; exit 1; fi
if bump_newer v0.1.452 v1.0.480; then echo "FAIL (pin-bump): 0.1.452 must NOT count as newer than 1.0.480"; exit 1; fi
echo "ok  (pin-bump 6a): is-newer gates forward-only bumps (v-prefix, numeric compare)"

# 6b: fixture-mode end-to-end — PIN_RELEASE_BASE writes the marker file
# directly (no gh), pre- and post-gates run against the fixture root.
mkdir -p "$work/pinrel-root/v0.0.0-test"
for a in $ALL_ASSETS; do
  printf 'fixture-%s\n' "$a" > "$work/pinrel-root/v0.0.0-test/$a"
done
pin_sign "$work/pinrel-root/v0.0.0-test" "$work/test.key" $ALL_ASSETS
if ! PIN_RELEASE_BASE="$work/pinrel-root" \
     FA_PIN_CONFIG="$work/pinfix/config.yaml" FA_PIN_INSTALLER="$work/pinfix/install.sh" \
     sh "$BUMPER" 0.0.0-test > "$work/pinrel-run.log" 2>&1; then
  echo "FAIL (pin-bump 6b): pin_release rejected the signed fixture:"
  cat "$work/pinrel-run.log"; exit 1
fi
[ "$(tr -d '[:space:]' < "$work/pinrel-root/vpinned/PINNED_VERSION")" = "v0.0.0-test" ] || {
  echo "FAIL (pin-bump 6b): marker file not written:"; cat "$work/pinrel-run.log"; exit 1
}
echo "ok  (pin-bump 6b): fixture pin_release wrote and verified the marker"

# re-run: marker already at the target — green skip, marker untouched
if ! PIN_RELEASE_BASE="$work/pinrel-root" \
     FA_PIN_CONFIG="$work/pinfix/config.yaml" FA_PIN_INSTALLER="$work/pinfix/install.sh" \
     sh "$BUMPER" v0.0.0-test > "$work/pinrel-rerun.log" 2>&1; then
  echo "FAIL (pin-bump 6b): re-run of an up-to-date marker must skip green:"
  cat "$work/pinrel-rerun.log"; exit 1
fi
grep -q "nothing to do" "$work/pinrel-rerun.log" || {
  echo "FAIL (pin-bump 6b): re-run did not skip:"; cat "$work/pinrel-rerun.log"; exit 1
}
echo "ok  (pin-bump 6b): re-run skips green when the marker is up to date"

# unsigned target: the gate must reject AND the marker must NOT move
mkdir -p "$work/pinrel-root/v0.0.1-test"
cp "$work/pinrel-root/v0.0.0-test/"* "$work/pinrel-root/v0.0.1-test/"
rm "$work/pinrel-root/v0.0.1-test/SHA256SUMS.sig"
set +e
PIN_RELEASE_BASE="$work/pinrel-root" \
  FA_PIN_CONFIG="$work/pinfix/config.yaml" FA_PIN_INSTALLER="$work/pinfix/install.sh" \
  sh "$BUMPER" 0.0.1-test > "$work/pinrel-unsigned.log" 2>&1
s=$?
set -e
if [ "$s" -eq 0 ]; then
  echo "FAIL (pin-bump 6b): unsigned target accepted"; exit 1
fi
[ "$(tr -d '[:space:]' < "$work/pinrel-root/vpinned/PINNED_VERSION")" = "v0.0.0-test" ] || {
  echo "FAIL (pin-bump 6b): marker MOVED to an unsigned target"; exit 1
}
echo "ok  (pin-bump 6b): unsigned target rejected, marker unmoved"

echo ""
echo "installer_verify_selftest: ALL GREEN (AC1-AC4, contracts 1+1b+5+6)"
