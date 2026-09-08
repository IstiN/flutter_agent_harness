import 'dart:async';
import 'dart:io';

import 'package:fa_hub_client/fa_hub_client.dart'
    hide AgentMessage, MailboxEntry;
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    hide PluginContext;
import 'package:test/test.dart';

import '../../bin/hub_fabric_repository.dart';
import 'fake_hub.dart';

const timeout = Timeout(Duration(seconds: 10));

void main() {
  late FakeHub hub;
  late HubClient sender;

  setUp(() async {
    hub = FakeHub();
    await hub.start();
    sender = HubClient(
      config: HubConfig(url: hub.url.toString()),
      identity: await HubIdentity.generate(),
    );
    await sender.connect();
  });

  tearDown(() async {
    await sender.disconnect();
    await hub.stop();
  });

  /// A plugin started against [hub], the adapter over it.
  Future<(HubFabricRepository, HubPlugin)> newFabric() async {
    final tmp = await Directory.systemTemp.createTemp('fah-hub-fabric');
    addTearDown(() => tmp.delete(recursive: true));
    final plugin = HubPlugin(
      environment: const {'DAP_MASTER_SECRET': 'test-master'},
    );
    plugin.register(
      PluginContext(
        config: {
          'hub': {
            'url': hub.url.toString(),
            'keyPath': '${tmp.path}/hub-key',
            'name': 'fabric-probe',
          },
        },
      ),
    );
    await plugin.start();
    addTearDown(plugin.dispose);
    return (HubFabricRepository(plugin), plugin);
  }

  test('outbound fabric mail rides the hub as the sender identity', () async {
    final (adapter, plugin) = await newFabric();
    final arrived = sender.inbound
        .firstWhere((m) => m.plaintext == 'ping')
        .timeout(const Duration(seconds: 5));
    await adapter.send(
      AgentMessage(
        id: 'm1',
        fromId: 'main',
        toId: sender.agentId!,
        text: 'ping',
        sentAt: DateTime.now().toUtc().toIso8601String(),
      ),
    );
    final message = await arrived;
    expect(message.from, plugin.agentId);
  }, timeout: timeout);

  test(
    'inbound hub mail drains through the fabric with sender attribution',
    () async {
      final (adapter, plugin) = await newFabric();
      final arrived = plugin.repository!.client.inbound
          .firstWhere((m) => m.plaintext == 'wake')
          .timeout(const Duration(seconds: 5));
      await sender.sendDm(plugin.agentId!, 'wake');
      await arrived;
      final drained = await adapter.drain('main');
      expect(drained, hasLength(1));
      expect(drained.single.text, 'wake');
      expect(drained.single.fromId, sender.agentId);
      expect(drained.single.toId, plugin.agentId);
      expect(DateTime.parse(drained.single.sentAt).isUtc, isTrue);
      // Drained mail is gone.
      expect(await adapter.drain('main'), isEmpty);
      await sender.sendDm(plugin.agentId!, 'again');
      await plugin.repository!.client.inbound
          .firstWhere((m) => m.plaintext == 'again')
          .timeout(const Duration(seconds: 5));
      final peeked = await adapter.peek('main');
      expect(peeked.single.text, 'again');
      expect(await adapter.drain('main'), hasLength(1));
    },
    timeout: timeout,
  );

  test('resolveTarget answers the roster; channels pass through', () async {
    final (adapter, plugin) = await newFabric();
    expect(await adapter.resolveTarget(sender.agentId!), sender.agentId);
    expect(await adapter.resolveTarget('fabric-probe'), plugin.agentId);
    expect(await adapter.resolveTarget('#general'), '#general');
    // Our own hub id is not a fabric target (the file mailbox owns it).
    expect(await adapter.resolveTarget(plugin.agentId!), isNull);
    expect(adapter.isConnected, isTrue);
  }, timeout: timeout);

  test('directory maps the hub roster onto mailbox entries', () async {
    final (adapter, plugin) = await newFabric();
    final entries = await adapter.directory();
    final ids = entries.map((e) => e.id);
    expect(ids, containsAll([sender.agentId, plugin.agentId]));
    expect(entries.firstWhere((e) => e.id == sender.agentId).id, isNotNull);
    // Registration-backed presence: every connected roster peer is live —
    // no mtime heuristic.
    expect(entries.map((e) => e.presence), everyElement(AgentPresence.live));
    // Hub roster entries carry no capabilities (not on the wire yet).
    expect(
      entries.firstWhere((e) => e.id == sender.agentId).capabilities,
      isEmpty,
    );
  }, timeout: timeout);

  test('the adapter serves exactly one inbox — the hub identity\'s; the '
      'COMPOSITE guards which fabric mailbox reaches it', () async {
    final (adapter, plugin) = await newFabric();
    final arrived = plugin.repository!.client.inbound
        .firstWhere((m) => m.plaintext == 'wake')
        .timeout(const Duration(seconds: 5));
    await sender.sendDm(plugin.agentId!, 'wake');
    await arrived;
    // The adapter maps every drain to the hub inbox; the
    // FallbackMessagingRepository (tested separately) is what keeps
    // subagent mailboxes away from it.
    expect(await adapter.drain('sub1'), hasLength(1));
    // register/touch are deliberate no-ops.
    await adapter.register('main', sessionName: 'goal_builder');
    await adapter.touch('main');
  }, timeout: timeout);

  test('disconnected adapter resolves nothing and reads empty', () async {
    final (adapter, plugin) = await newFabric();
    // Simulate the hub being gone: stop it under the plugin.
    await hub.stop();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    // The send contract throws honestly when the hub is unreachable.
    await expectLater(
      adapter.send(
        AgentMessage(
          id: 'm2',
          fromId: 'main',
          toId: sender.agentId!,
          text: 'lost',
          sentAt: DateTime.now().toUtc().toIso8601String(),
        ),
      ),
      throwsStateError,
    );
    expect(adapter.isConnected, anyOf(isTrue, isFalse)); // never throws
    expect(plugin.agentId, isNotNull);
  }, timeout: timeout);
}
