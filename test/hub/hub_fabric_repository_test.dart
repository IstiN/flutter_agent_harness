import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:fa_hub_client/fa_hub_client.dart'
    hide AgentMessage, MailboxEntry;
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    hide HubIdentity, PluginContext;
import 'package:flutter_agent_harness/io.dart' show LocalHub;
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

  /// A plugin started against [hub], the adapter over it. [rosterWarmup]
  /// overrides the adapter's warm-up window (default: the production 5s)
  /// so tests can settle the roster without waiting it out in real time.
  Future<(HubFabricRepository, HubPlugin)> newFabric({
    Duration? rosterWarmup,
  }) async {
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
    return (
      HubFabricRepository(
        plugin,
        rosterWarmup: rosterWarmup ?? hubRosterWarmup,
      ),
      plugin,
    );
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

  test('PUBLIC channel: fabric sends the raw base64({"text":…}) contract, '
      'keyless members decode it, and #channel inboxes drain', () async {
    final (adapter, plugin) = await newFabric();
    final fabric = HubFabricRepository(
      plugin,
      publicChannelChecker: (_, channel) async => channel == 'room',
      channelLister: (_) async => ['room'],
    );
    // Keyless joins on both ends (the public showcase membership).
    plugin.repository!.client.join('room', '');
    sender.join('room', '');

    // Fabric → sender: the payload is the public contract, decoded by
    // a keyless client (no "undecryptable" placeholder).
    final arrived = sender.inbound
        .firstWhere((m) => m.channel == 'room')
        .timeout(const Duration(seconds: 5));
    await fabric.send(
      AgentMessage(
        id: 'pub1',
        fromId: 'main',
        toId: '#room',
        text: 'hello public',
        sentAt: DateTime.now().toUtc().toIso8601String(),
      ),
    );
    expect((await arrived).plaintext, 'hello public');

    // Sender → fabric: the #room inbox is drained ALONGSIDE the agent
    // inbox (drain(agentId) alone drops channel traffic).
    final received = plugin.repository!.client.inbound
        .firstWhere((m) => m.channel == 'room')
        .timeout(const Duration(seconds: 5));
    await sender.sendChannelEnvelope(
      'room',
      (frameId) async => encodePublicChannelText('back at you'),
    );
    await received;
    final drained = await fabric.drain('main');
    expect(drained, hasLength(1));
    expect(drained.single.toId, '#room');
    expect(drained.single.text, 'back at you');
    expect(drained.single.fromId, sender.agentId);
  }, timeout: timeout);

  test('a private channel with an UNRESOLVED key refuses loudly instead '
      'of downgrading to plaintext or auto-keygen (gh-1888 review)', () async {
    final (adapter, plugin) = await newFabric();
    final fabric = HubFabricRepository(
      plugin,
      privateKeyMissingChecker: (_, channel) async => channel == 'locked',
    );
    await expectLater(
      fabric.send(
        AgentMessage(
          id: 'blk1',
          fromId: 'main',
          toId: '#locked',
          text: 'secret payload',
          sentAt: DateTime.now().toUtc().toIso8601String(),
        ),
      ),
      throwsA(
        isA<ChannelDeliveryException>().having(
          (e) => e.message,
          'message',
          allOf(contains('refusing to send to #locked'), contains('key')),
        ),
      ),
    );
    // Nothing reached the wire.
    await expectLater(
      sender.inbound
          .firstWhere((m) => m.channel == 'locked')
          .timeout(const Duration(milliseconds: 300)),
      throwsA(anything),
    );
  }, timeout: timeout);

  test('PRIVATE channel: fabric sends a fanet1 frame, not RAW dap/1', () async {
    final (adapter, plugin) = await newFabric();
    const channel = 'private-room';
    final keys = await newChannelKeypair();
    final client = plugin.repository!.client;
    await client.channelStore!.accept(channel, keys);
    client.join(channel, keys.pub);
    sender.join(channel, keys.pub);

    final arrived = sender.inbound
        .firstWhere((message) => message.channel == channel)
        .timeout(const Duration(seconds: 5));
    await adapter.send(
      AgentMessage(
        id: 'private1',
        fromId: 'main',
        toId: '#$channel',
        text: 'hello private',
        sentAt: DateTime.now().toUtc().toIso8601String(),
      ),
    );
    await arrived;

    final wire = hub.relayed.single;
    final payload = base64Decode(wire['ciphertext'] as String);
    expect(payload.first, fanet1FrameVersion);
    expect(payload.sublist(1, 33), client.identity.dhPublicKey.bytes);
    expect(
      payload.length,
      1 + 32 + 12 + 16 + utf8.encode('hello private').length,
    );
    final opened = await openFanet1(
      channelKeyPair: await X25519().newKeyPairFromSeed(
        base64Decode(keys.priv),
      ),
      frameId: wire['id'] as String,
      channelId: channel,
      payloadB64: wire['ciphertext'] as String,
    );
    expect(opened.plaintext, 'hello private');
  }, timeout: timeout);

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

  test('directory falls back to empty when the hub drops mid-query', () async {
    final (adapter, plugin) = await newFabric();
    expect(plugin.agentId, isNotNull);
    // Simulate the hub being gone: presenceQuery's waiter is failed with
    // StateError('connection closed') — the directory must degrade to an
    // empty roster (the composite falls back to the file fabric), never
    // throw into a background poller.
    await hub.stop();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(await adapter.directory(), isEmpty);
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

  test('rosterSettled: our re-welcome after a hub restart gates the warm-up '
      'window (gh-2471)', () async {
    final (adapter, plugin) = await newFabric(
      rosterWarmup: const Duration(milliseconds: 300),
    );
    // Pre-restart: the peer is registered, our client is welcomed.
    expect(await adapter.resolveTarget(sender.agentId!), sender.agentId);

    // The hub dies (kill -9 shape: no graceful stop) and revives on the
    // same port. Both clients auto-reconnect on their own backoff.
    final port = hub.url.port;
    await hub.stop();
    final revived = LocalHub(port: port);
    await _startHubWithRetry(revived);
    addTearDown(revived.stop);

    // OUR client re-welcomes first — the restart witness.
    await _waitFor(() => adapter.isConnected);
    // The roster was just reset: misses are not ownership evidence yet.
    expect(
      adapter.rosterSettled,
      isFalse,
      reason: 'freshly re-welcomed — the roster cannot confirm a miss',
    );
    // A genuinely absent peer still resolves null (the query contract is
    // unchanged); only the COMPOSITION'S untrack is gated on settledness.
    expect(await adapter.resolveTarget('ghost-peer'), isNull);

    // A HIT answers fine even while unsettled: the sender re-hellos and
    // resolves immediately — forwarding must never wait out the warm-up.
    await _waitFor(() => sender.connected);
    await revived.waitForHellos(2);
    expect(await adapter.resolveTarget(sender.agentId!), sender.agentId);

    // After the warm-up window the roster is settled: misses become
    // conclusive ownership evidence again (the collision guard).
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(adapter.rosterSettled, isTrue);
    expect(await adapter.resolveTarget('ghost-peer'), isNull);
  }, timeout: timeout);
}

/// Bounded bind-retry for a hub reviving its old port (#948 shape: the
/// freed ephemeral port can be re-grabbed for a few ms by a concurrent
/// bind(0); LocalHub.start is a deliberately loud plain bind). Only rides
/// out "address already in use".
Future<void> _startHubWithRetry(LocalHub hub) async {
  final deadline = DateTime.now().add(const Duration(seconds: 6));
  var attempt = 0;
  while (true) {
    try {
      await hub.start();
      return;
    } on SocketException catch (e) {
      final inUse =
          e.osError?.errorCode == 98 ||
          e.osError?.errorCode == 48 /* macOS EADDRINUSE */ ||
          e.osError?.errorCode == 10048 /* Windows */;
      if (!inUse || attempt >= 8 || DateTime.now().isAfter(deadline)) {
        rethrow;
      }
      await Future<void>.delayed(
        Duration(
          milliseconds: 150 * (1 << attempt) > 1200
              ? 1200
              : 150 * (1 << attempt),
        ),
      );
      attempt++;
    }
  }
}

/// Short poll loop (bounded at ~5s) for cross-socket readiness.
Future<void> _waitFor(bool Function() probe) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    if (probe()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('condition not reached within 5s');
}
