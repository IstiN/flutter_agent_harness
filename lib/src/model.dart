/// Model descriptors and pricing.
///
/// Ported from pi-mono `packages/ai/src/types.ts` (`Model`, `ModelCost`,
/// `OpenAICompletionsCompat`) and `packages/ai/src/models.ts`
/// (`calculateCost`). Only the subset needed for the Phase 0
/// openai-completions adapter is ported; pricing tiers and the full compat
/// matrix arrive with later providers.
library;

import 'types.dart';

/// Per-million-token pricing for a model, in USD.
///
/// Ported from pi's `ModelCostRates`. Request-wide pricing tiers from pi's
/// `ModelCost` are not ported yet.
final class ModelCost {
  const ModelCost({
    this.input = 0,
    this.output = 0,
    this.cacheRead = 0,
    this.cacheWrite = 0,
  });

  /// Cost per million input tokens.
  final double input;

  /// Cost per million output tokens.
  final double output;

  /// Cost per million tokens read from the prompt cache.
  final double cacheRead;

  /// Cost per million tokens written to the prompt cache.
  final double cacheWrite;
}

/// How a provider expects the reasoning/thinking parameter to be shaped.
///
/// Ported from the `openai` and `openrouter` cases of pi's
/// `OpenAICompletionsCompat.thinkingFormat`; the remaining provider-specific
/// formats arrive with their adapters.
enum ThinkingFormat {
  /// OpenAI-style top-level `reasoning_effort`.
  openai,

  /// OpenRouter-style nested `reasoning: { effort: ... }`.
  openrouter,
}

/// Compatibility flags for OpenAI-compatible chat-completions endpoints.
///
/// Ported subset of pi's `OpenAICompletionsCompat`. When a flag is `null`
/// the adapter auto-detects it from the model's provider/baseUrl.
final class OpenAICompletionsCompat {
  const OpenAICompletionsCompat({
    this.maxTokensField,
    this.supportsUsageInStreaming,
    this.thinkingFormat,
    this.requiresToolResultName,
  });

  /// Which field carries the output-token cap: `max_tokens` or
  /// `max_completion_tokens`. Default: `max_completion_tokens`.
  final String? maxTokensField;

  /// Whether the provider supports `stream_options: { include_usage: true }`.
  /// Default: true.
  final bool? supportsUsageInStreaming;

  /// How to send reasoning effort. Default: auto-detected
  /// ([ThinkingFormat.openrouter] for OpenRouter, [ThinkingFormat.openai]
  /// otherwise).
  final ThinkingFormat? thinkingFormat;

  /// Whether tool results must carry the tool `name` field. Default: false.
  final bool? requiresToolResultName;
}

/// A model the harness can call.
///
/// Ported subset of pi's `Model`: pricing tiers, thinking-level maps, and
/// per-provider compat beyond [OpenAICompletionsCompat] are deferred to the
/// phases that need them.
final class Model {
  const Model({
    required this.id,
    this.name = '',
    required this.api,
    required this.provider,
    required this.baseUrl,
    this.reasoning = false,
    this.input = const ['text'],
    this.cost = const ModelCost(),
    required this.contextWindow,
    required this.maxTokens,
    this.headers,
    this.compat,
  });

  /// The model id sent to the provider (e.g. `gpt-4o-mini`,
  /// `anthropic/claude-sonnet-4` on OpenRouter).
  final String id;

  /// Human-readable display name.
  final String name;

  /// The API dialect used to talk to this model (e.g. `openai-completions`).
  final String api;

  /// The provider id (e.g. `openai`, `openrouter`).
  final String provider;

  /// Base URL of the API. Swapping this is how OpenRouter and other
  /// OpenAI-compatible endpoints are reached (e.g.
  /// `https://openrouter.ai/api/v1`).
  final String baseUrl;

  /// Whether the model produces reasoning/thinking output.
  final bool reasoning;

  /// Input modalities the model accepts: `text` and/or `image`.
  final List<String> input;

  /// Pricing used for inline cost accounting.
  final ModelCost cost;

  /// Total context window in tokens.
  final int contextWindow;

  /// Maximum output tokens the model can produce.
  final int maxTokens;

  /// Default headers sent with every request to this model.
  final Map<String, String>? headers;

  /// Compatibility overrides for OpenAI-compatible APIs. When `null`, the
  /// adapter auto-detects from [provider]/[baseUrl].
  final OpenAICompletionsCompat? compat;
}

/// Fills in [Usage.cost] from the model's [ModelCost] rates.
///
/// Ported from pi's `calculateCost` (flat-rate case; tiered pricing is not
/// ported yet). Returns [usage] unchanged apart from the cost breakdown.
Usage calculateCost(Usage usage, Model model) {
  const perMillion = 1000000.0;
  final cost = UsageCost(
    input: usage.input * model.cost.input / perMillion,
    output: usage.output * model.cost.output / perMillion,
    cacheRead: usage.cacheRead * model.cost.cacheRead / perMillion,
    cacheWrite: usage.cacheWrite * model.cost.cacheWrite / perMillion,
  );
  return usage.copyWith(
    cost: cost.copyWith(
      total: cost.input + cost.output + cost.cacheRead + cost.cacheWrite,
    ),
  );
}
