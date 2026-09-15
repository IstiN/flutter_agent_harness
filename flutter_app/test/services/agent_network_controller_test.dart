// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The app agent's hub membership controller (issue #402): the opt-in join
/// swaps the hub-primary composite over the file fabric; opt-out swaps
/// back; DMs flow through the composite both ways — against the real hub
/// semantics (the harness [LocalHub] on an ephemeral port).
library;

import 'dart:async';

import 'package:fa/services/agent_network_controller.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_test/flutter_test.dart';

Duration testBackoff(int attempt) => const Duration(milliseconds: 5);

Future<void> waitUntil(
  FutureOr<bool> Function() predicate, {
  Duration limit = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(limit);
  while (!await predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $limit');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late LocalHub hub;
  late Uri url;

  setUp(() async {
    hub = LocalHub();
    await hub.start();
    url = hub.url;
  });

  tearDown(() async {
    await hub.stop();
  });

  FileMessagingRepository fileLayer(MemoryExecutionEnv env) =>
      FileMessagingRepository(
        env: env,
        root: '/sessions/--work--/messages',
        homeDir: null,
        decodeSessionCwd: decodeSessionCwd,
      );

  test('enabled store joins: composite carries a hub DM into the agent '
      'inbox; disable swaps back and unregisters', () async {
    final env = MemoryExecutionEnv(cwd: '/app-sandbox');
    final fabric = SwappableMessagingRepository(fileLayer(env));
    final controller = AgentNetworkController(
      env: env,
      fileLayer: fileLayer(env),
      fileFabric: fabric,
      transport: const IoHubTransport(),
      loadIdentity: (_) async => null,
    );
    addTearDown(controller.dispose);
    await controller.start();
    // The UI flow: load, then flip the toggle (the join happens on the
    // toggle, not on a pre-seeded store).
    await controller.store.setConnection(url: url.toString());
    await controller.setEnabled(true);
    await waitUntil(() => controller.state == HubLinkState.connected);
    expect(controller.agentId, isNotNull);

    // A hub peer DMs the app agent: the mail lands in the agent's fabric
    // inbox (the composite — drained by the existing inbox probe).
    final peerRepo = HubMessagingRepository(
      url: url,
      transport: const IoHubTransport(),
      name: 'cli-peer',
      backoff: testBackoff,
    );
    await peerRepo.start();
    addTearDown(peerRepo.dispose);
    await waitUntil(() => peerRepo.isConnected);
    await waitUntil(
      () async =>
          (await peerRepo.directory()).any((e) => e.id == controller.agentId),
    );
    await peerRepo.send(
      AgentMessage(
        id: 'm1',
        fromId: peerRepo.agentId!,
        toId: controller.agentId!,
        text: 'hello app',
        sentAt: '2026-01-01T00:00:01Z',
      ),
    );
    await waitUntil(() async => (await fabric.peek('main')).isNotEmpty);
    final drained = await fabric.drain('main');
    expect(drained.single.text, 'hello app');

    // Outbound: the app DMs the peer through the composite — E2E-encrypted
    // on the hub, decrypted for the peer's inbox.
    await controller.sendDm(peerRepo.agentId!, 'hello cli');
    await waitUntil(
      () async => (await peerRepo.peek(peerRepo.agentId!)).isNotEmpty,
    );
    expect((await peerRepo.drain(peerRepo.agentId!)).single.text, 'hello cli');

    // Opt-out: the link is gone, the fabric answers from the file layer.
    await controller.setEnabled(false);
    expect(controller.state, isNull);
    await controller.sendDm('offline-peer', 'carried by files');
    final file = fileLayer(env);
    expect((await file.peek('offline-peer')).single.text, 'carried by files');
  });

  test('disabled store stays off the hub; boot is fully usable (E4)', () async {
    final env = MemoryExecutionEnv(cwd: '/app-sandbox');
    final fabric = SwappableMessagingRepository(fileLayer(env));
    final controller = AgentNetworkController(
      env: env,
      fileLayer: fileLayer(env),
      fileFabric: fabric,
      transport: const IoHubTransport(),
      loadIdentity: (_) async => null,
    );
    addTearDown(controller.dispose);
    // Even a dead hub URL changes nothing: opt-in is off, so no dialing.
    await controller.store.setConnection(url: 'ws://127.0.0.1:1/ws');
    await controller.start();
    expect(controller.state, isNull);
    expect(controller.agentId, isNull);
    expect(await controller.peers(), isEmpty);
  });
}
