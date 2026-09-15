/// ACs of issue #402 for the hub-backed messaging repository (phase 27.1).
///
/// * AC1 `UT-hub-repo`: register → send → receive → dedup by id →
///   per-sender order; queue while disconnected → drain on reconnect in
///   order, no dupes.
/// * AC4 `IT-ios-lan` (token half): a protected hub with the pairing token
///   accepts the join; a wrong or absent token is a clean reject — the
///   repository never becomes connected, never registers.
/// * AC7 `UT-presence`: busy (run in progress) still accepts mail, and the
///   directory reports busy instead of offline while the run streams.
/// * AC5 `UT-pure-core` lives in the purity suite: this repository imports
///   no `dart:io` — the transport is a constructor seam (the fake below),
///   so `lib/` compiles for web with the hub repo present.
///
/// Everything runs against the fake hub (`FakeHub` = the production
/// `LocalHub` on an ephemeral port) — never a real network.
library;

import 'dart:async';
import 'dart:convert';

import 'package:fa_hub_client/fa_hub_client.dart' as peer;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

import 'fake_hub.dart';

const timeout = Timeout(Duration(seconds: 30));

/// Instant backoff for tests: reconnects happen on the next timer tick
/// rather than the 1 s default schedule.
Duration testBackoff(int attempt) => const Duration(milliseconds: 5);

/// Transport with a reconnect gate: [allow] = false makes every dial throw,
/// so a drop STAYS a drop until the test reopens the gate (deterministic
/// queue-while-disconnected — no races against the 5 ms backoff).
class GatedTransport implements HubTransport {
  bool allow = true;
  int dials = 0;

  @override
  Future<HubSocket> connect(Uri url) async {
    dials++;
    if (!allow) throw StateError('gate closed');
    return const IoHubTransport().connect(url);
  }
}

/// Builds a repository joined to [hub] with a fresh identity.
Future<HubMessagingRepository> joinedRepo(
  FakeHub hub, {
  String? name,
  HubTransport? transport,
  HubIdentity? identity,
  String? token,
  void Function(String)? onLog,
}) async {
  final repo = HubMessagingRepository(
    url: hub.url,
    transport: transport ?? const IoHubTransport(),
    identity: identity,
    name: name,
    token: token,
    backoff: testBackoff,
    onLog: onLog,
  );
  await repo.start();
  return repo;
}

