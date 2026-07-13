/// Context-overflow detection via provider-specific error-message regexes.
///
/// Ported from pi-mono `packages/ai/src/utils/overflow.ts`. The regex set and
/// branching are identical to pi's — keep them mechanically close so future
/// pi fixes port trivially. Unlike the name might suggest, pi has no
/// per-provider branching: a single pattern list covers all providers, with a
/// separate exclusion list for known non-overflow errors (rate limiting,
/// throttling).
library;

import 'types.dart';

/// Regex patterns matching error messages returned when the input exceeds the
/// model's context window.
///
/// Provider coverage (with example messages):
///
/// - Anthropic: "prompt is too long: 213462 tokens > 200000 maximum"
/// - Anthropic (HTTP 413): `{"error":{"type":"request_too_large",...}}`
/// - Amazon Bedrock: "input is too long for requested model"
/// - OpenAI: "Your input exceeds the context window of this model"
/// - OpenAI/LiteLLM: "Requested token count exceeds the model's maximum
///   context length of 131072 tokens"
/// - OpenAI-compatible: "Input length (265330) exceeds model's maximum
///   context length (262144)."
/// - Google (Gemini): "The input token count (1196265) exceeds the maximum
///   number of tokens allowed (1048575)"
/// - xAI: "This model's maximum prompt length is 131072 but the request
///   contains 537812 tokens"
/// - Groq: "Please reduce the length of the messages or completion"
/// - OpenRouter: "This endpoint's maximum context length is X tokens.
///   However, you requested about Y tokens"
/// - OpenRouter/Poolside: "Input length X exceeds the maximum allowed input
///   length of Y tokens."
/// - Together AI: "The input (X tokens) is longer than the model's context
///   length (Y tokens)."
/// - GitHub Copilot: "prompt token count of X exceeds the limit of Y"
/// - llama.cpp: "the request exceeds the available context size"
/// - LM Studio: "tokens to keep from the initial prompt is greater than the
///   context length"
/// - MiniMax: "invalid params, context window exceeds limit"
/// - Kimi For Coding: "Your request exceeded model token limit: X
///   (requested: Y)"
/// - Mistral: "Prompt contains X tokens ... too large for model with Y
///   maximum context length"
/// - DS4: "Prompt has X tokens, but the configured context size is Y tokens"
/// - z.ai: "model_context_window_exceeded" (non-standard finish reason
///   surfaced as error text)
/// - Ollama: "prompt too long; exceeded max context length by X tokens"
/// - Cerebras: "400/413 status code (no body)"
final _overflowPatterns = [
  RegExp(r'prompt is too long', caseSensitive: false), // Anthropic
  RegExp(r'request_too_large', caseSensitive: false), // Anthropic HTTP 413
  RegExp(
    r'input is too long for requested model',
    caseSensitive: false,
  ), // Amazon Bedrock
  RegExp(r'exceeds the context window', caseSensitive: false), // OpenAI
  RegExp(
    r"exceeds (?:the )?(?:model'?s )?maximum context length"
    r'(?: of [\d,]+ tokens?|\s*\([\d,]+\))',
    caseSensitive: false,
  ), // OpenAI-compatible proxies (LiteLLM)
  RegExp(
    r'input token count.*exceeds the maximum',
    caseSensitive: false,
  ), // Google (Gemini)
  RegExp(r'maximum prompt length is \d+', caseSensitive: false), // xAI (Grok)
  RegExp(r'reduce the length of the messages', caseSensitive: false), // Groq
  RegExp(
    r'maximum context length is \d+ tokens',
    caseSensitive: false,
  ), // OpenRouter (most backends)
  RegExp(
    r'exceeds (?:the )?maximum allowed input length of [\d,]+ tokens?',
    caseSensitive: false,
  ), // OpenRouter/Poolside
  RegExp(
    r"input \(\d+ tokens\) is longer than the model'?s context length"
    r' \(\d+ tokens\)',
    caseSensitive: false,
  ), // Together AI
  RegExp(r'exceeds the limit of \d+', caseSensitive: false), // GitHub Copilot
  RegExp(
    r'exceeds the available context size',
    caseSensitive: false,
  ), // llama.cpp server
  RegExp(r'greater than the context length', caseSensitive: false), // LM Studio
  RegExp(r'context window exceeds limit', caseSensitive: false), // MiniMax
  RegExp(
    r'exceeded model token limit',
    caseSensitive: false,
  ), // Kimi For Coding
  RegExp(
    r'too large for model with \d+ maximum context length',
    caseSensitive: false,
  ), // Mistral
  RegExp(
    r'prompt has [\d,]+ tokens?, but the configured context size is'
    r' [\d,]+ tokens?',
    caseSensitive: false,
  ), // DS4 server
  RegExp(r'model_context_window_exceeded', caseSensitive: false), // z.ai
  RegExp(
    r'prompt too long; exceeded (?:max )?context length',
    caseSensitive: false,
  ), // Ollama explicit overflow error
  RegExp(r'context[_ ]length[_ ]exceeded', caseSensitive: false), // Generic
  RegExp(r'too many tokens', caseSensitive: false), // Generic fallback
  RegExp(r'token limit exceeded', caseSensitive: false), // Generic fallback
  RegExp(
    r'^4(?:00|13)\s*(?:status code)?\s*\(no body\)',
    caseSensitive: false,
  ), // Cerebras: 400/413 with no body
];

