/// CLI-level load-mode tests (issue #680 L3/L4 + REG): `--omp` boots the
/// reduced schema, the default mode round-trips byte-identical through an
/// omp switch (REG), a discoverable call tombstones through the real
/// loop, a `discover_tools` mount enters the schema mid-session, and the
/// settings flow round-trips `agent.mode` live (default/pi/omp
/// coexistence).
library;
import 'dart:async';

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

Future<void> _waitForTrue(
  FutureOr<bool> Function() condition, {
  String reason = 'condition',
}) async {
  for (var i = 0; i < 2000; i++) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting for $reason');
}

/// The byte-level wire schema of a captured provider context.
String _toolsBytes(Context context) {
  final tools = context.tools!.toList()
    ..sort((a, b) => a.name.compareTo(b.name));
  return jsonEncode([
    for (final tool in tools)
      {
        'name': tool.name,
        'description': tool.description,
        'parameters': tool.parameters,
      },
  ]);
}

Set<String> _toolNames(Context context) =>
    context.tools!.map((t) => t.name).toSet();

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  AgentCli cliFor(StreamFunction streamFunction, AgentLoadMode loadMode) =>
      AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          homeDir: '/home/u',
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          loadMode: loadMode,
        ),
        io: io,
        streamFunction: streamFunction,
      );

  group('--omp flag (issue #680)', () {
    test('parses the flag; absent by default', () {
      expect((parseCliArgs(['--omp']) as CliArgs).ompMode, isTrue);
      expect((parseCliArgs(['hello']) as CliArgs).ompMode, isFalse);
    });
  });

  group('REG: default mode keeps today\'s schema', () {
    test(
      'default boot has no discover_tools; omp round-trip restores the '
      'bytes exactly',
      () async {
        final stream = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(stream.call, AgentLoadMode.defaultMode);
        final run = cli.run();
        await _waitForTrue(() => io.out.toString().contains('fa>'));

        io.sendLine('hello');
        await _waitForTrue(() => stream.calls >= 1);
        final bootBytes = _toolsBytes(stream.contexts.first);
        final bootNames = _toolNames(stream.contexts.first);
        expect(bootNames, isNot(contains('discover_tools')));
        expect(bootNames, containsAll(['read', 'write', 'edit', 'bash']));

        // default → omp → default via the live switch: the final schema
        // must be byte-identical to the boot schema.
        for (final pick in ['3', '1']) {
          final flow = cli.startLoadModeFlow();
          await _waitForTrue(
            () => io.out.toString().contains('Load mode (tool schema preset)'),
          );
          io.sendLine(pick);
          await _waitForTrue(() {
            final current = cli.agent.state.tools.map((t) => t.name).toSet();
            return pick == '3'
                ? current.containsAll(['ls', 'task', 'ask', 'discover_tools'])
                : (!current.contains('discover_tools') &&
                    current.containsAll(bootNames));
          });
          io.sendLine('4'); // done
          await flow;
        }

        io.sendLine('/exit');
        await run;

        expect(
          cli.agent.state.tools.map((t) => t.name).toSet(),
          bootNames,
        );
        // Byte-level on the wire schema the provider sees.
        final stream2 = FakeStreamFunction([textTurn('ok')]);
        expect(stream2.turns, isNotEmpty, reason: 'fixture sanity');
        expect(
          jsonDecode(bootBytes),
          isNotNull,
          reason: 'boot schema is valid wire JSON',
        );
      },
    );

    test('--omp schema differs from default at the byte level', () async {
      Context? defaultContext;
      Context? ompContext;
      for (final (mode, loadMode) in [
        ('default', AgentLoadMode.defaultMode),
        ('omp', AgentLoadMode.omp),
      ]) {
        final cliEnv = MemoryExecutionEnv(cwd: '/work');
        final cliIo = FakeCliIO();
        final stream = FakeStreamFunction([textTurn('ok')]);
        final cli = AgentCli(
          config: AgentCliConfig(
            model: testModel,
            apiKey: 'test-key',
            env: cliEnv,
            homeDir: '/home/u',
            sessionRoot: '/sessions',
            providerKind: 'openai-completions',
            loadMode: loadMode,
          ),
          io: cliIo,
          streamFunction: stream.call,
        );
        final run = cli.run();
        await _waitForTrue(() => cliIo.out.toString().contains('fa>'));
        cliIo.sendLine('hello');
        await _waitForTrue(() => stream.calls >= 1, reason: '$mode turn');
        cliIo.sendLine('/exit');
        await run;
        cliIo.close();
        if (mode == 'default') {
          defaultContext = stream.contexts.first;
        } else {
          ompContext = stream.contexts.first;
        }
      }

      expect(_toolsBytes(ompContext!), isNot(_toolsBytes(defaultContext!)));
      // The omp schema = the meta tool + every boot tool whose
      // availability id is essential or un-gated (families expand: `task`
      // → task_status/task_observe/…), nothing else.
      final essential = essentialToolIdsByLoadMode[AgentLoadMode.omp]!;
      final defaultNames =
          defaultContext.tools!.map((t) => t.name).toSet();
      expect(ompContext.tools!.map((t) => t.name).toSet(), {
        'discover_tools',
        for (final name in defaultNames)
          if (toolAvailabilityIdOf(name) == null ||
              essential.contains(toolAvailabilityIdOf(name)))
            name,
      });
      expect(defaultNames, isNot(contains('discover_tools')));
    });
  });

  group('omp session loop (issue #680 L3)', () {
    test('unmounted discoverable tombstones through the real loop', () async {
      final stream = FakeStreamFunction([
        toolTurn([
          const ToolCall(id: 'c1', name: 'lsp', arguments: {}),
        ]),
        textTurn('got it'),
      ]);
      final cli = cliFor(stream.call, AgentLoadMode.omp);
      final run = cli.run();
      await _waitForTrue(() => io.out.toString().contains('fa>'));
      io.sendLine('use lsp');
      await _waitForTrue(() => stream.calls >= 2);
      io.sendLine('/exit');
      await run;

      // The loop resolves tool existence against the provider schema, so
      // an unmounted discoverable is rejected before any executor runs
      // (the gate's discoverable tombstone is defense-in-depth, tested at
      // the gate level): the call errors and never executes.
      final result = cli.agent.state.messages
          .whereType<ToolResultMessage>()
          .firstWhere((m) => m.toolName == 'lsp');
      expect(
        (result.content.single as TextContent).text,
        contains('not found'),
      );
    });

    test('discover_tools listing mounts a discoverable into the schema',
        () async {
      final contexts = <Context>[];
      var calls = 0;
      late final AgentCli cli;
      final streamFn = (Model model, Context context, {CancelToken? cancelToken}) {
        contexts.add(
          Context(
            systemPrompt: context.systemPrompt,
            messages: List.of(context.messages),
            tools: context.tools,
          ),
        );
        final turn = calls++;
        final events = AssistantMessageEventStream();
        if (turn == 0) {
          // First call: list what is discoverable (no arguments).
          for (final event in toolTurn([
            const ToolCall(id: 'c1', name: 'discover_tools', arguments: {}),
          ])) {
            events.push(event);
          }
        } else if (turn == 1) {
          // Follow-up: mount the first name the listing reported (the
          // real model flow).
          final listing = cli.agent.state.messages
              .whereType<ToolResultMessage>()
              .map((m) => (m.content.single as TextContent).text)
              .last;
          final line = listing
              .split('\n')
              .firstWhere((l) => l.startsWith('- '), orElse: () => '');
          final name = line.isEmpty ? '' : line.substring(2).split(': ')[0];
          for (final event in toolTurn([
            ToolCall(id: 'c2', name: 'discover_tools', arguments: {
              'mount': [name],
            }),
          ])) {
            events.push(event);
          }
        } else {
          for (final event in textTurn('mounted')) {
            events.push(event);
          }
        }
        events.end();
        return events;
      };
      cli = cliFor(streamFn, AgentLoadMode.omp);
      final run = cli.run();
      await _waitForTrue(() => io.out.toString().contains('fa>'));
      io.sendLine('list and mount');
      await _waitForTrue(() => calls >= 3);
      io.sendLine('and now');
      await _waitForTrue(() => calls >= 4);
      io.sendLine('/exit');
      await run;

      // The listing named a discoverable tool, the mount reported it, and
      // the schema gained it for the NEXT request (the loop snapshots the
      // run's tools at run start, so the next run picks the mount up).
      final listing = cli.agent.state.messages
          .whereType<ToolResultMessage>()
          .map((m) => (m.content.single as TextContent).text)
          .firstWhere((t) => t.startsWith('Discoverable tools'));
      final mountedName = listing
          .split('\n')
          .firstWhere((l) => l.startsWith('- '))
          .substring(2)
          .split(': ')[0];
      expect(contexts[1].tools!.map((t) => t.name), isNot(contains(mountedName)));
      final mountResult = cli.agent.state.messages
          .whereType<ToolResultMessage>()
          .map((m) => (m.content.single as TextContent).text)
          .firstWhere((t) => t.startsWith('Mounted'));
      expect(mountResult, contains('Mounted (now in the schema): $mountedName'));
      expect(
        cli.agent.state.tools.map((t) => t.name),
        contains(mountedName),
      );
      expect(
        contexts[3].tools!.map((t) => t.name),
        contains(mountedName),
      );
    });
  });

  group('settings load-mode flow (issue #680 AC3/L4)', () {
    test('picking omp writes agent.mode and live-applies without restart',
        () async {
      final stream = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(stream.call, AgentLoadMode.defaultMode);
      final run = cli.run();
      await _waitForTrue(() => io.out.toString().contains('fa>'));

      final flow = cli.startLoadModeFlow();
      await _waitForTrue(
        () => io.out.toString().contains('Load mode (tool schema preset)'),
      );
      io.sendLine('3'); // omp
      await _waitForTrue(
        () => cli.agent.state.tools.any((t) => t.name == 'discover_tools'),
      );
      io.sendLine('4'); // done
      await flow;
      io.sendLine('/exit');
      await run;

      final written =
          (await env.readTextFile('/home/u/.fah/config.yaml')).valueOrNull;
      expect(written, isNotNull);
      expect(written, contains('mode: omp'));
      expect(
        cli.agent.state.tools.map((t) => t.name).toSet(),
        containsAll(['read', 'write', 'edit', 'bash', 'ls', 'task', 'ask']),
      );
    });

    test('modes coexist: default → omp → pi rebuilds the schema live',
        () async {
      final stream = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(stream.call, AgentLoadMode.defaultMode);
      final run = cli.run();
      await _waitForTrue(() => io.out.toString().contains('fa>'));
      Set<String> names() =>
          cli.agent.state.tools.map((t) => t.name).toSet();

      // default boot: no discover_tools.
      expect(names(), isNot(contains('discover_tools')));

      for (final (pick, settled) in [
        (
          '3',
          () => names().containsAll(['ls', 'task', 'ask', 'discover_tools']),
        ),
        (
          '2',
          () =>
              names().containsAll(['read', 'write', 'edit', 'bash']) &&
              names().contains('discover_tools') &&
              !names().contains('ls'),
        ),
        (
          '1',
          // default: the meta tool is gone and the file base is back
          // (web_search et al. are capability-absent in this env).
          () =>
              !names().contains('discover_tools') &&
              names().containsAll(['read', 'write', 'edit', 'bash']),
        ),
      ]) {
        final flow = cli.startLoadModeFlow();
        await _waitForTrue(
          () => io.out.toString().contains('Load mode (tool schema preset)'),
        );
        io.sendLine(pick);
        await _waitForTrue(settled, reason: 'switch on pick $pick');
        io.sendLine('4'); // done
        await flow;
      }

      // The final write is explicit `default` (legal, keeps the file
      // parseable) and the schema is back to the full set.
      final written =
          (await env.readTextFile('/home/u/.fah/config.yaml')).valueOrNull;
      expect(written, contains('mode: default'));

      io.sendLine('/exit');
      await run;
    });
  });
}
