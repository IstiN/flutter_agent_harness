@TestOn('vm')
/// Tool-level tests for the durable deliverable path (issue #1829):
/// UT-07 contract snapshots of the child-facing descriptions, flow A
/// through the real reply/agent_message tools, and the E11 scoping rule.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/prompts/prompts.g.dart'
    show taskToolDescriptionPrompt;
import 'package:test/test.dart';

const _secret = 'sk-live-canary-0123456789';

/// Minimal in-memory fabric so cross-session deliveries can be observed.
final class _FakeFabric implements MessagingRepository {
  final _inboxes = <String, List<AgentMessage>>{};

  List<AgentMessage> inbox(String mailbox) =>
      List.unmodifiable(_inboxes[mailbox] ?? const []);

  @override
  Future<void> send(AgentMessage message) async =>
      _inboxes.putIfAbsent(message.toId, () => []).add(message);

  @override
  Future<List<AgentMessage>> peek(String agentId) async => inbox(agentId);

  @override
  Future<List<AgentMessage>> drain(String agentId) async =>
      List.unmodifiable(_inboxes.remove(agentId) ?? const []);

  @override
  Future<void> register(
    String agentId, {
    String? sessionName,
    List<AgentCapability> capabilities = const [],
  }) async {}

  @override
  Future<void> touch(String agentId, {bool busy = false}) async {}

  @override
  Future<List<MailboxEntry>> directory() async => const [];
}

(SubagentManager, AgentOutputStore, Map<String, AgentTool>) _rig({
  int cap = 200,
  String Function(String text)? redact,
  _FakeFabric? fabric,
}) {
  final manager = SubagentManager(
    parentSessionId: 'p',
    maxReplyChars: cap,
    messaging: fabric,
  );
  manager.register(id: 'kid', name: 'kid', agentType: 'task', task: 't');
  final store = AgentOutputStore();
  final capture = DeliverableCapture(
    store: store,
    manager: manager,
    redact: redact,
  );
  final tools = {
    for (final t in subagentMonitoringTools(
      manager: manager,
      currentSubagentId: () => 'kid',
      capture: () => capture,
    ))
      t.name: t,
  };
  return (manager, store, tools);
}

String _text(ToolExecutionResult result) =>
    result.content.whereType<TextContent>().map((b) => b.text).join('\n');

