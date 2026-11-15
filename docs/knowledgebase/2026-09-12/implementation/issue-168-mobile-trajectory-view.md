# issue-168-mobile-trajectory-view

**Date**: 2026-09-12
**Category**: implementation
**Project**: /Users/s0m8u78r/work/opensource/tools/flutter_agent_harness
**Status**: done (PR #175 merged as 7a147b4c; issue #168 auto-closed COMPLETED at 06:15Z; all CI gates green incl. Quality gates 10m55s)

## Task
Issue #168 «Mobile: trajectory view (parity desktop)»: the narrow layout (`AppLauncherScreen` + `SessionChatSheet` floating panel) had no trajectory entry — mobile could not inspect runs/tool calls/compaction. Reuse the existing `packages/fa_ui` trajectory widgets; never fork rendering.

## Findings / Result
- The gap was NOT `FaChatScreen` (it already had a narrow Chat|Trajectory switcher) but the **launcher's `SessionChatSheet`** — mobile's primary surface had no trajectory affordance at all.
- Entry: timeline `IconButton` (`ValueKey('sessionChatPanelTrajectory')`, `Icons.timeline`, tooltip `appsOpenTrajectoryTooltip` en/ru) in the panel header row before the 3-dots menu → `MaterialPageRoute` push of `_SessionTrajectoryPage`.
- Page = `TrajectoryScreen(controller:, loaded:, onClose: pop)` — the exact shared fa_ui surface desktop uses (ledger/timeline/details/master-detail), zero fa_ui/lib changes.
- Controller ownership: **page-owned** `TrajectoryController` + subscription to the active session's `TrajectoryServiceFeed` (broadcast → replays latest snapshot, so a page opened mid-run renders the in-progress run; live turns keep arriving without refresh).
- **E2 pinned: follow** — page listens to `FlutterSessionManager`; a session switch while open re-binds to the newly active session (fresh controller → fresh scroll/selection state).
- AC4 goldens: added `layout/narrow_page_320` (320×844) + `layout/narrow_page_400` (400×844) baselines to `trajectory_layout_golden_test.dart`; committed PNGs rendered locally per convention (CI does not run goldens).
- AC5 needed no new work: virtualization already pinned by the existing `10k records stay virtualised while scrolling` (E5) table test at 2× the issue's scale; the page inherits ListView.builder + `ScrollCacheExtent.viewport(4)` + tail-follow.

## Gotchas
- **`fake_chat_service.dart` did not compile on clean main**: `FaChatService` grew `scrollToMessageHandler` in #120 but the fake never implemented it — every fa_ui test using the fake failed to load. Fixed with a 2-line no-op field (root-cause, disclosed in PR).
- **Ledger row text must be matched with `find.textContaining`**: rows render previews via spans, and exact `find.text` instead matches the transcript bubble *behind* the pushed route (misleading `descendant of TrajectoryScreen: []` failure message).
- **`tester.pageBack()` is useless here** (no `CupertinoNavigationBarBackButton`/`BackButton` in these surfaces): details sheet closes via barrier tap (`tester.tapAt(Offset(10,10))` — `tap(find.byType(ModalBarrier).last)` misses the hit test), the page pops via its header close (`find.byIcon(Icons.close)`).
- Real provider streams need `runAsync` (initialize/sendText/waitForIdle); settle the controller debounce with explicit `pump(4s)`, never `pumpAndSettle` (loading spinner animates until first snapshot).
- Rebinding the controller must dispose the OLD controller **post-frame** (`addPostFrameCallback`): `TrajectoryView.didUpdateWidget` removeListens the old controller during rebuild — synchronous dispose inside the manager notification throws.
- Parallel `flutter test` runs in one package poison golden comparisons (font/raster contention); classify golden failures only from solo runs. Solo drift set on this container (pre-existing AA class, cf. dd8c6a82, NOT regenerated): `layout/narrow_page`, `wide_fullscreen_dark/light`, 4 cell goldens; the two NEW baselines pass everywhere.
- Pre-existing failure on clean main: «mic swaps into send» in `session_chat_sheet_test.dart`.
- `flutter pub get`/test runs dirty `GeneratedPluginRegistrant.swift` + windows registrants (connectivity_plus transitive drift) — checkout before every commit.
- flutter_app tests refuse to build without a `flutter_app/.env` file (pubspec asset, gitignored; see also `issue-140-env-asset-ci.md`): `printf '# local dev env (gitignored)\n' > .env` in each fresh worktree.
- `/knowledgebase` at the container root is an UNRELATED repo (git.customsmobile.com, no SSH keys in container) — the KB convention lives in-repo at `knowledgebase/<date>/implementation/` via a `docs/<issue>-kb` PR (cf. #163/#165).

## Key Files
- `flutter_app/lib/apps/session_chat_sheet.dart` — `_openTrajectory`, header button, `_SessionTrajectoryPage`/`State{_bind,_onManagerChanged,_onSnapshot}` (+122 ln)
- `flutter_app/lib/l10n/app_{en,ru}.arb` + regenerated `app_localizations*.dart` — `appsOpenTrajectoryTooltip`
- `flutter_app/test/apps/session_chat_sheet_test.dart` — group «SessionChatSheet trajectory (issue #168)»: AC1/AC2/AC3/E1/E2 (5 tests)
- `packages/fa_ui/test/trajectory/golden/trajectory_layout_golden_test.dart` + `goldens/layout/narrow_page_{320,400}.png` — AC4
- `packages/fa_ui/test/fake_chat_service.dart` — compile fix (`scrollToMessageHandler`)

## Config / Commands
- Suite: `cd flutter_app && flutter test test/apps/session_chat_sheet_test.dart --name 'trajectory'` → 5 pass (full file: 29 pass + 1 pre-existing fail).
- Golden regen (affected only): `flutter test test/trajectory/golden/trajectory_layout_golden_test.dart --update-goldens --name 'narrow_page_320|narrow_page_400'`.
- PR: https://github.com/IstiN/flutter_agent_harness/pull/175 (branch `feat/168-mobile-trajectory`, commit 3f45a44d).

## Open Questions
- None. Merge-trigger label handling and auto-close verified; `in progress` label removed post-close.
