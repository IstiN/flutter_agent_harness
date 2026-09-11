# Issue #140 — browser-ext dispatch + macOS release fail on `.env` asset: `flutter pub get` deletes the placeholder

- **Issue:** https://github.com/IstiN/flutter_agent_harness/issues/140
- **PR:** https://github.com/IstiN/flutter_agent_harness/pull/150
- **Follow-up (unmasked):** https://github.com/IstiN/flutter_agent_harness/issues/152
- **Date:** 2026-09-11
- **Surface:** `scripts/build_browser_ext.sh`, `.github/workflows/browser-ext.yml`, `.github/workflows/build-macos.yml` (also covers `.github/workflows/pages.yml` implicitly)

## Symptom

`flutter_app/pubspec.yaml` declares gitignored `.env` as a Flutter asset
(flutter_dotenv). Every `build_browser_ext.sh --with-app` build without a real
`.env` died at asset bundling: `No file or variants found for asset: .env`
(`copyAssets` → `web_release_bundle`). Workflow-level `touch flutter_app/.env`
steps added in #136/#138 did **not** fix it — the file was gone again by the
time `flutter build web` ran (runs 34593431895, 34596707238).

## Root cause

`flutter pub get`'s **first full resolution** in `flutter_app` (fresh
checkout, no `.dart_tool/`) removes a pre-existing empty-touched `.env`;
a warm no-op re-get does not. Ordering decided everything:

- **browser-ext.yml dispatch (red):** `touch .env` → `(cd flutter_app &&
  flutter pub get)` (first resolution — deletes) → script → build fails.
- **pages.yml (green, same day, same runner image):** `flutter pub get`
  (line 44, first resolution) → `touch .env` (line 49) → script → green.
  pages.yml had accidentally been doing the correct order all along.

The issue author's local repro (touch → pub get → gone) matches; my
flutter 3.47.0/linux-arm64 did *not* reproduce the deletion — the behavior is
resolution/fleet-sensitive, which is exactly why placement (not mechanism
hunting) is the robust fix.

## Fix

`scripts/build_browser_ext.sh` now creates the placeholder itself, inside the
`--with-app` block, **after** the script's internal `flutter pub get`,
immediately before `flutter build web`:

- later than every pub resolution on every consumer path (browser-ext
  dispatch, build-macos 'Build extension zip', pages.yml 'Build Chrome
  extension');
- **non-empty** (`OPENROUTER_API_KEY=` / `MODEL_ID=` / `BASE_URL=`) — the
  populated shape is what build-macos.yml's macOS app job has shipped green;
- `[ -f .env ]` guard — a real local `.env` with developer keys is never
  overwritten.

The now-redundant workflow `touch` steps from #136/#138 were dropped (one
script covers all three consumers; the pre-#136 `(cd flutter_app && flutter
pub get)` warm-up stays — harmless, the script re-gets anyway).

## Verification

1. Local dry-run (flutter 3.47.0, full script end-to-end): no `.env` →
   placeholder created, build green, `.env` present in
   `flutter_app/build/web/assets/` (the exact failing step); real `.env`
   (`sk-real123`) → preserved byte-identical (md5), build green.
2. Dispatch smoke on the branch (run 34608446683, both attempts):
   'Build extension with the fa web app' **green ×2** — the exact step that
   failed in 34583546205/34593431895/34596707238.
3. Post-merge main: Pages workflow green (34610280476 — runs the script
   `--with-app`); owner-dispatched browser-ext on main (34610300389): build
   step green; macOS release run (34610304401): 'Build Chrome extension'
   exercises the same script.

## Lessons

- **Placeholder creation must follow the tool that prunes it.** When a
  gitignored file is a declared build input, create it *at the point of
  consumption* (after the last `pub get`), not at the workflow rim — every
  intervening tool run is a chance to lose it.
- **Mine green twins before theorizing.** pages.yml running the identical
  script green the same hour the dispatch failed pinned the mechanism
  (ordering) without reproducing the deletion locally.
- **A fixed build unmasks the next failure.** The dispatch e2e step had
  never executed in recorded history; once unblocked it turned out flaky
  (#152). Expect the next link in the chain when you fix a link.
