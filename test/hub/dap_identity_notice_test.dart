import 'dart:io';

import 'package:fa_hub_client/fa_hub_client.dart' as hub;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/hub/dap_membership.dart';
import 'package:test/test.dart';

import '../../bin/fah_hub_plugin.dart';
import '../cli/agent_cli_test_support.dart';
import 'fake_hub.dart';

final class _IO implements PluginIO {
  @override
  void write(String text) {}

  @override
  void writeln(String text) {}
}

void main() {
  test('boot channel notice includes the own DAP name and agentId', () async {
    final tmp = await Directory.systemTemp.createTemp('dap-identity-test');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });
    final fakeHub = FakeHub();
    await fakeHub.start();
    addTearDown(fakeHub.stop);
    final env = <String, String>{
      'DAP_KEY_PASSPHRASE': 'pass',
      'DAP_MASTER_SECRET': 'test-master',
      'DAP_HUB_URL': fakeHub.url.toString(),
      'DAP_AGENT_NAME': 'kb-agent',
    };
    final membership = DapChannelMembership(
      hubUrl: fakeHub.url.toString(),
      channelId: 'kb',
      scope: DapChannelScope.session,
      joinedAt: DateTime.utc(2026, 1, 1),
    );
    final plugin = hub.HubPlugin(environment: env, home: tmp.path);
    final context = PluginContext(
      env: MemoryExecutionEnv(cwd: tmp.path),
      io: _IO(),
      readSessionRecords: (type) async => [membership.toJson()],
    );
    HubPluginHost(plugin, environment: env, home: tmp.path).register(context);
    addTearDown(plugin.dispose);
    await waitForIt(
      () async =>
          HubPluginHost.activeRepositoryFor(plugin)?.client.connected ?? false,
    );

    expect(HubPluginHost.dapDisplayNameFor(plugin), 'kb-agent');
    final notices = <AgentMessage>[];
    for (final inbox in context.externalInboxes) {
      notices.addAll(await inbox.drain());
    }
    final text = notices.map((m) => m.text).join('\n');
    final agentId = HubPluginHost.activeRepositoryFor(plugin)!.client.agentId;
    expect(agentId, isNotNull);
    expect(text, contains('#kb'));
    expect(text, contains('Your DAP identity is kb-agent (agentId $agentId).'));
  }, timeout: const Timeout(Duration(seconds: 30)));
}
