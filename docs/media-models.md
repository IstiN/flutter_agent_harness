# Media models

Per-modality media slots (`imageGeneration`, `audioTts`, `musicGeneration`,
`videoGeneration`, `vision`, `transcription`) steer image/audio/video calls
to dedicated endpoints. Configuration lives in the CLI's `~/.fah/config.yaml`
(`models.slots.<slot>`) and the app's `media_models.json`; both share the
schema in `lib/src/model_roles/media_model_slots.dart`.

## No implicit main-connection fallback (gh-1844)

A slot **without** an override is **UNCONFIGURED** — the main connection is
never an implicit fallback (sending the chat model id to a media API was the
worst case). Tools fail with an actionable "configure the slot" error that
names the slot and the config path.

To serve a slot from the main connection, opt in **explicitly** per slot:

```yaml
models:
  slots:
    imageGeneration:
      useMainConnection: true
```

- default: `false`; the endpoint fields (`providerKind`, `baseUrl`,
  `modelId`) are required unless the opt-in is set (validated at load).
- app: the settings "Media models" pick **"Same as main connection"** saves
  the same opt-in into `media_models.json`; rows show **Not configured**
  instead of an inherited main endpoint.
- API-key inheritance is deliberately PER SURFACE (one unambiguous rule
  each):
  - **CLI** (`generate_image` / `generate_video`): an override without
    `apiKeyName` reuses the MAIN connection's key when (and only when)
    the override's endpoint is on the **same host**; a named-but-
    unresolvable or cross-host key fails with an actionable
    "the &lt;slot&gt; slot has no resolvable API key" error **before any
    provider call**. Both CLI resolvers share this one rule.
  - **app** (`MediaModelsStore.resolve`): an override **never** inherits
    the main connection's key — app overrides must name `apiKeyName`;
    without one the endpoint is unusable (no key is sent anywhere).

## Multimodal image/video input (text + reference images)

`generate_image` and `generate_video` accept an optional `images` list
(sandbox paths, `http(s)` URLs, or base64 — `b64:<payload>` / `data:` URLs /
bare base64), reusing the chat image-input size and count guards.

- OpenRouter endpoints carry them as `input_references`
  (`image_url` entries); the wire formats are pinned in
  `OpenRouterImageDialect` / `OpenRouterVideoDialect`.
- **Declared input modalities gate image input**: the slot override's
  `input:` list wins; otherwise OpenRouter endpoints are probed
  (`GET /api/v1/models` → `architecture.input_modalities`). An endpoint
  known not to accept images fails with a capability error **before any
  provider call**; unknown capabilities are left for the provider to
  validate.
- reference images are supported only by the OpenRouter dialects; MiniMax /
  OpenAI-compatible endpoints reject them up front.

## Decisions API (`decide` tool)

OpenRouter's Decisions API (`POST {base}/systemone`) is a new modality, not
a chat dialect: send a `state` plus typed questions — `bool` (yes/no; the
API's wire discriminator is `noul` per the official OpenAPI spec, the tool
accepts both spellings), `choice` (pick one from a fixed map), `score`
(calibrated score over an ordered legend) — and receive answers with
calibrated probabilities plus usage accounting. Provider errors and local
validation failures are returned as structured JSON results (never
thrown). The API is OpenRouter-only and non-streaming; the tool gates on
the main connection's provider kind before any network call.
