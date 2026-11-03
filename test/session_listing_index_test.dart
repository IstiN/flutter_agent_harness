// Issue #2053 — persisted listing index + fingerprint incremental scan +
// segment shortcut + lazy names, at the JsonlSessionRepo level.
//
// All tests run on a fake (in-memory) FS wrapped in a counter that tracks
// the op classes the ACs constrain: header reads (AC1), name-probe window
// reads (AC4), per-session segment listDirs (AC8), index reads/writes
// (AC6/AC7). The real corpus is never touched by tests.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/session_listing_index.dart';
import 'package:test/test.dart';

/// Wraps a [FileSystem] and counts the op classes the #2053 ACs talk
/// about. Everything else delegates untouched.
final class _CountingFs
    implements FileSystem, RangedReadFileSystem, RenamableFileSystem {
  _CountingFs(this._delegate);

  final FileSystem _delegate;

  /// `readTextLines(maxLines: 1)` over a `.jsonl` file — the per-session
  /// header read the warm listing must not perform (AC1).
  int headerReads = 0;

  /// `readRange` over a `.jsonl` file — the name-probe windows (AC4: zero
  /// on the boot path).
  int windowReads = 0;

  /// Reads/writes of the sidecar index itself.
  int indexReads = 0;
  int indexWrites = 0;

  /// `listDir` calls, keyed by directory (AC8 counts per-session segment
  /// discovery directories).
  final Map<String, int> listDirCalls = {};

  bool _isHeaderRead(String path, int? maxLines) =>
      maxLines == 1 && path.endsWith('.jsonl');
  bool _isIndexPath(String path) => path.contains('.listing-index.json');

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) async {
    if (_isHeaderRead(path, maxLines)) headerReads++;
    return _delegate.readTextLines(path, maxLines: maxLines);
  }

  @override
  Future<Result<Uint8List, FileError>> readRange(
    String path,
    int start,
    int end,
  ) async {
    if (path.endsWith('.jsonl')) windowReads++;
    final delegate = _delegate;
    if (delegate case final RangedReadFileSystem ranged) {
      return ranged.readRange(path, start, end);
    }
    return Err(
      const FileError(
        FileErrorCode.notSupported,
        'ranged reads not supported',
      ),
    );
  }

  @override
  Future<Result<String, FileError>> readTextFile(String path) async {
    if (_isIndexPath(path)) indexReads++;
    return _delegate.readTextFile(path);
  }

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) async {
    if (_isIndexPath(path)) indexWrites++;
    return _delegate.writeFile(path, content);
  }

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) async {
    listDirCalls[path] = (listDirCalls[path] ?? 0) + 1;
    return _delegate.listDir(path);
  }

  @override
  Future<Result<void, FileError>> renamePath(String from, String to) async {
    final delegate = _delegate;
    if (delegate case final RenamableFileSystem renamable) {
      return renamable.renamePath(from, to);
    }
    return Err(
      const FileError(
        FileErrorCode.notSupported,
        'rename not supported',
      ),
    );
  }

  @override
  String get cwd => _delegate.cwd;
  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _delegate.absolutePath(path);
  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      _delegate.joinPath(parts);
  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) =>
      _delegate.readBinaryFile(path);
  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) => _delegate.writeBinaryFile(path, content);
  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      _delegate.appendFile(path, content);
  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      _delegate.fileInfo(path);
  @override
  Future<Result<bool, FileError>> exists(String path) =>
      _delegate.exists(path);
  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => _delegate.createDir(path, recursive: recursive);
  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => _delegate.remove(path, recursive: recursive, force: force);
}

const _root = '/sessions';

_JsonlHeaderLine _header(
  String id,
  String cwd, {
  Map<String, dynamic>? metadata,
  String? parent,
}) => _JsonlHeaderLine(id, cwd, metadata, parent);

/// Raw session header writer for "a file appeared since the index" tests —
/// the writer path of a FOREIGN process (the index hook cannot see it).
class _JsonlHeaderLine {
  _JsonlHeaderLine(this.id, this.cwd, this.metadata, this.parent);

