# ChatGPT Codex WebSocket adapter — implementation plan

> **Status:** PLANNING. Codex provider is hidden from pickers until this
> lands (`ProviderSpec.visible: false` in
> `lib/src/model_roles/provider_catalog.dart`).
>
> **Why this exists:** Codex's Responses API is WebSocket-only — plain
> HTTP POST returns `404`, and users read that as a broken provider. The
> OAuth flow (`ChatGptOAuthCredentials` + PKCE against
> `https://auth.openai.com`) works fine; the *transport* for the model
> requests is what's missing.

---

## 1. Problem statement

When a user picks the ChatGPT Codex provider today and sends a chat
message, the app hits `https://chatgpt.com/backend-api/codex/responses`
with a plain HTTP POST and gets back `404`. The Codex backend rejects
HTTP transport for the Responses API — it expects a WebSocket handshake
carrying Codex-specific headers and a Codex-shaped streaming protocol.

The original `codex-rs` CLI does this correctly. Reading it (see
§3 below) is the source of truth for what we need to implement.

---

## 2. Current state

| Layer | What exists | What's missing |
|---|---|---|
| OAuth | `lib/src/providers/chatgpt_oauth.dart` — PKCE + token exchange + refresh + accountId from the id_token JWT. | Nothing. This works. |
| Streaming (HTTP) | `lib/src/providers/chatgpt_codex.dart` — plain `http.post` + SSE parse + tool call handling. | Rejected by the Codex backend (404). Kept as a fallback only if the backend ever enables HTTP. |
| Provider wiring | `lib/src/model_roles/provider_catalog.dart` registers `kind: 'chatgpt-codex'` with `api: 'responses'`. `streamChatGptCodex` is called from `providerStreamFunction`. | Hidden until the WS adapter ships (`visible: false`). |
| Pickers / OAuth button | `packages/fa_ui/lib/src/providers/unified_model_picker.dart` + `packages/fa_ui/lib/src/providers/providers_section.dart` + `packages/fa_ui/lib/src/providers/add_provider_picker.dart` — the ChatGPT preset appears with the branded ProviderMark. | Unaffected by the picker visibility change; the underlying chat stream returns an honest error when invoked. |

---

## 3. What codex-rs does (the wire shape we need to replicate)

From `codex-rs/core/src/client.rs`:

### 3.1. Connection

