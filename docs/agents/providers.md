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
| `copilot` | GitHub credential → short-lived Copilot API token exchange (`copilot_internal/v2/token`); see the Copilot section below | `api: 'openai-completions'` over the plan host (individual/business/enterprise/custom); token `proxy-ep` picks the tenant API host | `/models` (picker-enabled, tool-call capable, `/chat/completions`-capable entries) |

## GitHub Copilot credentials

Three supported GitHub credential shapes (`lib/src/providers/copilot_oauth.dart`):

| Credential | Support |
| --- | --- |
| Device-flow OAuth token (`gho_`/`ghu_`) | **Recommended.** `/provider copilot` → GitHub device flow; exchanged for a ~30-min Copilot API token (single-flight, proactive refresh 2 min before expiry, one 401/403 refresh+retry) |
| `COPILOT_GITHUB_TOKEN` env (headless) | An OAuth token (exchanged like above) **or** a fine-grained PAT (`github_pat_…`) |
| Fine-grained PAT (pasted or env) | **PAT mode:** the exchange is skipped entirely — the raw PAT is the Bearer against the configured base URL (the seat's tier host), with the official Copilot CLI's first-party identity headers (`copilot-integration-id: copilot-developer-cli`, `user-agent: copilot/<fa-version> (<os>) term/unknown`) — the only request shape the Copilot API accepts a PAT with. No 401 refresh-retry (nothing to refresh). Requires the token's **"Copilot Requests"** permission and a Copilot seat |
| Classic PAT (`ghp_…`) | Never supported by Copilot — rejected at paste time |

Headless flows: `--provider copilot --model <id>` with `COPILOT_GITHUB_TOKEN` (OAuth or fine-grained PAT), or a saved entry's key slot (`FA_KEY_COPILOT_<NAME>`). `/provider export` copies the saved Copilot account's full token to the clipboard (picker on several accounts; the token never prints to the transcript).

## CLI flags

CLI: `/provider chatgpt oauth [headless]` (callback server in `lib/src/cli/chatgpt_oauth_server.dart`, exported from `lib/io.dart`). `/provider codemie sso [orgUrl]` (callback server in `lib/src/cli/codemie_sso_server.dart`, exported from `lib/io.dart`). Headless: `--provider dial --model <deployment> [--base-url …]` (dial has no default model id — `buildCliDefaultModel` throws without `--model`).

## Roles × custom providers

A `roles:` chain entry can name a saved `customProviders:` entry **by name** (issue #1552) — the natural hand-written config works instead of silently degrading to a single model:

```yaml
customProviders:
  - name: aiai
    apiType: openai          # the adapter dialect (catalog spec)
    baseUrl: https://api.bycom.by/v1
    modelId: glm-4.6
    keyName: AIAI_API_KEY    # optional: the env/secure-store slot for the key

roles:
  default:
    - provider: aiai         # names the entry above
      model: glm-4.6
```

Rules:

- **Kind-vs-name**: resolution order is catalog name, then adapter kind (`chatgpt-codex`), then the `customProviders:` registry. Registry entries can never be named after catalog providers (reserved names), so the two namespaces never shadow. An entry known to NEITHER catalog nor registry still skips + degrades exactly as before (the roles config falls back to the single model with one warning — which also prints in the TUI, not only stderr).
- **Defaults**: the entry supplies `baseUrl` and `keyName` where the chain ref omits them; explicit ref fields always win.
- **Key slots** (issue #40 precedence): a custom endpoint's key resolves
  from the entry's pinned `keyName` first, then the endpoint-scoped
  `FA_KEY_<HOST>` store slot (e.g. `FA_KEY_API_BYCOM_BY`) or its
  `_2`/`_3`… rotation stack, and only then falls back to the adapter
  dialect's catalog env names (`OPENAI_API_KEY` for an `openai` entry —
  the last-resort fallback, shared with the dialect's default endpoint).
  Export `AIAI_API_KEY=<key>` (or `/key set FA_KEY_API_BYCOM_BY <key>`)
  and every chain entry referencing the entry resolves.

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
