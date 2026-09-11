# fa — Office add-in (Outlook)

fa as an Outlook taskpane: the Dart agent core (`dart/` → `dart compile js` →
`web/office_agent.js`) runs inside the Outlook host, with mail tools
(`outlook.*`) on top. Classic v1 MailApp manifest plus a
`VersionOverrides` command surface (Mailbox 1.8+, no mobile form factor):
an «fa» button on the message Apps flyout / compose ribbon opens the
taskpane — new Outlook for Windows (Monarch) and modern OWA render
command-based add-ins only (issue #143), legacy hosts fall back to the
classic pane.

## Layout

- `manifest/outlook.xml` — Outlook add-in manifest: classic FormSettings
  for legacy hosts plus `VersionOverridesV1_0` command surfaces
  (MessageRead + MessageCompose) for Monarch/new OWA. Prod URLs point
  at `https://fa1.dev/outlook/…`; the build's `--dev` variant rewrites
  them to `https://localhost:8443`.
- `dart/` — `fa_office_agent` package. `src/manifest.dart` is a pure-Dart
  manifest validator (https + host + `/outlook/` path shape, permission
  ladder exactly `ReadWriteItem` ⇒ `{ReadItem, ReadWriteItem}`, one
  Mailbox host, no MobileFormFactor, clean XML comments, ItemEdit
  SourceLocation-only, and the command surface: MessageReadCommandSurface
  + ShowTaskpane, 16/32/80 px button icons, MailHost type, resolvable
  resids); `tool/validate_manifest.dart` is its CLI
  (`dart run tool/validate_manifest.dart ../manifest/outlook.xml [--dev]`).
- `web/` — taskpane page (`index.html`), privacy and support pages. The
  page boots Office.js from the Microsoft CDN; if the host API never
  becomes available it shows a banner and the agent answers without mail
  tools. The page IS the chat surface: a composer (Send button or Enter)
  drives `faOfficeAgent.sendUser`, streamed replies render in the
  transcript, `approval_request` events become Approve/Deny cards wired
  to `faOfficeAgent.decide`, and the raw event log stays below for
  sideload debugging. The full fa app loads in `app/index.html` only when
  the build bundled it (`--with-app`).
- `icons/` — taskpane icons (`fa-16/32/80.png` for the command buttons,
  `fa-64.png`, `fa-128.png` for the store/list surfaces).

## Install (sideload)

Full step-by-step guide (requirements, exact UI path, troubleshooting):
[docs/outlook-addin.md](../docs/outlook-addin.md), mirrored live at
https://fa1.dev/outlook/support.html.

Short version — Microsoft removed "Add from a URL" from the manual
surface, so download and add from file:

1. Save https://fa1.dev/outlook/manifest.xml as `manifest.xml`.
2. Open https://aka.ms/olksideload (My add-ins) — works from the web,
   new Outlook, and classic Outlook.
3. My add-ins → Custom add-ins → "+ Add a custom add-in" →
   Add from file → `manifest.xml` → Install.

## Where the add-in shows up

After install the entry point depends on the client (manifest ≥ 1.1.0.0):

- **New Outlook for Windows (Monarch) / OWA**: open a message, click
  **Apps** (…) in the reading surface — the «fa» button opens the
  taskpane. In compose: «fa» sits in the message toolbar.
- **Classic Outlook (Win/Mac)**: «fa» group on the Home ribbon; legacy
  hosts that ignore command surfaces still auto-open the classic pane
  when a message is selected.

Sideloaded installs re-add the manifest after a version bump; store and
centralized deployments re-fetch automatically.

## Dev loop

```sh
bash scripts/build_office_addin.sh --dev   # validates + compiles + assembles build/pages/root/outlook/ (dev URLs)
# serve office_addin/web (or the assembled dir) on https://localhost:8443,
# then sideload build/pages/root/outlook/manifest.xml
bash scripts/build_office_addin.sh --with-app --dev  # bundle the full fa web app too
```

## What is tested automatically

- `dart/test/` — validator unit tests (synthetic corruptions) + committed
  artifact checks (manifest, page markers), plus the host-bridge suite.
- `test/` — Node vm sandbox: mocked `Office` global over the compiled
  `office_agent.js`.
- `e2e/` — Playwright chromium + webkit driving the built page.
- CI: `.github/workflows/office-addin.yml` runs all of the above and
  uploads `build/pages/root/outlook/` as the `office-addin` artifact.

## Manual real-host checklist

Mocks cannot prove these; verify by hand before a release:

1. **Real Office.js boot** inside Outlook (WebView2 / WKWebView / OWA
   iframe): the sandboxed mock proves the Dart contract, not Microsoft's
   runtime (mailbox readiness, item context, permission prompts).
2. **Real sideload + trust prompt**: store/admin policy surfaces
   (publisher trust, "unverified add-in" flows) only exist in a real host.
3. **Renderer sanity on the oldest supported WebView2**: the canvaskit
   WASM path in the bundled app must render there, not just in current
   Chrome.