- **WebSocket connect** via `tokio_tungstenite::tungstenite::client_async`
  (we'll use `package:web_socket_channel` in Dart).
- `ApiWebSocketResponsesClient::new(provider, auth).connect(...)`.
- The connect goes to a WebSocket URL derived from the Codex base URL
  (`wss://chatgpt.com/backend-api/codex/responses` — replace `https:`
  with `wss:`).

### 3.2. Headers (built per connect, not per message)

From `build_websocket_headers` (client.rs:1125):

| Header | Value | Notes |
|---|---|---|
| `Authorization` | `Bearer <access_token>` | From `ChatGptOAuthCredentials.accessToken` (already in our store). |
| `ChatGPT-Account-ID` | `<account_id>` | From the id_token JWT (`chatgpt_account_id` claim, already extracted). |
| `OpenAI-Beta` | `responses_websockets=2026-02-06` | **Mandatory** — tells the backend we're a V2-WebSocket client. Without this we get 404. |
| `x-openai-internal-codex-responses-lite` | `"true"` | Codex-internal routing. |
| `originator` | `codex_cli_rs` | Already sent in the OAuth flow; the model requests need it too. |
| `x-client-request-id` | `<thread_id>` | The current thread/conversation id. |
| `x-openai-subagent` | optional | When running subagents; not needed for the main turn. |
| Session headers | `session_id`, `thread_id`, … | From the existing Codex session metadata (session_id is the OAuth-issued id, thread_id is per-conversation). |

> **Attestation** — `x-oai-attestation` — is built from device/platform
> info by `codex-rs`'s `generate_attestation_header_for` (client.rs).
> This is a Codex-specific integrity proof (HMAC over device info +
> originator). Without it the backend may still answer, but with
> degraded features. Defer this to phase 2.

### 3.3. Wire protocol (message shape)

The Codex WebSocket protocol is NOT OpenAI-compatible SSE. The backend
streams JSON messages over the socket, each tagged with a type. The
client sends a single `response.create` JSON message per turn, then
reads streaming events.

Per-turn:

1. **Client → server** (one message): `{"type": "response.create", "body": {…}}`.
   The `body` carries the same shape the HTTP adapter currently uses
   (model, stream, store: false, instructions, input, tools).
2. **Server → client** (many messages):
   - `response.created` — response id + model.
   - `response.in_progress` — currently being generated.
   - `response.output_text.delta` — text chunk (has `delta`).
   - `response.output_text.done` — text block complete.
   - `response.function_call_arguments.delta` — tool-call args chunk.
   - `response.function_call_arguments.done` — tool-call args complete.
   - `response.completed` — final response with usage.
   - `response.failed` — error (`response.error.message`).
3. **Lifecycle:** the connection is cached per turn; on errors the
   transport may reconnect. For our purposes: keep the connection
   alive for the duration of the turn, close when the turn ends.

### 3.4. What we already have

The `_SseAccumulator` in `chatgpt_codex.dart` parses exactly the same
event types — the SSE/JSON shape of the payloads matches the WebSocket
shape. So the streaming-parse logic (`_handleTextEvent`,
`_handleToolEvent`, `_handleLifecycleEvent`, `_setResponse`) carries
over untouched. Only the **transport** (HTTP → WS) and the **headers**
differ.

---

## 4. Implementation plan

### Phase 1 — WebSocket transport in `lib/src/providers/chatgpt_codex.dart`

Goal: send one `response.create` over a WebSocket, stream the events
into the same `_SseAccumulator`-shaped handlers.

Files to touch:

- `lib/src/providers/chatgpt_codex.dart` — replace the `_request()`
  HTTP POST with a WebSocket adapter.
- Add `web_socket_channel` to `pubspec.yaml`.

Steps:

1. Add `package:web_socket_channel` to `lib/pubspec.yaml` (or the
   harness package's pubspec if it lives in `packages/`).
2. In `_ChatGptCodexSession.run()`:
   - Resolve the WS URL: `Uri.parse(model.baseUrl).replace(scheme: 'wss',
     path: '/responses')`.
   - Open the socket with the headers from §3.2.
   - Serialize the request body (same `_requestBody()` we use for
     HTTP) as a JSON `response.create` message and send it.
   - Listen on the socket's `Stream` for messages, parse each as a
     Codex event, and forward to the existing `_dispatchEvent`.
3. Map errors:
   - Connection refused / TLS error → `ProviderHttpError(503, …)`.
   - `response.failed` payload → existing `_handleFailed` (works
     unchanged — it already throws with the server's error message).
4. Close the socket on `response.completed` or `response.failed`.

### Phase 2 — Attestation header

The Codex backend's `x-oai-attestation` header is an HMAC over
device/platform info (see codex-rs's `generate_attestation_header_for`).
We don't have to replicate it exactly — it's used for device-fingerprint
integrity checks. Phase 2 can land it via a host-side callback (the
CLI's `default_headers()` already produces the attestation).

Until then the backend may return `403` for some accounts — that's an
acceptable phase-1 behaviour (the error surfaces to the user with a
clear "Codex access requires the official CLI attestation" message).

### Phase 3 — Token refresh + reconnect

WebSocket connections can drop mid-turn. Add:

- Idle timeout (no message for 30s → reconnect + re-send).
- On reconnect, if the current turn had in-flight text/tool events,
  resume from the last received event id (the Codex protocol supports
  this via `response_id`).

This phase is optional for the MVP — an error on a dropped connection
is acceptable (the user just retries).

### Phase 4 — Picker / Settings re-enable

Once phases 1-3 land:

- `ProviderSpec.visible: true` on `chatgpt` (re-enable).
- Remove the `404 → honest error` branch in `chatgpt_codex.dart`
  (it becomes dead code).

---

## 5. Where the code lives

The Codex adapter belongs in `lib/src/providers/chatgpt_codex.dart`
(the existing file), NOT in `packages/fa_llm`. Rationale:

- `fa_llm` is for *generic* LLM-provider abstractions (`LlmProvider`
  interface) shared across the app (OpenAI-compatible, DIAL, MiniMax,
  CodeMie, …). Codex is a **Codex-specific** transport — the WebSocket
  handshake + headers are non-standard and not reusable across other
  providers.
- `lib/src/providers/` is the harness's provider-adapter layer; the
  existing `streamChatGptCodex` signature already lives there.
- The Flutter-side picker/settings code just reads from `providerCatalog`
  and calls `providerStreamFunction` — it doesn't need to know which
  transport is underneath.

---

## 6. What stays out of scope

- **App-server / TUI WebSocket transport** (codex-rs's own app-server
  is a separate JSON-RPC over WebSocket; we're not porting that).
- **Codex "realtime" voice/audio** (Codex's realtime WebSocket is a
  separate protocol for voice-mode; not part of this adapter).
- **Streaming video** — not part of the Responses API.

---

## 7. Test plan

- `test/providers/chatgpt_codex_test.dart` — keep all existing tests
  (they cover the streaming parse; they're transport-agnostic).
- New: a fake WebSocket server in `test/` that mimics the Codex event
  stream (using `package:web_socket_channel`'s `WebSocketChannel`).
  Assert the adapter opens a socket, sends `response.create`, parses
  `output_text.delta` events into `TextDeltaEvent`, etc.
- Integration: a Codex account that works with codex-rs should work
  with our adapter too (smoke test against `wss://chatgpt.com/...`).

---

## 8. Reference pointers

- `codex-rs/core/src/client.rs` — the WebSocket session lifecycle
  (`connect_websocket`, `build_websocket_headers`,
  `force_http_fallback`).
- `codex-rs/login/src/server.rs` — the OAuth flow (PKCE + localhost
  callback) that feeds the `ChatGptOAuthCredentials`.
- `codex-rs/models-manager/models.json` — the bundled model catalog
  (our `lib/src/providers/chatgpt_codex_models_data.dart` mirrors it;
  refresh via `dart run scripts/sync_codex_models.dart`).
- Our existing implementation: `lib/src/providers/chatgpt_codex.dart`
  (SSE parsing lives here, transport is what changes).
