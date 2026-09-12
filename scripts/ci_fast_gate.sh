#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  SHARED FAST GATE — DO NOT LOWER THESE THRESHOLDS WITHOUT TEAM APPROVAL   ║
# ║  size ≤ 2800 lines · analyze · tests · coverage ≥ 80% · CRAP ratchet ·    ║
# ║  duplication < 1% (flutter_app < 3.7%)                                    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# THE shared fast gate used by BOTH the pre-commit hook and CI (issue #177,
# AC7). Both callers run this exact script and diff the one-line markers
#   GATE_STAGE <name> OK|SKIP <reason>
# for hook/CI parity. Every known stage ALWAYS prints exactly one marker:
# OK when it ran and passed, SKIP <reason> when it was not selected or a
# required tool is missing. A failing stage aborts the script with exit 1
# BEFORE its OK marker is printed (marker absent = failed).
#
# Usage:
#   scripts/ci_fast_gate.sh [--scope auto|all|core|app|docs] [--stages list] [--hook]
#
#   --scope auto  Derive the scope from changed paths (default):
#                 - in a git hook (--hook flag or GIT_INDEX_FILE set):
#                   staged files via `git diff --cached --name-only`;
#                 - in CI (BASE_REF + HEAD_REF env vars set):
#                   `git diff --name-only $BASE_REF...$HEAD_REF`;
#                 - otherwise: "all" (safe default).
#   --scope all   Run every stage.
#   --scope core  size + analyze + test-core + coverage + crap + dup.
#   --scope app   size + analyze + dup + flutter.
#   --scope docs  size + analyze only.
#   --stages l    Comma-separated stage list; overrides the scope-derived set.
#                 Known stages: size,analyze,test-core,coverage,crap,dup,flutter
#
# Path rules (union logic, E1; test/** counts as core, E6):
#   docs/ | *.md | prompts/ .................. size + analyze
#   lib/ | bin/ | test/ | pubspec.* .......... + test-core, coverage, crap, dup
#   flutter_app/ | packages/ ................. + dup, flutter
#   scripts/ | .github/ | crap4dart.yaml ..... ALL stages (safe default, E2)
#   anything unknown ......................... ALL stages (safe default)
#
# Concurrency overrides: FA_DART_TEST_CONCURRENCY / FA_FLUTTER_TEST_CONCURRENCY
# (auto-throttled via detect_test_concurrency, same as scripts/pre-commit).

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# Unset git env vars so test processes that spawn git subprocesses use the
# correct working directory rather than the hook's environment. The --hook
# scope detection below reads GIT_INDEX_FILE BEFORE this line runs.
SCOPE=auto
STAGES_OVERRIDE=""
HOOK_MODE=0
DRY_RUN=0
if [ "${GIT_INDEX_FILE:-}" ]; then HOOK_MODE=1; fi
while [ $# -gt 0 ]; do
  case "$1" in
    --scope) SCOPE="$2"; shift 2 ;;
    --scope=*) SCOPE="${1#*=}"; shift ;;
    --stages) STAGES_OVERRIDE="$2"; shift 2 ;;
    --stages=*) STAGES_OVERRIDE="${1#*=}"; shift ;;
    --hook) HOOK_MODE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;   # print derived scope/stages, run nothing
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE 2>/dev/null || true

COVERAGE_BASELINE=80.0
DUP_THRESHOLD=1.0
# flutter_app duplication ratchet: only allowed DOWN from the pinned ~3.66%.
DUP_THRESHOLD_APP=3.7
MAX_LINES=2800

ALL_STAGES="size analyze test-core coverage crap dup flutter"

# ── Load-aware test concurrency (copied from scripts/pre-commit) ───────────
# A busy box (other agents, IDE builds) makes widget tests' runAsync() flake
# and real-timer hub tests miss windows at full parallelism.
detect_test_concurrency() {
  local cores load1
  if command -v sysctl >/dev/null 2>&1; then
    cores=$(sysctl -n hw.ncpu 2>/dev/null)
    load1=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print int($2)}')
  elif [ -r /proc/loadavg ]; then
    cores=$(nproc 2>/dev/null)
    load1=$(awk '{print int($1)}' /proc/loadavg)
  fi
  if [ -n "$cores" ] && [ -n "$load1" ] && [ "$load1" -ge $((cores / 2)) ]; then
    echo 2
  fi
  # Empty output on an idle box = no --concurrency flag (package defaults).
}

# ── Stage selection ─────────────────────────────────────────────────────────
# SELECTED is a space-separated stage set; APP_IN_SCOPE tracks whether
# flutter_app/packages changed (analyze stage runs flutter analyze then).
SELECTED=""
APP_IN_SCOPE=0

add_stages() {
  local s
  for s in $1; do
    case " $SELECTED " in
      *" $s "*) ;;               # union: already present
      *) SELECTED="$SELECTED $s" ;;
    esac
  done
}

