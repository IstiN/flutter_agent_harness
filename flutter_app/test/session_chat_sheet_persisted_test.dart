// Drawer persisted-tail filtering (SessionChatSheet._reloadPersisted):
// the pure [drawerPersistedSessions] rules, pinned without pumping the
// sheet. The relay cases guard the "drawer collapses to the live row
// after session_open" regression: the manager slot id lags the SW's
// re-point, and excluding by slot ids hides the freshly archived
// session — the SW's `archived` flag is the authority instead.
import 'package:fa/apps/session_chat_sheet.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

SessionMetadata _row(String id, {bool archived = false}) => SessionMetadata(
  id: id,
  createdAt: DateTime.utc(2026, 9, 8),
  cwd: '/',
  path: '/session-$id.jsonl',
  metadata: archived ? const {'archived': true} : null,
);

void main() {
  group('drawerPersistedSessions', () {
    test('relay: a manager-lagging slot id must not hide a real archive', () {
      // SW live = B (archives: A); the manager slot still points at A
      // because session_open re-pointed the SW, not the slot. The drawer
      // must still list A — filtering by slot ids drops it and the
      // drawer collapses to just the live row.
      final persisted = drawerPersistedSessions(
        all: [_row('B'), _row('A', archived: true)],
        liveIds: {'A'},
        relayLiveId: 'B',
      );
      expect(persisted.map((m) => m.id), ['A']);
    });

    test('relay: the SW live row is never persisted, even when the '
        'service live id lags the SW', () {
      // relayLiveId still says A while the SW already lists B as live:
      // B (not archived) must not pop in as a persisted twin.
      final persisted = drawerPersistedSessions(
        all: [_row('B'), _row('A', archived: true)],
        liveIds: {'A'},
        relayLiveId: 'A',
      );
      expect(persisted, isEmpty);
    });

    test('relay: a live row is excluded even without the archived flag', () {
      final persisted = drawerPersistedSessions(
        all: [_row('B'), _row('A', archived: true), _row('C')],
        liveIds: const {},
        relayLiveId: 'B',
      );
      expect(persisted.map((m) => m.id), ['A']);
    });

    test('local (non-relay): disk sessions minus the live ones', () {
      final persisted = drawerPersistedSessions(
        all: [_row('X'), _row('Y')],
        liveIds: {'X'},
        relayLiveId: null,
      );
      expect(persisted.map((m) => m.id), ['Y']);
    });
  });
}
