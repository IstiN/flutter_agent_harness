import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

import 'flaky_session_fs.dart';

final chatGptModel = Model(
  id: 'gpt-5-codex',
  api: 'responses',
  provider: 'chatgpt',
  baseUrl: chatGptCodexBaseUrl,
  input: const ['text'],
  contextWindow: 128000,
  maxTokens: 16384,
);

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
        final healedLines = (await fs.readTextFile(
          path,
        )).getOrThrow().split('\n')..removeLast();
        expect(healedLines, hasLength(3)); // header + e1 + e2
        for (final line in healedLines.skip(1)) {
          jsonDecode(line); // throws on any remaining garbage
        }

        // A second open sees a clean file and keeps accepting appends.
        final clean = await JsonlSessionStorage.open(fs, path);
        expect(clean.quarantinedEntries, 0);
        await clean.appendEntry(msg('e3', 'e2', 'again'));
        final finalOpen = await JsonlSessionStorage.open(fs, path);
        expect((await finalOpen.getEntries()).map((e) => e.id), [
          'e1',
          'e2',
          'e3',
        ]);
      },
    );

    test(
      'concurrent appends serialize into whole lines in submit order',
      () async {
        final storage = await createStorage();
        const total = 40;
        await Future.wait([
          for (var i = 0; i < total; i++)
            storage.appendEntry(
              msg('c$i', i == 0 ? null : 'c${i - 1}', 'p$i ${'x' * (i * 31)}'),
            ),
        ]);

        final reopened = await JsonlSessionStorage.open(fs, path);
        expect((await reopened.getEntries()).map((e) => e.id), [
          for (var i = 0; i < total; i++) 'c$i',
        ]);
        // Every persisted line is complete JSON — writers never interleave.
        for (final line in (await fs.readTextFile(
          path,
        )).getOrThrow().split('\n')) {
          if (line.isEmpty) continue;
          jsonDecode(line); // throws on a torn line
        }
      },
    );

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

    test('getPathToRoot walks a branch; unknown ids fail loudly (#1114)',
        () async {
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

    test('getPathToRoot stops at a dangling parentId (partial path)', () async {
      await createStorage();
      await fs.appendFile(
        path,
        '${jsonEncode({'type': 'message', 'id': 'orphan', 'parentId': 'ghost', 'timestamp': DateTime.utc(2026).toIso8601String(), 'message': UserMessage.text('x').toJson()})}\n',
      );
      final storage = await JsonlSessionStorage.open(fs, path);
      // A missing parent is a hole (torn write, hard-cap truncation), not
      // a fatal corruption: the walk returns the partial path, matching
      // the windowed storage's behavior at the window edge.
      final pathToRoot = await storage.getPathToRoot('orphan');
      expect(pathToRoot.map((e) => e.id), ['orphan']);
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

    test(
      'open quarantines a corrupt entry line (JSON garbage) mid-file',
      () async {
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
        expect(
          (await fs.readTextFile('$path.corrupt')).getOrThrow().trim(),
          '{broken json',
        );
        expect((await storage.getEntries()).map((e) => e.id), ['l1']);
      },
    );

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

  group('JsonlSessionStorage segment rotation', () {
    late MemoryFileSystem fs;
    const path = '/sessions/r.jsonl';
    const rotate = 200;
    const hardCap = 400;

    setUp(() {
      fs = MemoryFileSystem();
    });

    Future<JsonlSessionStorage> createRotating() {
      return JsonlSessionStorage.create(
        fs,
        path,
        cwd: '/work',
        sessionId: 'r1',
      ).then(
        (storage) => storage.withRotationLimits(
          rotateBytes: rotate,
          hardCapBytes: hardCap,
        ),
      );
    }

    JsonlSessionStorage rotating(JsonlSessionStorage storage) =>
        storage.withRotationLimits(rotateBytes: rotate, hardCapBytes: hardCap);

    MessageRecord msg(String id, String? parentId, String text) =>
        MessageRecord(
          id: id,
          parentId: parentId,
          timestamp: DateTime.utc(2026),
          message: UserMessage.text(text),
        );

    test(
      'rotate: oversized primary moves to .part-0001, primary reseeds',
      () async {
        final storage = await createRotating();
        await storage.appendEntry(
          MessageRecord(
            id: 'e1',
            parentId: null,
            timestamp: DateTime.utc(2026),
            message: UserMessage.text('x' * 220),
          ),
        );
        // The big record pushed the primary past the rotate threshold; the
        // NEXT append rotates it away first.
        await storage.appendEntry(
          MessageRecord(
            id: 'e2',
            parentId: 'e1',
            timestamp: DateTime.utc(2026),
            message: UserMessage.text('e2'),
          ),
        );
        final primary = (await fs.readTextFile(path)).getOrThrow();
        expect(
          primary.contains('"e2"'),
          isTrue,
          reason: 'active record in primary',
        );
        final part = (await fs.readTextFile('$path.part-0001')).getOrThrow();
        expect(part.contains('"e1"'), isTrue, reason: 'old segment archived');
        expect(
          part.startsWith('{'),
          isTrue,
          reason: 'part keeps a header copy',
        );
      },
    );

    test('reopen loads parts + primary as one record chain', () async {
      final storage = await createRotating();
      await storage.appendEntry(
        MessageRecord(
          id: 'e1',
          parentId: null,
          timestamp: DateTime.utc(2026),
          message: UserMessage.text('x' * 220),
        ),
      );
      await storage.appendEntry(
        MessageRecord(
          id: 'e2',
          parentId: 'e1',
          timestamp: DateTime.utc(2026),
          message: UserMessage.text('e2'),
        ),
      );
      final reopened = await JsonlSessionStorage.open(fs, path);
      expect((await reopened.getEntries()).map((e) => e.id), ['e1', 'e2']);
      expect(await reopened.getLeafId(), 'e2');
      // The whole parent chain resolves across the segment boundary.
      final chain = await reopened.getPathToRoot('e2');
      expect(chain.map((e) => e.id), ['e1', 'e2']);
    });

    test('rotation continues after reopen (no part overwrite)', () async {
      final storage = await createRotating();
      await storage.appendEntry(
        MessageRecord(
          id: 'e1',
          parentId: null,
          timestamp: DateTime.utc(2026),
          message: UserMessage.text('x' * 220),
        ),
      );
      await storage.appendEntry(
        MessageRecord(
          id: 'e2',
          parentId: 'e1',
          timestamp: DateTime.utc(2026),
          message: UserMessage.text('e2'),
        ),
      );
      final reopened = rotating(await JsonlSessionStorage.open(fs, path));
      await reopened.appendEntry(
        MessageRecord(
          id: 'e3',
          parentId: 'e2',
          timestamp: DateTime.utc(2026),
          message: UserMessage.text('x' * 220),
        ),
      );
      await reopened.appendEntry(
        MessageRecord(
          id: 'e4',
          parentId: 'e3',
          timestamp: DateTime.utc(2026),
          message: UserMessage.text('e4'),
        ),
      );
      final part1 = (await fs.readTextFile('$path.part-0001')).getOrThrow();
      final part2 = (await fs.readTextFile('$path.part-0002')).getOrThrow();
      expect(part1.contains('"e1"'), isTrue);
      expect(part2.contains('"e2"'), isTrue);
      final reopened2 = await JsonlSessionStorage.open(fs, path);
      expect((await reopened2.getEntries()).map((e) => e.id).toList(), [
        'e1',
        'e2',
        'e3',
        'e4',
      ]);
    });

    test(
      'hard cap: oldest records dropped with a warning, append never fails',
      () async {
        final warnings = <String>[];
        final oldWarn = JsonlSessionStorage.onRotationWarning;
        JsonlSessionStorage.onRotationWarning = warnings.add;
        try {
          final storage = await createRotating();
          await storage.appendEntry(
            MessageRecord(
              id: 'big1',
              parentId: null,
              timestamp: DateTime.utc(2026),
              message: UserMessage.text('a' * 300),
            ),
          );
          // hardCap 400: the big record + header already sit above the cap
          // band once a similar record lands; the cap must truncate the
          // OLDEST records instead of failing.
          await storage.appendEntry(
            MessageRecord(
              id: 'big2',
              parentId: 'big1',
              timestamp: DateTime.utc(2026),
              message: UserMessage.text('b' * 300),
            ),
          );
          final primary = (await fs.readTextFile(path)).getOrThrow();
          expect(
            primary.contains('"big2"'),
            isTrue,
            reason: 'the newest record survives the cap',
          );
          expect(warnings, isNotEmpty, reason: 'truncation surfaces a warning');
        } finally {
          JsonlSessionStorage.onRotationWarning = oldWarn;
        }
      },
    );

    test('no rotation below the thresholds', () async {
      final storage = await createRotating().then(
        (s) => s.withRotationLimits(rotateBytes: 10240, hardCapBytes: 20480),
      );
      await storage.appendEntry(
        MessageRecord(
          id: 'small1',
          parentId: null,
          timestamp: DateTime.utc(2026),
          message: UserMessage.text('small'),
        ),
      );
      await storage.appendEntry(
        MessageRecord(
          id: 'small2',
          parentId: 'small1',
          timestamp: DateTime.utc(2026),
          message: UserMessage.text('small too'),
        ),
      );
      expect((await fs.exists('$path.part-0001')).getOrThrow(), isFalse);
      final storage2 = await JsonlSessionStorage.open(fs, path);
      expect((await storage2.getEntries()).map((e) => e.id), [
        'small1',
        'small2',
      ]);
    });

    /// Encoded on-disk size (UTF-8 bytes + the newline) of a record —
    /// keeps the cap arithmetic below stable when the record schema
    /// gains a field.
    int encodedRecordBytes(SessionRecord r) =>
        utf8.encode(jsonEncode(r.toJson())).length + 1;

    Future<int> headerBytes() async =>
        utf8.encode((await fs.readTextFile(path)).getOrThrow()).length;

    test(
      'hard cap truncation keeps the parent chain walkable after reopen',
      () async {
        final warnings = <String>[];
        final oldWarn = JsonlSessionStorage.onRotationWarning;
        JsonlSessionStorage.onRotationWarning = warnings.add;
        try {
          final base = await JsonlSessionStorage.create(
            fs,
            path,
            cwd: '/work',
            sessionId: 'r1',
          );
          final r1 = msg('r1', null, 'x' * 220);
          final r2 = msg('r2', 'r1', 'y' * 220);
          final r3 = msg('r3', 'r2', 'z' * 220);
          final r4 = msg('r4', 'r3', 'w' * 220);
          // header + 4 records exceed the cap; header + the newest 3
          // fit — the truncation drops r1 mid-segment.
          final s = encodedRecordBytes(r1);
          final storage = base.withRotationLimits(
            rotateBytes: 10 * 1024 * 1024,
            hardCapBytes: await headerBytes() + 3 * s + 5,
          );
          await storage.appendEntry(r1);
          await storage.appendEntry(r2);
          await storage.appendEntry(r3);
          await storage.appendEntry(r4);
          expect(
            warnings.where((w) => w.contains('hard cap')),
            isNotEmpty,
            reason: 'the cap must have truncated the active segment',
          );
          // The in-memory index is pruned in step with the rewrite —
          // a stale index masked the severed chain until the next open.
          expect((await storage.getEntries()).map((e) => e.id), [
            'r2',
            'r3',
            'r4',
          ]);
          expect(await storage.getLeafId(), 'r4');
          // The partial chain resolves instead of crashing the resume
          // (getBranch is on the agent loop's hot path).
          final chain = await storage.getPathToRoot('r4');
          expect(chain.map((e) => e.id), ['r2', 'r3', 'r4']);
          // …and a fresh open agrees.
          final reopened = await JsonlSessionStorage.open(fs, path);
          expect((await reopened.getEntries()).map((e) => e.id), [
            'r2',
            'r3',
            'r4',
          ]);
          expect((await reopened.getPathToRoot('r4')).map((e) => e.id), [
            'r2',
            'r3',
            'r4',
          ]);
          expect(await reopened.getLeafId(), 'r4');
        } finally {
          JsonlSessionStorage.onRotationWarning = oldWarn;
        }
      },
    );

    test('failed rotation seed does not duplicate records on reopen', () async {
      final warnings = <String>[];
      final oldWarn = JsonlSessionStorage.onRotationWarning;
      JsonlSessionStorage.onRotationWarning = warnings.add;
      try {
        final base = await JsonlSessionStorage.create(
          fs,
          path,
          cwd: '/work',
          sessionId: 'r1',
        );
        await base.appendEntry(msg('e1', null, 'x' * 220));
        final flaky = FlakySessionFs(fs);
        final storage = (await JsonlSessionStorage.open(
          flaky,
          path,
        )).withRotationLimits(rotateBytes: 200, hardCapBytes: 1 << 20);
        // Every header-only write to the primary (the rotation seed)
        // fails; the multi-line restore write still lands.
        flaky.failWritesWhere = (p, content) =>
            p == path && !content.trim().contains('\n');
        await storage.appendEntry(msg('e2', 'e1', 'e2'));
        expect(
          warnings.where((w) => w.contains('restored')),
          isNotEmpty,
          reason: 'the restore path ran',
        );
        // The stale part is an exact copy of the restored primary —
        // deleting it would bypass the AC3 session-deletion gate, so
        // the open path dedupes repeated record ids across segments…
        expect((await fs.exists('$path.part-0001')).getOrThrow(), isTrue);
        final reopened = await JsonlSessionStorage.open(fs, path);
        expect((await reopened.getEntries()).map((e) => e.id), ['e1', 'e2']);
        // …and the open-time rewrite scrubs the duplicated lines, so the
        // NEXT open is clean too.
        final again = await JsonlSessionStorage.open(fs, path);
        expect((await again.getEntries()).map((e) => e.id), ['e1', 'e2']);
      } finally {
        JsonlSessionStorage.onRotationWarning = oldWarn;
      }
    });

    test('hard cap still applies when the rotation itself fails', () async {
      final warnings = <String>[];
      final oldWarn = JsonlSessionStorage.onRotationWarning;
      JsonlSessionStorage.onRotationWarning = warnings.add;
      try {
        final base = await JsonlSessionStorage.create(
          fs,
          path,
          cwd: '/work',
          sessionId: 'r1',
        );
        final r1 = msg('r1', null, 'x' * 220);
        final r2 = msg('r2', 'r1', 'y' * 220);
        final r3 = msg('r3', 'r2', 'z' * 220);
        final s = encodedRecordBytes(r1);
        // header + 3 records exceed the cap; header + 2 fit — a working
        // cap must drop r1 even though the rotation below fails.
        final hardCap = await headerBytes() + 2 * s + 5;
        await base.appendEntry(r1);
        await base.appendEntry(r2);
        final flaky = FlakySessionFs(fs);
        final storage = (await JsonlSessionStorage.open(
          flaky,
          path,
        )).withRotationLimits(rotateBytes: 1, hardCapBytes: hardCap);
        flaky.failWritesWhere = (p, _) => p.contains('.part-');
        await storage.appendEntry(r3);
        expect(
          warnings.where((w) => w.contains('hard cap')),
          isNotEmpty,
          reason: 'the cap applies to the un-rotated segment',
        );
        final ids = (await JsonlSessionStorage.open(
          fs,
          path,
        )).getEntries().then((es) => es.map((e) => e.id).toList());
        expect(await ids, ['r2', 'r3']);
      } finally {
        JsonlSessionStorage.onRotationWarning = oldWarn;
      }
    });

    test(
      'open heals a primary lost mid-rotation (crash between rename and seed)',
      () async {
        final base = await JsonlSessionStorage.create(
          fs,
          path,
          cwd: '/work',
          sessionId: 'r1',
        );
        await base.appendEntry(msg('e1', null, 'e1'));
        // The crash window: the segment was archived to the part, the
        // fresh primary was never seeded.
        final segment = (await fs.readTextFile(path)).getOrThrow();
        (await fs.writeFile('$path.part-0001', segment)).getOrThrow();
        (await fs.remove(path)).getOrThrow();

        final reopened = await JsonlSessionStorage.open(fs, path);
        expect((await reopened.getEntries()).map((e) => e.id), ['e1']);
        // …and the healed primary accepts appends again.
        await reopened.appendEntry(msg('e2', 'e1', 'e2'));
        final again = await JsonlSessionStorage.open(fs, path);
        expect((await again.getEntries()).map((e) => e.id), ['e1', 'e2']);
        expect((await again.getPathToRoot('e2')).map((e) => e.id), [
          'e1',
          'e2',
        ]);
      },
    );

    test('open heals a header-less primary left by a racing append', () async {
      final base = await JsonlSessionStorage.create(
        fs,
        path,
        cwd: '/work',
        sessionId: 'r1',
      );
      await base.appendEntry(msg('e1', null, 'e1'));
      final segment = (await fs.readTextFile(path)).getOrThrow();
      (await fs.writeFile('$path.part-0001', segment)).getOrThrow();
      // A writer in another process recreated the primary with a bare
      // append: a record line, no header.
      final e2line = jsonEncode(msg('e2', 'e1', 'e2').toJson());
      (await fs.writeFile(path, '$e2line\n')).getOrThrow();

      final reopened = await JsonlSessionStorage.open(fs, path);
      // The header is restored and the raced record is kept.
      expect((await reopened.getEntries()).map((e) => e.id), ['e1', 'e2']);
      expect((await reopened.getPathToRoot('e2')).map((e) => e.id), [
        'e1',
        'e2',
      ]);
    });

    test(
      'a failed part listing suspends rotation instead of overwriting parts',
      () async {
        final storage = await createRotating();
        await storage.appendEntry(msg('e1', null, 'x' * 220));
        await storage.appendEntry(msg('e2', 'e1', 'e2'));
        final partBefore = (await fs.readTextFile(
          '$path.part-0001',
        )).getOrThrow();

        // The open cannot see the parts: a blind sequence reset would
        // retarget part-0001 and destroy it (rename overwrites).
        final flaky = FlakySessionFs(fs)..failNextListings = 1 << 30;
        final reopened = (await JsonlSessionStorage.open(
          flaky,
          path,
        )).withRotationLimits(rotateBytes: 200, hardCapBytes: 1 << 20);
        await reopened.appendEntry(msg('e3', 'e2', 'x' * 220));
        await reopened.appendEntry(msg('e4', 'e3', 'e4'));
        expect(
          (await fs.readTextFile('$path.part-0001')).getOrThrow(),
          partBefore,
          reason: 'the existing part survives a blind open',
        );
        expect((await fs.exists('$path.part-0002')).getOrThrow(), isFalse);
      },
    );

    test('a fileInfo failure degrades rotation to the plain append', () async {
      final flaky = FlakySessionFs(fs)..failNextFileInfos = 1 << 30;
      final storage = (await JsonlSessionStorage.create(
        flaky,
        path,
        cwd: '/work',
        sessionId: 'r1',
      )).withRotationLimits(rotateBytes: 1, hardCapBytes: 1 << 20);
      // The stat behind the size check never lands: rotation is skipped
      // (the documented degradation), the record itself is not lost.
      await storage.appendEntry(msg('e1', null, 'x' * 220));
      await storage.appendEntry(msg('e2', 'e1', 'e2'));
      expect((await fs.exists('$path.part-0001')).getOrThrow(), isFalse);
      final reopened = await JsonlSessionStorage.open(fs, path);
      expect((await reopened.getEntries()).map((e) => e.id), ['e1', 'e2']);
    });

    test(
      'failed rotation with a failed restore still never loses the append',
      () async {
        final warnings = <String>[];
        final oldWarn = JsonlSessionStorage.onRotationWarning;
        JsonlSessionStorage.onRotationWarning = warnings.add;
        try {
          final base = await JsonlSessionStorage.create(
            fs,
            path,
            cwd: '/work',
            sessionId: 'r1',
          );
          await base.appendEntry(msg('e1', null, 'x' * 220));
          final flaky = FlakySessionFs(fs);
          final storage = (await JsonlSessionStorage.open(
            flaky,
            path,
          )).withRotationLimits(rotateBytes: 200, hardCapBytes: 1 << 20);
          // EVERY primary write fails: the rotation seed AND the restore.
          flaky.failWritesWhere = (p, _) => p == path;
          await storage.appendEntry(msg('e2', 'e1', 'e2'));
          expect(
            warnings.where((w) => w.contains('missing a header')),
            isNotEmpty,
            reason: 'the unrecoverable rotation warns',
          );
          // The append landed on a header-less primary; the open heal
          // (parts exist) restores the header and keeps every record.
          flaky.failWritesWhere = null;
          final reopened = await JsonlSessionStorage.open(fs, path);
          expect((await reopened.getEntries()).map((e) => e.id), ['e1', 'e2']);
        } finally {
          JsonlSessionStorage.onRotationWarning = oldWarn;
        }
      },
    );

    test('size math counts UTF-8 bytes, not UTF-16 code units', () async {
      final warnings = <String>[];
      final oldWarn = JsonlSessionStorage.onRotationWarning;
      JsonlSessionStorage.onRotationWarning = warnings.add;
      try {
        final base = await JsonlSessionStorage.create(
          fs,
          path,
          cwd: '/work',
          sessionId: 'r1',
        );
        final c1 = msg('c1', null, '界' * 60);
        final c2 = msg('c2', 'c1', '界' * 60);
        final c3 = msg('c3', 'c2', '界' * 60);
        final bytes = encodedRecordBytes(c1);
        final units = jsonEncode(c1.toJson()).length + 1;
        expect(bytes, greaterThan(units), reason: 'CJK costs 3 bytes/char');
        // Between the UTF-16 total and the UTF-8 total: only exact byte
        // math sees the overflow.
        final hardCap = await headerBytes() + 2 * bytes + units + 10;
        await base.appendEntry(c1);
        await base.appendEntry(c2);
        final storage = base.withRotationLimits(
          rotateBytes: 1 << 20,
          hardCapBytes: hardCap,
        );
        await storage.appendEntry(c3);
        expect(
          warnings.where((w) => w.contains('hard cap')),
          isNotEmpty,
          reason: 'the byte-exact cap fires',
        );
        final ids = (await JsonlSessionStorage.open(
          fs,
          path,
        )).getEntries().then((es) => es.map((e) => e.id).toList());
        expect(await ids, isNot(contains('c1')));
        expect(await ids, contains('c3'));
      } finally {
        JsonlSessionStorage.onRotationWarning = oldWarn;
      }
    });

    test(
      'windowed open reads only the active segment (documented boundary)',
      () async {
        final storage = await createRotating();
        await storage.appendEntry(msg('e1', null, 'x' * 220));
        await storage.appendEntry(msg('e2', 'e1', 'e2'));
        // The windowed/chat path is bound to the primary file: history
        // archived in .part-NN segments is NOT pageable through it
        // (loadOlder stops at the segment boundary). Full-chain reads
        // go through JsonlSessionStorage.open / readCustomRecordsOfType.
        final windowed = await WindowedSessionStorage.open(fs, path);
        expect((await windowed.getEntries()).map((e) => e.id), ['e2']);
        expect(windowed.hasOlder, isFalse);
      },
    );

    test('a fresh session file carries header version 3', () async {
      await createRotating();
      final content = (await fs.readTextFile(path)).getOrThrow();
      final header =
          jsonDecode(content.split('\n').first) as Map<String, dynamic>;
      expect(header['version'], 3);
    });

    test('rotation marks every segment header with the rotated-format '
        'version so older builds fail with a clear error', () async {
      final storage = await createRotating();
      await storage.appendEntry(msg('e1', null, 'x' * 220));
      await storage.appendEntry(msg('e2', 'e1', 'e2'));
      // gh-1077 review round 5: a rotated session is a new on-disk
      // format for pre-rotation builds (they read only the primary and
      // crash on the severed chain). The header version marker rides
      // verbatim into every segment, so an old binary fails at header
      // parse with "unsupported session version" instead of a
      // chain-walk SessionException that looks like corruption.
      for (final p in [path, '$path.part-0001']) {
        final content = (await fs.readTextFile(p)).getOrThrow();
        final header =
            jsonDecode(content.split('\n').first) as Map<String, dynamic>;
        expect(header['version'], greaterThan(3), reason: '$p marked');
      }
      // This build still opens the rotated session fine.
      final reopened = await JsonlSessionStorage.open(fs, path);
      expect((await reopened.getEntries()).map((e) => e.id), ['e1', 'e2']);
    });

    test('SessionHeader.fromJson accepts the rotated-format version and '
        'rejects unknown versions', () {
      Map<String, dynamic> headerJson(int version) => {
        'type': 'session',
        'version': version,
        'id': 's1',
        'timestamp': DateTime.utc(2026).toIso8601String(),
        'cwd': '/work',
      };
      expect(SessionHeader.fromJson(headerJson(3)).id, 's1');
      expect(
        SessionHeader.fromJson(headerJson(SessionHeader.rotatedVersion)).id,
        's1',
      );
      expect(
        () => SessionHeader.fromJson(headerJson(99)),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('unsupported session version'),
          ),
        ),
      );
      // The old-build contract this marker relies on: a build that only
      // knows version 3 rejects the rotated header outright.
      expect(headerJson(SessionHeader.rotatedVersion)['version'] != 3, isTrue);
    });

    test(
      'open exposes the primary header, not the oldest segment header',
      () async {
        final storage = await createRotating();
        await storage.appendEntry(msg('e1', null, 'x' * 220));
        await storage.appendEntry(msg('e2', 'e1', 'e2'));
        // Rewrite the archived segment's header with a stale cwd (a valid
        // header, just not the primary's): the storage must still expose
        // the primary's header, matching the comment in the open loop.
        final part = (await fs.readTextFile('$path.part-0001')).getOrThrow();
        final lines = part.split('\n');
        final stale = Map<String, dynamic>.from(
          jsonDecode(lines.first) as Map<String, dynamic>,
        );
        stale['cwd'] = '/stale';
        lines[0] = jsonEncode(stale);
        await fs.writeFile('$path.part-0001', lines.join('\n'));

        final reopened = await JsonlSessionStorage.open(fs, path);
        expect(reopened.cachedMetadata.cwd, '/work');
      },
    );

    test('the heal never writes a segment first line that is not a session '
        'header into the primary', () async {
      final storage = await createRotating();
      await storage.appendEntry(msg('e1', null, 'x' * 220));
      await storage.appendEntry(msg('e2', 'e1', 'e2'));
      final partPath = '$path.part-0001';
      // Corrupt the archived segment's first line (external truncation),
      // then knock the primary's header off (racing bare append): the
      // heal must NOT prefix the garbage line into the primary — it
      // degrades to the classic open error instead.
      final part = (await fs.readTextFile(partPath)).getOrThrow();
      final partLines = part.split('\n');
      partLines[0] = '{"definitely":"not a session header"}';
      await fs.writeFile(partPath, partLines.join('\n'));
      final primary = (await fs.readTextFile(path)).getOrThrow();
      final primaryLines = primary.split('\n');
      await fs.writeFile(path, primaryLines.sublist(1).join('\n'));
      final barePrimary = (await fs.readTextFile(path)).getOrThrow();

      await expectLater(
        JsonlSessionStorage.open(fs, path),
        throwsA(isA<SessionException>()),
      );
      expect(
        (await fs.readTextFile(path)).getOrThrow(),
        barePrimary,
        reason: 'the heal left the primary untouched',
      );
    });
  });

  // Issue #858: no replayable history may ever brick a session. Quarantine
  // drops a malformed record, but surviving records still reference it via
  // parentId — the branch walk must stop at the hole instead of failing
  // every future resume (the windowed storage's "stop, never throw"
  // contract).
  group('quarantine never bricks the branch walk (#858)', () {
    /// A message record a pre-#705 / foreign binary could have written:
    /// the assistant content carries a WIRE-style `function_call` part —
    /// not a known [ContentBlock] type, so the line quarantines on open.
    String poisonAssistantLine(String id, String? parentId) => jsonEncode({
      'type': 'message',
      'id': id,
      'parentId': parentId,
      'timestamp': DateTime.utc(2026).toIso8601String(),
      'message': {
        'role': 'assistant',
        'api': 'responses',
        'provider': 'chatgpt',
        'model': 'gpt-5-codex',
        'usage': {'input': 1, 'output': 1, 'totalTokens': 2},
        'stopReason': 'toolUse',
        'timestamp': DateTime.utc(2026).millisecondsSinceEpoch,
        'content': [
          {'type': 'text', 'text': 'checking'},
          {
            'type': 'function_call',
            'call_id': 'call_42',
            'name': 'bash',
            'arguments': '{}',
          },
        ],
      },
    });

    test(
      'a descendant of a quarantined record no longer bricks the resume',
      () async {
        final storage = await createStorage();
        await storage.appendEntry(
          MessageRecord(
            id: 'r0',
            parentId: null,
            timestamp: DateTime.utc(2026),
            message: UserMessage.text('list the files'),
          ),
        );
        // The poison line, then a VALID record parented on it — the shape
        // every post-quarantine open of such a session carries.
        (await fs.appendFile(path, '${poisonAssistantLine('rp', 'r0')}\n'))
            .getOrThrow();
        await storage.appendEntry(
          MessageRecord(
            id: 'r1',
            parentId: 'rp',
            timestamp: DateTime.utc(2026),
            message: UserMessage.text('and the dirs too'),
          ),
        );

        final reopened = await JsonlSessionStorage.open(fs, path);
        expect(reopened.quarantinedEntries, 1);
        expect(await reopened.getLeafId(), 'r1');

        // Pre-fix this threw `Entry rp not found` — a permanent brick: the
        // rewrite had already dropped rp, so EVERY later open failed.
        final session = Session(reopened);
        final messages = await session.buildContextMessages();
        expect(messages, hasLength(1));
        expect(messages.single, isA<UserMessage>());

        // The surviving context converts grammar-valid for the responses
        // wire — the poisoned record never re-enters the payload.
        expect(
          firstResponsesGrammarViolation(responsesInputItems(messages)),
          isNull,
        );
      },
    );

    test('a dangling LeafRecord target falls back to the newest record',
        () async {
      final storage = await createStorage();
      await storage.appendEntry(
        MessageRecord(
          id: 'r0',
          parentId: null,
          timestamp: DateTime.utc(2026),
          message: UserMessage.text('hello'),
        ),
      );
      (await fs.appendFile(path, '${poisonAssistantLine('rp', 'r0')}\n'))
          .getOrThrow();
      // A navigation leaf whose target is the record about to quarantine.
      await storage.appendEntry(
        LeafRecord(
          id: 'L1',
          parentId: 'r0',
          timestamp: DateTime.utc(2026),
          targetId: 'rp',
        ),
      );

      final reopened = await JsonlSessionStorage.open(fs, path);
      expect(reopened.quarantinedEntries, 1);
      // The heal is surfaced, not silent — same convention as quarantine.
      expect(reopened.healedLeafEntries, 1);
      // The tracked leaf dangled ('rp' quarantined); load healed it to the
      // newest surviving record — the LeafRecord itself.
      expect(await reopened.getLeafId(), 'L1');
      final session = Session(reopened);
      final messages = await session.buildContextMessages();
      expect(messages, hasLength(1));
    });

    test('a parentId cycle terminates the walk instead of spinning',
        () async {
      final storage = await createStorage();
      // An adversarial/foreign-authored file can carry a cycle; appendEntry
      // does not validate tree shape, so it is reachable through the API.
      await storage.appendEntry(
        MessageRecord(
          id: 'a',
          parentId: 'b',
          timestamp: DateTime.utc(2026),
          message: UserMessage.text('a'),
        ),
      );
      await storage.appendEntry(
        MessageRecord(
          id: 'b',
          parentId: 'a',
          timestamp: DateTime.utc(2026),
          message: UserMessage.text('b'),
        ),
      );

      final reopened = await JsonlSessionStorage.open(fs, path);
      // Terminates bounded by the record count; never spins, never throws.
      final walked = await reopened.getPathToRoot('a');
      expect(walked.length, lessThanOrEqualTo(3));
    });

    test(
      'poison-typed session resumes a full turn without any JSONL rewrite',
      () async {
        // The pre-#705 session: typed records authored under the old
        // converter, ending with a compaction whose cut falls EXACTLY
        // between a function_call and its output (E4) — the kept region
        // opens with an orphan tool result.
        final storage = await createStorage();
        await storage.appendEntry(
          MessageRecord(
            id: 'r0',
            parentId: null,
            timestamp: DateTime.utc(2026),
            message: UserMessage.text('list the files'),
          ),
        );
        await storage.appendEntry(
          MessageRecord(
            id: 'r1',
            parentId: 'r0',
            timestamp: DateTime.utc(2026),
            message: AssistantMessage(
              content: const [
                TextContent(text: 'Checking.'),
                ToolCall(id: 'call_42', name: 'bash', arguments: {'cmd': 'ls'}),
              ],
              api: 'responses',
              provider: 'chatgpt',
              model: 'gpt-5-codex',
              usage: Usage.zero,
              stopReason: StopReason.toolUse,
              timestamp: DateTime.utc(2026),
            ),
          ),
        );
        await storage.appendEntry(
          MessageRecord(
            id: 'r2',
            parentId: 'r1',
            timestamp: DateTime.utc(2026),
            message: ToolResultMessage(
              toolCallId: 'call_42',
              toolName: 'bash',
              content: const [TextContent(text: 'file.txt')],
              isError: false,
              timestamp: DateTime.utc(2026),
            ),
          ),
        );
        await storage.appendEntry(
          CompactionRecord(
            id: 'c1',
            parentId: 'r2',
            timestamp: DateTime.utc(2026),
            summary: 'Earlier: the user asked for files and bash listed them.',
            firstKeptEntryId: 'r2',
            tokensBefore: 10,
          ),
        );

        final before = (await fs.readTextFile(path)).getOrThrow();

        final reopened = await JsonlSessionStorage.open(fs, path);
        final session = Session(reopened);
        final messages = await session.buildContextMessages();

        // E4: the cut leaves an orphan function_call_output — emitted
        // TOP-LEVEL (a valid item slot), never as a message content part.
        final input = responsesInputItems(messages);
        expect(firstResponsesGrammarViolation(input), isNull);
        expect(
          [
            for (final item in input)
              if (item['type'] == 'function_call_output') item,
          ],
          hasLength(1),
        );

        // The resumed turn completes against a fake Responses stream…
        final client = http_testing.MockClient.streaming((request, body) async {
          return http.StreamedResponse(
            Stream.value(utf8.encode(
              'data: ${jsonEncode({
                'type': 'response.completed',
                'response': {'id': 'r', 'model': 'gpt-5-codex'},
              })}\n\n',
            )),
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        });
        final events = await streamChatGptCodex(
          chatGptModel,
          Context(messages: messages),
          credentials: const ChatGptOAuthCredentials(
            accessToken: 'at-1',
            refreshToken: 'rt-1',
            idToken: 'it-1',
            accountId: 'acc-1',
          ).encode(),
          client: client,
        ).toList();
        expect(events.last, isA<DoneEvent>());

        // …and the transcript is byte-identical: repair is outbound-only.
        expect((await fs.readTextFile(path)).getOrThrow(), before);
      },
    );
  });
}
