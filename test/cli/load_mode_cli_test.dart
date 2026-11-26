/// CLI-level load-mode tests (issue #680 L3/L4 + GOAL #28/#2416 + REG):
/// the default partition boots keep-12 + `others`, `--omp` boots the
/// reduced schema, a deferred call tombstones through the real loop, an
/// `others` mount enters the schema mid-session, and the settings flow
/// round-trips `agent.mode` live (default/pi/omp coexistence — pi keeps
/// its exact 4-tool shape, no discovery surface).
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

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

/// Matcher: the actual iterable contains at least one of [any].
Matcher containsAny(Iterable<Object> any) => _ContainsAny(any);

class _ContainsAny extends Matcher {
  _ContainsAny(this._any);
  final Iterable<Object> _any;

  @override
  bool matches(Object? item, Map<dynamic, dynamic> matchState) =>
      item is Iterable && _any.any(item.contains);

  @override
  Description describe(Description description) =>
      description.add('contains any of ').add(_any.join(', '));
}

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

  group('AC1/E12: the default partition boot manifest', () {
    // This fake env wires no vision/transcription/media slots and the
    // test model is not OpenRouter, so the four conditional tools are
    // capability-absent; lsp/web_search/web_fetch are capability-absent
    // too (no transports). The keep-12 minus those + the `others` stub +
    // the gh-2423 always-on `working_set` (every agent, every host) =
    // exactly 12 entries.
    test(
      'default boot = keep-12 ∩ capabilities + others, nothing else',
      () async {
        final stream = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(stream.call, AgentLoadMode.defaultMode);
        final run = cli.run();
        await io.out.waitUntilContains('fa>');

        io.sendLine('hello');
        await waitForIt(() => stream.calls >= 1);
        final bootBytes = _toolsBytes(stream.contexts.first);
        final bootNames = _toolNames(stream.contexts.first);
        // GOAL #28 review round 2: session_search rides the keep set
        // always-on (the prompt-recall contract pins it under BOTH
        // engines), so the boot manifest is the keep-13 minus the
        // capability-absent names + the `others` stub + the gh-2423
        // always-on `working_set` (C1: every agent, every host) = 12
        // entries.
        expect(bootNames, {
          'read',
          'write',
          'edit',
          'ls',
          'bash',
          'bash_job',
          'memory_add',
          'memory_search',
          'working_set',
          'reply',
          'session_search',
          'others',
        });
        // The deferred candidates stay out of the manifest.
        expect(
          bootNames,
          isNot(containsAny(['task', 'config', 'memory_list'])),
        );
        // E12: capability-absent conditionals are invisible everywhere.
        expect(
          bootNames,
          isNot(
            containsAny([
              'generate_image',
              'generate_video',
              'decide',
              'inspect_image',
            ]),
          ),
        );
        expect(
          jsonDecode(bootBytes),
          isNotNull,
          reason: 'boot schema is valid wire JSON',
        );

        // default → omp → default via the live switch: the final schema
        // returns to the boot shape (E4: the round trip).
        for (final pick in ['3', '1']) {
          final flow = cli.startLoadModeFlow();
          await io.out.waitUntilContains('Load mode (tool schema preset)');
          io.sendLine(pick);
          await waitForIt(() {
            final current = cli.agent.state.tools.map((t) => t.name).toSet();
            return pick == '3'
                ? current.containsAll(['ls', 'task', 'ask', 'others'])
                : (!current.contains('task') && current.containsAll(bootNames));
          });
          io.sendLine('4'); // done
          await flow;
        }

        io.sendLine('/exit');
        await run;

        expect(cli.agent.state.tools.map((t) => t.name).toSet(), bootNames);
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
        await cliIo.out.waitUntilContains('fa>');
        cliIo.sendLine('hello');
        await waitForIt(() => stream.calls >= 1, reason: '$mode turn');
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
      // The omp schema = `others` + every tool whose availability id is
      // essential (families expand: `task` → task_status/task_observe/…),
      // nothing else. The default schema is the keep-12 ∩ capabilities +
      // `others` (the partition), a strictly smaller surface.
      final essential = essentialToolIdsByLoadMode[AgentLoadMode.omp]!;
      final ompNames = ompContext.tools!.map((t) => t.name).toSet();
      expect(ompNames, contains('others'));
      for (final name in ompNames.where((n) => n != 'others')) {
        final id = toolAvailabilityIdOf(name);
        expect(
          id == null || essential.contains(id),
          isTrue,
          reason: 'omp schema carries non-essential $name',
        );
      }
      final defaultNames = defaultContext.tools!.map((t) => t.name).toSet();
      expect(defaultNames, isNot(contains('task')));
      expect(defaultNames, contains('others'));
      expect(defaultNames.length, lessThan(ompNames.length));
    });
  });

  group('omp session loop (issue #680 L3)', () {
    test('unmounted discoverable tombstones through the real loop', () async {
      final stream = FakeStreamFunction([
        toolTurn([const ToolCall(id: 'c1', name: 'lsp', arguments: {})]),
        textTurn('got it'),
      ]);
      final cli = cliFor(stream.call, AgentLoadMode.omp);
      final run = cli.run();
      await io.out.waitUntilContains('fa>');
      io.sendLine('use lsp');
      await waitForIt(() => stream.calls >= 2);
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

    test('others listing mounts a deferred tool into the schema', () async {
      final contexts = <Context>[];
      var calls = 0;
      late final AgentCli cli;
      AssistantMessageEventStream streamFn(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
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
          // First call: list what is deferred (no arguments).
          for (final event in toolTurn([
            const ToolCall(id: 'c1', name: 'others', arguments: {}),
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
            ToolCall(id: 'c2', name: 'others', arguments: {'tool_name': name}),
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
      }

      cli = cliFor(streamFn, AgentLoadMode.omp);
      final run = cli.run();
      await io.out.waitUntilContains('fa>');
      io.sendLine('list and mount');
      await waitForIt(() => calls >= 3);
      io.sendLine('and now');
      await waitForIt(() => calls >= 4);
      io.sendLine('/exit');
      await run;

      // The listing named a deferred tool, the mount reported it with the
      // I4 doc bytes, and the schema gained it for the NEXT request (the
      // loop snapshots the run's tools at run start, so the next run
      // picks the mount up).
      final listing = cli.agent.state.messages
          .whereType<ToolResultMessage>()
          .map((m) => (m.content.single as TextContent).text)
          .firstWhere((t) => t.startsWith('Deferred tools'));
      final mountedName = listing
          .split('\n')
          .firstWhere((l) => l.startsWith('- '))
          .substring(2)
          .split(': ')[0];
      expect(
        contexts[1].tools!.map((t) => t.name),
        isNot(contains(mountedName)),
      );
      final mountResult = cli.agent.state.messages
          .whereType<ToolResultMessage>()
          .map((m) => (m.content.single as TextContent).text)
          .firstWhere((t) => t.startsWith('Loaded'));
      expect(
        mountResult,
        contains('Loaded `$mountedName` (now in the schema):'),
      );
      expect(
        mountResult,
        contains(
          '\n${jsonEncode(cli.agent.state.tools.firstWhere((t) => t.name == mountedName).parameters)}',
        ),
      );
      expect(cli.agent.state.tools.map((t) => t.name), contains(mountedName));
      expect(contexts[3].tools!.map((t) => t.name), contains(mountedName));
    });
  });

  group('settings load-mode flow (issue #680 AC3/L4)', () {
    test(
      'picking omp writes agent.mode and live-applies without restart',
      () async {
        final stream = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(stream.call, AgentLoadMode.defaultMode);
        final run = cli.run();
        await io.out.waitUntilContains('fa>');

        final flow = cli.startLoadModeFlow();
        await io.out.waitUntilContains('Load mode (tool schema preset)');
        io.sendLine('3'); // omp
        await waitForIt(
          // GOAL #2416: `others` alone does NOT discriminate — the default
          // partition boots it too. The omp-distinctive state: the task
          // family + ask load (id-level essentials) while memory_add
          // (keep-12 under default) demotes away.
          () =>
              cli.agent.state.tools.map((t) => t.name).toSet().containsAll([
                'ls',
                'task',
                'ask',
                'others',
              ]) &&
              !cli.agent.state.tools.any((t) => t.name == 'memory_add'),
        );
        io.sendLine('4'); // done
        await flow;
        io.sendLine('/exit');
        await run;

        final written = (await env.readTextFile(
          '/home/u/.fah/config.yaml',
        )).valueOrNull;
        expect(written, isNotNull);
        expect(written, contains('mode: omp'));
        expect(
          cli.agent.state.tools.map((t) => t.name).toSet(),
          containsAll(['read', 'write', 'edit', 'bash', 'ls', 'task', 'ask']),
        );
      },
    );

    test(
      'modes coexist: default → omp → pi rebuilds the schema live',
      () async {
        final stream = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(stream.call, AgentLoadMode.defaultMode);
        final run = cli.run();
        await io.out.waitUntilContains('fa>');
        Set<String> names() => cli.agent.state.tools.map((t) => t.name).toSet();

        // default boot: the partition (no task family, others present).
        expect(names(), isNot(contains('task')));
        expect(names(), contains('others'));

        for (final (pick, settled) in [
          ('3', () => names().containsAll(['ls', 'task', 'ask', 'others'])),
          (
            '2',
            // pi: pi-mono's EXACT benchmark shape (issue #679) — the 4-tool
            // base, discovery OFF (no others stub), nothing else.
            () =>
                names().containsAll(['read', 'write', 'edit', 'bash']) &&
                !names().contains('others') &&
                !names().contains('ls'),
          ),
          (
            '1',
            // default: the stub is back and the partition restored —
            // task family deferred again (web_search et al. are
            // capability-absent in this env). The condition MUST stay
            // false in the pi state: an instantly-true wait sends done
            // before the pick is processed, racing the flow's reader.
            () =>
                !names().contains('task') &&
                names().containsAll([
                  'read',
                  'write',
                  'edit',
                  'bash',
                  'ls',
                  'memory_add',
                  'reply',
                  'others',
                ]),
          ),
        ]) {
          final flow = cli.startLoadModeFlow();
          await io.out.waitUntilContains('Load mode (tool schema preset)');
          io.sendLine(pick);
          await waitForIt(settled, reason: 'switch on pick $pick');
          io.sendLine('4'); // done
          await flow;
        }

        // The final write is explicit `default` (legal, keeps the file
        // parseable) and the schema is back to the full set.
        final written = (await env.readTextFile(
          '/home/u/.fah/config.yaml',
        )).valueOrNull;
        expect(written, contains('mode: default'));

        io.sendLine('/exit');
        await run;
      },
    );
  });
}
