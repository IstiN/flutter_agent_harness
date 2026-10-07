import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// Line-mode `/models` coverage (issue #1234: `_listModels` sat at 0%
/// coverage — line-mode-only output — and capped the CRAP ratchet) plus
/// the TUI provider-picker routing (`_tuiPickProvider`).
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  AgentCli cliFor(StreamFunction streamFunction) {
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  /// Boots the CLI and waits for the idle prompt (the shared pattern:
  /// not busy and something painted). The returned [run] future must be
  /// awaited after `/exit`.
  Future<(AgentCli, Future<void>)> boot() async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call);
    final run = cli.run();
    await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);
    return (cli, run);
  }

  test('/models lists numbered candidates with the switch hint', () async {
    final (cli, run) = await boot();
    io.sendLine('/models');
    await waitForIt(() => io.out.toString().contains('use /model <n> or'));

    final out = io.out.toString();
    expect(out, contains('models (provider/model):'));
    // Numbered rows so `/model <n>` can pick one; the active model is
    // always a candidate.
    expect(out, matches(RegExp(r'^\s*1\) \S+/\S+', multiLine: true)));

    io.sendLine('/exit');
    await run;
  });

  test('/models with an unknown filter reports no models', () async {
    final (cli, run) = await boot();
    io.sendLine('/models zzz-no-such-model-filter');
    await waitForIt(() => io.out.toString().contains('no models available'));

    io.sendLine('/exit');
    await run;
  });

  test('the TUI provider picker routes add and saved keys', () async {
    final (cli, run) = await boot();

    // `add` opens the preset picker; execution must not throw and the
    // REPL must stay alive.
    await cli.tuiPickProviderForTest('add');
    expect(cli.addProviderItemsForTest(), isNotEmpty);

    // A `saved:` key for an unknown provider is a silent no-op (the
    // entry lookup misses and nothing opens).
    await cli.tuiPickProviderForTest('saved:does-not-exist');

    io.sendLine('/exit');
    await run;
  });
}
