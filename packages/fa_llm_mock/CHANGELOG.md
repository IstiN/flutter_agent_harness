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
