/// REG-legacy (issue #304 AC3/E6): with the hub fabric off — the
/// `fabric.hub: false` kill switch, or DAP never started — the messaging
/// fabric is the BARE file layer and the `agent_directory` listing is
/// byte-identical to the pre-hub rendering. The kill-switch gate itself
/// (`hubFabricWired`, bin) is pinned in `test/hub/dap_command_test.dart`;
/// this file pins the rendering consequence: no hub rows, no markers, no
/// byte drift on the file rows.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:flutter_agent_harness/src/messaging/agent_fabric.dart';
import 'package:flutter_agent_harness/src/task/subagent_manager.dart';
import 'package:flutter_agent_harness/src/task/subagent_tools.dart';
import 'package:test/test.dart';

/// A hub-primary stand-in that would pollute the listing if the kill
/// switch failed: one live hub peer with a name and the hub marker.
final class _HubPrimaryStub
    implements MessagingRepository, RoutingMessagingRepository {
  @override
  bool get isConnected => true;

  @override
  Future<String?> resolveTarget(String toId) async =>
      toId == 'browser123' ? toId : null;

  @override
  Future<void> send(AgentMessage message) async {}

  @override
  Future<List<AgentMessage>> peek(String agentId) async => const [];

  @override
  Future<List<AgentMessage>> drain(String agentId) async => const [];

  @override
  Future<void> register(
    String agentId, {
    String? sessionName,
    List<AgentCapability> capabilities = const [],
  }) async {}

  @override
  Future<void> touch(String agentId, {bool busy = false}) async {}

  @override
  Future<List<MailboxEntry>> directory() async => const [
    MailboxEntry(
      id: 'browser123',
      name: 'Browser',
      presence: AgentPresence.live,
      source: mailboxSourceHub,
    ),
  ];
}

void main() {
  /// Seeds one file mailbox with pending mail under a fresh in-memory
  /// fabric and returns it, so each rendering starts from identical
  /// state.
  Future<MessagingRepository> seededFabric() async {
    final built = buildAgentFabric(
      env: MemoryExecutionEnv(cwd: '/work'),
      sessionRoot: '/sessions',
      homeDir: null,
      hubFabric: null,
      mainMailbox: () => 'sess1/main',
    );
    await built.fabric.send(
      AgentMessage(
        id: 'legacy-mail-1',
        fromId: 'sess2/main',
        toId: 'sess1/main',
        text: 'hello from the file world',
        sentAt: '2026-01-01T00:00:00Z',
      ),
    );
    return built.fabric;
  }

  /// The `agent_directory` body rendered over [fabric] (the tool path the
  /// agent actually sees).
  Future<String> render(MessagingRepository fabric) async {
    final manager = SubagentManager(
      parentSessionId: 'p',
      messaging: fabric,
    )..mailboxPrefix = 'sess1';
    final tools = subagentMonitoringTools(manager: manager);
    final directory = tools.firstWhere((t) => t.name == 'agent_directory');
    final result = await directory.execute(const {}, null, null);
    return (result.content.first as dynamic).text as String;
  }

  test(
    'kill switch off (fabric.hub: false): the listing is byte-identical '
    'to the legacy file-only rendering',
    () async {
      final legacy = await render(await seededFabric());
      // What `fabric.hub: false` produces: the SAME bare construction —
      // bin/fah.dart passes hubFabric: null when the switch is off
      // (pinned by hubFabricWired in test/hub/dap_command_test.dart).
      final killSwitch = await render(await seededFabric());

      expect(killSwitch, legacy,
          reason: 'the kill switch must reproduce the legacy listing '
              'byte-for-byte (E6)');
      expect(killSwitch, isNot(contains('Browser')));
      expect(killSwitch, isNot(contains('[hub]')));
      expect(killSwitch, contains('sess1/main — 1 pending'));
    },
  );

  test('control: the same state with the hub fabric ON adds the hub row',
      () async {
    final bare = await seededFabric();
    final composite = FallbackMessagingRepository(
      primary: _HubPrimaryStub(),
      fallback: bare,
    )..primaryMailbox = () => 'sess1/main';
    final withHub = await render(composite);
    expect(withHub, contains('Browser'));
    expect(withHub, contains('[hub]'));
    // The file rows keep their exact legacy bytes inside the merged view.
    expect(withHub, contains('sess1/main — 1 pending'));
  });
}
