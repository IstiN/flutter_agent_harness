# Changelog

Older entries: [CHANGELOG_ARCHIVE.md](CHANGELOG_ARCHIVE.md) — moved out
on 2026-10-09 (gh-1452): pub.dev server-rejects a publish whose
CHANGELOG.md exceeds its 262144-byte content cap, so this file keeps a
bounded recent window and `scripts/check_changelog_size.sh` (release
pre-tag + publish gates) fails fast when the cap is approached again.

## 1.0.506

- fix(#1044): AIIN mobile/macOS add-provider — sign-in completes but the provider is never added (#1194)
- fix(ci): pass flutter-version explicitly — awf no longer defaults a toolchain (#1205)

## 1.0.507

- gh-1208 [BENCH] fix-git task image broken on CI runners — docker compose build fails in BOTH TBench-1 runs (unknown_agent_error, trial never starts) (#1218)
- gh-1206 WIP auto-save 2026-10-04T05-52-28 (#1216)
- gh-1209 [BENCH] usage fold skips failed trials — agent_timeout rows report 0/0 tokens though the session JSONL has full usage (#1123 follow-up) (#1215)

## 1.0.509


- chore(pin): awf workflows track @main — always-latest policy (owner
  directive 2026-10-04). All five machine-loop stubs (teammate, SM,
  merge, sm-kicker, merge-trigger) flip from immutable SHA pins to
  `dmtools-agentic-workflows@main`, so awf fixes (kicker real ticks
  awf#13, per-SHA concurrency awf#14, teammate defaults awf#12) go live
  on merge with no re-pin ceremony. Security trade-off (owner-accepted):
  a mutable ref executes whatever sits at the awf main head — mitigated
  by awf main being review-gated, by
  `test/machine_kit/factory_stub_ref_test.dart` now guarding ALL FIVE
  `uses:` refs resolve to exactly `main` (never a stale SHA, never a
  random ref) in lockstep, and by the agents ENGINE pin staying an
  immutable 40-hex SHA via `factory_ref`. The `secrets:` policy is
  settled per-callee in the same guard: teammate/sm/merge map
  `SOURCE_GITHUB_TOKEN` explicitly (their factories declare it
  required), while merge-trigger keeps the factory-documented
  `secrets: inherit` PAT passthrough (factory-merge-trigger declares no
  secrets) and the kicker carries no secrets block. Stale
  immutable-SHA pin comments in ai-teammate.yml / machine-sm.yml
  rewritten to state the always-`main` policy (#1222).

## 1.0.510

- gh-1226 [BUG] 1.0.505 (with #1190 aboard): mail-wake turn after /sessions restore still loses the provider/key binding — copilot-401 error on a z.ai session + fused guidance text (#1237)
- gh-1199 [GOAL] Deterministic-only Quality gate: mock LLM everywhere, live models move to supervised benches (#1229)
- feat(1101): Agent Wire Protocol v1 — web reference client (sdk/web), conformance runner, browser example (#1228)
- gh-1224 [BUG] iOS 1.0.504: all wasm interpreters (python/qjs/lua/sqlite3) dead — 'no lazy loader' in FOREGROUND bash _forJob() clone drops moduleLoader (regression suspect #1163) (#1225)

## 1.0.511

- gh-1164 [GOAL] built-in js-apps skill (promoted from app asset, decisive apps-vs-widget routing) + JS render/runtime errors reported back to the authoring agent as failures (blocked by #1151) (#1246)
- gh-1244 [FLAKE] PTY integration: secret_sheet_test «IT-mask: masked from the first keystroke» waits for exactly 5 bullets while typing races ahead (red main, run 37232401938) (#1245)
- gh-1241 [GOAL] Session token-usage ledger: resume-aware usage.json fold over the session chain (provider-reported, estimated marked) (#1243)
- ci(quarantine): skip scheduled_indicator_test.dart in the gate (flake, https://github.com/IstiN/flutter_agent_harness/issues/1252) (#1253)
- gh-1077 [GOAL] flutter_app compaction parity with CLI — mobile sessions never compact (roles/smol absent, wrong context window, silent failure, no over-window relief) (#1239)
- ci(quarantine): skip job_board_stability_pty_test.dart in the gate (flake, https://github.com/IstiN/flutter_agent_harness/issues/1250) (#1251)
- gh-1235 Wire jsr.openUrl + webView host into the app JS engine (js_widget_runtime = 0.4.154) (#1238)
- gh-1226 [BUG] 1.0.505 (with #1190 aboard): mail-wake turn after /sessions restore still loses the provider/key binding — copilot-401 error on a z.ai session + fused guidance text (#1237)
- gh-1199 [GOAL] Deterministic-only Quality gate: mock LLM everywhere, live models move to supervised benches (#1229)
- feat(1101): Agent Wire Protocol v1 — web reference client (sdk/web), conformance runner, browser example (#1228)
- gh-1224 [BUG] iOS 1.0.504: all wasm interpreters (python/qjs/lua/sqlite3) dead — 'no lazy loader' in FOREGROUND bash _forJob() clone drops moduleLoader (regression suspect #1163) (#1225)

## 1.0.513

- fix(1096): reseed fa-extension size floor for intentional js-apps skill growth (gh-1164) (#1258)

## 1.0.514


- fix(#1197): TUI frame pipeline self-heals a throwing view/render (gh-1197 AC3) — a mid-run render exception now logs loudly, invalidates the diff state (no stranded DEC 2026 BSU), and repaints instead of dying or freezing; PTY liveness regression test proving paced thinking + answer text + a long silent tool call paint continuously (AC1/AC2/AC4), via the scripted stream's new paced `chunks`/`pace_ms`, `thinking`, and `sleep_ms` steps

## 1.0.515

- gh-1292 fa-tokens line must reach stdout in headless/CI runs (ledger emission invisible to the GH log) (#1295)
- gh-1296 [BUG] iOS build red in CocoaPods layer: package:sqlite3 build_hook fails — Podfile.lock drift (pods cache re-rolls weekly) never-again: ALL lockfiles committed + enforced (#1298)
- feat(1096): mac size diet — wasm_run_flutter.framework + never-loaded assets, ratcheted (#1227)
- chore(merge-trigger): track awf @main + map_pr_labels: true (#1285)
- ci(quarantine): skip secret_sheet_test.dart in the gate (flake, https://github.com/IstiN/flutter_agent_harness/issues/1283) (#1284)
- fix(1280): CLI arch matrix gates the merge; release binaries boot-smoked (#1282)
- gh-1276 [BUG] iOS: memory_search returns garbage + memory_list hides user-scope notes (agent fell back to memory_delete by exact text) (#1281)
- ci(quarantine): test/integration/theme_readability_pty_test.dart (flake) (#1255)
- gh-1274 [BUG] iOS sandbox bash: relative paths resolve to a nonexistent CWD — files written in the sandbox are invisible to relative-path commands (still broken on 1.0.512 after #1225) (#1279)
- gh-1266 [BUG] nightly red: macOS flutter_app suite — 5-test cluster around apps panel / open_app launcher / dynamic_message tiles (suspects #1139, #1173) (#1278)
- gh-1275 [BUG] Built-in skills (#1151) not packaged into the apps: iOS ships EMPTY skill dirs (create-goal/fa-self-config/js-apps exist, SKILL.md missing) — verify macOS/Android too (#1277)
- gh-1272 [BUG] [URGENT] 1.0.512 TestFlight (build 205): EVERY JS widget dead — engine eval error 'Unterminated regular expression literal /[ ⇥' on all widgets (source corruption in assembly/catalog path) (#1273)
- gh-1265 [BUG] nightly red 5 nights: native desktop builds broken by a TRANSITIVE flutter_inappwebview nobody declares — linux WPE missing + windows MSVC 14.51 STL1011 (lockfile not committed) (#1268)
- gh-1261 [BUG] Play listing deploy fails: clear_images! HTTP 400 — invalid image_type "images" for en-US/phoneScreenshots (daily-publish Play leg red) (#1264)
- feat(#1079): SDK slice 2 — live agent-stack wiring (wireAgentCore); CLI converts to the shared builder (#1230)
- gh-1197 [BUG] TUI fixes (recovered dev leg) (#1263)
- ci(quarantine): skip dap_wake_hang_test.dart in the gate (flake, https://github.com/IstiN/flutter_agent_harness/issues/1248) (#1249)
- gh-1073 Session JSONL grows unboundedly (12 GiB ledger records) → resume fails with 'Failed to read session' + heap-exhaustion crash (#1247)
- fix(1096): reseed fa-extension size floor for intentional js-apps skill growth (gh-1164) (#1258)

## 1.0.516

- gh-1299 [BUG] [URGENT] main red 13 legs: release commit v1.0.515 bumps version WITHOUT regenerating pubspec.lock — new --enforce-lockfile (#1268) hard-fails every leg (#1304)

## 1.0.517

- gh-1299 [BUG] [URGENT] main red 13 legs: release commit v1.0.515 bumps version WITHOUT regenerating pubspec.lock — new --enforce-lockfile (#1268) hard-fails every leg (#1304)

## 1.0.518

- gh-1307 [BUG] nightly macOS suite red: js_app_error_capture_test — load error NOT captured (empty list) regression from #1273's engine fix, merged green through the PR exclusion-zone hole (#1309)
- fix(918): omp_ref reference fixtures captured on PTY host + nerd-glyph parity wiring (#1231)
- gh-1310 [CI] Tag CI for v1.0.513 red — 4+ jobs fail (Android APK, web debug, Hostile ambient env, PTY screenshots) → release asset-less, legs fall back to v1.0.511 (#1312)
- gh-1303 [CI] Pages 'Build landing + web demo' red on main — '41 packages have newer versions incompatible with dependency constraints' (blocks publish + merge-trigger) (#1305)
- gh-1299 [BUG] [URGENT] main red 13 legs: release commit v1.0.515 bumps version WITHOUT regenerating pubspec.lock — new --enforce-lockfile (#1268) hard-fails every leg (#1304)

## 1.0.520

- fix(1250): assert frozen-row invariant, not an unsampleable mid-drain frame (#1286)
- gh-1300 [ENH] PTY integration tests: pay toolchain+boot ONCE per shard, not per test (~30s spawn overhead × N tests) — boot-once + reset between tests (owner design), FA_BIN AOT seam as the cheap first cut (#1306)

## 1.0.521

- fix(1248): dart_tui guard misfires ghost mail-wake turns — log-and-keep-running (#1289)
- gh-1257 [FLAKE] PTY integration: convert the 5 residual exact-bullet-count anchors (secret_sheet_residual_test / password_prompt_pty_test) to the gh-1244 property anchor (#1287)

## 1.0.522

- fix(ci): play edit-commit sets changesNotSentForReview (#1367)
- fix(1339): surface recovered trials, terminal failure modes, and model ids in the bench summary (#1351)
- feat(1331): iOS size diet — IPA dSYM strip + never-loaded fixture prune + ratchet (#1333)

## 1.0.523

- gh-1341 Bump js_widget_runtime pin to 9d57570 / ^0.4.156 — flutter_js hostCall/capture channel fix (fa-craft lag, voxel-sandbox spinner) (#1366)
- fix(1349): deny bare long foreground sleeps; enrich liveness reminders with the background hint (#1355)
- fix(1293): dap start exit-0 guarantees the dial credential is durably on disk (#1354)

## 1.0.524

- ci(quarantine): skip shell_job_countdown_pty_test.dart in the gate (flake, https://github.com/IstiN/flutter_agent_harness/issues/1365) (#1347)
- fix(1368): pub.dev publish — push-tag-only OIDC path, dart-only gate, verify waits instead of false-alarming (#1370)
- fix(1339): review hardening — session-archive traversal guard on every branch (#1369)
- fix(1323): live thinking streams in the TUI — reasoning deltas commit the transient-retry attempt (#1325)

## 1.0.525

- ci(quarantine): skip subagent_integration_test.dart in the gate (flake, https://github.com/IstiN/flutter_agent_harness/issues/1372) (#1373)
- fix(1254): quarantine dracula theme-flake + wait headroom for starved shard (#1288)
- fix(1234): whole-tree CRAP ratchet 12→8, loc-gate migration, all top offenders fixed (#1291)
- fix(1252): widen scheduled-indicator reminder window past loaded-runner pre-check (#1290)

## 1.0.526

- feat(1322): wireAgentCore host-adoption gaps — embed guide, host key resolver, lifecycle telemetry (#1327)
- fix(1319): route paging history notifies through the guarded bridge (follow-up to #1320) (#1324)

## 1.0.527

- gh-1393 [GOAL] Mobile agent parity: bash-identical sandbox shell (glob/grep/cd/dev-null) + first-class jsr widget testing (jsr.test.*, check_app) (#1401)

## 1.0.528

- feat(1379): Compaction 2.0 second tier — agent-initiated hide, LRU re-hide, per-segment pins (#1383)
- fix(1402): pre-flight Play listing language gate + edit-discard on commit failure (#1405)
- feat(1380): obligations ledger substrate — verbatim entries + level-0 context block (A1 slice 1) (#1382)

## 1.0.529

- feat(1377): auto_update tri-state flag — notify banner, autonomous verified self-update, /update (#1384)

## 1.0.531

- fix(1406): bench ConnTrace dark inside tmux — launch-line env + loud-empty guard (#1416)

## 1.0.532

- ci(quarantine): skip pty_resume_equivalence_test.dart in the gate (flake, https://github.com/IstiN/flutter_agent_harness/issues/1422) (#1423)
- ci(quarantine): skip composer_echo_pty_test.dart in the gate (flake, https://github.com/IstiN/flutter_agent_harness/issues/1413) (#1414)

## 1.0.533

- gh-1412 [GOAL] Near-miss elimination: FinalizeGate contract + TaskLedger — the agent verifies produced state against task text before declaring done (#1418)
- gh-1403 [daily-publish] testflight leg failed (#1424)
- feat(bench): per-task test-budget override table + planner fairness guard (gh-1407) (#1417)

## 1.0.534

- fix(1408): harness-induced bench failures — isolated job logs, redacted at rest, shape-only bash interceptor (AC1–AC3; AC4 documented) (#1410)
- gh-1415 [GOAL] Subagent status line-language: one compact live row per subagent in the CLI TUI (omp-density, ten named deltas) (#1420)

## 1.0.535


- gh-1426 [GOAL] Model capability negotiation (rework): the resolver's loud
  notes now ride the built `Model` (`capabilityNotes`) and render on the
  status surfaces — `/model-edit` prints them next to the resolved triple,
  and the single-model boot prints them in the boot notice — so a gated
  pin (E3), an override-vs-endpoint divergence (E1), and a catalog-miss
  override (E4) are never silent. Also: `applicationNote('models')` says
  "applies live to the next model build" (the flow live-applies; "next
  boot" was wrong), the duplicate `_capabilitySummaryFor` collapsed onto
  `_capabilitySummary`, the two capability remove paths share one
  `_removeCapabilityYaml` body, the omit-max-output menu row names its
  adapter scope ("openai-completions only"), the dead
  `resolveModelRefCapabilities` export is dropped, and the resolver's
  ceiling-table lookup and documented wire field both read the same
  effective api (`api ?? spec?.api`).
- **Behavior change (gh-1426, deliberate — AC6)**: pre-existing
  `thinkingLevel` pins (a `roles:` chain entry, the `FA_PROVIDER_CONFIG`
  preconfig, or a `models.overrides` pin) now reach the wire for the first
  time on the openai-completions family (`reasoning_effort`) and google
  (`thinkingConfig`); on `origin/main` they were carried but wire-silent
  there. Consequences: (1) REG-1's "no overrides → byte-identical payload"
  corpus holds only for sessions with NO thinking pin at all — a session
  with a bare roles pin changes payloads by design; (2) an endpoint that
  rejects `reasoning_effort` (strict gateways, o-series rung spelling) can
  now 400 where it previously worked — unpin the level (`/settings → Model
  capabilities → thinking level → off`) or pin `omitMaxOutputTokens` where
  the max-output field is the problem. The boot note that claimed the
  openai-completions adapter "is not wired" to the config-carried level is
  corrected and now fires only for the genuinely unwired adapters (dial,
  copilot, chatgpt-codex).

## 1.0.537

- feat(1374): animated two-tone kaomoji thinking indicator — app + web TUI (#1419)

## 1.0.538

- gh-1433 [GOAL] Workflow log fidelity: non-interactive headless renders EVERYTHING the model says — thinking deltas AND assistant text, default-on (the post-hoc log IS the UI) (#1437)
- gh-1425 [GOAL] Resume loses structured-compaction folds — marathon session reopens at 143% of window make fold projection resume-equivalent and cap every detonation path (#1427)
- gh-1430 [GOAL] Headless stream-liveness: fa must heartbeat provably-alive reasoning streams, and the bench stall-gap must defer to fa's own watchdog (round-4 RCA: 13 tasks ≈ 16% killed mid-thinking) (#1436)
- chore(1431): reseed fa-extension size baseline for the 3.47.7 engine rev (#1432)
- gh-1409 [GOAL] Compaction-pinned skill operative lines — instructions must survive folding (image-carrier precedent) (#1428)
- feat(1374): animated two-tone kaomoji thinking indicator — app + web TUI (#1419)

## 1.0.539

- gh-1438 bash_job: resolve near-miss/stale job ids instead of 'unknown background job' dead-ends bound status output GC exited jobs (#1447)

## 1.0.540

- gh-1441 Voxel nodes render as the “Voxel world” placeholder — Fa app builds JsonWidgetRenderer without voxelWorld (fa-craft 0.2.18, voxel-sandbox 1.0.0) (#1445)

## 1.0.541

- feat(1079): SDK slice 6 — IT-5 record-level runtime parity for extension hosts (YoClip scenario) (#1456)
- gh-1449 [GOAL] Orphan-result notices: reported once, never a user turn, always identifies the call (#1451)
- gh-1439 [GOAL] Live-follow etiquette: scrolling up while the agent works never yanks the user back down (TUI + app + web: follow-mode contract + «jump to live» affordance) (#1443)

## 1.0.542

- gh-1450 [GOAL] SSO/OAuth login must always show the full authorization URL and allow opting out of the default browser (CodeMie/OpenRouter/ChatGPT family) (#1464)

## 1.0.543

- gh-1450 [GOAL] SSO/OAuth login must always show the full authorization URL and allow opting out of the default browser (CodeMie/OpenRouter/ChatGPT family) (#1464)

## Unreleased
