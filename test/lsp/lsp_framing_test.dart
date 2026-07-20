@Timeout(Duration(seconds: 10))
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('LspMessageFramer', () {
    test('decodes a single complete message in one chunk', () {
      final framer = LspMessageFramer();
      framer.push(LspMessageFramer.encode('{"jsonrpc":"2.0","id":1}'));
      expect(framer.drain(), ['{"jsonrpc":"2.0","id":1}']);
      expect(framer.remainder(), isEmpty);
    });

    test('decodes a message split across chunks', () {
      final framer = LspMessageFramer();
      final bytes = LspMessageFramer.encode('{"a":"b","c":[1,2,3]}');
      final chunks = <List<int>>[
        bytes.sublist(0, 5), // mid-header
        bytes.sublist(5, 20),
        bytes.sublist(20, bytes.length - 3), // mid-body
        bytes.sublist(bytes.length - 3),
      ];
      final messages = <String>[];
      for (final chunk in chunks) {
        framer.push(chunk);
        messages.addAll(framer.drain());
      }
      expect(messages, ['{"a":"b","c":[1,2,3]}']);
    });

    test('decodes multiple messages in one chunk', () {
      final framer = LspMessageFramer();
      final combined = [
        ...LspMessageFramer.encode('{"id":1}'),
        ...LspMessageFramer.encode('{"id":2}'),
      ];
      framer.push(combined);
      expect(framer.drain(), ['{"id":1}', '{"id":2}']);
    });

    test('resyncs past a junk header block', () {
      final framer = LspMessageFramer();
      final resynced = <String>[];
      final combined = [
        ...utf8.encode('noise from a wrapper script\r\n\r\n'),
        ...LspMessageFramer.encode('{"ok":true}'),
      ];
      framer.push(combined);
      final messages = framer.drain(onResync: resynced.add);
      expect(resynced, ['noise from a wrapper script']);
      expect(messages, ['{"ok":true}']);
    });

    test('tolerates extra headers (Content-Type)', () {
      final framer = LspMessageFramer();
      const body = '{"id":7}';
      final message =
          'Content-Length: ${utf8.encode(body).length}\r\n'
          'Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n'
          '\r\n'
          '$body';
      framer.push(utf8.encode(message));
      expect(framer.drain(), [body]);
    });

    test('remainder preserves a partial message for a restarted reader', () {
      final framer = LspMessageFramer();
      final bytes = LspMessageFramer.encode('{"partial":1}');
      framer.push(bytes.sublist(0, bytes.length - 5));
      expect(framer.drain(), isEmpty);

      final restarted = LspMessageFramer(framer.remainder());
      restarted.push(bytes.sublist(bytes.length - 5));
      expect(restarted.drain(), ['{"partial":1}']);
    });

    test('encode produces Content-Length framing', () {
      final encoded = utf8.decode(LspMessageFramer.encode('{}'));
      expect(encoded, 'Content-Length: 2\r\n\r\n{}');
    });
  });
}
