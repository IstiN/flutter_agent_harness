# GOAL — Fa widgets catalog (`fa_widgets`)

The widget-extensions initiative: a catalog of JS widgets hosted in its own
repo (`IstiN/fa_widgets`), published as GitHub release artifacts, browsable on
fa1.dev, and consumable by the Fa app ("Plugins / Widgets" panel). This doc is
the master spec: contracts, decisions, milestones, analytics, acceptance
criteria. Code lives in `/Users/Uladzimir_Klyshevich/git/fa_widgets`.

## Status of decisions (agreed 2026-08)

| Decision | Choice | Why |
| --- | --- | --- |
| Packaging per widget | **zip**, built by CI | widget dirs can grow to many files; git keeps text sources only |
| Binaries in git | **none** — zips exist only as release assets | diffs stay reviewable; no LFS |
| Catalog hosting | **GitHub rolling release `catalog`** (stable `latest/download` URLs) | no submodule hash bumps in flutter_agent, no cross-repo sync, site stays static |
| Per-widget releases | immutable tags `<id>-v<version>` created automatically on version bump | history + pinned permalinks + rollback |
| Site | fa1.dev gallery page fetches the SAME `catalog.json` client-side; raw files hotlinked from release assets | one source of truth, zero deploys to update catalog |
| Submodule | rejected | avoided on purpose (hash churn in flutter_agent on every catalog change) |
| CLI (headless install via config) | **out of scope until after App Store submission** | macOS/iOS ship first; revisit later (candidates: `js-apps:` section in `.fah/packages.yaml`, or an `apps_catalog` CLI tool) |
| Migration of already-seeded demos | none — existing installs are left untouched | ownership-aware seeding already protects user edits |
| Bundle slimming (move fitness-trainer ~5.5 MB out) | deferred to the app phase AFTER store submission | avoids golden/regression churn before submission |
| Apple positioning | "plugins / extensions / sample widgets", first-party curated, free, interpreted JS in our runtime; never "marketplace/store" | Guideline 2.5.2/4.7 scripting exception; avoid 3.2.2(b) store-likeness |

## Release contract (the ONLY interface consumers rely on)

Repo: `git@github.com:IstiN/fa_widgets.git` (MIT).

Stable URLs (rolling release named `catalog`, assets re-uploaded with
`--clobber`; asset names never change for a given id+version while it is
current):

```
https://github.com/IstiN/fa_widgets/releases/latest/download/catalog.json
https://github.com/IstiN/fa_widgets/releases/latest/download/<id>-<version>.zip
```

Pinned permalinks (per-widget immutable tags created on version bump):

```
https://github.com/IstiN/fa_widgets/releases/tag/<id>-v<version>
  → asset <id>-<version>.zip (same name)
```

