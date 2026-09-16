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

## Local test & CRAP measurement (issue #490)

The suite is not wedged — a "75-minute coverage hang" report was a
measurement-procedure artifact (coverage instrumentation × default
concurrency-4 file IO thrash), not a stuck test. The supported local
full-suite run:

```bash
cd flutter_app
flutter test --concurrency=2 --timeout 120s
```

That completes in ~20 minutes with zero timeouts. Anti-pattern: never
run `--coverage` with default concurrency locally — 14 concurrent
flutter_tester processes crawl for 75+ minutes and produce no lcov.

Expected local-red classes (all benign, see the 2026-09-16 evidence run:
1994 passed / 26 skipped / 85 failed):

- **Golden failures** — goldens are host-locked (they encode CI-machine
  fonts/emoji/shadows; guarded by build-macos.yml and the nightly matrix,
  never by local runs). For a clean signal, filter them out exactly like
  CI does:
  `flutter test --concurrency=2 --timeout 120s --exclude-tags integration $(find test -name '*_test.dart' ! -path '*/golden/*' ! -path '*/cli_visual/*')`
- **Deliberately red ACs of in-flight cards** —
  `wasm_sandbox_toolchain_test` (#337) and
  `session_oversized_windowed_test` (#381) fail on main on purpose until
  those cards land.
- `[fah][sessions] open … loading from disk` spam is session_reuse /
  oversized-window tests doing their job, not a hang.

**CRAP numbers are valid only from CI.** The `app-crap-gate` job ranks
from shard-merged lcov (union DA hits); a local ad-hoc `crap4dart
analyze` sees single-run coverage and lies. After any green CI run,
fetch the ranked report instead of gambling locally:

```bash
tools/crap_top.sh          # latest artifact, top-40 table
tools/crap_top.sh 100      # top-100
```

or download the raw JSON: `gh run download -R IstiN/flutter_agent_harness -n crap_report`.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
