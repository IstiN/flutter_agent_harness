/// The segment-close log line (gh-1241 surface 2): one `fa-tokens:` line
/// per closed segment keeps the dmtools-agents dashboard's log-grepping
/// reporter (`js/aiTeammateTokenUsageReporter.js`) alive with a one-line
/// parser change — the reporter greps for [usageTokensLogPrefix] and
/// JSON-parses the rest, so the payload is compact single-line JSON with
/// the documented key order.
///
/// [usageTokensLogPattern] is the PINNED fixture (IT-7/AC7): the test
/// suite asserts every emitted line matches it, so the external parser
/// can rely on the shape without running fa.
library;

import 'dart:convert';

import 'usage_ledger.dart';

/// The exact prefix the reporter greps for.
const String usageTokensLogPrefix = 'fa-tokens: ';

/// The pinned one-line shape (AC7): every field documented in gh-1241,
/// compact JSON, fixed key order. `source` is the segment's marker (I3).
final RegExp usageTokensLogPattern = RegExp(
  r'^fa-tokens: \{"sessionId":"[^"]*","segment":[0-9]+,'
  r'"input":[0-9]+,"output":[0-9]+,"cacheRead":[0-9]+,'
  r'"requests":[0-9]+,"source":"(reported|estimated|mixed)"\}$',
);

/// Builds the segment-close line for [segment] of [sessionId] — compact,
/// key order fixed, matching [usageTokensLogPattern] by construction.
String usageTokensLogLine({
  required String sessionId,
  required UsageSegment segment,
}) =>
    '$usageTokensLogPrefix${jsonEncode({
      'sessionId': sessionId,
      'segment': segment.index,
      'input': segment.totals.input,
      'output': segment.totals.output,
      'cacheRead': segment.totals.cacheRead,
      'requests': segment.totals.requests,
      'source': segment.source.wire,
    })}';
