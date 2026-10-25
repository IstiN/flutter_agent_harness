# Fa — Flutter Agent app

The Flutter macOS/iOS client for the agent harness.

## macOS builds

Two flavors are supported:

- **Sandboxed** (`flutter build macos --release`) — for the App Store.
  Script execution is blocked by the App Sandbox, so embedded interpreters
  are required for agent code execution.
- **Full / no-sandbox** (`scripts/build_macos_nosandbox.sh`) — for GitHub
  Releases. The hardened-runtime build can spawn system interpreters
  (`python3`, `bash`, `node`) and declares HealthKit access. Set
  `MACOS_IDENTITY` to a Developer ID certificate for distribution; the
  default `-` produces an ad-hoc signed local build.

## Local test runs aligned with CI (issues #490, #1851)

The suite is not wedged — a "75-minute coverage hang" report was a
measurement-procedure artifact (coverage instrumentation × default
concurrency-4 file IO thrash), not a stuck test. The supported local
full-suite run keeps `--concurrency=2`; never run `--coverage` with
default concurrency locally — 14 concurrent flutter_tester processes
crawl for 75+ minutes and produce no lcov.

**CRAP numbers are valid only from CI.** The `app-crap-gate` job ranks
from shard-merged lcov (union DA hits); a local ad-hoc `crap4dart
analyze` sees single-run coverage and lies. After any green CI run,
fetch the ranked report instead of gambling locally:

```bash
tools/crap_top.sh          # latest artifact, top-40 table
tools/crap_top.sh 100      # top-100
```

or download the raw JSON: `gh run download -R IstiN/flutter_agent_harness -n crap_report`.

### One copy-pasteable block per CI leg (issue #1851 AC1)

All blocks run from `flutter_app/` on a macOS dev host. Common prep
first (mirrors the ci.yml `flutter-tests` setup steps — both files are
gitignored hard build inputs):

```bash
cd flutter_app
ulimit -n 10240            # macOS agent shells: 256 FDs wedge the suite for hours
cat > .env << 'EOF'        # placeholder .env asset
OPENROUTER_API_KEY=
MODEL_ID=
BASE_URL=
HUGGINGFACE_TOKEN=
EOF
cp firebase_options.template.dart lib/firebase_options.dart
flutter pub get
```

**PR gate** (`ci.yml` `flutter-tests`, shards 0/1) — same `find` filter
the leg uses (goldens and cli_visual out); NO `--timeout` flag: CI runs
the per-test default, and a local `--timeout=120s` kills slow tests and
invents failures (issue #1851):

```bash
find test -name '*_test.dart' ! -path '*/golden/*' ! -path '*/cli_visual/*' \
  | sort | awk 'NR % 2 == 0' > /tmp/shard0.txt    # shard 1: NR % 2 == 1
flutter test --exclude-tags integration $(cat /tmp/shard0.txt)
```

**JS-engine exclusion zone** (`ci.yml` `flutter-app-exzone`, the macOS
leg for `test/apps`):

```bash
flutter test --exclude-tags integration test/apps
```

**Terminal visual** (`ci.yml` `pty-visual`) — integration tags ON, PTY
budget stretched for loaded hosts, NO per-test timeout:

```bash
FA_PTY_BUDGET_SCALE=2 flutter test test/cli_visual --tags integration
```

**WASM sandbox toolchain** (`nightly.yml` build-release macos row,
issue #1851 AC4) — needs the native `libwasm_run_dart.dylib`; the test
cannot download it itself (flutter_tester mocks sockets after binding
init), so seed it first:

```bash
mkdir -p .dart_tool/wasm_run temp
curl -L --retry 3 -o temp/macos.tar.gz \
  https://github.com/juancastillo0/wasm_run/releases/download/wasm_run-v0.1.0/macos.tar.gz
tar xzf temp/macos.tar.gz -C temp
cp temp/macos-arm64/libwasm_run_dart.dylib .dart_tool/wasm_run/
WASM_RUN_DART_DYNAMIC_LIBRARY=$PWD/.dart_tool/wasm_run/libwasm_run_dart.dylib \
  flutter test test/wasm_sandbox_toolchain_test.dart --tags integration
```

**Golden suite** — host-locked: goldens encode the rendering host's
fonts/emoji/shadows and redden across minor SDK differences (the
dynamic_messages saga). Local red here is expected environment noise,
not a regression:

```bash
flutter test test/golden
```

### Why local can be red while CI is green (issue #1851, measured 2026-10-25)

Whole `flutter_app/test` tree on origin/main (macOS arm64, no
`--timeout`, integration tags on): **4156 passed / ~50 skipped / 36
failed in ~4.3 min**. Full per-test classification table lives in issue
#1851. The ci.yml comment "goldens stay guarded by build-macos.yml and
the nightly full matrix" is STALE: build-macos.yml has never contained
a `flutter test` step (whole git history) and gh-1538 retired nightly's
full-suite backstop — nightly is builds + integration-only. At HEAD no
leg guards the golden suite; the pinned-font golden migration follow-up
(#1856) is the systemic fix tracked from issue #177 E5/OQ3.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
