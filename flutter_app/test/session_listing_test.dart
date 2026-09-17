import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/session_listing.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

SessionMetadata _meta(String id, {DateTime? createdAt, DateTime? lastUpdated}) {
  final created = createdAt ?? DateTime.utc(2026, 1, 1);
  return SessionMetadata(
    id: id,
    createdAt: created,
    cwd: '/work',
    path: '/sessions/$id.jsonl',
    lastUpdatedAt: lastUpdated,
  );
}

void main() {
  group('compareSessionsNewestFirst', () {
    test('orders by last-updated descending', () {
      final older = _meta('a', lastUpdated: DateTime.utc(2026, 1, 1));
      final newer = _meta('b', lastUpdated: DateTime.utc(2026, 1, 2));
      expect(compareSessionsNewestFirst(newer, older), isNegative);
      expect(compareSessionsNewestFirst(older, newer), isPositive);
    });

    test('falls back to createdAt when never updated', () {
      final older = _meta('a', createdAt: DateTime.utc(2026, 1, 1));
      final newer = _meta('b', createdAt: DateTime.utc(2026, 1, 2));
      expect(compareSessionsNewestFirst(newer, older), isNegative);
    });

    test('compares equal metadata to zero', () {
      final time = DateTime.utc(2026, 1, 2);
      expect(
        compareSessionsNewestFirst(
          _meta('a', createdAt: time, lastUpdated: time),
          _meta('b', createdAt: time, lastUpdated: time),
        ),
        isZero,
      );
    });
  });

  group('mergeSessionsAcrossRoots', () {
    test('dedupes by id across roots and sorts newest first', () async {
      final merged = await mergeSessionsAcrossRoots(
        roots: ['default', 'shared'],
        listRoot: (root) async => [
          // Both roots know 'a'; the default root's copy must win.
          _meta('a', createdAt: DateTime.utc(2026, 1, 1)),
          if (root == 'shared')
            _meta('b', createdAt: DateTime.utc(2026, 1, 3))
          else
            _meta('c', createdAt: DateTime.utc(2026, 1, 2)),
        ],
      );
      expect(merged.map((m) => m.id), ['b', 'c', 'a']);
    });

    test('a failing secondary root is non-fatal', () async {
      final merged = await mergeSessionsAcrossRoots(
        roots: ['default', 'broken'],
        listRoot: (root) async =>
            root == 'broken' ? throw StateError('unmounted') : [_meta('a')],
      );
      expect(merged.map((m) => m.id), ['a']);
    });

    test('no roots yields an empty listing', () async {
      expect(
        await mergeSessionsAcrossRoots(
          roots: const <String>[],
          listRoot: (_) async => throw StateError('never called'),
        ),
        isEmpty,
      );
    });
  });

  group('relinkSubagentParents', () {
    test('re-points listed ids at their resolved parent path', () {
      final listed = [_meta('child'), _meta('fresh')];
      final relinked = relinkSubagentParents(listed, {'child': '/p/parent'});
      expect(
        relinked.singleWhere((m) => m.id == 'child').metadata?['parent'],
        '/p/parent',
      );
      expect(
        relinked.singleWhere((m) => m.id == 'fresh').metadata?['parent'],
        isNull,
      );
    });

    test('nothing to relink returns the metadata unchanged', () {
      final listed = [_meta('a')];
      final relinked = relinkSubagentParents(listed, const {});
      expect(relinked.single, same(listed.single));
    });
  });
}
