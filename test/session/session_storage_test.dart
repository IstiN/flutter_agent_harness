import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  late MemoryFileSystem fs;
  const path = '/sessions/s.jsonl';

  setUp(() {
    fs = MemoryFileSystem();
  });

  Future<JsonlSessionStorage> createStorage() {
    return JsonlSessionStorage.create(
      fs,
      path,
      cwd: '/work',
      sessionId: 's1',
      metadata: const {'k': 'v'},
    );
  }

  group('JsonlSessionStorage', () {
    test('create writes a header line and exposes metadata', () async {
      final storage = await createStorage();
      final metadata = await storage.getMetadata();
      expect(metadata.id, 's1');
      expect(metadata.cwd, '/work');
      expect(metadata.path, path);
      expect(metadata.metadata, {'k': 'v'});
      expect(await storage.getLeafId(), isNull);
      expect(await storage.getEntries(), isEmpty);

      final content = (await fs.readTextFile(path)).getOrThrow();
      final header = jsonDecode(content.trim()) as Map<String, dynamic>;
      expect(header['type'], 'session');
      expect(header['version'], 3);
    });

    test('appendEntry persists JSONL lines that survive reopen', () async {
      final storage = await createStorage();
      await storage.appendEntry(
        MessageRecord(
          id: 'e1',
          parentId: null,
          timestamp: DateTime.utc(2026),
          message: UserMessage.text('hello'),
        ),
      );
      await storage.appendEntry(
        MessageRecord(
          id: 'e2',
          parentId: 'e1',
          timestamp: DateTime.utc(2026),
          message: UserMessage.text('world'),
        ),
      );

      final reopened = await JsonlSessionStorage.open(fs, path);
      final entries = await reopened.getEntries();
      expect(entries.map((e) => e.id), ['e1', 'e2']);
      expect(await reopened.getLeafId(), 'e2');
      final entry = await reopened.getEntry('e1');
      expect((entry as MessageRecord).message.role, 'user');
    });

    test(
      'a torn LAST line (crash mid-append) is dropped, history intact',
      () async {
        final storage = await createStorage();
        await storage.appendEntry(
          MessageRecord(
            id: 'e1',
            parentId: null,
            timestamp: DateTime.utc(2026),
            message: UserMessage.text('hello'),
          ),
        );
        // Simulate a crash mid-append: the final line is truncated JSON.
        (await fs.appendFile(
          path,
          '{"id":"e2","parentId":"e1","timestamp\n',
        )).getOrThrow();

        final reopened = await JsonlSessionStorage.open(fs, path);
        final entries = await reopened.getEntries();
        expect(entries.map((e) => e.id), ['e1']);
        expect(await reopened.getLeafId(), 'e1');

        // …and the file keeps accepting appends after the tear.
        await reopened.appendEntry(
          MessageRecord(
            id: 'e3',
            parentId: 'e1',
            timestamp: DateTime.utc(2026),
            message: UserMessage.text('recovered'),
          ),
        );
        final again = await JsonlSessionStorage.open(fs, path);
        expect((await again.getEntries()).map((e) => e.id), ['e1', 'e3']);
      },
    );

    MessageRecord msg(String id, String? parentId, String text) =>
        MessageRecord(
          id: id,
          parentId: parentId,
          timestamp: DateTime.utc(2026),
          message: UserMessage.text(text),
        );

    test(
      'a torn MID-FILE line is quarantined: the session always opens',
      () async {
        final storage = await createStorage();
        await storage.appendEntry(msg('e1', null, 'hello'));
        // Corrupt + a valid record after it: the bad line is NOT the last
        // one (two racing writers left a hole mid-file).
        (await fs.appendFile(
          path,
          '{"id":"torn","parentId":"e1"\n',
        )).getOrThrow();
        await storage.appendEntry(msg('e2', 'e1', 'world'));

        final reopened = await JsonlSessionStorage.open(fs, path);
        expect((await reopened.getEntries()).map((e) => e.id), ['e1', 'e2']);
        expect(reopened.quarantinedEntries, 1);
        expect(await reopened.getLeafId(), 'e2');

        // The raw bytes survive in a sidecar for forensics…
        final sidecar = (await fs.readTextFile('$path.corrupt')).getOrThrow();
        expect(sidecar.trim(), '{"id":"torn","parentId":"e1"');

        // …and the main file was rewritten without the tear: every line
        // past the header is valid JSON again.
        final healedLines =
            (await fs.readTextFile(path)).getOrThrow().split('\n')
              ..removeLast();
        expect(healedLines, hasLength(3)); // header + e1 + e2
        for (final line in healedLines.skip(1)) {
          jsonDecode(line); // throws on any remaining garbage
        }

        // A second open sees a clean file and keeps accepting appends.
        final clean = await JsonlSessionStorage.open(fs, path);
        expect(clean.quarantinedEntries, 0);
        await clean.appendEntry(msg('e3', 'e2', 'again'));
        final finalOpen = await JsonlSessionStorage.open(fs, path);
        expect(
          (await finalOpen.getEntries()).map((e) => e.id),
          ['e1', 'e2', 'e3'],
        );
      },
    );

    test('concurrent appends serialize into whole lines in submit order', () async {
      final storage = await createStorage();
      const total = 40;
      await Future.wait([
        for (var i = 0; i < total; i++)
          storage.appendEntry(
            msg('c$i', i == 0 ? null : 'c${i - 1}', 'p$i ${'x' * (i * 31)}'),
          ),
      ]);

      final reopened = await JsonlSessionStorage.open(fs, path);
      expect(
        (await reopened.getEntries()).map((e) => e.id),
        [for (var i = 0; i < total; i++) 'c$i'],
      );
      // Every persisted line is complete JSON — writers never interleave.
      for (final line in (await fs.readTextFile(path)).getOrThrow().split('\n')) {
        if (line.isEmpty) continue;
        jsonDecode(line); // throws on a torn line
      }
    });

    test('setLeafId appends a leaf record and validates the target', () async {
      final storage = await createStorage();
      await storage.appendEntry(
        MessageRecord(
          id: 'e1',
          parentId: null,
          timestamp: DateTime.utc(2026),
          message: UserMessage.text('a'),
        ),
      );
      await storage.appendEntry(
        MessageRecord(
          id: 'e2',
          parentId: 'e1',
          timestamp: DateTime.utc(2026),
          message: UserMessage.text('b'),
        ),
      );
      await storage.setLeafId('e1');
      expect(await storage.getLeafId(), 'e1');

      final reopened = await JsonlSessionStorage.open(fs, path);
      expect(await reopened.getLeafId(), 'e1');
      final leaf = await reopened.getEntry(
        (await reopened.getEntries()).last.id,
      );
      expect(leaf, isA<LeafRecord>());

      expect(
        () => storage.setLeafId('ghost'),
        throwsA(
          isA<SessionException>().having(
            (e) => e.code,
            'code',
            SessionErrorCode.notFound,
          ),
        ),
      );
    });

    test('createEntryId returns unique 8-char ids', () async {
      final storage = await createStorage();
      final ids = <String>{};
      for (var i = 0; i < 50; i++) {
        ids.add(await storage.createEntryId());
      }
      expect(ids, hasLength(50));
      expect(ids.every((id) => id.length == 8), isTrue);
    });

    test('labels: set, overwrite, and remove via empty label', () async {
      final storage = await createStorage();
      await storage.appendEntry(
        LabelRecord(
          id: 'l1',
          parentId: null,
          timestamp: DateTime.utc(2026),
          targetId: 'e1',
          label: 'first',
        ),
      );
      expect(await storage.getLabel('e1'), 'first');
      await storage.appendEntry(
        LabelRecord(
          id: 'l2',
          parentId: 'l1',
          timestamp: DateTime.utc(2026),
          targetId: 'e1',
          label: 'second',
        ),
      );
      expect(await storage.getLabel('e1'), 'second');
      await storage.appendEntry(
        LabelRecord(
          id: 'l3',
          parentId: 'l2',
          timestamp: DateTime.utc(2026),
          targetId: 'e1',
        ),
      );
      expect(await storage.getLabel('e1'), isNull);

      final reopened = await JsonlSessionStorage.open(fs, path);
      expect(await reopened.getLabel('e1'), isNull);
    });

    test('findEntries filters by type', () async {
      final storage = await createStorage();
      await storage.appendEntry(
        SessionInfoRecord(
          id: 'i1',
          parentId: null,
          timestamp: DateTime.utc(2026),
          name: 'one',
        ),
      );
      await storage.appendEntry(
        LabelRecord(
          id: 'l1',
          parentId: 'i1',
          timestamp: DateTime.utc(2026),
          targetId: 'i1',
          label: 'x',
        ),
      );
      final infos = await storage.findEntries('session_info');
      expect(infos, hasLength(1));
      expect(infos.single, isA<SessionInfoRecord>());
    });

    test('getPathToRoot walks a branch and validates ids', () async {
      final storage = await createStorage();
      await storage.appendEntry(
        MessageRecord(
          id: 'e1',
          parentId: null,
          timestamp: DateTime.utc(2026),
          message: UserMessage.text('a'),
        ),
      );
      await storage.appendEntry(
        MessageRecord(
          id: 'e2',
          parentId: 'e1',
          timestamp: DateTime.utc(2026),
          message: UserMessage.text('b'),
        ),
      );
      expect((await storage.getPathToRoot(null)), isEmpty);
      expect((await storage.getPathToRoot('e2')).map((e) => e.id), [
        'e1',
        'e2',
      ]);
      expect(
        () => storage.getPathToRoot('ghost'),
        throwsA(
          isA<SessionException>().having(
            (e) => e.code,
            'code',
            SessionErrorCode.notFound,
          ),
        ),
      );
    });

    test('getPathToRoot fails on a dangling parentId', () async {
      await createStorage();
      await fs.appendFile(
        path,
        '${jsonEncode({'type': 'message', 'id': 'orphan', 'parentId': 'ghost', 'timestamp': DateTime.utc(2026).toIso8601String(), 'message': UserMessage.text('x').toJson()})}\n',
      );
      final storage = await JsonlSessionStorage.open(fs, path);
      expect(
        () => storage.getPathToRoot('orphan'),
        throwsA(
          isA<SessionException>().having(
            (e) => e.code,
            'code',
            SessionErrorCode.invalidSession,
          ),
        ),
      );
    });

    test('open rejects a missing file as storage error', () async {
      expect(
        () => JsonlSessionStorage.open(fs, '/sessions/missing.jsonl'),
        throwsA(
          isA<SessionException>().having(
            (e) => e.code,
            'code',
            SessionErrorCode.notFound,
          ),
        ),
      );
    });

    test('open rejects an empty file (missing header)', () async {
      await fs.writeFile(path, '');
      expect(
        () => JsonlSessionStorage.open(fs, path),
        throwsA(
          isA<SessionException>().having(
            (e) => e.code,
            'code',
            SessionErrorCode.invalidSession,
          ),
        ),
      );
    });

    test('open rejects a corrupt header line', () async {
      await fs.writeFile(path, 'not json\n');
      expect(
        () => JsonlSessionStorage.open(fs, path),
        throwsA(
          isA<SessionException>().having(
            (e) => e.code,
            'code',
            SessionErrorCode.invalidSession,
          ),
        ),
      );
    });

    test('open quarantines a corrupt entry line (JSON garbage) mid-file', () async {
      await createStorage();
      await fs.appendFile(path, '{broken json\n');
      // A trailing valid record makes the corrupt one MID-file: a hole left
      // by racing writers. The open still succeeds and heals the file.
      await fs.appendFile(
        path,
        '${jsonEncode({'type': 'label', 'id': 'l1', 'parentId': null, 'timestamp': DateTime.utc(2026).toIso8601String(), 'targetId': 'x', 'label': 'y'})}\n',
      );
      final storage = await JsonlSessionStorage.open(fs, path);
      expect(storage.quarantinedEntries, 1);
      expect((await fs.readTextFile('$path.corrupt')).getOrThrow().trim(), '{broken json');
      expect((await storage.getEntries()).map((e) => e.id), ['l1']);
    });

    test('open quarantines an entry line missing required fields', () async {
      await createStorage();
      await fs.appendFile(path, '${jsonEncode({'type': 'label'})}\n');
      // Same mid-file setup: the incomplete record is not the last line.
      await fs.appendFile(
        path,
        '${jsonEncode({'type': 'label', 'id': 'l1', 'parentId': null, 'timestamp': DateTime.utc(2026).toIso8601String(), 'targetId': 'x', 'label': 'y'})}\n',
      );
      final storage = await JsonlSessionStorage.open(fs, path);
      expect(storage.quarantinedEntries, 1);
      expect((await storage.getEntries()).map((e) => e.id), ['l1']);
    });

    test('open skips blank lines', () async {
      await createStorage();
      await fs.appendFile(path, '\n   \n');
      final storage = await JsonlSessionStorage.open(fs, path);
      expect(await storage.getEntries(), isEmpty);
    });

    test('loadJsonlSessionMetadata reads only the header', () async {
      await createStorage();
      final metadata = await loadJsonlSessionMetadata(fs, path);
      expect(metadata.id, 's1');
      expect(metadata.cwd, '/work');
    });
  });
}
