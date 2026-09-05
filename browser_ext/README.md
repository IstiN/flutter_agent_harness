# browser-fa — fa browser agent extension

Chrome MV3 extension pairing the [fa](../) agent with your browser over a
loopback WebSocket. Plain JavaScript classic scripts — no npm. The embedded
agent core is Dart, compiled with dart2js by `scripts/build_browser_ext.sh`.

## Layout

```
browser_ext/
├── manifest.json        MV3 manifest (permissions: storage, tabs, scripting,
│                        sidePanel, alarms, debugger, tabGroups)
├── sw/
│   ├── main.js          SW entry: pairing storage, wiring, panel API,
│   │                    embedded-agent boot (classic script, importScripts)
│   ├── bridge.js        WebSocket transport (wire protocol v1)
│   ├── ops.js           browserReq dispatcher (navigate/click/type/…)
│   ├── tabs.js          `fa — <task>` tab-group tracking + cleanup
│   ├── cdp.js           chrome.debugger stub (later phase)
│   └── agent.js         dart2js output of dart/agent_main.dart (build
│                        artifact, never committed; absent → agent disabled)
├── dart/                Dart package (path dep on the repo) compiled into
│                        sw/agent.js: ExecutionEnv on chrome.storage, agent
│                        host (tools/approvals/session), provider streams
├── content/content.js   isolated-world DOM ops
└── panel/               side panel UI (pairing, status, chat, approvals,
                         provider form, event log, composer)
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

## Self-contained mode (embedded agent)

The extension runs the fa agent core INSIDE the service worker — no CLI, no
bridge needed. `scripts/build_browser_ext.sh` compiles `dart/agent_main.dart`
with dart2js into `sw/agent.js`; `sw/main.js` feature-detects
`globalThis.faAgent` after `importScripts` and boots it with stored config
(a checkout without `sw/agent.js` stays fully functional as a bridge-only
scaffold).

### Configure a provider

Open the side panel → **Provider** section → set Base URL, API key and
Model → **Save provider**. Any OpenAI-compatible chat-completions endpoint
works (e.g. `https://openrouter.ai/api/v1` + an openrouter model id). The
config (including the key) is written to `chrome.storage.local`
(`faProvider`) and is read ONLY inside the service worker.

Model ids starting with `fake:` select a deterministic scripted provider —
no network. It echoes the prompt, and a prompt containing
`navigate <url>` makes it emit one `browser_navigate` tool call, which makes
the whole agent loop (stream → approval → tool → result) observable without
an LLM. CI drives `faAgent.selfTest()`: one scripted fake turn against the
real op table, asserting the tool result lands in the transcript.

### Approval mode

The Provider form also sets the approval mode (`ask`, `write`, `yolo`,
`unattended`). In `ask`/`write` mode, exec/write-tier tool calls render an
approval banner in the panel with **Allow/Deny**; no answer within 30 s
denies the call and the model sees the refusal.

### Sessions

The transcript persists as JSONL (`/session.jsonl`) inside a versioned
snapshot of the agent's whole in-memory filesystem in `chrome.storage.local`
(`faFs`, debounced ~800 ms, flushed after every run). When the service
worker is reaped and later re-woken, the session resumes where it left off,
and context compaction stays active.

## Security notes

- The bridge is **loopback only**; the server refuses non-127.0.0.1 binds.
- Pairing tokens are one-time and single-use; they live in
  `chrome.storage.local` (extension-private) and never enter any page world.
- The embedded agent's provider API key lives in `chrome.storage.local` and
  is read ONLY by the Dart agent inside the service worker; it never reaches
  content scripts, pages, or the panel.
- Content scripts run in the **isolated world**; pages cannot reach the
  WebSocket, the token, or bridge state. `eval` op also runs isolated, so a
  page's CSP may block it (`csp` error) by design.
- Restricted targets (chrome://, Web Store, extension pages, PDF viewer) are
  refused before any interaction (`restricted_page`).
- There is no shell in self-contained mode; the agent's `exec` always answers
  `shellUnavailable`, and the `browser_*` tools are the action surface.
