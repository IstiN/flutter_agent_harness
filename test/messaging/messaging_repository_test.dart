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
}
