/// AC2 `UT-fallback` + AC6 `E2E-drill` of issue #402: the hub-primary,
/// file-fallback composition (phase 27.1) under a hub kill.
///
/// * AC2: hub down → sends land in the file inbox (fallback); hub back →
///   the queued mail drains exactly once (idempotent by id).
/// * AC6: connect → kill the hub mid-conversation → mail continues via the
///   file fabric → hub restarts → reconnect + flush → zero lost or
///   duplicated messages, per-sender order preserved, offline mailbox
///   mail delivered.
///
/// Both sides run the composition under test — [HubMessagingRepository]
/// (gated transport) over a [FileMessagingRepository] through
/// [FallbackMessagingRepository] — against the fake hub. No real network.
@TestOn('vm')
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

import 'fake_hub.dart';

const timeout = Timeout(Duration(seconds: 60));

Duration testBackoff(int attempt) => const Duration(milliseconds: 5);

/// Transport gate: [allow] = false keeps a dropped link down (deterministic
/// kill — no races against the reconnect timer).
///
/// [portOverride] repoints dials at the live hub's port: every hub in this
/// drill binds `:0` (kernel-assigned), so the replacement hub after a kill
/// lands on a fresh port instead of rebinding the freed one. Rebinding a
/// freed port races the OTHER suites of the shard — a concurrent
/// neighbor's `:0` bind can be handed the just-freed port and hold it for
/// its whole test, failing the restart bind with EADDRINUSE (errno 98;
/// seen twice on CI, ports 41663 and 39459). The repo's dial url is fixed
/// at construction, and this gate is the one test-owned hop on the dial
/// path, so the port rewrite lives here.
class GatedTransport implements HubTransport {
  bool allow = true;
  int? portOverride;

  @override
  Future<HubSocket> connect(Uri url) async {
    if (!allow) throw StateError('gate closed');
    final target = portOverride == null ? url : url.replace(port: portOverride);
    return const IoHubTransport().connect(target);
  }
}

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

/// One composed side: hub primary + file fallback, the app-agent shape.
final class Side {
  Side(this.hub, this.file, this.fabric, this.gate);

  final HubMessagingRepository hub;
  final FileMessagingRepository file;
  final FallbackMessagingRepository fabric;
  final GatedTransport gate;
}

Future<Side> makeSide(Uri hubUrl, {required String name}) async {
  final gate = GatedTransport();
  final hub = HubMessagingRepository(
    url: hubUrl,
    transport: gate,
    name: name,
    backoff: testBackoff,
  );
  final file = FileMessagingRepository(
    env: MemoryExecutionEnv(cwd: '/work'),
    root: '/sessions/--work--/messages',
    homeDir: null,
    decodeSessionCwd: decodeSessionCwd,
  );
  final fabric = FallbackMessagingRepository(primary: hub, fallback: file);
  fabric.primaryMailbox = () => 'main';
  await hub.start();
  await waitUntil(() => hub.isConnected);
  return Side(hub, file, fabric, gate);
}

AgentMessage mail(String id, String to, String text) => AgentMessage(
  id: id,
  fromId: 'main',
  toId: to,
  text: text,
  sentAt: '2026-01-01T00:00:0${id.length % 10}Z',
);

