# Outlook add-in (`office_addin/`)

How to install and run [fa](../README.md) inside Outlook. The add-in is
the full fa agent as a taskpane chat
([fa1.dev/outlook/app/](https://fa1.dev/outlook/app/)) with
approval-gated mail tools (`outlook.read_current_item`,
`outlook.read_attachment`, `outlook.insert_draft_body`) — the same app
that runs at fa1.dev, embedded in Outlook with the mail bridge wired in.
The same guide lives on the web at
[fa1.dev/outlook/support.html](https://fa1.dev/outlook/support.html) —
the add-in's Support URL.

This page is the install guide. Architecture and the dev loop:
[office_addin/README.md](../office_addin/README.md).

## Requirements

- An Outlook account: personal (outlook.com) or work/school. Org tenants
  must allow custom add-ins — see
  [troubleshooting](#troubleshooting) if yours doesn't.
- Any of: Outlook on the web (outlook.office.com / outlook.live.com),
  new Outlook for Windows, or classic Outlook for Windows / Mac.
- The manifest: <https://fa1.dev/outlook/manifest.xml> — 1.2.0.0, the
  release where the taskpane became the full fa app (issue #182). It
  carries both the classic form settings and the VersionOverrides
  command surface from
  [issue #143](https://github.com/IstiN/flutter_agent_harness/issues/143),
  so the «fa» button shows up in new Outlook for Windows and OWA as
  well as classic clients. If you installed an older manifest
  (≤ 1.1.0.0), re-download and re-add — old taskpane URLs keep working
  for one release via a redirect, then disappear.

## 1. Download the manifest

Save <https://fa1.dev/outlook/manifest.xml> as `manifest.xml`
(right-click → *Save link as…*, or Ctrl+S / Cmd+S on the page).

Why download instead of URL: Microsoft removed the manual
“Add from a URL” entry from the add-ins dialog, so
download-then-file is the only self-service install path. URL-based
install survives only as admin-deployed catalogs.

If the browser shows the XML as text instead of downloading, save the
page source (Ctrl+S). Do not let the file become `manifest.xml.txt`.

## 2. Open the add-ins manager

The reliable entry on every surface is Microsoft's deep link:
**<https://aka.ms/olksideload>** — it opens Outlook's *My add-ins*
dialog directly. Sign in with the same account you read mail with.

Manual alternatives (same dialog, more clicks):

- **Outlook on the web / new Outlook:** open a message, then the
  *Apps* flyout in the reading-pane toolbar → *Get add-ins* (or
  *More actions* ⋯ → *Get Add-ins*). Note: new Outlook's main
  Settings page has no add-ins section — the Apps flyout on a message
  is the entry.
- **Classic Outlook (Windows/Mac):** ribbon *Home* → *Get Add-ins*
  (or *File* → *Manage Add-ins*), then the *My add-ins* tab.

## 3. Install from file

In the dialog: **My add-ins → Custom add-ins →
“+ Add a custom add-in” → Add from file** → pick the downloaded
`manifest.xml` → *Install*. Accept the trust prompt
(“This add-in is not from the App Store”) with *Install*.

The add-in now appears under *My add-ins* → *Custom add-ins* as **fa**.

## 4. Open the taskpane

Open (or select) any email message, then:

- **New Outlook for Windows / Outlook on the web:** the message's
  *Apps* flyout (toolbar or ⋯ menu) → **fa**. In a compose window the
  same flyout sits in the compose toolbar.
- **Classic Outlook for Windows:** *Home* ribbon → **fa** button.
- **Classic Outlook for Mac:** the message ribbon → **fa**.

The taskpane is the fa app. Configure a provider and API key inside
the pane (BYOK — the key stays in the pane's own partitioned storage,
separate from fa1.dev and the browser extension), then ask. It has the
full agent surface: the sandbox shell with Python and JS interpreters,
files, apps — plus the three mail tools. Reading a mail body is
pre-approved at the read tier; reading an attachment or inserting into
a draft **always** prompts for approval, in every session mode.

Note: network access from the pane is the provider endpoints you
configure, called directly over HTTPS — nothing else (issue #182's
T1-only decision).

To remove: *My add-ins* → *Custom add-ins* → **⋯** on fa → *Remove*.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| “Installation failed — Add-in installation failed.” on upload | The manifest failed validation. Re-download `manifest.xml` and retry; make sure the file wasn't saved as `.txt` or truncated. Check `<Version>` — it should read `1.2.0.0`. |
| No *Custom add-ins* section, or “installing from url is disabled” | Your tenant blocks custom add-ins (common in corporate tenants). An admin can deploy fa via the M365 admin center (*Settings → Integrated apps → Upload custom apps*), or install with a personal Outlook.com account instead. |
| Installed but no **fa** button anywhere in new Outlook | You're running the pre-[#143](https://github.com/IstiN/flutter_agent_harness/issues/143) 1.0.0.0 manifest — it has no ribbon surface in new Outlook. Re-download the manifest (check `<Version>` — 1.2.0.0), remove the old add-in (*My add-ins* → *Custom add-ins* → **⋯** → *Remove*), re-add from file. Classic Outlook works on either version; Outlook may cache the old one up to 24 h. |
| Old pane (plain chat, no app UI) after updating to 1.2.0.0 | Outlook caches add-ins for up to 24 h (classic Windows). Remove the add-in, re-add from the new manifest, restart Outlook; worst case wait out the cache. |
| Pane loads but the agent reports “office_unavailable” | The Office.js runtime didn't load (network filters can block `appsforoffice.microsoft.com`). Reload the taskpane; if it persists, the pane still works as the full fa chat without the mail tools. |
| Pane gray/blank in Outlook on the web (fixed builds load fine) | OWA's taskpane iframe strips the History API; panes built before [#202](https://github.com/IstiN/flutter_agent_harness/issues/202) crashed mid-boot on it. Re-add the current manifest — fixed panes probe the History API and boot with a no-op URL strategy. |
| Taskpane blank | Your network must reach `fa1.dev`, the Office.js CDN (`appsforoffice.microsoft.com`) and `cdn.jsdelivr.net` (interpreter/model runtimes). Check proxies/corporate filters. On very old WebView2 builds the canvaskit renderer may fail — update Edge/WebView2. |
