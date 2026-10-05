## 0.1.1

- `MockLlmScript` scenario key `sticky: true` — a wildcard for
  background-noise scenarios: once the queue runs dry, every further
  matching request re-serves the LAST response instead of answering HTTP
  500 `script exhausted`. Kills the 500-retry-storm flake class where one
  schedule-dependent extra call (memory auto-tag generation, gh-1171)
  exhausts an exact-count script mid-test.

## 0.1.0

- Initial release.
- `MockLlmServer`: scripted OpenAI-compatible mock LLM server over loopback
  HTTP (SSE chat completions, models endpoint), extracted from the
  `flutter_agent_harness` integration-test helpers.
- `MockLlmScript`: YAML/JSON config mapping user messages to response
  queues — text, tool calls, tool-result echo, and error simulation —
  with strict validation (`MockLlmConfigException`).
- Programmatic scripting API: `enqueueToolCall`/`enqueueText`/
  `enqueueToolResultEcho`.
