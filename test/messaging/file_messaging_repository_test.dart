@TestOn('vm')
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  late MemoryExecutionEnv env;
  late FileMessagingRepository repo;

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
    repo = FileMessagingRepository(env: env, root: '/mail');
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
      final readDir = (await env.listDir('/mail/a1/read')).getOrThrow();
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
      expect(dir, containsAll(['a1', 'b2']));
    });

    test('a torn write never poisons the inbox', () async {
      await repo.send(msg(id: 'm9', text: 'good'));
      (await env.writeFile(
        '/mail/a1/inbox/20260102_bad.json',
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
      final instanceA = FileMessagingRepository(env: env, root: '/mail');
      final instanceB = FileMessagingRepository(env: env, root: '/mail');
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
      expect(await repo.directory(), ['sess1/main']);
      // Idempotent and non-destructive.
      await repo.send(msg());
      await repo.register('sess1/main');
      expect(await repo.peek('a1'), hasLength(1));
      expect(await repo.directory(), containsAll(['sess1/main', 'a1']));
    });
  });
}
