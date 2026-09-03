/// AC1 (issue #19): the `hub` plugin registers its `dap_*` tools ONLY when
/// a hub is actually configured. On the zero-config default URL every tool
/// call would dead-end ("no hub running"), so a fresh install gets zero
/// dap tools; an explicit `DAP_HUB_URL` (env) or `hub:` section
/// (`.fah/packages.yaml`) wires the full surface. The `/dap` slash command
/// and the inbox registration stay unconditional.
@Tags(['integration'])
library;

import 'dart:io';

import 'package:fah_hub_client/fah_hub_client.dart' as hub;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import '../../bin/fah_hub_plugin.dart';
import '../cli/agent_cli_test_support.dart';

/// Swallows plugin output.
class _SilentPluginIo implements PluginIO {
  @override
  void write(String text) {}

  @override
  void writeln(String text) {}
}

void main() {
  late Directory tempHome;

  setUp(() async {
    tempHome = await Directory.systemTemp.createTemp('fah-dap-unconfigured-');
  });

  tearDown(() async {
    if (await tempHome.exists()) tempHome.deleteSync(recursive: true);
  });

  List<AgentTool> registerWith({
    Map<String, String> environment = const {},
    Map<String, dynamic> config = const {},
  }) {
    final host = HubPluginHost(
      hub.HubPlugin(),
      environment: environment,
      home: tempHome.path,
    );
    final context = PluginContext(
      env: MemoryExecutionEnv(cwd: '/work'),
      io: _SilentPluginIo(),
      config: config,
    );
    host.register(context);
    return context.tools;
  }

  test('zero-config default URL registers NO dap tools (AC1)', () {
    final tools = registerWith();
    expect(tools.where((tool) => tool.name.startsWith('dap_')), isEmpty);
  });

  test('an explicit DAP_HUB_URL registers the full dap tool set', () {
    final tools = registerWith(
      // Port 1: connection refused instantly — the unawaited connect fails
      // fast and the test never touches the network for real.
      environment: {'DAP_HUB_URL': 'ws://127.0.0.1:1/ws'},
    );
    expect(tools.where((tool) => tool.name.startsWith('dap_')), hasLength(5));
  });

  test('a hub: section in packages.yaml counts as configured', () {
    final tools = registerWith(config: {'url': 'ws://127.0.0.1:1/ws'});
    expect(tools.where((tool) => tool.name.startsWith('dap_')), hasLength(5));
  });

  test(
    'boot with the hub plugin registers zero dap tools when unconfigured',
    () async {
      final io = FakeCliIO();
      addTearDown(io.close);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: MemoryExecutionEnv(cwd: '/work'),
          sessionRoot: '/sessions',
          plugins: [
            HubPluginHost(
              hub.HubPlugin(),
              environment: const {},
              home: tempHome.path,
            ),
          ],
        ),
        io: io,
        streamFunction: FakeStreamFunction([textTurn('ok')]).call,
      );
      final names = cli.agent.state.tools.map((tool) => tool.name).toSet();
      expect(names.where((name) => name.startsWith('dap_')), isEmpty);
    },
  );
}
