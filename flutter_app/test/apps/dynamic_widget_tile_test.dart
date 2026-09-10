// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/dynamic_messages.dart';
import 'package:fa/apps/dynamic_messages_sheet.dart';
import 'package:fa/apps/dynamic_widget_tile.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa_ui/fa_ui.dart' show FaChatMessage;
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Widget tests for the dynamic-message surfaces (issue #102): the inline
/// transcript tile (AC9 error tile, collapse, save-as-app, live badge) and
/// the ✦ list sheet (AC5 rows, jump-to-message, archive action).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  DynamicMessageDefinition definition(
    String id, {
    String title = 'Checklist',
  }) => DynamicMessageDefinition(
    id: id,
    title: title,
    jsSource: 'jsr.render({type:"text",data:"x"});',
    createdAt: DateTime(2026, 9, 10, 12, 30),
  );

  DynamicMessagesService service() => DynamicMessagesService(
    env: MemoryExecutionEnv(),
    sendText: (_) async {},
    sessionIdOf: () => 's1',
    sessionFileOf: () => 'sessions/s1.json',
    mediaGatewayOf: () => null,
    videoReaderOf: () => null,
    hostSecretsOf: () => const {},
    llmHandlerOf: () => null,
    asrTranscriberOf: () async => null,
  );

  /// An engine shell good enough for the tile's seams (live badge, null
  /// tree): never started, so no JS runtime is needed.
  JsAppEngine engine(DynamicMessageDefinition def) => JsAppEngine(
    app: JsAppInfo.fromManifest(
      {'id': def.id, 'name': def.title, 'version': '1.0.0'},
      bundled: false,
      fallbackId: def.id,
    ),
    env: MemoryExecutionEnv(),
    permissions: const AppPermissions(),
  );

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
      stream.push(
        DoneEvent(
          reason: StopReason.stop,
          message: AssistantMessage(
            content: [TextContent(text: 'ok')],
            api: model.api,
            provider: model.provider,
            model: model.id,
            usage: Usage.zero,
            stopReason: StopReason.stop,
            timestamp: DateTime.now(),
          ),
        ),
      );
      stream.end();
      return stream;
    },
    toolRegistry: ToolRegistry(const []),
  );

  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  Future<void> pumpTile(
    WidgetTester tester,
    DynamicMessagesService dm,
    String widgetId, {
    Future<void> Function(DynamicMessageDefinition definition)? onSaveAsApp,
  }) async {
    await tester.pumpWidget(
      host(
        DynamicWidgetTile(
          service: dm,
          message: FaChatMessage(role: 'widget', content: '', data: widgetId),
          onSaveAsApp: onSaveAsApp,
        ),
      ),
    );
    await tester.pump();
  }

  group('DynamicWidgetTile', () {
    testWidgets('unknown widget id renders nothing', (tester) async {
      await pumpTile(tester, service(), 'dm-missing');
      expect(find.text('Checklist'), findsNothing);
    });

    testWidgets('boot failure renders the AC9 error tile', (tester) async {
      final dm = service();
      final def = definition('dm-1');
      dm.debugAdd(def, engine: engine(def), bootError: 'SyntaxError: {{{');
      await pumpTile(tester, dm, 'dm-1');
      expect(find.text('Widget error'), findsOneWidget);
      expect(find.textContaining('SyntaxError'), findsOneWidget);
    });

    testWidgets('error detail collapses and re-expands', (tester) async {
      final dm = service();
      final def = definition('dm-1');
      dm.debugAdd(def, engine: engine(def), bootError: 'boom');
      await pumpTile(tester, dm, 'dm-1');
      await tester.tap(find.byTooltip('Widget error'));
      await tester.pump();
      expect(find.text('boom'), findsNothing);
      await tester.tap(find.byTooltip('Widget error'));
      await tester.pump();
      expect(find.text('boom'), findsOneWidget);
    });

    testWidgets('collapse hides the body, expand restores it', (tester) async {
      final dm = service();
      final def = definition('dm-1');
      dm.debugAdd(def, engine: engine(def));
      await pumpTile(tester, dm, 'dm-1');
      // No tree yet (engine not started): the body shows the boot spinner.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.text('Checklist'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.tap(find.text('Checklist'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('live badge marks a widget with a running engine', (
      tester,
    ) async {
      final dm = service();
      final def = definition('dm-1');
      dm.debugAdd(def, engine: engine(def));
      await pumpTile(tester, dm, 'dm-1');
      expect(find.byType(DynamicLiveBadge), findsOneWidget);
    });

    testWidgets('save-as-app hands the definition to the host', (tester) async {
      final dm = service();
      final def = definition('dm-1');
      dm.debugAdd(def, engine: engine(def));
      DynamicMessageDefinition? saved;
      await pumpTile(tester, dm, 'dm-1', onSaveAsApp: (d) async => saved = d);
      await tester.tap(find.byTooltip('Save as app'));
      await tester.pump();
      expect(saved?.id, 'dm-1');
    });
  });

  group('DynamicMessagesSheet', () {
    Future<(AgentService, DynamicMessagesService)> makeService() async {
      final agentService = AgentService(
        agent: agent(),
        env: MemoryExecutionEnv(),
        sessionsRoot: '/sessions',
      );
      // Wires the tool registry and the dynamic-messages host service.
      await agentService.initialize();
      return (agentService, agentService.dynamicMessages);
    }

    Future<void> pumpSheet(
      WidgetTester tester,
      AgentService agentService, {
      Future<void> Function(DynamicMessageDefinition definition)? onSaveAsApp,
    }) async {
      await tester.pumpWidget(
        host(
          DynamicMessagesSheet(
            service: agentService,
            onSaveAsApp: onSaveAsApp ?? (_) async {},
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('lists every widget with event count and live badge', (
      tester,
    ) async {
      final (agentService, dm) = await makeService();
      final live = definition('dm-1', title: 'Chart');
      dm.debugAdd(live, engine: engine(live));
      dm.debugAdd(definition('dm-2', title: 'List'));
      await pumpSheet(tester, agentService);
      expect(find.text('Dynamic messages'), findsOneWidget);
      expect(find.text('Chart'), findsOneWidget);
      expect(find.text('List'), findsOneWidget);
      expect(find.textContaining('0 events'), findsNWidgets(2));
      expect(find.byType(DynamicLiveBadge), findsOneWidget);
    });

    testWidgets('tap jumps to the widget transcript position', (tester) async {
      final (agentService, dm) = await makeService();
      dm.debugAdd(definition('dm-1'));
      String? jumped;
      agentService.scrollToMessageHandler = (messageId) => jumped = messageId;
      await pumpSheet(tester, agentService);
      await tester.tap(find.text('Checklist'));
      await tester.pump();
      expect(jumped, 'msg-0');
    });

    testWidgets('archive pops the sheet and graduates the widget', (
      tester,
    ) async {
      final (agentService, dm) = await makeService();
      dm.debugAdd(definition('dm-1'));
      DynamicMessageDefinition? saved;
      await pumpSheet(
        tester,
        agentService,
        onSaveAsApp: (d) async => saved = d,
      );
      await tester.tap(find.byTooltip('Save as app'));
      await tester.pump();
      expect(saved?.id, 'dm-1');
    });
  });
}
