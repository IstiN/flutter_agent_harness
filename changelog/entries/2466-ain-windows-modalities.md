---
type: fix
scope: aiin
issue: 2466
---

- fix(aiin): the AIN connect surfaces treat the gateway's blanket ≈1M window and
  its modality-blind id heuristic as truth (gh-2466) — Claude-family models the
  gateway leaves unverified ran on a fake 1M window (real: 200k) and multimodal
  ids (`mistralai/mistral-large-4-0`, `meta/muse-*`, …) were flagged text-only.
  `/models` answers now carry per-model input modalities (`input_modalities`,
  with the `modality` string as fallback) through a widened `ModelsEndpointInfo`
  4-tuple; every model switch, the CLI pickers, the app's settings vision
  switch and the fa_ui unified picker prefer the endpoint's modalities over the
  id heuristic; and AIN answers are normalized per curated family (claude →
  200k, gemini → 1M) with the gateway's stamp set {1048576, 1000000} treated as
  "unverified" — precise endpoint reports always win, uncurated families keep
  the endpoint's word (no global 1M fallback; ONE window per identity at the
  parse source, so picker, meter, registry and compaction agree — gh-1742).
  `buildAiinLoginUrl`/`runAinConnectCliFlow` now carry the client-picked
  identity provider as a `provider` hint so the hosted page can skip its own
  picker (one selection per sign-in; the hosted-page honouring is the
  IstiN/aiin companion issue).
