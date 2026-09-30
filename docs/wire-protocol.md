# Agent Wire Protocol v1 — host contract

The fa engine boundary is a frozen, versioned JSON protocol: **events out**,
**commands in**. This page is the contract a host implements. The canonical
mapping lives in `lib/src/wire/wire_protocol.dart` ([AgentWireProtocol]);
the in-process Dart adapter is `lib/src/wire/wire_adapter.dart`. Golden
fixtures pin every frame: `test/wire/fixtures/v1/` — a schema change without
fixtures fails CI, and reference clients parse old-version fixtures both ways.

## 1. Framing (NDJSON)

One JSON object per message, one message per line, UTF-8, `\n`-terminated —
**NDJSON, not JSONP**. Never batch objects onto one line; never split one
object across lines. Blank lines are skipped by parsers. Any byte-level
transport (stdio, socket, platform channel) may carry the lines; the
protocol itself is transport-free.

## 2. Frames and versioning

Every frame is `{"v": <version>, "kind": "<name>", ...payload}`. Version
**1** is the only live version. Rules:

- **Additive-only within a major**: new kinds and new optional payload
  fields are allowed; changing or removing anything bumps `v`.
- **Unknown fields are ignored** on decode; canonical re-encodes drop them.
- **Unknown kinds degrade to passthrough**: an event kind the host does not
  know arrives as `{"v":1,"kind":"unknown_event","originalKind":...,
  "payload":{...}}` — render nothing, keep the run alive (E3). Unknown
  command kinds surface as `unknown` commands the engine may reject loudly.
- **Handshake**: the client sends
  `{"v":1,"kind":"hello","versions":[1],"caps":[...]}`; the server answers
  `{"v":1,"kind":"welcome","version":<negotiated>,"caps":[...]}` with the
  highest mutually supported version. **No overlap is a loud handshake
  error** — the connection must not limp on a guessed version. The
  hello frame's own `v` caps only that frame's encoding: it is accepted
  (unknown fields tolerated) and IGNORED for negotiation — the `versions`
  array is what negotiates. A multi-version client talking to a v1 server
  is DOWNGRADED: every subsequent frame is encoded at the negotiated
  version, and fields added after that version are filtered out (E5).
- Every schema change ships golden fixtures for **all live versions**, and
  the fixture `kind`/`protocolVersion`/`frame` keys are load-validated —
  a half-written fixture is a CI failure, not a silent pin.

## 3. Events (engine → host)

Native kinds (`AgentEvent` stream, partial-first — every `message_update`
carries the live `message` snapshot):

| kind | payload |
|---|---|
| `agent_start` / `turn_start` / `agent_settled` | — |
| `agent_end` | `messages`: every message produced by the run |
| `turn_end` | `message` (assistant), `toolResults` |
| `message_start` / `message_end` | `message` (user / assistant / toolResult) |
| `message_update` | `message` (partial) + `event` (nested provider delta: `text_delta`, `thinking_delta`, `tool_call_delta`, `tool_call_end`, `done`, `error`, …) |
| `tool_execution_start` | `toolCallId`, `toolName`, `args`, `timestamp` |
| `tool_execution_update` | + `partialResult` |
| `tool_execution_end` | + `result`, `isError` |
| `model_request` | `detail` (sizes/previews), optional `promptBlob` / `manifestBlob`, optional `rawWireDump` (**SECRET**, see §5) |
| `tool_pairing_repair` | `report` (`droppedResultIds`, `synthesizedResultIds`, `renamedIds`), optional `providerError` |

Host-interaction request kinds (in-process these are the
`ApprovalPrompt` / `AskCallback` / `RequestSecretCallback`; over the wire
they are frames the host answers with commands, echoing `id`):

- `approval_request {id, toolName, tier, arguments, reason}` →
  `approval_response {id, decision: approve_once|approve_always|deny}`
- `ask_request {id, questions:[{question, options:[{label, description?}],
  multiSelect, recommended?}]}` →
  `ask_response {id, answers:[{selected?, freeText?}]}` or
  `{id, cancelled: true}`
- `secret_request {id, name, reason}` →
  `secret_response {id, granted: true, name, value, persisted}` or
  `{id, granted: false}`

## 4. Commands (host → engine)

- `prompt {text}` — start a run.
- `steer {text}` — inject a mid-run steering message.
- `abort` — cancel the active run.
- `approval_response` / `ask_response` / `secret_response` — see §3.
- `session_control {op, params?}` — session-level ops; the frame shape is
  pinned, the `op` registry grows additively.

## 5. Secrets (E4)

SECRET-class frame fields are registered in
`AgentWireProtocol.isSecretField` — today: `secret_response.value`,
`model_request.rawWireDump`, and `rawBody` (anywhere in a frame — it only
ever carries the raw provider 429 payload, `RateLimitInfo.rawBody`).
**Hosts MUST pass frames through `AgentWireProtocol.redactForLog` before
logging or persisting them.** Redacted fields carry the repo-standard
`[REDACTED:<kind>]` marker (kind = frame kind), which the layered
redaction pipeline recognizes and keys on. Additionally,
`rateLimit.rawBody` never
rides a wire frame at all: the engine strips it when embedding messages
(the live in-process object keeps the diagnostics payload). Secret values
never enter the session JSONL, the trajectory, or logs; the redaction
pipeline precedent applies.

## 6. What a host renders (host obligations)

1. Render the semantic event kinds: streamed text/thinking deltas
   (partial-first: render `message_update.message` directly), tool
   lifecycle, `approval_request` / `ask_request` / `secret_request` as
   interactive prompts answered via the response commands.
2. Supply platform capabilities where the engine is embedded (the
   ExecutionEnv seam) and obey the capability profile (#1079).
3. Handle `unknown_event` gracefully (render nothing, keep the run alive).
4. Negotiate the handshake before the first event frame; treat a handshake
   version error as fatal.

## 7. Transports

One schema, embedded-first: the in-process Dart adapter
(`toWire()`/`fromWire()`) is the default when the host IS Dart/Flutter.
Native hosts embed the fa engine in-app (zero WebView, zero remote — owner
ruling 2026-09-30). The DAP hub is out of scope and frozen; `fa wire-serve`
is a separate card (#1103). Reference clients per platform land in `sdk/`
(slices 2–3 of #1101).
