import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// Issue #503 round 3b: the resume boundary walk pays a full jsonDecode +
/// isolate transfer for every `model_request_summary` monster (~0.75 MB
/// each, hundreds per marathon session) even though those records count
/// ZERO context tokens. In shallow mode the walk parses only the header
/// (type/id/parentId/timestamp/customType) and stubs `data` to null.
void main() {
  const iso = '2026-01-01T00:00:00.000Z';

  String customLine(String id, String? parent, int dataSize) {
    return jsonEncode({
      'type': 'custom',
      'id': id,
      'parentId': parent,
      'timestamp': iso,
      'customType': 'model_request_summary',
      'data': {'blob': 'x' * dataSize},
    });
  }

  SessionRecord? parseOne(String line, {required bool shallow}) {
    final batch = SessionParseBatch(
      filePath: '/s.jsonl',
      firstLineNumber: 2,
      lines: [line],
      shallowGiantCustoms: shallow,
    );
    return parseSessionEntryLinesSync(batch).records.single;
  }

  group('shallow giant custom parse (walk path)', () {
    test('a giant custom record decodes header-only, data stubbed to null', () {
      final line = customLine('m0', 'e0', 200 * 1024);
      final record = parseOne(line, shallow: true);
      expect(record, isA<CustomRecord>());
      final custom = record! as CustomRecord;
      expect(custom.id, 'm0');
      expect(custom.parentId, 'e0');
      expect(custom.customType, 'model_request_summary');
      expect(custom.timestamp, DateTime.parse(iso));
      expect(custom.data, isNull);
    });

    test('shallow mode leaves small custom records fully decoded', () {
      final line = customLine('m0', 'e0', 100);
      final record = parseOne(line, shallow: true) as CustomRecord;
      expect(record.data, isNotNull);
      expect((record.data! as Map)['blob'], 'x' * 100);
    });

    test('default (non-shallow) mode always fully decodes, even giants', () {
      final line = customLine('m0', 'e0', 200 * 1024);
      final record = parseOne(line, shallow: false) as CustomRecord;
      expect((record.data! as Map)['blob'], hasLength(200 * 1024));
    });

    test('a foreign field order falls back to a full decode', () {
      // data BEFORE customType — the header scan can't trust the prefix.
      final line =
          '{"type":"custom","id":"m0","parentId":"e0","timestamp":"$iso",'
          '"data":{"blob":"${'x' * (200 * 1024)}"},'
          '"customType":"model_request_summary"}';
      final record = parseOne(line, shallow: true) as CustomRecord;
      expect(record.customType, 'model_request_summary');
      expect(record.data, isNotNull);
    });

    test('a giant custom record without a data key decodes fully', () {
      final line = jsonEncode({
        'type': 'custom',
        'id': 'm0',
        'parentId': null,
        'timestamp': iso,
        'customType': 'x' * (200 * 1024), // giant, but not via data
      });
      final record = parseOne(line, shallow: true) as CustomRecord;
      expect(record.customType, hasLength(200 * 1024));
    });

    test('custom_message giants are NEVER shallow-parsed (they project)', () {
      final line = jsonEncode({
        'type': 'custom_message',
        'id': 'cm0',
        'parentId': null,
        'timestamp': iso,
        'customType': 'note',
        'content': [
          {'type': 'text', 'text': 'y' * (200 * 1024)},
        ],
        'display': false,
      });
      final record = parseOne(line, shallow: true);
      expect(record, isA<CustomMessageRecord>());
      final content = (record! as CustomMessageRecord).content;
      final blocks = content as List<ContentBlock>;
      expect((blocks.single as TextContent).text, hasLength(200 * 1024));
    });

    test('message records are never shallow-parsed either', () {
      final line = jsonEncode({
        'type': 'message',
        'id': 'e0',
        'parentId': null,
        'timestamp': iso,
        'message': {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'z' * (200 * 1024)},
          ],
        },
      });
      final record = parseOne(line, shallow: true);
      expect(record, isA<MessageRecord>());
    });
  });
}
