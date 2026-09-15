/// IT for hub peers as first-class inbox agents over the REAL transport
/// (issue #304 AC2/AC4, E2, E5): the composite fabric
/// ([FallbackMessagingRepository] around [HubFabricRepository] over a
/// live [FakeHub]) with a second real `fa_hub_client` instance playing
/// the browser extension. Covers the directory merge with the hub marker,
/// the DM round-trip in both directions, at-least-once + dedup with a
/// duplicated-delivery fake, and the hub-down file fallback with
/// forward-on-restart (27.1).
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:fa_hub_client/fa_hub_client.dart'
    hide AgentMessage, MailboxEntry, MessagingRepository;
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    hide HubIdentity, PluginContext;
import 'package:flutter_agent_harness/io.dart' show LocalHub;
import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:flutter_agent_harness/src/messaging/agent_fabric.dart';
import 'package:flutter_agent_harness/src/messaging/file_messaging_repository.dart';
import 'package:flutter_agent_harness/src/session/session_repo.dart'
    show decodeSessionCwd;
import 'package:flutter_agent_harness/src/task/subagent_manager.dart';
import 'package:flutter_agent_harness/src/task/subagent_tools.dart';
import 'package:test/test.dart';

import '../../bin/hub_fabric_repository.dart';
import 'fake_hub.dart';

const timeout = Timeout(Duration(seconds: 20));

void main() {
  late FakeHub hub;
  late HubPlugin plugin;
  late HubClient browser;
  late FallbackMessagingRepository fabric;
  late SwappableMessagingRepository fileFabric;

  setUp(() async {
    hub = FakeHub();
    await hub.start();

    final tmp = await Directory.systemTemp.createTemp('fah-dap-fabric-');
    addTearDown(() => tmp.delete(recursive: true));

    plugin = HubPlugin(environment: const {'DAP_MASTER_SECRET': 't'});
    plugin.register(
      PluginContext(
        config: {
          'hub': {
            'url': hub.url.toString(),
            'keyPath': '${tmp.path}/host-key',
            'name': 'fabric-host',
          },
        },
      ),
    );
    await plugin.start();
    addTearDown(plugin.dispose);

    browser = HubClient(
      config: HubConfig(url: hub.url.toString(), name: 'Browser'),
      identity: await HubIdentity.generate(),
    );
    await browser.connect();
    addTearDown(browser.disconnect);

    fileFabric = SwappableMessagingRepository(
      FileMessagingRepository(
        env: MemoryExecutionEnv(cwd: '/work'),
        root: '/sessions/--work--/messages',
        decodeSessionCwd: decodeSessionCwd,
      ),
    );
    fabric = FallbackMessagingRepository(
      primary: HubFabricRepository(plugin),
      fallback: fileFabric,
    )..primaryMailbox = () => 'sess1/main';
  });

  tearDown(() async {
    await browser.disconnect();
    await plugin.dispose();
    try {
      await hub.stop();
    } on Object {
      // already stopped by a test (the restart scenario)
    }
  });

  /// Renders `agent_directory` over [fabric] — the exact tool body the
  /// agent sees.
  Future<String> renderDirectory() async {
    final manager = SubagentManager(parentSessionId: 'p', messaging: fabric)
      ..mailboxPrefix = 'sess1';
    final tools = subagentMonitoringTools(manager: manager);
    final directory = tools.firstWhere((t) => t.name == 'agent_directory');
    final result = await directory.execute(const {}, null, null);
    return (result.content.first as dynamic).text as String;
  }

  AgentMessage mail(
    String to,
    String text, {
    String from = 'sess1/main',
    String? id,
  }) => AgentMessage(
    id: id ?? 'm-${DateTime.now().microsecondsSinceEpoch}',
    fromId: from,
    toId: to,
    text: text,
    sentAt: DateTime.now().toUtc().toIso8601String(),
  );

  test(
    'IT-directory: hub peers merge with name, presence and [hub] marker',
    () async {
      final entries = await fabric.directory();
      final browserEntry = entries.firstWhere((e) => e.id == browser.agentId);
      expect(browserEntry.name, 'Browser');
      expect(browserEntry.presence, AgentPresence.live);
      expect(browserEntry.source, mailboxSourceHub);
      // File entries carry no marker (REG-legacy).
      final rendered = await renderDirectory();
      expect(rendered, contains('Browser ('));
      expect(rendered, contains('[hub]'));
    },
    timeout: timeout,
  );

  test('IT-roundtrip: agent_message-shaped send by NAME rides sendDm; the '
      'reply lands in the sender inbox at the drain boundary (E5)', () async {
    final arrived = browser.inbound
        .firstWhere((m) => m.plaintext == 'ping via fabric')
        .timeout(const Duration(seconds: 5));
    await fabric.send(mail('Browser', 'ping via fabric'));
    final inbound = await arrived;
    expect(inbound.from, plugin.agentId);

    // The extension replies with a DM.
    await browser.sendDm(plugin.agentId!, 'pong from browser');
    await plugin.repository!.client.inbound
        .firstWhere((m) => m.plaintext == 'pong from browser')
        .timeout(const Duration(seconds: 5));

    // Delivered at the step boundary: the main-mailbox drain (what the
    // steering loop runs between turns) sees it, attributed to the
    // sender — and consumption is once.
    final drained = await fabric.drain('sess1/main');
    expect(drained.map((m) => m.text), contains('pong from browser'));
    final pong = drained.firstWhere((m) => m.text == 'pong from browser');
    expect(pong.fromId, browser.agentId);
    expect(
      await fabric.drain('sess1/main'),
      isEmpty,
      reason: 'drained mail is consumed exactly once',
    );
  }, timeout: timeout);

  test('IT-dedup: a duplicated-delivery primary yields exactly one message '
      '(at-least-once + dedup by id and by sender|ts|body)', () async {
    // The hub wire assigns a FRESH id per delivered frame; a re-wrap or
    // redelivery therefore re-enters the drain under a new id. Wrap the
    // real primary so every hub frame is delivered TWICE: once verbatim
    // and once re-wrapped (fresh id, same sender/ts/body).
    final duplicating = _DuplicatingPrimary(HubFabricRepository(plugin));
    final composite = FallbackMessagingRepository(
      primary: duplicating,
      fallback: fileFabric,
    )..primaryMailbox = () => 'sess1/main';

    await browser.sendDm(plugin.agentId!, 'only once please');
    await plugin.repository!.client.inbound
        .firstWhere((m) => m.plaintext == 'only once please')
        .timeout(const Duration(seconds: 5));

    final drained = await composite.drain('sess1/main');
    final copies = drained.where((m) => m.text == 'only once please').toList();
    expect(
      copies,
      hasLength(1),
      reason: 'a re-wrapped duplicate collapses onto one delivery',
    );
    expect(copies.single.fromId, browser.agentId);
  }, timeout: timeout);

  test('IT-fallback: hub down — mail to a hub peer queues in the file inbox '
      '(no throw), directory degrades, and a hub restart forwards the queue '
      'exactly once (AC2, E2)', () async {
    final peerId = browser.agentId!;
    final port = hub.url.port; // capture before the hub dies
    // The hub dies mid-session (kill -9 shape: no graceful stop).
    await hub.stop();

    // The directory degrades to the file-only view — never throws.
    final entries = await fabric.directory();
    expect(entries.any((e) => e.id == peerId), isFalse);

    // Sending to the hub peer takes the honest fallback: no throw, the
    // mail is queued in the file inbox.
    await fabric.send(mail(peerId, 'queued while offline'));
    expect(
      (await fileFabric.peek(peerId)).map((m) => m.text),
      contains('queued while offline'),
    );

    // A later start: a hub comes back on the same port, both clients
    // reconnect, and the queued mail is forwarded on the next fabric
    // call (the 2s inbox probe in production).
    final revived = LocalHub(port: port);
    await revived.start();
    addTearDown(revived.stop);
    await _waitFor(() => fabric.isConnected);
    await _waitFor(() => browser.connected);
    final arrived = browser.inbound
        .firstWhere((m) => m.plaintext == 'queued while offline')
        .timeout(const Duration(seconds: 5));
    await fabric.drain('sess1/main'); // triggers the flush
    await arrived;

    // The file copy is gone — a file-polling peer never sees it twice.
    expect(await fileFabric.peek(peerId), isEmpty);
  }, timeout: timeout);
}

