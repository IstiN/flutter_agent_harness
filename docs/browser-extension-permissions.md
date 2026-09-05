# Browser extension — permissions

Per-permission justifications for Chrome Web Store review (and for
anyone auditing `browser_ext/manifest.json`). One row per permission;
the same facts live in `browser_ext/dart/src/permission_matrix.dart`
(the single source of truth the manifest and tool registry derive from
— a drift surfaces as a `MatrixViolation`, enforced by
`browser_ext/dart/test/permission_matrix_test.dart`).

The extension runs the fa agent locally; it has no telemetry and no
server of its own. Every agent action rides the approval gate
(`ask`/`write` modes prompt; `inject_js` in the page's MAIN world always
prompts), and pages the agent reads pass a redaction + quarantine
layer before anything is persisted. See
[docs/browser-extension.md](browser-extension.md) → Security model.

## Core permissions (26, in `permissions`)

| Permission | Used by | Justification (for a reviewer) |
|---|---|---|
| `alarms` | Scheduled tasks (`AlarmScheduler`) | The agent runs user-scheduled prompts (e.g. "check this page hourly") while the browser is open; alarms let due work fire and survive service-worker restarts. |
| `bookmarks` | `bookmarks_list` / `bookmarks_add` / `bookmarks_update` / `bookmarks_remove` | The agent lists, organizes, and edits the user's bookmarks on request. |
| `commands` | `ask-fa` hotkey (Ctrl+Shift+1) | Registers the keyboard shortcut that asks fa about the current page. |
| `contextMenus` | Right-click menu entries | Adds "ask fa" entries for the selected text, link, image, or page the user right-clicked. |
| `cookies` | `cookies_get` / `cookies_set` / `cookies_remove` | The agent reads/edits cookies for a site when the user asks (e.g. debugging a login issue); every cookie tool result is approval-gated. Stripped from the store profile. |
| `debugger` | `cdp_eval`, `page_screenshot`, trusted input | The trusted-input plane: `chrome.debugger` lets the agent dispatch real browser-synthesized input and capture screenshots of background tabs. Chrome shows its "started debugging" infobar whenever it is in use. Stripped from the store profile. |
| `downloads` | `downloads_start` / `downloads_search` / `downloads_cancel` | The agent downloads a file the user asked for and manages (find/cancel) downloads. |
| `history` | `history_search` | The agent searches browsing history on request ("find that page I visited yesterday"). |
| `identity` | Provider OAuth flows | `launchWebAuthFlow` lets the user sign in to LLM providers via browser OAuth instead of pasting long-lived API keys. |
| `system.cpu` | Read-only CPU info | Lets the agent answer "will this machine survive this job?" from real CPU load/architecture info. |
| `idle` | Idle awareness | Detects when the user is away so the agent can defer noisy work (tab churn) or schedule it for that window. |
| `system.memory` | Read-only memory info | Read-only current memory capacity/usage so the agent can judge if a heavy job fits. |
| `system.storage` | Read-only storage info | Read-only available storage so the agent can judge download/extraction sizes. |
| `system.display` | Read-only display info | Read-only display unit info so the agent can reason about screenshots and window placement. |
| `notifications` | Run completion / attention / mail | Tells the user when a background run finishes, needs attention, or mail arrives; a denied permission degrades to badge-only signaling. |
| `offscreen` | `OffscreenManager` | Opens one lifetime-capped offscreen document so the agent can parse/extract from pages with no visible tab. |
| `omnibox` | `fa ` keyword | Lets the user type `fa <query>` in the address bar to prompt the agent. |
| `power` | Keep-awake | Keeps the machine awake during a long agent run; the lock is released when the run ends. |
| `scripting` | `inject_js` / `inject_css` | The agent injects JavaScript/CSS into a page at the user's request — the core page-editing capability; MAIN-world injections always prompt first. |
| `sessions` | `sessions_recent` / `sessions_restore` | The agent lists and reopens recently closed tabs/windows on request. |
| `sidePanel` | The app panel | Hosts the extension's UI — the fa app — in Chrome's side panel. |
| `storage` | All agent state | `chrome.storage.local` holds the agent's provider config (including the API key), sessions, and scheduled tasks; it is read only inside the extension's service worker, never by pages. |
| `tabGroups` | `tabs_group` / `tabs_ungroup` / `groups_update` / `groups_close` | The agent organizes the tabs it opens into named groups and cleans them up when the task ends. |
| `tabs` | `tabs_open` / `tabs_close` / `tabs_update` / `tabs_query` / `tabs_move` / `tabs_reload` / `tabs_discard`, `app_screenshot` | The agent opens, organizes, reloads, and closes tabs on request — the agent's primary workspace. |
| `webNavigation` | `nav_wait` | The agent waits for a page to finish loading before acting on it. |
| `windows` | `windows_open` / `windows_update` / `windows_close` / `windows_list` | The agent arranges, focuses, resizes, and closes browser windows on request. |

