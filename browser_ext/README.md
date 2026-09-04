# browser-fa — fa browser agent extension

Chrome MV3 extension pairing the [fa](../) agent with your browser over a
loopback WebSocket. Plain JavaScript ES modules — no build step, no npm.

## Layout

```
browser_ext/
├── manifest.json        MV3 manifest (permissions: storage, tabs, scripting,
│                        sidePanel, alarms, debugger, tabGroups)
├── sw/
│   ├── main.js          SW entry: pairing storage, wiring, panel API
│   ├── bridge.js        WebSocket transport (wire protocol v1)
│   ├── ops.js           browserReq dispatcher (navigate/click/type/…)
│   ├── tabs.js          `fa — <task>` tab-group tracking + cleanup
│   └── cdp.js           chrome.debugger stub (later phase)
├── content/content.js   isolated-world DOM ops
└── panel/               side panel UI (pairing, status, event log, composer)
```

## Load unpacked

1. Open `chrome://extensions`, enable **Developer mode**.
2. **Load unpacked** → select this `browser_ext/` directory.
3. Open the side panel (extension puzzle-piece icon → *fa — browser agent*).

## Pairing walkthrough

1. In the fa CLI run `/browser connect` — it starts `fa serve --bridge`
   (loopback only) and mints a **one-time** 32-byte hex token.
2. In the side panel paste the bridge URL (`ws://127.0.0.1:<port>`) and the
   token, press **Connect**.
3. The service worker sends `hello {agentId, proto:1, token, caps}`; on
   `welcome` the panel dot turns teal and the agent can drive the browser.
4. Tokens are single-use: a stale token yields
   `disconnected — bad token — run /browser connect again`. Re-run
   `/browser connect` for a fresh one, then **Connect** again.

## What works in v1

- Full wire-protocol v1 client: hello/welcome, reconnect backoff (1s → 30s),
  offline outbox (100 frames, drained oldest-first after welcome), msgId
  dedupe (LRU 512), 20 s ping keepalive via `chrome.alarms`.
- All `browserReq` ops: `navigate`, `tabs`, `switch_tab`, `click`, `type`,
  `press_key`, `select`, `read_dom`, `eval`, `screenshot`, `wait_for`,
  `task_end`.
- Task tab groups: tabs the agent opens land in a group titled
  `fa — <session uuid>`; `task_end` (or bridge disconnect) closes exactly
  those tabs. Tabs you opened yourself are never touched.
- Smoke path: the panel composer sends real fabric mail (`sendTest`) for CI.

## Security notes

- The bridge is **loopback only**; the server refuses non-127.0.0.1 binds.
- Pairing tokens are one-time and single-use; they live in
  `chrome.storage.local` (extension-private) and never enter any page world.
- Content scripts run in the **isolated world**; pages cannot reach the
  WebSocket, the token, or bridge state. `eval` op also runs isolated, so a
  page's CSP may block it (`csp` error) by design.
- Restricted targets (chrome://, Web Store, extension pages, PDF viewer) are
  refused before any interaction (`restricted_page`).
