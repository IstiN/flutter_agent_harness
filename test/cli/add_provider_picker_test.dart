import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// The "Add provider" preset picker must list every catalog provider with
/// a typed `/provider <name>` connect flow. Copilot shipped MISSING from
/// the picker even though `/provider copilot` (device flow) worked — the
/// list is hand-maintained, so this test pins the pairing.
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

  test('the preset picker lists GitHub Copilot', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call);
    final run = cli.run();
    await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);

    final items = cli.addProviderItemsForTest();
    final keys = items.map((i) => i.key).toList();
    expect(keys, contains('preset:copilot'));
    final copilot = items.firstWhere((i) => i.key == 'preset:copilot');
    expect(copilot.label, contains('Copilot'));

    io.sendLine('/exit');
    await run;
  });

  test('every preset key routes to a handler', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call);
    final run = cli.run();
    await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);

    // A preset row without a handler is a silent dead menu entry. The
    // known connect flows: every catalog provider reachable by a typed
    // `/provider <name>` command plus the guided wizards.
    final items = cli.addProviderItemsForTest();
    final presetKeys = [
      for (final item in items)
        if (item.key.startsWith('preset:')) item.key.substring(7),
    ];
    const expectedFlows = {
      'openrouter',
      'chatgpt',
      'copilot',
      'codemie',
      'dial',
      'kimi',
      'zai',
      'minimax',
      'openai',
      'anthropic',
      'google',
    };
    expect(
      presetKeys.toSet(),
      expectedFlows,
      reason: 'a provider with a typed flow must also be a picker preset',
    );

    io.sendLine('/exit');
    await run;
  });
}
