## 0.2.1 — 2026-09-30

- `LlmConfig.fromEnvironment` base URLs (the explicit argument or `{PROVIDER}_BASE_PATH`/`{PROVIDER}_BASE_URL`) are normalized for the OpenAI-compatible providers: a bare origin or versioned base (`…/v1`) resolves to the full `/v1/chat/completions` endpoint, replacing the ollama-only fixup. Full endpoints, custom gateway paths, and query-string URLs pass through verbatim; `copilot` base URLs are never rewritten. The resolution order and accepted shapes are now documented in the class docs and the package README.

## 0.2.0 — 2026-08-28

- GitHub Copilot as a first-class provider: OAuth device-flow auth (request/poll with pending/slow_down/expired/denied semantics), GitHub-token-to-Copilot-token exchange with dead-token detection, and login resolution.
- CopilotTokenManager: cached short-lived Copilot tokens with proactive refresh (2 min before expiry), 30 s minimum exchange spacing, single-flight locking, and forced refresh (getAgain) for 401/403 retries.
- CopilotTokenStore abstraction with an in-memory implementation for tests and apps without a secure backend.
- CopilotProvider over /chat/completions: streaming SSE and complete responses, mandatory Copilot headers, per-request X-Initiator and Copilot-Vision-Request, cancel that stops emission immediately, refresh-once retry on 401/403, and listModels() parsing capabilities/limits/supported_endpoints.
- ProviderFactory copilot branch with accountType (individual/business/enterprise), explicit baseUrl override, and entry-name-scoped token store wiring.
- LlmConfig gains optional accountType and entryName fields.
## 0.1.0

- Initial release.
- OpenAI-compatible provider with streaming support.
- OpenRouter provider with model routing.
- Ollama provider for local inference.
- Provider configuration and resolution utilities.
- Token counting and context window management.