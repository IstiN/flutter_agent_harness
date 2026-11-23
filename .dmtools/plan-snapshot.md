# gh-2381 — plan (as executed)

Ticket: [ci-red] v1.0.766 failed — PTY shard 2/3 exit-handshake wedge →
cancelled → Quality gate red → vpinned refused; watchdog retrigger red'd
the #2260 AC1 hostile-env flake. Mode: plan (sp=4).

## Tasks

- [x] T1 — RCA from the run artifacts (45200064457 shard 2/3 log + reporter
  json + the retrigger 45208045955 hostile-env log).
  - what: pin the three-layer chain (ws drop → engine abandonment →
    pty2 exit wedge) and the independent #2260 AC1 manifest-write race.
  - verify: `python3 scripts/gate_failed_targets.py --unfinished
    /tmp/shard2json/integration-shard-2.json` → the 3 in-flight suites;
    `--loaded` → 16; hostile log line 248 assertion vs the settle chain in
    `lib/src/cli/agent_cli_waiting.dart` (`jobSettled` unawaited).
- [x] T2 — RED: analyzer projections.
  - what: `--unfinished`/`--loaded` tests in
    `test/scripts/gate_failed_targets_test.dart`.
  - verify: `dart test test/scripts/gate_failed_targets_test.dart` — 3 fail
    before the analyzer change.
- [x] T3 — RED: wrapper abandonment semantics.
  - what: AC10–13 in `test/scripts/load_drop_retry_test.dart` (wedge kill +
    heal, rerun-red stays loud, exit-70 unfinished, never-loaded on exit 0).
  - verify: `dart test test/scripts/load_drop_retry_test.dart` — AC10–13
    fail against the old wrapper.
- [x] T4 — GREEN: `scripts/gate_failed_targets.py` projections (default
  contract unchanged).
  - verify: `dart test test/scripts/gate_failed_targets_test.dart` — 15 pass.
- [x] T5 — GREEN: `scripts/load_drop_retry.sh` — fifo+setsid runner, spam
  watchdog, abandonment-aware rerun, retry `--file-reporter` preserved.
  - verify: `dart test test/scripts/load_drop_retry_test.dart` — 13 pass;
    manual wedge repro heals in ~3s with the exact inventory.
- [x] T6 — Fix A: bounded observable-effect wait for the #2260 AC1 manifest
  leave (gh-2378 house shape).
  - verify: `dart test test/cli/agent_cli_waiting_integration_test.dart` —
    29 pass.
- [x] T7 — wiring/docs: ci.yml step comment (gh-2381), fixture-test header;
  no ci.yml invocation-shape change (AC1–AC4 static pins untouched).
  - verify: `dart test test/ci_load_drop_retry_guard_test.dart
    test/ci_jsr_trio_load_drop_guard_test.dart
    test/ci_watchdog_tag_retrigger_guard_test.dart` — 27 pass.
- [x] T8 — no-regression: full non-integration suite.
  - verify: `dart test --exclude-tags integration,browser-ext,llm` green.

## Decisions

- Detect+kill+rerun instead of preventing the wedge: dart has no atexit
  hook, abandoned suites are unreachable by teardowns — the only in-repo
  lever is evidence-driven healing at the wrapper.
- Trust the gh-2381 projections ONLY when the reporter log exists and is
  non-empty (missing log → never rerun blind, the #2331 rule).
- Spam pattern anchored on `Attempt:<n> waiting for isolate` so test-failure
  text that QUOTES the phrase (pty_harness StateError) never trips the kill.
- AC2 (#2260) left untouched: it asserts the record is KEPT — the race
  direction cannot fail it.
- The watchdog stays off when `LOAD_DROP_RETRY_SPAM_LIMIT=0`; default 8
  lines (~4s of blocked handshake — finite handshakes never block that long).

## Open questions

- Upstream test_core/coverage bug (engine dies on a coverage-gather throw,
  queue abandoned): filed as evidence here, not patchable in-repo; the
  wrapper makes the outcome heal + loud either way.
