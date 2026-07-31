import 'dart:convert';

/// One-line `key=value` rendering of tool-call arguments, capped at 100
/// columns.
String formatArgs(Map<String, dynamic> args) {
  var formatted = args.entries
      .map((entry) => '${entry.key}=${safeJsonEncode(entry.value)}')
      .join(', ');
  if (formatted.length > 100) {
    formatted = '${formatted.substring(0, 100)}...';
  }
  return formatted;
}

/// [jsonEncode] that never throws (cyclic/unserializable values degrade to
/// a placeholder).
String safeJsonEncode(Object? value) {
  try {
    return jsonEncode(value);
  } catch (_) {
    return '[unserializable]';
  }
}
