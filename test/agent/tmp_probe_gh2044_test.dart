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
  void onAttemptStart(String label, int attempt, Duration budget) {
    // ignore: avoid_print
    print('PROBE: attemptStart label=$label attempt=$attempt');
  }

  @override
  void onPass(AutoCompactorPass pass) => passes.add(pass);

  @override
  void onRetry(int attempt, int maxAttempts, Duration backoff, Object error) {
    // ignore: avoid_print
    print('PROBE: retry attempt=$attempt error=$error');
  }

  @override
  void onDone(int passes, int tokens) => doneCount++;

  @override
  void onBothRolesFailed(Object lastError) {
    bothRolesError = lastError;
    // ignore: avoid_print
    print('PROBE: bothRolesFailed error=$lastError');
  }
}

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  });

  test('PROBE-2: classic engine alone on the nothing-droppable fixture', () async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
    await session.appendMessage(UserMessage.text('a' * 40));
    final state = AgentState(
      model: _model,
      messages: await session.buildContextMessages(),
    );
    final hooks = _CapturingHooks();

    final sw = Stopwatch()..start();
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
          print('PROBE: STREAM CALLED (wedged)');
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
    sw.stop();

    // ignore: avoid_print
    print('PROBE: ok=$ok elapsed=${sw.elapsedMilliseconds}ms '
        'bothRolesError=${hooks.bothRolesError} doneCount=${hooks.doneCount}');
    for (final p in hooks.passes) {
      // ignore: avoid_print
      print('PROBE: pass=${p.pass} fallback=${p.fallback} ok=${p.ok} '
          'tokens ${p.tokensBefore}->${p.tokensAfter} summary=${p.summary}');
    }
    expect(true, isTrue);
  });
}
