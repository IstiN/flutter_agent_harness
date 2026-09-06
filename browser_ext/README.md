# fa — browser agent extension

The extension hosts THE fa web experience: the same Flutter web app users
know from the main page runs in the side panel (and as a full tab from the
toolbar), and on top of it the agent gets the full Chrome extension API
surface as tools — tabs, windows, history, bookmarks, downloads, cookies,
and first-class JavaScript injection into pages. One sentence: fa-for-web
moves into the extension and grows browser superpowers. The embedded agent
core is Dart, compiled with dart2js by `scripts/build_browser_ext.sh`;
plain JavaScript classic scripts around it — no npm.

## Two panel modes

`panel/panel.html` is an app-hosting bootstrap:

- **App panel** — when `browser_ext/app/` exists (built by
  `scripts/build_browser_ext.sh --with-app`), the panel loads the real fa
  web app from local extension assets (MV3 CSP-compliant, no remote code).
- **Legacy fallback chat** — without `app/`, the v1 minimal chat UI
  (pairing, provider form, approvals, event log) is shown instead. It
  stays as fallback only.

Status note: the app-hosting panel currently runs the app's own local
agent path when hosted; the service-worker protocol server is ready for
it, the app-side worker-relay chat integration is still pending (see
[docs/browser-extension.md](../docs/browser-extension.md) → Status).

## Build & load (unpacked)

1. Build the zip:

   ```bash
   bash scripts/build_browser_ext.sh             # agent only
   bash scripts/build_browser_ext.sh --with-app  # + the real app UI in the panel
   ```

   The script compiles the Dart agent (when a Dart SDK is on PATH) and
   zips the runtime files into `build/fa-extension.zip`. `--with-app`
   first runs `flutter build web --release` and bundles the result as
   `browser_ext/app/` (a build artifact, never committed).

2. Open `chrome://extensions`, enable **Developer mode**.
3. **Load unpacked** → select this `browser_ext/` directory — or drag in /
   load `build/fa-extension.zip`.

Minimum Chrome 116. Manifest: 26 core permissions, the 9 second-tier
APIs in `optional_permissions` (registered-hidden behind a Settings
gate), and `<all_urls>` in `optional_host_permissions` for store
builds — per-permission justifications:
[docs/browser-extension-permissions.md](../docs/browser-extension-permissions.md).

## Where keys live

The provider API key and all agent config live in
`chrome.storage.local` **inside the service worker** and are read only
there — never in content scripts, never in page worlds, never in the
panel. In extension mode the UI process holds no keys and makes no
provider fetches; everything flows over an extension-internal
`chrome.runtime` port.

## What the agent can do — 34 tools

| Family | Tools | Tiers |
|---|---|---|
| Tabs (9) | `tabs_open` `tabs_close` `tabs_update` `tabs_query` `tabs_move` `tabs_group` `tabs_ungroup` `tabs_reload` `tabs_discard` | query = read; rest = write |
| Windows (4) | `windows_open` `windows_update` `windows_close` `windows_list` | list = read; rest = write |
| Groups (2) | `groups_update` `groups_close` | write |
| Sessions (2) | `sessions_recent` `sessions_restore` | read / write |
| History (1) | `history_search` | read |
| Bookmarks (4) | `bookmarks_list` `bookmarks_add` `bookmarks_update` `bookmarks_remove` | list = read; rest = write |
| Downloads (3) | `downloads_start` `downloads_search` `downloads_cancel` | search = read; rest = write |
| Cookies (3) | `cookies_get` `cookies_set` `cookies_remove` | get = read; rest = write |
| Injection & CDP (4) | `inject_js` `inject_css` `cdp_eval` `page_screenshot` | inject_js = exec and **always prompts** (MAIN world); inject_css = write; cdp_eval / page_screenshot = exec |
| App & navigation (2) | `app_screenshot` `nav_wait` | read |

Restricted pages (chrome://, Chrome Web Store, extension pages, PDF
viewer) are never scripted or injected; tab management (open/close/move)
still works there so the agent can clean up.

## Entry points

Every external trigger lands in the same service-worker agent:

- **Hotkey** `Ctrl+Shift+1` (command `ask-fa`) — ask fa about the current
  page.
- **Omnibox** — type `fa <query>` in the address bar.
- **Right-click menu** — selection, link, image, or page → ask fa.

While a run is active an entry steers the live run; otherwise it queues.
Page data attached by these entries is marked untrusted and is never
executed.

## Background residency

The agent lives in the browser, not in the panel:

- **Badge** — the toolbar badge shows `idle` / `busy` / `mail!`
  (priority: mail > busy > idle). After a forced service-worker kill the
  badge is re-synced from authoritative state, never replayed; a denied
  notification permission degrades to badge-only signaling.
- **Scheduled tasks** — "check this hourly"-style prompts register as
  `chrome.alarms`. The task list and a fire ledger live in
  `chrome.storage.local`, so a restart never misses or doubles a run
  (exactly-once delivery). Results arrive as notifications + panel mail.
- **Offscreen documents** — background DOM extraction with no visible
  tab, under MV3 lifetime caps; long extractions chunk or degrade
  cleanly.
- **Panel closed ≠ agent stopped** — long research runs continue in the
  service worker; the badge and notifications carry the state.

## Security model (summary)

- **Page text is always data.** Page content — DOM, bookmark titles,
  history entries, download filenames, alt text — enters a quarantine
  layer that classifies instruction-shaped spans: a fake `SYSTEM:` frame
  or "ignore previous instructions" inside a page can REQUEST an action,
  never GRANT one. Only real user input grants authority.
- **Credential firewall.** There is no password-dump API in Chrome — the
  permission matrix records that row as impossible by construction.
  (`[REDACTED:credential]`) before anything is persisted, and
  keystroke-capture code is refused everywhere. (The `login_form`
  credential-page refusal exists but is inert with the shipped
  URL-only classifier — v2.1 needs a host-supplied DOM-probing
  `PageClassifier` to arm it.)
- **Exfiltration gate.** Actions that move data out of the browser
  (cross-origin fetch, clipboard, download, window open, mail) need
  approval when the payload is page-derived or the origin was never
  visited.
- **Restricted pages** (chrome://, Web Store, extension pages, PDF
  viewer) refuse scripting/CDP with a clean structured error.
- **Keys** stay in `chrome.storage.local` in the service worker (above).

Full details: [docs/browser-extension.md](../docs/browser-extension.md).

## Store review

Unpacked and enterprise installs are the first-class distribution path
(store review risks around `debugger`/cookies/broad host permissions are
documented, not wished away). A store-profile build strips `debugger` +
`cookies` and the second tier of optional tools; the SW degrades
cleanly without them. Per-permission justifications for a reviewer:
[docs/browser-extension-permissions.md](../docs/browser-extension-permissions.md).

## Advanced: desktop bridge (optional)

The v1 loopback WebSocket bridge (`/browser connect` in the fa CLI,
one-time pairing tokens) and the DAP/1 agent-to-agent hub remain
available as an advanced/optional path — the panel's legacy chat hosts
the pairing form. Tokens stay loopback-only and single-use. The full
walkthrough, CDP trusted-input details, and task tab groups live in
[docs/browser-extension.md](../docs/browser-extension.md) → Advanced.
