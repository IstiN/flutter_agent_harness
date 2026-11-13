/// Provider error text compaction, moved out of the `agent_cli.dart`
/// library (was in its `agent_cli_io.dart` part) so pure modules like
/// `key_status.dart` can import it: a `part` file cannot be imported
/// directly.
///
/// Also hosts the console-line failure classifier (issue #2119): the four
/// user-facing categories — content filter / rate limit / network / stall —
/// reuse the ladders' own taxonomy functions, so a rewording upstream can
/// never drop a class out of the console classification silently.
library;

import 'dart:convert';

import '../providers/stall_taxonomy.dart' show classifyProviderStall;
import '../providers/transient_retry_stream.dart'
    show matchesRateLimitWording, matchesTransientNetworkWording;
import '../types.dart' show classifyFinishReason, FinishReasonClass;

/// Reduces a provider error blob to something readable on one line:
/// unwraps OpenRouter's `metadata.raw` upstream JSON recursively, prefers
/// the most specific message, and caps the result at 300 chars.
String compactProviderError(String message) {
  Map<String, dynamic>? decodeJson(String text) {
    final start = text.indexOf('{');
    if (start < 0) return null;
    try {
      final decoded = jsonDecode(text.substring(start));
      return decoded is Map<String, dynamic> ? decoded : null;
    } on Object {
      return null;
    }
  }

  String? extract(Map<String, dynamic> json) {
    final error = json['error'];
    if (error is! Map<String, dynamic>) return null;
    final metadata = error['metadata'];
    if (metadata is Map<String, dynamic>) {
      final raw = metadata['raw'];
      if (raw is String) {
        final upstream = decodeJson(raw);
        final upstreamMessage = upstream == null ? null : extract(upstream);
        if (upstreamMessage != null) {
          final provider = metadata['provider_name'];
          return provider is String
              ? '$upstreamMessage ($provider)'
              : upstreamMessage;
        }
      }
    }
    final msg = error['message'];
    return msg is String && msg.isNotEmpty ? msg : null;
  }

  var result = message;
  final json = decodeJson(message);
  final extracted = json == null ? null : extract(json);
  if (extracted != null) {
    final code = RegExp(r'^\d{3}').firstMatch(message)?.group(0);
    result = '${code != null ? '$code: ' : ''}$extracted';
  }
  if (result.length > 300) result = '${result.substring(0, 300)}…';
  return result;
}

/// The user-facing failure categories a provider error can render as
/// (issue #2119). Mirrors the retry ladders' own classes — [classifyProviderStall]
/// owns stalls, [classifyFinishReason] owns finish_reason words,
/// [matchesRateLimitWording] owns quota — so console classification and
/// retry policy can never disagree about what a failure was.
enum ProviderErrorCategory {
  /// The provider's content filter refused the response (the terminal
  /// finish_reason family). Never retried — replaying a filter is unsafe.
  contentFilter,

  /// Quota / rate limit (429 wordings). A retry window applies.
  rateLimit,

  /// Wire-level failure: transport drops, gateway 5xx, the transient
  /// finish_reason family (`network_error`).
  network,

  /// Alive-but-silence: connect / first-byte / mid-stream idle stall
  /// (the gh-1395 taxonomy).
  stall,

  /// Nothing matched — passthrough keeps today's raw text (never a wrong
  /// category).
  unclassified,
}

/// One classified provider failure: the category, the single-line console
/// text (category → human text → one matching recovery action), and the
/// dedup key two renders of the SAME failure share.
final class ClassifiedProviderError {
  const ClassifiedProviderError._(this.category, this.consoleLine, this.key);

  /// The matched category.
  final ProviderErrorCategory category;

  /// The full classified console line, `error: `-prefixed (the headless
  /// line grammar — issue #2119 AC5 — is untouched; only the human text
  /// after the prefix is classified).
  final String consoleLine;

  /// The dedup identity: two failures with the same key render once per
  /// episode (a run between user prompts).
  final String key;
}

/// The `Retry-After` hint a provider may quote inline (`retry after 12
/// seconds`, `try again in 30s`, `retry after 2 hours`). The structured
/// header rides ErrorEvents only and never reaches the rendered
/// AssistantMessage, so the console hint parses the text. Known units map
/// to s/m/h factors (word-anchored: `m\b` cannot swallow the `m` of
/// `months`, and the bare `s` of the first revision cannot swallow the
/// `s` of `hours`); any OTHER trailing unit word (`days`, `weeks`) is
/// captured as unknown and OMITS the time claim entirely — a wrong unit
/// claim is worse than none (issue #2119 review round 2). A bare number
/// (no unit — header-style) is seconds by the header's own unit.
final RegExp _retryAfterPattern = RegExp(
  r'(?:retry.?after|try again in)[:\s]*(\d+)\s*'
  r'(?:(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b|([a-z]+))?',
  caseSensitive: false,
);