  final String id;
  final String cwd;
  final Map<String, dynamic>? metadata;
  final String? parent;

  Future<void> write(FileSystem fs, String path) async {
    final line = jsonEncode({
      'type': 'session',
      'version': 3,
      'id': id,
      'timestamp': DateTime.parse('2026-01-15T10:00:00.000Z').toIso8601String(),
      'cwd': cwd,
      if (parent != null) 'parentSession': parent,
      if (metadata != null) 'metadata': metadata,
    });
    await fs.writeFile(path, '$line\n');
  }
}

/// Seeds `count` sessions spread over `dirs` through the repo (real
/// headers, real create path).
Future<void> _seed(
  FileSystem fs, {
  required List<String> dirs,
  required int perDir,
  String Function(int dir, int i)? idFor,
}) async {
  final repo = JsonlSessionRepo(fs: fs, sessionsRoot: _root);
  for (var d = 0; d < dirs.length; d++) {
    for (var i = 0; i < perDir; i++) {
      final id = idFor?.call(d, i) ?? 's-$d-$i';
      await repo.create(
        JsonlSessionCreateOptions(id: id, cwd: dirs[d]),
      );
    }
  }
}

/// Field-for-field comparison of two listings (AC2's byte-comparable
/// metadata — [SessionMetadata] has no ==).
void _expectSameListings(List<SessionMetadata> a, List<SessionMetadata> b) {
  expect(b.length, a.length, reason: 'session count differs');
  for (var i = 0; i < a.length; i++) {
    final x = a[i];
    final y = b[i];
    expect(y.id, x.id, reason: 'order differs at $i');
    expect(y.path, x.path);
    expect(y.cwd, x.cwd);
    expect(y.createdAt, x.createdAt);
    expect(y.lastUpdatedAt, x.lastUpdatedAt);
    expect(y.sizeBytes, x.sizeBytes);
    expect(y.parentSessionPath, x.parentSessionPath);
    expect(y.metadata, x.metadata);
  }
}

