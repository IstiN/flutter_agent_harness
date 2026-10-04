import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// Async-condition waitForIt: polls a future predicate until true.
Future<void> waitForTrue(Future<bool> Function() condition) async {
  for (var i = 0; i < 5000; i++) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: async condition');
}

/// The idle inbox-wake lanes (gh-1180): scheduled self-mail must be exempt
/// from the agent-chatter wake cap, foreign chatter must stay capped, and
/// every refused wake must leave a visible receipt.
///
/// `run()` creates the session at boot WITHOUT starting a turn — the
/// first stream call is the first wake — so the post-boot baseline is
/// zero calls.
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  AgentCli buildCli(FakeStreamFunction fake) => AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: '[REDACTED:Sensitive Value]',
      env: env,
      sessionRoot: '/sessions',
      providerKind: 'openai-completions',
    ),
    io: io,
    streamFunction: fake.call,
  );

  /// Waits for the session to exist; returns (sessionId, 0 calls).
  Future<(String, int)> boot(FakeStreamFunction fake, AgentCli cli) async {
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    await waitForTrue(() async => (await repo.list(cwd: '/work')).isNotEmpty);
    return ((await repo.list(cwd: '/work')).first.id, fake.calls);
  }

  /// Sends one message shaped exactly like the scheduler's delivery of a
  /// self-addressed record: `[scheduled] ` prefix, from == to == own
  /// mailbox (what `_deliverDueInner` produces).
  Future<String> sendScheduledSelfMail(String id, String text) async {
    final mailbox = '$id/main';
    final message = AgentMessage(
      id: newMessageId(),
      fromId: mailbox,
      toId: mailbox,
      text: '[scheduled] $text',
      sentAt: DateTime.now().toUtc().toIso8601String(),
    );
    await FileMessagingRepository(
      env: env,
      root: '/sessions/--work--/messages',
    ).send(message);
    return message.id;
  }

  Future<void> sendForeignMail(String id, String text) async {
    await FileMessagingRepository(
      env: env,
      root: '/sessions/--work--/messages',
    ).send(
      AgentMessage(
        id: newMessageId(),
        fromId: 'peer-session/main',
        toId: '$id/main',
        text: text,
        sentAt: DateTime.now().toUtc().toIso8601String(),
      ),
    );
  }

  Future<List<Map<String, dynamic>>> receipts() async {
    final text = (await env.readTextFile(
      '/sessions/--work--/messages/_scheduled/receipts.jsonl',
    )).valueOrNull;
    if (text == null || text.isEmpty) return const [];
    return [
      for (final line in text.trim().split('\n'))
        jsonDecode(line) as Map<String, dynamic>,
    ];
  }

  test(
    'gh-1180 AC1: scheduled self-mail wakes the CLI even with the chatter '
    'streak capped, and the exempt wake never counts against the cap',
    () async {
      final fake = FakeStreamFunction([
        textTurn('on watch'),
        textTurn('still on watch'),
      ]);
      final cli = buildCli(fake);
      final run = cli.run();
      final (id, baseline) = await boot(fake, cli);
      // Ten agent-to-agent wakes already burned (the attach-driven REG
      // tests use the same seam): a pure self-scheduled chain has no
      // user-kind input to reset the streak, so pre-fix the gate refuses.
      cli.inboxWakeStreakForTest = 10;

      await sendScheduledSelfMail(id, 'night-watch sweep');

      await waitForTrue(
        () async => fake.calls == baseline + 1 && !cli.isBusy,
      ); // RED pre-fix: the watcher never wakes.
      expect(
        cli.inboxWakeStreakForTest,
        10,
        reason: 'the exempt lane must not count against the chatter cap',
      );

      io.sendLine('/exit');
      await run;
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('gh-1180 AC4: a scheduled-self wake leaves a persisted receipt trail '
      '(wake_attempted + turn_started, correlated by message id)', () async {
    final fake = FakeStreamFunction([textTurn('on watch'), textTurn('ok')]);
    final cli = buildCli(fake);
    final run = cli.run();
    final (id, baseline) = await boot(fake, cli);
    cli.inboxWakeStreakForTest = 10;
    final mailId = await sendScheduledSelfMail(id, 'night-watch sweep');

    await waitForTrue(() async => fake.calls == baseline + 1 && !cli.isBusy);
    final trail = await receipts();
    final attempted = trail.where(
      (event) => event['event'] == 'wake_attempted',
    );
    expect(attempted, isNotEmpty);
    expect(
      (attempted.first['ids'] as List).cast<String>(),
      contains(mailId),
      reason: 'the receipt names the scheduled mail that prompted the wake',
    );
    expect(
      trail.where((event) => event['event'] == 'turn_started'),
      isNotEmpty,
    );

    io.sendLine('/exit');
    await run;
  }, timeout: const Timeout(Duration(seconds: 60)));

  test(
    'gh-1180 AC2 REG: foreign agent chatter stays capped — no wake past '
    'the streak cap, and the refusal is receipted once, not every tick',
    () async {
      final fake = FakeStreamFunction([textTurn('unused')]);
      final cli = buildCli(fake);
      final run = cli.run();
      final (id, baseline) = await boot(fake, cli);
      cli.inboxWakeStreakForTest = 10;

      await sendForeignMail(id, 'ping from a peer agent');
      // The watcher ticks every 2s; wait out three ticks of refusal.
      await Future<void>.delayed(const Duration(seconds: 6));
      expect(
        fake.calls,
        baseline,
        reason: 'anti-storm REG: capped chatter must not wake the agent',
      );
      expect(
        io.out.toString().contains('wake refused'),
        isTrue,
        reason: 'a refused wake is visible, not silent',
      );
      final refused = (await receipts()).where(
        (event) => event['event'] == 'wake_refused',
      );
      expect(refused, hasLength(1), reason: 'one receipt per refusal episode');

      io.sendLine('/exit');
      await run;
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'gh-1180 review T1: a HELD refusal gate receipts one wake_attempted '
    'per episode — not one per 2 s watcher tick (~43k duplicate '
    'lines/day in receipts.jsonl)',
    () async {
      final fake = FakeStreamFunction([textTurn('unused')]);
      final cli = buildCli(fake);
      final run = cli.run();
      final (id, baseline) = await boot(fake, cli);
      cli.inboxWakeStreakForTest = 10;

      await sendForeignMail(id, 'ping from a peer agent');
      await waitForTrue(
        () async => io.out.toString().contains('wake refused'),
      );
      // Hold the gate across three more watcher ticks.
      await Future<void>.delayed(const Duration(seconds: 6));
      final attempted = (await receipts()).where(
        (event) => event['event'] == 'wake_attempted',
      );
      expect(
        attempted,
        hasLength(1),
        reason:
            'the pending batch is unchanged — re-attempting it every tick '
            'is noise, not information',
      );
      expect(fake.calls, baseline, reason: 'still capped, still silent');

      io.sendLine('/exit');
      await run;
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'gh-1180 review T2: a SECOND refusal episode after user input '
    'announces and receipts again — the episode latch resets with the '
    'streak, so a repeat refusal is never silent AND never unreceipted',
    () async {
      final fake = FakeStreamFunction([
        textTurn('ack'),
        textTurn('ack again'),
      ]);
      final cli = buildCli(fake);
      final run = cli.run();
      final (id, baseline) = await boot(fake, cli);
      cli.inboxWakeStreakForTest = 10;

      // Episode #1: capped foreign chatter refuses (visible + receipted).
      await sendForeignMail(id, 'ping 1');
      await waitForTrue(
        () async => io.out.toString().contains('wake refused'),
      );
      expect(
        (await receipts()).where((event) => event['event'] == 'wake_refused'),
        hasLength(1),
      );

      // User input: resets the streak AND ends the refusal episode.
      io.sendLine('hello there');
      await waitForTrue(() async => fake.calls == baseline + 1 && !cli.isBusy);
      expect(cli.inboxWakeStreakForTest, 0);

      // Episode #2: burn the freshly reset cap with chatter again.
      cli.inboxWakeStreakForTest = 10;
      await sendForeignMail(id, 'ping 2');
      await Future<void>.delayed(const Duration(seconds: 6));
      expect(
        'wake refused'.allMatches(io.out.toString()).length,
        2,
        reason: 'the second episode is announced too',
      );
      expect(
        (await receipts()).where((event) => event['event'] == 'wake_refused'),
        hasLength(2),
        reason: 'and receipted too (AC4: every refusal accounted for)',
      );

      io.sendLine('/exit');
      await run;
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
