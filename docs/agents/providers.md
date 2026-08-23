# Providers

See [cli.md](cli.md) for the `/settings` hub and CLI flags.

## Provider catalog (CLI auth flows)

| Provider | Auth | Endpoint notes | Models list |
| --- | --- | --- | --- |
| `chatgpt` (`chatgpt-codex`) | OAuth PKCE against `auth.openai.com`; `CHATGPT_OAUTH_CREDENTIALS` blob | Responses-API SSE, `store: false`, `ChatGPT-Account-ID` header; 401 → refresh → re-persist | manual |
| `codemie` (manual) | env `CODEMIE_API_KEY` | `<org>/code-assistant-api/v1` Bearer | `/models` |
| `codemie` (SSO) | browser SSO → `codemie_access_token` JWT Bearer (random callback port, base64 `token` carries session cookies; re-login refreshes, keeps last-used model) | same as manual | `/llm_models?include_all=true` (LiteLLM) — `_refreshModelCache` branches on `code-assistant-api` marker |
| `dial` (EPAM DIAL Core) | `Api-Key` header (adapter null key — no `Authorization: Bearer`); `?api-version=` from `DIAL_API_VERSION` env | chat at `{baseUrl}/openai/deployments/{model}/chat/completions` (deployment name in PATH via `OpenAICompletionsOptions.urlBuilder`) | `{baseUrl}/openai/models` (`fetchDialModels`, `_refreshModelCache` `provider == 'dial'` branch) |
| `anthropic` | env `ANTHROPIC_API_KEY` | `api: 'anthropic-messages'`, `https://api.anthropic.com` | context window 200k / max 16k |
| `google` | env `GOOGLE_API_KEY` | `api: 'google-generative-ai'`, `https://generativelanguage.googleapis.com/v1beta` (also Gemini media — see `MediaGateway`) | context window 1M / max 16k |
| `openrouter` | env `OPENROUTER_API_KEY` (or `OPENAI_API_KEY`); OAuth PKCE via `lib/src/providers/openrouter_oauth.dart` + `services/openrouter_oauth_*` | `api: 'openai-completions'`, `https://openrouter.ai/api/v1` | `/api/v1/models` |

## CLI flags

CLI: `/provider chatgpt oauth [headless]` (callback server in `lib/src/cli/chatgpt_oauth_server.dart`, exported from `lib/io.dart`). `/provider codemie sso [orgUrl]` (callback server in `lib/src/cli/codemie_sso_server.dart`, exported from `lib/io.dart`). Headless: `--provider dial --model <deployment> [--base-url …]` (dial has no default model id — `buildCliDefaultModel` throws without `--model`).

## Vision helpers

- `lib/src/model_roles/vision_models.dart` — shared vision heuristic (`modelIdSuggestsVision`, `visionMarker` picker checkmark, `inputModalitiesFor`): CLI model switches recompute `Model.input` from it and the model pickers show the ✓/✗ marker; `packages/fa_ui` re-exports it (one marker list for CLI and app).
- `lib/src/providers/models_for_endpoint.dart` — shared "list this endpoint's models" dispatch (`fetchModelsForEndpoint`): CodeMie `/llm_models` by URL marker, DIAL deployments by `provider: 'dial'`, else OpenAI `/models`; every model picker (CLI flows, app pages) routes through it so no dialect silently degrades to manual entry.