/// Waits for [probe] with a short poll loop (bounded at ~5s).
Future<void> _waitFor(bool Function() probe) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    if (probe()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('condition not reached within 5s');
}

/// A primary that doubles every hub delivery: the verbatim frame plus a
/// re-wrapped copy (fresh id, same sender+ts+body) — the duplicated-
/// delivery fake for the at-least-once dedup proof.
final class _DuplicatingPrimary
    implements MessagingRepository, RoutingMessagingRepository {
  _DuplicatingPrimary(this._inner);

  final HubFabricRepository _inner;
  int _rewrapSeq = 0;

  @override
  bool get isConnected => _inner.isConnected;

  @override
  Future<String?> resolveTarget(String toId) => _inner.resolveTarget(toId);

  @override
  Future<void> send(AgentMessage message) => _inner.send(message);

  @override
  Future<List<AgentMessage>> peek(String agentId) async =>
      _dup(await _inner.peek(agentId));

  @override
  Future<List<AgentMessage>> drain(String agentId) async =>
      _dup(await _inner.drain(agentId));

  List<AgentMessage> _dup(List<AgentMessage> messages) => [
    for (final message in messages) ...[
      message,
      AgentMessage(
        id: 'rewrap-${_rewrapSeq++}',
        fromId: message.fromId,
        toId: message.toId,
        text: message.text,
        sentAt: message.sentAt,
        hops: message.hops,
        kind: message.kind,
      ),
    ],
  ];

  @override
  Future<void> register(
    String agentId, {
    String? sessionName,
    List<AgentCapability> capabilities = const [],
  }) => _inner.register(
    agentId,
    sessionName: sessionName,
    capabilities: capabilities,
  );

  @override
  Future<void> touch(String agentId, {bool busy = false}) =>
      _inner.touch(agentId, busy: busy);

  @override
  Future<List<MailboxEntry>> directory() => _inner.directory();
}
