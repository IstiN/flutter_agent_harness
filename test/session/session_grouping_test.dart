import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// UT-group (issue #198): `groupSessionsByParent` — children nest under
/// their parent, orphans surface top-level, order is preserved per level,
/// and grouping a large list performs no I/O beyond the caller's header
/// reads.
void main() {
  SessionMetadata meta(
    String id, {
    Map<String, dynamic>? metadata,
    DateTime? at,
    String cwd = '/work',
  }) {
    return SessionMetadata(
      id: id,
      createdAt: at ?? DateTime.utc(2026, 9, 12, 15, 22),
      cwd: cwd,
      path: '/sessions/$id.jsonl',
      metadata: metadata,
    );
  }

  SessionMetadata mainSession(
    String id, {
    DateTime? at,
    String cwd = '/work',
  }) => meta(id, at: at, cwd: cwd, metadata: {'agent': 'cli', 'model': 'm'});

  SessionMetadata child(
    String id,
    String parentId, {
    DateTime? at,
    String cwd = '/work',
  }) => meta(
    id,
    at: at,
    cwd: cwd,
    metadata: {'agent': 'subagent', 'id': 'ag-$id', 'parent': parentId},
  );

  group('classification', () {
    test('a session without metadata (pre-feature file) is a main', () {
      expect(isSubagentSession(meta('plain')), isFalse);
      expect(subagentParentId(meta('plain')), isNull);
    });

    test('cli/app agents are mains; subagent carries its parent id', () {
      expect(isSubagentSession(mainSession('m1')), isFalse);
      expect(isSubagentSession(child('c1', 'm1')), isTrue);
      expect(subagentParentId(child('c1', 'm1')), 'm1');
    });
  });

  group('groupSessionsByParent', () {
    test('a list with no children yields one group per main, in order', () {
      final a = mainSession('a');
      final b = mainSession('b');
      final groups = groupSessionsByParent([a, b]);
      expect(groups, hasLength(2));
      expect(groups[0].main.id, 'a');
      expect(groups[0].children, isEmpty);
      expect(groups[1].main.id, 'b');
    });

    test('children attach to their parent when it is in the list', () {
      final parent = mainSession('p');
      final c1 = child('c1', 'p');
      final c2 = child('c2', 'p');
      final other = mainSession('other');
      final groups = groupSessionsByParent([c2, parent, c1, other]);
      expect(groups, hasLength(2));
      expect(groups[0].main.id, 'p');
      expect(groups[0].children.map((m) => m.id), ['c2', 'c1']);
      expect(groups[1].main.id, 'other');
    });

    test('a child whose parent is missing from the list is an orphan: '
        'top-level group, still marked as a subagent', () {
      final orphan = child('orphan', 'deleted-parent');
      final groups = groupSessionsByParent([orphan]);
      expect(groups, hasLength(1));
      expect(groups.single.main.id, 'orphan');
      expect(groups.single.children, isEmpty);
      expect(isSubagentSession(groups.single.main), isTrue);
    });

    test('a subagent with an empty parent id never vanishes: it surfaces '
        'top-level with the subagent marker (both hosts wrote parent: '
        "'' before the writers stamped real ids)", () {
      final emptyParent = child('empty-parent', '');
      final groups = groupSessionsByParent([mainSession('p'), emptyParent]);
      expect(groups.map((g) => g.main.id), ['p', 'empty-parent']);
      expect(isSubagentSession(groups[1].main), isTrue);
      expect(groups[1].children, isEmpty);
    });

    test('a self-referential parent id degrades to an orphan too', () {
      final groups = groupSessionsByParent([child('self', 'self')]);
      expect(groups, hasLength(1));
      expect(groups.single.main.id, 'self');
      expect(groups.single.children, isEmpty);
    });

    test('deep nesting is impossible: a child pointing at another child '
        'never nests below depth one', () {
      // Subagents cannot spawn subagents; a malformed child-of-child
      // header must degrade to an orphan, never a two-level tree.
      final parent = mainSession('p');
      final sub = child('sub', 'p');
      final grandchild = child('grand', 'sub');
      final groups = groupSessionsByParent([parent, sub, grandchild]);
      expect(groups, hasLength(2));
      expect(groups[0].main.id, 'p');
      expect(groups[0].children.map((m) => m.id), ['sub']);
      expect(groups[1].main.id, 'grand');
      expect(groups[1].children, isEmpty);
    });

    test('per-level order follows the input order (activity-sorted callers '
        'keep newest-first at both levels)', () {
      final newer = mainSession('newer', at: DateTime.utc(2026, 9, 12, 15));
      final older = mainSession('older', at: DateTime.utc(2026, 9, 10));
      final newestChild = child(
        'nc',
        'older',
        at: DateTime.utc(2026, 9, 12, 14),
      );
      final oldestChild = child('oc', 'older', at: DateTime.utc(2026, 9, 9));
      // Activity-descending input, exactly what the CLI list passes in.
      final groups = groupSessionsByParent([
        newer,
        newestChild,
        older,
        oldestChild,
      ]);
      expect(groups.map((g) => g.main.id), ['newer', 'older']);
      expect(groups[1].children.map((m) => m.id), ['nc', 'oc']);
    });

    test('orphans sit at their own activity position in the top level, '
        'not after every main', () {
      final newest = child(
        'newest-orphan',
        'gone',
        at: DateTime.utc(2026, 9, 12, 16),
      );
      final mid = mainSession('mid', at: DateTime.utc(2026, 9, 12, 12));
      final oldest = mainSession('oldest', at: DateTime.utc(2026, 9, 10));
      final groups = groupSessionsByParent([newest, mid, oldest]);
      expect(groups.map((g) => g.main.id), ['newest-orphan', 'mid', 'oldest']);
    });

    test('every child attaches to exactly one group; none is dropped', () {
      final sessions = <SessionMetadata>[
        mainSession('p1'),
        mainSession('p2'),
        for (var i = 0; i < 5; i++) child('p1-c$i', 'p1'),
        for (var i = 0; i < 3; i++) child('p2-c$i', 'p2'),
        child('lost', 'nowhere'),
      ];
      final groups = groupSessionsByParent(sessions);
      final grouped = groups.expand((g) => [g.main, ...g.children]);
      expect(grouped.map((m) => m.id).toSet(), hasLength(sessions.length));
      expect(
        groups.firstWhere((g) => g.main.id == 'p1').children,
        hasLength(5),
      );
      expect(
        groups.firstWhere((g) => g.main.id == 'p2').children,
        hasLength(3),
      );
    });

    test('AC5: grouping 500 sessions performs zero file reads beyond the '
        "caller's header reads", () async {
      final fs = _CountingFileSystem(MemoryFileSystem());
      final repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
      final parent = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
      );
      final parentId = parent.cachedId;
      for (var i = 0; i < 499; i++) {
        await repo.create(
          JsonlSessionCreateOptions(
            cwd: '/work',
            metadata: i.isEven
                ? {'agent': 'subagent', 'parent': parentId}
                : {'agent': 'cli'},
          ),
        );
      }
      final listed = await repo.list();
      expect(listed, hasLength(500));
      final readsAfterList = fs.reads;
      final groups = groupSessionsByParent(listed);
      expect(fs.reads, readsAfterList, reason: 'grouping must not read files');
      final withChildren = groups.where((g) => g.children.isNotEmpty).length;
      expect(withChildren, 1);
    });
  });
}

/// [FileSystem] decorator counting `readTextLines` calls — the header-only
/// read the session list is built from (AC5 instrument).
final class _CountingFileSystem implements FileSystem {
  _CountingFileSystem(this._inner);

  final FileSystem _inner;
  int reads = 0;

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) {
    reads++;
    return _inner.readTextLines(path, maxLines: maxLines);
  }

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
  Future<Result<void, FileError>> writeBinaryFile(String path, Uint8List c) =>
      _inner.writeBinaryFile(path, c);

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
