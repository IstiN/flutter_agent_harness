import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// Decodes [chunks] (each string is one arbitrarily-split chunk) into events.
Future<List<ServerSentEvent>> decode(List<String> chunks) {
  return Stream.fromIterable(chunks).transform(const SseDecoder()).toList();
}

void main() {
  group('SseDecoder', () {
    test('parses a simple data-only event', () async {
      final events = await decode(['data: hello\n\n']);
      expect(events, hasLength(1));
      expect(events.single.event, isNull);
      expect(events.single.data, 'hello');
    });

    test('parses event name and data', () async {
      final events = await decode(['event: message_start\ndata: {"a":1}\n\n']);
      expect(events, hasLength(1));
      expect(events.single.event, 'message_start');
      expect(events.single.data, '{"a":1}');
    });

    test('joins multi-line data with newlines', () async {
      final events = await decode(['data: line one\ndata: line two\n\n']);
      expect(events.single.data, 'line one\nline two');
    });

    test('ignores comment lines but keeps them in raw', () async {
      final events = await decode([': heartbeat\ndata: x\n\n']);
      expect(events, hasLength(1));
      expect(events.single.data, 'x');
      expect(events.single.raw, [': heartbeat', 'data: x']);
    });

    test('handles CRLF line endings', () async {
      final events = await decode(['event: a\r\ndata: b\r\n\r\n']);
      expect(events.single.event, 'a');
      expect(events.single.data, 'b');
    });

    test('handles lone CR line endings', () async {
      final events = await decode(['event: a\rdata: b\r\r']);
      expect(events.single.event, 'a');
      expect(events.single.data, 'b');
    });

    test('parses events split across chunks', () async {
      final events = await decode([
        'event: mess',
        'age_start\nda',
        'ta: {"hel',
        'lo": true}\n',
        '\n',
      ]);
      expect(events, hasLength(1));
      expect(events.single.event, 'message_start');
      expect(events.single.data, '{"hello": true}');
    });

    test('chunk boundary between CR and LF of a CRLF pair', () async {
      // The decoder consumes the lone CR as the line break; the LF then
      // terminates an empty line, which flushes the event.
      final events = await decode(['data: x\r', '\ndata: y\n\n']);
      expect(events, hasLength(2));
      expect(events[0].data, 'x');
      expect(events[1].data, 'y');
    });

    test('parses multiple events from one chunk', () async {
      final events = await decode([
        'event: one\ndata: 1\n\nevent: two\ndata: 2\n\n',
      ]);
      expect(events, hasLength(2));
      expect(events[0].event, 'one');
      expect(events[1].event, 'two');
    });

    test('flushes a trailing event without a final blank line', () async {
      final events = await decode(['event: message_stop\ndata: {}\n']);
      expect(events, hasLength(1));
      expect(events.single.event, 'message_stop');
    });

    test('decodes a trailing line without any newline', () async {
      final events = await decode(['data: no-newline']);
      expect(events.single.data, 'no-newline');
    });

    test('yields nothing for an empty stream', () async {
      expect(await decode([]), isEmpty);
    });

    test('yields nothing for comment-only input', () async {
      expect(await decode([': just a heartbeat\n']), isEmpty);
    });

    test('consecutive blank lines do not create empty events', () async {
      final events = await decode(['data: x\n\n\n\n\n']);
      expect(events, hasLength(1));
    });

    test('strips a single leading space from values', () async {
      final events = await decode(['data:   spaced\n\n']);
      expect(events.single.data, '  spaced');
    });

    test('field-less lines are ignored (per SSE spec)', () async {
      final events = await decode(['garbage\ndata: ok\n\n']);
      expect(events.single.data, 'ok');
    });

    test('strips a UTF-8 BOM at the start of the stream (SSE spec)', () async {
      // The SSE spec requires stripping a single leading BOM; without it the
      // first field name decodes as "\uFEFFdata" and the payload is dropped.
      final events = await decode(['\uFEFFdata: ok\n\n']);
      expect(events.single.event, isNull);
      expect(events.single.data, 'ok');
    });

    test('a BOM elsewhere in the stream is NOT stripped', () async {
      // Only the very first character of the stream is a BOM; a later one
      // is ordinary field-name content. The BOM-prefixed line degrades to
      // an unknown field, and following well-formed lines are unaffected.
      final events = await decode(['data: a\n\n\uFEFFjunk: x\ndata: b\n\n']);
      expect(events, hasLength(2));
      expect(events[1].data, 'b');
      expect(events[1].raw, contains('\uFEFFjunk: x'));
    });

    test('a BOM after an empty first chunk is stripped', () async {
      // Upstream decoding (utf8.decoder) always yields the BOM as one char,
      // but it may land in a later chunk after empty leading chunks.
      final events = await decode(['', '', '\uFEFFdata: ok\n\n']);
      expect(events.single.data, 'ok');
    });

    test('unknown fields are ignored', () async {
      final events = await decode(['id: 42\nretry: 1000\ndata: ok\n\n']);
      expect(events.single.event, isNull);
      expect(events.single.data, 'ok');
      expect(events.single.raw, ['id: 42', 'retry: 1000', 'data: ok']);
    });

    test('event with only an event name and no data still flushes', () async {
      final events = await decode(['event: ping\n\n']);
      expect(events.single.event, 'ping');
      expect(events.single.data, '');
    });

    test('later event: line overwrites an earlier one', () async {
      final events = await decode(['event: first\nevent: second\ndata: x\n\n']);
      expect(events.single.event, 'second');
    });
  });
}
