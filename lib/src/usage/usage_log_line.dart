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
/// gh-1460 adds the OPTIONAL `"model"` key — the segment's last-seen model
/// id, emitted once per segment-close line so every token row is
/// attributable (and priceable) downstream; it is omitted when the fold
/// never saw a model (legacy chains), which keeps old lines parsing and
/// lets this regex keep matching them (the group is optional, and the
/// builder only writes the key when a model exists).
final RegExp usageTokensLogPattern = RegExp(
  r'^fa-tokens: \{"sessionId":"[^"]*","segment":[0-9]+(?:,"model":"[^"]*")?'
  r',"input":[0-9]+,"output":[0-9]+,"cacheRead":[0-9]+,'
  r'"requests":[0-9]+,"source":"(reported|estimated|mixed)"\}$',
);

/// Builds the segment-close line for [segment] of [sessionId] — compact,
/// key order fixed, matching [usageTokensLogPattern] by construction. The
/// optional `"model"` key rides the segment's last-seen model (gh-1460)
/// and is left out entirely when the segment has none (legacy shape).
String usageTokensLogLine({
  required String sessionId,
  required UsageSegment segment,
}) =>
    '$usageTokensLogPrefix${jsonEncode({'sessionId': sessionId, 'segment': segment.index, if (segment.model case final model? when model.isNotEmpty) 'model': model, 'input': segment.totals.input, 'output': segment.totals.output, 'cacheRead': segment.totals.cacheRead, 'requests': segment.totals.requests, 'source': segment.source.wire})}';
