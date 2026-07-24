// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/agent_service.dart';
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

void main() {
  testWidgets('thinking deltas stream live and finalize as thinking message', (
    tester,
  ) async {
    fn(Model model, dynamic context, {cancelToken}) {
      final stream = AssistantMessageEventStream();
      final thinking = _msg([const ThinkingContent(thinking: 'hmm…')], model);
      final full = _msg([
        const ThinkingContent(thinking: 'hmm… let me think'),
        const TextContent(text: 'the answer'),
      ], model);
      stream.push(StartEvent(partial: thinking));
      stream.push(
        ThinkingDeltaEvent(
          contentIndex: 0,
          delta: ' let me think',
          partial: thinking,
        ),
      );
      stream.push(
        TextDeltaEvent(contentIndex: 1, delta: 'the answer', partial: full),
      );
      stream.push(DoneEvent(reason: StopReason.stop, message: full));
      stream.end();
      return stream;
    }

    final service = AgentService(
      agent: Agent(
        model: Model(
          id: 'test-model',
          api: 'test-api',
          provider: 'test',
          baseUrl: 'https://example.com',
          contextWindow: 100000,
          maxTokens: 4096,
        ),
        systemPrompt: 'You are fah.',
        streamFunction: fn,
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

    await tester.runAsync(() async {
      await service.sendText('question');
      await service.waitForIdle();
    });
    await tester.pump();

    final roles = service.messages.map((m) => m.role).toList();
    expect(roles, containsAllInOrder(['user', 'thinking', 'assistant']));
    final thinking = service.messages.firstWhere((m) => m.role == 'thinking');
    expect(thinking.content, contains('let me think'));
    final answer = service.messages.firstWhere((m) => m.role == 'assistant');
    expect(answer.content, 'the answer');
  });
}
