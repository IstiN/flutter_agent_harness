// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fa_hub_client/fa_hub_client.dart' as hub;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/hub/dap_membership.dart';
import 'package:test/test.dart';

import '../../bin/fah_dap_scoped.dart';
import '../../bin/fah_hub_plugin.dart';
import '../../bin/hub_fabric_repository.dart';
import '../cli/agent_cli_test_support.dart';
import 'fake_hub.dart';

void main() {
  for (final scope in [DapChannelScope.session, DapChannelScope.project]) {
    test(
      'resumed ${scope.name} membership joins before channel mail wakes '
      'the idle agent',
      () => _verifyResume(scope),
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }
}

Future<void> _verifyResume(DapChannelScope scope) async {
  final tmp = await Directory.systemTemp.createTemp('dap-resume-test');
  final fakeHub = FakeHub();
  await fakeHub.start();
  final sender = hub.HubClient(
    config: hub.HubConfig(url: fakeHub.url.toString()),
    identity: await hub.HubIdentity.generate(),
  );
  await sender.connect();
  final io = FakeCliIO();
  var cliRunning = false;
  Future<void>? run;
  hub.HubPlugin? plugin;
  late AgentCli cli;
  try {
    final channel = 'resumed-${scope.name}';
    sender.join(channel, '');
    final membership = DapChannelMembership(
      hubUrl: fakeHub.url.toString(),
      channelId: channel,
      scope: scope,
      joinedAt: DateTime.utc(2026, 10, 24),
    );
    final env = MemoryExecutionEnv(cwd: tmp.path, shell: FakeShell());
    await env.writeFile('${tmp.path}/.fah/memory/.last_maintenance', '');
    final sessions = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final sessionName = 'ai_${scope.name}';
    final persisted = await sessions.create(
      JsonlSessionCreateOptions(cwd: tmp.path, metadata: {'agent': 'cli'}),
    );
    await persisted.appendSessionName(sessionName);
    await persisted.appendMessage(UserMessage.text('before resume'));
    if (scope == DapChannelScope.session) {
      await persisted.appendCustomEntry(
        customType: dapMembershipRecordType,
        data: membership.toJson(),
      );
    } else {
      final project = File('${tmp.path}/.fah/dap.json');
      await project.parent.create(recursive: true);
      await project.writeAsString(
        jsonEncode({
          'channels': [membership.toJson()],
        }),
      );
    }

    final dapEnvironment = <String, String>{
      'DAP_MASTER_SECRET': 'test-master',
      'DAP_HUB_URL': fakeHub.url.toString(),
    };
    plugin = hub.HubPlugin(environment: dapEnvironment, home: tmp.path);
    final host = HubPluginHost(
      plugin,
      environment: dapEnvironment,
      home: tmp.path,
      fabricDeliversMail: true,
    );
    final fabric = HubFabricRepository(
      plugin,
      repositoryResolver: HubPluginHost.activeRepositoryFor,
      publicChannelChecker: HubPluginHost.publicChannelFor,
      channelLister: HubPluginHost.joinedChannelsFor,
    );
    final resumedJoin = fakeHub.joins.firstWhere(
      (join) => join.channel == channel && join.agentId != sender.agentId,
    );
    final stream = FakeStreamFunction([textTurn('awake')]);
    final capturing = _ContextCapturingPlugin(host);
    cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        sessionName: sessionName,
        providerKind: 'openai-completions',
        plugins: [capturing],
        hubFabric: fabric,
      ),
      io: io,
      streamFunction: stream.call,
    );
    if (scope == DapChannelScope.session) {
      // Consume the one-shot boot sync while _session is still null. Replay
      // must invalidate this empty view instead of leaving the channel
      // unjoined forever.
      await waitForIt(
        () async =>
            HubPluginHost.activeRepositoryFor(plugin!)?.client.connected ??
            false,
      );
      for (final inbox in capturing.context.externalInboxes) {
        await inbox.drain();
      }
    }
    run = cli.run();
    cliRunning = true;
    await waitForIt(
      () async => io.out.toString().contains('restored session: $sessionName'),
    );

    // The first idle probe after replay must finish any deferred membership
    // sync; no user turn or notice-inbox drain is involved here.
    await cli.inboxWakeTickForTest();
    await resumedJoin.timeout(const Duration(seconds: 5));

    final text = 'arrived after ${scope.name} resume';
    await sender.sendChannelEnvelope(
      channel,
      (frameId) async => hub.encodePublicChannelText(text),
    );
    await waitForIt(
      () async => (await fabric.peek(
        'main',
      )).any((message) => message.text == text && message.toId == '#$channel'),
    );
    await cli.inboxWakeTickForTest();
    await waitForIt(() async => stream.calls == 1 && !cli.isBusy);

    final delivered = stream.contexts.single.messages
        .whereType<UserMessage>()
        .map((message) => message.content)
        .whereType<String>()
        .join('\n');
    expect(delivered, contains(text));
    expect(delivered, contains('from ${sender.agentId} in #$channel'));

    io.sendLine('/exit');
    await run;
    cliRunning = false;
  } finally {
    if (cliRunning) {
      io.sendLine('/exit');
      await run!.timeout(const Duration(seconds: 5));
    }
    await plugin?.dispose();
    await io.close();
    await sender.disconnect();
    await fakeHub.stop();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  }
}

final class _ContextCapturingPlugin implements FahPlugin {
  _ContextCapturingPlugin(this._host);

  final HubPluginHost _host;
  late final PluginContext context;

  @override
  String get name => _host.name;

  @override
  void register(PluginContext context) {
    this.context = context;
    _host.register(context);
  }
}
