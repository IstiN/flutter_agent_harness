import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  late MemoryFileSystem fs;
  const path = '/sessions/s.jsonl';

  setUp(() {
    fs = MemoryFileSystem();
  });

  SessionChunkReader reader() => SessionChunkReader(fs: fs, path: path);

  MessageRecord userRecord(String id, {String text = 'hi'}) => MessageRecord(
    id: id,
    parentId: null,
    timestamp: DateTime.utc(2026, 1, 1),
    message: UserMessage.text(text),
  );

  Future<void> writeFile(String content) async {
    final result = await fs.appendFile(path, content);
    result.getOrThrow();
  }

  Future<void> writeLines(List<Object> lines) =>
      writeFile('${lines.map(jsonEncode).join('\n')}\n');

  group('SessionChunkReader.readRecordsByIds (issue #385 F4)', () {
    test('resolves the wanted ids from a raw file in one pass', () async {
      final u1 = userRecord('u1');
      final u2 = userRecord('u2', text: 'hidden work');
      final u3 = userRecord('u3');
      await writeLines([u1.toJson(), u2.toJson(), u3.toJson()]);
      final found = await reader().readRecordsByIds({'u3', 'u1'});
      expect(found.keys, unorderedEquals(['u1', 'u3']));
      expect(found['u3'], isA<MessageRecord>());
    });

    test('missing ids stay absent and missing files resolve empty', () async {
      final u1 = userRecord('u1');
      await writeLines([u1.toJson()]);
      final found = await reader().readRecordsByIds({'u1', 'ghost'});
      expect(found.keys, ['u1']);
      expect(
        await SessionChunkReader(
          fs: fs,
          path: '/sessions/absent.jsonl',
        ).readRecordsByIds({'u1'}),
        isEmpty,
      );
    });

    test('an empty id set short-circuits without reading', () async {
      final u1 = userRecord('u1');
      await writeLines([u1.toJson()]);
      expect(await reader().readRecordsByIds(const <String>{}), isEmpty);
    });

    test('torn and foreign lines degrade around the drill-in (E6)', () async {
      final u1 = userRecord('u1');
      final u2 = userRecord('u2', text: 'kept');
      await writeLines([
        u1.toJson(),
        {'torn': true}, // parseable JSON, not a session record
        u2.toJson(),
      ]);
      // And a genuinely torn line in the middle.
      await writeFile(
        '${jsonEncode(u1.toJson())}\n{"id":\n${jsonEncode(u2.toJson())}\n',
      );
      final found = await reader().readRecordsByIds({'u1', 'u2'});
      expect(found.keys, unorderedEquals(['u1', 'u2']));
    });
  });

  group('SessionChunkReader.readBlockBefore (issue #503 boundary walk)', () {
    const header =
        '{"type":"session","version":3,"id":"s",'
        '"timestamp":"2026-01-01T00:00:00.000Z","cwd":"/work"}';

    /// Writes header + records, returns the byte offset of each line start
    /// (header at index 0).
    Future<List<int>> writeWithOffsets(List<String> bodies) async {
      final lines = [header, ...bodies];
      final offsets = <int>[];
      var cursor = 0;
      for (final line in lines) {
        offsets.add(cursor);
        cursor += utf8.encode(line).length + 1; // + the newline
      }
      await writeFile('${lines.join('\n')}\n');
      return offsets;
    }

    String body(String id, {String? parentId, int pad = 0}) {
      final record = MessageRecord(
        id: id,
        parentId: parentId,
        timestamp: DateTime.utc(2026, 1, 1),
        message: UserMessage.text('x' * pad),
      );
      return jsonEncode(record.toJson());
    }

    test('reads the whole strip above the anchor, header dropped', () async {
      final offsets = await writeWithOffsets([
        body('a'),
        body('b', parentId: 'a'),
        body('c', parentId: 'b'),
        body('d', parentId: 'c'),
      ]);
      // Anchor at 'd': the block covers header + a + b + c.
      final chunk = await reader().readBlockBefore(
        offsets[4],
        maxRecords: 100,
        maxBytes: 1 << 20,
      );
      expect([for (final e in chunk.entries) e.record.id], ['a', 'b', 'c']);
      expect(chunk.hasOlder, isFalse); // file top reached
      expect(chunk.firstOffset, offsets[1]);
      expect(chunk.limitOffset, offsets[4]);
    });

    test('a byte-bound strip keeps the NEWEST records and hasOlder', () async {
      final offsets = await writeWithOffsets([
        body('a', pad: 64),
        body('b', parentId: 'a', pad: 64),
        body('c', parentId: 'b', pad: 64),
        body('d', parentId: 'c', pad: 64),
      ]);
      final recordBytes = offsets[3] - offsets[2];
      // Room for the two records above the anchor plus a few bytes of the
      // one above them (a strip start mid-record drops the partial tail).
      final chunk = await reader().readBlockBefore(
        offsets[4],
        maxRecords: 100,
        maxBytes: 2 * recordBytes + 7,
      );
      expect([for (final e in chunk.entries) e.record.id], ['b', 'c']);
      expect(chunk.hasOlder, isTrue);
      expect(chunk.firstOffset, offsets[2]);
    });

    test(
      'a record cap trims to the newest records and keeps hasOlder',
      () async {
        final offsets = await writeWithOffsets([
          body('a'),
          body('b', parentId: 'a'),
          body('c', parentId: 'b'),
          body('d', parentId: 'c'),
        ]);
        final chunk = await reader().readBlockBefore(
          offsets[4],
          maxRecords: 2,
          maxBytes: 1 << 20,
        );
        expect([for (final e in chunk.entries) e.record.id], ['b', 'c']);
        expect(chunk.hasOlder, isTrue);
        expect(chunk.firstOffset, offsets[2]);
      },
    );

    test(
      'a record wider than the strip widens the block until it fits',
      () async {
        final offsets = await writeWithOffsets([
          body('a'),
          body('big', parentId: 'a', pad: 512),
          body('c', parentId: 'big'),
        ]);
        // Anchor at 'c'; the strip starts too small to hold the 'big' line.
        final chunk = await reader().readBlockBefore(
          offsets[3],
          maxRecords: 100,
          maxBytes: 64,
        );
        expect([for (final e in chunk.entries) e.record.id], ['a', 'big']);
        expect(chunk.hasOlder, isFalse);
        expect(chunk.firstOffset, offsets[1]);
      },
    );

    test('anchor clamps to EOF and a zero anchor reads nothing', () async {
      final offsets = await writeWithOffsets([body('a'), body('b')]);
      final fileBytes = offsets.last + utf8.encode(body('b')).length + 1;
      final atEof = await reader().readBlockBefore(
        fileBytes + 4096,
        maxRecords: 100,
        maxBytes: 1 << 20,
      );
      expect([for (final e in atEof.entries) e.record.id], ['a', 'b']);
      expect(atEof.hasOlder, isFalse);
      final atZero = await reader().readBlockBefore(
        0,
        maxRecords: 100,
        maxBytes: 1 << 20,
      );
      expect(atZero.entries, isEmpty);
      expect(atZero.hasOlder, isFalse);
    });

    test('a missing file surfaces notFound', () async {
      await expectLater(
        SessionChunkReader(
          fs: fs,
          path: '/sessions/absent.jsonl',
        ).readBlockBefore(128, maxRecords: 10, maxBytes: 128),
        throwsA(
          isA<SessionException>().having(
            (e) => e.code,
            'code',
            SessionErrorCode.notFound,
          ),
        ),
      );
    });
  });
}