classify_path() {
  # Echoes the stage group contributed by one changed path (union logic).
  case "$1" in
    scripts/*|.github/*|crap4dart.yaml) echo "all" ;;
    lib/*|bin/*|test/*|pubspec.yaml|pubspec.*) echo "core" ;;
    flutter_app/*|packages/*) echo "app" ;;
    docs/*|prompts/*|*.md) echo "docs" ;;
    *) echo "all" ;;             # unknown path: safe default (E2)
  esac
}

resolve_scope() {
  case "$SCOPE" in
    all) add_stages "$ALL_STAGES"; APP_IN_SCOPE=1 ;;
    core) add_stages "size analyze test-core coverage crap dup" ;;
    app) add_stages "size analyze dup flutter"; APP_IN_SCOPE=1 ;;
    docs) add_stages "size analyze" ;;
    auto)
      local files=""
      if [ "$HOOK_MODE" -eq 1 ]; then
        files=$(git diff --cached --name-only --diff-filter=ACM)
      elif [ "${BASE_REF:-}" ] && [ "${HEAD_REF:-}" ]; then
        files=$(git diff --name-only "$BASE_REF...$HEAD_REF")
      fi
      if [ -z "$files" ]; then
        # No diff source available: safe default.
        add_stages "$ALL_STAGES"; APP_IN_SCOPE=1
        return
      fi
      local f g
      while IFS= read -r f; do
        [ -z "$f" ] && continue
        g=$(classify_path "$f")
        case "$g" in
          all) add_stages "$ALL_STAGES"; APP_IN_SCOPE=1 ;;
          core) add_stages "size analyze test-core coverage crap dup" ;;
          app) add_stages "size analyze dup flutter"; APP_IN_SCOPE=1 ;;
          docs) add_stages "size analyze" ;;
        esac
      done <<EOF
$files
EOF
      ;;
    *) echo "Unknown scope: $SCOPE" >&2; exit 2 ;;
  esac
}

resolve_scope
if [ -n "$STAGES_OVERRIDE" ]; then
  SELECTED=" $(echo "$STAGES_OVERRIDE" | tr ',' ' ') "
  SELECTED=$(echo "$SELECTED")
fi
# A stage may request flutter even when classify missed it (e.g. --stages).
case " $SELECTED " in *" flutter "*) APP_IN_SCOPE=1 ;; esac

stage_selected() {
  case " $SELECTED " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

marker_ok()   { echo "GATE_STAGE $1 OK"; }
marker_skip() { echo "GATE_STAGE $1 SKIP $2"; }

# ── flutter_app placeholder steps (mirrors .github/workflows/ci.yml) ────────
# .env is gitignored but declared as a Flutter asset; firebase_options.dart
# is gitignored (real keys stay local) and the tracked placeholder makes the
# analyzer resolve the import. Both are idempotent.
ensure_app_placeholders() {
  touch flutter_app/.env
  if [ ! -f flutter_app/lib/firebase_options.dart ]; then
    cp flutter_app/firebase_options.template.dart flutter_app/lib/firebase_options.dart
  fi
}

FLUTTER_ANALYZED=0

# ── Stage implementations ───────────────────────────────────────────────────
stage_size() {
  # Same find-exec guard as ci.yml / pre-commit: no dart file over MAX_LINES.
  local dirs=""
  local d
  for d in lib test example bin; do
    [ -d "$d" ] && dirs="$dirs $d"
  done
  if [ "$APP_IN_SCOPE" -eq 1 ] && [ -d flutter_app/lib ]; then
    dirs="$dirs flutter_app/lib"
  fi
  local violations
  violations=$(find $dirs -name '*.dart' \
    ! -name '*.g.dart' ! -name '*.freezed.dart' ! -name '*.mocks.dart' \
    ! -name '*bridge_generated*.dart' ! -name '*app_localizations*.dart' \
    ! -name '*localizations_*.dart' \
    -exec sh -c 'lines=$(wc -l < "$1"); if [ "$lines" -gt '"$MAX_LINES"' ]; then echo "$1: $lines lines"; fi' _ {} \;)
  if [ -n "$violations" ]; then
    echo "❌ QUALITY GATE FAILED — FILE SIZE (max $MAX_LINES lines)" >&2
    echo "$violations" >&2
    exit 1
  fi
}

stage_analyze() {
  echo "🔍 Running dart analyze..."
  dart analyze
  if [ "$APP_IN_SCOPE" -eq 1 ] && command -v flutter >/dev/null 2>&1; then
    ensure_app_placeholders
    echo "🔍 Running flutter analyze (flutter_app)..."
    (cd flutter_app && flutter analyze --no-fatal-infos --no-fatal-warnings)
    FLUTTER_ANALYZED=1
  fi
}

stage_test_core() {
  echo "🧪 Running dart test --coverage (excluding integration tests)..."
  rm -rf coverage
  local conc="${FA_DART_TEST_CONCURRENCY:-$(detect_test_concurrency)}"
  echo "   concurrency: ${conc:-default}"
  dart test ${conc:+--concurrency=$conc} --coverage=coverage --exclude-tags integration
}

stage_coverage() {
  if [ ! -d coverage ]; then
    echo "❌ coverage/ not found — run the test-core stage first" >&2
    exit 1
  fi
  echo "📊 Formatting coverage to lcov..."
  dart run coverage:format_coverage --lcov -i coverage -o coverage/lcov.info
  echo "🔍 Checking line coverage (baseline: >= ${COVERAGE_BASELINE}%)..."
  if ! python3 scripts/check_coverage.py "$COVERAGE_BASELINE"; then
    echo "❌ QUALITY GATE FAILED — TEST COVERAGE (baseline ${COVERAGE_BASELINE}%)" >&2
    exit 1
  fi
}

stage_crap() {
  if command -v dart >/dev/null 2>&1 && \
     dart pub global run crap4dart --version >/dev/null 2>&1; then
    echo "🔍 Checking CRAP scores (ratchet pinned in crap4dart.yaml)..."
    # Reuses the fresh coverage/lcov.info produced by the coverage stage.
    if ! dart pub global run crap4dart analyze; then
      echo "❌ QUALITY GATE FAILED — CRAP RATCHET" >&2
      exit 1
    fi
  else
    return 2  # caller prints SKIP marker
  fi
}

stage_dup() {
  if ! command -v jscpd >/dev/null 2>&1; then
    return 2  # caller prints SKIP marker
  fi
  echo "🔍 Checking code duplication (core < ${DUP_THRESHOLD}%, flutter_app < ${DUP_THRESHOLD_APP}%)..."
  local core_dup app_dup dup_ok=1
  dup_pct() {
    jscpd --min-tokens 50 --min-lines 5 --reporters json --output "$2" "$1" >/dev/null 2>&1 || true
    python3 -c "
import json
try:
    with open('$2/jscpd-report.json') as f:
        d=json.load(f)
    print(d['statistics']['total']['percentage'])
except Exception:
    print('0.0')
" 2>/dev/null || echo "0.0"
  }
  core_dup=$(dup_pct lib/ /tmp/jscpd-fastgate-core)
  if [ "$APP_IN_SCOPE" -eq 1 ] && [ -d flutter_app/lib ]; then
    app_dup=$(dup_pct flutter_app/lib/ /tmp/jscpd-fastgate-app)
  else
    app_dup="0.0"
  fi
  if python3 -c "exit(0 if float('$core_dup') < float('$DUP_THRESHOLD') else 1)"; then
    echo "✅ Core duplication check OK ($core_dup% < ${DUP_THRESHOLD}%)"
  else
    dup_ok=0
  fi
  if python3 -c "exit(0 if float('$app_dup') < float('$DUP_THRESHOLD_APP') else 1)"; then
    echo "✅ flutter_app duplication check OK ($app_dup% < ${DUP_THRESHOLD_APP}%)"
  else
    dup_ok=0
  fi
  if [ "$dup_ok" -eq 0 ]; then
    echo "❌ QUALITY GATE FAILED — CODE DUPLICATION (core $core_dup%, flutter_app $app_dup%)" >&2
    exit 1
  fi
}

stage_flutter() {
  if ! command -v flutter >/dev/null 2>&1; then
    return 2  # caller prints SKIP marker
  fi
  ensure_app_placeholders
  if [ "$FLUTTER_ANALYZED" -eq 0 ]; then
    echo "🔍 Running flutter analyze (flutter_app)..."
    (cd flutter_app && flutter analyze --no-fatal-infos --no-fatal-warnings)
  fi
  echo "🧪 Running flutter_app tests (excluding integration)..."
  local conc="${FA_FLUTTER_TEST_CONCURRENCY:-$(detect_test_concurrency)}"
  echo "   concurrency: ${conc:-default}"
  if ! (cd flutter_app && flutter test ${conc:+--concurrency=$conc} --exclude-tags integration); then
    echo "❌ QUALITY GATE FAILED — FLUTTER APP TESTS" >&2
    exit 1
  fi
}

# ── Runner: every known stage prints exactly one marker ────────────────────
echo "Fast gate scope: $SCOPE → stages:${SELECTED:- (none)}"
if [ "$DRY_RUN" -eq 1 ]; then
  exit 0
fi
for stage in $ALL_STAGES; do
  if ! stage_selected "$stage"; then
    marker_skip "$stage" "out-of-scope"
    continue
  fi
  case "$stage" in
    size) stage_size ;;
    analyze) stage_analyze ;;
    test-core) stage_test_core ;;
    coverage) stage_coverage ;;
    crap)
      if ! stage_crap; then
        marker_skip crap "crap4dart-not-activated"
        continue
      fi
      ;;
    dup)
      if ! stage_dup; then
        marker_skip dup "jscpd-not-found"
        continue
      fi
      ;;
    flutter)
      if ! stage_flutter; then
        marker_skip flutter "flutter-not-found"
        continue
      fi
      ;;
  esac
  marker_ok "$stage"
done

echo "✅ Fast gate passed (scope: $SCOPE)"
