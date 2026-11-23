import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

Usage chainUsage(int tokens) => Usage(
  input: tokens,
  output: 0,
  cacheRead: 0,
  cacheWrite: 0,
  totalTokens: tokens,
  cost: const UsageCost(),
);

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

  AgentCli buildCli(
    FakeStreamFunction fake, {
    MessagingConfig? messaging,
    MessagingRepository? hubFabric,
  }) => AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: '[REDACTED:Sensitive-Value]',
      env: env,
      sessionRoot: '/sessions',
      providerKind: 'openai-completions',
      messaging: messaging,
      hubFabric: hubFabric,
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
    'goal_builder boot race: the inbox wake defers while a session load '
    'is in flight — the half-loaded agent never starts a run (the '
    'over-window guard would kill the scheduled task before the boot cap)',
    () async {
      final fake = FakeStreamFunction([
        textTurn('woken after load settled'),
        textTurn('done'),
      ]);
      final cli = buildCli(fake);
      final run = cli.run();
      final (id, baseline) = await boot(fake, cli);

      // Simulate the marathon-file load window: the watcher tick fires
      // mid-load.
      cli.sessionLoadsInFlightForTest = 1;
      await sendScheduledSelfMail(id, 'night-watch sweep');
      await cli.inboxWakeTickForTest();
      expect(fake.calls, baseline, reason: 'no run may start mid-load');
      expect(cli.isBusy, isFalse);

      // The load settles — the next tick drains the pending mail.
      cli.sessionLoadsInFlightForTest = 0;
      await cli.inboxWakeTickForTest();
      await waitForTrue(() async => fake.calls == baseline + 1 && !cli.isBusy);

      io.sendLine('/exit');
      await run;
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'gh-1180 AC1: scheduled self-mail wakes the CLI even with the chatter '
    'streak capped, and the exempt wake never counts against the cap',
    () async {
      final fake = FakeStreamFunction([
        textTurn('on watch'),
        textTurn('still on watch'),
      ]);
      final cli = buildCli(
        fake,
        messaging: const MessagingConfig(wakeChatterCap: 10),
      );
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
    final cli = buildCli(
      fake,
      messaging: const MessagingConfig(wakeChatterCap: 10),
    );
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
      final cli = buildCli(
        fake,
        messaging: const MessagingConfig(wakeChatterCap: 10),
      );
      final run = cli.run();
      final (id, baseline) = await boot(fake, cli);
      cli.inboxWakeStreakForTest = 10;

      await sendForeignMail(id, 'ping from a peer agent');
      // Three ticks, not one: the refusal never consumes the mail — it
      // stays pending, so every tick re-evaluates the cap. Three ticks
      // prove the anti-storm steady state (the cap never erodes across
      // repeated exposure), not just a single decision.
      await cli.inboxWakeTickForTest();
      await cli.inboxWakeTickForTest();
      await cli.inboxWakeTickForTest();

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

  test('gh-1180 review T1: a HELD refusal gate receipts one wake_attempted '
      'per episode — not one per 2 s watcher tick (~43k duplicate '
      'lines/day in receipts.jsonl)', () async {
    final fake = FakeStreamFunction([textTurn('unused')]);
    final cli = buildCli(
      fake,
      messaging: const MessagingConfig(wakeChatterCap: 10),
    );
    final run = cli.run();
    final (id, baseline) = await boot(fake, cli);
    cli.inboxWakeStreakForTest = 10;

    await sendForeignMail(id, 'ping from a peer agent');
    await waitForTrue(() async => io.out.toString().contains('wake refused'));
    // Three more ticks: the gate is held, so each tick re-refuses — and
    // the once-per-episode latch must keep the receipts at exactly one
    // (the ~43k duplicate-lines/day guard is about REPEATED ticks; one
    // tick could not distinguish a latch from a lone fire).
    await cli.inboxWakeTickForTest();
    await cli.inboxWakeTickForTest();
    await cli.inboxWakeTickForTest();

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
  }, timeout: const Timeout(Duration(seconds: 60)));

  test(
    'gh-1180 review T2: a SECOND refusal episode after user input '
    'announces and receipts again — the episode latch resets with the '
    'streak, so a repeat refusal is never silent AND never unreceipted',
    () async {
      final fake = FakeStreamFunction([textTurn('ack'), textTurn('ack again')]);
      final cli = buildCli(
        fake,
        messaging: const MessagingConfig(wakeChatterCap: 10),
      );
      final run = cli.run();
      final (id, baseline) = await boot(fake, cli);
      cli.inboxWakeStreakForTest = 10;

      // Episode #1: capped foreign chatter refuses (visible + receipted).
      await sendForeignMail(id, 'ping 1');
      await waitForTrue(() async => io.out.toString().contains('wake refused'));
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
      // Tick 1 re-arms and announces the second episode; tick 2 proves
      // the announcement did not double the receipts.
      await cli.inboxWakeTickForTest();
      await cli.inboxWakeTickForTest();
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

  test('gh-1180 review T11: the CLI receipt log is non-null from '
      'construction — the production wake path can never silently skip '
      'the trail because the queue was not built yet', () {
    final fake = FakeStreamFunction([textTurn('unused')]);
    final cli = buildCli(fake);
    // Contract pin for the seam rework: the receipt log is a non-nullable
    // late final created alongside the queue and exposed through this
    // getter — NOT a nullable mutable field assigned as a side effect of
    // the (lazy) queue construction, which the review flagged as
    // load-bearing-but-droppable in production. (Behaviorally the old
    // field was always set — the constructor's tool list forces the lazy
    // queue initializer — so this pin guards the contract, it did not
    // fail pre-fix.)
    expect(
      cli.scheduledReceiptsForTest,
      isNotNull,
      reason:
          'the receipt log is load-bearing in production (wake_attempted '
          '/ turn_started / wake_refused) — it must not depend on the '
          'lazy ScheduledMessageQueue initializer having run',
    );
  });

  // -------------------------------------------------------------------
  // Issue #2226: cap OFF by default, the chain guard gates, pauses are
  // visible with continue/stop.
  // -------------------------------------------------------------------

  test('#2226 AC4 REG: boot restores persisted chain spend before any wake '
      'policy access — a restart cannot mint a fresh budget', () async {
    final fake = FakeStreamFunction([
      textTurn('book this wake', usage: chainUsage(150)),
    ]);
    final cli = buildCli(
      fake,
      messaging: const MessagingConfig(chainBudgetTokens: 150),
    );
    final run = cli.run();
    final (id, baseline) = await boot(fake, cli);

    await sendForeignMail(id, 'a productive status update');
    await cli.inboxWakeTickForTest();
    await waitForTrue(() async => fake.calls == baseline + 1 && !cli.isBusy);
    expect(cli.chainSpendForTest, 150);
    final store = ChainStateStore(
      env: env,
      path: () => '/sessions/--work--/messages/_chain/state.json',
    );
    await waitForTrue(() async => (await store.load())?.tokensSpent == 150);

    io.sendLine('/exit');
    await run;
    await io.close();
    io = FakeCliIO();

    final restartedFake = FakeStreamFunction([]);
    final restarted = buildCli(
      restartedFake,
      messaging: const MessagingConfig(chainBudgetTokens: 150),
    );
    final restartedRun = restarted.run();
    await waitForTrue(() async => restarted.chainSpendForTest == 150);
    expect(
      restarted.chainSpendForTest,
      150,
      reason: 'the constructor must eagerly build and restore the guard',
    );

    final sessions = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    String? restartedId;
    await waitForTrue(() async {
      final others = [
        for (final session in await sessions.list(cwd: '/work'))
          if (session.id != id) session.id,
      ];
      if (others.isEmpty) return false;
      restartedId = others.first;
      return true;
    });
    await sendForeignMail(restartedId!, 'first exchange after restart');
    await restarted.inboxWakeTickForTest();
    await waitForTrue(() async => io.out.toString().contains('chain paused'));
    expect(
      restartedFake.calls,
      0,
      reason: 'the restored 150/150 budget must arm before the next wake',
    );
    expect(
      (await receipts()).where(
        (event) =>
            event['event'] == 'chain_paused' && event['reason'] == 'budget',
      ),
      hasLength(1),
    );

    io.sendLine('/exit');
    await restartedRun;
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('#2226 AC7 REG: scheduled-self spins book and enforce their own '
      'budget with the legacy cap off, then continue recovers', () async {
    final fake = FakeStreamFunction([
      textTurn('deliberate first reminder'),
      textTurn('rapid spin', usage: chainUsage(10)),
      textTurn('recovered'),
    ]);
    final cli = buildCli(
      fake,
      messaging: const MessagingConfig(chainBudgetTokens: 10),
    );
    final run = cli.run();
    final (id, baseline) = await boot(fake, cli);

    await sendScheduledSelfMail(id, 'first reminder');
    await cli.inboxWakeTickForTest();
    await waitForTrue(() async => fake.calls == baseline + 1 && !cli.isBusy);
    expect(cli.chainSpendForTest, 0, reason: 'the exempt cadence is unbilled');

    await sendScheduledSelfMail(id, 'zero-delay spin');
    await cli.inboxWakeTickForTest();
    await waitForTrue(() async => fake.calls == baseline + 2 && !cli.isBusy);
    expect(
      cli.chainSpendForTest,
      10,
      reason: 'a rapid spin must feed the budget even when the cap is off',
    );

    await sendScheduledSelfMail(id, 'spin past budget');
    await cli.inboxWakeTickForTest();
    await waitForTrue(() async => io.out.toString().contains('chain paused'));
    expect(fake.calls, baseline + 2, reason: 'the exhausted spin cannot wake');
    expect(
      (await receipts()).where(
        (event) =>
            event['event'] == 'chain_paused' && event['reason'] == 'budget',
      ),
      hasLength(1),
    );

    await cli.handleChainCommand('continue');
    expect(cli.chainSpendForTest, 0);
    await cli.inboxWakeTickForTest();
    await waitForTrue(() async => fake.calls == baseline + 3 && !cli.isBusy);

    io.sendLine('/exit');
    await run;
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('#2226 AC1: a productive 12-wake money-project chain is NEVER '
      'interrupted with defaults — no refusals, no chain_paused', () async {
    final fake = FakeStreamFunction([
      for (var round = 1; round <= 14; round++) textTurn('ack round $round'),
    ]);
    final cli = buildCli(fake, messaging: const MessagingConfig());
    final run = cli.run();
    final (id, baseline) = await boot(fake, cli);

    for (var round = 1; round <= 12; round++) {
      await sendForeignMail(
        id,
        'build fixed: blocker resolved, bear_naive recalculated, commit '
        'abc000$round delivered, package r$round ready for audit',
      );
      final expected = baseline + round;
      await waitForTrue(() async => fake.calls >= expected && !cli.isBusy);
    }

    expect(fake.calls, baseline + 12, reason: 'every mail woke the agent');
    final trail = await receipts();
    expect(trail.where((event) => event['event'] == 'wake_refused'), isEmpty);
    expect(trail.where((event) => event['event'] == 'chain_paused'), isEmpty);

    io.sendLine('/exit');
    await run;
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('#2226 AC2+AC5: a looping chain pauses with a loop-verdict digest '
      'card and a chain_paused receipt — then /chain continue resumes the '
      'queued mail (never silent, never dropped)', () async {
    final fake = FakeStreamFunction([
      textTurn('ack 1'),
      textTurn('ack 2'),
      textTurn('resumed'),
    ]);
    final cli = buildCli(
      fake,
      messaging: const MessagingConfig(
        loopDetection: ChainLoopDetectionConfig(
          similarityThreshold: 0.5,
          stuckRounds: 2,
        ),
      ),
    );
    final run = cli.run();
    final (id, baseline) = await boot(fake, cli);

    // Three identical no-state exchanges: two allowed (arming + stuck 1),
    // the third hits the stuckRounds-2 verdict.
    for (var round = 1; round <= 2; round++) {
      await sendForeignMail(id, 'are you there? please confirm.');
      await waitForTrue(() async => fake.calls >= baseline + round);
    }
    await sendForeignMail(id, 'are you there? please confirm.');
    await cli.inboxWakeTickForTest();
    await waitForTrue(() async => io.out.toString().contains('chain paused'));

    expect(
      io.out.toString().contains('/chain continue'),
      isTrue,
      reason: 'the digest card names both choices',
    );
    final paused = (await receipts()).where(
      (event) => event['event'] == 'chain_paused',
    );
    expect(paused, hasLength(1));
    expect(paused.first['reason'], 'loop');

    // The user answers the digest: the chain resumes and the queued mail
    // wakes on the next tick.
    io.sendLine('/chain continue');
    await waitForTrue(() async => fake.calls == baseline + 3 && !cli.isBusy);
    expect('chain resumed'.allMatches(io.out.toString()), isNotEmpty);

    io.sendLine('/exit');
    await run;
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('#2226: /chain stop drops the pending agent-kind mail with a '
      'tombstone receipt — and never touches user-kind mail', () async {
    final fake = FakeStreamFunction([
      textTurn('ack 1'),
      textTurn('answering the user mail'),
    ]);
    final cli = buildCli(
      fake,
      messaging: const MessagingConfig(
        loopDetection: ChainLoopDetectionConfig(
          similarityThreshold: 0.5,
          stuckRounds: 1,
        ),
      ),
    );
    final run = cli.run();
    final (id, baseline) = await boot(fake, cli);

    // Pause immediately: the first exchange arms (its wake settles), the
    // second identical one loops.
    await sendForeignMail(id, 'echo ping');
    await cli.inboxWakeTickForTest();
    await waitForTrue(() async => fake.calls >= baseline + 1 && !cli.isBusy);
    await sendForeignMail(id, 'echo ping');
    await cli.inboxWakeTickForTest();
    await waitForTrue(() async => io.out.toString().contains('chain paused'));

    // User-kind mail arrives while paused: stop must KEEP its complete
    // routing envelope queued, including relay attribution and hop budget.
    final userMail = AgentMessage(
      id: newMessageId(),
      fromId: 'relay/main',
      fromName: 'Alice Example',
      toId: '$id/main',
      text: 'stop everything',
      kind: AgentMessageKind.user,
      hops: 3,
      sentAt: DateTime.now().toUtc().toIso8601String(),
    );
    await FileMessagingRepository(
      env: env,
      root: '/sessions/--work--/messages',
    ).send(userMail);

    io.sendLine('/chain stop');
    await waitForTrue(() async => io.out.toString().contains('chain stopped'));

    final stopped = (await receipts()).where(
      (event) => event['event'] == 'chain_stopped',
    );
    expect(stopped, hasLength(1));
    expect(
      stopped.first['dropped'],
      1,
      reason: 'only the agent-kind echo mail was dropped',
    );
    expect(stopped.first['reason'], 'user');

    final preserved = await cli.subagentManager.pendingInbox('main');
    expect(preserved, hasLength(1));
    expect(preserved.single.id, isNot(userMail.id));
    expect(preserved.single.fromId, userMail.fromId);
    expect(preserved.single.fromName, 'Alice Example');
    expect(preserved.single.toId, userMail.toId);
    expect(preserved.single.text, userMail.text);
    expect(preserved.single.kind, AgentMessageKind.user);
    expect(preserved.single.hops, 3);
    expect(preserved.single.sentAt, userMail.sentAt);

    // The pending inbox now holds ONLY the user mail — a further tick
    // wakes on it (user input always wakes), proving nothing was lost.
    await cli.inboxWakeTickForTest();
    await waitForTrue(() async => fake.calls >= baseline + 2 && !cli.isBusy);

    io.sendLine('/exit');
    await run;
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('#2226 AC5 crash boundary: /chain stop queues the user copy before '
      'the original-id drain, so a mid-command crash cannot lose it', () async {
    final hub = _CrashAfterAgentDrainFabric();
    final fake = FakeStreamFunction([textTurn('unused')]);
    final cli = buildCli(fake, hubFabric: hub);
    final run = cli.run();
    final (id, _) = await boot(fake, cli);
    cli.sessionLoadsInFlightForTest = 1;
    final mailbox = '$id/main';
    hub.messages.addAll([
      AgentMessage(
        id: newMessageId(),
        fromId: 'peer/main',
        toId: mailbox,
        text: 'chain chatter',
        sentAt: DateTime.now().toUtc().toIso8601String(),
      ),
      AgentMessage(
        id: newMessageId(),
        fromId: 'relay/main',
        fromName: 'Alice Example',
        toId: mailbox,
        text: 'keep my input',
        kind: AgentMessageKind.user,
        hops: 2,
        sentAt: DateTime.now().toUtc().toIso8601String(),
      ),
    ]);

    // The injected repository dies AFTER its destructive drain. The old
    // drain→re-send sequence has no pending user copy at this boundary.
    await expectLater(cli.handleChainCommand('stop'), throwsStateError);

    final pending = await cli.subagentManager.pendingInbox('main');
    expect(
      pending,
      hasLength(1),
      reason: 'user mail must remain pending even when the command dies',
    );
    expect(pending.single.kind, AgentMessageKind.user);
    expect(pending.single.text, 'keep my input');
    expect(pending.single.fromName, 'Alice Example');
    expect(pending.single.hops, 2);

    io.sendLine('/exit');
    await run;
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('#2226 CRAP units: /chain dispatch pins the status, usage and '
      'paused-evidence shapes', () async {
    final fake = FakeStreamFunction([textTurn('ack 1'), textTurn('ack 2')]);
    final cli = buildCli(
      fake,
      messaging: const MessagingConfig(
        loopDetection: ChainLoopDetectionConfig(
          similarityThreshold: 0.5,
          stuckRounds: 1,
        ),
      ),
    );
    final run = cli.run();
    final (id, baseline) = await boot(fake, cli);

    // Bare status on a RUNNING gate: state, spend and pending count.
    await cli.handleChainCommand('');
    expect(
      io.out.toString(),
      contains('chain: running'),
      reason: 'an unpaused gate reports running',
    );

    // Unknown subcommand: the usage line.
    await cli.handleChainCommand('bogus');
    expect(io.out.toString(), contains('usage: /chain [continue|stop]'));

    // Pause the gate (two identical exchanges arm the loop verdict),
    // then the bare status shows PAUSED with evidence and the escapes.
    await sendForeignMail(id, 'echo ping');
    await cli.inboxWakeTickForTest();
    await waitForTrue(() async => fake.calls >= baseline + 1 && !cli.isBusy);
    await sendForeignMail(id, 'echo ping');
    await cli.inboxWakeTickForTest();
    await waitForTrue(() async => io.out.toString().contains('chain paused'));
    await cli.handleChainCommand('');
    expect(io.out.toString(), contains('chain: PAUSED'));
    expect(io.out.toString(), contains('evidence: '));
    expect(
      io.out.toString(),
      contains('/chain continue - resume · /chain stop - drop mail'),
    );

    io.sendLine('/exit');
    await run;
  }, timeout: const Timeout(Duration(seconds: 90)));
}

/// A hub primary whose consume operation fails after mutating its inbox,
/// modeling the process-failure boundary in `/chain stop`.
final class _CrashAfterAgentDrainFabric
    implements MessagingRepository, SelectiveMessagingRepository {
  final messages = <AgentMessage>[];

  @override
  Future<void> send(AgentMessage message) async => messages.add(message);

  @override
  Future<void> register(
    String agentId, {
    String? sessionName,
    List<AgentCapability> capabilities = const [],
  }) async {}

  @override
  Future<void> touch(String agentId, {bool busy = false}) async {}

  @override
  Future<List<AgentMessage>> peek(String agentId) async => List.of(messages);

  @override
  Future<List<AgentMessage>> drain(String agentId) async {
    final drained = List<AgentMessage>.of(messages);
    messages.clear();
    if (drained.isNotEmpty) {
      throw StateError('simulated crash after destructive drain');
    }
    return drained;
  }

  /// The selective consume operation used by the crash-safe stop path.
  @override
  Future<List<AgentMessage>> drainById(
    String agentId,
    Set<String> messageIds,
  ) async {
    final drained = [
      for (final message in messages)
        if (messageIds.contains(message.id)) message,
    ];
    messages.removeWhere((message) => messageIds.contains(message.id));
    if (drained.isNotEmpty) {
      throw StateError('simulated crash after selective drain');
    }
    return drained;
  }

  @override
  Future<List<MailboxEntry>> directory() async => const [];
}
