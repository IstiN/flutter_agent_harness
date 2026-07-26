// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/services/agent_service.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_view.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// A service whose scripted provider answers each run with the next reply
/// text: the stream emits the done message and closes, so every `sendText`
/// completes a full run (streaming → idle) with one assistant text message.
AgentService _scriptedService(List<String> replies) {
  var call = 0;
  fn(Model model, dynamic context, {cancelToken}) {
    final text = replies[call < replies.length ? call : replies.length - 1];
    call++;
    final stream = AssistantMessageEventStream();
    final message = AssistantMessage(
      content: [TextContent(text: text)],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime(2026, 1, 1),
    );
    stream.push(StartEvent(partial: message));
    stream.push(DoneEvent(reason: StopReason.stop, message: message));
    stream.end();
    return stream;
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
}

const _icon =
    "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'>"
    "<circle cx='12' cy='12' r='10' fill='#4F8CFF'/></svg>";

/// Pumps a real [JsAppView] (manifest without widget.js: the engine fails
/// to boot deterministically, but the Fa chrome — work bar, reply sheet —
/// renders regardless) wired to [service].
Future<void> _pumpView(WidgetTester tester, AgentService service) async {
  final env = MemoryExecutionEnv();
  await env.writeFile(
    'apps/demo/manifest.json',
    jsonEncode(const {'id': 'demo', 'name': 'Demo', 'icon': _icon}),
  );
  final permissions = await AppPermissionsStore.load(env);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: JsAppView(
        app: JsAppInfo.fromManifest(
          const {'id': 'demo', 'name': 'Demo', 'icon': _icon},
          bundled: false,
          fallbackId: 'demo',
        ),
        env: env,
        permissionsStore: permissions,
        onSendToAgent: (message) async {
          await service.sendText(message.text);
          return service;
        },
        agentService: service,
      ),
    ),
  );
  await tester.pump();
}

