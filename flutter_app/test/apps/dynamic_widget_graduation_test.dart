// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/apps/dynamic_widget_graduation.dart';
import 'package:fa/apps/dynamic_messages.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

AgentService _service() {
  Agent agent() => Agent(
    model: Model(
      id: 'test-model',
      api: 'test-api',
      provider: 'test',
      baseUrl: 'https://example.com',
      contextWindow: 100000,
      maxTokens: 4096,
    ),
    systemPrompt: 'Fa.',
    streamFunction: (model, context, {cancelToken}) {
      final stream = AssistantMessageEventStream();
      stream.end();
      return stream;
    },
    toolRegistry: ToolRegistry(const []),
  );
  return AgentService(
    agent: agent(),
    env: MemoryExecutionEnv(),
    sessionsRoot: '/sessions',
  );
}

DynamicMessageDefinition definition(String title) =>
    DynamicMessageDefinition(
      id: 'def-1',
      title: title,
      jsSource: 'jsr.render({type:"text",data:"hi"});',
      createdAt: DateTime.utc(2026, 2, 1, 12),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('installGraduatedWidget', () {
    test('installs under the slugified title', () async {
      final service = _service();
      addTearDown(service.dispose);
      final appId = await installGraduatedWidget(service, definition('Pomo'));

      expect(appId, 'pomo');
      expect(
        (await service.env.readTextFile('apps/pomo/manifest.json'))
            .valueOrNull,
        isNotNull,
      );
    });

    test('a taken title retries numbered suffixes', () async {
      final service = _service();
      addTearDown(service.dispose);
      await service.initialize();

      expect(await installGraduatedWidget(service, definition('Pomo')), 'pomo');
      // Same title again: `pomo` exists → the install lands on `pomo-2`.
      expect(await installGraduatedWidget(service, definition('Pomo')),
          'pomo-2');
      expect(
        (await service.env.readTextFile('apps/pomo/manifest.json'))
            .valueOrNull,
        isNotNull,
      );
      expect(
        (await service.env.readTextFile('apps/pomo-2/manifest.json'))
            .valueOrNull,
        isNotNull,
      );
    });

    test('gives up with null after all nine suffixes are taken', () async {
      final service = _service();
      addTearDown(service.dispose);
      await service.initialize();

      // Exhaust pomo, pomo-2 .. pomo-9 (nine installs, same title).
      for (var i = 0; i < 9; i++) {
        expect(
          await installGraduatedWidget(service, definition('Pomo')),
          isNotNull,
        );
      }
      expect(
        await installGraduatedWidget(service, definition('Pomo')),
        isNull,
      );
    });
  });

  group('showGraduationSnackbar', () {
    Future<void> pumpHost(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showGraduationSnackbar(context, 'pomo'),
                child: const Text('save'),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('a saved install names the new app id', (tester) async {
      await pumpHost(tester);
      await tester.tap(find.text('save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('pomo'), findsOneWidget);

      // Let the snackbar dismiss so its timer is not left pending.
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a failed install shows the failure line', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showGraduationSnackbar(context, null),
                child: const Text('save'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.text('Could not save this dynamic message as an app.'),
        findsOneWidget,
      );

      // Let the snackbar dismiss so its timer is not left pending.
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
