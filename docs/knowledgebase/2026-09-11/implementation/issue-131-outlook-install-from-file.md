# Issue #131 — Outlook add-in install from file fails («Installation failed»)

- **Issue:** https://github.com/IstiN/flutter_agent_harness/issues/131
- **PR:** https://github.com/IstiN/flutter_agent_harness/pull/133
- **Date:** 2026-09-11
- **Surface:** `office_addin/manifest/outlook.xml`, `office_addin/dart/src/manifest.dart`, `site/`

## Symptom

External user's tenant disables «Upload custom apps → Add from a URL», so they
downloaded `https://fa1.dev/outlook/manifest.xml` and used **Add from file**.
Outlook showed the generic dialog **«Installation failed — Add-in installation
failed.»** — no error code, no detail (see issue screenshot).

## Root cause — two defects, the second masked by the first

1. **`--` inside an XML comment.** The manifest header comment named the build
   flag `scripts/build_office_addin.sh --dev`. XML 1.0 §2.5 forbids `--`
   anywhere inside a comment, so strict parsers reject the *whole document* as
   malformed. Outlook's upload validation is strict — hence the parse-level
   «Add-in installation failed.» Reproduced outside Outlook:

   ```
   npx office-addin-manifest validate manifest.xml
   → Error: Malformed comment  Line: 4  Column: 38
   ```

   (that CLI POSTs to Microsoft's validation gateway
   `validationgateway.omex.office.net` — the same checks upload runs).

2. **`<RequestedHeight>` in the compose form.** With (1) fixed, the gateway
   surfaced a second error: the Office schema allows `RequestedHeight` only in
   the `ItemRead` form's `DesktopSettings`; the `ItemEdit` (compose) form
   accepts `SourceLocation` only:
   `invalid child element 'RequestedHeight' … has incomplete content … expected: 'RequestedHeight'`
   errors bracket this precisely (removing it from ItemRead → "incomplete";
   keeping it in ItemEdit → "invalid child").

Because defect 1 aborted at parse time, the repo's regex-lint validator
(`validateOutlookManifest`) — which never parses XML — saw nothing wrong, and
`manifest_artifact_test.dart` passed while the manifest was uninstallable.
Serving-side artifacts were never the problem: fa1.dev returned the manifest
byte-identical to the repo copy as `application/xml`, all referenced assets
HTTP 200.

## Fix

- Reworded the comment (no `--`); removed `RequestedHeight` from the `ItemEdit`
  form. Gateway verdict on the fixed manifest: **Accepted, 0 errors, 0
  warnings**.
- `validateOutlookManifest` gained two lints so neither defect can ship again:
  unterminated XML comment / `--` inside a comment; `RequestedHeight` inside an
  `ItemEdit` form. Both lints are string-scan shaped like the rest of the file
  (no XML dependency added).
- Install instructions (`site/index.html` ×4 incl. JSON-LD FAQ, `site/llms.txt`
  ×2, `office_addin/README.md`) now document **download manifest → Add from
  file** for tenants with URL install disabled — the reporter's exact case.

## Lessons

- **Regex lints don't validate XML well-formedness.** Any XML artifact that is
  handed to a strict consumer needs at least a comment/`--` and balance lint —
  or a real parse. Our validator passed while Outlook refused to parse the
  file at all.
- **Parse failures mask schema failures.** Fix the first rejection, then
  re-validate: the `ItemEdit`/`RequestedHeight` schema error only appeared
  after the comment was fixed. Validate the final bytes, not an intermediate.
- **Reproduce with the vendor's own gate.** `npx office-addin-manifest
  validate` hits Microsoft's real validation gateway (~0.5 s) — it matches
  Outlook's upload behavior far better than any local heuristic and turns
  «some Outlook dialog» into exact line/column diagnostics.
- **Sideload docs must cover the file path.** «Add from a URL» is frequently
  disabled by tenant policy; always document download + «Add from file» next
  to the URL flow.

## Verification checklist used

1. `npx office-addin-manifest validate <file>` pre-fix (repro) and post-fix.
2. `dart test test/manifest_test.dart test/manifest_artifact_test.dart` —
   includes the committed-artifact guard.
3. `dart test test/site/site_llms_guard_test.dart` after site edits.
4. `dart analyze` in `office_addin/dart`.
