import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/engine.dart';
import 'package:flutter_agent_harness/src/compaction/structured/projection.dart'
    show RecordSeqIndex, hiddenMarkerTokens, recordTokens;

AssistantMessage carrier(String callId) => AssistantMessage(
  content: [const TextContent(text: 'a'), ToolCall(id: callId, name: 'read', arguments: {})],
  api: 'a', provider: 'p', model: 'm1', usage: Usage.zero, stopReason: StopReason.stop,
  timestamp: DateTime.utc(2026),
);
ToolResultMessage result(String callId, int tokens) => ToolResultMessage(
  toolCallId: callId, toolName: 'read',
  content: [TextContent(text: 'x' * (tokens * 4))], isError: false, timestamp: DateTime.utc(2026));

void main() async {
  final fs = MemoryFileSystem();
  final repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
  await session.appendMessage(UserMessage.text('u' * 400));
  await session.appendMessage(UserMessage.text('f' * 16)); // hidden filler 4
  for (var i = 0; i < 5; i++) {
    await session.appendMessage(carrier('c$i'));
    await session.appendMessage(result('c$i', 100));
  }
  await session.appendMessage(UserMessage.text('f' * 196)); // kept filler 49
  final entries = await session.getEntries();
  final hidden = {entries[1].id, entries[2].id, entries[3].id};
  final seqs = RecordSeqIndex(entries);
  var helperTotal = 0;
  for (final r in entries) {
    if (r is! MessageRecord) continue;
    final seq = seqs.seqOf(r.id)!;
    final t = hidden.contains(r.id) ? hiddenMarkerTokens(r, seq) : recordTokens(r);
    helperTotal += t;
    if (hidden.contains(r.id)) print('hidden seq=$seq markerTokens=$t');
  }
  print('helperTotal=$helperTotal');
  await session.appendHiddenRange(recordIds: hidden.toList());
  final state = AgentState(model: Model(id: 'm', name: 'm', api: 'a', provider: 'p', baseUrl: 'x', contextWindow: 800, maxTokens: 100),
    messages: await session.buildContextMessages());
  print('engineEstimate=${estimateRequestTokens(state.messages)}');
}