/// The parsed `Retry-After` display, or null when the text carries no
/// parseable hint OR names an unknown unit (`2 days`) — no claim beats a
/// wrong claim.
String? _parseRetryAfter(String text) {
  final hint = _retryAfterPattern.firstMatch(text);
  final value = hint?.group(1);
  if (value == null) return null;
  final amount = int.parse(value);
  final knownUnit = hint?.group(2);
  // Group 3 is a captured-but-UNKNOWN unit word (`days`, `weeks`): the
  // known-word alternation plus word boundary rejected it — claim nothing.
  if (knownUnit == null) {
    return hint?.group(3) != null ? null : _formatDuration(amount);
  }
  final factor = switch (knownUnit[0].toLowerCase()) {
    'h' => 3600,
    'm' => 60,
    _ => 1,
  };
  return _formatDuration(amount * factor);
}

/// Renders a retry budget honestly at its own scale: hour-scale hints
/// print hours (`~2h`, `~1.5h`), minute-scale minutes (`~10m`, `~1.7m` —
/// one decimal, never a raw float), the rest seconds — never a
/// `3600s`-style bare-second dump.
String _formatDuration(int totalSeconds) {
  String trim(double v) {
    final fixed = v.toStringAsFixed(1);
    return fixed.endsWith('.0') ? fixed.substring(0, fixed.length - 2) : fixed;
  }

  if (totalSeconds >= 3600) return '~${trim(totalSeconds / 3600)}h';
  if (totalSeconds >= 60) return '~${trim(totalSeconds / 60)}m';
  return '~${totalSeconds}s';
}

/// Classifies a raw provider error message into the console category and
/// one-line text (issue #2119 AC2), reusing the ladders' taxonomy.
///
/// Precedence mirrors the retry ladders: stall first (its wording is
/// tag-pinned), then rate limit (a 429 may quote transport-ish phrases —
/// the guard set wins upstream of them), then the `Provider finish_reason:`
/// family ([classifyFinishReason]: terminal → content filter, transient →
/// network), then the transport wordings. Everything else stays
/// [ProviderErrorCategory.unclassified] — today's raw text, never a wrong
/// category.
///
/// [provider]/[model] name the serving endpoint in the line when known.
ClassifiedProviderError classifyProviderFailure(
  String rawMessage, {
  String? provider,
  String? model,
}) {
  final endpoint = (provider == null || model == null)
      ? ''
      : ' ($provider/$model)';

  String line(String category, String cause, String recovery) =>
      'error: $category: $cause$endpoint — $recovery';

  final compact = compactProviderError(rawMessage);

  final stall = classifyProviderStall(rawMessage);
  if (stall != null) {
    return ClassifiedProviderError._(
      ProviderErrorCategory.stall,
      line(
        'stall',
        'the provider stopped responding (${stall.label})',
        '/restart starts a fresh run, esc aborts',
      ),
      '${ProviderErrorCategory.stall.name}:$compact',
    );
  }

  if (matchesRateLimitWording(compact)) {
    final hint = _parseRetryAfter(compact);
    final wait = hint == null ? '' : ' — retry after $hint';
    return ClassifiedProviderError._(
      ProviderErrorCategory.rateLimit,
      line(
        'rate limit',
        'the provider quota window is exhausted',
        'wait it out or switch provider/model$wait',
      ),
      '${ProviderErrorCategory.rateLimit.name}:$compact',
    );
  }

  // The `Provider finish_reason: <word>` family — the same wording
  // [finishReasonRetryClass] keys on, so console and policy agree.
  if (rawMessage.startsWith('Provider finish_reason: ')) {
    final raw = rawMessage.substring('Provider finish_reason: '.length).trim();
    final reasonClass = classifyFinishReason(raw);
    if (reasonClass == FinishReasonClass.terminal) {
      return ClassifiedProviderError._(
        ProviderErrorCategory.contentFilter,
        line(
          'content filter',
          "the provider's content filter blocked this response",
          'rephrase the request or switch models',
        ),
        '${ProviderErrorCategory.contentFilter.name}:$compact',
      );
    }
    if (reasonClass == FinishReasonClass.transient) {
      return ClassifiedProviderError._(
        ProviderErrorCategory.network,
        line(
          'network',
          'the provider reported a network-level failure',
          'check connectivity; transient failures replay automatically',
        ),
        '${ProviderErrorCategory.network.name}:$compact',
      );
    }
    // Unknown finish_reason word: unclassified passthrough (never a wrong
    // category — the #312 cataloguing hook owns the vocabulary).
    return ClassifiedProviderError._(
      ProviderErrorCategory.unclassified,
      'error: $compact',
      '${ProviderErrorCategory.unclassified.name}:$compact',
    );
  }

  if (matchesTransientNetworkWording(compact)) {
    return ClassifiedProviderError._(
      ProviderErrorCategory.network,
      line(
        'network',
        'the provider connection failed',
        'check connectivity; transient failures replay automatically',
      ),
      '${ProviderErrorCategory.network.name}:$compact',
    );
  }

  return ClassifiedProviderError._(
    ProviderErrorCategory.unclassified,
    'error: $compact',
    '${ProviderErrorCategory.unclassified.name}:$compact',
  );
}
