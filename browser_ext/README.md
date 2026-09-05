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
│   ├── cdp.js           chrome.debugger transport: trusted input + any-tab
│   │                    screenshots (per-call opt-in via args.trusted)
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
  `task_end`. `click`/`type`/`press_key`/`screenshot` accept `trusted: true`
  for the chrome.debugger path (see below); results always say which path ran
  (`path: "cdp" | "dom"`).
- Task tab groups: tabs the agent opens land in a group titled
  `fa — <session uuid>`; `task_end` (or bridge disconnect) closes exactly
  those tabs. Tabs you opened yourself are never touched.
- Smoke path: the panel composer sends real fabric mail (`sendTest`) for CI.

## Trusted input (chrome.debugger / CDP)

Pages are driven over two control planes:

- **Content script (default, quiet)** — isolated-world DOM ops; no UI change
  in the target tab. A page can in principle tell synthetic DOM events from
  real user input.
- **CDP (per-call opt-in)** — pass `trusted: true` to `click`, `type`,
  `press_key`, or `screenshot`. Events go through `chrome.debugger`
  (`Input.dispatchMouseEvent` / `Input.dispatchKeyEvent`), so Chrome itself
  synthesizes them: pages cannot distinguish them from real user input, and
  screenshots work on background tabs without activating them (AC16).

**Honesty signal:** while a debugger session is open, Chrome shows the
*"… started debugging this browser"* infobar. That banner is by design — the
user always can see when the trusted path is in use. The quiet default path
shows nothing. Attach is lazy per tab and cached; sessions are dropped on
`task_end`, when another client takes the target, or when Chrome suspends the
service worker.

**Conflict (E23):** if DevTools (or any other client) already owns the tab,
the op answers `{ ok: false, code: "denied" }` and suggests retrying without
`trusted` — the quiet content path still works there.

The embedded agent opts in per tool call (`trusted` argument), so a session
can mix both planes: quiet DOM ops by default, trusted input where fidelity
matters (e.g. pages that ignore synthetic events).

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

### Agent-to-agent messaging (DAP hub)

The embedded agent can join a [DAP/1](../docs/dap.md) hub — the same
WebSocket network local `fa` instances use — so other agents can see it
(`dap_peers`), DM it (`dap_dm` steers it mid-run), and get replies back,
with end-to-end encryption intact (ChaCha20-Poly1305 under X25519 ECDH;
the hub only ever sees ciphertext).

Configure it in the side panel → **Hub** section: paste the hub URL
(e.g. `ws://127.0.0.1:8787/ws`) and a display name, then **Save hub**.

- The Ed25519/X25519 identity is generated on first start and persisted in
  `chrome.storage.local` (`faDapKey`, CLI-compatible key-file format), so
  the agentId (`hex(sha256(pubkey))[:16]`) is stable across SW restarts.
- Status is one quiet line under the form: `hub: connected as <agentId>` /
  `hub: disconnected (retrying)`. Reconnects back off 1 s → 30 s.
- The agent gets two tools: `dap_peers` (read) lists who is online;
  `dap_dm {to, text}` (exec) sends an E2E DM to a 16-hex id or a unique
  online name.
- Inbound DMs arrive as `[from <agentId>]` mail — the same intake as
  bridge mail, deduped against it, so a peer message arriving on both the
  bridge and the hub is delivered once.
- A payload that cannot be decrypted (unknown sender key, tampered box)
  is surfaced as `[hub] undecryptable message from <from>` — never
  dropped, and never shown as plaintext.
- Channels v1 is not implemented (no channel key store in the extension);
  the client speaks hello/send/whois/presence/flush only.

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
