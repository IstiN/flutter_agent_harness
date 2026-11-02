import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// gh-2044 rework probe: replicate the flutter_app over-window relief
/// fixture at the core level — [user 'go', assistant toolUse, huge tool
/// result] over an 8192 window; the fake stream answers call 1 with a
/// toolUse turn and every later call with text 'continued'.
void main() {
  test('PROBE: app over-window relief fixture through AutoCompactorFactory',
      () async {
    final fs = MemoryFileSystem();
    final repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    await session.appendMessage(UserMessage.text('go'));
    await session.appendMessage(
      AssistantMessage(
        content: const [
          TextContent(text: 'a'),
          ToolCall(id: 'tc-1', name: 'echo', arguments: {}),
        ],
        api: 'anthropic-messages',
        provider: 'test',
        model: 'test-model',
        usage: Usage.zero,
        stopReason: StopReason.toolUse,
        timestamp: DateTime.now(),
      ),
    );
    await session.appendMessage(
      ToolResultMessage(
        toolCallId: 'tc-1',
        toolName: 'echo',
        content: [TextContent(text: 'y' * 34000)],
        isError: false,
        timestamp: DateTime.now(),
      ),
    );
    var calls = 0;
    AssistantMessageEventStream fake(
      Model m,
      Context c, {
      CancelToken? cancelToken,
    }) {
      calls++;
      AssistantMessage msg(dynamic content, StopReason reason) =>
          AssistantMessage(
            content: [content],
            api: m.api,
            provider: m.provider,
            model: m.id,
            usage: Usage.zero,
            stopReason: reason,
            timestamp: DateTime.now(),
          );
      final stream = AssistantMessageEventStream();
      if (calls == 1) {
        stream.push(
          DoneEvent(
            reason: StopReason.toolUse,
            message: msg(
              const ToolCall(id: 'tc-2', name: 'echo', arguments: {}),
              StopReason.toolUse,
            ),
          ),
        );
      } else {
        stream.push(
          DoneEvent(
            reason: StopReason.stop,
            message: msg(const TextContent(text: 'continued'), StopReason.stop),
          ),
        );
      }
      stream.end();
      return stream;
    }

    final model = Model(
      id: 'test-model',
      name: 'test-model',
      api: 'anthropic-messages',
      provider: 'test',
      baseUrl: 'http://localhost:1',
      contextWindow: 8192,
      maxTokens: 4096,
    );
    final state = AgentState(
      model: model,
      messages: await session.buildContextMessages(),
      systemPrompt: '',
    );
    final hooks = _Hooks();
    final ok = await AutoCompactorFactory(
      session: session,
      state: state,
      window: 8192,
      settings: CompactionSettings.forWindow(8192),
      sources: AutoCompactorSources(
        smolStream: null,
        smolModel: null,
        mainStream: fake,
        mainModel: model,
      ),
      hooks: hooks,
      prompts: const CompactionPrompts(),
      engine: CompactionEngine.structured,
    ).run();
    // ignore: avoid_print
    print('PROBE run()=$ok streamCalls=$calls');
    for (final p in hooks.passes) {
      // ignore: avoid_print
      print(
          'PROBE pass=${p.pass} ok=${p.ok} fallback=${p.fallback} '
          'before=${p.tokensBefore} after=${p.tokensAfter} '
          'err=${p.error} summaryLen=${p.summary?.length}');
    }
    final entries = await session.getEntries();
    final ckpts = entries.whereType<CompactionRecord>().length;
    // ignore: avoid_print
    print('PROBE session: ${entries.length} records, $ckpts compactionRecords');
    expect(ok, isTrue, reason: 'relief must land: the app turn continues');
  });
}

final class _Hooks implements AutoCompactorHooks {
  final passes = <AutoCompactorPass>[];
  @override
  void onPass(AutoCompactorPass pass) => passes.add(pass);
  @override
  void onRetry(int attempt, int maxAttempts, Duration backoff, Object error) {}
  @override
  void onDone(int passes, int tokens) {}
  @override
  void onBothRolesFailed(Object lastError) {}
  @override
  void onDelta(String delta) {}
  @override
  void onAttemptStart(String label, int attempt, Duration budget) {}
}
