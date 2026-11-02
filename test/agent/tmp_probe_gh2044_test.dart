import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _model = Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

AssistantMessage _message(StopReason reason) => AssistantMessage(
  content: const [],
  api: 'test-api',
  provider: 'test-provider',
  model: 'test-model',
  usage: Usage.zero,
  stopReason: reason,
  timestamp: DateTime.utc(2026),
);

final class _CapturingHooks implements AutoCompactorHooks {
  Object? bothRolesError;
  final passes = <AutoCompactorPass>[];
  int doneCount = 0;

  @override
  void onDelta(String delta) {}

  @override
  void onAttemptStart(String label, int attempt, Duration budget) {}

  @override
  void onPass(AutoCompactorPass pass) => passes.add(pass);

  @override
  void onRetry(int attempt, int maxAttempts, Duration backoff, Object error) {}

  @override
  void onDone(int passes, int tokens) => doneCount++;

  @override
  void onBothRolesFailed(Object lastError) => bothRolesError = lastError;
}

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  });

  test('PROBE: gh-1743 nothing-droppable trace', () async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
    await session.appendMessage(UserMessage.text('a' * 40));
    final state = AgentState(
      model: _model,
      messages: await session.buildContextMessages(),
    );
    final hooks = _CapturingHooks();

    final ok = await AutoCompactorFactory(
      session: session,
      state: state,
      window: 100,
      settings: const CompactionSettings(
        enabled: true,
        reserveTokens: 100,
        keepRecentTokens: 150,
      ),
      sources: AutoCompactorSources(
        smolStream: null,
        smolModel: null,
        mainStream: (m, c, {cancelToken}) {
          // ignore: avoid_print
          print('PROBE: main stream called (wedged)');
          final stream = AssistantMessageEventStream();
          stream.push(StartEvent(partial: _message(StopReason.stop)));
          return stream;
        },
        mainModel: _model,
      ),
      hooks: hooks,
      force: true,
      attemptBudget: const Duration(seconds: 30),
      totalBudget: const Duration(milliseconds: 300),
    ).run();

    // ignore: avoid_print
    print('PROBE: ok=$ok bothRolesError=${hooks.bothRolesError} '
        'doneCount=${hooks.doneCount}');
    for (final p in hooks.passes) {
      // ignore: avoid_print
      print('PROBE: pass=${p.pass} fallback=${p.fallback} ok=${p.ok} '
          'tokens ${p.tokensBefore}->${p.tokensAfter} '
          'error=${p.error} summary=${p.summary?.substring(0, p.summary!.length.clamp(0, 120))} '
          'hidden=${p.hiddenRecords} summarized=${p.summarizedMessages} dropped=${p.droppedMessages}');
    }
    expect(true, isTrue);
  });
}
