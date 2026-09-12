# issue-167-mobile-model-quick-switch

**Date**: 2026-09-12
**Category**: implementation
**Project**: /Users/s0m8u78r/work/opensource/tools/flutter_agent_harness
**Status**: done (PR #174 merged as squash dc9996f1; issue #167 auto-closed COMPLETED at 09:15:57Z; `in progress` label removed; all CI gates green — Quality gates incl. two re-review waves)

## Task
Issue #167 «Mobile: быстрый переключатель модели в хедере (parity desktop)»: the wide shell's chat header had a one-tap current-model chip → unified model picker; the narrow layout (`SessionChatSheet` panel header) had nothing — switching model on mobile meant opening Settings. Bring parity reusing the exact desktop flow, never forking picker logic.

## Findings / Result
- The mobile "header" is the `SessionChatSheet._buildHeader` row (title + kebab), NOT an app bar — the issue's line refs predated the launcher-shell refactor.
- **Shared chip**: new `flutter_app/lib/ui/widgets/quick_model_chip.dart` — `QuickModelChip` is the wide header's inline chip extracted verbatim (same tree: `Icons.memory` 14 indigo + bodySmall 12/dim, `Material`+`InkWell` r8, padding h8/v4) + `Flexible` ellipsis clamp + optional `tooltip`/`maxWidth` (narrow caps at 132). Wide renders `ValueKey('wideModelChip')`, mobile `ValueKey('sessionChatModelChip')`.
- **One picker config**: `quickModelPickerPage()` — the exact settings "Default chat model" `MediaSlotProviderPickerPage` config (slot null, `connectedOnly: true`, `allowMainConnection: false`, `mainBaseUrl: service.activeBaseUrl`). Both headers route through it → AC2 by construction.
- **One apply path**: `openQuickModelPicker()` — key resolve (`registry.keyValueForName` → `FaUiHost.resolveKey`) → `FaChatModelConfig` → `agentConfigFrom` → `AgentService.reconfigure` → `lastConnectionStore.saveFromConfig`. Presentation split only: wide `pushFaPage` dialog, mobile `pushQuickModelSheet` bottom sheet (0.8×screen, safe-area, rounded top). AC4 (mid-run semantics) by construction — single `reconfigure` path; stated in PR body, no dedicated IT.
- **Live chip**: the sheet now keeps `AgentService? _listenedService` (wide shell's pattern) — resubscribed in `initState`/first line of `_onManagerChanged`, removed in `dispose`; reconfigure and session-restore rebuild the chip without the manager ever notifying.
- **Long-press polish** on the mobile chip → `ModelsSettingsPage`.
- l10n `chatModelSwitchTooltip` en/ru; golden_guard `_coverage` entry → `launcher_golden_test.dart`.
- Tests (`test/quick_model_chip_test.dart`, 6): factory-config parity, E2E bottom-sheet switch (registry Acme → `acme-1` → `service.modelId` + chip label), live updates (reconfigure + session switch), long-press, 320pt clamp, and a **wide-callsite wiring test** (pumps `faHomeScreen` @1280×800, taps `wideModelChip`, asserts the opened page's config) so a re-forked call site fails on either side.
- Goldens: new `launcher/sheet_session_chip_320_dark.png` (320×568, long id ellipsizes); `sheet_session_*` ×6 + `store_inapp` ×6 (en/ru × ios/ipad/mac) re-minted for the chip, later re-minted again after the main merge added #168's trajectory button to the same row (header order: chip → timeline icon → kebab).

## Gotchas
- **Golden drift is host-class, not per-PR**: pristine main fails ALL launcher goldens + 5/6 store screens on this Linux container (`asrPlatformSupported` is macOS/iOS-only → composer renders send-arrow instead of mic; plus AA/codec drift). Convention (per Main, cf. dd8c6a82): regenerate ONLY the PNGs your diff touches, revert the rest, review by eye. Reviewer verified the Linux-minted PNGs pass his macOS full-suite run — the SDK (not the OS) dominates rendering for these suites.
- **CI has NO `flutter test` job at all** — no golden gate exists in any workflow; goldens are fleet-local only. That blind spot is why a 0.02% store_inapp chip delta survived until the reviewer's macOS full-suite run flagged it (store_chat already failed 2.36%/85179px locally pre-existing on `2ea54fa`, masking everything).
- **`store_inapp` snapshots include the sheet header** — any `SessionChatSheet` header change re-mints 6 PNGs (en/ru × ios/ipad/mac), not just the 4 the reviewer names (iOS carries the same header).
- **Never `git pull --rebase` on this branch**: orchestrated merge waves land `Merge branch 'main'` commits on it; a rebase replays MAIN's commits as branch-local picks and conflicts. Sync with `git merge origin/main` (resolve header-row conflicts by keeping BOTH additions) and push — history is a fast-forward superset of the remote head.
- `MediaSlotProviderPickerPage` renders fine inside `showModalBottomSheet` (it's a full Scaffold+AppBar); its AppBar back pops the sheet with a null result → no change.
- Fake-service `reconfigure` in tests needs a real `providerKind` (`'openai-completions'`) — `'test'` throws `Unknown provider kind` at system-prompt composition.
- Model step in tests: `find.widgetWithText(TextField, 'Model id')` + `ensureVisible(find.text('Save'))` before tapping Save; the `/models` fetch failure against fake hosts is silent (free-text entry) — same tolerance as `settings_test.dart`.
- `flutter test` runs dirty `GeneratedPluginRegistrant.swift` + windows registrants (connectivity_plus) — `git checkout --` before every commit; fresh worktrees need `touch flutter_app/.env`.
- File-scoped `read` + line-range edits on shifting files: anchor drift clobbers adjacent lines (lost `manager.addSession(...)` once, orphaning every session → all sheet goldens regenerated empty). Re-read after every multi-hunk edit session; diff against HEAD before committing.

## Key Files
- `flutter_app/lib/ui/widgets/quick_model_chip.dart` — NEW: chip + `quickModelPickerPage` + `pushQuickModelSheet` + `openQuickModelPicker`
- `flutter_app/lib/ui/widgets/wide_layout_shell.dart` — inline chip/flow → shared ones (−69/+22)
- `flutter_app/lib/apps/session_chat_sheet.dart` — chip + long-press + `_listenedService` subscription (+~60)
- `flutter_app/lib/l10n/app_{en,ru}.arb` + regenerated `app_localizations*.dart`
- `flutter_app/test/quick_model_chip_test.dart` — NEW, 6 tests
- `flutter_app/test/golden/launcher_golden_test.dart` — `_pumpLauncher(size:, modelId:)` + 320pt golden; `golden_guard_test.dart` — coverage entry
- Goldens: `launcher/sheet_session_*` ×7 (incl. new `sheet_session_chip_320_dark`), `store/*/store_inapp` ×6

## Config / Commands
- Scoped suite: `cd flutter_app && flutter test test/quick_model_chip_test.dart test/app_launcher_screen_test.dart test/settings_test.dart test/l10n_guard_test.dart` → 6+71 green.
- Golden regen (affected only): `flutter test test/golden/launcher_golden_test.dart --update-goldens` then `git checkout --` the untouched PNGs; same for `--plain-name "store_inapp"`.
- PR: https://github.com/IstiN/flutter_agent_harness/pull/174 (branch `feat/167-model-quick-switch`, squash-merged dc9996f1; review waves 05:27Z CHANGES_REQUESTED → answered 05:50Z, merge 09:15:56Z).

## Open Questions
- A CI-side flutter-golden job would close the gate blind-spot class (offered to the reviewer as a follow-up issue; not tracked yet).
