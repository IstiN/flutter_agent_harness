#!/usr/bin/env bash
# Copyright (c) 2026, the Flutter Agent Harness authors.
# Use of this source code is governed by a MIT license that can be found
# in the LICENSE file.
#
# gh-1296 AC2: the lockfile gate must demonstrably fail when a lockfile is
# deleted, gitignored, untracked, or STALE (a native plugin with no pod, or
# a pod pinned at a STALE VERSION) — and must not false-positive on
# dart-only plugins, dashed vendored pod names, or a healthy repo.
# Fixture-driven: builds synthetic git repos in a temp dir, no flutter.
# Wired into ci.yml Static gates so the guard itself cannot rot (#1100
# pattern); test/scripts/check_lockfiles_gate_test.dart re-runs it in the
# regular dart legs.
#
# PR #1298 rework additions: every NG1 lockfile (Package.resolved,
# e2e package-lock.json, Cargo.lock) is inventoried — deleting any of them
# must red (cases 9/10); pod-sync must red on a stale pod VERSION (case 7);
# a dashed podspec name must NOT false-red (part of the healthy fixture);
# a corrupt plugins file must fail with a clean ::error::, not a Python
# traceback (case 8).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/check_lockfiles.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

git_config() {
  git -c user.email=gate-selftest@example.com -c user.name=gate-selftest "$@"
}

