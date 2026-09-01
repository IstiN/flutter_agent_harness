/// Provider error text compaction, moved out of the `agent_cli.dart`
/// library (was in its `agent_cli_io.dart` part) so pure modules like
/// `key_status.dart` can import it: a `part` file cannot be imported
/// directly.
library;

import 'dart:convert';

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