/// Runs one scripted question to completion and lets the reply sheet's
/// entrance animation finish.
Future<void> _completeRun(WidgetTester tester, AgentService service) async {
  await tester.runAsync(() async {
    await service.sendText('make it purple');
    for (var i = 0; i < 20 && service.isStreaming; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  });
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

void main() {
  testWidgets('reply sheet is hidden initially', (tester) async {
    final service = _scriptedService(const ['Done — now purple.']);
    addTearDown(service.dispose);
    await _pumpView(tester, service);
    expect(find.byType(FaReplySheet), findsNothing);
  });

  testWidgets('completed run with a new assistant text shows the sheet', (
    tester,
  ) async {
    final service = _scriptedService(const ['Done — the buttons are purple.']);
    addTearDown(service.dispose);
    await _pumpView(tester, service);
    expect(service.isStreaming, isFalse);

    await _completeRun(tester, service);

    expect(find.byType(FaReplySheet), findsOneWidget);
    expect(find.textContaining('buttons are purple'), findsOneWidget);
  });

  testWidgets('dismiss hides the sheet and it stays hidden for that reply', (
    tester,
  ) async {
    final service = _scriptedService(const ['Done — the buttons are purple.']);
    addTearDown(service.dispose);
    await _pumpView(tester, service);
    await _completeRun(tester, service);
    expect(find.byType(FaReplySheet), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.byType(FaReplySheet), findsNothing);

    // Later service activity without a new assistant message must NOT
    // resurrect the dismissed reply.
    service.setApprovalMode(ApprovalMode.yolo);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(FaReplySheet), findsNothing);
  });

  testWidgets('sending a new message hides the sheet; the new reply shows', (
    tester,
  ) async {
    // Controllable provider: each run starts streaming immediately and
    // stays open until the test pushes the done message.
    final streams = <AssistantMessageEventStream>[];
    fn(Model model, dynamic context, {cancelToken}) {
      final stream = AssistantMessageEventStream();
      streams.add(stream);
      stream.push(
        StartEvent(
          partial: AssistantMessage(
            content: const [],
            api: model.api,
            provider: model.provider,
            model: model.id,
            usage: Usage.zero,
            stopReason: StopReason.stop,
            timestamp: DateTime(2026, 1, 1),
          ),
        ),
      );
      return stream;
    }

    AssistantMessage doneMessage(String text) => AssistantMessage(
      content: [TextContent(text: text)],
      api: 'test-api',
      provider: 'test',
      model: 'test-model',
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime(2026, 1, 1),
    );

    Future<void> finishLastRun(AgentService service, String text) async {
      await tester.runAsync(() async {
        streams.last
          ..push(DoneEvent(reason: StopReason.stop, message: doneMessage(text)))
          ..end();
        for (var i = 0; i < 20 && service.isStreaming; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
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
    addTearDown(service.dispose);
    await _pumpView(tester, service);

    // First run: streaming shows no sheet, completion shows the reply.
    await tester.runAsync(() async {
      await service.sendText('make it purple');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(service.isStreaming, isTrue);
    expect(find.byType(FaReplySheet), findsNothing);

    await finishLastRun(service, 'Done — the buttons are purple.');
    expect(find.byType(FaReplySheet), findsOneWidget);
    expect(find.textContaining('buttons are purple'), findsOneWidget);

    // A new message: the sheet hides at once and the work bar takes over.
    await tester.runAsync(() async {
      await service.sendText('make them teal');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(service.isStreaming, isTrue);
    expect(find.byType(FaReplySheet), findsNothing);
    expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);

    // The new run's reply replaces the old one.
    await finishLastRun(service, 'Done — the buttons are teal.');
    expect(find.textContaining('buttons are purple'), findsNothing);
    expect(find.byType(FaReplySheet), findsOneWidget);
    expect(find.textContaining('buttons are teal'), findsOneWidget);
  });

  testWidgets('tapping the card expands to the chat (pops the app view)', (
    tester,
  ) async {
    final service = _scriptedService(const ['Done — the buttons are purple.']);
    addTearDown(service.dispose);
    final env = MemoryExecutionEnv();
    await env.writeFile(
      'apps/demo/manifest.json',
      jsonEncode(const {'id': 'demo', 'name': 'Demo', 'icon': _icon}),
    );
    final permissions = await AppPermissionsStore.load(env);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => JsAppView(
                      app: JsAppInfo.fromManifest(
                        const {'id': 'demo', 'name': 'Demo', 'icon': _icon},
                        bundled: false,
                        fallbackId: 'demo',
                      ),
                      env: env,
                      permissionsStore: permissions,
                      onSendToAgent: (message) async {
                        await service.sendText(message.text);
                        return service;
                      },
                      agentService: service,
                    ),
                  ),
                ),
                child: const Text('open app'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open app'));
    await tester.pumpAndSettle();
    expect(find.byType(JsAppView), findsOneWidget);

    await _completeRun(tester, service);
    expect(find.byType(FaReplySheet), findsOneWidget);

    // Tap the card body (not the close button): same navigation as the
    // work bar's expand.
    await tester.tap(find.textContaining('buttons are purple'));
    await tester.pumpAndSettle();
    expect(find.byType(JsAppView), findsNothing);
  });

  testWidgets('send rebinds the Fa chrome to the session that received it', (
    tester,
  ) async {
    // First-contact flow: the view opened with the ACTIVE session, but the
    // forwarder created/used the app's bound session — the reply sheet must
    // follow the bound session, not the one passed at construction.
    final activeService = _scriptedService(const ['active reply']);
    final boundService = _scriptedService(const ['bound reply']);
    addTearDown(activeService.dispose);
    addTearDown(boundService.dispose);
    final env = MemoryExecutionEnv();
    await env.writeFile(
      'apps/demo/manifest.json',
      jsonEncode(const {'id': 'demo', 'name': 'Demo', 'icon': _icon}),
    );
    final permissions = await AppPermissionsStore.load(env);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: JsAppView(
          app: JsAppInfo.fromManifest(
            const {'id': 'demo', 'name': 'Demo', 'icon': _icon},
            bundled: false,
            fallbackId: 'demo',
          ),
          env: env,
          permissionsStore: permissions,
          agentService: activeService,
          onSendToAgent: (message) async {
            await boundService.sendText(message.text);
            return boundService;
          },
        ),
      ),
    );
    await tester.pump();

    await tester.runAsync(() async {
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextField), 'make it teal');
      await tester.pump();
      await tester.tap(find.byType(FilledButton));
      // The send path's screenshot capture times out (5 s real) in the test
      // environment before the forwarder runs — wait it out, then let the
      // scripted run finish.
      for (var i = 0; i < 70; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byType(FaReplySheet), findsOneWidget);
    expect(find.textContaining('bound reply'), findsOneWidget);
  });
}
