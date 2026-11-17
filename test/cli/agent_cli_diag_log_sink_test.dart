import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';
import 'wedge_env.dart';

/// Issue #2248 AC4: the fa.log sink never goes blind silently.
///
/// The incident's log hole: the log appends themselves were failing
/// (`catch (_) {}` swallowed even the Result), so the post-mortem had a
/// hole exactly at the failure. Now: the first failure marks
/// `fa_log_sink=fail(errno=...)` on the diagnostics channel, failing
/// lines buffer in a bounded in-memory ring AND ride stderr, and the
/// first successful write flushes the ring with a
/// `log_sink_recovered buffered=N` marker. An exit while still failing
/// dumps the ring instead of losing it.
void main() {
  const emfileMessage = 'Cannot open file (errno 24: Too many open files)';

  late MemoryExecutionEnv mem;
  late WedgeEnv env;
  late FakeCliIO io;

  setUp(() {
    mem = MemoryExecutionEnv(cwd: '/work');
    env = WedgeEnv(mem);
    io = FakeCliIO();
    SessionIoHealth.resetForTests();
  });

  tearDown(() async {
    SessionIoHealth.resetForTests();
    await io.close();
  });

  AgentCli buildCli() {
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive-Value]',
        env: env,
        sessionRoot: '/sessions',
        homeDir: '/home',
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: FakeStreamFunction([textTurn('ok')]).call,
    );
  }

  Future<String> faLog() async =>
      (await env.readTextFile('/home/.fah/logs/fa.log')).valueOrNull ?? '';

  test('the first sink failure marks fa_log_sink=fail(errno) and the line '
      'rides the diagnostics channel', () async {
    env.failNextLogAppends = 99; // the sink stays down for the window.
    env.failLogMessage = emfileMessage;
    final cli = buildCli();
    final run = cli.run();
    await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);

    final out = io.out.toString();
    expect(out, contains('fa_log_sink=fail(errno=24: Too many open files)'));
    // The failed line itself rode the fallback (the boot line).
    expect(out, contains('fa boot'));
    // And nothing landed in the file yet.
    expect(await faLog(), isEmpty);

    io.sendLine('/exit');
    await run;
  });

  test('recovery flushes the buffered ring with the log_sink_recovered '
      'buffered=N marker', () async {
    env.failNextLogAppends = 2; // boot line + probe-1 fail.
    env.failLogMessage = emfileMessage;
    final cli = buildCli();
    final run = cli.run();
    await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);
    cli.logDiagnosticForTest('probe-1');
    await cli.flushDiagnosticLog();

    // Recover: the next append succeeds, the ring flushes first.
    env.failNextLogAppends = 0;
    cli.logDiagnosticForTest('probe-2');
    await cli.flushDiagnosticLog();

    final log = await faLog();
    expect(log, contains('fa boot'), reason: 'the failed boot line flushed');
    expect(log, contains('probe-1'));
    expect(log, contains('probe-2'));
    expect(log, contains('log_sink_recovered buffered=2'));
    expect(log, contains('failed_as=errno=24: Too many open files'));
    expect(io.out.toString(), contains('fa_log_sink=recovered'));

    io.sendLine('/exit');
    await run;
  });

  test('an exit while the sink is still failing dumps the ring to the '
      'diagnostics channel', () async {
    env.failNextLogAppends = 99;
    env.failLogMessage = emfileMessage;
    final cli = buildCli();
    final run = cli.run();
    await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);
    cli.logDiagnosticForTest('lost-1');
    cli.logDiagnosticForTest('lost-2');
    await cli.flushDiagnosticLog();

    final out = io.out.toString();
    expect(out, contains('lost-1'));
    expect(out, contains('lost-2'));
    expect(out, contains('fa_log_sink=exit_drain buffered='));
    // The file never saw them.
    expect(await faLog(), isEmpty);

    io.sendLine('/exit');
    await run;
  });

  test('a healthy sink never emits sink markers (REG)', () async {
    final cli = buildCli();
    final run = cli.run();
    await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);
    cli.logDiagnosticForTest('probe-ok');
    await cli.flushDiagnosticLog();

    final log = await faLog();
    expect(log, contains('fa boot'));
    expect(log, contains('probe-ok'));
    expect(log, isNot(contains('fa_log_sink=')));
    expect(log, isNot(contains('log_sink_recovered')));
    expect(io.out.toString(), isNot(contains('fa_log_sink=')));

    io.sendLine('/exit');
    await run;
  });
}
