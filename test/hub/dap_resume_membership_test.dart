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
      // The dial here is a boot-time backstop, but the boot itself (hub
      // subprocess spawn + connect + restore) is load-sensitive: one
      // body overran 30s under a parallel-gate window, so keep the cap
      // above the generous inner ceilings.
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }
  test(
    'resumed session membership dials its own hub when boot had no '
    'DAP_HUB_URL',
    () => _verifyResume(DapChannelScope.session, bootHubUrl: false),
    // This variant's dial is the LAST stage of the timeline (after the
    // boot, overlay-existence and restore waits below), so its outer cap
    // must leave room for the generous inner ceilings on a loaded machine
    // instead of becoming the effective 5s-equivalent bottleneck.
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

Future<void> _verifyResume(
  DapChannelScope scope, {
  bool bootHubUrl = true,
}) async {
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
      // Without a boot hub URL the resumed membership itself must supply
      // the enrolled credential for the scoped dial.
      hubClientSecret: bootHubUrl ? null : 'resume-client-secret',
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
      if (bootHubUrl) 'DAP_HUB_URL': fakeHub.url.toString(),
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
    if (scope == DapChannelScope.session && bootHubUrl) {
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
    if (!bootHubUrl) {
      // Deterministic boot-before-replay ordering: _connect reads its
      // (empty) membership view BEFORE seedOverlay() writes the runtime
      // overlay, so the overlay's existence proves the boot cannot see
      // the resumed session record any more.
      final overlay = File('${tmp.path}/.dap/runtime/channels.json');
      await waitForIt(overlay.exists);
    }
    run = cli.run();
    cliRunning = true;
    await waitForIt(
      () async => io.out.toString().contains('restored session: $sessionName'),
    );

    // The first idle probe after replay must finish any deferred membership
    // sync; no user turn or notice-inbox drain is involved here.
    await cli.inboxWakeTickForTest();
    // The hub-side join acceptance IS the assertion: `resumedJoin`
    // subscribes to the hub's broadcast join stream before cli.run(), so
    // the event cannot be missed. A hard 5s window on it flaked under
    // parallel-gate CPU contention — and a generous ceiling alone does
    // not fix it: the boot-time dial can lose a HubIdentity.load race on
    // the shared identity `.tmp` rename, and that swallowed one-shot
    // sync never re-fires on its own. Production heals through the next
    // idle probe, whose channelLister re-drives _syncRuntimeMemberships
    // — so poll through that exact seam until the acceptance lands (the
    // 10s redial throttle bounds the worst healing delay), then assert
    // the acceptance itself.
    final accepted = Completer<void>();
    unawaited(
      resumedJoin.then(
        (_) => accepted.complete(),
        onError: accepted.completeError,
      ),
    );
    await waitForIt(
      () async {
        await HubPluginHost.joinedChannelsFor(plugin!);
        return accepted.isCompleted;
      },
      reason: 'resumed $scope membership to dial its own hub after replay',
      seconds: 45,
    );
    // Long settled by the poll above in healthy runs; kept generous so
    // the ceiling can never be the load bottleneck under parallel gates.
    await accepted.future.timeout(const Duration(seconds: 30));

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
