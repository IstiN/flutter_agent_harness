// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-2472 — the model-facing `m<N>` record tags a model echoes into its
/// replies never reach the app's chat. The streamed deltas are sanitized
/// at the ingestion seam (a tag split across deltas — `m14` then `82
/// При…` — never flickers a fragment into the live bubble) and the
/// finalized row renders the clean text (the agent's persist-side echo
/// seam supplies it, as in production under the structured engine).
///
/// Plain async tests: the service is a ChangeNotifier with no widget
/// binding, and the gated mid-stream observation needs REAL timers — the
/// testWidgets/runAsync zone wedged on them.
library;

import 'dart:async';

import 'package:fa/services/agent_service.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

AssistantMessage _msg(List<ContentBlock> content, Model m) => AssistantMessage(
  content: content,
  api: m.api,
  provider: m.provider,
  model: m.id,
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime.now(),
);

AgentService _service(StreamFunction streamFn) => AgentService(
  agent: Agent(
    model: Model(
      id: 'test-model',
      api: 'test-api',
      provider: 'test',
      baseUrl: 'https://example.com',
      contextWindow: 100000,
      maxTokens: 4096,
    ),
    systemPrompt: 'You are Fa.',
    streamFunction: streamFn,
    toolRegistry: ToolRegistry(const []),
  ),
  env: MemoryExecutionEnv(),
  sessionsRoot: '/sessions',
  config: AgentConfig(
    providerKind: 'test',
    modelId: 'test-model',
    baseUrl: 'https://example.com',
    apiKey: '',
  ),
);

/// Waits until [condition] holds (2ms polls, 15s cap).
Future<void> _waitFor(bool Function() condition) async {
  for (var i = 0; i < 7500 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

FahChatMessage? _assistantRow(AgentService service) => service.messages
    .where((m) => m.role == 'assistant')
    .firstOrNull;

void main() {
  test('a tag split across deltas never flickers into the bubble', () async {
    final releaseSecond = Completer<void>();
    AssistantMessageEventStream? live;

    // The turn streams `m1482 Принято…` in two fragments; the gate holds
    // the stream open after the first so the test can observe the live
    // bubble before the rest arrives.
    AssistantMessageEventStream fn(
      Model model,
      Context context, {
      CancelToken? cancelToken,
    }) {
      final stream = AssistantMessageEventStream();
      live = stream;
      stream
        ..push(StartEvent(partial: _msg(const [], model)))
        ..push(
          TextDeltaEvent(
            contentIndex: 0,
            delta: 'm14',
            partial: _msg([const TextContent(text: 'm14')], model),
          ),
        );
      unawaited(
        releaseSecond.future.then((_) {
          final full = _msg([const TextContent(text: 'm1482 Принято…')], model);
          stream
            ..push(
              TextDeltaEvent(
                contentIndex: 0,
                delta: '82 Принято…',
                partial: full,
              ),
            )
            ..push(DoneEvent(reason: StopReason.stop, message: full));
          stream.end();
        }),
      );
      return stream;
    }

    final service = _service(fn);
    // Production runs with the structured engine's record tags on: the
    // finalize seam strips the echoed tag from the completed message.
    service.agentForTest.recordTagsEnabled = true;

    final sending = service.sendText('question');
    await _waitFor(() => _assistantRow(service) != null);
    // The held fragment must not have flickered into the live bubble.
    final streamed = _assistantRow(service)!.content;
    releaseSecond.complete();
    await sending.timeout(const Duration(seconds: 30));
    await service.waitForIdle();

    expect(
      streamed.contains('m14'),
      isFalse,
      reason: 'the held tag fragment flickered: "$streamed"',
    );
    expect(_assistantRow(service)!.content, 'Принято…');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('an undecided tail survives verbatim (regex contract)', () async {
    // `ответ\nm2` — the trailing `m2` has no space after the digits, so
    // `^m\d+ +` never matched: the bytes are the model's own words.
    AssistantMessageEventStream fn(
      Model model,
      Context context, {
      CancelToken? cancelToken,
    }) {
      final partial = _msg([const TextContent(text: 'ответ\nm2')], model);
      final stream = AssistantMessageEventStream();
      stream
        ..push(StartEvent(partial: _msg(const [], model)))
        ..push(
          TextDeltaEvent(contentIndex: 0, delta: 'ответ\nm2', partial: partial),
        )
        ..push(DoneEvent(reason: StopReason.stop, message: partial));
      stream.end();
      return stream;
    }

    final service = _service(fn);
    service.agentForTest.recordTagsEnabled = true;

    await service.sendText('question');
    await service.waitForIdle();

    expect(_assistantRow(service)!.content, contains('m2'));
  }, timeout: const Timeout(Duration(seconds: 60)));
}
