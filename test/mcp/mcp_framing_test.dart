/// Tests for the MCP stdio line framer: newline-delimited JSON across chunk
/// boundaries, CRLF tolerance, blank-line skipping, and the encode/decode
/// round-trip.
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('McpLineFramer', () {
    test('decodes complete lines and keeps a partial tail', () {
      final framer = McpLineFramer();
      framer.push(utf8.encode('{"a":1}\n{"b":'));
      expect(framer.drain(), ['{"a":1}']);
      framer.push(utf8.encode('2}\n'));
      expect(framer.drain(), ['{"b":2}']);
      expect(framer.drain(), isEmpty);
    });

    test('skips blank lines and tolerates CRLF', () {
      final framer = McpLineFramer();
      framer.push(utf8.encode('\n{"a":1}\r\n\n{"b":2}\n'));
      expect(framer.drain(), ['{"a":1}', '{"b":2}']);
    });

    test('handles a message split mid-UTF-8-sequence', () {
      const text = '{"emoji":"héllo"}';
      final bytes = McpLineFramer.encode(text);
      final framer = McpLineFramer();
      // Split inside the multibyte é (0xC3 0xA9).
      final splitAt = bytes.indexOf(0xC3) + 1;
      framer.push(bytes.sublist(0, splitAt));
      expect(framer.drain(), isEmpty);
      framer.push(bytes.sublist(splitAt));
      expect(framer.drain(), [text]);
    });

    test('encode appends exactly one newline', () {
      final encoded = McpLineFramer.encode('{"x":true}');
      expect(utf8.decode(encoded), '{"x":true}\n');
    });

    test('round-trips a batch of messages', () {
      final framer = McpLineFramer();
      final batch = StringBuffer();
      for (var i = 0; i < 5; i++) {
        batch.write(utf8.decode(McpLineFramer.encode('{"i":$i}')));
      }
      framer.push(utf8.encode(batch.toString()));
      expect(framer.drain(), [for (var i = 0; i < 5; i++) '{"i":$i}']);
    });
  });
}