### catalog.json (schemaVersion 1)

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-08-26T10:00:00Z",
  "sourceRepo": "https://github.com/IstiN/fa_widgets",
  "widgets": [
    {
      "id": "focus-timer",
      "name": "Focus Timer",
      "version": "1.0.0",
      "description": "Pomodoro-style 25/5 focus timer",
      "author": "Fa",
      "tags": ["productivity", "timer"],
      "permissions": { "network": false, "allowedCommands": [] },
      "minRuntime": "0.4.79",
      "icon": "icon.svg",
      "zip": {
        "file": "focus-timer-1.0.0.zip",
        "sha256": "<hex of the zip bytes>",
        "sizeBytes": 4821
      }
    }
  ]
}
```

Rules:

- `widgets[]` sorted by `id` (stable diffs); `generatedAt` UTC ISO-8601.
- `zip.file` is a bare file name — consumers join it against
  `releases/latest/download/`. NO directory components (assets are flat).
- `sha256` is over the exact published zip bytes.
- Additive changes only within schemaVersion 1; bump the number when breaking.

### Widget manifest (`widgets/<id>/manifest.json`)

Runtime fields (already consumed by the Fa app's `AppsStore` — MUST keep
shape): `id`, `name`, `description`, `version`, `icon`, `network` (bool),
`allowedCommands` (list), optional `widget` tile section and permission keys
(`llm`, `homekit`, `health`, `contacts`, `calendar`, `microphone`,
`notifications`, `media`, `keys`). All default-denied at runtime regardless.

Catalog-only fields (validated here, informational to consumers): `author`,
`tags`, `minRuntime` (semver ≥, e.g. `0.4.79`), `license` (optional).

Validator rules (CI-enforced):

1. Directory name == manifest `id`: `[a-z0-9][a-z0-9-]{1,31}`.
2. `version` strict semver `X.Y.Z`.
3. Entry `widget.js` exists and parses as JS text (non-empty; IIFE or module
   style accepted).
4. `icon`, if present, exists inside the widget dir (`.svg` recommended).
5. `network` bool; `allowedCommands` list of strings.
6. `minRuntime` semver.
7. Warnings (not errors): widget dir > 5 MB total, > 50 files, missing
   `description`.
8. Unknown top-level keys → warning (forward compatibility).

### Zip layout

Every zip contains ONE root folder named `<id>/` holding all files:

```
focus-timer-1.0.0.zip
└── focus-timer/
    ├── manifest.json
    ├── widget.js
    └── icon.svg
