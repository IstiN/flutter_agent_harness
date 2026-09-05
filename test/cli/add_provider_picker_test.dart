import 'dart:async';

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
      'aiin',
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

    // THE live bug: a preset row WITHOUT a handler — the picker closed and
    // nothing happened (`null?.call()`). Rows and handlers must be the
    // same set in BOTH directions.
    final handlerKeys = cli.addProviderHandlerKeysForTest();
    expect(
      presetKeys.toSet(),
      handlerKeys,
      reason:
          'every preset row needs a handler and every handler a row — '
          'a row without a handler is a dead menu entry',
    );

    io.sendLine('/exit');
    await run;
  });

  test(
    'the picker covers the whole catalog — preset or documented exclusion',
    () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();
      await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);

      // THE regression guard for the Copilot gap: adding a provider to the
      // catalog without touching the picker must FAIL here. Every catalog
      // provider is either a `preset:<name>` row or carries a written
      // reason in _addProviderExclusions — no silent third state.
      final items = cli.addProviderItemsForTest();
      final presetKeys = {
        for (final item in items)
          if (item.key.startsWith('preset:')) item.key.substring(7),
      };
      final exclusions = cli.addProviderExclusionsForTest();
      for (final reason in exclusions.values) {
        expect(
          reason.trim().length,
          greaterThan(12),
          reason: 'an exclusion must explain WHY, not just exist',
        );
      }
      for (final spec in enabledProviders()) {
        expect(
          presetKeys.contains(spec.name) || exclusions.containsKey(spec.name),
          isTrue,
          reason:
              'catalog provider "${spec.name}" is neither an "Add provider" '
              'preset nor a documented exclusion — add the row to '
              '_addProviderItems + _addProviderHandlers, or write the reason '
              'into _addProviderExclusions',
        );
      }
      // And the reverse: no phantom presets / stale exclusions for
      // providers the catalog no longer knows.
      for (final key in presetKeys) {
        expect(
          catalogProvider(key),
          isNotNull,
          reason: 'preset "$key" has no catalog provider — stale row?',
        );
      }
      for (final name in exclusions.keys) {
        expect(
          catalogProvider(name),
          isNotNull,
          reason: 'exclusion "$name" has no catalog provider — stale entry?',
        );
      }

      io.sendLine('/exit');
      await run;
    },
  );

  test('routing a copilot pick starts the connect flow', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call);
    final run = cli.run();
    await waitForIt(() => !cli.isBusy && io.out.toString().isNotEmpty);

    // The picker handler must land in the same connect flow the typed
    // `/provider copilot` runs — its first step is the sign-in question.
    unawaited(cli.tuiPickAddProviderForTest('preset:copilot'));
    await waitForIt(
      () => io.out.toString().contains('Copilot sign-in'),
      reason: 'the preset row routes to the copilot connect flow',
    );

    // Walk out of the flow the way a user cancels it: paste-token branch,
    // an empty token line cancels — then /exit reaches the REPL again.
    io.sendLine('2');
    await waitForIt(() => io.out.toString().contains('GitHub token:'));
    io.sendLine('');
    await waitForIt(
      () => io.out.toString().contains('Copilot connect cancelled'),
    );
    io.sendLine('/exit');
    await run;
  });
}
