// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// Counts the operation classes a catalog refresh may perform, split by
/// session file so per-file assertions stay exact. Everything forwards.
final class _CountingFs extends ForwardingFs
    with ForwardingRangedReadFs, ForwardingRenamableFs {
  _CountingFs(super.delegate);

  int headerReads = 0;
  int stats = 0;

  /// Content reads of `.jsonl` session files per path (snippet heads,
  /// name-probe windows, whole-file reads).
  final contentReads = <String>[];

  void reset() {
    headerReads = 0;
    stats = 0;
    contentReads.clear();
  }

  int get totalContentReads => contentReads.length;

  int readsOf(String path) => contentReads.where((p) => p == path).length;

  bool _isSession(String path) => path.endsWith('.jsonl');

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) {
    if (maxLines == 1 && _isSession(path)) headerReads++;
    if (_isSession(path)) contentReads.add(path);
    return super.readTextLines(path, maxLines: maxLines);
  }

  @override
  Future<Result<String, FileError>> readTextFile(String path) {
    if (_isSession(path)) contentReads.add(path);
    return super.readTextFile(path);
  }

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) {
    if (_isSession(path)) contentReads.add(path);
    return super.readBinaryFile(path);
  }

  @override
  Future<Result<Uint8List, FileError>> readRange(
    String path,
    int start,
    int end,
  ) {
    if (_isSession(path)) contentReads.add(path);
    return super.readRange(path, start, end);
  }

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) {
    stats++;
    return super.fileInfo(path);
  }
}

List<String> _titles(List<SessionCatalogEntry> rows) => [
  for (final row in rows) '${row.id}|${row.title}|${row.snippet}',
];

