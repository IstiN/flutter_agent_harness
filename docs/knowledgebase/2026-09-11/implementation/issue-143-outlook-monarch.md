# Issue #143 — add-in invisible in new Outlook (Monarch): manifest needed VersionOverrides command surfaces

- **Issue:** https://github.com/IstiN/flutter_agent_harness/issues/143
- **PR:** https://github.com/IstiN/flutter_agent_harness/pull/151
- **Date:** 2026-09-11
- **Surface:** `office_addin/manifest/outlook.xml`, `office_addin/dart/src/manifest.dart`, `office_addin/icons/`, `scripts/build_office_addin.sh`, `office_addin/README.md`, `site/`

## Symptom

After #131/#133 fixed install-from-file, the add-in installed cleanly
(«✓ Added» in Custom add-ins) but was **invisible in new Outlook for
Windows (Monarch) and modern OWA**: the message Apps flyout listed
nothing. Modern OWA's reading view also no longer renders classic
panes — the reporter confirmed both surfaces ignore classic
`FormSettings`.

## Root cause

Monarch and current OWA render **command-based add-ins only**: a
manifest must declare `VersionOverrides` with
`MessageReadCommandSurface` (button + `ShowTaskpane`) for anything to
appear. Our manifest was classic-only v1.1 MailApp (`FormSettings`
ItemRead/ItemEdit panes) — valid XML, valid schema, installs fine,
renders nowhere current.

## Fix

`office_addin/manifest/outlook.xml` gained a `VersionOverridesV1_0`
block (version bumped 1.0.0.0 → **1.1.0.0** so deployed clients
re-fetch):

- `MessageReadCommandSurface` **and** `MessageComposeCommandSurface`
  (parity with the classic ItemRead/ItemEdit forms): one «fa» button on
  `OfficeTab id="TabDefault"`, `Action xsi:type="ShowTaskpane"` → the
  same `https://fa1.dev/outlook/index.html`.
- Classic `FormSettings` kept for legacy hosts (issue: don't rely on it
  for any current client).
- New `fa-16/32/80.png` icons (command buttons require `bt:Image`
  16/32/80; area-average downscales of `fa-128.png` via a throwaway
  pure-Python zlib resampler — no PIL/ImageMagick on the box),
  assembled by `scripts/build_office_addin.sh`.
- `validateOutlookManifest` lints the new failure classes: missing
  `VersionOverrides`/`MessageReadCommandSurface`/`ShowTaskpane` (the
  exact regression), `Mailbox`-typed override Host, command `Icon`
  without the 16/32/80 set, unresolved `resid` references. Fixture
  extended + 5 corruption tests; artifact tests guard the committed
  surfaces and that every icon the manifest references is committed.
- README/site document the per-client entry point (Apps flyout vs Home
  ribbon).

## Lessons

- **`Host` inside VersionOverrides is `xsi:type="MailHost"`, not
  `"Mailbox"`.** The override schema's Host enum differs from the
  classic top-level `<Host Name="Mailbox"/>`. With `Mailbox` the OMEX
  gateway rejects the whole package with a misleading trio («product ID
  could not be parsed», «Package Type Not Identified», «Wrong
  Package») that looks like a broken `<Id>` GUID. Fixed in one line,
  linted now.
- **Bisect against a known-good sample.** When the gateway gave the
  misleading trio, validating a canonical OfficeDev sample manifest
  (`Office-Add-in-samples/…/Outlook-Add-in-SSO-NAA-IE/manifest.xml`)
  through the same tool proved the tool fine and the diff against it
  exposed `MailHost` in seconds. Note: generator-office template
  manifests contain ejs placeholders (`<% %>`) and fail to parse — use
  a real sample, not a template.
- **Regex lints CAN carry structure checks when scoped.** Cutting the
  `VersionOverrides` substring out first keeps the classic-section
  lints and the override-section lints from cross-matching (e.g.
  `MobileFormFactor` vs `DesktopFormFactor`, classic `Host Name=` vs
  override `xsi:type=`).
- **A remote merge "fixing" a conflict can silently revert a just-merged
  PR.** An automation merged main into our branch resolving the site
  conflicts toward the pre-#149 install text and dropping the
  support.html guide; the rebase resolution had to keep BOTH #149's
  install rewrite and #143's surface copy. Always diff a foreign merge
  against your own resolution before force-pushing over it.

## Verification checklist used

1. `npx office-addin-manifest validate office_addin/manifest/outlook.xml`
   (Microsoft validation gateway, exact committed bytes): **valid** —
   with both command surfaces. Baseline HEAD re-validated valid first
   (bisect hygiene: version-bump-only and overrides-only variants).
2. `dart analyze` + `dart test` in `office_addin/dart`: clean, 75
   passing.
3. `dart test test/site/site_llms_guard_test.dart`: 10 passing
   (re-run after the #149 rebase too).
4. `bash scripts/build_office_addin.sh --dev`: manifest OK on the
   dev-rewritten URLs, dart2js compiles, all 5 icon sizes assembled.
5. CI: Office add-in suite + Quality gates green (one known
   `hub_client_test` flake, rerun clean).

## Manual steps still owed (live host)

E2E against a real Outlook host isn't automatable without a mailbox:
in Monarch/new OWA open a message → Apps flyout → «fa» → taskpane
opens; compose toolbar button in Monarch; Home ribbon group in classic.
Documented in `office_addin/README.md` ("Where the add-in shows up").
fa1.dev must redeploy `outlook/` so the served manifest.xml + icons
match the repo.
