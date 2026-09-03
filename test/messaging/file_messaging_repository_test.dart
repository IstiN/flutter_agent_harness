@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  late MemoryExecutionEnv env;
  late FileMessagingRepository repo;

  const messagesRoot = '/sessions/--work--/messages';

  AgentMessage msg({
    String id = 'm1',
    String from = 'main',
    String to = 'a1',
    String text = 'hello',
    String sentAt = '2026-01-01T00:00:00Z',
    int hops = 2,
  }) => AgentMessage(
    id: id,
    fromId: from,
    toId: to,
    text: text,
    sentAt: sentAt,
    hops: hops,
  );

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    repo = FileMessagingRepository(
      env: env,
      root: messagesRoot,
      homeDir: '/home/user',
      decodeSessionCwd: decodeSessionCwd,
    );
  });

  group('FileMessagingRepository', () {
    test(
      'send + peek delivers to the recipient inbox without consuming',
      () async {
        await repo.send(msg());
        final first = await repo.peek('a1');
        expect(first, hasLength(1));
        expect(first.single.fromId, 'main');
        expect(first.single.text, 'hello');
        expect(first.single.hops, 2);
        // Peek again — still there.
        expect(await repo.peek('a1'), hasLength(1));
        // Another agent sees nothing.
        expect(await repo.peek('b2'), isEmpty);
      },
    );

    test('drain consumes: messages land in read/ and never reappear', () async {
      await repo.send(msg(id: 'm1', text: 'one'));
      await repo.send(msg(id: 'm2', text: 'two'));
      final drained = await repo.drain('a1');
      expect(drained.map((m) => m.text), ['one', 'two']);
      expect(await repo.drain('a1'), isEmpty);
      // The read/ archive kept both.
      final readDir = (await env.listDir('$messagesRoot/a1/read')).getOrThrow();
      expect(readDir, hasLength(2));
    });

    test('inbox order is arrival order (filename sort)', () async {
      // Ids deliberately out of alphabetical order vs insertion order.
      await repo.send(msg(id: '20260101_0003_z', text: 'third'));
      await repo.send(msg(id: '20260101_0001_x', text: 'first'));
      await repo.send(msg(id: '20260101_0002_y', text: 'second'));
      final drained = await repo.drain('a1');
      expect(drained.map((m) => m.text), ['first', 'second', 'third']);
    });

    test('agent ids are sanitized for the filesystem', () async {
      expect(
        FileMessagingRepository.sanitizeAgentId('explore:a1'),
        'explore_a1',
      );
      await repo.send(msg(to: 'explore:a1'));
      expect(await repo.peek('explore:a1'), hasLength(1));
      // Same agent resolves to the same inbox regardless of addressing form.
      expect(await repo.peek('explore_a1'), hasLength(1));
    });

    test('directory lists agents that have mail', () async {
      expect(await repo.directory(), isEmpty);
      await repo.send(msg(to: 'a1'));
      await repo.send(msg(to: 'b2'));
      await repo.drain('a1');
      final dir = await repo.directory();
      expect(dir.map((e) => e.id), containsAll(['a1', 'b2']));
      expect(dir.every((e) => e.slug == '--work--'), isTrue);
      expect(dir.every((e) => e.cwd == '/work'), isTrue);
    });

    test(
      'directory falls back to the directory name when .id is missing',
      () async {
        await env.createDir('$messagesRoot/no-id/inbox', recursive: true);
        final dir = await repo.directory();
        expect(dir.map((e) => e.id), contains('no-id'));
        expect(dir.firstWhere((e) => e.id == 'no-id').slug, '--work--');
      },
    );

    test('a torn write never poisons the inbox', () async {
      await repo.send(msg(id: 'm9', text: 'good'));
      (await env.writeFile(
        '$messagesRoot/a1/inbox/20260102_bad.json',
        '{broken',
      )).getOrThrow();
      final drained = await repo.drain('a1');
      // The broken file sorts after m9's name? Force order: m9 id sorts
      // before 20260102 only when named so — just assert the good one came
      // through and nothing threw.
      expect(drained.any((m) => m.text == 'good'), isTrue);
    });

    test('two repository instances share mail through one root', () async {
      // Two "Fa instances": separate repo objects, same env + root.
      final instanceA = FileMessagingRepository(
        env: env,
        root: messagesRoot,
        decodeSessionCwd: decodeSessionCwd,
      );
      final instanceB = FileMessagingRepository(
        env: env,
        root: messagesRoot,
        decodeSessionCwd: decodeSessionCwd,
      );
      await instanceA.send(msg(id: 'm1', from: 'a1', to: 'main', text: 'ping'));
      final inbox = await instanceB.drain('main');
      expect(inbox.single.text, 'ping');
      await instanceB.send(msg(id: 'm2', from: 'main', to: 'a1', text: 'pong'));
      expect((await instanceA.drain('a1')).single.text, 'pong');
    });

    test('newMessageId is unique and time-ordered', () {
      final ids = [for (var i = 0; i < 100; i++) newMessageId()];
      expect(ids.toSet(), hasLength(100));
      final sorted = [...ids]..sort();
      expect(ids, sorted);
    });

    test('register announces a zero-mail mailbox in the directory', () async {
      expect(await repo.directory(), isEmpty);
      await repo.register('sess1/main');
      final dir = await repo.directory();
      expect(dir.map((e) => e.id), ['sess1/main']);
      expect(dir.single.slug, '--work--');
      expect(dir.single.cwd, '/work');
      // Idempotent and non-destructive.
      await repo.send(msg());
      await repo.register('sess1/main');
      expect(await repo.peek('a1'), hasLength(1));
      final later = await repo.directory();
      expect(later.map((e) => e.id), containsAll(['sess1/main', 'a1']));
    });

    test('broad-scan finds mailboxes in sibling cwd-slug dirs', () async {
      final foreignRoot = '/sessions/--other--/messages';
      final foreignRepo = FileMessagingRepository(
        env: env,
        root: foreignRoot,
        decodeSessionCwd: decodeSessionCwd,
      );
      await repo.send(msg(id: 'm1', from: 'other', to: 'main', text: 'own'));
      await foreignRepo.send(
        msg(id: 'm2', from: 'other', to: 'foreign-agent', text: 'foreign'),
      );

      final dir = await repo.directory();
      final byId = {for (final e in dir) e.id: e};
      expect(byId.keys, containsAll(['main', 'foreign-agent']));
      expect(byId['main']?.cwd, '/work');
      expect(byId['main']?.slug, '--work--');
      expect(byId['foreign-agent']?.cwd, '/other');
      expect(byId['foreign-agent']?.slug, '--other--');
    });

    test(
      'register writes the messages-registry.json with correct shape',
      () async {
        await repo.register('sess1/main');
        final registryText = (await env.readTextFile(
          '/home/user/.fah/messages-registry.json',
        )).getOrThrow();
        final registry = jsonDecode(registryText) as Map<String, dynamic>;
        expect(registry['sess1/main'], {'slug': '--work--', 'cwd': '/work'});
      },
    );

    test('registry upserts multiple agent ids', () async {
      await repo.register('main');
      await repo.register('explore:a1');
      final registryText = (await env.readTextFile(
        '/home/user/.fah/messages-registry.json',
      )).getOrThrow();
      final registry = jsonDecode(registryText) as Map<String, dynamic>;
      expect(registry['main'], {'slug': '--work--', 'cwd': '/work'});
      expect(registry['explore:a1'], {'slug': '--work--', 'cwd': '/work'});
    });

    test('directory tolerates a missing session root', () async {
      final isolated = FileMessagingRepository(
        env: MemoryExecutionEnv(),
        root: '/nowhere/--work--/messages',
        decodeSessionCwd: decodeSessionCwd,
      );
      expect(await isolated.directory(), isEmpty);
    });

    test(
      'touch writes a heartbeat that directory reports as lastActivity',
      () async {
        await repo.send(msg(to: 'a1'));
        // Backdate the mail: without a heartbeat the mailbox would look stale.
        final twoHoursAgo = DateTime.now().toUtc().subtract(
          const Duration(hours: 2),
        );
        env.setMtime(
          '$messagesRoot/a1/inbox/m1.json',
          twoHoursAgo.millisecondsSinceEpoch,
        );
        await repo.touch('a1');
        final entry = (await repo.directory()).single;
        expect(entry.lastActivity, isNotNull);
        // The heartbeat is the activity source — fresher than the mail and
        // inside the live window.
        expect(entry.lastActivity!.isAfter(twoHoursAgo), isTrue);
        expect(MailboxEntry.isLive(entry.lastActivity), isTrue);
      },
    );

    test('touch announces an unknown mailbox in the directory', () async {
      expect(await repo.directory(), isEmpty);
      await repo.touch('fresh/main');
      final dir = await repo.directory();
      expect(dir.map((e) => e.id), ['fresh/main']);
      expect(dir.single.lastActivity, isNotNull);
    });

    test(
      'directory lastActivity is the newest file across inbox and read',
      () async {
        await repo.send(msg(id: 'm1', to: 'a1'));
        await repo.send(msg(id: 'm2', to: 'a1'));
        await repo.drain('a1'); // Both land in read/, inbox is empty.
        final threeDaysAgo = DateTime.now().toUtc().subtract(
          const Duration(days: 3),
        );
        env.setMtime(
          '$messagesRoot/a1/read/m1.json',
          threeDaysAgo.millisecondsSinceEpoch,
        );
        env.setMtime(
          '$messagesRoot/a1/read/m2.json',
          threeDaysAgo.millisecondsSinceEpoch,
        );
        final entry = (await repo.directory()).single;
        expect(entry.lastActivity, isNotNull);
        // The .id marker is identity, not activity — excluded from the scan.
        final age = DateTime.now().toUtc().difference(entry.lastActivity!);
        expect(age.inDays, greaterThanOrEqualTo(2));
        expect(MailboxEntry.isLive(entry.lastActivity), isFalse);
      },
    );

    test(
      'directory skips reserved directories (_scheduled, dot-dirs)',
      () async {
        await repo.send(msg(to: 'a1'));
        await env.createDir('$messagesRoot/_scheduled', recursive: true);
        env.writeFile('$messagesRoot/_scheduled/20260101_x.json', '{}');
        await env.createDir('$messagesRoot/.hidden/inbox', recursive: true);
        final ids = (await repo.directory()).map((e) => e.id).toList();
        expect(ids, ['a1']);
      },
    );

    test(
      'MailboxEntry.isLive: null is live, staleness respects the window',
      () {
        final now = DateTime.utc(2026, 1, 1, 12);
        expect(MailboxEntry.isLive(null, now: now), isTrue);
        expect(
          MailboxEntry.isLive(
            now.subtract(const Duration(minutes: 14)),
            now: now,
          ),
          isTrue,
        );
        expect(
          MailboxEntry.isLive(
            now.subtract(const Duration(minutes: 16)),
            now: now,
          ),
          isFalse,
        );
        expect(
          MailboxEntry.isLive(
            now.subtract(const Duration(hours: 2)),
            now: now,
            window: const Duration(hours: 3),
          ),
          isTrue,
        );
      },
    );
  });

  // Cross-project delivery: a mailbox registered under a DIFFERENT cwd slug
  // must receive mail in ITS messages root — the recipient drains only its
  // own root, so sender-rooted delivery silently vanishes (the peer fa in
  // another project never sees the message). Resolution order: the
  // messages-registry.json slug lookup, then a broad scan of sibling slugs
  // for a mailbox whose .id marker matches; unknown ids stay local.
  group('cross-project send routing', () {
    test('registry-known foreign slug receives the message', () async {
      await env.writeFile(
        '/home/user/.fah/messages-registry.json',
        jsonEncode({
          '01a044d9/main': {'slug': '--other-project--', 'cwd': '/other'},
        }),
      );
      await env.createDir(
        '/sessions/--other-project--/messages/01a044d9_main/inbox',
      );
      await repo.send(msg(to: '01a044d9/main', text: 'cross'));
      final there =
          (await env.listDir(
            '/sessions/--other-project--/messages/01a044d9_main/inbox',
          )).valueOrNull ??
          const [];
      expect(there.where((e) => e.kind == FileKind.file), hasLength(1));
      // NOT in our own root — sender-rooted delivery is the bug.
      expect(await repo.peek('01a044d9/main'), isEmpty);
    });

    test(
      'broad scan finds a foreign mailbox without a registry entry',
      () async {
        await env.createDir(
          '/sessions/--other-project--/messages/01a044d9_main/inbox',
        );
        await env.writeFile(
          '/sessions/--other-project--/messages/01a044d9_main/.id',
          '01a044d9/main',
        );
        await repo.send(msg(to: '01a044d9/main', text: 'scan'));
        final there =
            (await env.listDir(
              '/sessions/--other-project--/messages/01a044d9_main/inbox',
            )).valueOrNull ??
            const [];
        expect(there.where((e) => e.kind == FileKind.file), hasLength(1));
        expect(await repo.peek('01a044d9/main'), isEmpty);
      },
    );

    test('unknown ids stay in the local root', () async {
      await repo.send(msg(to: 'local-child', text: 'local'));
      expect(await repo.peek('local-child'), hasLength(1));
    });
  });
}
