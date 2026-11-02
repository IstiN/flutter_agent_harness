// SCRATCH probe — measure recordTokens for the fixture records via a repo.
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/projection.dart'
    show recordTokens, hiddenMarkerTokens, RecordSeqIndex;

AssistantMessage carrier(String callId) => AssistantMessage(
  content: [
    const TextContent(text: 'a'),
    ToolCall(id: callId, name: 'read', arguments: {}),
  ],
  api: 'anthropic-messages',
  provider: 'p',
  model: 'm1',
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime.utc(2026),
);

ToolResultMessage result(String callId, int tokens) => ToolResultMessage(
  toolCallId: callId,
  toolName: 'read',
  content: [TextContent(text: 'x' * (tokens * 4))],
  isError: false,
  timestamp: DateTime.utc(2026),
);

AssistantMessage filler(int tokens) => AssistantMessage(
  content: [TextContent(text: 'f' * (tokens * 4))],
  api: 'anthropic-messages',
  provider: 'p',
  model: 'm1',
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime.utc(2026),
);

Future<void> main() async {
  final fs = MemoryFileSystem();
  final repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
  await session.appendMessage(UserMessage.text('u' * 400));
  await session.appendMessage(carrier('c0'));
  await session.appendMessage(result('c0', 100));
  await session.appendMessage(filler(150));
  await session.appendMessage(filler(75));
  final entries = await session.getEntries();
  final seqs = RecordSeqIndex(entries);
  for (final r in entries) {
    if (r is! MessageRecord) continue;
    // ignore: avoid_print
    print('${r.message.runtimeType}: tokens=${recordTokens(r)} '
        'marker=${hiddenMarkerTokens(r, seqs.seqOf(r.id)!)} '
        'seq=${seqs.seqOf(r.id)}');
  }
  final total = entries
      .whereType<MessageRecord>()
      .fold<int>(0, (a, r) => a + recordTokens(r));
  // ignore: avoid_print
  print('total=$total');
  final state = AgentState(
    model: Model(
      id: 'm1',
      name: 'm1',
      api: 'anthropic-messages',
      provider: 'p',
      baseUrl: 'http://localhost:1',
      contextWindow: 800,
      maxTokens: 4096,
    ),
    messages: await session.buildContextMessages(),
  );
  // ignore: avoid_print
  print('requestTokens=${estimateRequestTokens(state.messages)}');
}