## Host permissions

| Permission | Profile | Justification |
|---|---|---|
| `<all_urls>` (in `host_permissions`) | unpacked (core) | The agent acts on whichever page the user points it at — page identity is chosen per prompt, not at install time. All script injections are approval-gated. |
| `<all_urls>` (in `optional_host_permissions`) | store | Store builds can drop broad host access; the user grants sites on demand. |

## Second tier (9, in `optional_permissions`)

Implemented, but not registered by default — a Settings gate turns each
on; the store manifest carries them as optional so nothing is requested
up front.

| Permission | Tool/feature | Justification |
|---|---|---|
| `declarativeNetRequest` | Network rules | Lets the agent install request-blocking/redirect rules on explicit request; powerful, so it is opt-in and approval-gated. |
| `desktopCapture` | See-what-I-see capture | Lets the agent see the user's screen region when asked ("what is wrong with this dialog?"). |
| `pageCapture` | Save page as MHTML | Lets the agent save an offline snapshot of a page on request. |
| `readingList` | Reading list | The agent adds/fetches the user's reading-list entries on request. |
| `search` | Trigger browser search | Lets the agent run a browser search the user asked for. |
| `tabCapture` | Tab capture | Lets the agent capture the visible tab for "look at this" workflows. |
| `topSites` | Top sites | Read-only list of most-visited sites, used as context when the user asks about "my usual sites". |
| `tts` | Speak answers | Reads an answer aloud when the user asks for it. |
| `userScripts` | User-script registration | Lets the agent register persistent user scripts on explicit request; opt-in and approval-gated. |

## Excluded (no manifest permission, no tool)

Recorded in the matrix so the absence is auditable, not accidental:

| API | Why excluded |
|---|---|
| `browsingData` | Wipes user data — too destructive for an agent. |
| `privacy` | Mutates browser-wide privacy settings. |
| `proxy` | Browser-wide settings mutation. |
| `management` | Controls other extensions. |
| `gcm` | Push-messaging transport, not an agent surface. |
| `devtools` | Opens interactive devtools windows, not automation. |
| `fileBrowserHandler` | ChromeOS-only. |
| `printing` | ChromeOS-only. |
| `printingMetrics` | ChromeOS-only. |
| `fileSystemProvider` | ChromeOS-only. |
| `passwords` | **Impossible by construction**: chrome exposes no password API at all. There is no manifest entry, no tool, and no prompt vocabulary that can reach saved passwords — the matrix checker flags anything that tries, wherever it appears. |

## Profiles

- **unpacked** (developers, enterprise installs — the first-class
  distribution path): the full core table above.
- **store** (CWS submission): strips `debugger` and `cookies` (review
  risk) and does not request the second tier up front; the service
  worker degrades cleanly without them — those tools simply hide.
  `checkMatrix(profile: store)` enforces "may be absent, never
  present-extra".