/// Waits until [predicate] holds, polling the event loop.
Future<void> waitUntil(
  FutureOr<bool> Function() predicate, {
  Duration limit = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(limit);
  while (!await predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $limit');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// A CLI-style peer speaking the same wire (the interop check for the
/// crypto stack: our repo must decrypt its DMs and vice versa).
Future<peer.HubClient> cliPeer(FakeHub hub) async {
  final client = peer.HubClient(
    config: peer.HubConfig(url: hub.url.toString()),
    identity: await peer.HubIdentity.generate(),
  );
  await client.connect();
  return client;
}

void main() {
  late FakeHub hub;

  setUp(() async {
    hub = FakeHub();
    await hub.start();
  });

  tearDown(() async {
    await hub.stop();
  });

  group('AC1 UT-hub-repo', () {
    test('register → send → receive round trip with a CLI peer', () async {
      final repo = await joinedRepo(hub, name: 'mac-app-agent');
      final sender = await cliPeer(hub);
      addTearDown(sender.disconnect);
      addTearDown(repo.dispose);

      await waitUntil(() => repo.isConnected);
      // The hello published the display name: the peer resolves it.
      final roster = await sender.peers();
      expect(
        roster.any((agent) => agent.name == 'mac-app-agent'),
        isTrue,
        reason: 'register publishes the session name on the roster',
      );

      // Inbound: the CLI peer DMs our address; the repo decrypts it.
      await sender.sendDm(repo.agentId!, 'hello from the cli');
      List<AgentMessage> got = const [];
      await waitUntil(() async {
        got = await repo.peek('main');
        return got.isNotEmpty;
      });
      expect(got.single.text, 'hello from the cli');
      expect(got.single.fromId, sender.agentId);
      expect((await repo.drain('main')), hasLength(1));
      expect(await repo.drain('main'), isEmpty);

      // Outbound: the repo DMs the peer's hub id; the peer decrypts it.
      final arrived = sender.inbound
          .firstWhere((m) => m.plaintext == 'hello from the app')
          .timeout(const Duration(seconds: 10));
      await repo.send(
        AgentMessage(
          id: 'm1',
          fromId: 'main',
          toId: sender.agentId!,
          text: 'hello from the app',
          sentAt: DateTime.now().toUtc().toIso8601String(),
        ),
      );
      await arrived;
    });

    test('resolveTarget: exact id resolves; unknown names fall through',
        () async {
      final repo = await joinedRepo(hub, name: 'goal_builder');
      final sender = await cliPeer(hub);
      addTearDown(sender.disconnect);
      addTearDown(repo.dispose);
      await waitUntil(() => repo.isConnected);

      expect(await repo.resolveTarget(sender.agentId!), sender.agentId);
      // Our own name is our own fabric mailbox, not a target.
      expect(await repo.resolveTarget('goal_builder'), isNull);
      // An unknown name resolves to nothing (falls through to the file
      // fabric in the composition).
      expect(await repo.resolveTarget('no-such-name'), isNull);
    });

    test('queue while disconnected → drain on reconnect in order, no dupes',
        () async {
      final gate = GatedTransport();
      final repo = await joinedRepo(hub, transport: gate);
      final sender = await cliPeer(hub);
      addTearDown(sender.disconnect);
      addTearDown(repo.dispose);
      await waitUntil(() => repo.isConnected);
      final target = sender.agentId!;

      // Pull the plug and HOLD it (gate closed): the drop stays a drop.
      gate.allow = false;
      await hub.closeAgent(repo.agentId!);
      await waitUntil(() => !repo.isConnected);
      final dialsBefore = gate.dials;
      AgentMessage mail(String id) => AgentMessage(
        id: id,
        fromId: 'main',
        toId: target,
        text: 'queued $id',
        sentAt: DateTime.now().toUtc().toIso8601String(),
      );
      await repo.send(mail('q1'));
      await repo.send(mail('q2'));
      await repo.send(mail('q3'));
      expect(repo.isConnected, isFalse);

      // Reopen the gate: the reconnect drain delivers all three, in send
      // order, once.
      final received = <String>[];
      final sub = sender.inbound.listen((m) {
        if (m.plaintext != null) received.add(m.plaintext!);
      });
      addTearDown(sub.cancel);
      gate.allow = true;
      await waitUntil(
        () => received.length >= 3,
      );
      expect(
        received.take(3).map((t) => t.split(' ').last),
        ['q1', 'q2', 'q3'],
        reason: 'per-sender order survives the queue',
      );
      // No dupes: let the loop settle, the count stays at three.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        received.where((t) => t.startsWith('queued ')),
        hasLength(3),
      );
      expect(gate.dials, greaterThan(dialsBefore));
    });

    test('inbound dedup by frame id: a redelivered frame lands once',
        () async {
      final repo = await joinedRepo(hub);
      final sender = await cliPeer(hub);
      addTearDown(sender.disconnect);
      addTearDown(repo.dispose);
      await waitUntil(() => repo.isConnected);

      await sender.sendDm(repo.agentId!, 'once only');
      await waitUntil(() async {
        final peeked = await repo.peek('main');
        return peeked.isNotEmpty;
      });
      final delivered = await repo.drain('main');
      expect(delivered, hasLength(1));

      // Re-push the SAME wire frame through the hub (same frame id) — the
      // at-least-once redelivery shape. It must collapse.
      final relayed = hub.relayed.last;
      hub.pushMsg(repo.agentId!, {
        'from': sender.agentId,
        'id': relayed['id'],
        'ts': relayed['ts'],
        'ciphertext': relayed['ciphertext'],
      });
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(await repo.peek('main'), isEmpty, reason: 'dedup by id');
    });
  });

  group('AC4 IT-ios-lan (token auth)', () {
    Future<(FakeHub, HubMessagingRepository)> joinProtected(
      String? token,
    ) async {
      final protected = FakeHub(masterSecret: 'pairing-token');
      await protected.start();
      addTearDown(protected.stop);
      final repo = await joinedRepo(protected, token: token);
      addTearDown(repo.dispose);
      return (protected, repo);
    }

    test('the pairing token joins the protected hub', () async {
      final (protected, repo) = await joinProtected('pairing-token');
      await waitUntil(() => repo.isConnected);
      expect(repo.agentId, isNotNull);
      expect(protected.agentIds, contains(repo.agentId));
    });

    test('wrong token: clean reject, no register, no welcome', () async {
      final (protected, repo) = await joinProtected('wrong-token');
      // Never connects; never registers (the roster stays empty).
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(repo.isConnected, isFalse);
      expect(protected.agentIds, isEmpty);
      expect(protected.hellosSeen, 0);
    });

    test('absent token: same clean reject', () async {
      final (protected, repo) = await joinProtected(null);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(repo.isConnected, isFalse);
      expect(protected.agentIds, isEmpty);
    });
  });

  group('AC7 UT-presence', () {
    test('busy accepts mail; directory reports busy for self, live for peers',
        () async {
      final gate = GatedTransport();
      final repo = await joinedRepo(hub, name: 'busy-agent', transport: gate);
      final sender = await cliPeer(hub);
      addTearDown(sender.disconnect);
      addTearDown(repo.dispose);
      await waitUntil(() => repo.isConnected);

      // A run starts: busy. Mail still lands (steering semantics).
      await repo.touch('main', busy: true);
      await sender.sendDm(repo.agentId!, 'steer the busy turn');
      var got = <AgentMessage>[];
      await waitUntil(() async {
        got = await repo.peek('main');
        return got.isNotEmpty;
      });
      expect(got.single.text, 'steer the busy turn');

      final directory = await repo.directory();
      final me = directory.singleWhere((e) => e.id == repo.agentId);
      expect(me.presence, AgentPresence.busy);
      expect(me.source, mailboxSourceHub);

      // The peer shows live (connection-backed presence, not mtime).
      final peerEntry = directory.singleWhere((e) => e.id == sender.agentId);
      expect(peerEntry.presence, AgentPresence.live);

      // Run ends → back to live (connected), never offline.
      await repo.touch('main');
      expect(
        (await repo.directory()).singleWhere((e) => e.id == repo.agentId)
            .presence,
        AgentPresence.live,
      );

      // The link drops and STAYS down → the disconnected directory view:
      // the roster as of last contact, everyone offline.
      gate.allow = false;
      await hub.closeAgent(repo.agentId!);
      await waitUntil(() => !repo.isConnected);
      final entry = (await repo.directory()).singleWhere(
        (e) => e.id == repo.agentId,
      );
      expect(entry.presence, AgentPresence.offline);
    });
  });

  group('link lifecycle', () {
    test('E4: an unreachable hub boots disconnected and keeps retrying',
        () async {
      // Port 1 on loopback: nothing listens, connects refuse instantly.
      final repo = HubMessagingRepository(
        url: Uri.parse('ws://127.0.0.1:1/ws'),
        transport: const IoHubTransport(),
        backoff: testBackoff,
      );
      addTearDown(repo.dispose);
      await repo.start();
      // The boot never throws; the state is honest.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(repo.isConnected, isFalse);
      expect(
        repo.state,
        anyOf(HubLinkState.disconnected, HubLinkState.connecting),
      );
      // Queueing works — nothing throws.
      await repo.send(AgentMessage(
        id: 'q',
        fromId: 'main',
        toId: 'nobody',
        text: 'later',
        sentAt: DateTime.now().toUtc().toIso8601String(),
      ));
    });

    test('stop → start: clean disconnect, reconnect drains the hub mailbox',
        () async {
      final repo = await joinedRepo(hub);
      final sender = await cliPeer(hub);
      addTearDown(sender.disconnect);
      addTearDown(repo.dispose);
      await waitUntil(() => repo.isConnected);

      // Offline mail: the peer sends while we are cleanly stopped; the hub
      // parks it in the offline mailbox and flushes on reconnect.
      await repo.stop();
      expect(repo.isConnected, isFalse);
      await sender.sendDm(repo.agentId!, 'while suspended');
      await repo.start();
      await waitUntil(() => repo.isConnected);
      var text = '';
      await waitUntil(() async {
        text = (await repo.peek('main')).map((m) => m.text).join('|');
        return text == 'while suspended';
      });
    });
  });

  test('AC4 IT-ios-lan (host half): --bind lan listens on all interfaces', () async {
    final lan = FakeHub(bind: 'lan');
    await lan.start();
    addTearDown(lan.stop);
    // 0.0.0.0 covers loopback: the ordinary client path still works.
    final repo = HubMessagingRepository(
      url: lan.url,
      transport: const IoHubTransport(),
      name: 'loopback-client-of-lan-hub',
      backoff: testBackoff,
    );
    await repo.start();
    addTearDown(repo.dispose);
    await waitUntil(() => repo.isConnected);
    expect(repo.agentId, isNotNull);
  });

  group('identity', () {
    test('a passed identity is stable across restarts', () async {
      final seeds = utf8.encode('0123456789abcdef0123456789abcdef');
      final identity = await HubIdentity.fromSeeds(
        ed25519Seed: seeds,
        x25519Private: seeds,
      );
      Future<HubMessagingRepository> make() async {
        final repo = HubMessagingRepository(
          url: hub.url,
          transport: const IoHubTransport(),
          identity: identity,
          backoff: testBackoff,
        );
        await repo.start();
        return repo;
      }

      final first = await make();
      await waitUntil(() => first.isConnected);
      final address = first.agentId;
      await first.dispose();

      final second = await make();
      addTearDown(second.dispose);
      await waitUntil(() => second.isConnected);
      expect(second.agentId, address, reason: 'seeds → same hub address');
    });
  });
}