void main() {
  group('UT-07: the chunk contract is child-visible', () {
    test(
      'reply description exposes the budget, protocol, and manifest rule',
      () {
        final (manager, _, tools) = _rig(cap: 4321);
        final description = tools['reply']!.description;
        expect(description, contains('4321 chars'));
        expect(description, contains('REPORT SIZE'));
        expect(description, contains('report_id'));
        expect(description, contains('part_index'));
        expect(description, contains('more=false'));
        expect(description, contains('manifest'));
        expect(description, contains('Never probe the output limit'));
        // Plain text is never forced through a schema (F4/I7).
        expect(description.toLowerCase().contains('outputschema'), isFalse);
      },
    );

    test('agent_message description exposes the budget and ordered parts', () {
      final (manager, _, tools) = _rig(cap: 777);
      final description = tools['agent_message']!.description;
      expect(description, contains('777 chars'));
      expect(description, contains('REPORT SIZE'));
      expect(description, contains('part_index'));
    });

    test(
      'the parent-facing task tool description documents artifact recovery',
      () {
        expect(taskToolDescriptionPrompt, contains('# Report Size'));
        expect(taskToolDescriptionPrompt, contains('agent://'));
        expect(taskToolDescriptionPrompt, contains('INCOMPLETE'));
      },
    );
  });

  group('flow A through the reply tool (AC1/AC2/AC8)', () {
    test(
      'over-cap reply stores the artifact and records the envelope',
      () async {
        final (manager, store, tools) = _rig(
          cap: 100,
          redact: (text) => text.replaceAll(_secret, '***'),
        );
        final result = await tools['reply']!.execute(
          {'message': 'a canary $_secret report ' * 5},
          null,
          null,
        );
        expect(
          _text(result),
          contains('reply delivered to the parent via artifact'),
        );
        final record = manager['kid']!.deliverables.single;
        expect(record.status, AgentArtifactStatus.complete);
        // lastReply is the envelope, bounded by the cap.
        final reply = manager['kid']!.lastReply!;
        expect(reply.length, lessThanOrEqualTo(100));
        expect(reply, contains(record.pointer!));
        // The stored artifact is the REDACTED text.
        expect(store.get(record.outputId!), isNot(contains(_secret)));
        // And so is the delivered envelope (the parent-visible surface):
        // canary AND canary prefix absent (review hardening — the
        // excerpt window cuts the 25-char canary, so scan a prefix).
        expect(reply, isNot(contains(_secret)));
        expect(reply, isNot(contains(_secret.substring(0, 10))));
      },
    );

    test('in-budget reply stays direct with no artifact', () async {
      final (manager, store, tools) = _rig(cap: 100);
      final result = await tools['reply']!.execute(
        {'message': 'short answer'},
        null,
        null,
      );
      expect(_text(result), 'reply delivered to the parent');
      expect(manager['kid']!.lastReply, 'short answer');
      expect(store.availableIds, isEmpty);
    });

    test(
      'an impossible envelope cap is an explicit error, never a malformed pointer',
      () async {
        final (manager, store, tools) = _rig(cap: 10);
        final result = await tools['reply']!.execute(
          {'message': 'x' * 200},
          null,
          null,
        );
        expect(_text(result), contains('error:'));
        expect(_text(result), contains('cannot hold a deliverable envelope'));
        expect(_text(result), isNot(contains('agent://')));
        // Nothing was persisted for the failed envelope either.
        expect(
          store.availableIds.where((id) => store.artifactMeta(id) != null),
          isEmpty,
        );
        expect(manager['kid']!.lastReply, isNull);
      },
    );

    test('report_parts without report_id is rejected', () async {
      final (manager, store, tools) = _rig();
      final result = await tools['reply']!.execute(
        {'message': 'manifest', 'report_parts': 3},
        null,
        null,
      );
      expect(_text(result), contains('error: report_parts requires report_id'));
    });
  });

  group('flow A through agent_message + E11 scoping', () {
    test('oversize same-session body arrives as an envelope', () async {
      final fabric = _FakeFabric();
      final (manager, store, tools) = _rig(cap: 100, fabric: fabric);
      final result = await tools['agent_message']!.execute(
        {'to': 'main', 'message': 'body ' * 100},
        null,
        null,
      );
      expect(_text(result), contains('message queued for "main"'));
      final delivered = fabric.inbox('main').single.text;
      expect(delivered.length, lessThanOrEqualTo(100));
      expect(delivered, contains('agent://'));
      final record = manager['kid']!.deliverables.single;
      expect(store.get(record.outputId!), 'body ' * 100);
    });

    test(
      'oversize cross-instance mailbox keeps the legacy bare cap (E11)',
      () async {
        final fabric = _FakeFabric();
        final (manager, store, tools) = _rig(cap: 100, fabric: fabric);
        final result = await tools['agent_message']!.execute(
          {'to': 'othersession/main', 'message': 'body ' * 100},
          null,
          null,
        );
        expect(_text(result), contains('message queued for'));
        final delivered = fabric.inbox('othersession/main').single.text;
        // Bare legacy truncation — no unresolvable pointer.
        expect(delivered, contains('…[truncated]'));
        expect(delivered, isNot(contains('agent://')));
        expect(manager['kid']!.deliverables, isEmpty);
        expect(store.availableIds, isEmpty);
      },
    );

    test('oversize A2A target keeps the legacy bare cap (E11)', () async {
      final fabric = _FakeFabric();
      final (manager, store, tools) = _rig(cap: 100, fabric: fabric);
      // 'far@machine' has no local handle and no gateway: delivery is
      // refused with the honest unknown-recipient error — either way no
      // same-session pointer is minted.
      final result = await tools['agent_message']!.execute(
        {'to': 'far@machine', 'message': 'body ' * 100},
        null,
        null,
      );
      expect(_text(result), startsWith('error:'));
      expect(manager['kid']!.deliverables, isEmpty);
      expect(store.availableIds, isEmpty);
    });
  });
}
