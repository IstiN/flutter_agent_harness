# Outlook add-in (`office_addin/`)

How to install and run [fa](../README.md) inside Outlook. The add-in is a
taskpane chat ([fa1.dev/outlook/](https://fa1.dev/outlook/)) with three
approval-gated mail tools (`outlook.read_current_item`,
`outlook.read_attachment`, `outlook.insert_draft_body`). The same guide
lives on the web at
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
- The manifest: <https://fa1.dev/outlook/manifest.xml>
  (version ≥ 1.1.0.0 — required for the ribbon button in new Outlook,
  see [issue #143](https://github.com/IstiN/flutter_agent_harness/issues/143)).

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
  same flyout sits in the compose toolbar. *(Requires manifest ≥
  1.1.0.0, which adds the ribbon surface — issue #143.)*
- **Classic Outlook for Windows:** *Home* ribbon → **fa** button.
- **Classic Outlook for Mac:** the message ribbon → **fa**.

The taskpane is the fa chat. Configure a provider and API key inside
the pane (BYOK — the key stays in the add-in's local storage), then
ask; reading a mail body or attachment always prompts for approval.

To remove: *My add-ins* → *Custom add-ins* → **⋯** on fa → *Remove*.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| “Installation failed — Add-in installation failed.” on upload | The manifest failed validation. This was a real manifest defect before v1.0.0.0 finished deployment (#131/#133 — an XML comment bug, since fixed; Microsoft's validation gateway now accepts the manifest). Re-download `manifest.xml` and retry; make sure the file wasn't saved as `.txt` or truncated. |
| No *Custom add-ins* section, or “installing from url is disabled” | Your tenant blocks custom add-ins (common in corporate tenants). An admin can deploy fa via the M365 admin center (*Settings → Integrated apps → Upload custom apps*), or install with a personal Outlook.com account instead. |
| Installed but no **fa** button anywhere in new Outlook | Manifest < 1.1.0.0 has no ribbon surface in new Outlook (#143). Re-download the manifest (check `<Version>` — need 1.1.0.0+), remove the old add-in, re-add from file. In classic Outlook the taskpane entry appears without the button. |
| Old version keeps running after an update | Outlook caches add-ins for up to 24 h (classic Windows). Remove the add-in, re-add from the new manifest, restart Outlook; worst case wait out the cache. |
| “host API unavailable” banner in the taskpane | The Office.js runtime didn't load. Reload the taskpane; if it persists, the pane still works as a plain chat without the mail tools. |
| Taskpane blank | Your network must reach `fa1.dev` and the Office.js CDN (`appsforoffice.microsoft.com`). Check proxies/corporate filters. |
