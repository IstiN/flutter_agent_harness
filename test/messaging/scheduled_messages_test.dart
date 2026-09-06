@TestOn('vm')
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  test('parseDelay handles units and combinations', () {
    expect(parseDelay('90s'), const Duration(seconds: 90));
    expect(parseDelay('25m'), const Duration(minutes: 25));
    expect(parseDelay('1h30m'), const Duration(minutes: 90));
    expect(parseDelay('1d'), const Duration(days: 1));
    expect(parseDelay('500ms'), const Duration(milliseconds: 500));
    expect(parseDelay('0.5m'), const Duration(seconds: 30));
    expect(parseDelay('1.5h'), const Duration(minutes: 90));
    expect(parseDelay('abc'), isNull);
    expect(parseDelay('0m'), isNull);
  });

  test('due messages land in the inbox and rearm works', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    final repo = FileMessagingRepository(
      env: env,
      root: '/sessions/--work--/messages',
      homeDir: '/home/user',
      decodeSessionCwd: decodeSessionCwd,
    );
    final queue = ScheduledMessageQueue(
      env: env,
      repo: () => repo,
      root: () => '/sessions/--work--/messages',
    );
    await repo.register('main');
    await queue.schedule(
      text: 'check the build',
      delay: const Duration(milliseconds: 30),
      to: 'main',
      from: 'main',
    );
    // Not yet due.
    expect(await repo.peek('main'), isEmpty);
    // The queue's own timer delivers when due; a manual deliverDue is an
    // idempotent catch-up for restarts.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    final mail = await repo.peek('main');
    expect(mail, hasLength(1));
    expect(mail.single.text, contains('[scheduled] check the build'));
    // Delivered records are consumed, not re-delivered.
    expect(await queue.deliverDue(), 0);
  });

  test(
    'overdue records survive a restart (new queue instance delivers)',
    () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final root = '/sessions/--work--/messages';
      final repo = FileMessagingRepository(
        env: env,
        root: root,
        homeDir: '/home/user',
        decodeSessionCwd: decodeSessionCwd,
      );
      final first = ScheduledMessageQueue(
        env: env,
        repo: () => repo,
        root: () => root,
      );
      await first.schedule(
        text: 'ping later',
        delay: const Duration(milliseconds: 20),
        to: 'main',
      );
      // A fresh queue (host restart) re-arms and delivers overdue records.
      final second = ScheduledMessageQueue(
        env: env,
        repo: () => repo,
        root: () => root,
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await second.start();
      expect((await repo.peek('main')).single.text, contains('ping later'));
    },
  );

  test(
    'self-scheduled mail resolves to the host mailbox, not a "self" dir',
    () async {
      // Regression: without a `to`, records stored the literal string 'self',
      // and delivery wrote into a phantom <root>/self mailbox nobody drains —
      // self-reminders were lost forever (38 on one production machine).
      final env = MemoryExecutionEnv(cwd: '/work');
      final root = '/sessions/--work--/messages';
      final repo = FileMessagingRepository(
        env: env,
        root: root,
        homeDir: '/home/user',
        decodeSessionCwd: decodeSessionCwd,
      );
      final queue = ScheduledMessageQueue(
        env: env,
        repo: () => repo,
        root: () => root,
        selfMailbox: () => 'sid-1/main',
      );
      await queue.schedule(
        text: 'ping me',
        delay: const Duration(milliseconds: 20),
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final mail = await repo.peek('sid-1/main');
      expect(mail.single.text, contains('[scheduled] ping me'));
      expect(mail.single.fromId, 'sid-1/main');
      expect(mail.single.toId, 'sid-1/main');
      // Nothing must be left behind in the phantom self mailbox.
      expect((await repo.peek('self')).isEmpty, isTrue);
    },
  );

  test('cross-mailbox schedule attributes the message to the sender', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    final root = '/sessions/--work--/messages';
    final repo = FileMessagingRepository(
      env: env,
      root: root,
      homeDir: '/home/user',
      decodeSessionCwd: decodeSessionCwd,
    );
    final queue = ScheduledMessageQueue(
      env: env,
      repo: () => repo,
      root: () => root,
      selfMailbox: () => 'sid-1/main',
    );
    await queue.schedule(
      text: 'hey jsr',
      delay: const Duration(milliseconds: 20),
      to: 'jsr/main',
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await queue.deliverDue();
    final mail = await repo.peek('jsr/main');
    expect(mail.single.fromId, 'sid-1/main');
  });

  test('legacy "self" inbox mail is migrated into the real mailbox', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    final root = '/sessions/--work--/messages';
    final repo = FileMessagingRepository(
      env: env,
      root: root,
      homeDir: '/home/user',
      decodeSessionCwd: decodeSessionCwd,
    );
    await repo.register('sid-1/main');
    // A message delivered by a build predating the self-mailbox fix.
    await repo.send(
      AgentMessage(
        id: 'legacy-1',
        fromId: 'self',
        toId: 'self',
        text: '[scheduled] old reminder',
        sentAt: DateTime.now().toUtc().toIso8601String(),
        hops: 0,
      ),
    );
    final queue = ScheduledMessageQueue(
      env: env,
      repo: () => repo,
      root: () => root,
      selfMailbox: () => 'sid-1/main',
    );
    await queue.start();
    final mail = await repo.peek('sid-1/main');
    expect(mail.single.text, '[scheduled] old reminder');
    expect(mail.single.fromId, 'sid-1/main');
    expect((await repo.peek('self')).isEmpty, isTrue);
  });

  test('concurrent delivery runs send each record once', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    final root = '/sessions/--work--/messages';
    final repo = FileMessagingRepository(
      env: env,
      root: root,
      homeDir: '/home/user',
      decodeSessionCwd: decodeSessionCwd,
    );
    final queue = ScheduledMessageQueue(
      env: env,
      repo: () => repo,
      root: () => root,
      selfMailbox: () => 'sid-1/main',
    );
    await queue.schedule(text: 'once', delay: const Duration(milliseconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await Future.wait([queue.deliverDue(), queue.deliverDue()]);
    expect(await repo.peek('sid-1/main'), hasLength(1));
  });

  test('schedule/fire notices are surfaced to the host', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    final root = '/sessions/--work--/messages';
    final repo = FileMessagingRepository(
      env: env,
      root: root,
      homeDir: '/home/user',
      decodeSessionCwd: decodeSessionCwd,
    );
    final scheduledNotices = <String>[];
    final firedNotices = <String>[];
    final queue = ScheduledMessageQueue(
      env: env,
      repo: () => repo,
      root: () => root,
      selfMailbox: () => 'sid-1/main',
      onScheduled: scheduledNotices.add,
      onFired: firedNotices.add,
    );
    await queue.schedule(
      text: 'check CI',
      delay: const Duration(milliseconds: 10),
    );
    expect(scheduledNotices.single, contains('check CI'));
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(firedNotices.single, contains('check CI'));
  });

  test('schedule_message tool validates and schedules', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    final root = '/sessions/--work--/messages';
    final repo = FileMessagingRepository(
      env: env,
      root: root,
      homeDir: '/home/user',
      decodeSessionCwd: decodeSessionCwd,
    );
    final queue = ScheduledMessageQueue(
      env: env,
      repo: () => repo,
      root: () => root,
    );
    final tool = scheduleMessageTool(queue);

    String content(dynamic result) =>
        result.content.whereType<TextContent>().map((b) => b.text).join();

    final bad = await tool.execute({'text': 'x', 'delay': 'soon'}, null, null);
    expect(content(bad), contains('error: delay'));

    final ok = await tool.execute(
      {'text': 'remind me', 'delay': '10m', 'to': 'main'},
      null,
      null,
    );
    expect(content(ok), contains('scheduled'));
    final pending = (await env.listDir('$root/_scheduled')).valueOrNull ?? [];
    expect(pending.where((e) => e.kind == FileKind.file), hasLength(1));
  });
}
