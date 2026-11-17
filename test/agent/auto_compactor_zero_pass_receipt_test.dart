// gh-2237 AC2 — the zero-pass structured outcome is a TERMINAL receipt,
// not silence. The factory threads the engine's exit reason into
// [AutoCompactorHooks.onDone], so a host listening for the bracket close
// can print `passes=0 (no-op: …)` on every surface it owns.
//
// gh-1742 invariant preserved: a FORCED zero-pass structured run still
// falls through to the classic engine — /compact immunity is untouched.

library;

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

const _settings = CompactionSettings(
  enabled: true,
  reserveTokens: 100,
  keepRecentTokens: 150,
);

AssistantMessage _assistant(String text) => AssistantMessage(
  content: [TextContent(text: text)],
  api: 'test-api',
  provider: 'test-provider',
  model: 'test-model',
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime.utc(2026),
);

final class _CapturingHooks implements AutoCompactorHooks {
  final passes = <AutoCompactorPass>[];
  final doneCalls = <(int, int, String?)>[];

  @override
  void onDelta(String delta) {}

  @override
  void onAttemptStart(String label, int attempt, Duration budget) {}

  @override
  void onPass(AutoCompactorPass pass) => passes.add(pass);

  @override
  void onRetry(int attempt, int maxAttempts, Duration backoff, Object error) {}

  @override
  void onDone(int passes, int tokens, {String? reason}) =>
      doneCalls.add((passes, tokens, reason));

  @override
  void onBothRolesFailed(Object lastError) {}
}

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  });

  /// A small transcript — far under the 900-token trigger of the
  /// 1000-token window.
  Future<(Session, AgentState)> underTriggerSession() async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
    await session.appendMessage(UserMessage.text('fix the login crash'));
    await session.appendMessage(_assistant('looking around ' * 80));
    await session.appendMessage(_assistant('found it ' * 80));
    final state = AgentState(
      model: _model,
      messages: await session.buildContextMessages(),
    );
    return (session, state);
  }

  AutoCompactorFactory factory(
    Session session,
    AgentState state,
    _CapturingHooks hooks, {
    bool force = false,
  }) => AutoCompactorFactory(
    session: session,
    state: state,
    window: 1000,
    settings: _settings,
    sources: AutoCompactorSources(
      smolStream: null,
      smolModel: null,
      mainStream: (m, c, {cancelToken}) {
        // A canned summarizer answer for the classic fall-through.
        final partial = AssistantMessage(
          content: [const TextContent(text: 'canned summary')],
          api: 'test-api',
          provider: 'test-provider',
          model: 'test-model',
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: DateTime.utc(2026),
        );
        final stream = AssistantMessageEventStream()
          ..push(StartEvent(partial: partial))
          ..push(DoneEvent(reason: StopReason.stop, message: partial))
          ..end();
        return stream;
      },
      mainModel: _model,
    ),
    hooks: hooks,
    force: force,
  );

  test(
    'UT-4: unforced under-trigger run reports onDone(0) with the reason',
    () async {
      final (session, state) = await underTriggerSession();
      final hooks = _CapturingHooks();

      final ok = await factory(session, state, hooks).run();

      expect(ok, isTrue);
      expect(hooks.passes, isEmpty, reason: 'no pass ran — under trigger');
      expect(hooks.doneCalls, hasLength(1));
      final (passes, tokens, reason) = hooks.doneCalls.single;
      expect(passes, 0);
      expect(tokens, greaterThan(0));
      expect(
        reason,
        isNotNull,
        reason:
            'AC2: the zero-pass outcome must carry the exit reason — '
            'a started compaction can never end in silence',
      );
      expect(
        reason!,
        matches(RegExp(r'basis \d+ below trigger \d+ at the run gate')),
      );
    },
  );

  test('gh-1742 preserved: a forced zero-pass run still reaches the classic '
      'fall-through — no reason-bearing onDone(0)', () async {
    final (session, state) = await underTriggerSession();
    final hooks = _CapturingHooks();

    final ok = await factory(session, state, hooks, force: true).run();

    expect(ok, isTrue);
    // The classic engine ran its (no-op) pass — never a silent zero.
    expect(hooks.passes, hasLength(1));
    expect(hooks.doneCalls.single.$1, 1);
  });
}
