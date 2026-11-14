# Quality gates (pre-commit hook: scripts/pre-commit)

> Moved verbatim from `AGENTS.md` (gh-2181 — the slim-AGENTS.md card). Canonical reference; the slim AGENTS.md carries the one-line summary and points here.

## Quality gates (pre-commit hook: `scripts/pre-commit`)

The single CI gate is the SM pre-merge validation run (gh-1537): the
machine SM (#687, `machine-sm.yml` → factory-sm) updates the branch onto
main, dispatches `ci.yml` on the updated head, and merges only when green
— the tree that lands is byte-identical to the validated tree, so the
retired post-merge main CI run was pure repetition (and #1522's
tag-sourced versions remove the release-bot commits that retriggered it —
fewer main pushes → less SM queue churn). `ci.yml` fires on `v*` tags
(release pipeline), the 2h auto-release coalesce schedule, `release:
published`, and workflow_dispatch ONLY — never on `push: [main]`. The
serialized-validation invariant is alarmed by `sm-merge-guard.yml`: every
main push must carry a tree covered by a successful dispatched
validation, else one deduplicated `sm-guard` issue files (no nightly
backstop, per the owner's directive).

Issue #177 restructured CI so a PR pays only for what it touched. The hook
is a thin wrapper over `scripts/ci_fast_gate.sh`; CI is NOT the same
process — it implements the same stages as parallel jobs, and since
issue #194 its PR path classification runs through the SAME script
(`ci_fast_gate.sh --dry-run` in the `changes` job). One classifier, one
set of thresholds; parity is checkable by diffing the hook's
`GATE_STAGE <name> OK|SKIP` markers against the stages the CI changes job
logs for the same diff. Path filters: docs/markdown/prompts-only →
size+analyze; lib/bin/test/example/pubspec → +tests, coverage, CRAP,
jscpd + cross-module dupx; `test/integration/**` → + `integration-mock`
(issue #551: the no-key legs run per-PR); flutter_app/packages → +dupx,
flutter analyze+tests;
scripts/.github/crap4dart.yaml/unknown → everything (safe default, E2 —
holds in CI too). Hook-only extras: dart format self-heal of staged files
and `scripts/check_goldens.py --quick` (skipped for docs-only commits).

- `dart analyze` + dart format clean (explicit dirs — `yoclip/` is a
  standalone video workspace with its own toolchain); example app also
  `flutter analyze --no-fatal-infos --no-fatal-warnings`.
- `dart test` green (integration-tagged excluded from test-core — issue
  #551: `test/integration/**` changes also run the `integration-mock` leg
  per-PR: no-key legs via `MockLlmServer`, `--exclude-tags llm,browser-ext,
  perf,pty`; child-agent-spawn PTY tests carry `pty` and stay in nightly
  (issue #553). Tag-only CI = llm smoke + publish + binaries; nightly keeps
  the full real-provider suite (pty-integration). Since gh-1537 there are
  NO main CI runs — "tag-only" is literal: tags/dispatch/schedule only.
  **The Quality gate is deterministic-only (gh-1199): mock LLM everywhere,
  live models never.** Real-provider files carry
  `@Tags(['integration', 'llm'])` and run ONLY in the tag-only
  provider-smoke job and nightly with secrets — the per-PR integration
  shards exclude them at selection (`shard_files.py --exclude-tag llm`) AND
  at invocation (`--exclude-tags browser-ext,llm`), so a model's mood can
  never block a merge. The boundary is self-enforcing:
  `scripts/check_llm_tag_boundary.py` (static-gate step + pinned audit)
  fails any integration-tagged file that looks live without the `llm` tag;
  `test/scripts/shard_files_llm_boundary_test.dart` proves the shard
  selection stays live-free. Real-model verification belongs to the bench
  harnesses (terminal-bench / harbor / MLS-Bench) run under supervision,
  plus manual `dart test --tags "integration && llm"` for debugging — NO
  scheduled-or-gate live runs in the PR path. A proven flake (red in ≥2
  distinct-SHA gate runs within 24h) is quarantined via
  `scripts/test_quarantine.json` (checked in, reviewed in the fix PR;
  `flake-watch.yml` files the issue and opens the PR) — the gate legs pipe
  their targets through `scripts/apply_quarantine.py`, while nightly
  KEEPS running the file to produce the un-quarantine repeat-run proof.
  Flake intake consumes PR-dispatch runs only (gh-1537:
  `scripts/flake_watch.py` filters to `workflow_dispatch` events — the
  retired main trigger leaves SM validation dispatches and v* tag runs;
  a red tag run is a release-flow failure, triaged by daily-publish /
  ci-red-report, never quarantined as a flake). Dedup is per test name
  (the #1364 lesson): one test red across N runs files ONE issue.
- `cd flutter_app && flutter test --exclude-tags integration` green
  (includes golden suite; integration-tagged `test/cli_visual` runs
  pre-merge in ci.yml's `pty-visual` leg — gh-1538 retired the nightly
  duplicate — and on demand).
- Line coverage of `lib/` ≥ 80% (full ratchet in the pre-merge SM
  validation gate — every run that exists is a whole-tree
  `scripts/check_coverage.py 80` dispatch run; ci.yml has no
  `pull_request` trigger and no main runs since gh-1537, so the
  diff-coverage arm in `coverage-gate` is reserve for a future real PR
  trigger); jscpd duplication < 1%
  core `lib/`, < 3.7% `flutter_app/lib/` (ratchet — only tighten).
- Cross-module duplication (issue #487): clones spanning module roots
  (`lib`, `bin`, `flutter_app/lib`, `packages/*/lib`, `browser_ext/dart`)
  via `scripts/check_dup_cross_module.sh` — stage `dupx`, ONE jscpd
  invocation, marker-parity with the CI `guards` job (which also runs it
  for app-only PRs — cross-module clones are usually born app-side).
  Baseline 0.3013% of the combined ~283k lines, pinned 0.31 in
  `ci_fast_gate.sh` (ratchet — only tighten; the per-package gates above
  cannot see across module boundaries).
- CRAP ratchet (`crap4dart analyze`, tool pinned as
  `dart pub global activate crap4dart ">=0.15.0 <0.16.0"` — gh-1738
  superseded the old 0.11.0 bound: the root config's `gates.similarity`
  block ConfigExceptions on <0.15.0 parsers; gates/baselines need 0.15),
  one config per package, thresholds are the current per-package max —
  only down from here:
  - core (`crap4dart.yaml`, sources `[lib, bin]`): **12.0** (issue #1234:
    the named census offenders moved — CC-12 trio + readPasteboardImage
    16.32 split, the 0%-cov CC-3 quartet and the named CC-9 tier covered
    or split, `_listModels` covered — but the first whole-tree
    measurement showed the 8.0 repin unearned: 54 methods at 12.00
    (CC-3@0% tier + covered CC-12 dispatchers) and 83 at 9.00. Threshold
    stays at the measured max; the tier is the next ladder card).
  - flutter_app (`flutter_app/crap4dart.yaml`, sources `[lib]`,
    issue #433/#475): **30.0** — measured by the SAME pipeline the CI gate
    uses (the two `flutter-tests` shards emit `--coverage`; the
    `app-crap-gate` job merges the lcovs and runs the pinned analyzer —
    widget-test coverage differs from the core's dart lcov, E2).
  - The app ladder (follow-up cards, NOT this one): 2450 → 870 → 702 → 650
    → 380 → 272 → 210 (done: `JsAppEngine._faCall` 2450→6 via map
    dispatch, `patch` 94→19, `_tokenize` 70→18; issue #475:
    `wasm_shell_git.run` route-table + 51 golden tests, app `main()`
    boot-phase helpers, `wasm_shell` beasts `_grepBuiltin` 812→covered
    parse helpers, `_runPipeline` 702→210, `_runStage` 600→380,
    `_parsePrimary` 506→210; issue #558: the wasm_shell pipeline engine
    (`_runStage` 380→4, `_runPipeline` 210→4, `_evalExpr` 182→3); issue
    #559: the wasm_shell builtins (`_xargsBuiltin` 272→7,
    `_TestEvaluator._parsePrimary` 210→3, `_trBuiltin` 210→4,
    `_testBuiltin` 132→9, `_duBuiltin` 132→3, `_expandTrSet` 110→gone,
    `_tacBuiltin` 90→6, `_pipBuiltin` 72→3 — spec/table-driven parse
    helpers in `wasm_shell_builtins.dart` + tested exec halves) → next
    milestone 210-class (`GemmaService.chatStream` — gh-2004 since removed, `_statBuiltin` 156,
    wide_layout 156 pair) → … → **40**, each step "fix the code, then
    lower the threshold" — never lower first.
  - Guards (`scripts/check_crap_guards.py`): README badge == config
    threshold for BOTH packages, generated-exclude parity between the
    two configs, and `--only-down` (a PR that raises any threshold vs
    the merge base is rejected in CI).
- Max 2800 lines per `.dart` file (crap4dart `loc` gate, issue #1234 —
  generated output excluded in the gate configs; `*.g.dart` exempt).
- CI layout: `changes` (path filter) → parallel `static`, `test-core`
  (3 duration-balanced shards, `scripts/test_shards.json`, rebalanced
  weekly from junit durations; shard jobs emit junit-shard-N artifacts and
  `shard_files.py` bin-packs manifest-missing new test dirs at runtime),
  `coverage-gate`, `guards`, `flutter-tests` (ubuntu; goldens stay
  host-locked in build-macos.yml) → one aggregate `Quality gate`
  required check, plus `step-timings` (per-step duration telemetry) and a
  `watchdog` (>2x-baseline timeouts; a timed-out PR leg gets ONE
  empty-commit retrigger — never `gh run rerun`, which reallocates into
  the same degraded runner pool). `perf-gate` (issue #303) folds the #262
  DoD `dart test --tags perf` trajectory gate into the aggregate for
  trajectory-touching PRs. Issue #551 adds the `integration-mock` leg to
  the aggregate for `test/integration/**` PRs (no-key legs via
  MockLlmServer); the tag-only `integration` job is just the llm provider
  smoke and `publish` waits on it. Issue #1267 N1 adds the
  `flutter-app-exzone` leg: it runs the macOS exclusion-zone family
  (`flutter_app/test/apps/` — JS-engine tests the ubuntu leg skips via
  `native_test_guard.dart`, plus `flutter_app/lib/apps/` + `lib/src/js_ext/`
  are the code that surfaces there) on macos pre-merge, closing the
  nightly-only gap the #1309 escape rode. Under this repo's dispatch-only
  CI the leg is path-blind: ci.yml has no `pull_request` trigger (SM
  `workflow_dispatch` validation is the PR gate), so the leg runs in every
  SM validation dispatch (gh-1280 binaries-pr idiom); the
  `flutter_app/lib/apps/**`/`lib/src/js_ext/**`/`flutter_app/pubspec.yaml`
  path set in the `changes` job only narrows a future real `pull_request`
  trigger. Tag/schedule/release runs skip it — gh-1538 retired the
  nightly full-suite macOS backstop, so this pre-merge leg is the macOS
  coverage for the JS-engine surface (with gh-1537 there are no main ci
  runs at all — the SM validation dispatch is the single test gate).
  **Nightly (gh-1538) is builds + integration-only**: `nightly.yml` keeps
  the release-mode build matrix (all store/desktop targets) + PTY/CLI
  integration (full real-provider suite with secrets, un-quarantined per
  gh-1199); unit shards, analyze, coverage, CRAP/jscpd and the duplicated
  cli-visual / flutter-app-macos legs moved out as pre-merge-gate
  duplication. `coverage-gardener.yml` measures the only-up CLI
  coverage weekly and files an ai-teammate "raise coverage to X" issue —
  the baseline itself only moves through a reviewed PR (issue #927).

