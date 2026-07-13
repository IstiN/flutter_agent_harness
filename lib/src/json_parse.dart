/// Shared JSON parsing helpers for provider adapters.
///
/// Ported from pi-mono `packages/ai/src/utils/json-parse.ts`
/// (`parseStreamingJson`, `parseJsonWithRepair`, `repairJson`). Internal to
/// the package: not exported from `flutter_agent_harness.dart`.
///
/// Deliberate divergence from pi: pi's `parseStreamingJson` falls back to the
/// `partial-json` package for truncated JSON; [parseStreamingJson] falls back
/// to an empty map (after a [repairJson] pass), which only matters for
/// truncated final tool-call arguments.
library;

import 'dart:convert';
import 'dart:math';

/// Attempts to parse potentially incomplete tool-call argument JSON.
///
/// Incomplete or unrepairable JSON yields an empty map.
Map<String, dynamic> parseStreamingJson(String partialJson) {
  if (partialJson.trim().isEmpty) {
    return const <String, dynamic>{};
  }
  try {
    final decoded = jsonDecode(partialJson);
    return decoded is Map<String, dynamic>
        ? decoded
        : const <String, dynamic>{};
  } on FormatException {
    try {
      final decoded = jsonDecode(repairJson(partialJson));
      return decoded is Map<String, dynamic>
          ? decoded
          : const <String, dynamic>{};
    } on FormatException {
      return const <String, dynamic>{};
    }
  }
}

/// Parses [text] as JSON, retrying once after a [repairJson] pass.
///
/// Ported from pi's `parseJsonWithRepair`. Unlike [parseStreamingJson] this
/// rethrows the [FormatException] when the repaired text still does not
/// parse — callers turn that into an error event.
Object? parseJsonWithRepair(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    return jsonDecode(repairJson(text));
  }
}

const _validJsonEscapes = {'"', '\\', '/', 'b', 'f', 'n', 'r', 't', 'u'};

bool _isControlCharacter(String char) {
  final codeUnit = char.codeUnitAt(0);
  return codeUnit <= 0x1f;
}

String _escapeControlCharacter(String char) {
  return switch (char) {
    '\b' => r'\b',
    '\f' => r'\f',
    '\n' => r'\n',
    '\r' => r'\r',
    '\t' => r'\t',
    _ => '\\u${char.codeUnitAt(0).toRadixString(16).padLeft(4, '0')}',
  };
}

/// Repairs malformed JSON string literals by escaping raw control characters
/// inside strings and doubling backslashes before invalid escape characters.
///
/// Ported from pi's `repairJson`.
String repairJson(String json) {
  final repaired = StringBuffer();
  var inString = false;

  for (var index = 0; index < json.length; index++) {
    final char = json[index];

    if (!inString) {
      repaired.write(char);
      if (char == '"') {
        inString = true;
      }
      continue;
    }

    if (char == '"') {
      repaired.write(char);
      inString = false;
      continue;
    }

    if (char == '\\') {
      final nextChar = index + 1 < json.length ? json[index + 1] : null;
      if (nextChar == null) {
        repaired.write(r'\\');
        continue;
      }

      if (nextChar == 'u') {
        final unicodeDigits = json.substring(
          index + 2,
          min(index + 6, json.length),
        );
        if (RegExp('^[0-9a-fA-F]{4}\$').hasMatch(unicodeDigits)) {
          repaired.write('\\u$unicodeDigits');
          index += 5;
          continue;
        }
      }

      if (_validJsonEscapes.contains(nextChar)) {
        repaired.write('\\$nextChar');
        index += 1;
        continue;
      }

      repaired.write(r'\\');
      continue;
    }

    repaired.write(
      _isControlCharacter(char) ? _escapeControlCharacter(char) : char,
    );
  }

  return repaired.toString();
}
