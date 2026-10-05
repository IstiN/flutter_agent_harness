#!/usr/bin/env bash
# Copyright (c) 2026, the Flutter Agent Harness authors.
# Use of this source code is governed by a MIT license that can be found
# in the LICENSE file.
#
# gh-1296 AC2: the lockfile gate must demonstrably fail when a lockfile is
# deleted, gitignored, untracked, or STALE (a native plugin with no pod) —
# and must not false-positive on dart-only plugins or a healthy repo.
# Fixture-driven: builds synthetic git repos in a temp dir, no flutter.
# Wired into ci.yml Static gates so the guard itself cannot rot (#1100 pattern).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/check_lockfiles.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

git_config() {
  git -c user.email=gate-selftest@example.com -c user.name=gate-selftest "$@"
}

# A minimal fixture: one native ios plugin + one dart-only ios plugin,
# the plugins file, and a Podfile.lock body.
make_fixture() {
  local dir="$1" lock_pods="$2"
  mkdir -p "$dir/flutter_app/ios" "$dir/flutter_app/macos" "$dir/vendor/native_pkg/ios"
  git init -q "$dir"

  cat > "$dir/flutter_app/.flutter-plugins-dependencies" <<'EOF'
{"plugins":{"ios":[
  {"name":"native_pkg","path":"/ABS/vendor/native_pkg/","native_build":true},
  {"name":"dart_only","path":"/ABS/vendor/dart_only/","native_build":false}],
 "macos":[]}}
EOF

  cat > "$dir/vendor/native_pkg/ios/native_pkg.podspec" <<'EOF'
Pod::Spec.new do |s|
  s.name             = 'native_pkg'
  s.dependency 'Flutter'
end
EOF
  mkdir -p "$dir/vendor/dart_only/lib"

  cat > "$dir/flutter_app/ios/Podfile.lock" <<EOF
PODS:
  - Flutter (1.0.0)
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

# 1. Healthy fixture: native pod present, dart-only plugin has no pod.
d="$tmp/healthy"
make_fixture "$d" "  - native_pkg (0.0.1):"
expect_pass "healthy repo passes" "$d" bash "$GATE" all

# 2. THE gh-1274 class: native plugin landed, Podfile.lock never regenerated.
d="$tmp/stale"
make_fixture "$d" ""
expect_fail "stale Podfile.lock (native plugin pod missing) fails" "$d" bash "$GATE" pod-sync

# 3. Lockfile deleted from the working tree.
d="$tmp/deleted"
make_fixture "$d" "  - native_pkg (0.0.1):"
rm "$d/flutter_app/ios/Podfile.lock"
expect_fail "deleted lockfile fails" "$d" bash "$GATE" inventory

# 4. Lockfile gitignored.
d="$tmp/ignored"
make_fixture "$d" "  - native_pkg (0.0.1):"
echo "flutter_app/ios/Podfile.lock" >> "$d/.gitignore"
expect_fail "gitignored lockfile fails" "$d" bash "$GATE" inventory

# 5. Lockfile present but untracked.
d="$tmp/untracked"
make_fixture "$d" "  - native_pkg (0.0.1):"
git_config -C "$d" rm -q --cached flutter_app/ios/Podfile.lock
expect_fail "untracked lockfile fails" "$d" bash "$GATE" inventory

# 6. Missing plugins file (gate must demand the flutter pub get precondition
#    instead of silently passing).
d="$tmp/noplugins"
make_fixture "$d" "  - native_pkg (0.0.1):"
rm "$d/flutter_app/.flutter-plugins-dependencies"
expect_fail "missing plugins file fails loudly" "$d" bash "$GATE" pod-sync

echo "lockfile gate self-test: all red exits stay red, green path stays green (gh-1296 AC2)"
