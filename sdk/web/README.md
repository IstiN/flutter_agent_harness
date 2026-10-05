# fah-wire-client-web — Agent Wire Protocol v1 reference client (web)

A thin, dependency-free TypeScript client for the [Agent Wire Protocol
v1](../../../docs/wire-protocol.md) (issue #1101). It mirrors the canonical
Dart contract in `lib/src/wire/wire_protocol.dart` and is conformance-pinned
against the same golden fixtures (`test/wire/fixtures/v1/`) — by the runner
in `test/conformance.test.mjs`, which CI invokes from the Dart side
(`test/wire/web_client_conformance_test.dart`), so this client and the Dart
server cannot drift.

## What it does

- **Handshake** — `helloFrame()` + `acceptWelcome()`; max-overlap version
  negotiation, loud `WireVersionError` when there is no overlap.
- **Commands in** — `promptCommand`, `steerCommand`, `abortCommand`,
  `approvalResponseCommand`, `askResponseCommand`, `secretResponseCommand`,
  `sessionControlCommand` (canonical frames, golden-pinned).
- **Events out** — `decodeEvent(frame)` classifies every frame:
  `{type:'known'}` (render it), `{type:'request'}` (answer it with the
  matching `_response` command, echoing `requestId`), `{type:'unknown'}`
  (E3 forward-compat passthrough: render nothing, keep the run alive).
- **Rendering helpers** — `messageText(message)` for streamed text
  (partial-first: `message_update.message` IS the live snapshot).
- **NDJSON framing** — `frameLine` / `parseLine` (one JSON object per line,
  NOT JSONP).
- **Secrets (E4)** — `isSecretField`, `redactForLog(frame)`; redact before
  you log or persist, never render secret values.

## Run

```sh
npm test        # conformance runner against the golden fixtures (node >= 22.18)
npm run build   # strips types → dist/wire-client.js for the browser example
```

## Example

`sdk/web/example/index.html` is a minimal vanilla-JS chat UI over WebSocket
to `fa wire-serve`:

```sh
dart run bin/fah.dart wire-serve --port 8787 --token mytoken
cd sdk/web && npm run build
python3 -m http.server -d example 8080
# open http://127.0.0.1:8080, connect to ws://127.0.0.1:8787/?token=mytoken
```

No fa handy? `node test/mock-serve.mjs` is a dependency-free scripted engine
(Node, one port for static + ws): it serves `example/` on
`http://127.0.0.1:8091`, accepts `/ws`, and runs ONE scripted prompt —
Cyrillic deltas, tool lifecycle, approval/ask/secret round-trips.

It connects (handshake), sends prompts (steering mid-run), renders streamed
text and tool lifecycle, answers `approval_request` / `ask_request` /
`secret_request` (secret values are sent but never rendered or logged), and
logs `unknown_event` frames gracefully.

## Embedding

The client is transport-free: any byte channel that carries NDJSON lines
(WebSocket, postMessage, platform channel) works — `frameLine` before send,
`parseLine` after receive, then `decodeEvent`. For TypeScript consumers the
source of truth is `src/wire-client.ts` (erasable-syntax only, so it also
runs directly under node's type stripping).