void main() {
  test('AC6 E2E-drill: kill mid-conversation, file carries on, restart '
      'drains with zero loss/dupe and order preserved', () async {
    final hub = FakeHub();
    await hub.start();
    addTearDown(hub.stop);
    final url = hub.url;

    final a = await makeSide(url, name: 'mac-app');
    final b = await makeSide(url, name: 'cli-peer');
    addTearDown(a.hub.dispose);
    addTearDown(b.hub.dispose);
    await waitUntil(() => a.hub.isConnected && b.hub.isConnected);
    final bId = b.hub.agentId!;
    final aId = a.hub.agentId!;

    // --- Phase 1: both live, a normal hub DM round trip ------------------
    await a.fabric.send(mail('M1', bId, 'M1 live'));
    await waitUntil(
      () async => (await b.fabric.peek('main')).any((m) => m.id == 'M1'),
    );
    expect((await b.fabric.drain('main')).single.id, 'M1');

    // --- Phase 2: KILL the hub mid-conversation --------------------------
    // Hold both links down across the restart (deterministic, no races
    // against the 5 ms reconnect timer).
    a.gate.allow = false;
    b.gate.allow = false;
    await hub.stop();
    await waitUntil(() => !a.hub.isConnected && !b.hub.isConnected);

    // Mail continues via the file fabric: sends succeed (file fallback).
    await a.fabric.send(mail('M2', bId, 'M2 queued'));
    await a.fabric.send(mail('M3', bId, 'M3 queued'));
    // The copies sit in A's file inbox (the offline carrier).
    expect((await a.file.peek(bId)).map((m) => m.id), ['M2', 'M3']);

    // --- Phase 3: hub restarts; both sides rejoin ------------------------
    final restarted = FakeHub();
    await restarted.start();
    addTearDown(restarted.stop);
    a.gate.portOverride = restarted.url.port;
    b.gate.portOverride = restarted.url.port;
    a.gate.allow = true;
    b.gate.allow = true;
    await waitUntil(() => a.hub.isConnected && b.hub.isConnected);

    // --- Phase 4: the drain — exactly once, in order, nothing lost -------
    // A's next inbox probe drives the forward flush (the peek shape).
    await a.fabric.peek('main');
    await waitUntil(
      () async =>
          (await b.fabric.peek(
            'main',
          )).where((m) => m.id.startsWith('M')).length >=
          2,
    );
    final drained = await b.fabric.drain('main');
    final forwarded = drained.where((m) => m.id.startsWith('M')).toList();
    expect(forwarded.map((m) => m.id), [
      'M2',
      'M3',
    ], reason: 'order preserved through file carry + forward');
    // Settle: no dupes arrive afterwards.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(
      (await b.fabric.drain('main')).where((m) => m.id.startsWith('M')),
      isEmpty,
    );
    // The file carrier is emptied by the forward (exactly once).
    expect(await a.file.peek(bId), isEmpty);
  });

  test('AC2 UT-fallback: hub down → file inbox; hub back → drains once; '
      'inbound mail sent while suspended flushes on rejoin', () async {
    final hub = FakeHub();
    await hub.start();
    addTearDown(hub.stop);
    final url = hub.url;

    final a = await makeSide(url, name: 'mac-app');
    final b = await makeSide(url, name: 'cli-peer');
    addTearDown(a.hub.dispose);
    addTearDown(b.hub.dispose);
    await waitUntil(() => a.hub.isConnected && b.hub.isConnected);
    final bId = b.hub.agentId!;
    final aId = a.hub.agentId!;

    // Kill: sends land in the file inbox (fallback), nothing throws.
    a.gate.allow = false;
    await hub.stop();
    await waitUntil(() => !a.hub.isConnected && !b.hub.isConnected);
    await a.fabric.send(mail('K1', bId, 'while down'));
    expect((await a.file.peek(bId)).single.id, 'K1');

    // Restart + rejoin: the flush forwards exactly once.
    final restarted = FakeHub();
    await restarted.start();
    addTearDown(restarted.stop);
    a.gate.portOverride = restarted.url.port;
    b.gate.portOverride = restarted.url.port;
    a.gate.allow = true;
    b.gate.allow = true;
    await waitUntil(() => a.hub.isConnected && b.hub.isConnected);
    await a.fabric.peek('main');
    await waitUntil(
      () async => (await b.fabric.peek('main')).any((m) => m.id == 'K1'),
    );
    expect(
      (await b.fabric.drain('main')).where((m) => m.id == 'K1'),
      hasLength(1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      (await b.fabric.drain('main')).where((m) => m.id == 'K1'),
      isEmpty,
      reason: 'idempotent by id across the drain',
    );

    // Inbound direction: B's DM while A is suspended (plain stop → the
    // suspend/resume path) flushes from the hub offline mailbox on rejoin.
    await a.hub.stop();
    await waitUntil(() => !a.hub.isConnected);
    await b.fabric.send(mail('S1', aId, 'while suspended'));
    await a.hub.start();
    await waitUntil(() => a.hub.isConnected);
    await waitUntil(
      () async => (await a.fabric.peek('main')).any((m) => m.id == 'S1'),
    );
    expect((await a.fabric.drain('main')).single.id, 'S1');
  });
}
