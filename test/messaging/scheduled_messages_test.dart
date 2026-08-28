@TestOn('vm')
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/messaging/schedule_message_tool.dart';
import 'package:flutter_agent_harness/src/messaging/scheduled_messages.dart';
import 'package:test/test.dart';

void main() {
  test('parseDelay handles units and combinations', () {
    expect(parseDelay('90s'), const Duration(seconds: 90));
    expect(parseDelay('25m'), const Duration(minutes: 25));
    expect(parseDelay('1h30m'), const Duration(minutes: 90));
    expect(parseDelay('1d'), const Duration(days: 1));
    expect(parseDelay('500ms'), isNotNull);
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
      final first = ScheduledMessageQueue(env: env, repo: () => repo, root: () => root);
      await first.schedule(
        text: 'ping later',
        delay: const Duration(milliseconds: 20),
        to: 'main',
      );
      // A fresh queue (host restart) re-arms and delivers overdue records.
      final second = ScheduledMessageQueue(env: env, repo: () => repo, root: () => root);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await second.start();
      expect((await repo.peek('main')).single.text, contains('ping later'));
    },
  );

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
