@TestOn('vm')
library;

import 'package:flutter_agent_harness/src/messaging/messaging_repository.dart';
import 'package:test/test.dart';

void main() {
  group('MailboxEntry', () {
    const entry = MailboxEntry(id: 'sess1/main', cwd: '/work', slug: 'sess1');

    test('holds id, cwd and slug', () {
      expect(entry.id, 'sess1/main');
      expect(entry.cwd, '/work');
      expect(entry.slug, 'sess1');
    });

    test('toString includes all fields', () {
      expect(
        entry.toString(),
        'MailboxEntry(sess1/main, name: null, cwd: /work, slug: sess1, '
        'presence: null, lastActivity: null, capabilities: [])',
      );
      final named = MailboxEntry(
        id: 'sess1/main',
        name: 'goal_builder',
        cwd: '/work',
        slug: 'sess1',
      );
      expect(named.toString(), contains('name: goal_builder'));
      final stamped = MailboxEntry(
        id: 'sess1/main',
        lastActivity: DateTime.utc(2026, 1, 1),
      );
      expect(stamped.toString(), contains('lastActivity: 2026-01-01'));
    });

    test('supports value equality', () {
      const same = MailboxEntry(id: 'sess1/main', cwd: '/work', slug: 'sess1');
      const differentCwd = MailboxEntry(
        id: 'sess1/main',
        cwd: '/other',
        slug: 'sess1',
      );
      expect(entry, same);
      expect(entry.hashCode, same.hashCode);
      expect(entry, isNot(differentCwd));
    });

    test('presence and capabilities participate in equality', () {
      const busy = MailboxEntry(id: 'a1', presence: AgentPresence.busy);
      expect(busy, const MailboxEntry(id: 'a1', presence: AgentPresence.busy));
      expect(busy, isNot(const MailboxEntry(id: 'a1')));
      const capable = MailboxEntry(
        id: 'a1',
        capabilities: [AgentCapability(name: 'x.y')],
      );
      expect(
        capable,
        const MailboxEntry(
          id: 'a1',
          capabilities: [AgentCapability(name: 'x.y')],
        ),
      );
      expect(capable, isNot(const MailboxEntry(id: 'a1')));
      // Same-capability content built non-const still compares equal.
      expect(
        capable,
        MailboxEntry(
          id: 'a1',
          capabilities: [const AgentCapability(name: 'x.y')],
        ),
      );
    });

    test('AgentCapability JSON round-trips and skips malformed entries', () {
      const capability = AgentCapability(
        name: 'yoclip.render',
        description: 'Render to MP4',
        payload: 'scene=<id>',
      );
      expect(AgentCapability.listFromJson(capability.toJson()), [capability]);
      expect(AgentCapability.listFromJson(null), isEmpty);
      expect(
        AgentCapability.listFromJson([
          'nope',
          {'name': ''},
          {'name': 'ok'},
        ]),
        const [AgentCapability(name: 'ok')],
      );
    });

    test('omitted cwd and slug default to null', () {
      const bare = MailboxEntry(id: 'a1');
      expect(bare.cwd, isNull);
      expect(bare.slug, isNull);
    });
  });

  group('cross-root misroute diagnostics (#516)', () {
    // The issue #516 AC1 fixture: the same id owns a stale mailbox under
    // the OLD project (demo_widget) and a live one under the CURRENT
    // project (flutter_agent). Pre-fix a send silently landed in the
    // stale root; the diagnostic must name both roots instead.
    MailboxEntry box(
      String cwd, {
      DateTime? lastActivity,
      AgentPresence? presence,
    }) => MailboxEntry(
      id: '01a060f2/main',
      cwd: cwd,
      lastActivity: lastActivity,
      presence: presence,
    );

    final fresh = DateTime.now().toUtc().subtract(const Duration(minutes: 1));
    final dead = DateTime.now().toUtc().subtract(const Duration(days: 3));

    test('isConfirmedLive trusts evidence, never an undated entry', () {
      expect(box('/w', lastActivity: fresh).isConfirmedLive, isTrue);
      expect(box('/w', presence: AgentPresence.busy).isConfirmedLive, isTrue);
      expect(box('/w', presence: AgentPresence.live).isConfirmedLive, isTrue);
      expect(box('/w', lastActivity: dead).isConfirmedLive, isFalse);
      expect(
        box(
          '/w',
          presence: AgentPresence.offline,
          lastActivity: fresh,
        ).isConfirmedLive,
        isFalse,
      );
      // Undated (file entry without a heartbeat): visibility says live,
      // routing evidence says unknown.
      expect(box('/w').isConfirmedLive, isFalse);
      expect(MailboxEntry.isLive(null), isTrue);
    });

    test('the AC1 fixture names the live root and the stale corpse', () {
      final note = mailboxMisrouteNote([
        box('/git/demo_widget', lastActivity: dead),
        box('/git/flutter_agent', lastActivity: fresh),
      ], '01a060f2/main');
      expect(note, contains('Delivered to the live mailbox under'));
      expect(note, contains('/git/flutter_agent'));
      expect(note, contains('stale mailbox under /git/demo_widget'));
      expect(note, contains('ignored'));
    });

    test('several stale copies warn: no live registration anywhere', () {
      final note = mailboxMisrouteNote([
        box('/git/demo_widget', lastActivity: dead),
        box('/git/legacy', lastActivity: dead),
      ], '01a060f2/main');
      expect(note, contains('warning'));
      expect(note, contains('/git/demo_widget, /git/legacy'));
      expect(note, contains('not live anywhere'));
    });

    test('a single mailbox — even asleep — stays silent', () {
      expect(
        mailboxMisrouteNote([
          box('/git/flutter_agent', lastActivity: dead),
        ], '01a060f2/main'),
        isEmpty,
      );
      expect(mailboxMisrouteNote([], '01a060f2/main'), isEmpty);
      // A different id under two roots is not our target's problem.
      expect(
        mailboxMisrouteNote([
          MailboxEntry(id: 'other', cwd: '/a'),
          MailboxEntry(id: 'other', cwd: '/b'),
        ], '01a060f2/main'),
        isEmpty,
      );
    });
  });
}
