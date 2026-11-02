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

class HooksProbe implements StructuredCompactorHooks {
  final passes = <StructuredCompactionPass>[];
  @override void onDelta(String delta) {}
  @override void onPass(StructuredCompactionPass pass) => passes.add(pass);
}

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
  final entries = await session.getEntries();
  final hiddenIds = {entries[1].id, entries[2].id, entries[3].id};
  final allFull = entries.whereType<MessageRecord>().fold<int>(0, (s, r) => s + recordTokens(r));
  final hiddenFull = entries.whereType<MessageRecord>().where((r) => hiddenIds.contains(r.id)).fold<int>(0, (s, r) => s + recordTokens(r));
  final seqs = RecordSeqIndex(entries);
  var settledPre = 0;
  for (final r in entries) {
    if (r is! MessageRecord) continue;
    final seq = seqs.seqOf(r.id)!;
    settledPre += hiddenIds.contains(r.id) ? hiddenMarkerTokens(r, seq) : recordTokens(r);
  }
  final markerTotal = settledPre - allFull + hiddenFull;
  final keptFiller = 600 - 0 - 100 - 102 * 4 - markerTotal;
  print('markerTotal=$markerTotal keptFiller=$keptFiller');
  await session.appendMessage(UserMessage.text('f' * (keptFiller * 4)));
  final state = AgentState(model: Model(id: 'm', name: 'm', api: 'a', provider: 'p', baseUrl: 'x', contextWindow: 800, maxTokens: 100),
    messages: await session.buildContextMessages());
  print('entry=${estimateRequestTokens(state.messages)}');
  final judgeAnswer = '[3,4]';
  final hooks = HooksProbe();
  final compactor = StructuredCompactor(
    session: session, state: state, window: 800,
    settings: const CompactionSettings(enabled: true, reserveTokens: 200, keepRecentTokens: 200),
    judge: (_) async => judgeAnswer,
    summarize: (_) async => SummarizationResult.success('CKPT'),
    checkpointPrompt: 'P', hooks: hooks, protectLastN: 4);
  final ok = await compactor.run();
  print('ok=$ok');
  for (final p in hooks.passes) {
    print('pass ${p.kind} before=${p.tokensBefore} after=${p.tokensAfter} ok=${p.ok} margin=${p.marginTokens} band=${p.bandTokens} err=${p.error}');
  }
}