void main() {
  test('JSONL catalog reads names, first prompt, exact cwd and lastActiveAt '
      'without opening whole transcripts', () async {
    final env = MemoryExecutionEnv();
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final named = await repo.create(
      JsonlSessionCreateOptions(
        id: '123e4567-e89b-12d3-a456-426614174000',
        cwd: '/work/flutter_agent',
      ),
    );
    await named.appendMessage(
      UserMessage.text('  First prompt\n with detail '),
    );
    await named.appendMessage(UserMessage.text('later prompt'));
    await named.appendSessionName('Roster work');
    final snippetOnly = await repo.create(
      JsonlSessionCreateOptions(id: 'snippet', cwd: '/work/other'),
    );
    await snippetOnly.appendMessage(UserMessage.text('Snippet title'));

    final store = JsonlSessionCatalogStore(repo: repo);
    final rows = await store.loadSessions(
      liveSessionIds: {'123e4567-e89b-12d3-a456-426614174000'},
    );

    expect(rows, hasLength(2));
    final namedRow = rows.singleWhere((row) => row.id == named.cachedId);
    expect(namedRow.sessionName, 'Roster work');
    expect(namedRow.title, 'Roster work');
    expect(namedRow.snippet, 'First prompt with detail');
    expect(namedRow.displayName, 'Roster work');
    expect(namedRow.cwd, '/work/flutter_agent');
    expect(namedRow.cwdSlug, 'flutter_agent');
    expect(namedRow.live, isTrue);
    expect(namedRow.lastActiveAt, isNotNull);
    final snippetRow = rows.singleWhere((row) => row.id == 'snippet');
    expect(snippetRow.title, isNull);
    expect(snippetRow.snippet, 'Snippet title');
    expect(snippetRow.displayName, 'other');
    expect(snippetRow.live, isFalse);
  });

  test(
    'JSONL catalog marks child and orphaned subagent headers for retraction',
    () async {
      final env = MemoryExecutionEnv();
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      await repo.create(
        const JsonlSessionCreateOptions(id: 'parent', cwd: '/work'),
      );
      await repo.create(
        const JsonlSessionCreateOptions(
          id: 'child',
          cwd: '/work',
          metadata: {'agent': 'subagent', 'parent': 'parent'},
        ),
      );
      await repo.create(
        const JsonlSessionCreateOptions(
          id: 'orphan',
          cwd: '/work',
          metadata: {'agent': 'subagent'},
        ),
      );

      final rows = await JsonlSessionCatalogStore(repo: repo).loadSessions();
      expect(rows.singleWhere((row) => row.id == 'parent').isSubagent, isFalse);
      expect(rows.singleWhere((row) => row.id == 'child').isSubagent, isTrue);
      expect(rows.singleWhere((row) => row.id == 'orphan').isSubagent, isTrue);
    },
  );

  test('catalog cache does not rescan an unchanged transcript and refreshes '
      'after append', () async {
    final env = MemoryExecutionEnv();
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final session = await repo.create(
      JsonlSessionCreateOptions(id: 'cached', cwd: '/work/cache'),
    );
    await session.appendMessage(UserMessage.text('Before'));
    final store = JsonlSessionCatalogStore(repo: repo);

    final first = await store.loadSessions();
    final second = await store.loadSessions();
    expect(second.single.snippet, first.single.snippet);
    expect(store.debugTranscriptScans, 1);

    await session.appendMessage(UserMessage.text('After'));
    final third = await store.loadSessions();
    expect(store.debugTranscriptScans, 2);
    expect(third.single.snippet, 'Before');
    expect(
      third.single.lastActiveAt.isAfter(first.single.lastActiveAt) ||
          third.single.lastActiveAt.isAtSameMomentAs(first.single.lastActiveAt),
      isTrue,
    );
  });

  group('stamp cache (gh-2410 cheap periodic pass)', () {
    late MemoryExecutionEnv memory;
    late _CountingFs fs;
    late JsonlSessionRepo repo;

    Future<Session> create(String id, {bool name = false}) async {
      final session = await repo.create(
        JsonlSessionCreateOptions(id: id, cwd: '/work/a'),
      );
      await session.appendMessage(UserMessage.text('Prompt of $id'));
      if (name) await session.appendSessionName('Named $id');
      return session;
    }

    Future<String> pathOf(String id) async =>
        (await repo.list()).singleWhere((m) => m.id == id).path;

    setUp(() async {
      memory = MemoryExecutionEnv();
      fs = _CountingFs(memory);
      repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
      await create('named', name: true);
      await create('unnamed');
    });

    test('a refresh on an unchanged store reads ZERO session content '
        '(stat only) and serves identical rows', () async {
      final store = JsonlSessionCatalogStore(repo: repo);
      final cold = await store.loadSessions();
      final coldScans = store.debugTranscriptScans;
      expect(cold, hasLength(2));
      expect(cold.singleWhere((r) => r.id == 'named').title, 'Named named');
      expect(
        cold.singleWhere((r) => r.id == 'unnamed').snippet,
        'Prompt of unnamed',
      );

      fs.reset();
      final warm = await store.loadSessions();
      expect(
        fs.totalContentReads,
        0,
        reason: 'an unchanged store must not re-read transcript windows',
      );
      expect(fs.headerReads, 0);
      expect(fs.stats, greaterThan(0), reason: 'the pass is stat-only');
      expect(store.debugTranscriptScans, coldScans);
      expect(_titles(warm), _titles(cold));
      expect(
        [for (final r in warm) r.lastActiveAt],
        [for (final r in cold) r.lastActiveAt],
      );
    });

    test('a file whose size OR mtime moved is re-read exactly once; new '
        'files are read; removed files disappear and are forgotten', () async {
      final store = JsonlSessionCatalogStore(repo: repo);
      final namedPath = await pathOf('named');
      final unnamedPath = await pathOf('unnamed');
      await store.loadSessions();
      await store.loadSessions(); // warm
      fs.reset();

      // Size change (append) on the named session.
      final named = (await repo.open(
        (await repo.list()).singleWhere((m) => m.id == 'named'),
      ));
      await named.appendMessage(UserMessage.text('more'));
      // mtime-only change on the unnamed session.
      final before = (await fs.fileInfo(unnamedPath)).valueOrNull!;
      memory.setMtime(unnamedPath, before.mtimeMs + 1000);
      // A new session since the last pass.
      await create('fresh');
      final freshPath = await pathOf('fresh');
      // (pathOf above listed the repo; only the catalog pass counts.)
      fs.reset();
      final rows = await store.loadSessions();
      expect(fs.readsOf(namedPath), greaterThanOrEqualTo(1));
      expect(
        fs.readsOf(unnamedPath),
        2,
        reason:
            'a changed file costs its snippet head + ONE name-probe '
            'window, then nothing until it changes again',
      );
      expect(fs.readsOf(freshPath), greaterThanOrEqualTo(1));
      expect(rows.map((r) => r.id), containsAll(['named', 'unnamed', 'fresh']));
      expect(store.debugCachedSessions, 3);

      // Unchanged again: nothing is re-read.
      fs.reset();
      await store.loadSessions();
      expect(fs.totalContentReads, 0);

      // Removal: the row disappears and the memo drops the file.
      await repo.delete(
        (await repo.list()).singleWhere((m) => m.id == 'fresh'),
        actor: 'test',
      );
      final afterDelete = await store.loadSessions();
      expect(afterDelete.map((r) => r.id), isNot(contains('fresh')));
      expect(store.debugCachedSessions, 2);
    });

    test('without a persisted listing index the memo alone serves names '
        'and keeps the warm pass at zero content reads', () async {
      // Hosts that must leave the sessions root byte-frozen: no index, so
      // every load starts from an empty name map — the memo is the only
      // thing standing between a refresh and a full re-probe.
      final bare = JsonlSessionRepo(
        fs: fs,
        sessionsRoot: '/sessions',
        persistListingIndex: false,
      );
      final store = JsonlSessionCatalogStore(repo: bare);
      final cold = await store.loadSessions();
      expect(cold.singleWhere((r) => r.id == 'named').title, 'Named named');
      expect(fs.totalContentReads, greaterThan(0));

      fs.reset();
      final warm = await store.loadSessions();
      expect(_titles(warm), _titles(cold));
      // repo.list() itself pays one bounded header read per file on its
      // index-less cold path (pre-#2053 semantics); the store's snippet
      // and name-probe windows are what the memo must eliminate.
      expect(fs.totalContentReads - fs.headerReads, 0);
    });

    test('a renamed session (new session_info) is re-probed under its new '
        'stamp and keeps serving the memoized name', () async {
      final store = JsonlSessionCatalogStore(repo: repo);
      await store.loadSessions();
      final unnamed = await repo.open(
        (await repo.list()).singleWhere((m) => m.id == 'unnamed'),
      );
      await unnamed.appendSessionName('Late name');
      final rows = await store.loadSessions();
      expect(rows.singleWhere((r) => r.id == 'unnamed').title, 'Late name');
      fs.reset();
      final again = await store.loadSessions();
      expect(fs.totalContentReads, 0);
      expect(again.singleWhere((r) => r.id == 'unnamed').title, 'Late name');
    });
  });
}
