@TestOn('vm')
library;

/// Issue #862 IT-2 / AC5 (IT half): the luna death wiring replayed.
///
/// A parent tool pool that leaks the child-only `reply` tool into the
/// inherited surface (the luna session's wiring bug) used to kill every
/// child at spawn in 0.0s with `ConfigException: Duplicate tool name:
/// reply` (the hallucinated-fix death). With replace-and-note registration
/// the same wiring produces a LIVE child that runs and completes; the
/// duplicate registration is recorded as a warning, and the child-specific
/// injected `reply` wins.

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _model = Model(
  id: 'parent-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

AssistantMessage _assistant({
  List<ContentBlock> content = const [],
  StopReason stopReason = StopReason.stop,
}) {
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: stopReason,
    timestamp: DateTime.utc(2026),
  );
}

List<AssistantMessageEvent> _textTurn(String text) {
  final empty = _assistant();
  final partial = _assistant(content: [TextContent(text: text)]);
  return [
    StartEvent(partial: empty),
    TextStartEvent(contentIndex: 0, partial: empty),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

AssistantMessageEventStream _immediate(List<AssistantMessageEvent> events) {
  final stream = AssistantMessageEventStream();
  for (final event in events) {
    stream.push(event);
  }
  stream.end();
  return stream;
}

/// The exact luna wiring: the parent pool carries `reply` (it must not) in
/// addition to the monitoring tools every child inherits.
AgentTool _replyLeakTool() {
  return AgentTool(
    name: 'reply',
    description: 'reply (leaked from the parent surface)',
    tier: ApprovalTier.read,
    execute: (arguments, cancelToken, onUpdate) async =>
        ToolExecutionResult.text('leaked reply'),
  );
}

AgentTool _fakeTool(String name) {
  return AgentTool(
    name: name,
    description: '$name tool',
    tier: ApprovalTier.read,
    execute: (arguments, cancelToken, onUpdate) async =>
        ToolExecutionResult.text('$name result'),
  );
}

final class _FakeFabric implements MessagingRepository {
  @override
  Future<void> send(AgentMessage message) async {}

  @override
  Future<void> register(
    String agentId, {
    String? sessionName,
    List<AgentCapability> capabilities = const [],
  }) async {}

  @override
  Future<void> touch(String agentId, {bool busy = false}) async {}

  @override
  Future<List<AgentMessage>> peek(String agentId) async => const [];

  @override
  Future<List<AgentMessage>> drain(String agentId) async => const [];

  @override
  Future<List<MailboxEntry>> directory() async => const [];
}

void main() {
  test('IT-2: a duplicate-reply registry spawn produces a LIVE child that '
      'completes (issue #862 AC5)', () async {
    final manager = SubagentManager(
      parentSessionId: 'sess',
      messaging: _FakeFabric(),
    )..mailboxPrefix = 'sess';
    final executor = TaskExecutor(
      childTools: [_replyLeakTool(), _fakeTool('read')],
      streamFunction: () => (model, context, {cancelToken}) {
        return _immediate(_textTurn('child finished the work'));
      },
      model: () => _model,
      registry: TaskAgentRegistry(const []),
      semaphore: Semaphore(2),
      store: AgentOutputStore(),
      subagentManager: manager,
    );

    final result = await executor.runSpawn(
      item: const TaskItem(name: 'scout', task: 'luna mini-app job'),
      index: 0,
      context: 'ctx',
    );

    // The child RAN (pre-fix: status failed, error 'Duplicate tool name:
    // reply', duration ~0.0s).
    expect(result.status, TaskSpawnStatus.completed);
    expect(result.error, isNull);
    expect(result.output, contains('child finished the work'));
    expect(result.requests, 1);

    // The duplicate registration degraded loudly into a warning on the
    // registry the child actually ran with: reachable via the manager's
    // handle metadata? No — via the child tool surface, asserted here by
    // the child completing at all. The registry-level warning is unit
    // covered in tool_registry_test.dart.
  });
}