void main() {
  late MemoryFileSystem base;
  late _CountingFs fs;
  late JsonlSessionRepo repo;

  setUp(() {
    base = MemoryFileSystem();
    fs = _CountingFs(base);
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: _root);
  });

  group('AC1 — warm boot is index-priced', () {
    test('warm list() performs zero header reads and zero window reads', () async {
      await _seed(fs, dirs: ['/work/a', '/work/b'], perDir: 3);
      await repo.list(); // cold: writes the index

      fs.headerReads = 0;
      fs.windowReads = 0;
      fs.indexWrites = 0;
      final warm = await repo.list();

      expect(warm, hasLength(6));
      expect(fs.headerReads, 0, reason: 'AC1: warm listing is index-priced');
      expect(fs.windowReads, 0);
      expect(fs.indexWrites, 0, reason: 'steady state: no index churn');
    });

    test('a created/deleted/mutated file since the index costs one re-read',
        () async {
      await _seed(fs, dirs: ['/work/a'], perDir: 3);
      await repo.list();

      fs.headerReads = 0;
      await _header('late', '/work/a').write(
        base,
        '$_root/--work-a--/20260201T00-00-00-000_late.jsonl',
      );
      final listed = await repo.list();
      expect(listed, hasLength(4));
      expect(fs.headerReads, 1, reason: 'only the new file is read');
    });
  });

  group('AC2 — cold path is semantically identical', () {
    test('no index: same set + order as a second cold scan', () async {
      await _seed(fs, dirs: ['/work/a', '/work/b'], perDir: 2);
      await repo.create(
        const JsonlSessionCreateOptions(
          id: 'rich',
          cwd: '/work/b',
          parentSessionPath: '$_root/other.jsonl',
          metadata: {'agent': 'subagent', 'parent': 'p1', 'n': 3},
        ),
      );
      final first = await repo.list();

      // Wipe the index: a fresh cold scan must produce the same rows.
      await base.remove('$_root/.listing-index.json', force: true);
      fs.headerReads = 0;
      final second = await repo.list();

      _expectSameListings(first, second);
      expect(fs.headerReads, greaterThanOrEqualTo(5));
    });

    test('corrupt index: ignored, full scan, index rewritten', () async {
      await _seed(fs, dirs: ['/work/a'], perDir: 2);
      final expected = await repo.list();

      await base.writeFile(
        '$_root/.listing-index.json',
        '{"version":1,"dirs":{,"entries":[', // torn mid-write
      );
      final listed = await repo.list();
      _expectSameListings(expected, listed);

      // And the sidecar is healthy again (AC7 rewrite).
      final healed = await base.readTextFile('$_root/.listing-index.json');
      final decoded = jsonDecode(healed.valueOrNull!);
      expect(decoded, isA<Map>());
      expect((decoded as Map)['entries'], hasLength(2));
    });

    test('version-drift index: treated as cold', () async {
      await _seed(fs, dirs: ['/work/a'], perDir: 2);
      final expected = await repo.list();

      await base.writeFile(
        '$_root/.listing-index.json',
        jsonEncode({
          'version': 99,
          'writtenAt': 1,
          'dirs': <String, dynamic>{},
          'entries': <dynamic>[],
        }),
      );
      fs.headerReads = 0;
      final listed = await repo.list();

      _expectSameListings(expected, listed);
      expect(fs.headerReads, 2, reason: 'foreign version: full scan');
      final healed = await base.readTextFile('$_root/.listing-index.json');
      expect(
        (jsonDecode(healed.valueOrNull!) as Map)['version'],
        SessionListingIndex.currentVersion,
      );
    });

    test('index listing order matches the cold newest-first order', () async {
      await _seed(fs, dirs: ['/work/a'], perDir: 4);
      final cold = await repo.list();
      final warm = await repo.list();
      _expectSameListings(cold, warm);
      for (var i = 1; i < warm.length; i++) {
        final a = warm[i - 1].lastUpdatedAt ?? warm[i - 1].createdAt;
        final b = warm[i].lastUpdatedAt ?? warm[i].createdAt;
        expect(a.isBefore(b), isFalse, reason: 'newest first');
      }
    });
  });

  group('AC3 — no stale tiles ever (incremental refresh)', () {
    test('created since index: seen', () async {
      await _seed(fs, dirs: ['/work/a'], perDir: 2);
      await repo.list();
      await _header('new-guy', '/work/a').write(
        base,
        '$_root/--work-a--/20260202T00-00-00-000_new-guy.jsonl',
      );
      final listed = await repo.list();
      expect(listed.map((m) => m.id), contains('new-guy'));
    });

    test('deleted since index: gone (never resurrected)', () async {
      await _seed(fs, dirs: ['/work/a'], perDir: 2);
      final before = await repo.list();
      final victim = before.first;
      await base.remove(victim.path, force: true);

      final listed = await repo.list();
      expect(listed.map((m) => m.id), isNot(contains(victim.id)));
      // And twice more — the index must not regress the deletion.
      expect((await repo.list()).map((m) => m.id), isNot(contains(victim.id)));
    });

    test('rotated since index: stats + segments reflected', () async {
      final session = await repo.create(
        const JsonlSessionCreateOptions(
          id: 'rotates',
          cwd: '/work/a',
          rotateBytes: 64,
        ),
      );
      await repo.list(); // index without rotation knowledge

      // Append past the tiny rotation threshold: the primary is renamed
      // to a part and reseeded (writer path — the index hook fires).
      await session.appendMessage(
        UserMessage.text('x' * 256),
      );

      final listed = await repo.list();
      final row = listed.where((m) => m.id == 'rotates').single;
      final info = (await base.fileInfo(row.path)).valueOrNull!;
      expect(row.sizeBytes, info.size, reason: 'stats refreshed');
      expect(row.lastUpdatedAt, isNotNull);

      // A warm re-list stays zero-read despite the mutation.
      fs.headerReads = 0;
      final warm = await repo.list();
      expect(warm.where((m) => m.id == 'rotates').single.sizeBytes, info.size);
      expect(fs.headerReads, 0);
    });

    test('moved since index: old path gone, new path listed', () async {
      await _seed(fs, dirs: ['/work/a', '/work/b'], perDir: 2);
      await repo.list();
      final before = await repo.list();
      final victim = before.first;

      final newName = victim.path.replaceAll('/work/a/', '/work/b/');
      final renamed = await (base as RenamableFileSystem).renamePath(
        victim.path,
        newName,
      );
      expect(renamed.isOk, isTrue);

      final listed = await repo.list();
      expect(listed.map((m) => m.id), contains(victim.id));
      expect(listed.where((m) => m.id == victim.id).single.path, newName);
    });

    test('same-size same-mtime swap inside a directory is still caught', () async {
      // The documented fingerprint residual (count+size+mtime identical):
      // two same-size files swapping identities. The per-entry stat
      // cross-check catches it — a stale entry can never serve the wrong
      // file's metadata.
      final repoA = JsonlSessionRepo(fs: fs, sessionsRoot: _root);
      final s1 = await repoA.create(
        const JsonlSessionCreateOptions(id: 'swap-a', cwd: '/work/s'),
      );
      final s2 = await repoA.create(
        const JsonlSessionCreateOptions(id: 'swap-b', cwd: '/work/s'),
      );
      await repoA.list();

      // Swap the file CONTENTS (headers) 1:1 — same sizes, and force the
      // same mtime by writing both then pinning mtimes through a rewrite.
      final p1 = (s1.getStorage() as JsonlSessionStorage).cachedMetadata.path;
      final p2 = (s2.getStorage() as JsonlSessionStorage).cachedMetadata.path;
      final c1 = (await base.readTextFile(p1)).valueOrNull!;
      final c2 = (await base.readTextFile(p2)).valueOrNull!;
      await base.writeFile(p1, c2);
      await base.writeFile(p2, c1);

      final listed = await repoA.list();
      expect(listed.where((m) => m.id == 'swap-a').single.path, p1);
      expect(listed.where((m) => m.id == 'swap-b').single.path, p2);
      final rowA = listed.where((m) => m.id == 'swap-a').single;
      final statA = (await base.fileInfo(p1)).valueOrNull!;
      expect(rowA.sizeBytes, statA.size);
    });
  });

  group('AC6 — writers keep the index fresh', () {
    test('create updates the sidecar in the same operation', () async {
      await _seed(fs, dirs: ['/work/a'], perDir: 1);
      await repo.list();
      fs.indexWrites = 0;
      await repo.create(
        const JsonlSessionCreateOptions(id: 'fresh', cwd: '/work/a'),
      );
      expect(fs.indexWrites, 1, reason: 'AC6: index updated by create');
      final raw = await base.readTextFile('$_root/.listing-index.json');
      final index = SessionListingIndex.fromJson(
        jsonDecode(raw.valueOrNull!),
      )!;
      expect(index.entryById('fresh'), isNotNull);

      // And the next listing is already warm (the writer refreshed the
      // touched directory's fingerprint terms).
      fs.headerReads = 0;
      await repo.list();
      expect(fs.headerReads, 0);
    });

    test('delete (soft) drops the sidecar entry in the same operation', () async {
      await _seed(fs, dirs: ['/work/a'], perDir: 2);
      final before = await repo.list();
      final victim = before.first;
      fs.indexWrites = 0;
      await repo.delete(victim);
      expect(fs.indexWrites, 1, reason: 'AC6: index updated by delete');
      final raw = await base.readTextFile('$_root/.listing-index.json');
      final index = SessionListingIndex.fromJson(
        jsonDecode(raw.valueOrNull!),
      )!;
      expect(index.entryById(victim.id), isNull);
      expect(
        index.entries.map((e) => e.path),
        isNot(contains(victim.path)),
      );
    });

    test('rotation fires the storage hook and updates the sidecar', () async {
      final session = await repo.create(
        const JsonlSessionCreateOptions(
          id: 'rotator',
          cwd: '/work/a',
          rotateBytes: 64,
        ),
      );
      await repo.list();
      fs.indexWrites = 0;
      await session.appendMessage(UserMessage.text('y' * 300));

      expect(fs.indexWrites, 1, reason: 'AC6: rotation updates the index');
      final raw = await base.readTextFile('$_root/.listing-index.json');
      final index = SessionListingIndex.fromJson(
        jsonDecode(raw.valueOrNull!),
      )!;
      final entry = index.entryById('rotator')!;
      expect(entry.hasParts, isTrue, reason: 'segment knowledge persisted');
      final info = (await base.fileInfo(entry.path)).valueOrNull!;
      expect(entry.sizeBytes, info.size);
    });

    test('failed-rotation restore fires the hook too', () async {
      final session = await repo.create(
        const JsonlSessionCreateOptions(
          id: 'restorer',
          cwd: '/work/a',
          rotateBytes: 64,
        ),
      );
      await repo.list();

      // Make the post-rename RESEED of the primary fail once: the rotate
      // then restores the primary from the part — and the hook must fire
      // for that restore as well (AC6 "restore"). The hook is wired on
      // the opened storage exactly the way the repo wires its index
      // updater.
      final rotations = <String>[];
      final flaky = _FailNextPrimaryWrite(base);
      final hooked = JsonlSessionRepo(fs: flaky, sessionsRoot: _root);
      final viaHooked = await hooked.open(
        (session.getStorage() as JsonlSessionStorage).cachedMetadata,
      );
      // The opened storage rides the shipped rotation threshold; shrink
      // it for the test (the hook rides the rebuilt storage too).
      final limited = (viaHooked.getStorage() as JsonlSessionStorage)
          .withRotationLimits(rotateBytes: 64)
        ..onMutated = (path) async => rotations.add(path);
      await Session(limited).appendMessage(UserMessage.text('z' * 300));
      expect(rotations, hasLength(1));
    });

    test('CLI + app racing: last-writer-wins converges via the fingerprint',
        () async {
      await _seed(fs, dirs: ['/work/a'], perDir: 2);
      final app = JsonlSessionRepo(fs: fs, sessionsRoot: _root);
      final cli = JsonlSessionRepo(fs: fs, sessionsRoot: _root);

      final appView = await app.list(); // app writes the index
      await cli.create(
        const JsonlSessionCreateOptions(id: 'from-cli', cwd: '/work/b'),
      ); // CLI rewrites the index last

      // The app's next listing must see the CLI's session — the index the
      // CLI wrote is validated by the fingerprint and merged.
      final converged = await app.list();
      expect(converged.map((m) => m.id), contains('from-cli'));
      expect(converged.length, appView.length + 1);
      // And a warm re-list stays consistent.
      _expectSameListings(converged, await app.list());
    });
  });

  group('AC7 — fail-open everywhere', () {
    test('a broken index never breaks boot', () async {
      await _seed(fs, dirs: ['/work/a'], perDir: 2);
      final expected = await repo.list();
      for (final garbage in <String>[
        '',
        'not json',
        '[]',
        '{"version":1,"dirs":{},"entries":"nope"}',
        '{"version":1,"dirs":{"x":[1,2]},"entries":[]}',
        '{"version":"1","dirs":{},"entries":[]}',
      ]) {
        await base.writeFile('$_root/.listing-index.json', garbage);
        final listed = await repo.list();
        _expectSameListings(expected, listed);
      }
    });

    test('missing sessions root lists empty, with or without an index', () async {
      final emptyRepo = JsonlSessionRepo(
        fs: fs,
        sessionsRoot: '/sessions-does-not-exist',
      );
      expect(await emptyRepo.list(), isEmpty);
    });

    test('empty root and single-file root', () async {
      expect(await repo.list(), isEmpty);
      await base.createDir('$_root/--work--', recursive: true);
      await _header('only', '/work').write(
        base,
        '$_root/--work--/20260101T00-00-00-000_only.jsonl',
      );
      final listed = await repo.list();
      expect(listed, hasLength(1));
      final warm = await repo.list();
      _expectSameListings(listed, warm);
    });
  });

  group('AC8 — segment discovery shortcut', () {
    test('cold listing + names with no segments: no per-session listDirs',
        () async {
      await _seed(fs, dirs: ['/work/a'], perDir: 3);
      final named = await repo.create(
        const JsonlSessionCreateOptions(id: 'named', cwd: '/work/a'),
      );
      await named.appendSessionName('The Named One');
      final sessions = await repo.list();
      expect(sessions, hasLength(4));

      fs.listDirCalls.clear();
      final names = await repo.sessionNamesQuick(sessions);
      expect(names['named'], 'The Named One');
      // The walk already saw every directory; name resolution adds ZERO
      // directory reads when no `.part-` siblings exist.
      expect(fs.listDirCalls, isEmpty,
          reason: 'AC8: segment discovery rides the walk');
    });

    test('with segments present: names still resolve (discovery unchanged)',
        () async {
      final rotated = await repo.create(
        const JsonlSessionCreateOptions(
          id: 'rotated-named',
          cwd: '/work/a',
          rotateBytes: 64,
        ),
      );
      await rotated.appendMessage(UserMessage.text('filler' * 40));
      await rotated.appendSessionName('Newest Name');

      final sessions = await repo.list();
      final names = await repo.sessionNamesQuick(sessions);
      expect(names['rotated-named'], 'Newest Name',
          reason: 'the newest session_info wins, wherever it lives');
    });

    test('a stale walk hint is dropped by writer mutations', () async {
      await _seed(fs, dirs: ['/work/a'], perDir: 2);
      final sessions = await repo.list();
      // create() clears the parts knowledge — a later names pass must not
      // trust a hint that predates the mutation.
      await repo.create(
        const JsonlSessionCreateOptions(id: 'after-create', cwd: '/work/a'),
      );
      final names = await repo.sessionNamesQuick(sessions);
      expect(sessions, hasLength(2));
      expect(names, isEmpty);
    });
  });

  group('AC4 core — lazy name persistence', () {
    test('rememberSessionNames persists a learned name for the next boot',
        () async {
      final session = await repo.create(
        const JsonlSessionCreateOptions(id: 'labelled', cwd: '/work/a'),
      );
      await session.appendSessionName('Persisted Name');
      final sessions = await repo.list();
      expect(await repo.knownSessionNames(), isEmpty);

      final probed = await repo.sessionNamesQuick(sessions);
      expect(probed['labelled'], 'Persisted Name');
      await repo.rememberSessionNames(probed);

      // The NEXT boot (fresh repo instance) knows the name with zero
      // window reads.
      final freshRepo = JsonlSessionRepo(fs: fs, sessionsRoot: _root);
      fs.windowReads = 0;
      expect(await freshRepo.knownSessionNames(), {
        'labelled': 'Persisted Name',
      });
      expect(fs.windowReads, 0);
      await freshRepo.list(); // warm
      fs.windowReads = 0;
      expect(fs.windowReads, 0);
    });

    test('rememberSessionNames is guarded: a changed file drops the name',
        () async {
      final session = await repo.create(
        const JsonlSessionCreateOptions(id: 'renamed-later', cwd: '/work/a'),
      );
      final sessions = await repo.list();
      expect(sessions, hasLength(1));
      await repo.rememberSessionNames({
        'renamed-later': 'First Name',
      });
      expect(await repo.knownSessionNames(), {
        'renamed-later': 'First Name',
      });

      // A /rename appends a record — the file's stats change, so the next
      // boot must NOT serve the frozen name (it may be stale).
      await session.appendSessionName('Second Name');
      expect((await repo.knownSessionNames())['renamed-later'], isNull,
          reason: 'the fingerprint caught the append: name re-learned lazily');
    });
  });

  group('index store — two-process write races', () {
    test('tmp + rename: last writer wins, no torn read served', () async {
      const store = SessionListingIndexStore();
      await base.createDir(_root, recursive: true);
      final first = SessionListingIndex(
        dirStats: const {'': ListingDirStats(
          fileCount: 1,
          totalBytes: 10,
          maxMtimeMs: 1,
        )},
        entries: [
          const SessionListingIndexEntry(
            id: 'a',
            path: '$_root/a.jsonl',
            sizeBytes: 10,
            mtimeMs: 1,
            createdAtIso: '2026-01-01T00:00:00.000Z',
            cwd: '/work',
          ),
        ],
        writtenAtMs: 1,
      );
      final second = SessionListingIndex(
        dirStats: const {
          '': ListingDirStats(fileCount: 2, totalBytes: 20, maxMtimeMs: 2),
        },
        entries: [
          const SessionListingIndexEntry(
            id: 'a',
            path: '$_root/a.jsonl',
            sizeBytes: 10,
            mtimeMs: 1,
            createdAtIso: '2026-01-01T00:00:00.000Z',
            cwd: '/work',
          ),
          const SessionListingIndexEntry(
            id: 'b',
            path: '$_root/b.jsonl',
            sizeBytes: 10,
            mtimeMs: 2,
            createdAtIso: '2026-01-02T00:00:00.000Z',
            cwd: '/work',
          ),
        ],
        writtenAtMs: 2,
      );
      await Future.wait([
        store.write(base, _root, first),
        store.write(base, _root, second),
      ]);
      final read = await store.read(base, _root);
      expect(read, isNotNull);
      // Last-writer-wins: the served snapshot is exactly ONE of the two
      // writes, never a mix.
      final ids = read!.entries.map((e) => e.id).toSet();
      expect(ids, anyOf(<String>{'a'}, <String>{'a', 'b'}));
      // And no tmp litter survives.
      final listed = await base.listDir(_root);
      expect(
        listed.valueOrNull!.where((e) => e.name.contains('.tmp')),
        isEmpty,
      );
    });
  });

  group('persistListingIndex = false — the pre-#2053 path', () {
    test('behaves like today: full scan every time, no sidecar', () async {
      final plain = JsonlSessionRepo(
        fs: fs,
        sessionsRoot: _root,
        persistListingIndex: false,
      );
      await _seed(fs, dirs: ['/work/a'], perDir: 2);
      final first = await plain.list();
      fs.headerReads = 0;
      final second = await plain.list();
      _expectSameListings(first, second);
      expect(fs.headerReads, 2, reason: 'no index: every listing re-reads');
      expect(
        (await base.exists('$_root/.listing-index.json')).valueOrNull,
        isFalse,
      );
    });
  });
}

