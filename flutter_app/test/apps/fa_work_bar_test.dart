// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/agent_service.dart';
import 'package:fa/apps/fa_work_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  AgentService hungService() {
    fn(Model model, dynamic context, {cancelToken}) {
      final stream = AssistantMessageEventStream();
      final partial = AssistantMessage(
        content: const [],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage.zero,
        stopReason: StopReason.stop,
        timestamp: DateTime.now(),
      );
      stream.push(StartEvent(partial: partial));
      // Honor aborts like a real provider would (close with an aborted error).
      cancelToken?.onCancel.then((_) {
        stream.push(ErrorEvent(reason: StopReason.aborted, error: partial));
        stream.end();
      });
      return stream; // stays open until aborted
    }

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
        systemPrompt: 'You are Fa.',
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
  }

  testWidgets('work bar shows while streaming, hides when idle, stops on tap', (
    tester,
  ) async {
    final service = hungService();
    addTearDown(service.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FaWorkBar(service: service)),
      ),
    );
    // Idle: the bar is hidden.
    expect(find.byIcon(Icons.stop_circle_outlined), findsNothing);

    await tester.runAsync(() async {
      await service.sendText('work');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(service.isStreaming, isTrue);
    expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);
    expect(find.text('Fa is working…'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.stop_circle_outlined));
    for (var i = 0; i < 30 && service.isStreaming; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
    }
    await tester.pump();
    expect(service.isStreaming, isFalse);
    expect(find.byIcon(Icons.stop_circle_outlined), findsNothing);
  });

  testWidgets('orbit spins while streaming, stops when idle', (tester) async {
    final service = hungService();
    addTearDown(service.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FaWorkBar(service: service)),
      ),
    );
    final state = tester.state(find.byType(FaWorkBar));
    final orbit =
        (state as dynamic).debugOrbitController as AnimationController;
    // Idle: no ticker running, no indicator in the tree.
    expect(orbit.isAnimating, isFalse);
    expect(find.byKey(const ValueKey('faWorkBarOrbit')), findsNothing);

    await tester.runAsync(() async {
      await service.sendText('work');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(service.isStreaming, isTrue);
    expect(orbit.isAnimating, isTrue);

    // The comet actually moves between frames.
    double cometProgress() {
      final paint = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byKey(const ValueKey('faWorkBarOrbit')),
          matching: find.byType(CustomPaint),
        ),
      );
      return (paint.painter as dynamic).progress as double;
    }

    await tester.pump(const Duration(milliseconds: 300));
    final a = cometProgress();
    await tester.pump(const Duration(milliseconds: 300));
    final b = cometProgress();
    expect(b, isNot(a));

    // Back to idle: the orbit halts (and the bar hides).
    await tester.runAsync(() async {
      service.abort();
      for (var i = 0; i < 30 && service.isStreaming; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    });
    await tester.pump();
    expect(service.isStreaming, isFalse);
    expect(orbit.isAnimating, isFalse);
  });

  testWidgets('pull-up past the threshold triggers expand', (tester) async {
    final service = hungService();
    addTearDown(service.dispose);
    var expanded = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: FaWorkBar(service: service, onExpand: () => expanded++),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await service.sendText('work');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    // A short pull below the threshold only stretches the bar.
    await tester.drag(
      find.byKey(const ValueKey('faWorkBarHandle')),
      const Offset(0, -30),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(expanded, 0);

    // A full pull-up expands (same action as the expand button).
    await tester.drag(
      find.byKey(const ValueKey('faWorkBarHandle')),
      const Offset(0, -120),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(expanded, 1);
  });

  testWidgets('pull-down past the threshold triggers collapse', (tester) async {
    final service = hungService();
    addTearDown(service.dispose);
    var collapsed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: FaWorkBar(
              service: service,
              onExpand: () {},
              onCollapse: () => collapsed++,
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await service.sendText('work');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    await tester.drag(
      find.byKey(const ValueKey('faWorkBarHandle')),
      const Offset(0, 120),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(collapsed, 1);
  });

  testWidgets('follow-up input sends the message', (tester) async {
    final service = hungService();
    addTearDown(service.dispose);
    final sent = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FaWorkBar(
            service: service,
            onSend: (text) async => sent.add(text),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await service.sendText('work');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'make it purple');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    expect(sent, ['make it purple']);
  });
}
