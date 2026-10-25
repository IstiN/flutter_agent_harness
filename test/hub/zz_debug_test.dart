import 'dart:io';
import 'package:fa_hub_client/fa_hub_client.dart' as hub;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';
import '../../bin/fah_hub_plugin.dart';

final class CapIo implements PluginIO {
  final lines = <String>[];
  @override
  void write(String t) => lines.add(t);
  @override
  void writeln(String t) => lines.add(t);
}

void main() {
  test('debug start', () async {
    final tmp = await Directory.systemTemp.createTemp('dbg');
    final env = <String, String>{'DAP_HUB_URL': 'ws://127.0.0.1:9/ws'};
    final plugin = hub.HubPlugin(environment: env, home: tmp.path);
    final host = HubPluginHost(plugin, environment: env, home: tmp.path);
    final io = CapIo();
    final ctx = PluginContext(
      env: MemoryExecutionEnv(cwd: '/w'),
      io: io,
      pickOption: (t, o, {initialKey}) async => 'start',
      askLine: (p, {secret = false}) async => '',
    );
    host.register(ctx);
    env['DAP_MASTER_SECRET'] = 'manual-write-works';
    expect(env['DAP_MASTER_SECRET'], 'manual-write-works');
    await ctx.slashCommands['/dap']!([]);
    print('lines: ${io.lines}');
    print('secret: ${env['DAP_MASTER_SECRET']}');
  });
}
