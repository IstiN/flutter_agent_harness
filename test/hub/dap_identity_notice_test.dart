import 'dart:io';

import 'package:fa_hub_client/fa_hub_client.dart' as hub;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/hub/dap_membership.dart';
import 'package:test/test.dart';

import '../../bin/fah_dap_scoped.dart';
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
  test(
    'scoped boot restores the enrollment instance into the dial env',
    () async {
      final tmp = await Directory.systemTemp.createTemp('dap-instance-boot');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
      final env = <String, String>{'DAP_KEY_PASSPHRASE': 'pass'};
      final membership = DapChannelMembership(
        hubUrl: 'wss://hub.fa1.dev/ws',
        channelId: 'team',
        scope: DapChannelScope.session,
        joinedAt: DateTime.utc(2026, 1, 1),
        agentName: 'same-name',
        agentInstance: '0123456789abcdef',
        hubClientSecret: 'test-enrollment-secret',
      );
      final plugin = hub.HubPlugin(environment: env, home: tmp.path);
      final context = PluginContext(
        env: MemoryExecutionEnv(cwd: tmp.path),
        io: _IO(),
        readSessionRecords: (type) async => [membership.toJson()],
      );
      final host = HubPluginHost(plugin, environment: env, home: tmp.path);
      String? dialed;
      host.scopedConnectOverride = (url) async => dialed = url;
      host.register(context);
      addTearDown(plugin.dispose);
      await waitForIt(() async => dialed != null);

      expect(dialed, membership.hubUrl);
      expect(env['DAP_CLIENT_SECRET'], membership.hubClientSecret);
      expect(env['DAP_AGENT_NAME'], membership.agentName);
      expect(env['DAP_AGENT_INSTANCE'], membership.agentInstance);
    },
  );

  test(
    'direct client-secret boot uses the scoped instance connector',
    () async {
      final tmp = await Directory.systemTemp.createTemp(
        'dap-direct-client-secret',
      );
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
      const url = 'wss://hub.fa1.dev/ws';
      final env = <String, String>{
        'DAP_KEY_PASSPHRASE': 'pass',
        'DAP_CLIENT_SECRET': 'test-enrollment-secret',
        'DAP_HUB_URL': url,
        'DAP_AGENT_NAME': 'same-name',
        'DAP_AGENT_INSTANCE': '0123456789abcdef',
      };
      final plugin = hub.HubPlugin(environment: env, home: tmp.path);
      final context = PluginContext(
        env: MemoryExecutionEnv(cwd: tmp.path),
        io: _IO(),
      );
      final host = HubPluginHost(plugin, environment: env, home: tmp.path);
      String? dialed;
      host.scopedConnectOverride = (hubUrl) async => dialed = hubUrl;
      host.register(context);
      addTearDown(plugin.dispose);

      await waitForIt(() async => dialed != null);
      expect(dialed, url);
    },
  );

  test(
    'direct env boot keeps independent same-name instances online',
    () async {
      final tmp = await Directory.systemTemp.createTemp(
        'dap-direct-instance-boot',
      );
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
      final fakeHub = FakeHub(masterSecret: 'test-master');
      await fakeHub.start();
      addTearDown(fakeHub.stop);

      Future<hub.HubPlugin> connect(String instance) async {
        final env = <String, String>{
          'DAP_KEY_PASSPHRASE': 'pass',
          'DAP_MASTER_SECRET': 'test-master',
          'DAP_HUB_URL': fakeHub.url.toString(),
          'DAP_AGENT_NAME': 'same-name',
          'DAP_AGENT_INSTANCE': instance,
          'DAP_CONFIG_FILE': '${tmp.path}/$instance-config.json',
        };
        final plugin = hub.HubPlugin(environment: env, home: tmp.path);
        final context = PluginContext(
          env: MemoryExecutionEnv(cwd: tmp.path),
          io: _IO(),
        );
        HubPluginHost(
          plugin,
          environment: env,
          home: tmp.path,
        ).register(context);
        addTearDown(plugin.dispose);
        await waitForIt(
          () async =>
              HubPluginHost.activeRepositoryFor(plugin)?.client.connected ??
              false,
        );
        return plugin;
      }

      const firstInstance = '0123456789abcdef';
      const secondInstance = 'fedcba9876543210';
      final first = await connect(firstInstance);
      final second = await connect(secondInstance);
      final firstClient = HubPluginHost.activeRepositoryFor(first)!.client;
      final secondClient = HubPluginHost.activeRepositoryFor(second)!.client;

      expect(firstClient.agentId, isNot(secondClient.agentId));
      await waitForIt(
        () async => firstClient.connected && secondClient.connected,
      );
      final expectedPath = scopedIdentityKeyPath(
        defaultKeyPath: hub.defaultDapKeyPath('same-name', tmp.path),
        explicitKeyPath: false,
        projectCwd: tmp.path,
        instanceId: firstInstance,
      );
      expect(
        firstClient.agentId,
        (await hub.HubIdentity.load(expectedPath)).agentId,
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

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
