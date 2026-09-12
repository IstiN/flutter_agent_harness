# Issue #166 — Apps grid custom cell spans (1×3, 2×2 …)

- **Issue:** https://github.com/IstiN/flutter_agent_harness/issues/166
- **PR:** https://github.com/IstiN/flutter_agent_harness/pull/176
- **Date:** 2026-09-12
- **Surface:** `flutter_app/lib/ui/widgets/span_grid_delegate.dart`,
  `flutter_app/lib/ui/screens/app_launcher_screen.dart`,
  `flutter_app/lib/apps/apps_store.dart` (`JsTileWidgetInfo`)

## Gap

The launcher grid already had span geometry — manifest
`"widget": {size: "WxH"}` and hold-release `tileSizes` overrides — but the
menu only offered the iOS presets (1×1/2×2/4×2/4×4), W was floored at 2 so
1-wide tiles (1×2, 1×3) were impossible, and `packTileSpans` was a first-fit
packer WITH hole backfill: a later small tile could slide back into an
earlier row's gap, so reading order ≠ tile order and a resize could
teleport tiles across the grid. The issue's grounding (apps_grid.dart /
AppsStore persistence) was stale — persistence lives in
`LauncherLayoutStore` (`launcher_layout.json` v2 `tileSizes`); the change
extends that store, no new subsystem.

## Change (+396 −52, 14 files)

- **Packer**: `packTileSpans` is now an order-preserving row-wrap packer —
  cursor row/col only advances; a span that doesn't fit the remaining row
  cells wraps to the next row and trailing cells stay blank; spans clamp
  to the column count. Reading order == tile order, deterministic.
- **Presets**: menu offers 1×1 / 1×2 / 2×1 / 2×2 / 1×3 / 3×1 plus the
  iOS 4×2 / 4×4 (l10n en/ru keys `launcherTileSizeTall/Wide/Column/Row`).
- **Manifest**: size range W 1–4 × H 1–4; out-of-range values clamp with
  an `AppLog.i` note, never a crash.
- **AGENTS.md**: span ranges, preset list, packer semantics updated.

## Tests

- AC3 property test: 300 seeded random span sequences → no overlap,
  in-bounds, monotone reading order, deterministic.
- AC1: manifest `1x3` renders 56px wide × 3 cells tall, beta packs beside.
- AC2: menu round-trip writes `tileSizes`; tile host survives reflow.
- AC4 goldens: `launcher/grid_span_clamp_narrow_dark` (3-col grid — 4×2
  clamps full-width, 1×3 tall, 2×2), `launcher/grid_span_wide_dark`
  (6-col desktop, unclamped), both eyeballed for tofu/overflow/legibility.
- E2: 0×0 / 9×9 manifest sizes clamp + note.

## Gotchas for next time

- **Golden baseline drift is pre-existing repo-wide in the Linux
  container**: clean main fails ALL launcher goldens + 12 apps goldens
  (verified via stash). Never "fix" this by regenerating pre-existing
  PNGs in a feature PR — restore them (`git checkout --`) and commit only
  genuinely new/affected ones. CI does not run goldens (precedent
  dd8c6a82).
- **`git stash` is a foot-gun around `flutter test`**: every test run
  re-modifies `macos/.../GeneratedPluginRegistrant.swift` +
  `windows/flutter/generated_*`, so a post-run `stash pop` CONFLICTS and
  aborts (silently restoring nothing, keeping the stash). Recover with
  `git checkout <stash-commit> -- <paths>`; never re-stash to "check
  clean main" around flutter runs — instead diff against `origin/main` in
  a scratch clone or accept the documented drift.
- 1-cell-wide (56px) tiles can't fit "Mon 8.2k"-style text at fontSize 11
  — the js_widget_runtime Column overflows vertically by ~58px (wrap).
  Compact ≤5-char strings + `maxLines: 1` fit.
