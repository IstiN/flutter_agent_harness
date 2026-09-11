import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// A [FileSystem] that tallies how many bytes each read strategy touched —
/// the O(window)-not-O(file) proof for issue #135.
final class CountingFileSystem implements FileSystem, RangedReadFileSystem {
  CountingFileSystem(this.delegate);

  final FileSystem delegate;

  /// Bytes moved by ranged (seek) reads — the windowed path.
  int rangedBytes = 0;

  /// Bytes moved by whole-file reads — must stay 0 while windowed.
  int bulkBytes = 0;

  @override
  String get cwd => delegate.cwd;

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      delegate.absolutePath(path);

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      delegate.joinPath(parts);

  @override
  Future<Result<String, FileError>> readTextFile(String path) async {
    final result = await delegate.readTextFile(path);
    if (result.isOk) bulkBytes += result.valueOrNull!.length;
    return result;
  }

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) async {
    final result = await delegate.readBinaryFile(path);
    if (result.isOk) bulkBytes += result.valueOrNull!.length;
    return result;
  }

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) => delegate.readTextLines(path, maxLines: maxLines);

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) => delegate.writeBinaryFile(path, content);

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      delegate.writeFile(path, content);

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      delegate.appendFile(path, content);

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      delegate.fileInfo(path);

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      delegate.listDir(path);

  @override
  Future<Result<bool, FileError>> exists(String path) => delegate.exists(path);

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => delegate.createDir(path, recursive: recursive);

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => delegate.remove(path, recursive: recursive, force: force);

  @override
  Future<Result<Uint8List, FileError>> readRange(
    String path,
    int start,
    int end,
  ) async {
    final Result<Uint8List, FileError> result;
    if (delegate case final RangedReadFileSystem ranged) {
      result = await ranged.readRange(path, start, end);
    } else {
      result = Err(
        FileError(FileErrorCode.notSupported, 'no ranged reads', path: path),
      );
    }
    if (result.isOk) rangedBytes += result.valueOrNull!.length;
    return result;
  }
}