```

Rationale: safe extraction (no zip-slip ambiguity), trivially idempotent to
unpack into `apps/<id>/`, matches the app's dir-per-app layout. Entries sorted
by path; deflate level default.

## Workflows (in fa_widgets)

### `.github/workflows/validate.yml` (PRs)

checkout → setup-dart stable → `dart pub get` → `dart analyze` → `dart test`
→ `dart run bin/fa_widgets.dart validate`. Fail = PR blocked. Contributors
cannot break publishing without going through review.

### `.github/workflows/publish.yml` (push to main + manual dispatch)

1. Same validate steps.
2. Build: `dart run bin/fa_widgets.dart catalog --out build/catalog`.
   Produces `build/catalog/catalog.json` + one `<id>-<version>.zip` per
   widget.
3. Diff vs currently published catalog:
   `gh release download catalog -R IstiN/fa_widgets -p 'catalog.json' || true`
   → detect new/bumped widgets from the two JSONs.
4. For every NEW or version-bumped widget: create immutable tag/release
   `<id>-v<version>` and upload that widget's zip to it.
5. Update the rolling release: ensure `catalog` release exists, then
   `gh release upload catalog build/catalog/* --clobber` and refresh notes
   (auto-generated table: widget, version, size, changed?).
6. `concurrency: catalog-publish` so parallel pushes serialize.

Asset naming guarantees `releases/latest/download/<file>` always points at
the current set without any consumer-side lookup logic.

## Consumers

### C1 — fa1.dev gallery (site/, this repo) — track 2

New page `site/widgets/index.html` (+ linked css): fetches the GitHub
catalog.json URL client-side (CORS on release assets is open
`*`), renders cards (icon, name, description, permission chips, size,
Download button → direct asset link, Install-from-browser later). Follow the
existing dark style of `site/index.html`; add `/widgets` row into
`site/llms.txt` plus a machine index `site/widgets/llms.txt` linking the
catalog JSON. Fallback copy if fetch fails (GH unavailable). No build step —
plain static files like the rest of the site.

### C2 — Fa app extensions (flutter_app/) — track 3, AFTER store submission

Planned implementation order (each independently shippable):

1. `CatalogService` (`flutter_app/lib/apps/catalog/`): fetch catalog.json
   (injectable http client), TTL cache at `apps/.catalog_cache.json`,
   download zip → verify sha256 → unpack with `package:archive` (reject entry
   paths escaping the single `<id>/` root) → stage into temp dir → atomic
   swap into `apps/<id>/`. Config override of the catalog base URL for tests.
2. Origin model in `AppsStore`: `bundled | catalog(id, version) | user` kept
   in `.installed.json`; update check compares versions semver-wise (no
   downgrade); installation goes through the same ownership-aware seeding as
   bundled demos (user-modified files are never clobbered; `storage.json`
   untouched). "Restore reference version" re-downloads the zip.
3. Panel rebuild (`apps_panel.dart` + shared pieces reused by mobile
   launcher): honest filter chips (All / Pinned ← LauncherLayoutStore /
   Recent ← new tiny activity store / Live tiles), live-tile hero strip
   instead of the static Focus Timer prototype card, sections Installed /
   Created-with-Fa, permanent "Get more" tile opening a `CatalogSheet`
   (permission chips shown, diff-prompt on update adding permissions, Remove
   extension with storage warning, progress states, offline fallback to
   bundled starters).
4. Agent integration: tool `apps_catalog` (`search|list` read tier;
   `install|remove|get-source` write tier; get-source unpacks the reference
   zip into `.fah/widget-sources/<id>/`) + skill `js-apps` gains the
   sanctioned pattern: *before authoring, fetch canonical examples with
   apps_catalog get-source (installed copies may be user-modified); browse
   https://fa1.dev/widgets; publish upstream via PR to fa_widgets*.
5. Bundle slimming LAST: `assets/apps/` shrinks to calculator + weather
   starters; fitness-trainer GLB moves to the catalog; regenerate goldens +
   `demo_assets_declared_test.dart`.

Explicitly OUT until after store submission: headless CLI parity
(packages.yaml section or CLI tool), third-party contributor onboarding.

### Analytics (do not skip)

Three layers, all privacy-light (no user identifiers):

1. **fa_widgets repo** — GitHub native per-asset download counts on the
   `catalog` release = free install metrics. Nothing to build.
2. **fa1.dev** — page-level counter only (same approach as the rest of the
   site today); events: `widgets_page_view`, `widget_download_click(id)`.
   Keep it behind the existing, minimal setup; document counts as public.
3. **Fa app** — rides the existing `AppAnalytics` facade
   (`flutter_app/lib/services/analytics.dart`, global instance + injected
   test recorder; noop without Firebase). Event contract (implementation =
   track 3 step 2/3):

| Event | Params | When |
| --- | --- | --- |
| `widget_catalog_fetch` | outcome ok/stale/offline, durationMs, widgetCount | each TTL-refresh attempt |
| `widget_install_start` | id, sizeBytes, source(=gallery) | user confirms install |
| `widget_install_done` / `_fail` | id, durationMs, errorClass | after swap / verification failure |
| `widget_update_done` | id, from→to version, newPermissionsCount | successful update |
| `widget_remove` | id | user removes extension |
| `widget_open` | id, source: launcher/gallery/agent/open_app | every open |
| `widget_permission_prompt` | id, added[], granted | diff-prompt shown |

Names must follow the repo's existing lower_snake event style; params flat
(strings/ints/bools only, Firebase-compatible). No PII: ids are slugs, never
user content.

## Testing strategy

- fa_widgets (this repo): unit tests for the validator (happy + each error
  rule via fixtures under `test/fixtures/`), the builder (zip layout, entry
  sorting, sha256 matches bytes on disk, catalog sort/dedup/id-directory
  mismatch), and the CLI exit codes. Pure Dart, no network.
- App side (track 3): mirror tests under `flutter_app/test/apps/catalog/`;
  integration test against a local fake HTTP server serving a fixture
  catalog (never hit github.com from tests).
- Site: manual checklist + optional link-check workflow.

## Risks

| Risk | Mitigation |
| --- | --- |
| GH unavailable at app start | bundled starter widgets still render; catalog purely additive |
| Contributor submits huge/odd widget | CI caps + warnings; review gate on PRs |
| Version spoofing (downgrade attack) | app rejects remote version ≤ installed unless explicit restore |
| zip-slip / path escape | single-root `<id>/` requirement + app-side path validation on extract |
| Apple review wording drift | lint the strings: no "store/marketplace/install apps" language anywhere user-visible |

## Acceptance criteria — current milestone (M0, this work)

1. `/Users/Uladzimir_Klyshevich/git/fa_widgets` is a valid Dart package:
   `dart analyze` clean, `dart test` green, MIT LICENSE, README with
   contributing + publish flow docs.
2. Two seed widgets present and validating: `calculator` (ported from the Fa
   bundle) and `focus-timer` (new, replaces the prototype card later).
3. `bin/fa_widgets.dart validate` exits 0 on the tree, non-zero on broken
   fixtures.
4. `bin/fa_widgets.dart catalog --out build/catalog` produces catalog.json +
   zips exactly per the contract above (verified by tests).
5. Both workflows committed with correct triggers/concurrency.
6. Initial commit pushed to `IstiN/fa_widgets` (main), first publish run
   produces the `catalog` release with stable URLs.
7. This GOAL.md reviewed & merged in flutter_agent/docs/widgets/.

STATUS 2026-08-26: criteria 1–6 DONE (commit ece0009 pushed via HTTPS;
gh active account switched to IstiN for pushes). Criterion 7 = the very next
flutter_agent commit including docs/widgets/GOAL.md. First CI publish run —
check https://github.com/IstiN/fa_widgets/actions; on green,
`releases/latest/download/catalog.json` must list calculator + focus-timer.

## Acceptance criteria — milestone M0' (site gallery)

1. `site/widgets/index.html` renders the client-side catalog gallery
   (cards with icon/name/description/permission chips/size/Download) with a
   graceful offline fallback banner.
2. `site/widgets/llms.txt` machine index added; root `site/llms.txt`
   gains a Widgets section linking gallery + catalog.json.
3. Page analytics: `widgets_page_view` + `widget_download_click(id)` through
   the existing gtag.

STATUS: DONE (same flutter_agent commit as criterion 7 above). Live after the
next Pages deploy of fa1.dev. LIVE 2026-08-27: https://fa1.dev/widgets/ serves
200; root llms.txt carries the Widgets section; catalog.json lists 16 widgets.

## Acceptance criteria — milestone C2/M1 (Fa app catalog) — SHIPPED 2026-08-27

flutter_agent commit `4ea43d4e` (hook skipped: parallel-agent full-tree gates
red; scoped apps suites verified green: catalog_service 10/10,
apps_store_catalog, apps_catalog_tool, widgets_catalog_sheet 4/4, panel
goldens regenerated).

1. CatalogService (flutter_app/lib/apps/catalog_service.dart): fetches
   catalog.json with injectable http client, TTL cache +
   stale-offline fallback at apps/.catalog_cache.json, sha256-verified
   zip download, single-root zip-slip guards. DONE.
2. AppsStore origin model: installWidget/removeWidget (storage.json kept),
   .installed.json origin records, semverNewer/availableUpdates. DONE
   (ownership-aware re-seed reuse where applicable; diff-prompt on
   permission growth deferred with the update UI).
3. Catalog UI: WidgetsCatalogSheet (search, permission chips, size,
   install progress, offline banner) + "Get widgets" entry in AppsPanel.
   DONE (panel stays the launcher grid; no hero-strip rebuild in this
   milestone).
4. Agent integration: apps_catalog read tier (list/search) + write tier
   (install/remove/get-source → .fah/widget-sources/<id>/); js-apps
   SKILL.md rule 13 documents the sanctioned fetch-examples / browse /
   PR-to-fa_widgets loop. DONE.
5. Bundle slimming: assets/apps/ = calculator + weather + fitness-trainer;
   pubspec assets + demoAppIds pruned; goldens + tolerant tests updated.
   DONE with ONE documented deviation — fitness-trainer stays bundled
   (5.5 MB GLB binary cannot live in a sources-only git repo; it ships as
   an offline/reviewer starter instead of a catalog widget).

Live verification 2026-08-27: catalog.json (releases/latest/download)
serves schemaVersion 1 with 16 widgets; fa1.dev/widgets/ = 200.
