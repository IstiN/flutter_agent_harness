# fa — Office add-in (Outlook)

fa as an Outlook taskpane: the Dart agent core (`dart/` → `dart compile js` →
`web/office_agent.js`) runs inside the Outlook host, with mail tools
(`outlook.*`) on top. Classic v1 MailApp manifest — no VersionOverrides, no
mobile form factor — for the broadest host coverage (Mailbox 1.8+).

## Layout

- `manifest/outlook.xml` — classic Outlook add-in manifest. Prod URLs point
  at `https://fa1.dev/outlook/…`; the build's `--dev` variant rewrites them
  to `https://localhost:8443`.
- `dart/` — `fa_office_agent` package. `src/manifest.dart` is a pure-Dart
  manifest validator (https + host + `/outlook/` path shape, permission
  ladder exactly `ReadWriteItem` ⇒ `{ReadItem, ReadWriteItem}`, one
  Mailbox host, no MobileFormFactor); `tool/validate_manifest.dart` is its
  CLI (`dart run tool/validate_manifest.dart ../manifest/outlook.xml [--dev]`).
- `web/` — taskpane page (`index.html`), privacy and support pages. The
  page boots Office.js from the Microsoft CDN; if the host API never
  becomes available it shows a banner and the agent answers without mail
  tools. The page IS the chat surface: a composer (Send button or Enter)
  drives `faOfficeAgent.sendUser`, streamed replies render in the
  transcript, `approval_request` events become Approve/Deny cards wired
  to `faOfficeAgent.decide`, and the raw event log stays below for
  sideload debugging. The full fa app loads in `app/index.html` only when
  the build bundled it (`--with-app`).
- `icons/` — taskpane icons (`fa-64.png`, `fa-128.png`).

## Install (sideload)

Manifest URL: `https://fa1.dev/outlook/manifest.xml`

- **Outlook on the web**: Settings → Integrate apps → Upload custom apps →
  “Add from a URL”, paste the manifest URL.
- **Windows / Mac (classic Outlook)**: follow Microsoft's sideload guide
  with the same manifest URL.

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
