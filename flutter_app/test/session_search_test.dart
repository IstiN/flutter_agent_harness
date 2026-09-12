// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The shared session-search filter (issue #200): `UT-filter` (AC1), the
/// instrumented zero-I/O budget (AC5) and the Unicode folding edge (E5).
/// The function is a pure filter over in-memory rows — no repo, no env.
import 'package:fa/ui/widgets/session_search_field.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Flips true when #198/#220 (sessions tree grouping) has landed: AC2's
/// dimmed-parent/hidden-sibling tree cases run then. The filter function
/// itself is tree-agnostic by contract — it ranks plain rows.
const bool kSessionsTreeLanded = false;

/// One row of the test fixture: a plain projection of a session.
class _Row {
  _Row(this.id, {this.title = '', this.cwd, DateTime? updatedAt})
    : updatedAt = updatedAt ?? DateTime(2026, 1, 15, 11, 5);

  final String id;
  final String title;
  final String? cwd;
  final DateTime updatedAt;

  ({String title, String id, String? cwd, DateTime updatedAt}) fields() =>
      (title: title, id: id, cwd: cwd, updatedAt: updatedAt);
}

List<_Row> _search(List<_Row> rows, String query) =>
    rankSessionEntries(rows, query, (r) => r.fields());

void main() {
  group('sessionSearchRank (UT-filter, AC1)', () {
    final named = _Row('s1', title: 'Goal Builder');
    final byId = _Row('agent-42');
    final byCwd = _Row('s3', cwd: '/work/goal_builder');
    final byStamp = _Row('s4', updatedAt: DateTime(2026, 1, 15, 11, 5));

    test('a display name match ranks first', () {
      expect(
        sessionSearchRank(
          query: 'goal',
          title: 'Goal Builder',
          id: 's1',
          cwd: null,
          updatedAt: named.updatedAt,
        ),
        0,
      );
    });

    test('id, cwd basename and timestamp text match at rank 1', () {
      int rank(_Row r, String q) => sessionSearchRank(
        query: q,
        title: r.title,
        id: r.id,
        cwd: r.cwd,
        updatedAt: r.updatedAt,
      );
      expect(rank(byId, 'agent-42'), 1);
      // The full cwd does NOT match — the basename is the field.
      expect(rank(byCwd, '/work'), -1);
      expect(rank(byCwd, 'goal_builder'), 1);
      // Both timestamp spellings hit: the month-day form and the 24h one.
      expect(rank(byStamp, 'jan 15'), 1);
      expect(rank(byStamp, '11:05'), 1);
    });

    test('a row matches if ANY field does; non-matches hide', () {
      final rows = [named, byId, byCwd, byStamp, _Row('s5')];
      expect(_search(rows, 'goal').map((r) => r.id), ['s1', 's3']);
      expect(_search(rows, 'zzz-nothing'), isEmpty);
    });

    test('matching is case-insensitive and Unicode-aware (E5)', () {
      final cyrillic = _Row('ru', title: 'Сессия Сборки');
      expect(_search([cyrillic], 'СБОРКИ').map((r) => r.id), ['ru']);
      expect(_search([cyrillic], 'сборка'), isEmpty);
      expect(_search([named], 'GOAL BUILDER').map((r) => r.id), ['s1']);
    });

    test('a blank query matches everything and filters nothing', () {
      final rows = [named, byId];
      expect(identical(_search(rows, ''), rows), isTrue);
      expect(identical(_search(rows, '   '), rows), isTrue);
    });
  });

  group('rankSessionEntries', () {
    test('name matches rank first, order inside a tier is stable', () {
      // Both match 'alpha': s-a via title (tier 0), s-b only via cwd
      // (tier 1). The name match surfaces first; s-b and s-c keep their
      // relative order inside tier 1.
      final rows = [
        _Row('s-b', cwd: '/work/alpha'),
        _Row('s-c', cwd: '/work/alpha-team'),
        _Row('s-a', title: 'Alpha'),
      ];
      expect(_search(rows, 'alpha').map((r) => r.id), ['s-a', 's-b', 's-c']);
    });
  });

  group('zero-I/O performance (AC5)', () {
    test('500 sessions filter in under one frame (16 ms)', () {
      final rows = List<_Row>.generate(
        500,
        (i) => _Row(
          'session-$i',
          title: i % 3 == 0 ? 'goal_builder $i' : 'run $i',
          cwd: '/work/project-${i % 7}',
          updatedAt: DateTime(2026, 1, 15, 10 + i % 12, i % 60),
        ),
      );
      final watch = Stopwatch()..start();
      final hits = _search(rows, 'goal_builder');
      watch.stop();
      expect(hits, isNotEmpty);
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 16)));
    });
  });

  test(
    'a matching child surfaces under its dimmed parent with non-matching '
    'siblings hidden (AC2, IT-tree-filter)',
    () {
      // Implemented when #198/#220 lands: rank the tree rows, keep a
      // matched child's parent as dimmed auto-expanded context.
    },
    skip: kSessionsTreeLanded
        ? null
        : 'AC2 rides #198/#220 tree grouping; the filter function is '
              'tree-agnostic by contract and is pinned by UT-filter above',
  );
}
