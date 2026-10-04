// Shared JSONL chain fixtures for the gh-1241 usage-fold tests. Builds the
// raw session-chain lines the fold scans — header, segment markers,
// `model_request_summary` records, assistant message records — the same
// shapes `SessionRecord.toJson` writes.

import 'dart:convert';

/// The session header line.
String sessionHeaderLine(String sessionId) => jsonEncode({
  'type': 'session',
  'version': 3,
  'id': sessionId,
  'timestamp': '2024-01-01T00:00:00.000Z',
  'cwd': '/tmp/usage-fold-test',
});

Map<String, dynamic> _recordBase(int n) => {
  'id': 'r$n',
  'parentId': null,
  // Distinct, MONOTONIC timestamps so ordering assertions can rely on
  // chain order being visible in the artifact's informational stamps.
  'timestamp': '2024-01-01T00:${n.toString().padLeft(2, '0')}:00.000Z',
};

/// One `usage_segment_start` marker (a segment boundary, gh-1241 I1).
String segmentMarkerLine(int n) => jsonEncode({
  ..._recordBase(n),
  'type': 'custom',
  'customType': 'usage_segment_start',
  'data': {'at': '2024-01-01T00:00:00.000Z'},
});

/// One `model_request_summary` custom record with the given outbound
/// message chars (input-estimation basis for the estimated fallback).
String requestSummaryLine(int n, {List<int> messageChars = const [400, 100]}) =>
    jsonEncode({
      ..._recordBase(n),
      'type': 'custom',
      'customType': 'model_request_summary',
      'data': {
        'messageCount': messageChars.length,
        'systemPromptChars': 10,
        'toolCount': 0,
        'toolNames': const <String>[],
        'messages': [
          for (final chars in messageChars)
            {'role': 'user', 'chars': chars, 'preview': 'p'},
        ],
      },
    });

/// Provider-reported usage (non-zero everywhere a real provider reports).
Map<String, dynamic> reportedUsage({
  int input = 100,
  int output = 50,
  int cacheRead = 0,
  int cacheWrite = 0,
  int? reasoning,
}) => {
  'input': input,
  'output': output,
  'cacheRead': cacheRead,
  'cacheWrite': cacheWrite,
  if (reasoning != null) 'reasoning': reasoning,
  'totalTokens': input + output + cacheRead + cacheWrite,
  'cost': const {
    'input': 0.0,
    'output': 0.0,
    'cacheRead': 0.0,
    'cacheWrite': 0.0,
    'total': 0.0,
  },
};

/// Usage as a fake provider that omits usage deserializes to: all zeros.
Map<String, dynamic> get omittedUsage => {
  'input': 0,
  'output': 0,
  'cacheRead': 0,
  'cacheWrite': 0,
  'totalTokens': 0,
  'cost': const {'total': 0.0},
};

/// One assistant `message` record.
String assistantLine(
  int n, {
  String model = 'model-a',
  Map<String, dynamic>? usage,
  List<String> texts = const ['hello world'],
}) => jsonEncode({
  ..._recordBase(n),
  'type': 'message',
  'message': {
    'role': 'assistant',
    'content': [
      for (final text in texts) {'type': 'text', 'text': text},
    ],
    'api': 'test',
    'provider': 'test',
    'model': model,
    'usage': usage ?? reportedUsage(),
    'stopReason': 'stop',
    'timestamp': 1700000000000,
  },
});

/// One user `message` record (must be ignored by the fold).
String userLine(int n, {String text = 'do the thing'}) => jsonEncode({
  ..._recordBase(n),
  'type': 'message',
  'message': {'role': 'user', 'content': text, 'timestamp': 1700000000000},
});

/// A giant blob record the scanner must skip WITHOUT decoding
/// (base64-shaped payload, like a wire dump).
String wireDumpLine(int n, {int payloadKb = 64}) => jsonEncode({
  ..._recordBase(n),
  'type': 'custom',
  'customType': 'trajectory_wire_dump',
  'data': {
    'hash': 'x' * 64,
    'payload': 'A' * (payloadKb * 1024),
    'truncated': false,
  },
});
