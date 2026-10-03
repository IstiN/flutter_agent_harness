import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

Future<void> waitForTrue(Future<bool> Function() condition) async {
  for (var i = 0; i < 5000; i++) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: async condition');
}

void main() {
  test('diag: where do the wake receipts land?', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    final io = FakeCliIO();
    final fake = FakeStreamFunction([textTurn('on watch'), textTurn('ok')]);
    final cli = AgentCli(
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
    final run = cli.run();
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    await waitForTrue(() async => (await repo.list(cwd: '/work')).isNotEmpty);
    final id = (await repo.list(cwd: '/work')).first.id;
    cli.inboxWakeStreakForTest = 10;
    final mailbox = '$id/main';
    await FileMessagingRepository(
      env: env,
      root: '/sessions/--work--/messages',
    ).send(
      AgentMessage(
        id: newMessageId(),
        fromId: mailbox,
        toId: mailbox,
        text: '[scheduled] diag sweep',
        sentAt: DateTime.now().toUtc().toIso8601String(),
      ),
    );
    await waitForTrue(() async => fake.calls == 1 && !cli.isBusy);
    final files = env
        .exportSnapshot()
        .files.keys
        .where((p) => p.contains('receipts') || p.contains('_scheduled'))
        .toList();
    // ignore: avoid_print
    print('RECEIPT-FILES: $files');
    // ignore: avoid_print
    print('OUT: ${io.out.toString().split('\n').where((l) => l.contains('sched') || l.contains('receipt')).take(5).toList()}');
    io.sendLine('/exit');
    await run;
  }, timeout: const Timeout(Duration(seconds: 60)));
}
