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
}
