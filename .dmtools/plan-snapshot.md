# gh-2466 plan — AIIN provider UX: double SSO picker, text-only multimodal models, blanket 1M windows

Live AIN gateway facts (fetched 2026-11 from `https://api.aiin.by/v1/models`, public):
- Shape: `{"models": [{"alias", "display_name", "provider", "context_length",
  "modality": "text+image->text", "input_modalities": ["text","image"],
  "output_modalities": [...], "price", "free"}]}` (567 entries).
- `input_modalities` carries `image` for many ids whose names the vision
  heuristic misses (`mistralai/mistral-large-4-0`, `meta/muse-*`,
  `cohere/command-a-plus`, …) → defect 2 root: client never parses modalities.
- `context_length` is per-model but the gateway stamps a blanket ≈1M default
  (1048576 exact, or 1000000 round) on unverified families — claude-sonnet-5/5.5,
  claude-opus-4.6..5.5, haiku-5.5 → 1M while the real window is 200k;
  verified entries carry true values (claude-opus-4.5 → 200000, deepseek →
  163840, gpt-5 → 400000, gemini → 1048576 legit). Several entries report 0
  (siliconflow/…, video models). → defect 3 root: the client renders that
  blanket 1M per-model; no client-side per-family correction exists.

## Tasks

- [x] T1 (RED first) — Endpoint-reported input modalities through the model
  list. `ModelsEndpointInfo` grows a 4th element
  `Map<String, List<String>> inputModalities`; `parseModelsResponse` reads
  `input_modalities` (string list) and falls back to the `modality` string's
  input side ("text+image->text" → ["text","image"]).
  verify: `dart test test/providers/models_endpoint_test.dart` — new fixture
  tests (image modalities listed; modality-string fallback; no-modalities
  entry absent) FAIL before, PASS after; `dart analyze` clean after all
  tuple sites updated.

- [x] T2 — AIN per-family context windows. New curated per-family map for
  ain (`claude` → 200000, `gemini` → 1048576) + the gateway's blanket-stamp
  set (1048576 exact, 1000000 round). Applied to ain endpoint answers only
  (`isAinBaseUrl`), at BOTH parse consumers (the default OpenAI-compatible
  dialect and the CLI's `_fetchOpenAiCompatibleModels`): a curated family
  value replaces a stamp or a missing window; a precise non-stamp endpoint
  value always wins; uncurated families keep the endpoint's word (gh-1742:
  ONE window per identity everywhere — normalization happens at parse time,
  so picker, meter, registry, compaction all inherit the same numbers).
  verify: fixture unit tests — claude stamp → 200000; claude-opus-4.5 200000
  stays; gemini 1048576 → 1048576; unknown-family stamp stands; absent
  claude → 200000; siliconflow 0 → stays absent (catalog/spec fallback).

- [x] T3 — CLI: model switches use endpoint modalities. `_modelInputModalities`
  side map (the `_modelContextWindows` pattern) fed by the fetch paths; the
  four `inputModalitiesFor(modelId)` switch sites consult the endpoint map
  first, heuristic fallback unchanged.
  verify: unit test — endpoint-reported image model switched to → `input`
  carries image; unreported id → heuristic.

- [x] T4 — App/fa_ui: pickers + connect honor endpoint modalities.
  `EndpointModelsController.inputModalities`; settings `_vision` derivation
  consults it (incl. custom providers — the ain case); fa_ui
  `unified_model_picker` entry `supportsImages` + `vision ✓` marker use
  endpoint modalities ?? heuristic; the app's ain connect flow sets
  `supportsImages` on the AgentConfig from the fetched modalities.
  verify: fa_ui/flutter_app unit tests for the picker entry + controller;
  `flutter analyze` + targeted `flutter test`.

- [x] T5 — SSO hint. `buildAinLoginUrl` gains optional `provider` (query
  param on the hosted login URL); `runAinConnectCliFlow` gains optional
  `provider` threaded into that URL; the CLI `_runAiinConnect` passes the
  user's picked provider. One selection total: the hosted page honours the
  hint (IstiN/aiin companion issue tracks the hosted-page side).
  verify: unit test — login URL carries `provider=google`;
  `runAiinConnectCliFlow(provider: …)` produces the hinted URL.

- [x] T6 — Full gates. `dart format` on touched files, `dart analyze`,
  `dart test` (SDK suite), fa_ui + flutter_app analyze/tests.
  verify: all green; no golden changes needed (no UI-shape change beyond a
  marker string).

- [ ] T7 — Close out. CHANGELOG `## Unreleased` entry, outputs/rca.md,
  outputs/response.md; plan snapshot removed per protocol.

## Decisions

- D1: modalities ride `ModelsEndpointInfo` as a 4th tuple element (structural
  records — the compiler finds every site; matches windows/caps precedent).
- D2: window normalization keys on the model id's family token
  (`claude`, `gemini` — case-insensitive, provider-prefixed ids included).
  The stamp set is exactly {1048576, 1000000} — the two ≈1M values the
  gateway stamps. Non-stamp values win (claude-opus-4.5 keeps 200000);
  families outside the map keep the endpoint's report (minimax-m3's
  genuine 1M stays 1M). This satisfies "no global 1M fallback" — the 1M
  survives only where per-model/per-family evidence says 1M.
- D3 (updated during T2/T3): the CLI's hand-rolled OpenAI-shaped fetch
  (`_fetchOpenAiCompatibleModels`) was rerouted THROUGH the shared dispatch
  (`fetchModelsForEndpoint`) instead of duplicating the ain normalization —
  one fetch path, one normalization site (the plan's original "apply at BOTH
  parse consumers" would have kept the duplication). The dispatch's
  copilot/CodeMie/DIAL dialect routing also starts serving those active-
  provider fetches, matching the saved-entry path.
- D5: the curated map lives in code next to the ain endpoint helpers, NOT as
  exact-id entries in the bundled remote catalog — catalog `contextWindows`
  keys would leak into the chat-fallback id list (`chatFallbackFor`), and
  exact ids can't express families.
- D4: SSO fix = hint param (the ticket's primary instruction); the
  hosted-page honouring is the IstiN/aiin companion issue, noted in
  response.md. Web/desktop app flows already skip a client-side picker.

## Open questions

- Q: exact hosted-page hint param name? A: `provider` (the
  oauth-proxy/initiate body key); harmless if unrecognised, companion issue
  owns alignment.
- Q: gpt-4.1's genuine 1047576? A: not in the stamp set — precise value wins.
