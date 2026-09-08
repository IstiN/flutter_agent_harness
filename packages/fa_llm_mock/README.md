# fa_llm_mock

Scripted OpenAI-compatible mock LLM server for integration tests. No real
LLM, no external network — a loopback HTTP server any test environment can
reach: the Fa CLI (headless or PTY), Flutter integration tests on macOS/iOS
simulators, headless-browser extension e2e, plain Dart unit tests.

## Usage

```dart
import 'package:fa_llm_mock/fa_llm_mock.dart';

final script = MockLlmScript.parseFile('mock_script.yaml');
final server = await MockLlmServer.start(script: script);
// point the system under test at server.baseUrl (http://127.0.0.1:<port>/v1)
await server.stop();
```

Programmatic scripting (no config file) is also available:

```dart
final server = await MockLlmServer.start();
server.enqueueToolCall('bash', '{"command": "ls"}');
server.enqueueToolResultEcho();
server.enqueueText('listed');
```

`baseUrl` already carries the trailing `/v1`, so it drops straight into the
CLI's `--base-url` or an OpenAI-compatible client's endpoint setting.

## Config document (YAML or JSON)

JSON is a YAML subset — the same parser takes both.

```yaml
model: mock-model            # optional, reported by GET /models
responses:                   # optional fallback queue when nothing matches
  - text: "Not sure what to do"
scenarios:
  - match: "list the files"  # substring of the LAST user message
    responses:               # popped in order, one per request
      - toolCall:
          name: bash
          arguments: '{"command": "ls"}'   # string rides verbatim; a
                                           # structured value is JSON-encoded
      - toolResultEcho: true # echo the last tool result back as the reply
      - text: "listed"
      - error:               # error simulation: HTTP status + JSON body
          status: 503
          message: "mock outage"
```

### Response kinds

| Key | Wire shape |
| --- | --- |
| `text` | `content` delta, `finish_reason: "stop"` |
| `toolCall` | `tool_calls` delta (`name`, `arguments`), `finish_reason: "tool_calls"` |
| `toolResultEcho` | assistant text quoting the last `role: "tool"` content |
| `error` | HTTP `status` (default 500) with `{"error": {"message": ...}}` |

### Routing

Per `/chat/completions` request: the FIRST scenario whose `match` is a
substring of the last user message pops the front of its queue; no match
pops the top-level `responses` queue; an empty queue (matched-but-exhausted
or no fallback) answers HTTP 500 `script exhausted`, which provider
adapters surface as an error turn (headless CLI exit code 1).

The parser is strict: unknown keys, unknown response kinds, and wrong
value types throw `MockLlmConfigException` at startup — a typo in a test
fixture fails fast instead of silently falling through to the fallback.

## Test seam details

- `server.chatCalls` — how many `/chat/completions` requests were served.
- `server.chatBodies` — raw request bodies in call order, for asserting on
  the exact wire payload (e.g. the advertised `tools` array).
- `GET {baseUrl}/models` answers a minimal model list; every other path is
  404.