/// A decorator that fails the NEXT short write to a `.jsonl` primary (the
/// rotation reseed), then passes everything — forces the failed-rotation
/// restore path deterministically.
final class _FailNextPrimaryWrite
    implements FileSystem, RangedReadFileSystem, RenamableFileSystem {
  _FailNextPrimaryWrite(this._delegate);

  final FileSystem _delegate;
  bool _armed = true;

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) async {
    if (_armed && path.endsWith('.jsonl') && content.length < 512) {
      _armed = false;
      return Err(
        FileError(FileErrorCode.unknown, 'injected reseed failure', path: path),
      );
    }
    return _delegate.writeFile(path, content);
  }

  @override
  String get cwd => _delegate.cwd;
  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _delegate.absolutePath(path);
  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      _delegate.joinPath(parts);
  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _delegate.readTextFile(path);
  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) => _delegate.readTextLines(path, maxLines: maxLines);
  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) =>
      _delegate.readBinaryFile(path);
  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) => _delegate.writeBinaryFile(path, content);
  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      _delegate.appendFile(path, content);
  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      _delegate.fileInfo(path);
  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      _delegate.listDir(path);
  @override
  Future<Result<bool, FileError>> exists(String path) =>
      _delegate.exists(path);
  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => _delegate.createDir(path, recursive: recursive);
  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => _delegate.remove(path, recursive: recursive, force: force);
  @override
  Future<Result<void, FileError>> renamePath(String from, String to) async {
    final delegate = _delegate;
    if (delegate case final RenamableFileSystem renamable) {
      return renamable.renamePath(from, to);
    }
    return Err(
      const FileError(FileErrorCode.notSupported, 'rename not supported'),
    );
  }

  @override
  Future<Result<Uint8List, FileError>> readRange(
    String path,
    int start,
    int end,
  ) async {
    final delegate = _delegate;
    if (delegate case final RangedReadFileSystem ranged) {
      return ranged.readRange(path, start, end);
    }
    return Err(
      const FileError(
        FileErrorCode.notSupported,
        'ranged reads not supported',
      ),
    );
  }
}
