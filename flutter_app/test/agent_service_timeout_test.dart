// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa/agent_service.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Real-time watchdog tests: a short injected `responseTimeout` lets us
/// exercise the idle watchdog without fake-time/async interop issues.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AssistantMessage msg(String t, Model m) => AssistantMessage(
    content: [TextContent(text: t)],
    api: m.api,
    provider: m.provider,
    model: m.id,
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.now(),
  );

  AgentService build(StreamFunction fn, Duration timeout) {
    return AgentService(
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
      responseTimeout: timeout,
    );
  }

  /// A stream that emits [tickCount] deltas spaced by [tickPeriod] and then
  /// stays open forever.
  StreamFunction ticks(int tickCount, Duration tickPeriod) {
    return (model, context, {cancelToken}) {
      final stream = AssistantMessageEventStream();
      var sent = 0;
      // The agent loop forwards mid-stream events only after a StartEvent
      // (partial-first invariant), so open with one.
      stream.push(StartEvent(partial: msg('', model)));
      void tick() {
        if (sent >= tickCount) return;
        sent++;
        stream.push(
          TextDeltaEvent(
            contentIndex: 0,
            delta: 'x',
            partial: msg('x' * sent, model),
          ),
        );
        Timer(tickPeriod, tick);
      }

      Timer(Duration.zero, tick);
      return stream;
    };
  }

  const idle = Duration(milliseconds: 400);

  test('idle watchdog aborts a run that goes silent', () async {
    final service = build(ticks(1, Duration.zero), idle);
    addTearDown(service.dispose);

    await service.sendText('hi');
    expect(service.isStreaming, isTrue);
    await Future<void>.delayed(idle + idle);
    expect(service.isStreaming, isFalse);
    expect(service.error, contains('stopped responding'));
  });

  test('activity rearms the watchdog — long runs survive', () async {
    // Ticks every 200 ms for 1.2 s: three idle windows back to back — the
    // old whole-run timeout would have aborted at 400 ms.
    final service = build(ticks(6, const Duration(milliseconds: 200)), idle);
    addTearDown(service.dispose);

    await service.sendText('hi');
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(service.isStreaming, isTrue);
    expect(service.error, isNull);

    // After the ticks stop, the idle window expires and the run aborts.
    await Future<void>.delayed(idle + const Duration(milliseconds: 300));
    expect(service.isStreaming, isFalse);
    expect(service.error, contains('stopped responding'));
  });
}
