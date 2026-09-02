// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/tool_phase_labels.dart';
import 'package:test/test.dart';

Agent _agent() => Agent(
  model: Model(
    id: 'test-model',
    api: 'test-api',
    provider: 'test',
    baseUrl: 'https://example.com',
    contextWindow: 100000,
    maxTokens: 4096,
  ),
  systemPrompt: 'test',
  streamFunction: (model, context, {cancelToken}) =>
      throw UnimplementedError('never streams in hook tests'),
  toolRegistry: ToolRegistry(const []),
);

AssistantMessage _assistant() => AssistantMessage(
  content: const [],
  api: 'test-api',
  provider: 'test',
  model: 'test-model',
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime.now(),
);

BeforeToolCallContext _beforeContext(String toolName) => BeforeToolCallContext(
  assistantMessage: _assistant(),
  toolCall: ToolCall(id: 'call-1', name: toolName, arguments: const {}),
  context: Context(messages: const []),
);

AfterToolCallContext _afterContext(String toolName) => AfterToolCallContext(
  assistantMessage: _assistant(),
  toolCall: ToolCall(id: 'call-1', name: toolName, arguments: const {}),
  result: ToolExecutionResult.text('ok'),
  isError: false,
  context: Context(messages: const []),
);

void main() {
  group('attachToolPhaseLabels', () {
    test('labels the busy row with the running tool, then clears', () async {
      final agent = _agent();
      final phases = <String>[];
      attachToolPhaseLabels(agent, phases.add);

      final result = await agent.beforeToolCall!(_beforeContext('bash'), null);
      expect(result, isNull);
      expect(phases, ['Running bash…']);

      await agent.afterToolCall!(_afterContext('bash'), null);
      expect(phases, ['Running bash…', '']);
    });

    test(
      'a blocked call never relabels (denied tools stay invisible)',
      () async {
        final agent = _agent();
        agent.beforeToolCall = (context, cancelToken) async =>
            const BeforeToolCallResult(block: true, reason: 'denied');
        final phases = <String>[];
        attachToolPhaseLabels(agent, phases.add);

        final result = await agent.beforeToolCall!(
          _beforeContext('bash'),
          null,
        );
        expect(result?.block, isTrue);
        expect(phases, isEmpty);
      },
    );

    test('preserves prior hooks: before runs first, after runs last', () async {
      final agent = _agent();
      final order = <String>[];
      agent.beforeToolCall = (context, cancelToken) async {
        order.add('before');
        return null;
      };
      agent.afterToolCall = (context, cancelToken) async {
        order.add('after');
        return null;
      };
      attachToolPhaseLabels(agent, (phase) => order.add('phase:$phase'));

      await agent.beforeToolCall!(_beforeContext('read'), null);
      expect(order, ['before', 'phase:Running read…']);

      order.clear();
      await agent.afterToolCall!(_afterContext('read'), null);
      expect(order, ['phase:', 'after']);
    });

    test('null onPhase leaves the hooks untouched', () {
      final agent = _agent();
      attachToolPhaseLabels(agent, null);
      expect(agent.beforeToolCall, isNull);
      expect(agent.afterToolCall, isNull);
    });
  });
}