/// Patterns that indicate non-overflow errors (rate limiting, server errors).
/// Messages matching any of these are excluded from overflow detection even
/// if they also match an overflow pattern — e.g. Bedrock formats throttling
/// errors as "Throttling error: Too many tokens, ..." which would otherwise
/// match the `too many tokens` fallback.
final _nonOverflowPatterns = [
  RegExp(
    r'^(Throttling error|Service unavailable):',
    caseSensitive: false,
  ), // AWS Bedrock non-overflow errors
  RegExp(r'rate limit', caseSensitive: false), // Generic rate limiting
  RegExp(r'too many requests', caseSensitive: false), // Generic HTTP 429
];

/// Whether [message] represents a context overflow.
///
/// Handles three cases, mirroring pi's `isContextOverflow`:
///
/// 1. **Error-based overflow**: [message] failed with an error message
///    matching a known overflow pattern (and no known non-overflow pattern).
/// 2. **Silent overflow** (z.ai style): the request succeeded but the
///    reported input usage exceeds [contextWindow]. Requires [contextWindow].
/// 3. **Length-stop overflow** (Xiaomi MiMo style): the server truncated
///    oversized input to fit the context window, returning
///    [StopReason.length] with zero output and input filling the window
///    (>= 99% of [contextWindow]). Requires [contextWindow].
///
/// Detection is reliable for providers that return a detectable error
/// (Anthropic, OpenAI, Google, xAI, Groq, Cerebras, Mistral, OpenRouter,
/// Together AI, llama.cpp, LM Studio, Kimi For Coding, DS4). z.ai and Xiaomi
/// MiMo need [contextWindow] for their silent forms; Ollama may truncate
/// silently in ways that cannot be detected here.
bool isContextOverflow(AssistantMessage message, {int? contextWindow}) {
  // Case 1: error message patterns.
  final errorMessage = message.errorMessage;
  if (message.stopReason == StopReason.error && errorMessage != null) {
    final isNonOverflow = _nonOverflowPatterns.any(
      (pattern) => pattern.hasMatch(errorMessage),
    );
    if (!isNonOverflow &&
        _overflowPatterns.any((pattern) => pattern.hasMatch(errorMessage))) {
      return true;
    }
  }

  // Case 2: silent overflow (z.ai style) — successful but usage exceeds
  // the context window.
  if (contextWindow != null && message.stopReason == StopReason.stop) {
    final inputTokens = message.usage.input + message.usage.cacheRead;
    if (inputTokens > contextWindow) {
      return true;
    }
  }

  // Case 3: length-stop overflow (Xiaomi MiMo style) — the server truncates
  // oversized input to fit the context window, leaving no room for output.
  if (contextWindow != null &&
      message.stopReason == StopReason.length &&
      message.usage.output == 0) {
    final inputTokens = message.usage.input + message.usage.cacheRead;
    if (inputTokens >= contextWindow * 0.99) {
      return true;
    }
  }

  return false;
}
