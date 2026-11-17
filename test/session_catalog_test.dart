// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

final class _FakeCatalogStore implements SessionCatalogStore {
  _FakeCatalogStore(this.entries);

  List<SessionCatalogEntry> entries;

  @override
  Future<List<SessionCatalogEntry>> loadSessions({
    Set<String> liveSessionIds = const {},
  }) async => entries;
}

final class _FakeRoster {
  final patches = <List<SessionCatalogEntry>>[];
  final retractions = <String>[];

  void publish(SessionCatalogProjection projection) {
    if (projection.upserts.isNotEmpty) patches.add(projection.upserts);
    retractions.addAll(projection.retractedIds);
  }
}

SessionCatalogEntry _entry(
  String id, {
  DateTime? lastActiveAt,
  String? title,
  String? snippet,
  String? sessionName,
  String? cwd,
  bool live = false,
  bool isSubagent = false,
}) => SessionCatalogEntry(
  id: id,
  live: live,
  isSubagent: isSubagent,
  title: title,
  snippet: snippet,
  sessionName: sessionName,
  cwd: cwd ?? '/work/$id',
  lastActiveAt: lastActiveAt ?? DateTime.utc(2026, 11, 12),
);

void main() {
  group('session catalog projection', () {
    test('subagent marker participates in equality and hashing', () {
      final parent = _entry('session', title: 'Parent');
      final same = _entry('session', title: 'Parent');
      final child = _entry('session', title: 'Parent', isSubagent: true);

      expect(parent, same);
      expect(parent.hashCode, same.hashCode);
      expect(parent, isNot(child));
      expect(parent.hashCode, isNot(child.hashCode));
    });

    test('fake store to fake roster publishes every named session, newest '
        'first, and never uses a bare UUID as the display label', () async {
      final store = _FakeCatalogStore([
        _entry(
          '123e4567-e89b-12d3-a456-426614174000',
          title: '123e4567-e89b-12d3-a456-426614174000',
          snippet: '  Fix the\n roster   projection ',
          cwd: '/work/flutter_agent',
          lastActiveAt: DateTime.utc(2026, 11, 12, 9),
        ),
        _entry(
          'older',
          title: 'Release plan',
          sessionName: 'release',
          lastActiveAt: DateTime.utc(2026, 11, 11),
        ),
        _entry(
          'newer',
          title: 'Live session',
          live: true,
          lastActiveAt: DateTime.utc(2026, 11, 12, 10),
        ),
      ]);
      final roster = _FakeRoster();

      final projection = projectSessionCatalog(
        previous: const [],
        current: await store.loadSessions(),
        fullSnapshot: true,
      );
      roster.publish(projection);

      expect(projection.entries.map((row) => row.id), [
        'newer',
        '123e4567-e89b-12d3-a456-426614174000',
        'older',
      ]);
      expect(projection.entries[1].displayName, 'Fix the roster projection');
      expect(
        projection.entries[1].displayName,
        isNot(projection.entries[1].id),
      );
      expect(projection.entries[1].cwdSlug, 'flutter_agent');
      expect(roster.patches.single, hasLength(3));
    });

    test('subagent and orphaned child rows retract instead of publishing', () {
      final projection = projectSessionCatalog(
        previous: const [],
        current: [
          _entry('parent', title: 'Parent session', live: true),
          _entry('child', title: 'Active child', isSubagent: true),
          _entry('orphan', title: 'Legacy orphan', isSubagent: true),
        ],
        fullSnapshot: true,
      );

      expect(projection.entries.map((row) => row.id), ['parent']);
      expect(projection.upserts.map((row) => row.id), ['parent']);
      expect(projection.retractedIds, ['child', 'orphan']);
    });

    test('incremental projection is minimal and retracts deleted ids', () {
      final previous = [
        _entry('same', title: 'Same'),
        _entry('changed', title: 'Before'),
        _entry('deleted', title: 'Delete me'),
      ];
      final projection = projectSessionCatalog(
        previous: previous,
        current: [
          _entry('same', title: 'Same'),
          _entry('changed', title: 'After'),
          _entry('created', title: 'New'),
        ],
      );

      expect(projection.upserts.map((row) => row.id), ['changed', 'created']);
      expect(projection.retractedIds, ['deleted']);
      expect(projection.pages, isNull);
    });

    test('full snapshots paginate at the server patch cap without dropping '
        'a 1000+ row store', () {
      final projection = projectSessionCatalog(
        previous: const [],
        current: [
          for (var i = 0; i < 1001; i++)
            _entry(
              'session-$i',
              title: 'Session $i',
              lastActiveAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
            ),
        ],
        fullSnapshot: true,
      );

      final pages = projection.pages!;
      expect(pages, hasLength(26));
      expect(pages.first.length, sessionCatalogRosterPageSize);
      expect(pages.last.length, 1);
      expect(pages.expand((page) => page), hasLength(1001));
      expect(projection.upserts, isEmpty);
      expect(pages.expand((page) => page).first.id, 'session-1000');
    });

    test('metadata is bounded and path-only and empty rows have honest '
        'fallback labels', () {
      final projection = projectSessionCatalog(
        previous: const [],
        current: [
          _entry(
            '123e4567-e89b-12d3-a456-426614174000',
            title: 'x' * 500,
            snippet: 'y' * 500,
            cwd: '/work/${'z' * 500}',
          ),
          _entry('plain', title: '   ', snippet: '\n\t', cwd: ''),
        ],
        fullSnapshot: true,
      );
      final rich = projection.entries.firstWhere(
        (row) => row.id.startsWith('123e'),
      );
      expect(rich.title!.runes.length, sessionCatalogTitleMaxRunes);
      expect(rich.snippet!.runes.length, sessionCatalogSnippetMaxRunes);
      expect(rich.cwd.runes.length, sessionCatalogPathMaxRunes);
      expect(rich.displayName, isNot(rich.id));
      expect(
        projection.entries.singleWhere((row) => row.id == 'plain').displayName,
        'Session plain',
      );
      expect(
        sessionCatalogDisplayName(
          _entry('123e4567-e89b-12d3-a456-426614174000', cwd: ''),
        ),
        'Session 123e4567',
      );
    });
  });

  test('relative activity is compact and deterministic', () {
    final now = DateTime.utc(2026, 11, 12, 12);
    expect(formatSessionCatalogRelativeTime(null, now: now), 'unknown');
    expect(formatSessionCatalogRelativeTime(now, now: now), 'now');
    expect(
      formatSessionCatalogRelativeTime(
        now.subtract(const Duration(minutes: 4)),
        now: now,
      ),
      '4m ago',
    );
    expect(
      formatSessionCatalogRelativeTime(
        now.subtract(const Duration(hours: 3)),
        now: now,
      ),
      '3h ago',
    );
    expect(
      formatSessionCatalogRelativeTime(
        now.subtract(const Duration(days: 9)),
        now: now,
      ),
      '9d ago',
    );
  });
}
