@TestOn('vm')
library;

/// gh-2492 C5 — the hide-only path writes engine-generated range labels.
///
/// Every bare hide writer (judge hide, deterministic fallback, LRU
/// re-hide, EmergencyRelief) consolidates its batch: ONE
/// `HiddenRangeRecord` with `consolidated: true` and a per-member
/// histogram label (`bash ×61 · read ×40 · 12:41–13:44`) computed from
/// the covered records — no model text, no injection surface. The
/// projection renders `<label> [expand a-b]` at the carrier, replacing
/// the per-record marker run.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/engine.dart';
import 'package:test/test.dart';

AssistantMessage _assistant(String text, {List<ToolCall>? calls}) {
  return AssistantMessage(
    content: [
      TextContent(text: text),
      ...?calls,
    ],
    api: 'anthropic-messages',
    provider: 'p',
    model: 'm1',
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.utc(2026, 11, 28, 12, 0, 0),
  );
}

ToolResultMessage _result(String callId, String name, String text) {
  return ToolResultMessage(
    toolCallId: callId,
    toolName: name,
    content: [TextContent(text: text)],
    isError: false,
    timestamp: DateTime.utc(2026, 11, 28, 12, 0, 0),
  );
}

const _settings = CompactionSettings(
  enabled: true,
  reserveTokens: 1000,
  keepRecentTokens: 2000,
);

/// An over-window session with two hideable tool pairs (the structured
/// engine test harness shape: JSONL repo, marker-sized payloads).
Future<(Session, AgentState)> _overWindowSession() async {
  final repo = JsonlSessionRepo(
    fs: MemoryFileSystem(),
    sessionsRoot: '/sessions',
  );
  final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
  await session.appendMessage(UserMessage.text('fix the crash'));
  await session.appendMessage(
    _assistant('looking', calls: [_call('c1', 'bash')]),
  );
  await session.appendMessage(_result('c1', 'bash', 'r${'x' * 16000}'));
  await session.appendMessage(_assistant('found it'));
  await session.appendMessage(_assistant('run', calls: [_call('c2', 'read')]));
  await session.appendMessage(_result('c2', 'read', 'r${'y' * 12000}'));
  for (var i = 0; i < 6; i++) {
    await session.appendMessage(_assistant('filler analysis $i'));
  }
  final messages = await session.buildContextMessages();
  final state = AgentState(
    model: Model(
      id: 'm1',
      name: 'm1',
      api: 'anthropic-messages',
      provider: 'p',
      baseUrl: 'http://localhost:1',
      contextWindow: 8000,
      maxTokens: 4096,
    ),
    messages: messages,
  );
  return (session, state);
}

ToolCall _call(String id, String name) =>
    ToolCall(id: id, name: name, arguments: const {});

void main() {
  group('C5 consolidated hide batches', () {
    test(
      'the judge hide writes consolidated: true with a histogram label',
      () async {
        final (session, state) = await _overWindowSession();
        final compactor = StructuredCompactor(
          session: session,
          state: state,
          window: 8000,
          settings: _settings,
          judge: (ledger, [token]) async => '["3"]',
          summarize: (request) async =>
              SummarizationResult.failure('must not summarize in this test'),
          checkpointPrompt: 'SUMMARY INSTRUCTIONS',
        );
        await compactor.run();
        final records = await session.getEntries();
        final hides = records.whereType<HiddenRangeRecord>().toList();
        expect(hides, hasLength(1));
        expect(hides.single.consolidated, isTrue);
        expect(hides.single.labels, isNotEmpty);
        final label = hides.single.labels.values.first;
        // The histogram counts TOOL EVENTS: the call block + its result.
        expect(label, contains('bash ×2'));
        expect(label, isNot(contains('\n')));
      },
    );

    test('the consolidated range renders `<label> [expand a-b]` at the '
        'carrier — no per-record marker run', () async {
      final (session, state) = await _overWindowSession();
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 8000,
        settings: _settings,
        judge: (ledger, [token]) async => '["3"]',
        summarize: (request) async =>
            SummarizationResult.failure('must not summarize in this test'),
        checkpointPrompt: 'SUMMARY INSTRUCTIONS',
      );
      await compactor.run();
      final messages = await session.buildContextMessages();
      final markers = messages
          .whereType<UserMessage>()
          .map((m) => m.content as String)
          .where((text) => text.contains('[expand'))
          .toList();
      expect(markers, hasLength(1), reason: 'ONE marker for the whole pair');
      expect(markers.single, contains('bash ×2'));
      expect(markers.single, contains('[expand 3-4]'));
      expect(
        messages.where(
          (m) => m is UserMessage && (m.content as String).contains(':hidden'),
        ),
        isEmpty,
        reason: 'no bare per-record markers remain for the batch',
      );
      expect(validateToolPairing(messages), isEmpty);
    });

    test('the deterministic fallback (dead judge) consolidates too', () async {
      final (session, state) = await _overWindowSession();
      final compactor = StructuredCompactor(
        session: session,
        state: state,
        window: 8000,
        settings: _settings,
        judge: (ledger, [token]) async => 'not json',
        summarize: (request) async =>
            SummarizationResult.failure('must not summarize in this test'),
        checkpointPrompt: 'SUMMARY INSTRUCTIONS',
      );
      await compactor.run();
      final records = await session.getEntries();
      final hides = records.whereType<HiddenRangeRecord>().toList();
      expect(hides, hasLength(1));
      expect(hides.single.consolidated, isTrue);
      expect(hides.single.labels, isNotEmpty);
    });
  });
}
