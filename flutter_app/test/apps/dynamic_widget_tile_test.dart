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

  /// Opens the ⋮ overflow menu (issue #378) and settles its entrance.
  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byTooltip('More actions'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
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

    testWidgets('status renders as a live dot for a running engine '
        '(issue #457 AC2)', (tester) async {
      final dm = service();
      final def = definition('dm-1');
      dm.debugAdd(def, engine: engine(def));
      await pumpTile(tester, dm, 'dm-1');
      // The `● live` pill is minimized to a dot with a tooltip.
      expect(find.byType(DynamicLiveBadge), findsNothing);
      expect(find.byTooltip('live'), findsOneWidget);
    });

    testWidgets('save-as-app hands the definition to the host', (tester) async {
      final dm = service();
      final def = definition('dm-1');
      dm.debugAdd(def, engine: engine(def));
      DynamicMessageDefinition? saved;
      await pumpTile(tester, dm, 'dm-1', onSaveAsApp: (d) async => saved = d);
      await openMenu(tester);
      await tester.tap(find.text('Save as app').last);
      await tester.pump();
      expect(saved?.id, 'dm-1');
    });
    testWidgets('title bar shows the promoted open action, chevron and '
        'overflow (issue #457 AC2)', (tester) async {
      final dm = service();
      final def = definition('dm-1');
      dm.debugAdd(def, engine: engine(def));
      await pumpTile(tester, dm, 'dm-1', onSaveAsApp: (_) async {});
      // Exactly one ⋮; the old inline save/permissions icons stay gone;
      // the open action is now a primary header icon.
      expect(find.byTooltip('More actions'), findsOneWidget);
      expect(find.byTooltip('Open as app (without saving)'), findsOneWidget);
      expect(find.byIcon(Icons.archive_outlined), findsNothing);
      expect(find.byIcon(Icons.shield_outlined), findsNothing);
      await openMenu(tester);
      expect(find.text('Save as app'), findsOneWidget);
      expect(find.text('Open as app (without saving)'), findsOneWidget);
      expect(find.text('Permissions'), findsOneWidget);
    });

    testWidgets('unwired graduation hides the save row instead of '
        'greying it out (issue #457 AC3)', (tester) async {
      final dm = service();
      final def = definition('dm-1');
      dm.debugAdd(def, engine: engine(def));
      await pumpTile(tester, dm, 'dm-1');
      await openMenu(tester);
      expect(find.text('Save as app'), findsNothing);
      expect(find.text('Open as app (without saving)'), findsOneWidget);
      expect(find.text('Permissions'), findsOneWidget);
    });

    testWidgets('menu tap does not toggle collapse (issue #377)', (
      tester,
    ) async {
      final dm = service();
      final def = definition('dm-1');
      dm.debugAdd(def, engine: engine(def));
      await pumpTile(tester, dm, 'dm-1');
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await openMenu(tester);
      // The body survived the ⋮ tap: the menu never collapses the tile.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tapAt(const Offset(10, 10)); // dismiss the menu
      await tester.pump();
    });

    testWidgets('open-as-app pushes an ephemeral full-screen view', (
      tester,
    ) async {
      final dm = service();
      final def = definition('dm-1');
      final liveEngine = engine(def);
      dm.debugAdd(def, engine: liveEngine);
      await pumpTile(tester, dm, 'dm-1');
      await openMenu(tester);
      await tester.tap(find.text('Open as app (without saving)'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      // Full-screen route mounted, its app bar carries the widget title.
      expect(
        find.byKey(const ValueKey('ephemeral-dynamic-app')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('Checklist'),
        ),
        findsOneWidget,
      );
      // AC2: no graduation — the env never gains an apps/<id> entry.
      expect(
        (dm.env as FsSnapshotExporter).exportSnapshot().files.keys.where(
          (path) => path.contains('apps/'),
        ),
        isEmpty,
      );
      // AC2: the view reuses the tile's engine — no second runtime.
      expect(dm.engineFor('dm-1'), same(liveEngine));
      // Closing pops the route; the tile renders again underneath.
      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('ephemeral-dynamic-app')), findsNothing);
      expect(find.text('Checklist'), findsOneWidget);
    });

    testWidgets('failed boot disables open with a reason, save stays', (
      tester,
    ) async {
      final dm = service();
      final def = definition('dm-1');
      dm.debugAdd(def, engine: engine(def), bootError: 'boom');
      DynamicMessageDefinition? saved;
      await pumpTile(tester, dm, 'dm-1', onSaveAsApp: (d) async => saved = d);
      await openMenu(tester);
      // E1: Open ships the failure reason inline…
      expect(find.textContaining("Widget can't start"), findsOneWidget);
      // …and stays disabled: tapping it mounts no route.
      await tester.tap(find.text('Open as app (without saving)'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('ephemeral-dynamic-app')), findsNothing);
      // Save stays available: it works from the persisted definition.
      await tester.tap(find.text('Save as app'));
      await tester.pump();
      expect(saved?.id, 'dm-1');
    });

    testWidgets('overflow stays reachable at a narrow phone width', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final dm = service();
      final def = definition('dm-1');
      dm.debugAdd(def, engine: engine(def));
      await pumpTile(tester, dm, 'dm-1');
      await tester.ensureVisible(find.byTooltip('More actions'));
      await tester.tap(find.byTooltip('More actions'), warnIfMissed: false);
      await tester.pump();
      expect(find.text('Open as app (without saving)'), findsOneWidget);
    });
  });

  group('issue #457', () {
    /// A widget fixture taller than any canvas: a 900px-declared box
    /// (E1 — the widget's own fixed height) of rows ending in one
    /// button control.
    Map<String, dynamic> tallTree() => {
      'type': 'sizedBox',
      'height': 900,
      'child': {
        'type': 'column',
        'mainAxisSize': 'min',
        'children': [
          {'type': 'text', 'data': 'top-row'},
          for (var i = 0; i < 20; i++) {'type': 'text', 'data': 'row-$i'},
          {'type': 'button', 'text': 'bottom-control'},
        ],
      },
    };

    (DynamicMessagesService, JsAppEngine) liveFixture() {
      final dm = service();
      final def = definition('dm-1');
      final eng = engine(def);
      dm.debugAdd(def, engine: eng);
      return (dm, eng);
    }

    Container tileRoot(WidgetTester tester) => tester
        .widgetList<Container>(
          find.descendant(
            of: find.byType(DynamicWidgetTile),
            matching: find.byWidgetPredicate(
              (w) => w is Container && w.margin != null,
            ),
          ),
        )
        .first;

    testWidgets('AC1 WIDGET-full-width: edge-to-edge at ≤600dp, '
        'desktop padding kept', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final (dm, _) = liveFixture();
      await pumpTile(tester, dm, 'dm-1');
      // Phone: zero horizontal margin.
      expect(
        tileRoot(tester).margin,
        const EdgeInsets.symmetric(horizontal: 0, vertical: 6),
      );
      // Desktop widths keep the breakpoint discipline (#379).
      tester.view.physicalSize = const Size(1280, 800);
      await tester.pump();
      expect(
        tileRoot(tester).margin,
        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      );
    });

    testWidgets('AC2 WIDGET-header-actions: the open icon opens the '
        'ephemeral runtime and never toggles collapse', (tester) async {
      final (dm, _) = liveFixture();
      await pumpTile(tester, dm, 'dm-1');
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.byTooltip('Open as app (without saving)'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.byKey(const ValueKey('ephemeral-dynamic-app')),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      // The tile survived the icon tap expanded (#377 REG).
      expect(find.byKey(const ValueKey('ephemeral-dynamic-app')), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('AC4 WIDGET-no-clip: a tall fixture scrolls to its last '
        'control in the chat tile', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final (dm, eng) = liveFixture();
      await pumpTile(tester, dm, 'dm-1');
      eng.tree.value = tallTree();
      await tester.pump();
      final scrollable = find.descendant(
        of: find.byType(DynamicWidgetTile),
        matching: find.byType(Scrollable),
      );
      final position = tester.state<ScrollableState>(scrollable).position;
      // E1: the scroll wrapper wins over the widget-declared 900px
      // height — the content exceeds the canvas and scrolls (pre-fix the
      // canvas had no scrollable and the overflow was silently clipped).
      expect(position.maxScrollExtent, greaterThan(0));
      await tester.scrollUntilVisible(
        find.text('bottom-control'),
        200,
        scrollable: scrollable,
      );
      // The last control lands inside the visible canvas.
      expect(tester.getRect(find.text('bottom-control')).top, lessThan(844));
    });

    testWidgets('AC4: the ephemeral full-screen runtime scrolls to the '
        'last control and opens at the top', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final (dm, eng) = liveFixture();
      await pumpTile(tester, dm, 'dm-1');
      eng.tree.value = tallTree();
      await tester.pump();
      await tester.tap(find.byTooltip('Open as app (without saving)'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      // Auto-scroll to top on open: the fresh viewport starts at offset 0.
      final scrollable = find.byType(Scrollable).last;
      expect(tester.state<ScrollableState>(scrollable).position.pixels, 0);
      // E1: the same tall fixture is fully reachable in the full-screen
      // runtime too (fillAvailable).
      await tester.scrollUntilVisible(
        find.text('bottom-control').last,
        200,
        scrollable: scrollable,
      );
      expect(
        tester.getRect(find.text('bottom-control').last).top,
        lessThan(844),
      );
      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('ephemeral-dynamic-app')), findsNothing);
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
      await openMenu(tester);
      await tester.tap(find.text('Save as app'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(saved?.id, 'dm-1');
    });

    testWidgets('row menu offers ephemeral open without popping first', (
      tester,
    ) async {
      final (agentService, dm) = await makeService();
      dm.debugAdd(definition('dm-1'));
      await pumpSheet(tester, agentService);
      await openMenu(tester);
      await tester.tap(find.text('Open as app (without saving)'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      // AC4: the sheet surface opens the widget ephemerally too — full
      // screen, on top of the sheet.
      expect(
        find.byKey(const ValueKey('ephemeral-dynamic-app')),
        findsOneWidget,
      );
    });
  });
}
