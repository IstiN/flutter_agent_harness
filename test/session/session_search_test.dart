// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Issue #1380 A2 — session-wide archive search: keyword/regex matching
/// over decoded text (hidden + checkpointed regions included), kind/time
/// filters, capped scans with continuation, branch vs tree scope, the
/// `mode: map` structure readout, and the E4/E5 bounds (streamed scan,
/// structured errors, previews never carry full content).
library;

import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _ruleText = 'always run tests before pushing';
const _oldDecision =
    'we decided the WASM size stays under 2 MB (decision record, three '
    'weeks ago)';
const _forkText = 'fork-only note: abandon this branch';
const _giantText = 'x' * 2000;

AssistantMessage _assistant(String text) {
  return AssistantMessage(
    content: [TextContent(text: text)],
    api: 'anthropic-messages',
    provider: 'p',
    model: 'm1',
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.utc(2026),
  );
}

/// A synthetic session carrying everything AC4 exercises: visible
/// messages, a HIDDEN rule record, a nested-checkpoint region holding an
/// old decision, a fork branch, and a giant record for the preview cap.
/// Returns the seeded record ids by role.
Future<({List<String> ids, Session session, String checkpointId})>
_seedArchive(Session session) async {
  final ids = <String>[];
  Future<void> user(String text) async {
    ids.add(await session.appendMessage(UserMessage.text(text)));
  }

  Future<void> reply(String text) async {
    ids.add(await session.appendMessage(_assistant(text)));
  }

  await user('$_ruleText — and that is a standing rule');
  await reply('understood');
  // The decision below gets checkpointed away; the record stays on disk.
  await user(_oldDecision);
  await reply('noted for the archive');
  await user(_giantText);
  // Fork: a branch the active leaf never revisits.
  await user(_forkText);
  await reply('fork explored and abandoned');

  final checkpointId = await session.appendCompactCheckpoint(
    firstRecordId: ids[2],
    lastRecordId: ids[3],
    text: 'checkpoint: the WASM decision arc',
    coversRecordIds: [ids[2], ids[3]],
    flattenedRecordIds: const [],
  );
  await session.appendHiddenRange(recordIds: [ids[0]]);
  return (
    ids: ids,
    session: session,
    checkpointId: checkpointId,
  );
}

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  });

  Future<List<SessionRecord>> seededRecords() async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    await _seedArchive(session);
    return session.getEntries();
  }

  group('argument validation (E5 — structured errors, never a hang)', () {
    test('empty search query is rejected with the map-mode hint', () {
      expect(
        () => SessionSearchQuery.fromArgs(const {}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('query is required'),
          ),
        ),
      );
    });

    test('an overlong query is rejected, not scanned', () {
      expect(
        () => SessionSearchQuery.fromArgs({'query': 'q' * 600}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('query is too long'),
          ),
        ),
      );
    });

    test('an invalid regex is rejected at parse time', () {
      expect(
        () => SessionSearchQuery.fromArgs({
          'query': '(unbalanced',
          'regex': true,
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('invalid regex'),
          ),
        ),
      );
    });

    test('a malformed time bound is rejected with its label', () {
      expect(
        () => SessionSearchQuery.fromArgs({
          'query': 'wasm',
          'before': 'not-a-date',
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('before must be an ISO-8601 timestamp'),
          ),
        ),
      );
    });

    test('map mode needs no query', () {
      final query = SessionSearchQuery.fromArgs(const {'mode': 'map'});
      expect(query.mode, SessionSearchMode.map);
      expect(query.pattern, isNull);
    });

    test('maxHits clamps to the hard ceiling', () {
      final query = SessionSearchQuery.fromArgs({'query': 'x', 'maxHits': 99});
      expect(query.maxHits, maxSessionSearchMaxHits);
    });
  });

  group('keyword search over hidden + checkpointed regions (AC4)', () {
    test('finds a record the projection hides', () async {
      final records = await seededRecords();
      final outcome = searchRecords(
        records,
        SessionSearchQuery.fromArgs({'query': 'always run tests'}),
      );
      expect(outcome.hits, hasLength(1));
      expect(outcome.hits.single.kind, 'message');
      expect(outcome.hits.single.preview, contains(_ruleText));
      expect(outcome.truncated, isFalse);
    });

    test('finds a record inside a checkpoint span', () async {
      final records = await seededRecords();
      final outcome = searchRecords(
        records,
        SessionSearchQuery.fromArgs({'query': 'WASM size stays under'}),
      );
      expect(outcome.hits, hasLength(1));
      expect(outcome.hits.single.preview, contains('2 MB'));
    });

    test('the checkpoint text itself is searchable', () async {
      final records = await seededRecords();
      final outcome = searchRecords(
        records,
        SessionSearchQuery.fromArgs({
          'query': 'decision arc',
          'kinds': ['compact_checkpoint'],
        }),
      );
      expect(outcome.hits, hasLength(1));
      expect(outcome.hits.single.kind, 'compact_checkpoint');
    });

    test('no match reports zero hits honestly', () async {
      final records = await seededRecords();
      final outcome = searchRecords(
        records,
        SessionSearchQuery.fromArgs({'query': 'quantum shutdown protocol'}),
      );
      expect(outcome.hits, isEmpty);
      expect(outcome.recordsTotal, records.length);
    });

    test('matching runs on DECODED text, not raw JSON', () async {
      final records = await seededRecords();
      // A quote character: present in decoded text, escaped in the raw
      // JSONL line — a raw-line pre-filter would miss it.
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendMessage(
        UserMessage.text('the rule says "quote me" verbatim'),
      );
      final outcome = searchRecords(
        await session.getEntries(),
        SessionSearchQuery.fromArgs({'query': '"quote me"'}),
      );
      expect(outcome.hits, hasLength(1));
    });
  });

  group('regex mode', () {
    test('case-insensitive regex matches across case', () async {
      final records = await seededRecords();
      final outcome = searchRecords(
        records,
        SessionSearchQuery.fromArgs({
          'query': r'wasm\s+size',
          'regex': true,
        }),
      );
      expect(outcome.hits, isNotEmpty);
    });

    test('a literal keyword never behaves as a pattern', () async {
      final records = await seededRecords();
      final outcome = searchRecords(
        records,
        SessionSearchQuery.fromArgs({'query': 'size (stays|remains)'}),
      );
      expect(outcome.hits, isEmpty);
    });
  });

  group('filters', () {
    test('kinds filter narrows to the requested record types', () async {
      final records = await seededRecords();
      final outcome = searchRecords(
        records,
        SessionSearchQuery.fromArgs({
          'query': 'the',
          'kinds': ['compact_checkpoint'],
        }),
      );
      expect(
        outcome.hits.map((h) => h.kind),
        everyElement('compact_checkpoint'),
      );
    });

    test('before/after bound the searched span', () async {
      final records = await seededRecords();
      final timestamps = records.map((r) => r.timestamp).toList();
      final mid = timestamps[3];
      final outcome = searchRecords(
        records,
        SessionSearchQuery.fromArgs({
          'query': 'the',
          'before': mid.toIso8601String(),
        }),
      );
      expect(
        outcome.hits.map((h) => h.timestamp),
        everyElement(isBeforeOrAt(mid)),
      );
    });
  });

  group('previews (AC4 — never full content)', () {
    test('a 2000-char record previews clipped and single-line', () async {
      final records = await seededRecords();
      final outcome = searchRecords(
        records,
        SessionSearchQuery.fromArgs({'query': 'xxx'}),
      );
      expect(outcome.hits, hasLength(1));
      expect(outcome.hits.single.preview.length, sessionSearchPreviewChars);
      expect(outcome.hits.single.preview, endsWith('…'));
      expect(outcome.hits.single.preview.length, lessThan(_giantText.length));
    });

    test('newlines flatten so one hit is one line', () {
      final preview = sessionSearchPreview('line one\nline two\nline three');
      expect(preview, isNot(contains('\n')));
    });
  });

  group('capped scans + continuation (E4)', () {
    test('the cap stops the scan and the token resumes it', () async {
      final records = await seededRecords();
      final first = searchRecords(
        records,
        SessionSearchQuery.fromArgs({'query': 'the', 'maxHits': 2}),
      );
      expect(first.truncated, isTrue);
      expect(first.hits, hasLength(2));
      expect(first.nextContinuation, isNotNull);
      final second = searchRecords(
        records,
        SessionSearchQuery.fromArgs({
          'query': 'the',
          'maxHits': 2,
          'continuation': first.nextContinuation!,
        }),
      );
      // No overlap, no skip: every hit id across pages is distinct and
      // the pages together cover the same set as a single uncapped scan.
      final ids = first.hits.map((h) => h.id).toSet()
        ..addAll(second.hits.map((h) => h.id));
      final uncapped = searchRecords(
        records,
        SessionSearchQuery.fromArgs({'query': 'the'}),
      );
      expect(ids, uncapped.hits.map((h) => h.id).toSet());
    });
  });

  group('branch vs tree scope (AC4 / IT-tree-scope)', () {
    test('branch scope excludes the abandoned fork; tree scope includes it',
        () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      final seeded = await _seedArchive(session);
      // Move the active leaf back to the pre-fork record: the fork arc
      // becomes an abandoned branch.
      final records = await session.getEntries();
      final preFork = seeded.ids[4];
      await session.getStorage().setLeafId(preFork);

      final branch = searchRecords(
        await session.getEntries(),
        SessionSearchQuery.fromArgs({'query': 'fork-only note'}),
      );
      expect(branch.hits, isEmpty);

      final tree = searchRecords(
        await session.getEntries(),
        SessionSearchQuery.fromArgs({
          'query': 'fork-only note',
          'scope': 'tree',
        }),
      );
      expect(tree.hits, hasLength(1));
      expect(tree.hits.single.preview, contains(_forkText));
      expect(records, isNotEmpty);
    });
  });

  group('mode: map (the archive forensics readout)', () {
    test('counts, hidden totals and checkpoint tree with nesting depth',
        () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      final seeded = await _seedArchive(session);
      // A checkpoint nested INSIDE the first one's span: depth 2.
      final records = await session.getEntries();
      final innerStart = seeded.ids[2];
      await session.appendCompactCheckpoint(
        firstRecordId: innerStart,
        lastRecordId: innerStart,
        text: 'inner checkpoint',
        coversRecordIds: [innerStart],
        flattenedRecordIds: const [],
      );
      final outcome = searchRecords(
        await session.getEntries(),
        SessionSearchQuery.fromArgs(const {'mode': 'map'}),
      );
      final map = outcome.map!;
      expect(map.recordCount, records.length + 1);
      expect(map.kindCounts['message'], greaterThanOrEqualTo(6));
      expect(map.hiddenRangeCount, 1);
      expect(map.hiddenRecordIdCount, 1);
      expect(map.checkpoints, hasLength(2));
      expect(map.maxCheckpointDepth, 2);
      final depths = {
        for (final checkpoint in map.checkpoints)
          checkpoint.id: checkpoint.depth,
      };
      expect(depths[seeded.checkpointId], 1);
      expect(depths.values, contains(2));
      expect(map.leafId, isNotNull);
      expect(map.branchRecordCount, greaterThanOrEqualTo(6));
      // Map mode exposes structure, never content.
      expect(
        map.checkpoints.every(
          (checkpoint) =>
              checkpoint.firstRecordId.isNotEmpty &&
              checkpoint.lastRecordId.isNotEmpty,
        ),
        isTrue,
      );
    });

    test('no checkpoints maps to an honest empty readout', () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendMessage(UserMessage.text('hello'));
      final outcome = searchRecords(
        await session.getEntries(),
        SessionSearchQuery.fromArgs(const {'mode': 'map'}),
      );
      expect(outcome.map!.checkpoints, isEmpty);
      expect(outcome.map!.maxCheckpointDepth, 0);
      expect(outcome.map!.hiddenRangeCount, 0);
    });
  });

  group('the obligations ledger is searchable (custom payload)', () {
    test('an entry quote inside a custom record is found', () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      final writer = ObligationsLedgerWriter();
      final payload = writer.ingest(
        text: _ruleText,
        sourceRecordId: 'rec-source',
        at: DateTime.utc(2026),
      )!;
      await session.appendCustomEntry(
        customType: obligationsLedgerRecordType,
        data: payload,
      );
      final outcome = searchRecords(
        await session.getEntries(),
        SessionSearchQuery.fromArgs({'query': _ruleText}),
      );
      expect(outcome.hits, hasLength(1));
      expect(outcome.hits.single.kind, 'custom');
    });
  });

  group('the streamed file scan', () {
    test('finds what the pure core finds on the same seeded session',
        () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await _seedArchive(session);
      final query = SessionSearchQuery.fromArgs({'query': 'WASM'});
      final fromFile = await searchSessionFile(
        fs,
        (await session.getMetadata()).path,
        query,
      );
      final fromMemory = searchRecords(await session.getEntries(), query);
      expect(
        fromFile.hits.map((h) => h.id).toSet(),
        fromMemory.hits.map((h) => h.id).toSet(),
      );
      expect(fromFile.recordsTotal, fromMemory.recordsTotal);
    });

    test('runs on a non-ranged file system too (readTextLines fallback)',
        () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await _seedArchive(session);
      final outcome = await searchSessionFile(
        _NonRangedFs(fs),
        (await session.getMetadata()).path,
        SessionSearchQuery.fromArgs({'query': 'always run tests'}),
      );
      expect(outcome.hits, hasLength(1));
    });

    test('non-ASCII matches survive tiny scan blocks (UTF-8 seam test)', () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendMessage(
        UserMessage.text('grün blau 日本語 🚀 the WASM ceiling decision'),
      );
      final outcome = await searchSessionFile(
        fs,
        (await session.getMetadata()).path,
        SessionSearchQuery.fromArgs({'query': '🚀'}),
        blockBytes: 7, // every line straddles several seams, mid-codepoint
      );
      expect(outcome.hits, hasLength(1));
      expect(outcome.hits.single.preview, contains('grün'));
      final umlaut = await searchSessionFile(
        fs,
        (await session.getMetadata()).path,
        SessionSearchQuery.fromArgs({'query': 'grün'}),
        blockBytes: 7,
      );
      expect(umlaut.hits, hasLength(1));
    });

    test('a malformed tail line never breaks the scan', () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await _seedArchive(session);
      await fs.appendFile(
        (await session.getMetadata()).path,
        '{"type":"message","id":"tor',
      );
      final outcome = await searchSessionFile(
        fs,
        (await session.getMetadata()).path,
        SessionSearchQuery.fromArgs({'query': 'WASM'}),
      );
      expect(outcome.hits, isNotEmpty);
    });

    test('map mode over the file agrees with the pure core', () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await _seedArchive(session);
      final query = SessionSearchQuery.fromArgs(const {'mode': 'map'});
      final fromFile = await searchSessionFile(
        fs,
        (await session.getMetadata()).path,
        query,
      );
      final fromMemory = searchRecords(await session.getEntries(), query);
      expect(fromFile.map!.recordCount, fromMemory.map!.recordCount);
      expect(
        fromFile.map!.hiddenRecordIdCount,
        fromMemory.map!.hiddenRecordIdCount,
      );
      expect(fromFile.map!.checkpoints.length,
          fromMemory.map!.checkpoints.length);
    });
  });
}

Matcher isBeforeOrAt(DateTime time) => predicate<DateTime>(
  (candidate) => !candidate.isAfter(time),
  'is before or at $time',
);

/// A [FileSystem] wrapper that deliberately does NOT implement
/// [RangedReadFileSystem] — exercises the whole-file fallback path.
final class _NonRangedFs implements FileSystem {
  _NonRangedFs(this._inner);

  final FileSystem _inner;

  @override
  String get cwd => _inner.cwd;

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _inner.absolutePath(path);

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      _inner.joinPath(parts);

  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _inner.readTextFile(path);

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) =>
      _inner.readBinaryFile(path);

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) => _inner.readTextLines(path, maxLines: maxLines);

  @override
  Future<Result<void, FileError>> writeBinaryFile(String path, Uint8List b) =>
      _inner.writeBinaryFile(path, b);

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      _inner.writeFile(path, content);

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      _inner.appendFile(path, content);

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      _inner.fileInfo(path);

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      _inner.listDir(path);

  @override
  Future<Result<bool, FileError>> exists(String path) => _inner.exists(path);

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => _inner.createDir(path, recursive: recursive);

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => _inner.remove(path, recursive: recursive, force: force);
}
