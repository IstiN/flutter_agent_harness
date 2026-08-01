// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/widgets/chat_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

StreamFunction _singleTextResponse(String text) {
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    final message = AssistantMessage(
      content: [TextContent(text: text)],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.now(),
    );
    stream.push(DoneEvent(reason: StopReason.stop, message: message));
    stream.end();
    return stream;
  };
}

StreamFunction _hungResponse() {
  fn(Model model, dynamic context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    final partial = AssistantMessage(
      content: const [],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime(2026),
    );
    stream.push(StartEvent(partial: partial));
    cancelToken?.onCancel.then((_) {
      stream.push(
        ErrorEvent(
          reason: StopReason.aborted,
          error: partial.copyWith(
            stopReason: StopReason.aborted,
            errorMessage: 'Operation aborted',
          ),
        ),
      );
      stream.end();
    });
    return stream; // stays open until aborted
  }

  return fn;
}

AgentService _fakeService(ExecutionEnv env, StreamFunction streamFunction) {
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
      streamFunction: streamFunction,
      toolRegistry: ToolRegistry(const []),
    ),
    env: env,
    sessionsRoot: '/sessions',
  );
}

Future<void> _pumpComposer(WidgetTester tester, AgentService service) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFahTheme(),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: ChatComposer(service: service)),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _typeAndSend(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
  await tester.tap(find.byIcon(Icons.send));
  await tester.pump();
}

/// The composer's `_send` → `service.sendText` future chain runs on whatever
/// zone the tap happened in; the fake widget-test zone never advances those
/// futures, so the send and the waits ride ONE runAsync block (real event
/// loop + real delays, the js_app_chrome_test pattern).
void main() {
  testWidgets('send while IDLE starts a run that completes (never aborted '
      'by the steer logic — the "empty session" regression)', (tester) async {
    final env = MemoryExecutionEnv();
    final service = _fakeService(env, _singleTextResponse('the answer'));
    addTearDown(service.dispose);
    await service.initialize();
    await _pumpComposer(tester, service);

    await tester.runAsync(() async {
      await _typeAndSend(tester, 'hello there');
      for (
        var i = 0;
        i < 100 && service.messages.where((m) => m.role == 'assistant').isEmpty;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pump();

    expect(
      service.messages.where((m) => m.role == 'user').map((m) => m.content),
      contains('hello there'),
    );
    expect(service.messages.last.role, 'assistant');
    expect(service.messages.last.content, 'the answer');
    expect(service.messages.where((m) => m.isError), isEmpty);
    expect(service.isStreaming, isFalse);
  });

  testWidgets('send while STREAMING interrupts the in-flight turn and the '
      'follow-up gets its own run', (tester) async {
    final env = MemoryExecutionEnv();
    var call = 0;
    streams(Model model, dynamic context, {cancelToken}) {
      call++;
      if (call == 1) {
        return _hungResponse()(model, context, cancelToken: cancelToken);
      }
      return _singleTextResponse('follow-up answer')(
        model,
        context,
        cancelToken: cancelToken,
      );
    }

    final service = _fakeService(env, streams);
    addTearDown(service.dispose);
    await service.initialize();
    await _pumpComposer(tester, service);

    // Start a long run through the composer, then send a second message
    // mid-flight: it must interrupt (abort) the first turn and run itself.
    await tester.runAsync(() async {
      await _typeAndSend(tester, 'long task');
      for (var i = 0; i < 100 && call == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
    });
    expect(call, 1);
    expect(service.isStreaming, isTrue);

    await tester.runAsync(() async {
      await _typeAndSend(tester, 'actually, follow up');
      for (var i = 0; i < 200 && (call < 2 || service.isStreaming); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
    });
    await tester.pump();

    expect(call, 2);
    expect(service.messages.last.role, 'assistant');
    expect(service.messages.last.content, 'follow-up answer');
  });
}
