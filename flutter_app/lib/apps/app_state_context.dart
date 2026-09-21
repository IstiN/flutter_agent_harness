// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// Bounded context injection for in-app Fa messages (issue #692 C+D).
///
/// When the user talks to Fa from inside a JS app, the host forwards their
/// text plus the app's exported state. Two fixes live here:
///
/// - **Viewport line (C):** the app view captures its logical size,
///   orientation and safe areas so the agent designs generated UI for the
///   real canvas instead of guessing desktop dimensions (the "Карточка
///   продуктивности" row clipped at the right edge was dimension-blind
///   output).
/// - **State budget (D):** the state JSON is capped at
///   [appStateContextMaxBytes] — the same budgeted rule project-context
///   uses (`projectContextMaxBytes`). An oversized state folds to top-level
///   keys with type/size and short value previews instead of spending 82 KB
///   of context per turn; the fold is always announced, never silent.
library;

import 'dart:convert';

import 'package:flutter/material.dart';

/// Maximum UTF-8 byte length of the app-state block injected into a user
/// message. Oversized states fold to keys + previews (issue #692 D).
const int appStateContextMaxBytes = 8 * 1024;

/// Longest single value preview rendered by the fold (chars).
const int _maxPreviewChars = 60;

/// Renders [stateJson] for injection into the agent-bound user message:
/// verbatim while it fits [budget], folded to top-level keys + previews
/// (with an explicit note) once it does not. Invalid or non-object JSON
/// degrades to a hard truncation with a note — never a silent cut.
String formatAppStateContext(
  String stateJson, {
  int budget = appStateContextMaxBytes,
}) {
  final bytes = utf8.encode(stateJson).length;
  if (bytes <= budget) return stateJson;

  Object? decoded;
  try {
    decoded = jsonDecode(stateJson);
  } on FormatException {
    decoded = null;
  }
  if (decoded is! Map) {
    if (decoded == null) {
      return _truncate(stateJson, budget, invalid: true);
    }
    return _truncate(stateJson, budget);
  }
  final entries = decoded.entries.toList();
  final buffer = StringBuffer();
  // The fold note (announced, never silent); the per-key omission count
  // fills in after the loop. The wording stays truthful when not even
  // the first key fits (zero keys listed — the note must not claim keys
  // are shown then).
  String noteFor(int skipped) {
    final shown = entries.length - skipped;
    final keysClause = shown == 0
        ? 'no top-level key fits the remaining budget'
        : 'top-level keys shown'
              '${skipped > 0 ? ' ($shown of ${entries.length})' : ''}';
    return '(app state folded: full JSON is $bytes bytes over the '
        '$budget-byte budget — $keysClause'
        '${skipped > 0 ? ', $skipped key(s) omitted for the budget' : ''}; '
        'ask the user or read the app storage for full values)';
  }

  var skipped = 0;
  for (var i = 0; i < entries.length; i++) {
    final line = '  ${entries[i].key}: ${_describe(entries[i].value)}';
    // Budget the note that would ACTUALLY be emitted if the fold stops
    // here: no omission suffix on the very last key (nothing after it to
    // omit), the suffix included otherwise. Checking the suffix-less
    // noteFor(0) stand-in let the emitted note overflow the budget by
    // the suffix length (~33 B).
    final noteOnBreak = noteFor(
      i == entries.length - 1 ? 0 : entries.length - i,
    );
    if (utf8.encode('$buffer$line\n$noteOnBreak').length > budget) {
      skipped = entries.length - i;
      break;
    }
    buffer.writeln(line);
  }
  buffer.write(noteFor(skipped));
  return buffer.toString();
}

/// One fold line's value description: kind, size and a short preview for
/// scalars.
String _describe(Object? value) {
  if (value == null) return 'null';
  if (value is bool) return value.toString();
  if (value is num) return value.toString();
  if (value is String) {
    return value.length <= _maxPreviewChars
        ? '"${value.replaceAll('\n', ' ')}"'
        : '"${value.substring(0, _maxPreviewChars)}…" '
              '(${value.length} chars)';
  }
  if (value is List) {
    final encoded = jsonEncode(value);
    return encoded.length <= _maxPreviewChars
        ? encoded
        : '[list: ${value.length} item(s), ${encoded.length} B]';
  }
  if (value is Map) {
    final encoded = jsonEncode(value);
    return encoded.length <= _maxPreviewChars
        ? encoded
        : '{object: ${value.length} key(s), ${encoded.length} B}';
  }
  return value.runtimeType.toString();
}

String _truncate(String text, int budget, {bool invalid = false}) {
  final kind = invalid ? 'unparseable' : 'non-object';
  final note =
      '\n(app state truncated: $kind JSON exceeded the $budget-byte '
      'budget)';
  final room = budget - note.length - 1;
  var cut = text.length;
  while (utf8.encode(text.substring(0, cut)).length > room && cut > 0) {
    cut = (cut * 0.9).floor();
  }
  return '${text.substring(0, cut)}$note';
}

/// One-line viewport summary for the agent-bound message (issue #692 C):
/// logical size, orientation and safe areas of the surface the generated
/// UI must fit.
String viewportContextLine({
  required Size size,
  required Orientation orientation,
  required EdgeInsets safeAreas,
}) {
  final rot = orientation == Orientation.portrait ? 'portrait' : 'landscape';
  return 'Viewport: ${size.width.round()}x${size.height.round()} logical '
      'px, $rot, safe areas LTRB '
      '${safeAreas.left.round()}/${safeAreas.top.round()}/'
      '${safeAreas.right.round()}/${safeAreas.bottom.round()} px — design '
      'generated UI and cards to fit this width (logical px), never wider.';
}
