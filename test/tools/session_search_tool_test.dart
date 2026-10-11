// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The `session_search` tool surface (issue #1380 A2): argument
/// validation errors, the graceful no-host contract, and the model-facing
/// formatting of search hits and the mode:map readout.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

SessionSearchOutcome _outcome({
  List<SessionSearchHit> hits = const [],
  bool truncated = false,
  int? nextContinuation,
  String truncationReason = '',
  String unavailableReason = '',
  SessionArchiveMap? map,
}) {
  return SessionSearchOutcome(
    hits: hits,
    recordsExamined: 12,
    recordsTotal: 34,
    truncated: truncated,
    nextContinuation: nextContinuation,
    truncationReason: truncationReason,
    unavailableReason: unavailableReason,
    map: map,
  );
}

void main() {
  group('the graceful-null contract', () {
    test('a host without session-file access says so, never throws', () async {
      final tool = sessionSearchTool();
      final result = await tool.execute(const {}, null, null);
      expect(result.content.single, isA<TextContent>());
      expect(
        (result.content.single as TextContent).text,
        'This host has no session file to search.',
      );
    });
  });

  group('argument validation surfaces as one-line errors', () {
    for (final (label, args, needle) in const [
      ('missing query', <String, Object?>{}, 'query is required'),
      (
        'invalid regex',
        <String, Object?>{'query': '(oops', 'regex': true},
        'invalid regex',
      ),
      (
        'bad timestamp',
        <String, Object?>{'query': 'x', 'after': 'yesterday'},
        'after must be an ISO-8601 timestamp',
      ),
    ]) {
      test(label, () async {
        final seen = <SessionSearchQuery>[];
        final tool = sessionSearchTool(
          search: (query) async {
            seen.add(query);
            return _outcome();
          },
        );
        final result = await tool.execute(
          Map<String, dynamic>.from(args),
          null,
          null,
        );
        final text = (result.content.single as TextContent).text;
        expect(text, startsWith('error: '));
        expect(text, contains(needle));
        expect(seen, isEmpty);
      });
    }
  });

  group('search-mode formatting', () {
    test('one pointer line per hit, never full content', () async {
      final tool = sessionSearchTool(
        search: (query) async {
          expect(query.query, 'always run tests');
          return _outcome(
            hits: [
              SessionSearchHit(
                id: 'rec_1',
                kind: 'message',
                timestamp: DateTime.utc(2026, 1, 2),
                preview: 'always run tests before pushing',
              ),
            ],
          );
        },
      );
      final result = await tool.execute(
        const {'query': 'always run tests'},
        null,
        null,
      );
      final text = (result.content.single as TextContent).text;
      expect(text, contains('1 hit(s)'));
      expect(text, contains('rec_1 [message] 2026-01-02T00:00:00.000'));
      expect(text, contains('always run tests before pushing'));
      expect(text, contains('examined 12 of 34 records'));
    });

    test('a capped scan carries the continuation hint', () async {
      final tool = sessionSearchTool(
        search: (query) async => _outcome(
          hits: [
            SessionSearchHit(
              id: 'rec_1',
              kind: 'message',
              timestamp: DateTime.utc(2026, 1, 2),
              preview: 'partial',
            ),
          ],
          truncated: true,
          nextContinuation: 21,
          truncationReason: 'result cap',
        ),
      );
      final result = await tool.execute(const {'query': 'x'}, null, null);
      final text = (result.content.single as TextContent).text;
      expect(text, contains('"continuation": 21'));
      expect(text, contains('result cap'));
    });

    test(
      'a capped ZERO-hit page still carries the stop reason and hint',
      () async {
        // The regression the rework pass caught: the empty-hits early
        // return dropped the footer, so a scan that stopped early with no
        // hits on this page read as a flat "no records match" — the model
        // would believe the archive has no matches when the scan never
        // finished (e.g. the budget expired before the first match).
        final tool = sessionSearchTool(
          search: (query) async => _outcome(
            truncated: true,
            nextContinuation: 21,
            truncationReason: 'time budget',
          ),
        );
        final result = await tool.execute(const {'query': 'x'}, null, null);
        final text = (result.content.single as TextContent).text;
        expect(text, startsWith('no records match'));
        expect(text, contains('time budget'));
        expect(text, contains('"continuation": 21'));
        // Nothing to expand when there are no hits — no expand advice.
        expect(text, isNot(contains('compact_expand')));
      },
    );

    test(
      'an unavailable archive is said verbatim, never as no-match',
      () async {
        // The CLI's no-session-file degradation lands here: the honest
        // rendering is the dedicated reason, not "no records match
        // (examined 0 of 0 records)" — which claims the archive was
        // scanned and is empty.
        final tool = sessionSearchTool(
          search: (query) async => _outcome(
            unavailableReason:
                'no session file backs this host — nothing was searched',
          ),
        );
        final result = await tool.execute(const {'query': 'x'}, null, null);
        final text = (result.content.single as TextContent).text;
        expect(text, startsWith('session_search unavailable:'));
        expect(text, contains('no session file backs this host'));
        expect(text, isNot(contains('no records match')));
      },
    );

    test('zero hits reports the honest no-match line', () async {
      final tool = sessionSearchTool(search: (query) async => _outcome());
      final result = await tool.execute(const {'query': 'x'}, null, null);
      final text = (result.content.single as TextContent).text;
      expect(text, startsWith('no records match'));
    });
  });

  group('map-mode formatting', () {
    test('counts, hidden totals and the checkpoint tree, no content', () async {
      final tool = sessionSearchTool(
        search: (query) async {
          expect(query.mode, SessionSearchMode.map);
          return _outcome(
            map: SessionArchiveMap(
              recordCount: 34,
              kindCounts: const {'message': 30, 'compact_checkpoint': 2},
              hiddenRangeCount: 2,
              hiddenRecordIdCount: 18,
              checkpoints: [
                const CheckpointMapEntry(
                  id: 'ck_1',
                  firstRecordId: 'rec_a',
                  lastRecordId: 'rec_z',
                  coversCount: 24,
                  depth: 1,
                ),
                const CheckpointMapEntry(
                  id: 'ck_2',
                  firstRecordId: 'rec_b',
                  lastRecordId: 'rec_y',
                  coversCount: 22,
                  depth: 2,
                ),
              ],
              maxCheckpointDepth: 2,
              branchRecordCount: 32,
              leafId: 'rec_z',
            ),
          );
        },
      );
      final result = await tool.execute(const {'mode': 'map'}, null, null);
      final text = (result.content.single as TextContent).text;
      expect(text, contains('session map: 34 records'));
      expect(text, contains('message 30'));
      expect(text, contains('covering 18 record id(s)'));
      expect(text, contains('max nesting depth 2'));
      expect(text, contains('ck_1 covers 24'));
      expect(text, contains('leaf rec_z'));
    });

    test('an empty archive maps honestly', () async {
      final tool = sessionSearchTool(
        search: (query) async => _outcome(
          map: const SessionArchiveMap(
            recordCount: 0,
            kindCounts: {},
            hiddenRangeCount: 0,
            hiddenRecordIdCount: 0,
            checkpoints: [],
            maxCheckpointDepth: 0,
            branchRecordCount: 0,
            leafId: null,
          ),
        ),
      );
      final result = await tool.execute(const {'mode': 'map'}, null, null);
      final text = (result.content.single as TextContent).text;
      expect(text, contains('session map: 0 records'));
      expect(text, contains('counts: (none)'));
      expect(text, contains('checkpoints: none'));
    });
  });
}