void main() {
  late MemoryFileSystem fs;
  const path = '/sessions/big.jsonl';

  setUp(() {
    fs = MemoryFileSystem();
  });

  /// Builds a big session file in one write (raw JSONL lines) — thousands
  /// of awaited storage appends would dominate the test runtime.
  Future<int> seedRaw(int count) async {
    const iso = '2026-01-01T00:00:00.000Z';
    final buffer = StringBuffer(
      '{"type":"session","version":3,"id":"big","timestamp":"$iso",'
      '"cwd":"/work"}\n',
    );
    for (var i = 0; i < count; i++) {
      buffer.write(
        '{"type":"message","id":"e$i","parentId":'
        '${i == 0 ? 'null' : '"e${i - 1}"'},"timestamp":"$iso",'
        '"message":{"role":"user","content":[{"type":"text","text":'
        '"message $i with a bit of body to be realistic"}]}}\n',
      );
    }
    await fs.writeFile(path, buffer.toString());
    return count;
  }

  Future<JsonlSessionStorage> seed(int count) async {
    final storage = await JsonlSessionStorage.create(
      fs,
      path,
      cwd: '/work',
      sessionId: 'big',
    );
    for (var i = 0; i < count; i++) {
      await storage.appendEntry(
        MessageRecord(
          id: 'e$i',
          parentId: i == 0 ? null : 'e${i - 1}',
          timestamp: DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
          message: UserMessage.text('message $i'),
        ),
      );
    }
    return storage;
  }

  List<String> idsOf(List<SessionRecord> records) => [
    for (final record in records) record.id,
  ];

  group('WindowedSessionStorage.open', () {
    test('reads only the tail window, not the whole file', () async {
      const count = 20000; // ~4 MB file
      await seedRaw(count);
      final raw = (await fs.readBinaryFile(path)).getOrThrow();
      final counting = CountingFileSystem(fs);

      final windowed = await WindowedSessionStorage.open(
        counting,
        path,
        chunkRecords: 200,
      );

      // Functional: the newest 200 records are resident, oldest-first.
      final entries = await windowed.getEntries();
      expect(entries, hasLength(200));
      expect(idsOf(entries).first, 'e${count - 200}');
      expect(idsOf(entries).last, 'e${count - 1}');
      expect(windowed.hasOlder, isTrue);
      expect(windowed.cachedMetadata.id, 'big');

      // The bound: opening a ~4 MB session must move on the order of the
      // initial window (128 KiB) plus a small header prefix — a small
      // constant, never a fraction of the file, and never via a whole-file
      // read.
      expect(
        counting.bulkBytes,
        0,
        reason:
            'windowed open must not materialize the file via '
            'readTextFile/readBinaryFile',
      );
      expect(
        counting.rangedBytes,
        lessThan(256 << 10),
        reason: 'open touched ${counting.rangedBytes} of ${raw.length} bytes',
      );
    });

    test('header parse fails loudly on a corrupt first line', () async {
      await fs.writeFile(path, 'not json at all\n');
      await expectLater(
        WindowedSessionStorage.open(fs, path),
        throwsA(isA<SessionException>()),
      );
    });

    test('missing file surfaces notFound', () async {
      await expectLater(
        WindowedSessionStorage.open(fs, '/sessions/nope.jsonl'),
        throwsA(
          isA<SessionException>().having(
            (error) => error.code,
            'code',
            SessionErrorCode.notFound,
          ),
        ),
      );
    });
  });

  group('WindowedSessionStorage.loadOlder', () {
    test('pages older records in order until the file top', () async {
      const count = 120;
      final full = await seed(count);
      final expected = idsOf(await full.getEntries());

      final windowed = await WindowedSessionStorage.open(
        fs,
        path,
        chunkRecords: 30,
      );
      final loaded = idsOf(await windowed.getEntries());
      expect(loaded, expected.sublist(count - 30));

      var batches = 0;
      while (windowed.hasOlder) {
        final older = await windowed.loadOlder(maxRecords: 30);
        batches++;
        expect(older, isNotEmpty);
        // Root-first: each batch continues upward without gaps or overlaps.
        final previous = 'e${int.parse(loaded.first.substring(1)) - 1}';
        expect(idsOf(older).last, previous);
        loaded.insertAll(0, idsOf(older));
      }
      expect(batches, 3, reason: '120 records in 30-record pages');
      expect(windowed.hasOlder, isFalse);
      expect(await windowed.loadOlder(), isEmpty);
      expect(idsOf(await windowed.getEntries()), expected);
      // The exact count agrees with a whole-file newline scan.
      expect(await windowed.countRecords(), count);
    });

    test('small sessions load whole: window == file', () async {
      await seed(5);
      final windowed = await WindowedSessionStorage.open(fs, path);
      expect(await windowed.getEntries(), hasLength(5));
      expect(windowed.hasOlder, isFalse);
      expect(await windowed.loadOlder(), isEmpty);
    });

    test('a chunk of foreign-branch records does not strand paging', () async {
      // File shape (root-first): e0 - e1 - [e2 (branch A) | f2 (branch B)]
      // - e3, with the active leaf on branch A. The newest window (records
      // e3, f2) contains NO active-branch record above e3 — paging must
      // keep going and land e2, then e1/e0.
      const iso = '2026-01-01T00:00:00.000Z';
      final header =
          '{"type":"session","version":3,"id":"fork","timestamp":"$iso",'
          '"cwd":"/work"}';
      String entry(String id, String? parent) =>
          '{"type":"message","id":"$id","parentId":${parent == null ? 'null' : '"$parent"'},'
          '"timestamp":"$iso","message":{"role":"user","content":[{"type":"text","text":"$id"}]}}';
      final lines = [
        header,
        entry('e0', null),
        entry('e1', 'e0'),
        entry('e2', 'e1'), // branch A
        entry('f2', 'e1'), // branch B (foreign)
        entry('e3', 'e2'), // newest write: active leaf chain e3-e2-e1-e0
      ];
      await fs.writeFile(path, '${lines.join('\n')}\n');

      final windowed = await WindowedSessionStorage.open(
        fs,
        path,
        chunkRecords: 2,
      );
      expect(idsOf(await windowed.getEntries()), ['f2', 'e3']);
      expect(await windowed.getLeafId(), 'e3');

      final older = await windowed.loadOlder(maxRecords: 2);
      // The 2-record chunk above f2 is [e1, e2]; both join the branch in
      // one batch (f2 itself is skipped — foreign). Root-first.
      expect(idsOf(older), ['e1', 'e2']);
      expect(idsOf(await windowed.getEntries()), ['e1', 'e2', 'f2', 'e3']);

      final older2 = await windowed.loadOlder(maxRecords: 2);
      expect(idsOf(older2), ['e0']);
      expect(windowed.hasOlder, isFalse);
      // The branch walk renders the active branch only, root-first.
      expect(idsOf(await windowed.getPathToRoot('e3')), [
        'e0',
        'e1',
        'e2',
        'e3',
      ]);
    });
  });

  group('WindowedSessionStorage byte cap', () {
    test(
      'keeps at least one record even when it alone exceeds the cap',
      () async {
        await seed(3); // e0, e1, e2 — e2 is the newest
        final windowed = await WindowedSessionStorage.open(
          fs,
          path,
          chunkRecords: 10,
          chunkBytes: 1, // nothing should fit; the newest record still must
        );
        final entries = await windowed.getEntries();
        expect(idsOf(entries), ['e2']);
        expect(windowed.hasOlder, isTrue);
      },
    );
  });

  group('WindowedSessionStorage.mutations', () {
    test('appends persist and a full reopen sees them', () async {
      await seed(4);
      final windowed = await WindowedSessionStorage.open(
        fs,
        path,
        chunkRecords: 2,
      );
      await windowed.appendEntry(
        MessageRecord(
          id: 'e4',
          parentId: 'e3',
          timestamp: DateTime.utc(2026, 1, 2),
          message: UserMessage.text('appended'),
        ),
      );
      expect(await windowed.getLeafId(), 'e4');

      final reopened = await JsonlSessionStorage.open(fs, path);
      final all = await reopened.getEntries();
      expect(idsOf(all).last, 'e4');
      expect(await reopened.getLeafId(), 'e4');
    });

    test(
      'setLeafId writes a leaf record chaining from the current leaf',
      () async {
        await seed(4);
        final windowed = await WindowedSessionStorage.open(
          fs,
          path,
          chunkRecords: 2,
        );
        await windowed.setLeafId('e2'); // fork up to e2 — an in-window record
        final reopened = await JsonlSessionStorage.open(fs, path);
        expect(await reopened.getLeafId(), 'e2');
      },
    );

    test('createEntryId avoids collisions with loaded records', () async {
      await seed(2);
      final windowed = await WindowedSessionStorage.open(fs, path);
      final id = await windowed.createEntryId();
      final entries = await windowed.getEntries();
      expect(idsOf(entries), isNot(contains(id)));
    });
  });

  group('WindowedSessionStorage.live tail', () {
    test('ingestAppended picks up externally-appended records', () async {
      await seed(10);
      final windowed = await WindowedSessionStorage.open(
        fs,
        path,
        chunkRecords: 5,
      );

      // An external writer (running CLI) appends below the app's nose.
      final external = await JsonlSessionStorage.open(fs, path);
      await external.appendEntry(
        MessageRecord(
          id: 'e10',
          parentId: 'e9',
          timestamp: DateTime.utc(2026, 1, 2),
          message: UserMessage.text('from cli'),
        ),
      );

      expect(idsOf((await windowed.ingestAppended()).delta), ['e10']);
      final entries = await windowed.getEntries();
      expect(idsOf(entries).last, 'e10');
      expect(await windowed.getLeafId(), 'e10');
      // Idempotent when nothing new landed.
      expect((await windowed.ingestAppended()).delta, isEmpty);
    });

    test('a shrunken file re-anchors to the new tail (E5)', () async {
      await seed(10);
      final windowed = await WindowedSessionStorage.open(
        fs,
        path,
        chunkRecords: 5,
      );
      final raw = (await fs.readTextFile(path)).getOrThrow();
      final truncated = '${raw.split('\n').take(4).join('\n')}\n';
      await fs.writeFile(path, truncated);

      expect((await windowed.ingestAppended()).reanchored, isTrue);
      final entries = await windowed.getEntries();
      expect(entries, hasLength(3)); // e0..e2 survive truncation
      expect(idsOf(entries), ['e0', 'e1', 'e2']);
      expect(await windowed.getLeafId(), 'e2');
    });
  });

  group('SessionChunkReader', () {
    test('countRecords counts records, not lines', () async {
      await seed(7);
      final reader = SessionChunkReader(fs: fs, path: path);
      expect(await reader.countRecords(), 7);
    });

    test('readAround centers on the target record', () async {
      await seed(20);
      final reader = SessionChunkReader(fs: fs, path: path);
      final tail = await reader.readTail(maxRecords: 20);
      final target = tail.entries
          .firstWhere((entry) => entry.record.id == 'e10')
          .offset;
      final around = await reader.readAround(target, maxRecords: 9);
      final ids = [for (final entry in around.entries) entry.record.id];
      // Records below AND above the target are present, in order.
      expect(ids.indexOf('e10'), lessThan(ids.length - 1));
      expect(ids.indexOf('e10'), greaterThan(0));
    });

    test('readForward parses only bytes from the offset', () async {
      await seed(6);
      final reader = SessionChunkReader(fs: fs, path: path);
      final tail = await reader.readTail(maxRecords: 6);
      final e3 = tail.entries
          .firstWhere((entry) => entry.record.id == 'e3')
          .offset;
      final forward = await reader.readForward(e3);
      expect(
        [for (final entry in forward.entries) entry.record.id],
        ['e3', 'e4', 'e5'],
      );
      expect(forward.limitOffset, (await fs.fileInfo(path)).getOrThrow().size);
    });
  });

  group('residency bound', () {
    test('resident window stays capped while paging far past it', () async {
      await seedRaw(3000);
      final storage = await WindowedSessionStorage.open(
        fs,
        path,
        chunkRecords: 200,
        residentRecords: 600,
        residentBytes: 24 * 1024 * 1024,
      );
      expect(storage.residentCount, 200); // open: tail chunk only
      // The app's load-end refresh primes the above-count memo.
      expect(await storage.countAbove(), 2800);
      for (var i = 0; i < 10; i++) {
        await storage.loadOlder();
      }
      // Ten pages loaded 2200 records, yet the index never outgrew the
      // cache bound - the invariant retires the full-materialization
      // blowup (issue #135 AC1, instrumented).
      expect(storage.residentCount, 600);
      expect(storage.residentWindowBytes, lessThanOrEqualTo(24 * 1024 * 1024));
      // Paging up keeps the OLDEST resident slice (the just-loaded
      // history); the newest side slides out (re-readable by paging
      // back down) and the anchor keeps moving toward the file top.
      final ids = [for (final entry in await storage.getEntries()) entry.id];
      expect(ids, [for (var i = 800; i < 1400; i++) 'e$i']);
      // 800 records remain above; the exact total survives eviction.
      expect(await storage.countAbove(), 800);
      // The evicted newest side is COUNTED below (the page-down
      // banner), not silently gone: 10 pages x 200 slid out.
      expect(storage.countBelow, 1600);
      expect(await storage.countRecords(), 3000);
    });

    test(
      'eviction prunes every side structure - nothing outlives residency',
      () async {
        await seedRaw(3000);
        final storage = await WindowedSessionStorage.open(
          fs,
          path,
          chunkRecords: 200,
          residentRecords: 600,
          residentBytes: 24 * 1024 * 1024,
        );
        for (var i = 0; i < 10; i++) {
          await storage.loadOlder();
        }
        // The id index and the branch walk stop at the window edge: the
        // evicted newest records hold no strong reference (round-2
        // review: monotonic map growth).
        expect(await storage.getEntry('e2999'), isNull);
        expect(await storage.getLabel('e2999'), isNull);
        expect(idsOf(await storage.getPathToRoot('e1399')), [
          for (var i = 800; i <= 1399; i++) 'e$i',
        ]);
        // The sparse offset map keeps everything explored (AC6 jumps).
        expect(storage.offsetOf('e2999'), isNotNull);
        expect(storage.offsetOf('e2998'), isNotNull);
      },
    );

    test(
      'appends never evict the live tail; the oldest side gives way',
      () async {
        await seedRaw(100);
        final storage = await WindowedSessionStorage.open(
          fs,
          path,
          chunkRecords: 50,
          residentRecords: 60,
          residentBytes: 1 << 30,
        );
        for (var i = 100; i < 400; i++) {
          await storage.appendEntry(
            MessageRecord(
              id: 'e$i',
              parentId: 'e${i - 1}',
              timestamp: DateTime.utc(2026, 1, 2),
              message: UserMessage.text('appended $i'),
            ),
          );
        }
        expect(storage.residentCount, 60);
        // The live tail is resident, the leaf is the TRUE file leaf, and
        // eviction only ever took the oldest side (round-2 review: the
        // tail can never silently vanish).
        final ids = idsOf(await storage.getEntries());
        expect(ids.last, 'e399');
        expect(await storage.getEntry('e399'), isNotNull);
        expect(await storage.getLeafId(), 'e399');
        expect(await storage.getEntry('e50'), isNull);
        expect(await storage.countAbove(), 340);
        expect(storage.countBelow, 0);
      },
    );

    test('external ingest never evicts the live tail either', () async {
      await seedRaw(1000);
      final storage = await WindowedSessionStorage.open(
        fs,
        path,
        chunkRecords: 200,
        residentRecords: 220,
        residentBytes: 1 << 30,
      );
      const iso = '2026-01-01T00:00:00.000Z';
      final extra = StringBuffer();
      for (var i = 1000; i < 1050; i++) {
        extra.write(
          '{"type":"message","id":"e$i","parentId":"e${i - 1}",'
          '"timestamp":"$iso","message":{"role":"user","content":'
          '[{"type":"text","text":"cli $i"}]}}\n',
        );
      }
      await fs.appendFile(path, extra.toString());
      expect(idsOf((await storage.ingestAppended()).delta).last, 'e1049');
      expect(idsOf(await storage.getEntries()).last, 'e1049');
      // 200 + 50 ingested over the 220 cap: the OLDEST side gives way,
      // the tail stays.
      expect(storage.residentCount, 220);
      expect(await storage.countAbove(), 830);
    });
    test(
      'deep paging slides the newest side out; loadNewer pages it back',
      () async {
        await seedRaw(3000);
        final storage = await WindowedSessionStorage.open(
          fs,
          path,
          chunkRecords: 200,
          residentRecords: 600,
          residentBytes: 24 * 1024 * 1024,
        );
        final view = idsOf(await storage.getEntries());
        while (storage.hasOlder) {
          final joined = await storage.loadOlder();
          if (joined.isEmpty) fail('loadOlder stalled with history above');
          view.insertAll(0, idsOf(joined));
        }
        // The paged deltas rebuild the whole branch above the open tail:
        // no gaps, no duplicates, no reordering (AC3).
        expect(view, [for (var i = 0; i < 3000; i++) 'e$i']);
        expect(await storage.countAbove(), 0);
        // Everything that slid out the newest side is COUNTED below.
        expect(storage.countBelow, 2400);

        // The page-down path (round-2 review): the evicted newest side
        // comes back chunk by chunk, oldest-first, until the live tail.
        final paged = <String>[];
        while (storage.hasNewer) {
          final joined = await storage.loadNewer();
          if (joined.isEmpty) fail('loadNewer stalled with records below');
          paged.addAll(idsOf(joined));
        }
        expect(paged, [for (var i = 600; i < 3000; i++) 'e$i']);
        expect(storage.countBelow, 0);
        expect(idsOf(await storage.getEntries()).last, 'e2999');
      },
    );

    test(
      'jumpToOffset recenters the window; leaf and counts behave (AC6)',
      () async {
        await seedRaw(3000);
        final storage = await WindowedSessionStorage.open(
          fs,
          path,
          chunkRecords: 200,
        );
        await storage.loadOlder(); // explore one chunk up: e2600..e2799
        final target = storage.offsetOf('e2700');
        expect(target, isNotNull);

        final branch = await storage.jumpToOffset(target!);
        expect(idsOf(branch), contains('e2700'));
        final ids = idsOf(await storage.getEntries());
        expect(ids, contains('e2700'));
        expect(ids.length, lessThanOrEqualTo(200));
        // The leaf is the TRUE file leaf regardless of the window position.
        expect(await storage.getLeafId(), 'e2999');
        // Edges are unknown right after a jump (null, not a guess).
        expect(await storage.countAbove(), isNull);
        // And the jump window pages back down to the tail cleanly.
        while (storage.hasNewer) {
          await storage.loadNewer();
        }
        expect(idsOf(await storage.getEntries()).last, 'e2999');
        expect(storage.countBelow, 0);
      },
    );

    test('byte cap bounds residency with pathological records', () async {
      // Five ~1.2 MiB records: the record cap alone would admit them all.
      const iso = '2026-01-01T00:00:00.000Z';
      final buffer = StringBuffer(
        '{"type":"session","version":3,"id":"big","timestamp":"$iso",'
        '"cwd":"/work"}\n',
      );
      for (var i = 0; i < 5; i++) {
        buffer.write(
          '{"type":"message","id":"e$i","parentId":'
          '${i == 0 ? 'null' : '"e${i - 1}"'},"timestamp":"$iso",'
          '"message":{"role":"user","content":[{"type":"text","text":'
          '"${'x' * (1200 * 1024)}"}]}}\n',
        );
      }
      await fs.writeFile(path, buffer.toString());
      final storage = await WindowedSessionStorage.open(
        fs,
        path,
        chunkRecords: 4,
        chunkBytes: 8 * 1024 * 1024,
        residentRecords: 6,
        residentBytes: 3 * 1024 * 1024,
      );
      await storage.loadOlder();
      // The byte cap holds even though the record cap (6) would allow
      // every one of the 5 MiB-scale records resident.
      expect(storage.residentWindowBytes, lessThanOrEqualTo(3 * 1024 * 1024));
      expect(storage.residentCount, lessThan(5));
    });

    test('external appends keep the cached total fresh (no drift)', () async {
      await seedRaw(1000);
      final storage = await WindowedSessionStorage.open(fs, path);
      expect(await storage.countRecords(), 1000);
      // A CLI appends 5 records straight to the file.
      const iso = '2026-01-01T00:00:00.000Z';
      final extra = StringBuffer();
      for (var i = 0; i < 5; i++) {
        extra.write(
          '{"type":"message","id":"e${1000 + i}","parentId":"e${999 + i}",'
          '"timestamp":"$iso","message":{"role":"user","content":'
          '[{"type":"text","text":"appended $i"}]}}\n',
        );
      }
      final appended = await fs.appendFile(path, extra.toString());
      if (appended.isErr) fail('append failed: ${appended.errorOrNull}');
      expect(idsOf((await storage.ingestAppended()).delta), hasLength(5));
      // A stale memo would report 1000 and drift the banner count
      // downward (negative) after every external append.
      expect(await storage.countRecords(), 1005);
    });

    test('seeded tap-walk concatenates the full branch with no gaps', () async {
      await seedRaw(777);
      final storage = await WindowedSessionStorage.open(
        fs,
        path,
        chunkRecords: 50,
        residentRecords: 5000,
        residentBytes: 1 << 30,
      );
      final walked = <String>[];
      while (storage.hasOlder) {
        final joined = await storage.loadOlder();
        if (joined.isEmpty) fail('loadOlder stalled with history above');
        walked.insertAll(0, [for (final record in joined) record.id]);
      }
      // The deltas (tap-joined records, root-first each tap) rebuild
      // everything above the open tail exactly: e0..e726, no gaps, no
      // duplicates, no reordering (issue #135 AC3).
      expect(walked, [for (var i = 0; i < 727; i++) 'e$i']);
      // And the resident window now spans the whole branch in file
      // order, open tail included.
      final ids = [for (final record in await storage.getEntries()) record.id];
      expect(ids, [for (var i = 0; i < 777; i++) 'e$i']);
    });
  });
}
