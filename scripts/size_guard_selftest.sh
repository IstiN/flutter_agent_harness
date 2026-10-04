#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  gh-1232 AC2 — size-guard self-test                                        ║
# ║  Proves the 2800-line guard fires on oversized files in bin/ and           ║
# ║  flutter_app/lib/ through BOTH paths a file can reach main:                ║
# ║    A. CI whole-tree scan   (ci_fast_gate.sh --scope all --stages size)     ║
# ║    B. pre-commit staged scan (ci_fast_gate.sh --hook --stages size)        ║
# ║  Method: drop two temporary 2801-line .dart files (one per directory),     ║
# ║  expect rejection, then remove them and expect the guard to pass again     ║
# ║  (negative control). The temp files never reach a commit; the index is     ║
# ║  restored exactly (only the two temp paths are ever staged/reset).         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Run from anywhere:  bash scripts/size_guard_selftest.sh
# Exit 0 = guard demonstrably fires on both paths; non-zero = hole remains.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

TMP_BIN="bin/fah_size_guard_probe_tmp.dart"
TMP_APP="flutter_app/lib/size_guard_probe_tmp.dart"
OVER=2801   # MAX_LINES (2800) + 1

cleanup() {
  git reset -q -- "$TMP_BIN" "$TMP_APP" 2>/dev/null || true
  rm -f "$TMP_BIN" "$TMP_APP"
}
trap cleanup EXIT

make_oversized() {
  # 2801 comment lines — syntactically valid Dart, over the ceiling.
  { echo "// size-guard probe (gh-1232 AC2 self-test) — DO NOT COMMIT"
    i=1
    while [ "$i" -lt "$OVER" ]; do echo '// padding'; i=$((i + 1)); done
  } > "$1"
}

expect_reject() {
  # $1 = label, $2.. = command to run (already staged temps assumed)
  local label="$1"; shift
  local out rc
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "❌ AC2 SELF-TEST FAILED ($label): guard PASSED an oversized file" >&2
    return 1
  fi
  if ! echo "$out" | grep -q "FILE SIZE"; then
    echo "❌ AC2 SELF-TEST FAILED ($label): rejected, but not by the size guard:" >&2
    echo "$out" >&2
    return 1
  fi
  if ! echo "$out" | grep -q "size_guard_probe_tmp.dart"; then
    echo "❌ AC2 SELF-TEST FAILED ($label): rejection did not name the probe file" >&2
    echo "$out" >&2
    return 1
  fi
  echo "✅ $label: guard rejected the oversized files"
}

echo "── gh-1232 AC2 size-guard self-test ──"

# Pre-flight: the negative control must pass with NO probe files staged.
out=$(bash scripts/ci_fast_gate.sh --hook --stages size 2>&1) \
  || { echo "❌ pre-flight: hook size stage fails on a clean tree:" >&2; echo "$out" >&2; exit 1; }
echo "✅ pre-flight: hook size stage passes without probes"

make_oversized "$TMP_BIN"
make_oversized "$TMP_APP"

echo "── A. CI whole-tree scan ──"
expect_reject "CI scan (bin/ + flutter_app/lib/)" \
  bash scripts/ci_fast_gate.sh --scope all --stages size

echo "── B. pre-commit staged scan ──"
git add -- "$TMP_BIN" "$TMP_APP"
expect_reject "hook staged scan (bin/ + flutter_app/lib/)" \
  bash scripts/ci_fast_gate.sh --hook --stages size

echo "── negative control: probes removed, guard passes again ──"
cleanup
trap - EXIT
out=$(bash scripts/ci_fast_gate.sh --hook --stages size 2>&1) \
  || { echo "❌ negative control: guard still fails after probe cleanup:" >&2; echo "$out" >&2; exit 1; }
[ ! -e "$TMP_BIN" ] && [ ! -e "$TMP_APP" ] \
  || { echo "❌ probe files left behind" >&2; exit 1; }
echo "✅ negative control: guard passes, probes gone"

echo ""
echo "╔═══════════════════════════════════════════════════════════════════════════╗"
echo "║  ✅ AC2 SELF-TEST PASSED — the 2800-line guard fires on bin/ and           ║"
echo "║     flutter_app/ through both the CI scan and the pre-commit staged scan   ║"
echo "╚═══════════════════════════════════════════════════════════════════════════╝"
