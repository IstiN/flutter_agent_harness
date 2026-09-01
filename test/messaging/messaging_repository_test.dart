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
        'MailboxEntry(sess1/main, cwd: /work, slug: sess1, '
        'lastActivity: null)',
      );
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

    test('omitted cwd and slug default to null', () {
      const bare = MailboxEntry(id: 'a1');
      expect(bare.cwd, isNull);
      expect(bare.slug, isNull);
    });
  });
}
