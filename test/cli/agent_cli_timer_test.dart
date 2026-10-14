import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// An immediately-ending stream: every call emits one text turn (or the
/// canned 'idle' text when the script ran out) and records the request
/// payloads it was handed.
class _InstantStream {
  _InstantStream(this.turns);

  final List<List<AssistantMessageEvent>> turns;
  final contexts = <Context>[];

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(context);
    final stream = AssistantMessageEventStream();
    final turn = turns.isEmpty ? textTurn('idle') : turns.removeAt(0);
    for (final event in turn) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

/// Split-channel headless IO: [out] is the primary stream (stdout),
/// [diag] the diagnostics stream.
class _HeadlessIO implements CliIO {
  final out = StringBuffer();
  final diag = StringBuffer();

  @override
  bool get isInteractive => false;

  @override
  int columns = 80;

  @override
  int rows = 24;

  @override
  Stream<String> get lines => const Stream.empty();

  @override
  Stream<void> get interrupts => const Stream.empty();

  @override
  Stream<KeyEvent> get keys => const Stream<KeyEvent>.empty();

  @override
  bool get supportsRawMode => false;

  @override
  void write(String text) => out.write(text);

  @override
  void writeln(String text) => diag.write('$text\n');
}

Future<void> _waitFor(bool Function() condition, String reason) async {
  for (var i = 0; i < 4000; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting for $reason');
}

/// gh-1556 AC5/AC6 — the CLI wiring of the ONE session deadline clock:
/// the `/timer` slash command (set/adjust/clear/show), the live
/// `FA_DEADLINE_EPOCH_MS` bash-env projection (mid-session adjustments
/// picked up per exec), the env < flag < `/timer` override order, the
/// one-shot wrap-up steering notices riding the existing
/// `<system-notice>` machinery, and the headless byte-for-byte REG when
/// no deadline is set.
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  /// A fixed-clock deadline so the REPL assertions never race the wall
  /// clock (the real clock is covered by the module + headless suites).
  final fixedNow = DateTime.utc(2026, 1, 1);

  AgentCli cliFor(_InstantStream stream, {SessionDeadline? deadline}) {
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive Value]',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        deadline: deadline ?? SessionDeadline(clock: () => fixedNow),
      ),
      io: io,
      streamFunction: stream.call,
    );
  }

  group('/timer slash command', () {
    test('bare shows the unset state; set shows; clear disarms', () async {
      final stream = _InstantStream(const []);
      final cli = cliFor(stream);
      final run = cli.run();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      io.sendLine('/timer');
      await _waitFor(
        () => io.out.toString().contains('no deadline set'),
        'the unset line',
      );

      io.sendLine('/timer 25m');
      await _waitFor(
        () => io.out.toString().contains('deadline set — time-left: 25min'),
        'the set line',
      );

      io.sendLine('/timer');
      await _waitFor(
        () => io.out.toString().contains('deadline armed — time-left: 25min'),
        'the armed line',
      );

      io.sendLine('/timer clear');
      await _waitFor(
        () => io.out.toString().contains('deadline cleared'),
        'the cleared line',
      );

      io.sendLine('/exit');
      await run;
      expect(cli.deadlineForTest.isArmed, isFalse);
    });

    test('an invalid value is a clear error and keeps the old clock', () async {
      final stream = _InstantStream(const []);
      final cli = cliFor(stream);
      final run = cli.run();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      io.sendLine('/timer 25m');
      await _waitFor(
        () => io.out.toString().contains('deadline set'),
        'the set line',
      );
      io.sendLine('/timer nope');
      await _waitFor(
        () => io.out.toString().contains('invalid /timer value'),
        'the error line',
      );
      expect(cli.deadlineForTest.isArmed, isTrue);
      expect(cli.deadlineForTest.budgetLine(), 'time-left: 25min');

      io.sendLine('/exit');
      await run;
    });

    test('a later /timer overrides an env-seeded clock', () async {
      final envDeadline = SessionDeadline(clock: () => fixedNow);
      envDeadline.setFromSpec('2h');
      final stream = _InstantStream(const []);
      final cli = cliFor(stream, deadline: envDeadline);
      expect(cli.deadlineForTest.budgetLine(), 'time-left: 2h');

      final run = cli.run();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      io.sendLine('/timer 10m');
      await _waitFor(
        () => io.out.toString().contains('deadline set — time-left: 10min'),
        'the override line',
      );
      expect(cli.deadlineForTest.budgetLine(), 'time-left: 10min');

      io.sendLine('/exit');
      await run;
    });
  });

  group('bash env projection (FA_DEADLINE_EPOCH_MS)', () {
    test('armed: the live value rides the session env vars', () async {
      final now = fixedNow;
      final deadline = SessionDeadline(clock: () => now);
      final stream = _InstantStream(const []);
      final cli = cliFor(stream, deadline: deadline);
      final run = cli.run();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      io.sendLine('/timer 25m');
      await _waitFor(
        () => io.out.toString().contains('deadline set'),
        'the set line',
      );
      final vars = await cli.sessionEnvVarsForTest();
      expect(vars[deadlineEpochMsEnvVar], isNotNull);
      final epoch = int.parse(vars[deadlineEpochMsEnvVar]!);
      expect(epoch, now.millisecondsSinceEpoch + 25 * 60 * 1000);

      // Mid-session adjustment is picked up LIVE (resolved per exec).
      io.sendLine('/timer 1h');
      await _waitFor(
        () => io.out.toString().contains('deadline set — time-left: 1h'),
        'the adjusted line',
      );
      final adjusted = await cli.sessionEnvVarsForTest();
      expect(
        int.parse(adjusted[deadlineEpochMsEnvVar]!),
        now.millisecondsSinceEpoch + 60 * 60 * 1000,
      );

      io.sendLine('/exit');
      await run;
    });

    test('unarmed: the var rides as an empty scrub sentinel', () async {
      // gh-1556 rework review (thread 8/10): the overlay must not just
      // OMIT the key when unarmed — LocalShell merges options.env OVER
      // Platform.environment, so a stale host-exported
      // FA_DEADLINE_EPOCH_MS would still leak into bash children. The
      // empty-string sentinel scrubs it (resolveSessionDeadline treats
      // an empty value as feature-off).
      final stream = _InstantStream(const []);
      final cli = cliFor(stream);
      final run = cli.run();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final vars = await cli.sessionEnvVarsForTest();
      expect(vars[deadlineEpochMsEnvVar], '');
      io.sendLine('/exit');
      await run;
    });

    test('clear: the overlay scrubs a previously-armed value', () async {
      // Armed → /timer clear: the sentinel must replace the live epoch
      // so the cleared clock cannot ride into later bash execs.
      final stream = _InstantStream(const []);
      final cli = cliFor(stream);
      final run = cli.run();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      io.sendLine('/timer 25m');
      await _waitFor(
        () => io.out.toString().contains('deadline set'),
        'the set line',
      );
      var vars = await cli.sessionEnvVarsForTest();
      expect(vars[deadlineEpochMsEnvVar], isNot(''));

      io.sendLine('/timer clear');
      await _waitFor(
        () => io.out.toString().contains('deadline cleared'),
        'the cleared line',
      );
      vars = await cli.sessionEnvVarsForTest();
      expect(vars[deadlineEpochMsEnvVar], '');
      expect(cli.deadlineForTest.isArmed, isFalse);

      io.sendLine('/exit');
      await run;
    });
  });

  group('wrap-up steering + headless behavior', () {
    Future<List<SessionRecord>> sessionEntries() async {
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final sessions = await repo.list(cwd: '/work');
      if (sessions.isEmpty) return const [];
      final session = await repo.open(sessions.first);
      return session.getEntries();
    }

    String userText(MessageRecord record) {
      final message = record.message;
      if (message is! UserMessage) return '';
      return messageText(message);
    }

    test('armed headless: time-left line per request, one-shot T-3min '
        'drain steer in the session, exit 0', () async {
      final now = DateTime.utc(2026, 1, 1);
      final deadline = SessionDeadline(clock: () => now);
      deadline.setDuration(const Duration(minutes: 2));
      final stream = _InstantStream([textTurn('landed it')]);
      final headlessIo = _HeadlessIO();
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: env,
          sessionRoot: '/sessions',
          headlessRun: true,
          approvalMode: ApprovalMode.unattended,
          deadline: deadline,
        ),
        io: headlessIo,
        streamFunction: stream.call,
      );

      final code = await cli.runHeadless('finish the task');

      expect(code, 0);
      // The wrap-up steer is already crossed at the first steering poll
      // (T-2min < T-3min): exactly ONE system notice, naming the drain.
      final notices = [
        for (final record in await sessionEntries())
          if (record is MessageRecord &&
              userText(record).contains('<system-notice>'))
            userText(record),
      ];
      expect(notices, hasLength(1));
      expect(notices.single, contains('background shell jobs'));
      expect(notices.single, contains('bash_job stop'));
      expect(notices.single, contains('finalize your outputs'));
      // No half-budget noise for a short budget that started inside the
      // wrap-up window.
      expect(notices.single, isNot(contains('Half of your time budget')));

      // The request payload carries the per-turn budget line.
      expect(stream.contexts, hasLength(1));
      final last = stream.contexts.single.messages.last;
      expect(last, isA<UserMessage>());
      expect(messageText(last as UserMessage), startsWith('time-left:'));

      // The final answer still streams to the primary channel untouched.
      expect(headlessIo.out.toString(), 'landed it\n');
    });

    test('deadline-unset headless is byte-for-byte: stdout, session and '
        'payloads unchanged', () async {
      final stream = _InstantStream([textTurn('done reading')]);
      final headlessIo = _HeadlessIO();
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive Value]',
          env: env,
          sessionRoot: '/sessions',
          headlessRun: true,
          approvalMode: ApprovalMode.unattended,
        ),
        io: headlessIo,
        streamFunction: stream.call,
      );

      final code = await cli.runHeadless('read notes.txt');

      expect(code, 0);
      expect(headlessIo.out.toString(), 'done reading\n');
      final entries = await sessionEntries();
      final users = [
        for (final record in entries)
          if (record is MessageRecord) userText(record),
      ].where((text) => text.isNotEmpty).toList();
      expect(users, ['read notes.txt']);
      expect(
        stream.contexts.single.messages.whereType<UserMessage>(),
        hasLength(1),
        reason: 'no budget line, no notices — the payload is legacy-shaped',
      );
    });
  });
}
