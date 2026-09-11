# Issue #144 — Real Outlook add-in installation guide

- **Issue:** https://github.com/IstiN/flutter_agent_harness/issues/144
- **PR:** https://github.com/IstiN/flutter_agent_harness/pull/149
- **Date:** 2026-09-11
- **Surface:** `docs/outlook-addin.md`, `office_addin/web/support.html`,
  `site/index.html`, `site/llms.txt`, `office_addin/README.md`, `README.md`

## Symptom

The repo's own install instructions were a dead end for real users: they
told people to use **Settings → Integrate apps → Upload custom apps →
“Add from a URL”** — an entry Microsoft has removed from the manual
surface — and pointed classic users at “Microsoft's sideload guide”
without the actual steps. The owner, installing live, burned through
four dead ends (Marketplace, new Outlook's Apps catalog, new Outlook's
Settings, …) before finding the only working path.

## The verified working path (as of 2026-09-11)

1. Download `https://fa1.dev/outlook/manifest.xml` → `manifest.xml`.
2. Open **https://aka.ms/olksideload** — Microsoft's deep link into the
   *My add-ins* dialog; works from web, new Outlook (Monarch), and
   classic Outlook.
3. **My add-ins → Custom add-ins → “+ Add a custom add-in” → Add from
   file** → `manifest.xml` → Install → accept the trust prompt.

“Add from a URL” survives only as admin-deployed catalogs; self-install
is download-then-file, full stop.

## Where the guide lives (dual home, one content)

- **Repo copy:** `docs/outlook-addin.md` (linked from the root README's
  new “Outlook add-in” section and `office_addin/README.md`).
- **fa1.dev copy:** `office_addin/web/support.html` — the manifest's
  `SupportUrl` target, so a stuck user is one click from the guide. The
  build assembles it to `build/pages/root/outlook/support.html`
  (`scripts/build_office_addin.sh` copies `web/*.html`).

Site copy (`site/index.html` ×4 incl. JSON-LD FAQ, `site/llms.txt` ×2)
now carries the short path + a link to the full guide instead of the
dead URL flow.

## Honesty gates (review-driven)

The first draft required “manifest ≥ 1.1.0.0” unconditionally — but
fa1.dev serves **1.0.0.0** today and #143 (VersionOverrides) was still
open, making the requirement unachievable. Reviewer caught it; final
wording states the rollout explicitly:

- 1.0.0.0 (today): surfaces in classic Outlook Win/Mac + classic web.
- 1.1.0.0 (#143, VersionOverridesV1_0 + Read/Compose CommandSurface,
  “fa” ShowTaskpane button): adds the *Apps*-flyout button in new
  Outlook. Until it deploys, **new Outlook shows no fa entry at all** —
  the troubleshooting row says “use classic surfaces”, not “re-download
  for 1.1.0.0” (impossible today).

Screenshots: deliberately text-only (exact UI labels, verified against
Microsoft Learn by review). No Outlook instance is reachable from the
agent environment; honest screenshots can't be produced, and fakes
would be worse. Any future screenshots belong on support.html, not the
markdown.

## Lessons

- **Document the path that was actually walked.** The previous
  instructions were plausible (they matched old Microsoft docs) but
  stale. The owner's live session was the only real ground truth —
  issue bodies that narrate a live failure path are gold for docs.
- **aka.ms deep links are the stable surface.** Outlook's settings UI
  moves per host/per release (new Outlook has no add-ins section in
  Settings at all); `aka.ms/olksideload` works everywhere and survives
  UI churn.
- **Version-gate unreleased requirements.** When docs reference a
  version that a sibling PR hasn't shipped, write the rollout state
  (“today 1.0.0.0, 1.1.0.0 lands with #143”), not a bare “≥ 1.1.0.0” —
  otherwise the doc instructs users toward an impossible remedy.
- **Cross-issue docs need sibling coordination.** The Monarch section
  was written against the #143 surface BEFORE that PR existed, via a
  hub handshake (surface, version, entry points). Result: zero rework
  when #151 landed — only the version-rollout honesty edit.

## Verification checklist used

1. `dart test test/site/site_llms_guard_test.dart` — 10 passing
   (manifest URL + tool mentions preserved in llms.txt/index.html).
2. `dart test test/manifest_artifact_test.dart` (office_addin/dart) —
   3 passing (support.html non-trivial + mentions fa).
3. JSON-LD in `site/index.html` re-validated (3 blocks parse) — the
   FAQ answer text contains escaped quotes.
4. Both touched HTML files parse via python html.parser.

## Ops notes

- `site/` + `office_addin/web/` changed → **fa1.dev needs a redeploy**
  after merge (Pages).
- Sibling #143 (PR #151) will bump the manifest to 1.1.0.0; when it
  merges, the guide's “today 1.0.0.0 / until it deploys” wording should
  flip to the simple “Apps flyout” state (one commit, three spots:
  requirements, step 4, troubleshooting row).
