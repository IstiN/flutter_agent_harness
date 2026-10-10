// Issue #1498 regression guards: the reader's parsed-line cache.
//
// The perf bug: every scan re-parsed every line of its range, so a
// 105k-line session re-paid ~1ms/line on every jump/scroll/tail poll.
// The fix: lines resolve against an (offset, byteLength, shallow)-keyed
// cache before any decode+parse. These guards pin the mechanism with the
// reader's own hit/miss counters (the `locatePassCount` precedent) plus
// one generous wall-clock bound for the gross-regression tripwire.
@TestOn('vm')
@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  late MemoryFileSystem fs;
  const path = '/sessions/s.jsonl';

  /// Canonical first line (dropped as the header by tail scans).
  const header =
      '{"type":"session","version":3,"id":"s1","timestamp":"2026-01-01T00:00:00.000Z","cwd":"/tmp"}';

  setUp(() {
    fs = MemoryFileSystem();
  });

  SessionChunkReader reader({
    int parseCacheEntries = defaultParseCacheEntries,
    int parseCacheBytes = defaultParseCacheBytes,
  }) => SessionChunkReader(
    fs: fs,
    path: path,
    parseCacheEntries: parseCacheEntries,
    parseCacheBytes: parseCacheBytes,
  );

  Map<String, dynamic> userJson(String id, {String text = 'hi'}) => {
    'type': 'message',
    'id': id,
    'parentId': null,
    'timestamp': '2026-01-01T00:00:00.000Z',
    'message': {'role': 'user', 'content': text, 'timestamp': 1767225600000},
  };

  Map<String, dynamic> customJson(String id, String data) => {
    'type': 'custom',
    'id': id,
    'parentId': null,
    'timestamp': '2026-01-01T00:00:00.000Z',
    'customType': 'note',
    'data': data,
  };

  Map<String, dynamic> toolResultJson(String id, int payloadBytes) => {
    'type': 'message',
    'id': id,
    'parentId': null,
    'timestamp': '2026-01-01T00:00:00.000Z',
    'message': {
      'role': 'toolResult',
      'toolCallId': '$id-call',
      'toolName': 'bash',
      'content': [
        {'type': 'text', 'text': 'x' * payloadBytes},
      ],
      'isError': false,
      'timestamp': 1767225600000,
    },
  };

  /// Header + [lines], newline-terminated — the canonical session shape.
  Future<void> writeLines(List<Map<String, dynamic>> lines) async {
    final result = await fs.appendFile(
      path,
      '$header\n${lines.map(jsonEncode).join('\n')}\n',
    );
    result.getOrThrow();
  }

  /// Byte offset of the line carrying [id] in the just-written file.
  Future<int> offsetOfId(String id) async {
    final content = (await fs.readTextFile(path)).getOrThrow();
    var offset = 0;
    for (final line in content.split('\n')) {
      if (line.contains('"id":"$id"')) return offset;
      offset += line.length + 1;
    }
    fail('id $id not in fixture');
  }

  List<String> idsOf(SessionChunk chunk) => [
    for (final entry in chunk.entries) entry.record.id,
  ];

  group('parse cache: repeated windows (issue #1498)', () {
    test('a repeat readAround splices instead of re-parsing', () async {
      await writeLines([
        for (var i = 0; i < 40; i++) userJson('u$i', text: 'msg $i'),
      ]);
      final r = reader();
      final anchor = await offsetOfId('u20');
      final first = await r.readAround(anchor);
      final missesAfterFirst = r.parseCacheMissCount;
      expect(missesAfterFirst, greaterThan(0));

      final second = await r.readAround(anchor);
      expect(r.parseCacheMissCount, missesAfterFirst);
      expect(r.parseCacheHitCount, greaterThan(0));
      expect(idsOf(second), idsOf(first));
      expect([
        for (final entry in second.entries) entry.record.toJson(),
      ], equals([for (final entry in first.entries) entry.record.toJson()]));
    });

    test('capped readForward over a visited range is a cache hit', () async {
      await writeLines([for (var i = 0; i < 60; i++) userJson('u$i')]);
      final r = reader();
      final anchor = await offsetOfId('u10');
      final first = await r.readForward(anchor, maxRecords: 20);
      final missesAfterFirst = r.parseCacheMissCount;
      final second = await r.readForward(anchor, maxRecords: 20);
      expect(r.parseCacheMissCount, missesAfterFirst);
      expect(idsOf(second), idsOf(first));
    });

    test('readBlockBefore re-walk is a cache hit, records identical', () async {
      await writeLines([for (var i = 0; i < 50; i++) userJson('u$i')]);
      final r = reader();
      final anchor = await offsetOfId('u30');
      final first = await r.readBlockBefore(anchor);
      final missesAfterFirst = r.parseCacheMissCount;
      final second = await r.readBlockBefore(anchor);
      expect(r.parseCacheMissCount, missesAfterFirst);
      expect(idsOf(second), idsOf(first));
    });

    test(
      'jumpToOffset twice on the same window stays under the budget',
      () async {
        await writeLines([
          for (var i = 0; i < 10000; i++)
            toolResultJson('u$i', i % 3 == 0 ? 4000 : 400),
        ]);
        final storage = await WindowedSessionStorage.open(fs, path);
        // A record inside the OPEN's resident tail: its offset is already
        // in the sparse map, so the jump exercises readAround + the cache,
        // not the locateRecord scan.
        final target = storage.offsetOf('u9950');
        expect(target, isNotNull);
        final first = await storage.jumpToOffset(target!);
        expect(first, isNotEmpty);
        final missesAfterFirst = storage.reader.parseCacheMissCount;

        final sw = Stopwatch()..start();
        var last = first;
        for (var i = 0; i < 5; i++) {
          last = await storage.jumpToOffset(target);
        }
        sw.stop();
        // Generous CI bound (measured warm ~2ms/jump locally): the tripwire
        // is the wall clock only; the mechanism is pinned by the counters.
        expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
        expect(storage.reader.parseCacheMissCount, missesAfterFirst);
        expect([
          for (final record in last) record.id,
        ], equals([for (final record in first) record.id]));
      },
    );
  });

  group('parse cache: freshness (issue #1498)', () {
    test('an append keeps the cached prefix and serves the new lines', () async {
      await writeLines([for (var i = 0; i < 20; i++) userJson('u$i')]);
      final r = reader();
      final first = await r.readTail();
      final missesAfterFirst = r.parseCacheMissCount;

      // Raw append (no header — that would be a second header line
      // mid-file): 10 new record lines.
      final append = await fs.appendFile(
        path,
        '${[for (var i = 20; i < 30; i++) userJson('u$i')].map(jsonEncode).join('\n')}\n',
      );
      append.getOrThrow();
      final second = await r.readTail(maxRecords: 50);
      expect(idsOf(second).take(20), idsOf(first));
      expect(idsOf(second), containsAll(['u25', 'u29']));
      // Only the appended lines paid a parse (the header's torn probe was
      // cached too).
      expect(r.parseCacheMissCount - missesAfterFirst, 10);

      // And a third pass over the same content parses nothing new.
      final missesBeforeThird = r.parseCacheMissCount;
      final third = await r.readTail(maxRecords: 50);
      expect(r.parseCacheMissCount, missesBeforeThird);
      expect(idsOf(third), idsOf(second));
    });

    test('a completed torn line re-parses (the length changed)', () async {
      // A record line cut mid-write at the tail, no trailing newline.
      final tornPrefix = jsonEncode(
        userJson('u0'),
      ).substring(0, 40); // torn, unparseable
      final result = await fs.appendFile(path, '$header\n$tornPrefix');
      result.getOrThrow();
      final r = reader();
      expect(idsOf(await r.readTail()), isEmpty);

      // The append completes the same line (same offset, longer length):
      // never served torn from the cache.
      final completion =
          '${jsonEncode(userJson('u0')).substring(40)}\n${jsonEncode(userJson('u1'))}\n';
      final append = await fs.appendFile(path, completion);
      append.getOrThrow();
      final healed = await r.readTail(maxRecords: 50);
      expect(idsOf(healed), ['u0', 'u1']);
    });

    test('a shrink (truncation) invalidates the cached lines', () async {
      await writeLines([for (var i = 0; i < 20; i++) userJson('u$i')]);
      final r = reader();
      await r.readTail();
      final missesAfterFirst = r.parseCacheMissCount;

      // Truncate to the header + first two records (a rewrite, not an
      // append): offsets into the old bytes are garbage now.
      final full = (await fs.readTextFile(path)).getOrThrow();
      final lines = full.split('\n')..removeLast();
      final shrunk = '${lines.take(3).join('\n')}\n';
      final write = await fs.writeFile(path, shrunk);
      write.getOrThrow();

      final after = await r.readTail();
      expect(idsOf(after), ['u0', 'u1']);
      expect(r.parseCacheMissCount, greaterThan(missesAfterFirst));
    });

    test('a same-size mtime move (the rewrite signal) invalidates', () async {
      await writeLines([
        for (var i = 0; i < 6; i++) userJson('u$i', text: 'msg $i'),
      ]);
      final r = reader();
      await r.readTail();
      final missesAfterFirst = r.parseCacheMissCount;

      // Same byte length, rewritten in place: the mtime is the only
      // signal (the rule `ingestAppended` uses for same-size rewrites).
      final content = (await fs.readTextFile(path)).getOrThrow();
      final rewritten = content.replaceFirst('"msg 0"', '"msg 9"');
      expect(rewritten.length, content.length);
      final write = await fs.writeFile(path, rewritten);
      write.getOrThrow();
      fs.setMtime(path, 1234567890999);

      await r.readTail();
      expect(r.parseCacheMissCount, greaterThan(missesAfterFirst));
      final body = (await fs.readTextFile(path)).getOrThrow();
      expect(body, contains('"msg 9"'));
    });

    test('shallow and full parses never cross (byte-compat guard)', () async {
      // A giant custom record: the resume walk parses it header-only
      // (data:null); a full-fidelity read must never see that stub, and
      // the walk must never see the full data either. A small sentinel
      // record after the giant gives readBlockBefore a line boundary
      // that includes the giant line whole.
      final giant = customJson('g1', 'x' * (80 << 10));
      await writeLines([giant, userJson('after')]);
      final r = reader();
      final anchor = await offsetOfId('after');
      CustomRecord giantIn(SessionChunk chunk) =>
          chunk.entries.firstWhere((entry) => entry.record.id == 'g1').record
              as CustomRecord;

      final shallow = await r.readBlockBefore(
        anchor,
        shallowGiantCustoms: true,
      );
      expect(giantIn(shallow).data, isNull);

      final full = await r.readBlockBefore(anchor);
      expect((giantIn(full).data as String?)?.length, 80 << 10);

      // And the shallow view again — still the stub, never the cache of
      // the full parse.
      final shallowAgain = await r.readBlockBefore(
        anchor,
        shallowGiantCustoms: true,
      );
      expect(giantIn(shallowAgain).data, isNull);
      expect(r.parseCacheHitCount, greaterThan(0));
    });
  });

  group('parse cache: bounds (issue #1498)', () {
    test('entry cap evicts oldest first', () async {
      await writeLines([for (var i = 0; i < 64; i++) userJson('u$i')]);
      final r = reader(parseCacheEntries: 8, parseCacheBytes: 1 << 30);
      await r.readTail(maxRecords: 200, maxBytes: 1 << 30);
      expect(r.parseCacheEntryCount, 8);
    });

    test('byte cap bounds the cached raw-line bytes', () async {
      await writeLines([
        for (var i = 0; i < 8; i++) userJson('u$i', text: 'x' * 1000),
      ]);
      final r = reader(parseCacheEntries: 100, parseCacheBytes: 2048);
      await r.readTail(maxRecords: 100, maxBytes: 1 << 30);
      expect(r.parseCacheEntryCount, lessThan(8));
      expect(r.parseCacheEntryCount, greaterThan(0));
    });

    test('parseCacheEntries: 0 disables the cache', () async {
      await writeLines([for (var i = 0; i < 6; i++) userJson('u$i')]);
      final r = reader(parseCacheEntries: 0, parseCacheBytes: 0);
      await r.readTail();
      final misses = r.parseCacheMissCount;
      expect(r.parseCacheEntryCount, 0);
      await r.readTail();
      expect(r.parseCacheMissCount, greaterThan(misses));
      expect(r.parseCacheEntryCount, 0);
    });
  });

  group('parse cache: torn and junk lines (issue #1498)', () {
    test('a known-torn line is skipped without a re-parse', () async {
      final result = await fs.appendFile(
        path,
        '$header\n${jsonEncode(userJson('u0'))}\n{"id":\n${jsonEncode(userJson('u1'))}\n',
      );
      result.getOrThrow();
      final r = reader();
      final first = await r.readTail();
      expect(idsOf(first), ['u0', 'u1']);
      final missesAfterFirst = r.parseCacheMissCount;
      final second = await r.readTail();
      expect(r.parseCacheMissCount, missesAfterFirst);
      expect(idsOf(second), ['u0', 'u1']);
    });

    test('a foreign (parseable, non-record) line stays skipped', () async {
      final result = await fs.appendFile(
        path,
        '$header\n${jsonEncode(userJson('u0'))}\n{"torn":true}\n${jsonEncode(userJson('u1'))}\n',
      );
      result.getOrThrow();
      final r = reader();
      expect(idsOf(await r.readTail()), ['u0', 'u1']);
      final misses = r.parseCacheMissCount;
      expect(idsOf(await r.readTail()), ['u0', 'u1']);
      expect(r.parseCacheMissCount, misses);
    });
  });
}
