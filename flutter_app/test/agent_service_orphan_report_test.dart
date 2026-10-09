// gh-1449 AC6 — the APP side of the one-shot orphan-report latch: the
// loadSession seed (`AgentServiceSessions.open` → reportedOrphanKeys) and
// the persist path (`AgentServiceEvents` appending the hidden orphan_report
// record on ToolPairingRepairEvent). Library-level latch behavior is
// covered by test/agent/tool_pairing_test.dart; here the wiring runs
// through the real service.
import 'package:fa/services/agent_service.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

final _at = DateTime.utc(2026, 1, 1, 12);

/// A [StreamFunction] answering every request with 'ok' and recording each
/// request context.
final class _CapturingStream {
  final contexts = <Context>[];

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(
      Context(
        systemPrompt: context.systemPrompt,
        messages: List.of(context.messages),
        tools: context.tools,
      ),
    );
    final stream = AssistantMessageEventStream();
    stream.push(
      DoneEvent(
        reason: StopReason.stop,
        message: AssistantMessage(
          content: const [TextContent(text: 'ok')],
          api: model.api,
          provider: model.provider,
          model: model.id,
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: DateTime.now(),
        ),
      ),
    );
    stream.end();
    return stream;
  }
}

Agent _agentWith(_CapturingStream stream) => Agent(
  model: Model(
    id: 'test-model',
    api: 'test-api',
    provider: 'test',
    baseUrl: 'https://example.com',
    contextWindow: 100000,
    maxTokens: 4096,
  ),
  systemPrompt: 'You are Fa.',
  streamFunction: stream.call,
  toolRegistry: ToolRegistry(const []),
);

/// Seeds [name] with the orphan shape (a result whose call is gone) and
/// returns (metadata, latch key) — the key computed from the REBUILT
/// context, i.e. what the resumed loop will see.
Future<(SessionMetadata, String)> _seedOrphanSession(
  JsonlSessionRepo repo,
  String name, {
  bool withRecord = false,
}) async {
  final seed = await repo.create(
    JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'fa'}),
  );
  await seed.appendSessionName(name);
  await seed.appendMessage(
    UserMessage.text('before the cut', timestamp: DateTime.utc(2026)),
  );
  await seed.appendMessage(
    ToolResultMessage(
      toolCallId: 'bash_198',
      toolName: 'bash',
      content: const [TextContent(text: 'ok')],
      timestamp: _at,
      isError: false,
    ),
  );
  final meta = await seed.getMetadata();
  final rebuilt = await (await repo.open(meta)).buildContextMessages();
  final key = orphanReportKey(rebuilt.whereType<ToolResultMessage>().single);
  if (withRecord) {
    final writer = await repo.open(meta);
    await writer.appendCustomEntry(
      customType: orphanReportRecordType,
      data: orphanReportRecordData({key}),
    );
  }
  return (meta, key);
}

List<String> _noteTexts(Context context) => context.messages
    .whereType<UserMessage>()
    .map(_messageText)
    .where((t) => t.contains('[context note:'))
    .toList();

/// The text of a user message (string or content-block content).
String _messageText(UserMessage message) {
  final content = message.content;
  if (content is String) return content;
  return [
    for (final block in content as List<ContentBlock>)
      if (block is TextContent) block.text,
  ].join();
}

void main() {
  test(
    'persist: a first-time orphan note appends the orphan_report record',
    () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final (meta, key) = await _seedOrphanSession(repo, 'orphan-app-live');
      final stream = _CapturingStream();
      final service = AgentService(
        agent: _agentWith(stream),
        env: env,
        sessionsRoot: '/sessions',
        repo: repo,
      );
      addTearDown(service.dispose);
      await service.initialize();
      await service.loadSession(meta);

      await service.sendText('go');
      await service.waitForIdle();

      // The note reached the request, riding a user message.
      final notes = _noteTexts(stream.contexts.first);
      expect(notes, hasLength(1));
      expect(notes.single, contains('bash_198'));

      // AC6: the batch was persisted as the hidden record.
      final records = await repo.readCustomRecordsOfType(meta, {
        orphanReportRecordType,
      });
      expect(orphanReportKeysFromRecords(records), {key});
    },
  );

  test('seed: a resumed session whose orphan_report record holds the key '
      'does not re-note', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final (meta, key) = await _seedOrphanSession(
      repo,
      'orphan-app-recorded',
      withRecord: true,
    );
    final stream = _CapturingStream();
    final service = AgentService(
      agent: _agentWith(stream),
      env: env,
      sessionsRoot: '/sessions',
      repo: repo,
    );
    addTearDown(service.dispose);
    await service.initialize();
    await service.loadSession(meta);

    await service.sendText('go');
    await service.waitForIdle();

    // The resumed history reached the request and the orphan was dropped…
    expect(
      stream.contexts.first.messages.whereType<UserMessage>().map(_messageText),
      contains('before the cut'),
    );
    expect(
      stream.contexts.first.messages.whereType<ToolResultMessage>(),
      isEmpty,
    );
    // …silently: the seeded latch suppressed the note.
    expect(_noteTexts(stream.contexts.first), isEmpty);

    // Sanity: the key the record holds is the one the repair computes.
    expect(key, isNotEmpty);
  });
}