# A minimal fixture: two native ios plugins (one plain name, one whose
# podspec s.name contains a dash), one dart-only ios plugin, the plugins
# file, every NG1 inventory lockfile, and a Podfile.lock body.
# $2 = the native_pkg pod line in ios/Podfile.lock — "  - native_pkg (0.0.2):"
# when in sync (the podspec declares 0.0.2), "" when the pod never landed
# (the gh-1274 class), "  - native_pkg (0.0.1):" for the stale-VERSION class.
make_fixture() {
  local dir="$1" lock_pods="$2"
  mkdir -p "$dir/flutter_app/ios" "$dir/flutter_app/macos" \
    "$dir/vendor/native_pkg/ios" "$dir/vendor/dashpkg/ios" \
    "$dir/vendor/dart_only/lib" \
    "$dir/browser_ext/e2e" "$dir/office_addin/e2e" \
    "$dir/vendor/flutter_inappwebview_macos/macos/flutter_inappwebview_macos" \
    "$dir/vendor/wasm_run/native"
  git init -q "$dir"

  cat > "$dir/flutter_app/.flutter-plugins-dependencies" <<'EOF'
{"plugins":{"ios":[
  {"name":"native_pkg","path":"/ABS/vendor/native_pkg/","native_build":true},
  {"name":"dashpkg","path":"/ABS/vendor/dashpkg/","native_build":true},
  {"name":"dart_only","path":"/ABS/vendor/dart_only/","native_build":false}],
 "macos":[]}}
EOF

  cat > "$dir/vendor/native_pkg/ios/native_pkg.podspec" <<'EOF'
Pod::Spec.new do |s|
  s.name             = 'native_pkg'
  s.version          = '0.0.2'
  s.dependency 'Flutter'
end
EOF
  # dashed s.name: the PODS-section regex must capture it (no false red)
  cat > "$dir/vendor/dashpkg/ios/dashpkg.podspec" <<'EOF'
Pod::Spec.new do |s|
  s.name             = 'dash-pkg'
  s.version          = '1.0.0'
  s.dependency 'Flutter'
end
EOF
  mkdir -p "$dir/vendor/dart_only/lib"

  # the remaining NG1 inventory lockfiles (content irrelevant — inventory
  # only demands tracked, not-ignored, present)
  : > "$dir/browser_ext/e2e/package-lock.json"
  : > "$dir/office_addin/e2e/package-lock.json"
  : > "$dir/vendor/flutter_inappwebview_macos/macos/flutter_inappwebview_macos/Package.resolved"
  : > "$dir/vendor/wasm_run/native/Cargo.lock"

  cat > "$dir/flutter_app/ios/Podfile.lock" <<EOF
PODS:
  - Flutter (1.0.0)
  - dash-pkg (1.0.0)
$lock_pods
DEPENDENCIES:
  - Flutter (from \`Flutter\`)
EOF
  cat > "$dir/flutter_app/macos/Podfile.lock" <<'EOF'
PODS:
  - FlutterMacOS (1.0.0)
DEPENDENCIES:
  - FlutterMacOS (from \`Flutter/ephemeral\`)
EOF
  # the inventory gate demands every listed lockfile, pubspec.lock included
  printf 'packages:\n  flutter:\n    dependency: "direct main"\n' > "$dir/flutter_app/pubspec.lock"

  git_config -C "$dir" add -A
  git_config -C "$dir" commit -qm fixture
  # rewrite the absolute paths now that the dir exists
  sed -i.bak "s|/ABS|$dir|g" "$dir/flutter_app/.flutter-plugins-dependencies"
  rm -f "$dir/flutter_app/.flutter-plugins-dependencies.bak"
}

expect_fail() {
  local name="$1" dir="$2"; shift 2
  if ( cd "$dir" && FAH_REPO_ROOT="$dir" "$@" ) > /dev/null 2>&1; then
    echo "FAIL: $name — the gate PASSED but must fail (AC2 red exit rot)" >&2
    exit 1
  fi
  echo "ok: $name — gate fails as required"
}

expect_pass() {
  local name="$1" dir="$2"; shift 2
  if ! ( cd "$dir" && FAH_REPO_ROOT="$dir" "$@" ) > /dev/null 2>&1; then
    echo "FAIL: $name — the gate FAILED but must pass (false positive)" >&2
    exit 1
  fi
  echo "ok: $name — gate passes"
}

# Like expect_fail but also asserts the failure is ANNOTATED (::error::)
# and NOT a raw stack — the gate's failure modes must stay readable.
expect_fail_clean() {
  local name="$1" dir="$2" log; shift 2
  log="$(mktemp)"
  if ( cd "$dir" && FAH_REPO_ROOT="$dir" "$@" ) >"$log" 2>&1; then
    echo "FAIL: $name — the gate PASSED but must fail (AC2 red exit rot)" >&2
    rm -f "$log"
    exit 1
  fi
  if ! grep -q '::error::' "$log"; then
    echo "FAIL: $name — the gate failed without a ::error:: annotation:" >&2
    cat "$log" >&2
    rm -f "$log"
    exit 1
  fi
  if grep -q 'Traceback' "$log"; then
    echo "FAIL: $name — the gate failed with a raw Python traceback:" >&2
    cat "$log" >&2
    rm -f "$log"
    exit 1
  fi
  rm -f "$log"
  echo "ok: $name — gate fails, cleanly annotated"
}

# 1. Healthy fixture: both native pods present at their podspec versions
#    (incl. the dashed pod name), dart-only plugin has no pod, every NG1
#    lockfile tracked and not ignored.
d="$tmp/healthy"
make_fixture "$d" "  - native_pkg (0.0.2):"
expect_pass "healthy repo passes" "$d" bash "$GATE" all

# 2. THE gh-1274 class: native plugin landed, Podfile.lock never regenerated.
d="$tmp/stale"
make_fixture "$d" ""
expect_fail "stale Podfile.lock (native plugin pod missing) fails" "$d" bash "$GATE" pod-sync

# 3. Lockfile deleted from the working tree.
d="$tmp/deleted"
make_fixture "$d" "  - native_pkg (0.0.2):"
rm "$d/flutter_app/ios/Podfile.lock"
expect_fail "deleted lockfile fails" "$d" bash "$GATE" inventory

# 4. Lockfile gitignored.
d="$tmp/ignored"
make_fixture "$d" "  - native_pkg (0.0.2):"
echo "flutter_app/ios/Podfile.lock" >> "$d/.gitignore"
expect_fail "gitignored lockfile fails" "$d" bash "$GATE" inventory

# 5. Lockfile present but untracked.
d="$tmp/untracked"
make_fixture "$d" "  - native_pkg (0.0.2):"
git_config -C "$d" rm -q --cached flutter_app/ios/Podfile.lock
expect_fail "untracked lockfile fails" "$d" bash "$GATE" inventory

# 6. Missing plugins file (gate must demand the flutter pub get precondition
#    instead of silently passing).
d="$tmp/noplugins"
make_fixture "$d" "  - native_pkg (0.0.2):"
rm "$d/flutter_app/.flutter-plugins-dependencies"
expect_fail "missing plugins file fails loudly" "$d" bash "$GATE" pod-sync

# 7. PR #1298 review thread 3: the pod present but at a STALE VERSION —
#    pubspec.lock/podspec moved on, Podfile.lock still pins the old pod
#    (the pre-rework flutter_gemma 1.8.0-vs-1.11.3 skew). Presence-only
#    checking stayed green through exactly this drift.
d="$tmp/stale-version"
make_fixture "$d" "  - native_pkg (0.0.1):"
expect_fail "stale pod version fails" "$d" bash "$GATE" pod-sync

# 8. PR #1298 review thread 6: a corrupt/truncated plugins file fails the
#    gate (fail-safe) with a clean ::error:: — not a raw Python traceback.
d="$tmp/corrupt"
make_fixture "$d" "  - native_pkg (0.0.2):"
printf '{"plugins": ' > "$d/flutter_app/.flutter-plugins-dependencies"
expect_fail_clean "corrupt plugins file fails cleanly" "$d" bash "$GATE" pod-sync

# 9. PR #1298 review thread 2: NG1 names Package.resolved — deleting the
#    vendored one must red the inventory, not silently pass.
d="$tmp/no-package-resolved"
make_fixture "$d" "  - native_pkg (0.0.2):"
rm "$d/vendor/flutter_inappwebview_macos/macos/flutter_inappwebview_macos/Package.resolved"
expect_fail "deleted Package.resolved fails" "$d" bash "$GATE" inventory

# 10. Same NG1 class for the e2e npm locks the browser-ext legs `npm ci`.
d="$tmp/no-package-lock"
make_fixture "$d" "  - native_pkg (0.0.2):"
rm "$d/browser_ext/e2e/package-lock.json"
expect_fail "deleted e2e package-lock.json fails" "$d" bash "$GATE" inventory

echo "lockfile gate self-test: all red exits stay red, green path stays green (gh-1296 AC2)"
