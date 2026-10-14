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

## Scoped provider timeouts (issue #1554)

`connectTimeoutMs`/`streamIdleTimeoutMs` (strict positive ints, ≤ 1 h) are
valid on three config surfaces: `roles:` chain entries (map form),
`customProviders:` entries, and `models.custom:` entries. Per FIELD, the
first level that declares a value wins:

```
role chain entry > customProviders entry > models.custom entry
    > global providerTimeouts: > built-in default (connect 180 s, idle 300 s)
```

Per-field fallback: an entry overriding only `streamIdleTimeoutMs` leaves the
connect leg at the lower levels. Configs without the keys behave
byte-identically (the standing uncapped-run rule). When a scoped override is
in effect the stall line names it (`idle window 1800s (role default
override)`), so a wide window never reads as a hang.

Slow-local-model recipe: a local endpoint that thinks minutes before the
first byte needs the IDLE leg widened, not the whole config. On the role
chain entry pinning the local endpoint set only `streamIdleTimeoutMs ≈ 2×`
its worst silent prefill stretch — every cloud provider in the same config
keeps the global watchdog untouched.

```yaml
roles:
  default:
    - provider: openai
      model: local-thinker
      baseUrl: http://127.0.0.1:11434/v1
      streamIdleTimeoutMs: 1800000   # this entry only
  smol: [openrouter/openai/gpt-4o-mini]   # keeps 300s
```

## Vision helpers

- `lib/src/model_roles/vision_models.dart` — shared vision heuristic (`modelIdSuggestsVision`, `visionMarker` picker checkmark, `inputModalitiesFor`): CLI model switches recompute `Model.input` from it and the model pickers show the ✓/✗ marker; `packages/fa_ui` re-exports it (one marker list for CLI and app).
- `lib/src/providers/models_for_endpoint.dart` — shared "list this endpoint's models" dispatch (`fetchModelsForEndpoint`): CodeMie `/llm_models` by URL marker, DIAL deployments by `provider: 'dial'`, else OpenAI `/models`; every model picker (CLI flows, app pages) routes through it so no dialect silently degrades to manual entry.
