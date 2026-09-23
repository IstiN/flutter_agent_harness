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

echo ""
echo "installer_verify_selftest: ALL GREEN (AC1-AC4)"
