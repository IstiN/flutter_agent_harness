/// Probable context-overflow classification for deterministic per-history
/// provider failures (gh-2470).
///
/// Some endpoints fail a request DETERMINISTICALLY — the same opaque error
/// (`Provider finish_reason: error`) on every retry of the same history —
/// while the same session succeeded minutes earlier at nearly the same
/// size (the ticket's evidence: a ~245k-token request failing ×3 on an
/// endpoint whose catalog advertises a 1M window). Retrying the unchanged
/// history can never succeed; the honest classification is PROBABLE
/// CONTEXT OVERFLOW / poisonous payload, and the remediation is compact
/// this session or switch model/session — never "check the provider
/// status / try again later".
///
/// This module is deliberately WORDING-FREE: it owns the size gate and the
/// marker, not the failure vocabulary. The exclusion nets (transient
/// transport wordings, rate limits, definite overflow patterns, budget
/// exhaustion) stay with the retry ladder that owns them
/// (`providers/transient_retry_stream.dart`) — one vocabulary, composed at
/// the classification site. The ladder only consults this module AFTER its
/// own nets stood down, so a probable-overflow verdict is by construction
/// "not transient-healable".
///
/// The definite overflow classes ([isContextOverflow]'s pattern hits, the
/// silent-overflow forms) are NOT this module's business either: they
/// classify exactly and route to compaction on their own paths. This
/// module covers the UNDETECTABLE family — an endpoint that refuses a
/// large request with an opaque error instead of an overflow message.
library;

import 'dart:convert';

import 'context.dart';
import 'types.dart';

/// The structural marker a probable-overflow terminal carries. Hosts
/// recognize the class through [isProbableOverflowError] — producer and
/// consumers pin the constant (the `connectWatchdogTag` discipline).
const String probableOverflowMarker = 'probable context overflow';

/// Whether [errorMessage] is a probable-overflow terminal (the marker
/// above). Null/empty/other failures are never the class.
bool isProbableOverflowError(String? errorMessage) =>
    errorMessage != null && errorMessage.contains(probableOverflowMarker);

/// The fraction of the model's catalog window above which a request is
/// "large": a deterministic opaque failure on ≥ 50% of the advertised
/// window is probable-overflow territory. (gh-2470: the copilot endpoint
/// failed at ~245k against an advertised 1M — well under 50% — which is
/// why the absolute floor below exists.)
const double probableOverflowWindowFraction = 0.5;

/// The absolute request size (estimated tokens) above which a request is
/// "large" regardless of the catalog window: the served-well-below-the-
/// advertised-window family the ticket reports (245k failing on a 1M
/// catalog window). A deterministic opaque failure on a 200k+-token
/// history is a poisoned/poisonous request until proven otherwise.
const int probableOverflowAbsoluteFloorTokens = 200000;

/// Whether [requestTokens] is a LARGE request for [contextWindow]: at or
/// above [probableOverflowWindowFraction] of the window when one is known
/// (≤ 0 = unknown), or at or above [probableOverflowAbsoluteFloorTokens]
/// regardless. The disjunction covers both families: small-window models
/// (fraction) and endpoints serving far below their advertised window
/// (floor).
bool isProbableOverflowLargeRequest({
  required int requestTokens,
  int? contextWindow,
}) {
  if (contextWindow != null && contextWindow > 0) {
    if (requestTokens >= contextWindow * probableOverflowWindowFraction) {
      return true;
    }
  }
  return requestTokens >= probableOverflowAbsoluteFloorTokens;
}

/// Estimated request tokens for the probable-overflow gate: the same
/// chars-per-token heuristic the compaction estimator uses (prose at
/// ~4 chars/token, the token-dense system prompt at ~2.5, images at the
/// flat 4800-char ≈ 1200-token estimate) as a SELF-CONTAINED walk —
/// providers sit below the compaction layer and must not import it, and
/// the gate only needs a coarse size signal, not the meter's anchored
/// precision. Tool-call arguments count at their JSON length (they ride
/// every request); video content prices at its payload bytes (the
/// estimator's gh-2007 rule).
int estimateProbableOverflowRequestTokens(Context context) {
  var chars = 0;
  for (final message in context.messages) {
    switch (message) {
      case UserMessage(:final content):
        chars += _blocksChars(content);
      case AssistantMessage(:final content):
        chars += _blocksChars(content);
      case ToolResultMessage(:final content):
        chars += _blocksChars(content);
      default:
        break;
    }
  }
  final systemPrompt = context.systemPrompt;
  // Transcript at ~4 chars/token; the token-dense system prompt at ~2.5
  // (the gh-2411 measured overhead density).
  final overhead = systemPrompt == null
      ? 0
      : (systemPrompt.length * 0.4).ceil();
  return chars ~/ 4 + overhead;
}

int _blocksChars(Object content) {
  if (content is String) return content.length;
  var chars = 0;
  for (final block in content as List<ContentBlock>) {
    switch (block) {
      case TextContent(:final text):
        chars += text.length;
      case ThinkingContent(:final thinking):
        chars += thinking.length;
      case ToolCall(:final name, :final arguments):
        chars += name.length + _jsonLen(arguments);
      case ImageContent():
        chars += 4800; // the flat estimate: 4800 chars ≈ 1200 tokens
      case VideoContent(:final data):
        chars += data.length;
      default:
        break;
    }
  }
  return chars;
}

int _jsonLen(Object? value) {
  try {
    return jsonEncode(value ?? '').length;
  } on Object {
    return '$value'.length;
  }
}
