import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('PluginContext', () {
    test('collects registered tools and slash commands', () {
      final context = PluginContext(
        env: MemoryExecutionEnv(),
        io: _FakePluginIO(),
      );
      final tool = AgentTool(
        name: 'demo',
        description: 'demo tool',
        parameters: const {},
        execute: (arguments, cancelToken, onUpdate) async =>
            ToolExecutionResult(content: []),
      );
      context
        ..registerTool(tool)
        ..registerSlashCommand('/demo', (_) async {});

      expect(context.tools, hasLength(1));
      expect(context.tools.first.name, 'demo');
      expect(context.slashCommands.keys, contains('/demo'));
    });
  });

  group('AgentCli plugins', () {
    late MemoryExecutionEnv env;
    late FakeCliIO io;

    setUp(() {
      env = MemoryExecutionEnv();
      io = FakeCliIO();
    });

    tearDown(() => io.close());

    AgentCli cliBuilder(
      List<FahPlugin> plugins, {
      Map<String, dynamic>? config,
    }) {
      return AgentCli(
        config: AgentCliConfig(
          model: Model(
            id: 'test-model',
            api: 'test-api',
            provider: 'test',
            baseUrl: 'https://example.com',
            contextWindow: 100000,
            maxTokens: 4096,
          ),
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          plugins: plugins,
          pluginConfig: config ?? const {},
        ),
        io: io,
        streamFunction: (model, context, {cancelToken}) =>
            AssistantMessageEventStream(),
      );
    }

    test('plugin tools are registered on the agent', () {
      final plugin = _DemoPlugin();
      final cli = cliBuilder([plugin]);
      final names = cli.agent.state.tools.map((t) => t.name);
      expect(names, contains('demo_tool'));
    });

    test('plugin slash commands are dispatched', () async {
      final plugin = _DemoPlugin();
      final cli = cliBuilder(
        [plugin],
        config: {
          'demo': {'greet': 'hello'},
        },
      );
      final run = cli.run();

      io.sendLine('/demo');
      await _waitFor(() => io.out.toString().contains('hello'));
      io.sendLine('/exit');
      await run;
    });

    test('unknown slash command still prints error', () async {
      final cli = cliBuilder([]);
      final run = cli.run();

      io.sendLine('/unknown');
      await _waitFor(
        () => io.out.toString().contains('unknown command: /unknown'),
      );
      io.sendLine('/exit');
      await run;
    });

    test('plugin config is passed to the plugin', () {
      final plugin = _DemoPlugin();
      cliBuilder(
        [plugin],
        config: {
          'demo': {'value': 42},
        },
      );
      expect(plugin.lastConfig['value'], 42);
    });
  });
}

final class _DemoPlugin implements FahPlugin {
  Map<String, dynamic> lastConfig = {};

  @override
  String get name => 'demo';

  @override
  void register(PluginContext context) {
    lastConfig = Map<String, dynamic>.from(context.config);
    context
      ..registerTool(
        AgentTool(
          name: 'demo_tool',
          description: 'demo',
          parameters: const {},
          execute: (arguments, cancelToken, onUpdate) async =>
              ToolExecutionResult(content: []),
        ),
      )
      ..registerSlashCommand('/demo', (args) async {
        context.io.writeln((context.config['greet'] ?? 'hi') as String);
      });
  }
}

// Minimal FakeCliIO copy to avoid cross-test coupling.
class FakeCliIO implements CliIO {
  final _lines = StreamController<String>();
  final _interrupts = StreamController<void>.broadcast();
  final out = StringBuffer();

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Stream<void> get interrupts => _interrupts.stream;

  @override
  void write(String text) => out.write(text);

  @override
  void writeln(String text) => out.writeln(text);

  void sendLine(String line) => _lines.add(line);

  Future<void> close() async {
    unawaited(_lines.close());
    await _interrupts.close();
  }
}

final class _FakePluginIO implements PluginIO {
  final buffer = StringBuffer();

  @override
  void write(String text) => buffer.write(text);

  @override
  void writeln(String text) => buffer.writeln(text);
}

Future<void> _waitFor(bool Function() predicate, {int attempts = 50}) async {
  for (var i = 0; i < attempts; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw StateError('predicate never became true');
}
